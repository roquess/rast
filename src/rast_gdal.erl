%%%-------------------------------------------------------------------
%%% @doc rast_gdal — bridge to GDAL for windowed raster I/O.
%%%
%%% rast does not implement raster I/O, reprojection, COG, CRS or nodata
%%% semantics — GDAL owns all of that (ARCHITECTURE.md §8). This module is the
%%% seam. It is a **CLI port** driven via `open_port({spawn_executable, ...})'
%%% (no shell, so no Windows quoting hell): metadata via `gdalinfo -json',
%%% windowed reads via `gdal_translate -srcwin' into a headerless ENVI raw that
%%% Erlang reads back. (Per-tile subprocess spawn is the simple first cut; a
%%% persistent port or a dedicated NIF over the `gdal' crate is the later
%%% optimization.)
%%%
%%% Writes go the other way: GDAL cannot easily patch a sub-window into an
%%% existing raster from the CLI, so the output is owned by Erlang as a flat raw
%%% file — workers `pwrite' their tiles at the right offsets — and a single
%%% `gdal_translate' wraps the finished raw into a GeoTIFF at the end.
%%%
%%% GDAL location: `application:get_env(rast, gdal_bin_dir)', else `$GDAL_BIN_DIR',
%%% else the platform default (`C:/Program Files/GDAL' on Windows), else `PATH'.
%%% @end
%%%-------------------------------------------------------------------
-module(rast_gdal).

%% Discovery
-export([available/0]).
%% Read side
-export([open/1, info/1, read_window/2, read_window/3, close/1]).
%% Write side
-export([create_output/4, write_window/3, finalize/1]).

-type handle() :: #{source := string(), width := pos_integer(), height := pos_integer(),
                    bands := pos_integer(), dtype := binary()}.
-type window() :: rast_tiling:tile().
-type out()    :: #{path := string(), fd := file:io_device(),
                    width := pos_integer(), height := pos_integer(),
                    bpp := pos_integer(), dtype := binary()}.

-export_type([handle/0, out/0]).

-define(TIMEOUT, 120000).

%%%===================================================================
%%% Discovery
%%%===================================================================

%% @doc Whether the GDAL CLI can be located.
-spec available() -> boolean().
available() ->
    filelib:is_regular(exe("gdalinfo")).

%%%===================================================================
%%% Read side
%%%===================================================================

