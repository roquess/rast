%%% @private
%%% @doc Top-level supervisor.
%%%
%%% Empty for now: kernels are called directly and need no owning process.
%%% Once the tiling orchestration lands, a per-scene supervisor
%%% (rast_coordinator + a rast_worker pool) is started dynamically under a
%%% simple_one_for_one child here, one subtree per scene/job.
-module(rast_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 10, period => 10},
    {ok, {SupFlags, []}}.
