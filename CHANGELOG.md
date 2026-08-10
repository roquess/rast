# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added
- Initial project scaffold: OTP application, native NIF crate, tiling helpers,
  GDAL bridge stub, benchmark harness, test suite (17 tests).
- Native kernels: `decode_u16_to_f32/2`, `ndvi_u16/2`, `ndvi_f32/2`,
  `convolve_f32/6`.
  - `ndvi_f32` is **SIMD** via simdeez runtime dispatch (SSE2/SSE4.1/AVX2/NEON),
    zero-copy on aligned tile binaries, masked select for divide-by-zero.
  - `decode_u16_to_f32` / `ndvi_u16` widen `u16 -> f32` via an aligned
    reinterpret + cast loop that **auto-vectorizes** to a hardware widening
    convert (guaranteed lane order, portable, ~2× the byte-wise version).
  - `convolve_f32/6` — valid 2-D cross-correlation with an arbitrary `KW × KH`
    f32 kernel; output shrinks by the kernel radius (halo/apron model).
  - `pad_replicate_f32/7` — edge-replicate padding, used to synthesize the
    convolution apron at the scene border.
- `rast_tiling`: pure tile-grid computation (`tile_grid/4`, `tile_count/4`).
- **Tiling orchestration**: `rast:process_tiles/3` — demand-driven, bounded
  worker pool (`rast_coordinator` pull scheduler + `rast_worker`). Peak memory
  bounded by `workers × tile_bytes`; each tile processed exactly once. I/O is
  injected as funs, so the same engine drives an in-memory source or the GDAL
  bridge unchanged.
- **GDAL bridge** (`rast_gdal`): CLI port via `open_port(spawn_executable)` (no
  shell). Read side — `open/1` (metadata via `gdalinfo -json`, parsed with OTP's
  `json`), `read_window/2,3` (windowed read via `gdal_translate -srcwin` → ENVI
  raw). Write side — `create_output/4` + `write_window/3` (Erlang owns a flat raw
  file, workers `pwrite` disjoint tiles) + `finalize/1` (single `gdal_translate`
  wraps the raw into a GeoTIFF). GDAL located via `application:get_env(rast,
  gdal_bin_dir)` / `$GDAL_BIN_DIR` / platform default.
- **`rast:process_band/3`**: full scene pipeline — open sources, tile, read
  windows, run the fused kernel, scatter results, finalize a GeoTIFF. Supports
  `op => ndvi` (2 sources) and `op => {decode, Scale}` (1 source).
- Test suite now 20 tests, incl. an end-to-end NDVI over a real GeoTIFF (GDAL
  tests skip cleanly when GDAL is absent).

- **`rast:process_convolution/5`**: whole-scene convolution — tiles the output,
  reads halo-grown source windows (decoding `u16 -> f32`), runs `convolve_f32`,
  scatters results, finalizes a GeoTIFF. `pad => clamp` (default) gives a
  full-size result with edge-replicated borders; `pad => valid` shrinks by the
  kernel radius.

### Benchmarks (single core, 2048×2048 tile)
- `ndvi_f32` [SIMD]: ~19 GB/s (near single-core DRAM bandwidth — memory-bound).
- `ndvi_u16` [auto-vec]: ~12 GB/s (was ~6 before the aligned widening cast).
- `decode_u16_to_f32` [auto-vec]: ~11 GB/s (was ~7).

### Not yet implemented (optimizations, not correctness)
- Explicit-intrinsic SIMD convolution (kernel is scalar/auto-vectorized).
- Persistent GDAL port / NIF (current bridge spawns one subprocess per tile
  read — fine for correctness, a throughput optimization later).
- Reflect/wrap padding modes (only `clamp` and `valid` today).
