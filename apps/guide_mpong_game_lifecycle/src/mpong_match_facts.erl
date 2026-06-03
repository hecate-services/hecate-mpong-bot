%%%-------------------------------------------------------------------
%%% @doc Mesh integration-fact contract for pong-over-mesh matchmaking.
%%%
%%% Single source of truth for the seat-negotiation + paddle-sync wire
%%% shapes, so producers (request_seat, reserve_seat, play_remote_paddle)
%%% and the consumer (discover_games coordinator) cannot drift.
%%%
%%% Topics are tiered constants under
%%% `io.macula/beam-campus/hecate/mpong/<type>_v1' (one per fact type).
%%% The `game_id' lives in the payload and is matched in-handler — there
%%% are NO per-game topics.
%%%
%%% Build functions use atom keys (publish side; macula CBOR-encodes the
%%% term). Parse functions accept EITHER atom or binary keys, because a
%%% payload that has crossed the mesh comes back with binary keys.
%%% @end
%%%-------------------------------------------------------------------
-module(mpong_match_facts).

-export([topic_seat_requested/0, topic_seat_reserved/0,
         topic_seat_denied/0, topic_paddle_moved/0, topic_game_advertised/0]).
-export([seat_requested/3, seat_reserved/4, seat_denied/4, paddle_moved/4]).
-export([parse_seat_requested/1, parse_seat_reserved/1, parse_seat_denied/1,
         parse_paddle_moved/1, parse_game_advertised/1]).

%%====================================================================
%% Topics
%%====================================================================

topic_seat_requested()  -> hecate_topics:app_fact(<<"mpong">>, <<"seat_requested">>, 1).
topic_seat_reserved()   -> hecate_topics:app_fact(<<"mpong">>, <<"seat_reserved">>, 1).
topic_seat_denied()     -> hecate_topics:app_fact(<<"mpong">>, <<"seat_denied">>, 1).
topic_paddle_moved()    -> hecate_topics:app_fact(<<"mpong">>, <<"paddle_moved">>, 1).
topic_game_advertised() -> hecate_topics:app_fact(<<"mpong">>, <<"game_advertised">>, 1).

%%====================================================================
%% Build (publish side — atom keys)
%%====================================================================

-spec seat_requested(binary(), binary(), non_neg_integer()) -> map().
seat_requested(GameId, ChallengerNodeId, WallIndex) ->
    #{game_id => GameId, challenger_node_id => ChallengerNodeId,
      wall_index => WallIndex, requested_at => now_ms()}.

-spec seat_reserved(binary(), binary(), binary(), non_neg_integer()) -> map().
seat_reserved(GameId, HostNodeId, ChallengerNodeId, WallIndex) ->
    #{game_id => GameId, host_node_id => HostNodeId,
      challenger_node_id => ChallengerNodeId, wall_index => WallIndex,
      reserved_at => now_ms()}.

-spec seat_denied(binary(), binary(), binary(), atom() | binary()) -> map().
seat_denied(GameId, HostNodeId, ChallengerNodeId, Reason) ->
    #{game_id => GameId, host_node_id => HostNodeId,
      challenger_node_id => ChallengerNodeId, reason => to_bin(Reason)}.

-spec paddle_moved(binary(), non_neg_integer(), integer(), non_neg_integer()) -> map().
paddle_moved(GameId, WallIndex, Y, Tick) ->
    #{game_id => GameId, wall_index => WallIndex, y => Y, tick => Tick}.

%%====================================================================
%% Parse (receive side — atom OR binary keys)
%%====================================================================

parse_seat_requested(P) ->
    #{game_id            => g([<<"game_id">>, game_id], P),
      challenger_node_id => g([<<"challenger_node_id">>, challenger_node_id], P),
      wall_index         => g([<<"wall_index">>, wall_index], P)}.

parse_seat_reserved(P) ->
    #{game_id            => g([<<"game_id">>, game_id], P),
      host_node_id       => g([<<"host_node_id">>, host_node_id], P),
      challenger_node_id => g([<<"challenger_node_id">>, challenger_node_id], P),
      wall_index         => g([<<"wall_index">>, wall_index], P)}.

parse_seat_denied(P) ->
    #{game_id            => g([<<"game_id">>, game_id], P),
      challenger_node_id => g([<<"challenger_node_id">>, challenger_node_id], P),
      reason             => g([<<"reason">>, reason], P)}.

parse_paddle_moved(P) ->
    #{game_id    => g([<<"game_id">>, game_id], P),
      wall_index => g([<<"wall_index">>, wall_index], P),
      y          => g([<<"y">>, y], P),
      tick       => g([<<"tick">>, tick], P)}.

%% game_advertised is produced by advertise_game (action + game_id +
%% host_node_id + max_players). We only need the open-game fields.
parse_game_advertised(P) ->
    #{action       => g([<<"action">>, action], P),
      game_id      => g([<<"game_id">>, game_id], P),
      host_node_id => g([<<"host_node_id">>, host_node_id], P),
      max_players  => g([<<"max_players">>, max_players], P)}.

%%====================================================================
%% Internal
%%====================================================================

%% First present key wins (binary preferred, atom fallback).
g([], _P) -> undefined;
g([K | Rest], P) ->
    case maps:find(K, P) of
        {ok, V} -> V;
        error   -> g(Rest, P)
    end.

now_ms() -> erlang:system_time(millisecond).

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A)   -> atom_to_binary(A, utf8).
