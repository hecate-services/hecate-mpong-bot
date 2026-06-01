%%%-------------------------------------------------------------------
%%% @doc Central mesh-topic builder for hecate-mpong-bot.
%%%
%%% A thin service-local copy of the daemon's `hecate_topics' (the
%%% generic 5-segment macula_topic builder), kept so the extracted
%%% mpong slices publish to the BYTE-IDENTICAL topics the daemon used
%%% and the macula-realm `/demo/mpong' spectator already subscribes to:
%%%
%%%   io.macula/beam-campus/hecate/mpong/game_advertised_v1
%%%   io.macula/beam-campus/hecate/mpong/state_broadcast_v1
%%%
%%% The `app' segment stays `hecate' (NOT the bot name) on purpose —
%%% that is the existing wire contract. Do not change `?ORG'/`?APP'
%%% without coordinated changes in macula-realm's Mpong sink.
%%% @end
%%%-------------------------------------------------------------------
-module(hecate_topics).

-export([app_fact/3, app_hope/3, realm/0, org/0, app/0]).

-define(ORG, <<"beam-campus">>).
-define(APP, <<"hecate">>).

-spec app_fact(binary(), binary(), pos_integer()) -> binary().
app_fact(Domain, Name, Version) ->
    macula_topic:app_fact(realm(), ?ORG, ?APP, Domain, Name, Version).

-spec app_hope(binary(), binary(), pos_integer()) -> binary().
app_hope(Domain, Name, Version) ->
    macula_topic:app_hope(realm(), ?ORG, ?APP, Domain, Name, Version).

-spec realm() -> binary().
realm() ->
    application:get_env(hecate_mpong_bot, realm, <<"io.macula">>).

-spec org() -> binary().
org() -> ?ORG.

-spec app() -> binary().
app() -> ?APP.
