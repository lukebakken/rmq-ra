%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2017-2023 Broadcom. All Rights Reserved. The term Broadcom refers to Broadcom Inc. and/or its subsidiaries.
%%
-module(ra_server_tests).
-include_lib("eunit/include/eunit.hrl").
-include("ra.hrl").

%% Test the improved membership change error handling
membership_change_error_handling_test() ->
    %% Setup a mock ra_server state
    ServerId1 = {ra_server1, node()},
    ServerId2 = {ra_server2, node()},
    ServerId3 = {ra_server3, node()},
    
    InitialCluster = #{
        ServerId1 => {10, erlang:system_time(millisecond)},
        ServerId2 => {10, erlang:system_time(millisecond)}
    },
    
    State = #{
        self => ServerId1,
        current_term => 1,
        cluster => InitialCluster,
        commit_index => 10,
        last_applied => 10
    },
    
    %% Test 1: Join command starts tracking the membership change
    JoinCmd = {'$ra_join', #{}, ServerId3, #{}},
    From = {self(), make_ref()},
    {NewState1, Effects1} = ra_server:handle_leader({command, JoinCmd, From}, State),
    
    %% Verify the state was updated correctly
    ?assertMatch(#{pending_membership_change := #{
        type := join,
        server_id := ServerId3,
        started_at := _,
        timeout := 30000
    }}, NewState1),
    
    %% Verify the cluster was updated
    ?assert(maps:is_key(ServerId3, maps:get(cluster, NewState1))),
    
    %% Verify effects include the verification timer
    TimerEffect = lists:keyfind(timer, 1, Effects1),
    ?assertMatch({timer, verify_membership_change, 5000}, TimerEffect),
    
    %% Test 2: Verification succeeds when server is healthy
    %% Mock a successful health check by updating the server's last ack time
    CurrentTime = erlang:system_time(millisecond),
    UpdatedCluster = maps:update(ServerId3, {1, CurrentTime}, maps:get(cluster, NewState1)),
    NewState2 = NewState1#{cluster := UpdatedCluster},
    
    {NewState3, Effects2} = ra_server:handle_leader({timeout, verify_membership_change}, NewState2),
    
    %% Verify the pending change was cleared
    ?assertNot(maps:is_key(pending_membership_change, NewState3)),
    ?assertEqual([], Effects2),
    
    %% Test 3: Verification fails and reverts when server is unhealthy
    %% Create a state with a pending join but no recent communication
    OldTime = CurrentTime - 20000, % 20 seconds ago
    UnhealthyCluster = maps:update(ServerId3, {1, OldTime}, UpdatedCluster),
    UnhealthyState = NewState1#{
        cluster := UnhealthyCluster,
        pending_membership_change := #{
            type => join,
            server_id => ServerId3,
            started_at => CurrentTime - 40000, % 40 seconds ago (past timeout)
            timeout => 30000
        }
    },
    
    {RevertedState, RevertEffects} = ra_server:handle_leader(
        {timeout, verify_membership_change}, UnhealthyState),
    
    %% Verify the change was reverted
    ?assertNot(maps:is_key(pending_membership_change, RevertedState)),
    ?assertNot(maps:is_key(ServerId3, maps:get(cluster, RevertedState))),
    
    %% Verify notification effect was added
    ?assertMatch([{send_msg, _}], RevertEffects),
    
    %% Test 4: Leave command starts tracking the membership change
    LeaveCmd = {'$ra_leave', #{}, ServerId2},
    {NewState4, Effects4} = ra_server:handle_leader({command, LeaveCmd, From}, State),
    
    %% Verify the state was updated correctly
    ?assertMatch(#{pending_membership_change := #{
        type := leave,
        server_id := ServerId2,
        started_at := _,
        timeout := 30000
    }}, NewState4),
    
    %% Verify the cluster was updated
    ?assertNot(maps:is_key(ServerId2, maps:get(cluster, NewState4))),
    
    %% Verify effects include the verification timer
    LeaveTimerEffect = lists:keyfind(timer, 1, Effects4),
    ?assertMatch({timer, verify_membership_change, 5000}, LeaveTimerEffect),
    
    ok.
