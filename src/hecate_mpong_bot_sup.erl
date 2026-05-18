%%% @doc Service-level root supervisor.
%%%
%%% Owns service-wide infrastructure that doesn't fit inside a
%%% single umbrella app:
%%%   - Cowboy HTTP listener (serves /health from hecate_om, plus
%%%     any future per-slice admin/debug routes under /api/v1/*)
%%%   - hecate_mpong_bot_mesh_rpc: registers the RPC handlers that
%%%     back the capabilities advertised by
%%%     hecate_mpong_bot_service:capabilities/0 (scaffolded —
%%%     module lands when the first capability is wired)
%%%
%%% The umbrella apps under `apps/' (run_game_engine,
%%% advertise_game, broadcast_game_state, auto_host_demo_loop, …)
%%% start themselves via their entries in
%%% hecate_mpong_bot.app.src.
-module(hecate_mpong_bot_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy  => one_for_one,
        intensity => 10,
        period    => 10
    },
    Children = [
        cowboy_child()
        %% Mesh RPC dispatcher — uncomment when the module lands:
        %% #{
        %%     id       => hecate_mpong_bot_mesh_rpc,
        %%     start    => {hecate_mpong_bot_mesh_rpc, start_link, []},
        %%     restart  => permanent,
        %%     shutdown => 5000,
        %%     type     => worker,
        %%     modules  => [hecate_mpong_bot_mesh_rpc]
        %% }
    ],
    {ok, {SupFlags, Children}}.

%%% Internal

cowboy_child() ->
    Port = application:get_env(hecate_mpong_bot, http_port, 8470),
    Dispatch = cowboy_router:compile(routes()),
    #{
        id       => cowboy_listener,
        start    => {cowboy, start_clear, [
            hecate_mpong_bot_http_listener,
            [{port, Port}],
            #{env => #{dispatch => Dispatch}}
        ]},
        restart  => permanent,
        shutdown => 5000,
        type     => worker,
        modules  => [cowboy]
    }.

routes() ->
    HealthRoutes = hecate_om_health_handler:routes(),
    [{'_', HealthRoutes}].
