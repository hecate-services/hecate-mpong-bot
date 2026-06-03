%%%-------------------------------------------------------------------
%%% @doc Challenger-side paddle loop for a pong-over-mesh game.
%%%
%%% Started by the discover_games coordinator once a seat is reserved.
%%% Subscribes to the host's `state_broadcast' (filtered to our game),
%%% reads the authoritative ball, runs the local mpong_ai to aim our
%%% wall, and publishes `paddle_moved' back to the host each frame.
%%%
%%% The challenger keeps NO game state of its own — the host is
%%% authoritative. This process is a pure input source: ball in
%%% (over mesh), paddle position out (over mesh).
%%% @end
%%%-------------------------------------------------------------------
-module(play_remote_paddle).
-behaviour(gen_server).

-export([start_link/2, stop/1]).
-export([init/1, handle_info/2, handle_cast/2, handle_call/3, terminate/2]).

-define(RESUB_MS, 1000).

-record(st, {
    game_id :: binary(),
    wall    :: non_neg_integer(),
    y = 500 :: integer(),
    sub_ref :: reference() | undefined
}).

-spec start_link(binary(), non_neg_integer()) -> {ok, pid()}.
start_link(GameId, WallIndex) ->
    gen_server:start_link(?MODULE, {GameId, WallIndex}, []).

-spec stop(pid()) -> ok.
stop(Pid) -> gen_server:stop(Pid).

init({GameId, WallIndex}) ->
    self() ! subscribe,
    logger:info("[play_remote_paddle] joined ~s as wall ~b", [GameId, WallIndex]),
    {ok, #st{game_id = GameId, wall = WallIndex}}.

handle_info(subscribe, St) ->
    case hecate_mesh:subscribe(broadcast_game_state:topic(), self()) of
        {ok, Ref} -> {noreply, St#st{sub_ref = Ref}};
        _Dark ->
            erlang:send_after(?RESUB_MS, self(), subscribe),
            {noreply, St}
    end;
handle_info({macula_event, Ref, _Topic, Payload, _Meta},
            #st{sub_ref = Ref, game_id = GId, wall = Wall, y = Y0} = St) ->
    case ball_for_game(Payload, GId) of
        {ok, Ball, Tick} ->
            Y1 = mpong_ai:compute_paddle_position(Ball, Y0, Wall),
            hecate_mesh:publish(mpong_match_facts:topic_paddle_moved(),
                                mpong_match_facts:paddle_moved(GId, Wall, Y1, Tick)),
            {noreply, St#st{y = Y1}};
        ignore ->
            {noreply, St}
    end;
handle_info({macula_event_gone, Ref, _Reason}, #st{sub_ref = Ref} = St) ->
    self() ! subscribe,
    {noreply, St#st{sub_ref = undefined}};
handle_info(_Other, St) ->
    {noreply, St}.

handle_cast(_, St) -> {noreply, St}.
handle_call(_, _From, St) -> {reply, ok, St}.

terminate(_Reason, #st{sub_ref = Ref}) ->
    catch hecate_mesh:unsubscribe(Ref),
    ok.

%%====================================================================
%% Internal
%%====================================================================

%% Extract an atom-keyed ball (y, vx) for our game from a received
%% state_broadcast. The payload has crossed the mesh, so keys are
%% binaries. Returns `ignore' for other games or a malformed ball.
ball_for_game(Payload, GId) ->
    case g([<<"game_id">>, game_id], Payload) of
        GId ->
            BallRaw = g([<<"ball">>, ball], Payload),
            case {is_map(BallRaw),
                  g([<<"y">>, y], def(BallRaw)),
                  g([<<"vx">>, vx], def(BallRaw))} of
                {true, Y, Vx} when is_integer(Y), is_integer(Vx) ->
                    Tick = g([<<"tick">>, tick], Payload),
                    {ok, #{y => Y, vx => Vx}, Tick};
                _ ->
                    ignore
            end;
        _Other ->
            ignore
    end.

def(M) when is_map(M) -> M;
def(_)               -> #{}.

g([], _M) -> undefined;
g([K | Rest], M) ->
    case maps:find(K, M) of
        {ok, V} -> V;
        error   -> g(Rest, M)
    end.
