-module(rast_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct.hrl").

%% Epsilon for f32 comparisons.
-define(EPS, 1.0e-5).

all() ->
    [
        %% Pure — always run, no native build required.
        version_is_binary,
        tile_count_exact,
        tile_count_remainder,
        tile_grid_full_coverage,
        tile_grid_edge_clipping,
        tile_grid_count_matches,
        %% Native kernels — skipped if the NIF is not built (run `make build`).
        decode_u16_roundtrip,
        decode_u16_scaled,
        decode_u16_odd_length,
        ndvi_u16_basic,
        ndvi_u16_zero_denominator,
        ndvi_u16_length_mismatch,
        ndvi_f32_basic,
        convolve_identity,
        convolve_box_blur,
        convolve_bad_dims,
        pad_replicate_basic,
        %% Orchestration — pure scheduling (no NIF) + one kernel-backed run.
        process_tiles_each_once,
        process_tiles_single_worker,
        process_tiles_error_propagates,
        process_tiles_with_kernel,
        %% GDAL bridge — skipped if GDAL is not installed.
        gdal_read_window,
        gdal_write_roundtrip,
        process_band_ndvi,
        process_convolution_identity,
        process_convolution_valid
    ].

init_per_suite(Config) ->
    %% Probe whether the native NIF is loaded; gate kernel tests on it.
    NifLoaded =
        try rast_nif:decode_u16_to_f32(<<1, 0>>, 1.0) of
            {ok, _} -> true;
            _       -> false
        catch
            error:_ -> false
        end,
    [{nif_loaded, NifLoaded}, {gdal, rast_gdal:available()} | Config].

end_per_suite(_Config) ->
    ok.

%%%===================================================================
%%% Pure: metadata + tiling geometry
%%%===================================================================

version_is_binary(_Cfg) ->
    V = rast:version(),
    true = is_binary(V),
    <<"0.1.0">> = V.

tile_count_exact(_Cfg) ->
    4 = rast_tiling:tile_count(1024, 1024, 512, 512).

tile_count_remainder(_Cfg) ->
    %% 1000/256 -> 4 columns, 1000/256 -> 4 rows.
    16 = rast_tiling:tile_count(1000, 1000, 256, 256).

tile_grid_full_coverage(_Cfg) ->
    W = 1000, H = 700,
    Tiles = rast_tiling:tile_grid(W, H, 256, 256),
    %% Every pixel covered exactly once => sum of tile areas == W*H.
    Area = lists:sum([Tw * Th || #{w := Tw, h := Th} <- Tiles]),
    Area = W * H.

tile_grid_edge_clipping(_Cfg) ->
    Tiles = rast_tiling:tile_grid(1000, 1000, 256, 256),
    %% Bottom-right tile must be clipped: 1000 - 768 = 232.
    #{w := 232, h := 232} = lists:last(Tiles).

tile_grid_count_matches(_Cfg) ->
    W = 1000, H = 700, Tw = 256, Th = 256,
    Tiles = rast_tiling:tile_grid(W, H, Tw, Th),
    Count = rast_tiling:tile_count(W, H, Tw, Th),
    Count = length(Tiles).

%%%===================================================================
%%% Native kernels
%%%===================================================================

decode_u16_roundtrip(Cfg) ->
    need_nif(Cfg),
    Data = u16_bin([0, 1, 2, 65535]),
    {ok, Out} = rast:decode_u16(Data, 1.0),
    assert_f32_close([0.0, 1.0, 2.0, 65535.0], Out).

decode_u16_scaled(Cfg) ->
    need_nif(Cfg),
    Data = u16_bin([1, 2, 10]),
    {ok, Out} = rast:decode_u16(Data, 0.5),
    assert_f32_close([0.5, 1.0, 5.0], Out).

decode_u16_odd_length(Cfg) ->
    need_nif(Cfg),
    {error, odd_length} = rast:decode_u16(<<1, 0, 2>>, 1.0).

ndvi_u16_basic(Cfg) ->
    need_nif(Cfg),
    Nir = u16_bin([200, 50]),
    Red = u16_bin([100, 50]),
    {ok, Out} = rast:ndvi_u16(Nir, Red),
    %% (200-100)/300 = 0.3333..., (50-50)/100 = 0.0
    assert_f32_close([100.0 / 300.0, 0.0], Out).

ndvi_u16_zero_denominator(Cfg) ->
    need_nif(Cfg),
    Nir = u16_bin([0, 5]),
    Red = u16_bin([0, 5]),
    {ok, Out} = rast:ndvi_u16(Nir, Red),
    assert_f32_close([0.0, 0.0], Out).

ndvi_u16_length_mismatch(Cfg) ->
    need_nif(Cfg),
    {error, length_mismatch} = rast:ndvi_u16(u16_bin([1, 2]), u16_bin([1])).

ndvi_f32_basic(Cfg) ->
    need_nif(Cfg),
    Nir = f32_bin([0.8, 0.2]),
    Red = f32_bin([0.2, 0.2]),
    {ok, Out} = rast:ndvi_f32(Nir, Red),
    %% (0.8-0.2)/1.0 = 0.6, (0.2-0.2)/0.4 = 0.0
    assert_f32_close([0.6, 0.0], Out).

%%%===================================================================
%%% Convolution
%%%===================================================================

%% Identity 3x3 kernel: valid output = interior of the source.
convolve_identity(Cfg) ->
    need_nif(Cfg),
    %% 4x4 source, value(col,row) = row*4 + col
    Src = f32_bin([float(R*4 + C) || R <- lists:seq(0,3), C <- lists:seq(0,3)]),
    Id  = f32_bin([0.0,0.0,0.0, 0.0,1.0,0.0, 0.0,0.0,0.0]),
    {ok, Out} = rast:convolve_f32(Src, 4, 4, Id, 3, 3),
    %% 2x2 output = source[(1,1),(1,2),(2,1),(2,2)] = [5,6,9,10]
    [5.0, 6.0, 9.0, 10.0] = f32_list(Out).

%% 3x3 box blur of a 3x3 tile = single-pixel average.
convolve_box_blur(Cfg) ->
    need_nif(Cfg),
    Src = f32_bin([float(V) || V <- lists:seq(1, 9)]),   % 1..9, avg = 5.0
    Box = f32_bin([1.0/9.0 || _ <- lists:seq(1, 9)]),
    {ok, Out} = rast:convolve_f32(Src, 3, 3, Box, 3, 3),
    [V] = f32_list(Out),
    true = (abs(V - 5.0) < ?EPS).

convolve_bad_dims(Cfg) ->
    need_nif(Cfg),
    %% kernel larger than source
    {error, bad_dims} = rast:convolve_f32(f32_bin([1.0]), 1, 1, f32_bin([1.0,1.0,1.0,1.0]), 2, 2).

pad_replicate_basic(Cfg) ->
    need_nif(Cfg),
    %% 2x2 [1,2 / 3,4], pad left=1 top=1 -> 3x3
    Src = f32_bin([1.0,2.0, 3.0,4.0]),
    {ok, Out} = rast:pad_replicate_f32(Src, 2, 2, 1, 1, 0, 0),
    [1.0,1.0,2.0, 1.0,1.0,2.0, 3.0,3.0,4.0] = f32_list(Out).

%%%===================================================================
%%% Orchestration (rast:process_tiles/3)
%%%===================================================================

%% Every tile is read/processed/written exactly once under concurrency.
process_tiles_each_once(_Cfg) ->
    T = ets:new(seen, [public, set]),
    Tiles = lists:seq(1, 500),
    Funs = #{
        read   => fun(Id) -> {ok, <<Id:32>>} end,
        kernel => fun(Bin) -> {ok, Bin} end,           % identity, no NIF
        write  => fun(Id, <<Got:32>>) ->
                      Id = Got,                         % payload round-trips
                      ets:update_counter(T, Id, {2, 1}, {Id, 0}),
                      ok
                  end
    },
    {ok, #{tiles := 500, workers := W}} = rast:process_tiles(Tiles, Funs, #{workers => 8}),
    true = (W =:= 8),
    %% Exactly one write per tile, all tiles present.
    500 = ets:info(T, size),
    Counts = [C || {_Id, C} <- ets:tab2list(T)],
    500 = length(Counts),
    true = lists:all(fun(C) -> C =:= 1 end, Counts),
    ets:delete(T).

process_tiles_single_worker(_Cfg) ->
    T = ets:new(seen, [public, set]),
    Tiles = lists:seq(1, 50),
    Funs = #{
        read   => fun(Id) -> {ok, <<Id:32>>} end,
        kernel => fun(Bin) -> {ok, Bin} end,
        write  => fun(Id, _Out) -> ets:insert(T, {Id}), ok end
    },
    {ok, #{tiles := 50, workers := 1}} = rast:process_tiles(Tiles, Funs, #{workers => 1}),
    50 = ets:info(T, size),
    ets:delete(T).

process_tiles_error_propagates(_Cfg) ->
    Tiles = lists:seq(1, 20),
    Funs = #{
        read   => fun(Id) -> {ok, <<Id:32>>} end,
        kernel => fun(<<Id:32>>) when Id =:= 7 -> {error, boom};
                     (Bin) -> {ok, Bin}
                  end,
        write  => fun(_Id, _Out) -> ok end
    },
    {error, {worker_error, {kernel, boom}}} =
        rast:process_tiles(Tiles, Funs, #{workers => 4}).

%% Full pipeline shape with a real kernel: NDVI over synthetic u16 tiles.
process_tiles_with_kernel(Cfg) ->
    need_nif(Cfg),
    T = ets:new(results, [public, set]),
    Px = 256,
    Tiles = lists:seq(1, 16),
    Funs = #{
        read   => fun(Id) ->
                      Nir = u16_bin([Id * 100 || _ <- lists:seq(1, Px)]),
                      Red = u16_bin([Id * 50  || _ <- lists:seq(1, Px)]),
                      {ok, {Nir, Red}}
                  end,
        kernel => fun({Nir, Red}) -> rast:ndvi_u16(Nir, Red) end,
        write  => fun(Id, Out) -> ets:insert(T, {Id, Out}), ok end
    },
    {ok, #{tiles := 16}} = rast:process_tiles(Tiles, Funs, #{workers => 4}),
    16 = ets:info(T, size),
    %% NDVI of (100k, 50k) = (100-50)/(150) = 1/3 for every pixel of every tile.
    [{_, OutBin} | _] = ets:tab2list(T),
    [V | _] = f32_list(OutBin),
    true = (abs(V - (1.0 / 3.0)) < ?EPS),
    ets:delete(T).

%%%===================================================================
%%% GDAL bridge (rast_gdal / rast:process_band)
%%%===================================================================

gdal_read_window(Cfg) ->
    need_gdal(Cfg),
    Src = mk_u16_envi(?config(priv_dir, Cfg), "src", 8, 8,
                      fun(C, R) -> R * 100 + C end),
    {ok, H} = rast_gdal:open(Src),
    #{width := 8, height := 8, dtype := <<"UInt16">>} = H,
    {ok, Bin} = rast_gdal:read_window(H, #{x => 2, y => 2, w => 3, h => 3}),
    [202,203,204, 302,303,304, 402,403,404] = u16_list(Bin).

gdal_write_roundtrip(Cfg) ->
    need_gdal(Cfg),
    Dir = ?config(priv_dir, Cfg),
    Out = filename:join(Dir, "wr.tif"),
    {ok, O} = rast_gdal:create_output(Out, 8, 8, #{dtype => <<"Float32">>}),
    ok = rast_gdal:write_window(O, #{x=>0, y=>0, w=>4, h=>4}, f32_bin(dup(1.0, 16))),
    ok = rast_gdal:write_window(O, #{x=>4, y=>0, w=>4, h=>4}, f32_bin(dup(3.0, 16))),
    ok = rast_gdal:write_window(O, #{x=>0, y=>4, w=>8, h=>4}, f32_bin(dup(2.0, 32))),
    {ok, Out} = rast_gdal:finalize(O),
    {ok, Ho} = rast_gdal:open(Out),
    #{dtype := <<"Float32">>, width := 8, height := 8} = Ho,
    {ok, TL} = rast_gdal:read_window(Ho, #{x=>0, y=>0, w=>2, h=>2}),
    {ok, TR} = rast_gdal:read_window(Ho, #{x=>6, y=>0, w=>2, h=>2}),
    {ok, BL} = rast_gdal:read_window(Ho, #{x=>0, y=>6, w=>2, h=>2}),
    [1.0,1.0,1.0,1.0] = f32_list(TL),
    [3.0,3.0,3.0,3.0] = f32_list(TR),
    [2.0,2.0,2.0,2.0] = f32_list(BL).

process_band_ndvi(Cfg) ->
    need_gdal(Cfg),
    Dir = ?config(priv_dir, Cfg),
    Nir = mk_u16_envi(Dir, "nir", 20, 20, fun(_, _) -> 200 end),
    Red = mk_u16_envi(Dir, "red", 20, 20, fun(_, _) -> 100 end),
    Dst = filename:join(Dir, "ndvi.tif"),
    {ok, Dst} = rast:process_band([Nir, Red], Dst,
                                  #{op => ndvi, tile => {8, 8}, workers => 4}),
    {ok, Ho} = rast_gdal:open(Dst),
    #{dtype := <<"Float32">>, width := 20, height := 20} = Ho,
    %% NDVI of (200, 100) = 100/300 = 1/3 everywhere; check a few windows.
    {ok, A} = rast_gdal:read_window(Ho, #{x=>0,  y=>0,  w=>4, h=>4}),
    {ok, B} = rast_gdal:read_window(Ho, #{x=>16, y=>16, w=>4, h=>4}),   % edge tile
    Third = 1.0 / 3.0,
    true = lists:all(fun(V) -> abs(V - Third) < ?EPS end, f32_list(A) ++ f32_list(B)).

%% End-to-end convolution, default `clamp' padding => full-size output.
%% Identity 3x3 with edge replication reproduces the source exactly, including
%% the border pixels a valid convolution would drop. Tiles smaller than the
%% raster exercise halo composition and border padding.
process_convolution_identity(Cfg) ->
    need_gdal(Cfg),
    Dir = ?config(priv_dir, Cfg),
    %% 12x12 source, value(col,row) = row*100 + col
    Src = mk_u16_envi(Dir, "conv_src", 12, 12, fun(C, R) -> R * 100 + C end),
    Dst = filename:join(Dir, "conv_out.tif"),
    Id  = f32_bin([0.0,0.0,0.0, 0.0,1.0,0.0, 0.0,0.0,0.0]),
    {ok, Dst} = rast:process_convolution(Src, Dst, Id, {3, 3}, #{tile => {4, 4}, workers => 3}),
    {ok, Ho} = rast_gdal:open(Dst),
    #{dtype := <<"Float32">>, width := 12, height := 12} = Ho,   % full size (clamp)
    %% identity => output == source everywhere, borders included
    {ok, Corner} = rast_gdal:read_window(Ho, #{x=>0,  y=>0,  w=>1, h=>1}),
    {ok, Br}     = rast_gdal:read_window(Ho, #{x=>11, y=>11, w=>1, h=>1}),
    {ok, Mid}    = rast_gdal:read_window(Ho, #{x=>5,  y=>7,  w=>1, h=>1}),
    [VC] = f32_list(Corner),
    true = (abs(VC) < ?EPS),      % source(0,0) = 0
    [1111.0] = f32_list(Br),      % 11*100 + 11
    [705.0]  = f32_list(Mid).     % 7*100 + 5

%% valid mode: output shrinks by the kernel radius.
process_convolution_valid(Cfg) ->
    need_gdal(Cfg),
    Dir = ?config(priv_dir, Cfg),
    Src = mk_u16_envi(Dir, "convv_src", 12, 12, fun(C, R) -> R * 100 + C end),
    Dst = filename:join(Dir, "convv_out.tif"),
    Id  = f32_bin([0.0,0.0,0.0, 0.0,1.0,0.0, 0.0,0.0,0.0]),
    {ok, Dst} = rast:process_convolution(Src, Dst, Id, {3, 3},
                                         #{tile => {4, 4}, workers => 3, pad => valid}),
    {ok, Ho} = rast_gdal:open(Dst),
    #{width := 10, height := 10} = Ho,   % 12 - 3 + 1
    {ok, A} = rast_gdal:read_window(Ho, #{x=>0, y=>0, w=>1, h=>1}),
    {ok, B} = rast_gdal:read_window(Ho, #{x=>9, y=>9, w=>1, h=>1}),
    [101.0]  = f32_list(A),      % source(1,1)
    [1010.0] = f32_list(B).      % source(10,10)

%%%===================================================================
%%% Helpers
%%%===================================================================

need_gdal(Cfg) ->
    case ?config(gdal, Cfg) of
        true  -> ok;
        false -> {skip, "GDAL not available"}
    end.

%% Write a WxH single-band UInt16 ENVI raster (raw + .hdr). GDAL reads ENVI
%% natively, so this needs no gdal invocation to create. Returns the data path.
mk_u16_envi(Dir, Name, W, H, Fun) ->
    Raw = filename:join(Dir, Name ++ ".raw"),
    Hdr = filename:join(Dir, Name ++ ".hdr"),
    Data = << <<(Fun(C, R)):16/unsigned-little>>
              || R <- lists:seq(0, H - 1), C <- lists:seq(0, W - 1) >>,
    ok = file:write_file(Raw, Data),
    ok = file:write_file(Hdr,
        io_lib:format("ENVI~nsamples = ~w~nlines = ~w~nbands = 1~nheader offset = 0~n"
                      "data type = 12~ninterleave = bsq~nbyte order = 0~n", [W, H])),
    Raw.

dup(V, N) -> [V || _ <- lists:seq(1, N)].

u16_list(Bin) -> [V || <<V:16/unsigned-little>> <= Bin].

need_nif(Cfg) ->
    case ?config(nif_loaded, Cfg) of
        true  -> ok;
        false -> {skip, "native NIF not built — run `make build`"}
    end.

u16_bin(Vals) -> << <<V:16/unsigned-little>> || V <- Vals >>.

f32_bin(Vals) -> << <<V:32/float-little>> || V <- Vals >>.

f32_list(<<>>) -> [];
f32_list(<<V:32/float-little, Rest/binary>>) -> [V | f32_list(Rest)].

assert_f32_close(Expected, Bin) ->
    Got = f32_list(Bin),
    true = (length(Expected) =:= length(Got)),
    lists:foreach(
        fun({E, G}) -> true = (abs(E - G) < ?EPS) end,
        lists:zip(Expected, Got)).
