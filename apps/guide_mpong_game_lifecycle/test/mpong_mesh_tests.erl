%%%-------------------------------------------------------------------
%%% @doc Tests for the mesh-fact contract + matchmaking role decision.
%%%
%%% Facts must round-trip whether parsed from the atom-keyed build form
%%% or the binary-keyed form a payload takes after crossing the mesh
%%% (CBOR). The role decision must be deterministic and race-damping.
%%% @end
%%%-------------------------------------------------------------------
-module(mpong_mesh_tests).
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Fact round-trips (atom-key build + binary-key wire form)
%%====================================================================

seat_requested_roundtrip_test() ->
    Built = mpong_match_facts:seat_requested(<<"g">>, <<"c">>, 1),
    Want  = #{game_id => <<"g">>, challenger_node_id => <<"c">>, wall_index => 1},
    ?assertEqual(Want, mpong_match_facts:parse_seat_requested(Built)),
    Wire = #{<<"game_id">> => <<"g">>, <<"challenger_node_id">> => <<"c">>,
             <<"wall_index">> => 1},
    ?assertEqual(Want, mpong_match_facts:parse_seat_requested(Wire)).

seat_reserved_roundtrip_test() ->
    Built = mpong_match_facts:seat_reserved(<<"g">>, <<"h">>, <<"c">>, 1),
    P = mpong_match_facts:parse_seat_reserved(Built),
    ?assertEqual(<<"g">>, maps:get(game_id, P)),
    ?assertEqual(<<"c">>, maps:get(challenger_node_id, P)),
    ?assertEqual(1, maps:get(wall_index, P)),
    Wire = #{<<"game_id">> => <<"g">>, <<"host_node_id">> => <<"h">>,
             <<"challenger_node_id">> => <<"c">>, <<"wall_index">> => 1},
    ?assertEqual(P, mpong_match_facts:parse_seat_reserved(Wire)).

seat_denied_reason_is_binary_test() ->
    Built = mpong_match_facts:seat_denied(<<"g">>, <<"h">>, <<"c">>, game_full),
    P = mpong_match_facts:parse_seat_denied(Built),
    ?assertEqual(<<"game_full">>, maps:get(reason, P)).

paddle_moved_roundtrip_test() ->
    Built = mpong_match_facts:paddle_moved(<<"g">>, 1, 250, 42),
    Want  = #{game_id => <<"g">>, wall_index => 1, y => 250, tick => 42},
    ?assertEqual(Want, mpong_match_facts:parse_paddle_moved(Built)),
    Wire = #{<<"game_id">> => <<"g">>, <<"wall_index">> => 1,
             <<"y">> => 250, <<"tick">> => 42},
    ?assertEqual(Want, mpong_match_facts:parse_paddle_moved(Wire)).

%%====================================================================
%% Role decision (pure, race-damping)
%%====================================================================

no_ads_means_host_test() ->
    ?assertEqual(host, discover_games:decide_role([], <<"me">>)).

heard_open_game_means_challenge_test() ->
    Ad = ad(<<"hosted">>, <<"other">>, <<"g2">>),
    ?assertEqual({challenge, <<"g2">>}, discover_games:decide_role([Ad], <<"me">>)).

ignores_own_advertisement_test() ->
    Mine = ad(<<"hosted">>, <<"me">>, <<"g1">>),
    ?assertEqual(host, discover_games:decide_role([Mine], <<"me">>)).

ignores_non_hosted_actions_test() ->
    Ended = ad(<<"ended">>, <<"other">>, <<"g3">>),
    ?assertEqual(host, discover_games:decide_role([Ended], <<"me">>)).

lowest_game_id_wins_test() ->
    A1 = ad(<<"hosted">>, <<"o1">>, <<"gb">>),
    A2 = ad(<<"hosted">>, <<"o2">>, <<"ga">>),
    ?assertEqual({challenge, <<"ga">>}, discover_games:decide_role([A1, A2], <<"me">>)).

ad(Action, Host, GameId) ->
    #{action => Action, host_node_id => Host, game_id => GameId, max_players => 2}.
