%%%-------------------------------------------------------------------
%%% @doc Thin service-local mesh surface for hecate-mpong-bot.
%%%
%%% The daemon's `hecate_mesh' is a stateful gen_server facade with
%%% pool routing, DHT put_record, RPC and structured logging. A bot
%%% needs none of that — just publish/subscribe a term on a topic over
%%% the service's macula client pool. So this is a ~deliberately tiny
%%% replacement exposing the surface the mpong slices call.
%%%
%%% == Publish ==
%%% `publish/2' is fire-and-forget: it returns `ok' even if the client
%%% is mid-churn, `{error, mesh_unavailable}' while dark.
%%%
%%% == Subscribe ==
%%% `subscribe/2' takes a topic and EITHER:
%%%
%%%   * a pid — the SDK delivers `{macula_event, SubRef, Topic, Payload,
%%%     Meta}' to that process per event (and `{macula_event_gone,
%%%     SubRef, Reason}' if the subscription dies). Idiomatic for
%%%     gen_servers: match in `handle_info/2', filter `game_id' in the
%%%     payload with a function-head clause, drop the rest.
%%%
%%%   * a 1-arity fun — invoked as `Fun(Payload)' per event (the SDK
%%%     spawns its own receiver; a crashing fun does not kill it).
%%%
%%% Both return `{ok, SubRef}' | `{error, mesh_unavailable}'. Drop a
%%% subscription with `unsubscribe/1' (idempotent).
%%%
%%% == Re-subscribe on pool churn ==
%%% `hecate_om' monitors and re-attaches the client pool on disconnect.
%%% A pid subscriber observes this as `{macula_event_gone, SubRef, _}'
%%% (or its monitored pool dying); each subscribing slice is responsible
%%% for re-subscribing against the fresh pool — there is no central
%%% subscription manager (vertical-slice ownership). The retry mirrors
%%% `hecate_om_identity''s deferred-connect pattern.
%%%
%%% Wire rule: pass the term, NEVER pre-encode. macula encodes CBOR;
%%% a pre-encoded iolist crashes `macula_frame:to_wire'.
%%% @end
%%%-------------------------------------------------------------------
-module(hecate_mesh).

-export([publish/2, subscribe/2, unsubscribe/1]).

%% @doc Publish `Payload' (an Erlang term) on `Topic' over the bot's
%% realm-bound macula client pool. Fire-and-forget. Degrades to
%% `{error, mesh_unavailable}' (never crashes the caller) while dark.
-spec publish(binary(), term()) -> ok | {error, mesh_unavailable}.
publish(Topic, Payload) ->
    with_mesh(fun(Pool, Realm) ->
        catch macula:publish(Pool, Realm, Topic, Payload),
        ok
    end).

%% @doc Subscribe to `Topic'. `Subscriber' is either a pid (mailbox
%% delivery of `{macula_event, SubRef, Topic, Payload, Meta}') or a
%% 1-arity fun invoked as `Fun(Payload)' per event. Returns
%% `{ok, SubRef}' | `{error, mesh_unavailable}'.
-spec subscribe(binary(), pid() | fun((term()) -> term())) ->
    {ok, reference()} | {error, term()}.
subscribe(Topic, Subscriber) when is_pid(Subscriber) ->
    with_mesh(fun(Pool, Realm) ->
        macula:subscribe(Pool, Realm, Topic, Subscriber)
    end);
subscribe(Topic, Callback) when is_function(Callback, 1) ->
    with_mesh(fun(Pool, Realm) ->
        macula:subscribe_callback(Pool, Realm, Topic,
            fun(_Topic, Payload, _Meta) -> Callback(Payload) end)
    end).

%% @doc Drop a subscription by its `SubRef'. Idempotent — a dead pool
%% (already torn the subscription down) or unknown ref is a no-op.
-spec unsubscribe(reference()) -> ok.
unsubscribe(SubRef) when is_reference(SubRef) ->
    case hecate_om:macula_client() of
        {ok, Pool} -> macula:unsubscribe(Pool, SubRef);
        _          -> ok
    end.

%% Run `F(Pool, Realm)' when both the client pool and the realm tag are
%% available; otherwise the mesh is dark. No defensive wrap around the
%% gen_server calls: at runtime `hecate_om_identity' is always
%% supervised-up and returns `{ok, _}' | `{error, no_client}'.
with_mesh(F) ->
    case {hecate_om:macula_client(), hecate_om_identity:realm()} of
        {{ok, Pool}, {ok, Realm}} -> F(Pool, Realm);
        _DarkOrNoRealm            -> {error, mesh_unavailable}
    end.
