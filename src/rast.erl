%%%-------------------------------------------------------------------
%%% @doc rast — SIMD raster tile processing for Erlang.
%%%
%%% Public façade. Two layers live behind it:
%%%
%%%   1. <b>Kernels</b> ({@link rast_nif}) — bounded, per-tile, binary-first
%%%      operations in Rust. Fused and typed: `u16' source data is widened to
%%%      `f32' inside the kernel, and compound indices such as NDVI are computed
%%%      in a single pass over the tile.
%%%   2. <b>Orchestration</b> (planned: `rast_coordinator' / `rast_worker' /
%%%      `rast_gdal') — bounded-memory, demand-driven tiling of a whole scene,
%%%      with GDAL doing the windowed I/O.
%%%
%%% Only layer 1 is implemented in this scaffold. Layer 2 functions return
%%% `{error, not_implemented}' and document the intended contract.
%%%
%%% All vectors/tiles crossing this boundary are <b>little-endian binaries</b>,
%%% never Erlang lists — that is the whole point at raster scale (a single
%%% Sentinel-2 band is ~120 M pixels).
%%% @end
%%%-------------------------------------------------------------------
-module(rast).

%% Metadata
-export([version/0]).

%% Kernels (tile-level)
-export([decode_u16/2, ndvi_u16/2, ndvi_f32/2, convolve_f32/6, pad_replicate_f32/7]).

%% Orchestration
-export([process_tiles/3, process_band/3, process_convolution/5]).

-type u16_bin()  :: binary().   %% little-endian uint16 samples
-type f32_bin()  :: binary().   %% little-endian IEEE-754 f32 samples
-type reason()   :: length_mismatch | odd_length | empty | not_implemented | term().

-export_type([u16_bin/0, f32_bin/0]).

-spec version() -> binary().
version() -> <<"0.1.0">>.

%%%===================================================================
%%% Kernels
%%%===================================================================

%% @doc Widen a `u16' tile to an `f32' tile, scaling each sample by `Scale'.
-spec decode_u16(u16_bin(), float()) -> {ok, f32_bin()} | {error, reason()}.
decode_u16(Data, Scale) when is_binary(Data), is_number(Scale) ->
    rast_nif:decode_u16_to_f32(Data, float(Scale)).

%% @doc NDVI of two `u16' tiles (NIR, Red) → `f32' tile, fused single pass.
-spec ndvi_u16(u16_bin(), u16_bin()) -> {ok, f32_bin()} | {error, reason()}.
ndvi_u16(Nir, Red) when is_binary(Nir), is_binary(Red) ->
    rast_nif:ndvi_u16(Nir, Red).

%% @doc NDVI of two `f32' tiles (NIR, Red) → `f32' tile, fused single pass.
-spec ndvi_f32(f32_bin(), f32_bin()) -> {ok, f32_bin()} | {error, reason()}.
ndvi_f32(Nir, Red) when is_binary(Nir), is_binary(Red) ->
    rast_nif:ndvi_f32(Nir, Red).

%% @doc Replicate-pad an `f32' tile by `Left'/`Top'/`Right'/`Bottom' rows/cols.
%% Output `(W+Left+Right) × (H+Top+Bottom)'.
-spec pad_replicate_f32(f32_bin(), pos_integer(), pos_integer(),
                        non_neg_integer(), non_neg_integer(),
                        non_neg_integer(), non_neg_integer()) ->
        {ok, f32_bin()} | {error, reason()}.
pad_replicate_f32(Src, W, H, L, T, R, B) when is_binary(Src) ->
    rast_nif:pad_replicate_f32(Src, W, H, L, T, R, B).

%% @doc Valid 2-D cross-correlation of an `f32' tile (`SrcW × SrcH') with a
%% `KW × KH' `f32' kernel. Output `(SrcW-KW+1) × (SrcH-KH+1)'.
-spec convolve_f32(f32_bin(), pos_integer(), pos_integer(),
                   f32_bin(), pos_integer(), pos_integer()) ->
        {ok, f32_bin()} | {error, reason()}.
convolve_f32(Src, SrcW, SrcH, Kernel, KW, KH) when is_binary(Src), is_binary(Kernel) ->
    rast_nif:convolve_f32(Src, SrcW, SrcH, Kernel, KW, KH).

%%%===================================================================
%%% Orchestration
%%%===================================================================

