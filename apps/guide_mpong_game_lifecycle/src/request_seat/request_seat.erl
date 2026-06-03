%%%-------------------------------------------------------------------
%%% @doc Challenger-side emitter: request a seat in an advertised game.
%%%
%%% Publishes the `seat_requested' integration fact on the mesh. The
%%% host of `GameId' reacts (via discover_games in HOST role) by
%%% dispatching join_game and replying with `seat_reserved' or
%%% `seat_denied'.
%%% @end
%%%-------------------------------------------------------------------
-module(request_seat).

-export([publish/3]).

%% @doc Ask to fill `WallIndex' of `GameId' as `ChallengerNodeId'.
-spec publish(binary(), binary(), non_neg_integer()) ->
    ok | {error, term()}.
publish(GameId, ChallengerNodeId, WallIndex) ->
    hecate_mesh:publish(mpong_match_facts:topic_seat_requested(),
                        mpong_match_facts:seat_requested(GameId, ChallengerNodeId, WallIndex)).
