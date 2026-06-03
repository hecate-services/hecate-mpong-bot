%%%-------------------------------------------------------------------
%%% @doc Self-organizing matchmaking coordinator for pong-over-mesh.
%%%
%%% One per bot. Owns the bot's role state machine and its current
%%% game end-to-end. Race-free by construction: a jittered seek window
%%% makes each bot become HOST xor CHALLENGER, never both at once.
%%%
%%%   SEEKING ──hears an open game──▶ CHALLENGING ──seat_reserved──▶ PLAYING_REMOTE
%%%       │                              └─seat_denied─▶ SEEKING
%%%       └──window expires, none heard──▶ HOSTING ──seat filled──▶ PLAYING_HOST
%%%                                            └─no seat in T─▶ (re-advertise)
%%%
%%% Subscriptions are single, long-lived, one per fact type (NOT per
%%% game); the handler filters by role + game_id (the function-head
%%% clause is the filter). The game lifecycle itself is the existing
%%% event-sourced aggregate (host_game / join_game / start_game /
%%% end_game) — this process only drives it and bridges the mesh facts.
%%% @end
%%%-------------------------------------------------------------------
-module(discover_games).
-behaviour(gen_server).

-include_lib("evoq/include/evoq.hrl").

-export([start_link/0, decide_role/2, churn_action/3]).
-export([init/1, handle_info/2, handle_cast/2, handle_call/3, terminate/2]).

-define(SEEK_BASE_MS, 3000).
-define(SEEK_JITTER_MS, 3000).
-define(REANNOUNCE_MS, 10000).
-define(RESUB_MS, 1000).
-define(MAX_PLAYERS, 2).
-define(REMOTE_WALL, 1).
%% Churn watchdog: the host pauses when the remote paddle goes silent,
%% then ends the game if it stays silent past the grace window.
-define(WATCHDOG_MS, 1000).   %% how often the host checks paddle freshness
-define(STALE_MS, 3000).      %% no paddle_moved for this long => pause
-define(GRACE_MS, 10000).     %% paused this long with no return => end

