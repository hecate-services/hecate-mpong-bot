%%%-------------------------------------------------------------------
%%% @doc Top-level supervisor for MPong game lifecycle.
%%% @end
%%%-------------------------------------------------------------------
-module(guide_mpong_game_lifecycle_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 10, period => 10},
    %% Phase 1 (self-hosting bot): the engine sup + the auto-host loop.
    %% listen_game_state_sup + mpong_lobby_seeker (the federated-join /
    %% seat-negotiation path) are deferred to Phase 2.
    Base = [
        #{id => run_game_engine_sup,
          start => {run_game_engine_sup, start_link, []},
          restart => permanent,
          type => supervisor}
    ],
    Children = Base ++ discover_games_children(),
    {ok, {SupFlags, Children}}.

%% Only run the matchmaking coordinator when explicitly enabled via
%% application env (`{hecate_mpong_bot, mpong_auto_host}') OR the OS env
%% `HECATE_MPONG_AUTO_HOST=true' (set per node on beam-cluster boxes
%% designated for the demo). Default off — user-installed daemons must
%% never spam mpong matches. Replaces the retired self-hosting
%% auto_host_demo_loop with the pong-over-mesh discover_games coordinator.
discover_games_children() ->
    case auto_host_enabled() of
        true ->
            [#{id => discover_games_sup,
               start => {discover_games_sup, start_link, []},
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