%% @doc Generic bounded-memory tiling engine.
%%
%% Drives a demand-driven worker pool over `Tiles': each worker pulls a tile,
%% `read's it, runs the `kernel', and `write's the result, repeating until the
%% tiles are exhausted. Peak memory is bounded by `Workers × tile_bytes' — no
%% more than one tile is resident per worker (ARCHITECTURE.md §5).
%%
%% This is the source-agnostic core: `Funs' injects the I/O so the same engine
%% serves an in-memory source (tests) or the GDAL bridge (production).
%%
%%   `Funs'  :: #{read := fun((Tile) -> {ok, binary()} | {error, term()}),
%%               kernel := fun((binary()) -> {ok, binary()} | {error, term()}),
%%               write := fun((Tile, binary()) -> ok | {error, term()})}
%%   `Opts'  :: #{workers => pos_integer()}   %% default: dirty CPU schedulers
-spec process_tiles(Tiles :: [term()], Funs :: rast_worker:funs(), Opts :: map()) ->
        {ok, #{tiles := non_neg_integer(), workers := pos_integer()}} | {error, term()}.
process_tiles(Tiles, Funs, Opts) when is_list(Tiles), is_map(Funs) ->
    W = maps:get(workers, Opts, max(1, erlang:system_info(dirty_cpu_schedulers))),
    {ok, Coord} = rast_coordinator:start_link(Tiles),
    try
        Mons = [element(2, spawn_monitor(rast_worker, run, [Coord, Funs]))
                || _ <- lists:seq(1, W)],
        case await_workers(Mons, ok) of
            ok              -> {ok, #{tiles => length(Tiles), workers => W}};
            {error, _} = E  -> E
        end
    after
        rast_coordinator:stop(Coord)
    end.

%% Wait for every worker monitor to fire; keep the first abnormal reason.
await_workers([], Acc) ->
    Acc;
await_workers([Ref | Rest], Acc) ->
    receive
        {'DOWN', Ref, process, _Pid, normal} ->
            await_workers(Rest, Acc);
        {'DOWN', Ref, process, _Pid, Reason} ->
            NewAcc = case Acc of ok -> {error, Reason}; _ -> Acc end,
            await_workers(Rest, NewAcc)
    end.

%% @doc Process a whole scene through GDAL, tile-by-tile, under a fixed memory
%% budget, writing a GeoTIFF result.
%%
%%   `Sources' :: [file:filename()]   %% 1 for {decode,_}, 2 (NIR, Red) for ndvi
%%   `Dst'     :: file:filename()     %% output GeoTIFF path
%%   `Opts'    :: #{op := ndvi | {decode, Scale :: float()},
%%                  tile => {W, H},       %% default {512, 512}
%%                  workers => pos_integer()}
%%
%% Reads windows via the GDAL bridge, runs the fused kernel per tile, and scatters
%% results into the output; peak memory stays bounded by `workers × tile_bytes'
%% (ARCHITECTURE.md §5). Requires GDAL — see {@link rast_gdal}.
-spec process_band(Sources :: [file:filename()], Dst :: file:filename(), Opts :: map()) ->
        {ok, file:filename()} | {error, reason()}.
process_band(Sources, Dst, Opts) when is_list(Sources), is_map(Opts) ->
    {TW, TH} = maps:get(tile, Opts, {512, 512}),
    Op = maps:get(op, Opts),
    case open_all(Sources, []) of
        {ok, Handles} ->
            [#{width := W, height := H, dtype := SrcDType} | _] = Handles,
            Tiles = rast_tiling:tile_grid(W, H, TW, TH),
            case rast_gdal:create_output(Dst, W, H, #{dtype => out_dtype(Op)}) of
                {ok, Out} ->
                    Kernel = kernel_fun(Op, SrcDType),
                    Funs = #{
                        read   => fun(T) -> read_all(Handles, T) end,
                        kernel => Kernel,
                        write  => fun(T, Bin) -> rast_gdal:write_window(Out, T, Bin) end
                    },
                    WOpts = maps:with([workers], Opts),
                    Res = process_tiles(Tiles, Funs, WOpts),
                    [rast_gdal:close(Hdl) || Hdl <- Handles],
                    case Res of
                        {ok, _} -> rast_gdal:finalize(Out);
                        Error   -> _ = rast_gdal:finalize(Out), Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

open_all([], Acc) ->
    {ok, lists:reverse(Acc)};
open_all([Src | Rest], Acc) ->
    case rast_gdal:open(Src) of
        {ok, H}        -> open_all(Rest, [H | Acc]);
        {error, _} = E -> E
    end.

out_dtype(ndvi)         -> <<"Float32">>;
out_dtype({decode, _})  -> <<"Float32">>.

kernel_fun(ndvi, <<"UInt16">>)  -> fun({N, R}) -> rast:ndvi_u16(N, R) end;
kernel_fun(ndvi, <<"Float32">>) -> fun({N, R}) -> rast:ndvi_f32(N, R) end;
kernel_fun({decode, Scale}, _)  -> fun(B) -> rast:decode_u16(B, Scale) end.

read_all([H], T) ->
    rast_gdal:read_window(H, T);
read_all([H1, H2], T) ->
    case {rast_gdal:read_window(H1, T), rast_gdal:read_window(H2, T)} of
        {{ok, A}, {ok, B}} -> {ok, {A, B}};
        {{error, _} = E, _} -> E;
        {_, {error, _} = E} -> E
    end.

%% @doc Convolve a whole scene with a `KW × KH' `f32' kernel, writing an `f32'
%% GeoTIFF. Each output tile reads a source window grown by the halo, so tiles
%% compose without seams (ARCHITECTURE.md §5).
%%
%%   `Src'    :: file:filename()          %% UInt16 or Float32 single band
%%   `Kernel' :: f32_bin()                %% KW*KH little-endian f32, row-major
%%   `Opts'   :: #{tile => {W,H}, workers => pos_integer(),
%%                 pad => clamp | valid}   %% default clamp
%%
%% `pad => clamp' (default): full-size `W × H' output; the apron at the scene
%% border is synthesized by edge replication. `pad => valid': no border
%% synthesis, output shrinks to `(W-KW+1) × (H-KH+1)'.
-spec process_convolution(Src :: file:filename(), Dst :: file:filename(),
                          Kernel :: f32_bin(), {pos_integer(), pos_integer()},
                          Opts :: map()) ->
        {ok, file:filename()} | {error, reason()}.
