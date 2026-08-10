%%%-------------------------------------------------------------------
%%% @doc rast_worker — one tile-processing loop.
%%%
%%% A worker pulls a tile from the coordinator, reads it, runs the kernel, writes
%%% the result, and repeats until the coordinator reports `done'. Because tiles
%%% are refc-binaries, handing them between processes is by-reference and cheap.
%%%
%%% The pipeline is injected as three funs so the same loop drives an in-memory
%%% source (tests, benches) or the GDAL bridge (production) unchanged:
%%%
%%%   `read'   :: fun((Tile)          -> {ok, binary()} | {error, term()})
%%%   `kernel' :: fun((binary())      -> {ok, binary()} | {error, term()})
%%%   `write'  :: fun((Tile, binary()) -> ok | {error, term()})
%%% @end
%%%-------------------------------------------------------------------
-module(rast_worker).

-export([start_link/2, run/2]).

-type funs() :: #{read := fun((term()) -> {ok, binary()} | {error, term()}),
                  kernel := fun((binary()) -> {ok, binary()} | {error, term()}),
                  write := fun((term(), binary()) -> ok | {error, term()})}.

-export_type([funs/0]).

%% @doc Spawn a linked worker that drains the coordinator, then exits `normal'
%% (or with `{worker_error, Reason}' on the first failing tile).
-spec start_link(pid(), funs()) -> {ok, pid()}.
start_link(Coordinator, Funs) when is_pid(Coordinator), is_map(Funs) ->
    Pid = spawn_link(?MODULE, run, [Coordinator, Funs]),
    {ok, Pid}.

%% @private
-spec run(pid(), funs()) -> ok.
run(Coordinator, Funs) ->
    case rast_coordinator:next_tile(Coordinator) of
        done ->
            ok;
        {ok, Tile} ->
            ok = process_one(Tile, Funs),
            run(Coordinator, Funs)
    end.

process_one(Tile, #{read := Read, kernel := Kernel, write := Write}) ->
    case Read(Tile) of
        {ok, In} ->
            case Kernel(In) of
                {ok, Out} ->
                    case Write(Tile, Out) of
                        ok              -> ok;
                        {error, Reason} -> exit({worker_error, {write, Reason}})
                    end;
                {error, Reason} ->
                    exit({worker_error, {kernel, Reason}})
            end;
        {error, Reason} ->
            exit({worker_error, {read, Reason}})
    end.
