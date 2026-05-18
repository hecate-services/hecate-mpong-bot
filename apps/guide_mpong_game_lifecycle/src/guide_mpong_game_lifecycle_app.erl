%%%-------------------------------------------------------------------
%%% @doc guide_mpong_game_lifecycle application behaviour.
%%%
%%% In hecate-daemon this also spun up an `ensure_champion'
%%% background process that re-dispatches `register_champion'
%%% until the `mpong_champions' projection table sees the row.
%%% That depends on the `register_champion' + reckon_evoq stack
%%% which hasn't been extracted yet — held back until the
%%% mpong_game_aggregate / reckon_db / evoq slice moves over.
%%% @end
%%%-------------------------------------------------------------------
-module(guide_mpong_game_lifecycle_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    guide_mpong_game_lifecycle_sup:start_link().

stop(_State) ->
    ok.