process_convolution(Src, Dst, Kernel, {KW, KH}, Opts)
        when is_binary(Kernel), KW > 0, KH > 0 ->
    {TW, TH} = maps:get(tile, Opts, {512, 512}),
    Mode = maps:get(pad, Opts, clamp),
    RX = KW div 2, RY = KH div 2,
    case rast_gdal:open(Src) of
        {ok, #{width := W, height := H, dtype := DType} = Handle} ->
            {OutW, OutH} = case Mode of
                               clamp -> {W, H};
                               valid -> {W - KW + 1, H - KH + 1}
                           end,
            case (OutW > 0) andalso (OutH > 0) of
                false ->
                    rast_gdal:close(Handle),
                    {error, {kernel_larger_than_raster, {KW, KH}, {W, H}}};
                true ->
                    case rast_gdal:create_output(Dst, OutW, OutH, #{dtype => <<"Float32">>}) of
                        {ok, Out} ->
                            Tiles = rast_tiling:tile_grid(OutW, OutH, TW, TH),
                            Funs = #{
                                read   => conv_read_fun(Handle, DType, RX, RY, W, H, Mode),
                                kernel => fun({F, GW, GH}) ->
                                              rast:convolve_f32(F, GW, GH, Kernel, KW, KH)
                                          end,
                                write  => fun(T, Bin) -> rast_gdal:write_window(Out, T, Bin) end
                            },
                            Res = process_tiles(Tiles, Funs, maps:with([workers], Opts)),
                            rast_gdal:close(Handle),
                            case Res of
                                {ok, _} -> rast_gdal:finalize(Out);
                                Error   -> _ = rast_gdal:finalize(Out), Error
                            end;
                        {error, _} = Error ->
                            rast_gdal:close(Handle),
                            Error
                    end
            end;
        {error, _} = Error ->
            Error
    end.

%% Grown-window read for one output tile. In `valid' mode the grown window is
%% read directly; in `clamp' mode it is clamped to the raster and the missing
%% apron is rebuilt by edge replication. Returns `{ok, {F32Grown, GW, GH}}'.
conv_read_fun(Handle, DType, RX, RY, _W, _H, valid) ->
    fun(#{x := OX, y := OY, w := TW, h := TH}) ->
        GW = TW + 2 * RX,
        GH = TH + 2 * RY,
        read_decode(Handle, DType, #{x => OX, y => OY, w => GW, h => GH}, GW, GH)
    end;
conv_read_fun(Handle, DType, RX, RY, W, H, clamp) ->
    fun(#{x := OX, y := OY, w := TW, h := TH}) ->
        GW = TW + 2 * RX, GH = TH + 2 * RY,
        GX0 = OX - RX, GY0 = OY - RY,
        GX1 = OX + TW + RX, GY1 = OY + TH + RY,   % exclusive ends
        RX0 = max(0, GX0), RY0 = max(0, GY0),
        RX1 = min(W, GX1), RY1 = min(H, GY1),
        ReadW = RX1 - RX0, ReadH = RY1 - RY0,
        L = RX0 - GX0, T = RY0 - GY0, R = GX1 - RX1, B = GY1 - RY1,
        case read_decode(Handle, DType, #{x => RX0, y => RY0, w => ReadW, h => ReadH}, ReadW, ReadH) of
            {ok, {F, ReadW, ReadH}} ->
                case rast:pad_replicate_f32(F, ReadW, ReadH, L, T, R, B) of
                    {ok, Padded}   -> {ok, {Padded, GW, GH}};
                    {error, _} = E -> E
                end;
            {error, _} = E ->
                E
        end
    end.

read_decode(Handle, DType, Window, GW, GH) ->
    case rast_gdal:read_window(Handle, Window) of
        {ok, Raw} ->
            case DType of
                <<"Float32">> -> {ok, {Raw, GW, GH}};
                _ ->
                    case rast:decode_u16(Raw, 1.0) of
                        {ok, F}        -> {ok, {F, GW, GH}};
                        {error, _} = E -> E
                    end
            end;
        {error, _} = E ->
            E
    end.
