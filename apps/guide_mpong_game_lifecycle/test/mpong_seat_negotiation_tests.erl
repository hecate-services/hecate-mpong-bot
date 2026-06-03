%%%-------------------------------------------------------------------
%%% @doc Pure domain tests for pong-over-mesh seat negotiation.
%%%
%%% Proves the existing aggregate (host_game / join_game / start_game)
%%% already models 1v1 mesh seating, so no new commands were needed:
%%%   * host (max 2) → join wall 0 → join wall 1 → start succeeds
%%%   * a third join is denied (game_full) — the "deny" condition
%%%   * start before 2 players is denied (need_at_least_2_players)
%%%   * only the host may start (only_host_can_start)
%%%
%%% All pure: drives mpong_game_aggregate:execute/2 + apply/2 with no
%%% running store.
%%% @end
%%%-------------------------------------------------------------------
-module(mpong_seat_negotiation_tests).
-include_lib("eunit/include/eunit.hrl").

-define(G, <<"g1">>).
-define(HOST, <<"host@n">>).
-define(CH, <<"challenger@m">>).

seat_sequence_test() ->
    S3 = seated(),
    {ok, [E4]} = ex(S3, start_game, #{game_id => ?G, host_node_id => ?HOST}),
    ?assertEqual(<<"game_started_v1">>, maps:get(event_type, E4)).

challenger_gets_wall_one_test() ->
    S0 = mpong_game_state:new(?G),
    {ok, [E1]} = ex(S0, host_game, #{game_id => ?G, host_node_id => ?HOST, max_players => 2}),
    ?assertEqual(<<"game_hosted_v1">>, maps:get(event_type, E1)),
    S1 = mpong_game_aggregate:apply(S0, E1),
    {ok, [E2]} = ex(S1, join_game, #{game_id => ?G, player_node_id => ?HOST}),
    ?assertEqual(0, maps:get(wall_index, E2)),
    S2 = mpong_game_aggregate:apply(S1, E2),
    {ok, [E3]} = ex(S2, join_game, #{game_id => ?G, player_node_id => ?CH}),
    ?assertEqual(1, maps:get(wall_index, E3)).

third_join_is_full_test() ->
    S3 = seated(),
    ?assertEqual({error, game_full},
                 ex(S3, join_game, #{game_id => ?G, player_node_id => <<"third@x">>})).

start_needs_two_players_test() ->
    S0 = mpong_game_state:new(?G),
    {ok, [E1]} = ex(S0, host_game, #{game_id => ?G, host_node_id => ?HOST, max_players => 2}),
    S1 = mpong_game_aggregate:apply(S0, E1),
    {ok, [E2]} = ex(S1, join_game, #{game_id => ?G, player_node_id => ?HOST}),
    S2 = mpong_game_aggregate:apply(S1, E2),
    ?assertEqual({error, need_at_least_2_players},
                 ex(S2, start_game, #{game_id => ?G, host_node_id => ?HOST})).

only_host_can_start_test() ->
    S3 = seated(),
    ?assertEqual({error, only_host_can_start},
                 ex(S3, start_game, #{game_id => ?G, host_node_id => <<"impostor@z">>})).

%%--------------------------------------------------------------------
%% Build state up to "hosted + both seats filled" (2 players, wall 0+1).
seated() ->
    S0 = mpong_game_state:new(?G),
    {ok, [E1]} = ex(S0, host_game, #{game_id => ?G, host_node_id => ?HOST, max_players => 2}),
    S1 = mpong_game_aggregate:apply(S0, E1),
    {ok, [E2]} = ex(S1, join_game, #{game_id => ?G, player_node_id => ?HOST}),
    S2 = mpong_game_aggregate:apply(S1, E2),
    {ok, [E3]} = ex(S2, join_game, #{game_id => ?G, player_node_id => ?CH}),
    mpong_game_aggregate:apply(S2, E3).

ex(State, Cmd, Payload) ->
    mpong_game_aggregate:execute(State, Payload#{command_type => Cmd}).
