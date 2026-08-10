%%%-------------------------------------------------------------------
%%% @doc rast_coordinator — demand-driven, bounded-memory tile scheduler.
%%%
%%% Owns the tile list for one scene/band and hands out tiles to workers on
%%% demand. Workers <b>pull</b> ({@link next_tile/1}) when idle; the coordinator
%%% never pushes the whole grid into mailboxes (which would materialise the
%%% scene in RAM). With at most one tile resident per worker, peak memory is
%%% bounded by `Workers × tile_bytes' — the ceiling from ARCHITECTURE.md §5.
%%%
%%% Each tile is handed out exactly once; when the list is empty every puller
%%% gets `done'.
%%% @end
%%%-------------------------------------------------------------------
-module(rast_coordinator).
-behaviour(gen_server).

-export([start_link/1, next_tile/1, remaining/1, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    tiles     :: [term()],
    handed    :: non_neg_integer(),
    total     :: non_neg_integer()
}).

-spec start_link([term()]) -> {ok, pid()}.
start_link(Tiles) when is_list(Tiles) ->
    gen_server:start_link(?MODULE, Tiles, []).

%% @doc Claim the next tile, or `done' once the list is exhausted.
-spec next_tile(pid()) -> {ok, term()} | done.
next_tile(Pid) ->
    gen_server:call(Pid, next_tile, infinity).

%% @doc Number of tiles not yet handed out.
-spec remaining(pid()) -> non_neg_integer().
remaining(Pid) ->
    gen_server:call(Pid, remaining, infinity).

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:stop(Pid).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(Tiles) ->
    {ok, #state{tiles = Tiles, handed = 0, total = length(Tiles)}}.

handle_call(next_tile, _From, #state{tiles = [T | Rest], handed = H} = S) ->
    {reply, {ok, T}, S#state{tiles = Rest, handed = H + 1}};
handle_call(next_tile, _From, #state{tiles = []} = S) ->
    {reply, done, S};
handle_call(remaining, _From, #state{tiles = Tiles} = S) ->
    {reply, length(Tiles), S};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_request}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, _S) ->
    ok.
