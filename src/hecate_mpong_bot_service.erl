%%% @doc hecate-mpong-bot — implements the hecate_om_service behaviour.
%%%
%%% Lifecycle, health, capabilities, identity. The actual supervisory
%%% root lives in hecate_mpong_bot_sup; per-slice OTP apps boot
%%% independently via the `applications' list in
%%% hecate_mpong_bot.app.src once they're extracted from
%%% hecate-daemon.
-module(hecate_mpong_bot_service).
-behaviour(hecate_om_service).

-export([info/0, start/1, stop/1, health/0, capabilities/0, identity_spec/0]).

info() ->
    #{
        name        => <<"hecate-mpong-bot">>,
        version     => <<"0.1.0">>,
        description => <<"Realm-bound autonomous Pong-over-mesh bot. "
                         "One container per bot identity.">>
    }.

start(_Opts) ->
    hecate_mpong_bot_sup:start_link().

stop(_State) ->
    ok.

%% @doc Composite health check.
%%
%% Today: scaffolded `ok'. Real probe lands as the slices wire up.
%% Future check chain:
%%   - run_game_engine_sup alive (when present)
%%   - macula client pool has healthy_links > 0
%%   - if currently hosting: state-broadcast emitter is alive
%%   - if currently joining: lobby_seeker subscription is alive
health() ->
    ok.

%% @doc Advertised onto the mesh bloom-channel by hecate_om_capabilities.
%%
%% Mpong is mostly pubsub-driven (state_broadcast, seat_requested,
%% paddle_moved are all topics, not RPC). The RPCs we DO advertise
%% are the operator-facing surface — "is there a bot willing to fill
%% a seat for me?", "what's this bot currently doing?", "host a game
%% on demand", "withdraw from your current game". Hosts can call
%% `fill_seat' to recruit an opponent across the mesh instead of
%% relying on whoever happens to be polling the lobby.
capabilities() ->
    [
        #{name => <<"hecate-mpong-bot.fill_seat">>,         version => 1},
        #{name => <<"hecate-mpong-bot.list_active_games">>, version => 1},
        #{name => <<"hecate-mpong-bot.host_game">>,         version => 1},
        #{name => <<"hecate-mpong-bot.withdraw">>,          version => 1}
    ].

%% @doc Realm-issued service-principal scope. hecate-realm mints a
%% credential matching this at provision time.
identity_spec() ->
    #{
        scope     => <<"hecate-mpong-bot">>,
        actions   => [
            <<"host_game">>,
            <<"join_game">>,
            <<"publish_game_advertise">>,
            <<"publish_state_broadcast">>,
            <<"publish_paddle_input">>,
            <<"publish_seat_response">>,
            <<"advertise_capability">>
        ],
        resources => [
            <<"mpong/*">>
        ],
        ttl_days  => 365
    }.
