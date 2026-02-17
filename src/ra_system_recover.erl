%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2017-2025 Broadcom. All Rights Reserved. The term Broadcom refers to Broadcom Inc. and/or its subsidiaries.
%% @hidden
-module(ra_system_recover).

-behaviour(gen_server).

-include("ra.hrl").
%% API functions
-export([start_link/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(DEFAULT_SCAN_INTERVAL, 30000).
-define(DEFAULT_MAX_BACKOFF, 600000).
-define(DEFAULT_INITIAL_BACKOFF, 5000).

%% failed map: ServerName -> {NextRetryMonotonicMs, CurrentBackoffMs}
-record(state, {system :: atom(),
                failed = #{} :: #{atom() => {integer(), non_neg_integer()}},
                scan_interval :: non_neg_integer(),
                initial_backoff :: non_neg_integer(),
                max_backoff :: non_neg_integer()}).

%%%===================================================================
%%% API functions
%%%===================================================================

start_link(System) when is_atom(System) ->
    gen_server:start_link(?MODULE, [System], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([System]) ->
    Conf = ra_system:fetch(System),
    case Conf of
        #{server_recovery_strategy := registered = Strat} ->
            Regd = ra_directory:list_registered(System),
            ?INFO("~s: ra system '~ts' server recovery strategy ~w,
                   num servers ~b",
                  [?MODULE, System, Strat, length(Regd)]),
            [begin
                 case ra:restart_server(System, {N, node()}) of
                     ok ->
                         ok;
                     Err ->
                         ?WARN("~s: ra:restart_server/2 failed with ~p",
                               [?MODULE, Err]),
                         ok
                 end
             end || {N, _Uid} <- Regd],
            ok;
        #{server_recovery_strategy := {Mod, Fun, Args}} ->
            ?INFO("~s: ra system '~ts' server recovery strategy ~s:~s",
                  [?MODULE, System, Mod, Fun]),
            try apply(Mod, Fun, [System | Args]) of
                ok ->
                    ok
            catch C:E:S ->
                      ?ERROR("~s: ~s encountered during server recovery ~p. "
                             "stack ~p",
                             [?MODULE, C, E, S]),
                      ok
            end;
        _ ->
            ?DEBUG("~s: no server recovery configured", [?MODULE]),
            ok
    end,
    ScanInterval = maps:get(server_recovery_scan_interval, Conf,
                            ?DEFAULT_SCAN_INTERVAL),
    InitialBackoff = maps:get(server_recovery_initial_backoff, Conf,
                              ?DEFAULT_INITIAL_BACKOFF),
    MaxBackoff = maps:get(server_recovery_max_backoff, Conf,
                          ?DEFAULT_MAX_BACKOFF),
    State = #state{system = System,
                   scan_interval = ScanInterval,
                   initial_backoff = InitialBackoff,
                   max_backoff = MaxBackoff},
    case Conf of
        #{server_recovery_strategy := undefined} ->
            {ok, State, hibernate};
        #{server_recovery_strategy := _} ->
            schedule_scan(State),
            {ok, State};
        _ ->
            {ok, State, hibernate}
    end.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(scan, #state{system = System,
                         failed = Failed0,
                         initial_backoff = InitialBackoff,
                         max_backoff = MaxBackoff} = State) ->
    Now = erlang:monotonic_time(millisecond),
    Registered = ra_directory:list_registered(System),
    Failed =
        lists:foldl(
          fun({Name, _UId}, Acc) ->
                  case ra_directory:where_is(System, Name) of
                      Pid when is_pid(Pid) ->
                          case maps:is_key(Name, Acc) of
                              true ->
                                  ?INFO("~s: ra server ~w recovered",
                                        [?MODULE, Name]),
                                  maps:remove(Name, Acc);
                              false ->
                                  Acc
                          end;
                      undefined ->
                          case maps:get(Name, Acc, undefined) of
                              undefined ->
                                  attempt_restart(System, Name,
                                                  InitialBackoff,
                                                  MaxBackoff, Acc);
                              {NextRetry, _Backoff} when Now >= NextRetry ->
                                  attempt_restart(System, Name,
                                                  InitialBackoff,
                                                  MaxBackoff, Acc);
                              {_NextRetry, _Backoff} ->
                                  Acc
                          end
                  end
          end, Failed0, Registered),
    schedule_scan(State),
    {noreply, State#state{failed = Failed}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

schedule_scan(#state{scan_interval = Interval}) ->
    erlang:send_after(Interval, self(), scan),
    ok.

attempt_restart(System, Name, InitialBackoff, MaxBackoff, Failed) ->
    ServerId = {Name, node()},
    case ra:restart_server(System, ServerId) of
        ok ->
            ?INFO("~s: successfully restarted ra server ~w",
                  [?MODULE, Name]),
            maps:remove(Name, Failed);
        {error, {already_started, _}} ->
            maps:remove(Name, Failed);
        Err ->
            PrevBackoff = case maps:get(Name, Failed, undefined) of
                              undefined -> InitialBackoff;
                              {_, B} -> B
                          end,
            Backoff = min(PrevBackoff * 2, MaxBackoff),
            NextRetry = erlang:monotonic_time(millisecond) + Backoff,
            ?WARN("~s: failed to restart ra server ~w: ~p. "
                  "Will retry in ~bms",
                  [?MODULE, Name, Err, Backoff]),
            maps:put(Name, {NextRetry, Backoff}, Failed)
    end.
