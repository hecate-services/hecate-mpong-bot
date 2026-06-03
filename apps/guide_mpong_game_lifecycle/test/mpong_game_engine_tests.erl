%%%-------------------------------------------------------------------
%%% @doc Engine tests for the pong-over-mesh remote wall + churn pause.
%%%
%%% Verifies the two engine behaviours phase 2 depends on:
%%%   1. a `remote' wall holds its externally-set paddle position
%%%      (run_ai must NOT overwrite it with bot AI), and
%%%   2. `pause/1' freezes the ball even past the point-countdown
%%%      window, `resume/1' restarts motion.
%%%
%%% The engine auto-ticks at 25Hz and broadcasts every 5th tick via
%%% hecate_mesh:publish. We start hecate_om_identity so that publish
%%% degrades to {error, mesh_unavailable} instead of crashing on a
%%% noproc gen_server call. No live mesh is needed.
%%% @end
%%%-------------------------------------------------------------------
-module(mpong_game_engine_tests).
-include_lib("eunit/include/eunit.hrl").

%% paused_until = COUNTDOWN_TICKS = 50 ticks * 40ms = 2.0s before the
%% ball naturally starts moving. We must wait past that to prove a
%% suspend freezes a ball that WOULD otherwise be in motion.
-define(PAST_COUNTDOWN_MS, 2300).
-define(FEW_TICKS_MS, 250).

engine_test_() ->
    {setup, fun setup/0, fun teardown/1,
     [
        {"remote wall holds externally-set position", fun remote_wall_holds_position/0},
        {"suspend freezes the ball; resume restarts it", {timeout, 15, fun suspend_resume/0}}
     ]}.

setup() ->
    case whereis(hecate_om_identity) of
        undefined ->
            {ok, Pid} = hecate_om_identity:start_link(),
            {started, Pid};
        Pid ->
            {existing, Pid}
    end.

teardown({started, Pid}) ->
    catch gen_server:stop(Pid),
    ok;
teardown(_) ->
    ok.

%%--------------------------------------------------------------------

remote_wall_holds_position() ->
    {ok, Pid} = start_engine(),
    %% Set the remote wall (wall 1) to a non-default y; the AI loop runs
    %% every tick but must skip remote walls, leaving it untouched.
    mpong_game_engine:update_paddle(Pid, <<"remote">>, 250),
    timer:sleep(?FEW_TICKS_MS),
    #{paddles := Paddles} = info(Pid),
    ?assertEqual(250, maps:get(1, Paddles)),
    gen_server:stop(Pid).

suspend_resume() ->
    {ok, Pid} = start_engine(),
    mpong_game_engine:pause(Pid),
    Ball0 = ball(Pid),
    %% Wait well past the natural point-countdown: a non-suspended ball
    %% would be moving by now. A suspended one must not have moved.
    timer:sleep(?PAST_COUNTDOWN_MS),
    Ball1 = ball(Pid),
    ?assertEqual(Ball0, Ball1),
    %% Resume and confirm the ball starts moving again.
    mpong_game_engine:resume(Pid),
    timer:sleep(?FEW_TICKS_MS),
    Ball2 = ball(Pid),
    ?assertNotEqual(Ball1, Ball2),
    gen_server:stop(Pid).

%%--------------------------------------------------------------------

start_engine() ->
    GameId = list_to_binary("test-" ++ integer_to_list(erlang:unique_integer([positive]))),
    Config = #{
        game_id => GameId,
        players => #{<<"host">>   => #{wall_index => 0},
                     <<"remote">> => #{wall_index => 1}},
        player_modes => #{0 => {bot, #{}}, 1 => remote}
    },
    mpong_game_engine:start_link(Config).

info(Pid)  -> gen_server:call(Pid, get_game_info).
ball(Pid)  -> maps:get(ball, info(Pid)).