-record(st, {
    node_id    :: binary(),
    role = seeking :: seeking | hosting | challenging | playing_host | playing_remote,
    game_id    :: binary() | undefined,
    challenger :: binary() | undefined,   %% host: the remote player's node id
    target     :: binary() | undefined,   %% challenger: game we requested
    engine_pid :: pid() | undefined,      %% host
    engine_mon :: reference() | undefined,
    paddle_pid :: pid() | undefined,      %% challenger
    last_paddle_ms :: integer() | undefined,  %% host: last paddle_moved arrival
    paused_since   :: integer() | undefined,  %% host: when we churn-paused (undefined = running)
    heard = [] :: [map()],                %% SEEKING: open ads collected
    subs  = #{} :: #{binary() => reference()}
}).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Pure role decision (exported for tests): given the open-game
%% ads heard during the seek window and our own node id, become HOST if
%% none are joinable, else CHALLENGE the lowest game_id (stable
%% tie-break to damp two challengers colliding on the same game).
-spec decide_role([map()], binary()) -> host | {challenge, binary()}.
decide_role(Heard, MyNode) ->
    Open = [GId || #{action := <<"hosted">>, host_node_id := H, game_id := GId} <- Heard,
                   H =/= MyNode, is_binary(GId)],
    case lists:usort(Open) of
        []        -> host;
        [GId | _] -> {challenge, GId}
    end.

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    process_flag(trap_exit, true),   %% linked play_remote_paddle exits arrive as messages
    NodeId = atom_to_binary(node(), utf8),
    self() ! subscribe,
    {ok, #st{node_id = NodeId}}.

handle_info(subscribe, St) ->
    {noreply, ensure_subs(St)};

%% Seek window elapsed — commit to a role.
handle_info(seek_deadline, #st{role = seeking, heard = Heard, node_id = Me} = St) ->
    case decide_role(Heard, Me) of
        host             -> {noreply, become_host(St)};
        {challenge, GId} -> {noreply, become_challenger(GId, St)}
    end;
handle_info(seek_deadline, St) ->
    {noreply, St};

handle_info(reannounce, #st{role = hosting, game_id = GId, node_id = Me} = St) ->
    advertise_game:announce(#{game_id => GId, host_node_id => Me,
                              max_players => ?MAX_PLAYERS}),
    schedule(reannounce, ?REANNOUNCE_MS),
    {noreply, St};
handle_info(reannounce, St) ->
    {noreply, St};

%% Host churn watchdog: pause when the remote paddle goes silent, end
%% the game if it stays silent past the grace window.
handle_info(paddle_watchdog, #st{role = playing_host, engine_pid = Pid,
                                 last_paddle_ms = Last, paused_since = Since} = St) ->
    case churn_action(Last, Since, now_ms()) of
        ok ->
            schedule(paddle_watchdog, ?WATCHDOG_MS),
            {noreply, St};
        pause ->
            mpong_game_engine:pause(Pid),
            logger:info("[discover_games] ~s paused ~s — remote paddle stale",
                        [St#st.node_id, St#st.game_id]),
            schedule(paddle_watchdog, ?WATCHDOG_MS),
            {noreply, St#st{paused_since = now_ms()}};
        end_stale ->
            logger:info("[discover_games] ~s ending ~s — challenger abandoned",
                        [St#st.node_id, St#st.game_id]),
            {noreply, abandon_game(St)}   %% engine DOWN -> reseek; no reschedule
    end;
handle_info(paddle_watchdog, St) ->
    {noreply, St};

%% Mesh facts. Route by topic; the role/game guards do the filtering.
handle_info({macula_event, _Ref, Topic, Payload, _Meta}, St) ->
    {noreply, route(Topic, Payload, St)};

handle_info({macula_event_gone, Ref, _Reason}, St) ->
    {noreply, resubscribe(Ref, St)};

%% Our engine (host) or paddle loop (challenger) ended → the game is
%% over for us. Re-advertise withdrawal if hosting and re-seek.
handle_info({'DOWN', Mon, process, _Pid, _Reason}, #st{engine_mon = Mon, game_id = GId} = St) ->
    catch advertise_game:ended(GId),
    {noreply, reseek(St)};
handle_info({'EXIT', Pid, _Reason}, #st{paddle_pid = Pid} = St) ->
    {noreply, reseek(St)};
handle_info(_Other, St) ->
    {noreply, St}.

handle_cast(_, St) -> {noreply, St}.
handle_call(_, _From, St) -> {reply, ok, St}.

terminate(_Reason, _St) -> ok.

%%====================================================================
%% Subscriptions (single per fact type, long-lived, self-healing)
%%====================================================================

topics() ->
    [mpong_match_facts:topic_game_advertised(),
     mpong_match_facts:topic_seat_requested(),
     mpong_match_facts:topic_seat_reserved(),
     mpong_match_facts:topic_seat_denied(),
     mpong_match_facts:topic_paddle_moved()].

%% Subscribe to any not-yet-subscribed topic; retry while the mesh is
%% dark. On first success, open the seek window.
ensure_subs(#st{subs = Subs0} = St) ->
    {Subs, AllUp} = lists:foldl(fun(Topic, {Acc, Up}) ->
        case maps:is_key(Topic, Acc) of
            true  -> {Acc, Up};
            false ->
                case hecate_mesh:subscribe(Topic, self()) of
                    {ok, Ref} -> {Acc#{Topic => Ref}, Up};
                    _Dark     -> {Acc, false}
                end
        end
    end, {Subs0, true}, topics()),
    St1 = St#st{subs = Subs},
    case AllUp of
        false ->
            schedule(subscribe, ?RESUB_MS),
            St1;
        true ->
            maybe_open_seek_window(St1)
    end.

maybe_open_seek_window(#st{role = seeking, game_id = undefined} = St) ->
    schedule(seek_deadline, ?SEEK_BASE_MS + rand:uniform(?SEEK_JITTER_MS)),
    St;
maybe_open_seek_window(St) ->
    St.

resubscribe(Ref, #st{subs = Subs} = St) ->
    case [T || {T, R} <- maps:to_list(Subs), R =:= Ref] of
        [Topic | _] -> ensure_subs(St#st{subs = maps:remove(Topic, Subs)});
        []          -> St
    end.

%%====================================================================
%% Fact routing
%%====================================================================

route(Topic, Payload, St) ->
    Adv  = mpong_match_facts:topic_game_advertised(),
    Req  = mpong_match_facts:topic_seat_requested(),
    Res  = mpong_match_facts:topic_seat_reserved(),
    Den  = mpong_match_facts:topic_seat_denied(),
    Pad  = mpong_match_facts:topic_paddle_moved(),
    case Topic of
        Adv -> on_game_advertised(mpong_match_facts:parse_game_advertised(Payload), St);
        Req -> on_seat_requested(mpong_match_facts:parse_seat_requested(Payload), St);
        Res -> on_seat_reserved(mpong_match_facts:parse_seat_reserved(Payload), St);
        Den -> on_seat_denied(mpong_match_facts:parse_seat_denied(Payload), St);
        Pad -> on_paddle_moved(mpong_match_facts:parse_paddle_moved(Payload), St);
        _   -> St
    end.

%% SEEKING: collect open ads from other hosts.
on_game_advertised(#{action := <<"hosted">>} = Ad, #st{role = seeking, heard = H} = St) ->
    St#st{heard = [Ad | H]};
%% PLAYING_REMOTE / CHALLENGING: our host's game ended/withdrew → re-seek.
on_game_advertised(#{game_id := GId, action := Action},
                   #st{game_id = GId} = St)
  when Action =:= <<"ended">>; Action =:= <<"withdrawn">>; Action =:= <<"closed">> ->
    reseek(St);
on_game_advertised(_Ad, St) ->
    St.

%% HOST: a challenger wants our open seat.
on_seat_requested(#{game_id := GId, challenger_node_id := Ch},
                  #st{role = hosting, game_id = GId, node_id = Me} = St)
  when is_binary(Ch), Ch =/= Me ->
    case dispatch(join_game, GId, #{player_node_id => Ch,
                                    transport => <<"remote">>,
                                    champion_name => Ch}) of
        {ok, _V, _Events} ->
            reserve_seat:publish_reserved(GId, Me, Ch, ?REMOTE_WALL),
            start_and_launch(Ch, St);
        {error, Reason} ->
            reserve_seat:publish_denied(GId, Me, Ch, Reason),
            St
    end;
on_seat_requested(_Req, St) ->
    St.

%% CHALLENGER: our seat was granted → start playing the remote paddle.
on_seat_reserved(#{game_id := GId, challenger_node_id := Me, wall_index := Wall},
                 #st{role = challenging, target = GId, node_id = Me} = St) ->
    {ok, Pid} = play_remote_paddle:start_link(GId, wall_or_default(Wall)),
    logger:info("[discover_games] ~s playing remote wall in ~s", [Me, GId]),
    St#st{role = playing_remote, game_id = GId, paddle_pid = Pid};
on_seat_reserved(_Res, St) ->
    St.

%% CHALLENGER: denied → back to seeking.
on_seat_denied(#{game_id := GId, challenger_node_id := Me},
               #st{role = challenging, target = GId, node_id = Me} = St) ->
    reseek(St);
on_seat_denied(_Den, St) ->
    St.

%% HOST: feed the remote challenger's paddle into our engine.
on_paddle_moved(#{game_id := GId, y := Y},
                #st{role = playing_host, game_id = GId,
                    engine_pid = Pid, challenger = Ch, paused_since = Since} = St)
  when is_pid(Pid), is_integer(Y), is_binary(Ch) ->
    mpong_game_engine:update_paddle(Pid, Ch, Y),
    %% Fresh input: record it and, if we were churn-paused, resume.
    St1 = case Since of
        undefined -> St;
        _ ->
            mpong_game_engine:resume(Pid),
            logger:info("[discover_games] ~s resumed ~s — remote paddle returned",
                        [St#st.node_id, GId]),
            St#st{paused_since = undefined}
    end,
    St1#st{last_paddle_ms = now_ms()};
on_paddle_moved(_Pad, St) ->
    St.

%%====================================================================
%% Role transitions
%%====================================================================

become_host(#st{node_id = Me} = St) ->
    GId = gen_game_id(),
    {ok, _, _} = dispatch(host_game, GId, #{host_node_id => Me, max_players => ?MAX_PLAYERS}),
    %% Join our own local AI bot at wall 0 (assigned by join order).
    _ = dispatch(join_game, GId, #{player_node_id => Me,
                                   transport => <<"local">>,
                                   champion_name => Me}),
    advertise_game:announce(#{game_id => GId, host_node_id => Me,
                              max_players => ?MAX_PLAYERS}),
    schedule(reannounce, ?REANNOUNCE_MS),
    logger:info("[discover_games] ~s hosting open game ~s", [Me, GId]),
    St#st{role = hosting, game_id = GId, heard = []}.

become_challenger(GId, #st{node_id = Me} = St) ->
    request_seat:publish(GId, Me, ?REMOTE_WALL),
    logger:info("[discover_games] ~s requesting a seat in ~s", [Me, GId]),
    St#st{role = challenging, target = GId, heard = []}.

%% HOST: seat filled — start the game and launch the engine with the
%% remote wall wired up.
start_and_launch(Ch, #st{game_id = GId, node_id = Me} = St) ->
    case dispatch(start_game, GId, #{host_node_id => Me}) of
        {ok, _V, _Events} ->
            Config = #{game_id => GId,
                       players => #{Me => #{wall_index => 0},
                                    Ch => #{wall_index => ?REMOTE_WALL}},
                       player_modes => #{0 => {bot, #{}}, ?REMOTE_WALL => remote}},
            {ok, EnginePid} = run_game_engine_sup:start_engine(Config),
            Mon = erlang:monitor(process, EnginePid),
            schedule(paddle_watchdog, ?WATCHDOG_MS),
            logger:info("[discover_games] ~s started mesh game ~s vs ~s", [Me, GId, Ch]),
            St#st{role = playing_host, challenger = Ch,
                  engine_pid = EnginePid, engine_mon = Mon,
                  last_paddle_ms = now_ms(), paused_since = undefined};
        {error, _Reason} ->
            St
    end.

%% Reset to SEEKING and open a fresh window.
reseek(#st{paddle_pid = PPid} = St) ->
    case is_pid(PPid) of
        true -> catch play_remote_paddle:stop(PPid);
        false -> ok
    end,
    St1 = St#st{role = seeking, game_id = undefined, challenger = undefined,
                target = undefined, engine_pid = undefined, engine_mon = undefined,
                paddle_pid = undefined, last_paddle_ms = undefined,
                paused_since = undefined, heard = []},
    schedule(seek_deadline, ?SEEK_BASE_MS + rand:uniform(?SEEK_JITTER_MS)),
    St1.

%% Pure churn decision (exported for tests). Given the last paddle_moved
%% arrival, when we churn-paused (or undefined if running), and now:
%%   ok        — input is fresh, or we're paused but still within grace
%%   pause     — input just went stale; suspend the engine
%%   end_stale — paused past the grace window; abandon the game
-spec churn_action(integer(), integer() | undefined, integer()) ->
    ok | pause | end_stale.
churn_action(LastMs, PausedSince, Now) ->
    case Now - LastMs > ?STALE_MS of
        false -> ok;
        true ->
            case PausedSince of
                undefined                              -> pause;
                Since when Now - Since > ?GRACE_MS     -> end_stale;
                _                                      -> ok
            end
    end.

%% Best-effort: record the end, stop the engine. The engine 'DOWN'
%% handler then advertises the game ended and re-seeks.
abandon_game(#st{game_id = GId, node_id = Me, engine_pid = Pid} = St) ->
    catch dispatch(end_game, GId, #{winner_node_id => Me,
                                    reason => <<"challenger_abandoned">>}),
    catch run_game_engine_sup:stop_engine(Pid),
    St.

%%====================================================================
%% Helpers
%%====================================================================

%% Dispatch a command through evoq into the mpong_store aggregate.
dispatch(CmdType, GameId, Extra) ->
    StreamId = mpong_game_aggregate:stream_id(GameId),
    EvoqCmd = #evoq_command{
        command_type = CmdType,
        aggregate_type = mpong_game_aggregate,
        aggregate_id = StreamId,
        payload = Extra#{command_type => CmdType, game_id => GameId},
        metadata = #{timestamp => erlang:system_time(millisecond)}
    },
    evoq_dispatcher:dispatch(EvoqCmd, #{store_id => mpong_store,
                                        adapter => reckon_evoq_adapter,
                                        consistency => eventual}).

gen_game_id() ->
    Rand = integer_to_binary(erlang:unique_integer([positive])),
    <<"mesh-", Rand/binary>>.

wall_or_default(W) when is_integer(W) -> W;
wall_or_default(_)                    -> ?REMOTE_WALL.

schedule(Msg, Ms) -> erlang:send_after(Ms, self(), Msg).

now_ms() -> erlang:system_time(millisecond).
