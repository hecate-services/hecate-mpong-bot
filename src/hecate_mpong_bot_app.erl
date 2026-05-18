%%% @doc hecate-mpong-bot OTP application entry.
%%%
%%% Hands off to hecate_om:boot/1 with this service's callback
%%% module; om handles capability advertise + identity load + the
%%% /health Cowboy listener on port 8470. Our own sup
%%% (hecate_mpong_bot_sup) is started from
%%% hecate_mpong_bot_service:start/1.
-module(hecate_mpong_bot_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    hecate_om:boot(hecate_mpong_bot_service).

stop(_State) ->
    ok.
