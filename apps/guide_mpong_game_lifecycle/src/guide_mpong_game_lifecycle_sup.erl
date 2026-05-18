%%%-------------------------------------------------------------------
%%% @doc Top-level supervisor for MPong game lifecycle in the
%%% hecate-mpong-bot service.
%%%
%%% Slimmed-down vs the original in hecate-daemon — today this only
%%% supervises `auto_host_demo_loop_sup' (when enabled). The
%%% `run_game_engine_sup', `listen_game_state_sup', and
%%% `mpong_lobby_seeker' children from the daemon's version come
%%% back as their slices land. Until then, `auto_host_demo_loop'
%%% will start successfully but its `host_one_match' will crash
%%% with `undef' on `run_game_engine_sup:start_engine/1' — the bot
%%% logs the failure and ticks again.
%%%
%%% Auto-host is enabled via the `{hecate_mpong_bot, mpong_auto_host}'
%%% app env or the OS env `HECATE_MPONG_AUTO_HOST=true'. The OS env
%%% name is held over from the daemon for operator continuity.
%%% @end
%%%-------------------------------------------------------------------
-module(guide_mpong_game_lifecycle_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 10, period => 10},
    Children = auto_host_demo_loop_children(),
    {ok, {SupFlags, Children}}.

auto_host_demo_loop_children() ->
    case auto_host_enabled() of
        true ->
            [#{id => auto_host_demo_loop_sup,
               start => {auto_host_demo_loop_sup, start_link, []},
               restart => permanent,
               type => supervisor}];
        _ ->
            []
    end.

auto_host_enabled() ->
    case application:get_env(hecate_mpong_bot, mpong_auto_host, undefined) of
        true -> true;
        false -> false;
        _ -> os_env_true("HECATE_MPONG_AUTO_HOST")
    end.

os_env_true(Var) ->
    case os:getenv(Var) of
        "true"  -> true;
        "1"     -> true;
        "yes"   -> true;
        "TRUE"  -> true;
        _       -> false
    end.
