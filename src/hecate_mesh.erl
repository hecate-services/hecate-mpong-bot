%%%-------------------------------------------------------------------
%%% @doc Thin service-local mesh publisher for hecate-mpong-bot.
%%%
%%% The daemon's `hecate_mesh' is a stateful gen_server facade with
%%% pool routing, DHT put_record, RPC and structured logging. A bot
%%% needs none of that — just publish a term on a topic over the
%%% service's macula client pool. So this is a ~deliberately tiny
%%% replacement exposing the same `publish/2' surface the extracted
%%% mpong slices already call (guarded by `function_exported/3').
%%%
%%% Wire rule: pass the term, NEVER pre-encode. macula encodes CBOR;
%%% a pre-encoded iolist crashes `macula_frame:to_wire'.
%%% @end
%%%-------------------------------------------------------------------
-module(hecate_mesh).

-export([publish/2]).

%% @doc Publish `Payload' (an Erlang term) on `Topic' over the bot's
%% realm-bound macula client pool. Degrades to `{error, _}' (never
%% crashes the caller) while the client/realm is not yet up.
-spec publish(binary(), term()) -> ok | {error, term()}.
publish(Topic, Payload) ->
    case {hecate_om:macula_client(), hecate_om_identity:realm()} of
        {{ok, Pool}, {ok, Realm}} ->
            catch macula:publish(Pool, Realm, Topic, Payload),
            ok;
        _DarkOrNoRealm ->
            {error, mesh_unavailable}
    end.
