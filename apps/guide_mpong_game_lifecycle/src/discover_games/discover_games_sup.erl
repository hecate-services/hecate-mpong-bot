%%%-------------------------------------------------------------------
%%% @doc Supervisor for the discover_games matchmaking coordinator.
%%%
%%% Conditionally started by guide_mpong_game_lifecycle_sup only when
%%% the demo is enabled (app env `{hecate_mpong_bot, mpong_auto_host}'
%%% or OS env `HECATE_MPONG_AUTO_HOST=true'). Replaces the retired
%%% auto_host_demo_loop (which self-hosted single-node games).
%%% @end
%%%-------------------------------------------------------------------
-module(discover_games_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 10, period => 10},
    Child = #{id => discover_games,
              start => {discover_games, start_link, []},
              restart => permanent,
              type => worker},
    {ok, {SupFlags, [Child]}}.
