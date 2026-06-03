%%%-------------------------------------------------------------------
%%% @doc Host-side emitter: answer a seat request.
%%%
%%% After the host dispatches join_game for a remote challenger, it
%%% publishes the outcome as a mesh fact:
%%%   * `seat_reserved' — the challenger now owns `WallIndex'.
%%%   * `seat_denied'   — the game was full / already started / etc.
%%%
%%% The seat itself is the event-sourced `player_joined_v1' on the host
%%% aggregate; these facts are the public mesh contract telling the
%%% challenger the outcome.
%%% @end
%%%-------------------------------------------------------------------
-module(reserve_seat).

-export([publish_reserved/4, publish_denied/4]).

-spec publish_reserved(binary(), binary(), binary(), non_neg_integer()) ->
    ok | {error, term()}.
publish_reserved(GameId, HostNodeId, ChallengerNodeId, WallIndex) ->
    hecate_mesh:publish(mpong_match_facts:topic_seat_reserved(),
                        mpong_match_facts:seat_reserved(GameId, HostNodeId,
                                                        ChallengerNodeId, WallIndex)).

-spec publish_denied(binary(), binary(), binary(), atom() | binary()) ->
    ok | {error, term()}.
publish_denied(GameId, HostNodeId, ChallengerNodeId, Reason) ->
    hecate_mesh:publish(mpong_match_facts:topic_seat_denied(),
                        mpong_match_facts:seat_denied(GameId, HostNodeId,
                                                      ChallengerNodeId, Reason)).