%% @doc Open a raster source and read its metadata via `gdalinfo -json'.
-spec open(Source :: string()) -> {ok, handle()} | {error, term()}.
open(Source) ->
    case run(exe("gdalinfo"), ["-json", Source]) of
        {ok, Json} ->
            try json:decode(Json) of
                Meta ->
                    [W, H] = maps:get(<<"size">>, Meta),
                    Bands  = maps:get(<<"bands">>, Meta, []),
                    DType  = case Bands of
                                 [B0 | _] -> maps:get(<<"type">>, B0, <<"UInt16">>);
                                 []       -> <<"UInt16">>
                             end,
                    {ok, #{source => Source, width => W, height => H,
                           bands => length(Bands), dtype => DType}}
            catch
                _:_ -> {error, {gdalinfo_parse, Source}}
            end;
        {error, Reason} ->
            {error, {gdalinfo_failed, Reason}}
    end.

%% @doc Metadata map for an open handle.
-spec info(handle()) -> {ok, map()} | {error, term()}.
info(Handle) when is_map(Handle) -> {ok, Handle}.

%% @doc Read band 1 of a window as a little-endian binary in the source dtype.
-spec read_window(handle(), window()) -> {ok, binary()} | {error, term()}.
read_window(Handle, Window) -> read_window(Handle, Window, 1).

%% @doc Read `Band' of a window as a little-endian binary in the source dtype.
%% For convolution, pass a window already grown by the halo width.
-spec read_window(handle(), window(), pos_integer()) -> {ok, binary()} | {error, term()}.
read_window(#{source := Src}, #{x := X, y := Y, w := W, h := H}, Band) ->
    Tmp = tmp(".img"),
    Args = ["-q", "-b", i(Band),
            "-srcwin", i(X), i(Y), i(W), i(H),
            "-of", "ENVI", Src, Tmp],
    Result = case run(exe("gdal_translate"), Args) of
                 {ok, _} ->
                     case file:read_file(Tmp) of
                         {ok, Bin}       -> {ok, Bin};
                         {error, Reason} -> {error, {read_window_failed, Reason}}
                     end;
                 {error, Reason} ->
                     {error, {read_window_failed, Reason}}
             end,
    cleanup(sidecars(Tmp)),
    Result.

%% @doc Release the handle (no-op for the CLI port).
-spec close(handle()) -> ok.
close(_Handle) -> ok.

%%%===================================================================
%%% Write side
%%%===================================================================

%% @doc Create a flat raw output sized `W × H', ready for windowed `pwrite's.
%% `DType' is the *output* dtype (e.g. `<<"Float32">>' for NDVI results).
-spec create_output(Path :: string(), pos_integer(), pos_integer(), map()) ->
        {ok, out()} | {error, term()}.
create_output(Path, W, H, #{dtype := DType}) when W > 0, H > 0 ->
    Bpp = bpp(DType),
    Raw = Path ++ ".raw",
    %% NOT `raw`: the fd is shared across worker processes doing concurrent
    %% pwrites to disjoint tile regions, so it must be a file-server fd (a pid),
    %% not a process-local raw fd.
    case file:open(Raw, [write, read, binary]) of
        {ok, Fd} ->
            ok = file:pwrite(Fd, W * H * Bpp - 1, <<0>>),   % preallocate
            {ok, #{path => Path, fd => Fd, width => W, height => H,
                   bpp => Bpp, dtype => DType}};
        {error, Reason} ->
            {error, {create_output_failed, Reason}}
    end.

%% @doc Scatter a tile result into the flat output: `TH' row-writes at the
%% tile's byte offsets in the full-width raster.
-spec write_window(out(), window(), binary()) -> ok | {error, term()}.
write_window(#{fd := Fd, width := W, bpp := Bpp}, #{x := X, y := Y, w := TW, h := TH}, Bin) ->
    RowBytes = TW * Bpp,
    Writes = [ {((Y + R) * W + X) * Bpp, binary:part(Bin, R * RowBytes, RowBytes)}
               || R <- lists:seq(0, TH - 1) ],
    file:pwrite(Fd, Writes).

%% @doc Close the raw file and wrap it into a GeoTIFF at `Path' via a single
%% `gdal_translate'. Writes a minimal ENVI header so GDAL can read the raw.
-spec finalize(out()) -> {ok, string()} | {error, term()}.
finalize(#{path := Path, fd := Fd, width := W, height := H, dtype := DType}) ->
    ok = file:close(Fd),
    Raw = Path ++ ".raw",
    Hdr = Path ++ ".hdr",
    ok = file:write_file(Hdr, envi_hdr(W, H, DType)),
    Result = case run(exe("gdal_translate"), ["-q", "-of", "GTiff", Raw, Path]) of
                 {ok, _} ->
                     case filelib:is_regular(Path) of
                         true  -> {ok, Path};
                         false -> {error, finalize_failed}
                     end;
                 {error, Reason} ->
                     {error, {finalize_failed, Reason}}
             end,
    cleanup([Raw, Hdr, Path ++ ".aux.xml"]),
    Result.

%%%===================================================================
%%% Subprocess execution (spawn_executable — no shell, no quoting)
%%%===================================================================

run(Exe, Args) ->
    try open_port({spawn_executable, Exe},
                  [{args, Args}, binary, exit_status, stderr_to_stdout, in]) of
        Port -> collect(Port, <<>>)
    catch
        error:Reason -> {error, {spawn_failed, Reason}}
    end.

collect(Port, Acc) ->
    receive
        {Port, {data, D}}          -> collect(Port, <<Acc/binary, D/binary>>);
        {Port, {exit_status, 0}}   -> {ok, Acc};
        {Port, {exit_status, N}}   -> {error, {exit_status, N, Acc}}
    after ?TIMEOUT ->
        catch port_close(Port),
        {error, timeout}
    end.

%%%===================================================================
%%% Internal
%%%===================================================================

%% GDAL "data type" codes for the ENVI header.
envi_dtype(<<"Byte">>)    -> 1;
envi_dtype(<<"UInt16">>)  -> 12;
envi_dtype(<<"Int16">>)   -> 2;
envi_dtype(<<"UInt32">>)  -> 13;
envi_dtype(<<"Int32">>)   -> 3;
envi_dtype(<<"Float32">>) -> 4;
envi_dtype(<<"Float64">>) -> 5.

bpp(<<"Byte">>)    -> 1;
bpp(<<"UInt16">>)  -> 2;
bpp(<<"Int16">>)   -> 2;
bpp(<<"UInt32">>)  -> 4;
bpp(<<"Int32">>)   -> 4;
bpp(<<"Float32">>) -> 4;
bpp(<<"Float64">>) -> 8.

envi_hdr(W, H, DType) ->
    iolist_to_binary(io_lib:format(
        "ENVI~n"
        "samples = ~w~n"
        "lines = ~w~n"
        "bands = 1~n"
        "header offset = 0~n"
        "file type = ENVI Standard~n"
        "data type = ~w~n"
        "interleave = bsq~n"
        "byte order = 0~n",
        [W, H, envi_dtype(DType)])).

%% Resolve a GDAL executable to a native path.
exe(Name) ->
    Full = Name ++ exe_ext(),
    case gdal_dir() of
        "" -> case os:find_executable(Full) of
                  false -> filename:nativename(Full);
                  Path  -> Path
              end;
        Dir -> filename:nativename(filename:join(Dir, Full))
    end.

gdal_dir() ->
    case application:get_env(rast, gdal_bin_dir) of
        {ok, D} -> D;
        undefined ->
            case os:getenv("GDAL_BIN_DIR") of
                false -> default_dir();
                D     -> D
            end
    end.

default_dir() ->
    case os:type() of
        {win32, _} -> "C:/Program Files/GDAL";
        _          -> ""
    end.

exe_ext() ->
    case os:type() of
        {win32, _} -> ".exe";
        _          -> ""
    end.

%% ENVI sidecar files that `gdal_translate -of ENVI' may produce.
sidecars(Img) ->
    [Img, Img ++ ".hdr", filename:rootname(Img) ++ ".hdr", Img ++ ".aux.xml"].

tmp(Ext) ->
    Name = lists:flatten(
             io_lib:format("rast_~p~s", [erlang:unique_integer([positive]), Ext])),
    filename:join(tmpdir(), Name).

tmpdir() ->
    case os:getenv("TMP") of
        false -> case os:getenv("TMPDIR") of false -> "."; D -> D end;
        D     -> D
    end.

cleanup(Paths) ->
    lists:foreach(fun(P) -> _ = file:delete(P) end, Paths).

i(N) -> integer_to_list(N).
