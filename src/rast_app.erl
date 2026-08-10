%%% @private
-module(rast_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    rast_sup:start_link().

stop(_State) ->
    ok.
