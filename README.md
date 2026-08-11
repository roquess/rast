# rast

SIMD raster tile processing for Erlang: **fused, typed, binary-first kernels**
under a **bounded-memory OTP tiling** layer. Built for large satellite scenes
(Sentinel-2 / Landsat, 10k–100k px per side, multi-band, `uint16`).

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

> **Status: early, working end-to-end.** Fused tile kernels (NDVI SIMD on the
> f32 path), tiling geometry, a bounded-memory demand-driven tiling engine
> (`process_tiles/3`), and a GDAL I/O bridge (`rast_gdal`) are in place and
> tested (20 tests, incl. an end-to-end NDVI over a real GeoTIFF via
> `process_band/3`). Remaining: SIMD `u16 -> f32` widening and convolution/halo
> — see [ARCHITECTURE.md](../ARCHITECTURE.md) and [CHANGELOG.md](CHANGELOG.md).

## Why

A single Sentinel-2 band is ~120 M pixels. Two things follow, and they shape the
whole design:

1. **Everything is a binary, never a list.** A float list of one band would cost
   ~5 GB of BEAM heap; the same data is 240 MB as a `uint16` binary.
2. **The workload is memory-bandwidth-bound.** Arithmetic is nearly free; bytes
   moved is the cost. So kernels are **fused** (NDVI = `(NIR-Red)/(NIR+Red)` in
   one pass, not three) and **typed** (`u16` widened to `f32` inside the kernel,
   halving traffic).

The pixel crunching is a thin Rust NIF; the BEAM does what it is good at —
bounded-memory, demand-driven orchestration of tiles across cores, with
supervision and backpressure. GDAL/PROJ do all I/O and reprojection; rast does
not reinvent them.

## Layout

```
rast/
├── src/
│   ├── rast.erl              # public façade
│   ├── rast_nif.erl          # native kernel wrappers
│   ├── rast_tiling.erl       # pure tile-grid geometry
│   ├── rast_gdal.erl         # GDAL bridge (stub)
│   ├── rast_coordinator.erl  # demand-driven tile scheduler (skeleton)
│   ├── rast_worker.erl       # per-tile loop (skeleton)
│   ├── rast_app.erl / rast_sup.erl
│   └── rast.app.src
├── native/rast/              # Rust NIF crate (Rustler)
├── test/rast_SUITE.erl
├── bench/rast_bench.erl      # GB/s bandwidth microbench
└── Makefile
```

## Install

```erlang
%% rebar.config
{deps, [{rast, "0.1.0"}]}.
```

**No Rust toolchain required.** The package ships a per-platform prebuilt NIF
(`priv/rast-<os>-<arch>`) for Linux x86_64, macOS x86_64 + aarch64, and Windows
x86_64; the right one is selected at load time. (Each platform gets its own file
because Erlang loads NIFs as `.so` on every Unix — macOS included — so Linux and
macOS cannot share a single `rast.so`.)

GDAL (`gdalinfo`, `gdal_translate`) is only needed for the `rast_gdal` /
`process_band` / `process_convolution` I/O paths, not for the kernels.

## Build & test (from source)

For development or an unsupported platform, build the NIF locally:

```bash
make build      # cargo build --release -> priv/rast-<os>-<arch>
make test       # rebar3 ct
make bench      # bandwidth microbenchmark
```

Requirements to build: Erlang/OTP 25+, Rust 1.80+ (Cargo in `PATH`). The
platform binaries shipped in the package are produced and committed by the
`build-nif` CI workflow.

## Kernels (implemented)

```erlang
%% Widen a uint16 tile to f32, scaling each sample.
{ok, F32Bin} = rast:decode_u16(U16Bin, 1.0).

%% NDVI from two uint16 tiles (NIR, Red), fused single pass.
{ok, NdviBin} = rast:ndvi_u16(NirU16, RedU16).

%% NDVI from two f32 tiles.
{ok, NdviBin} = rast:ndvi_f32(NirF32, RedF32).
```

All tiles are little-endian binaries: `uint16` = 2 bytes/sample, `f32` = 4
bytes/sample.

## Tiling engine (implemented)

`process_tiles/3` runs a demand-driven, bounded-memory worker pool. I/O is
injected as funs, so the same engine drives an in-memory source now and the GDAL
bridge later. Peak memory is bounded by `workers × tile_bytes`; every tile is
processed exactly once.

```erlang
Tiles = rast_tiling:tile_grid(Width, Height, 512, 512),
Funs = #{
    read   => fun(Tile) -> rast_gdal:read_window(Src, Tile) end,
    kernel => fun(Bin)  -> rast:decode_u16(Bin, 1.0) end,
    write  => fun(Tile, Out) -> rast_gdal:write_window(Dst, Tile, Out) end
},
{ok, #{tiles := N}} = rast:process_tiles(Tiles, Funs, #{workers => 8}).
```

## End-to-end via GDAL (implemented)

`process_band/3` wires the GDAL bridge into the engine: open sources, tile, read
windows, run the fused kernel, scatter results, finalize a GeoTIFF.

```erlang
%% NDVI from two uint16 bands (NIR, Red) into an f32 GeoTIFF.
{ok, "ndvi.tif"} =
    rast:process_band(["nir.tif", "red.tif"], "ndvi.tif",
                      #{op => ndvi, tile => {512, 512}, workers => 8}).
```

### GDAL requirement

The bridge shells out to the GDAL CLI (`gdalinfo`, `gdal_translate`). Point rast
at it via `application:set_env(rast, gdal_bin_dir, "…")`, the `GDAL_BIN_DIR`
environment variable, or the platform default (`C:/Program Files/GDAL` on
Windows). The kernels and `process_tiles/3` need no GDAL; only `rast_gdal` /
`process_band/3` do. `rast_gdal:available()` reports whether it was found.

## Roadmap

See [ARCHITECTURE.md](../ARCHITECTURE.md) §9 for the full incremental plan.
Next up: SIMD-ize the kernels (`simdeez`), the GDAL windowed-read bridge, then
the bounded-memory tiling orchestrator, then convolution with halo.

## License

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
