//! # rast — SIMD raster tile kernels for Erlang
//!
//! Thin Rustler NIF exposing bounded, per-tile, memory-bound kernels to the
//! BEAM. The Erlang side (`rast`, `rast_coordinator`, `rast_worker`) owns all
//! I/O, tiling, halo assembly and backpressure; this crate only computes one
//! tile at a time and returns a single output binary.
//!
//! ## Design rules (see ARCHITECTURE.md)
//! - **Binary-first**: inputs and outputs are refc-binaries, never lists.
//! - **Typed decode fused into the kernel**: `u16` source data is widened to
//!   `f32` inside the kernel, halving memory traffic vs pre-converting.
//! - **Fused**: `(a-b)/(a+b)` is one pass over the data, not three.
//! - **DirtyCpu**: tiles are multi-MB, well past the ~1 ms NIF budget.
//! - **Panic-safe**: `panic = "unwind"` (see Cargo.toml); expected errors are
//!   returned as `{error, Reason}` tuples.
//!
//! ## SIMD status
//! - `ndvi_f32` is SIMD via `simdeez` runtime dispatch (SSE2/SSE4.1/AVX2/NEON),
//!   zero-copy on aligned tile binaries, with a masked select for the
//!   divide-by-zero case.
//! - `decode_u16_to_f32` and `ndvi_u16` stay **scalar** (LLVM auto-vectorizes
//!   the widening loop). Portable `u16 -> f32` SIMD widening is deferred: the
//!   `simdeez` `extend_to_i32` split has *implementation-defined* lane ordering,
//!   which is unsafe for an order-sensitive decode. Revisit with explicit
//!   per-engine unpack if the scalar path proves to be the bottleneck.

use rustler::{Binary, Encoder, Env, Error, OwnedBinary, Term};
use simdeez::prelude::*;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        length_mismatch,
        odd_length,
        empty,
        bad_dims,
    }
}

rustler::init!("rast_nif");

//==============================================================================
// Byte-layout helpers
//==============================================================================

/// Allocate an Erlang binary of `n` bytes, hand it to `fill`, release into `env`.
fn build_binary<'a, F>(env: Env<'a>, n: usize, fill: F) -> Result<Term<'a>, Error>
where
    F: FnOnce(&mut [u8]),
{
    let mut owned = match OwnedBinary::new(n) {
        Some(b) => b,
        None => return Ok((atoms::error(), atoms::empty()).encode(env)),
    };
    fill(owned.as_mut_slice());
    Ok((atoms::ok(), owned.release(env)).encode(env))
}

#[inline]
fn read_u16_le(b: &[u8], i: usize) -> u16 {
    u16::from_le_bytes([b[i], b[i + 1]])
}

/// View a byte slice as `&[f32]` without copying, **iff** it is 4-byte aligned.
/// Erlang whole-tile refc-binaries are 8-byte aligned, so this is the common
/// case; sub-binaries at odd offsets fall through to the scratch-copy path.
fn as_f32(bytes: &[u8]) -> Option<&[f32]> {
    if bytes.as_ptr() as usize % 4 == 0 {
        Some(unsafe { std::slice::from_raw_parts(bytes.as_ptr() as *const f32, bytes.len() / 4) })
    } else {
        None
    }
}

/// Return an `f32` view of `bytes`, copying into `scratch` only if unaligned.
fn f32_input<'a>(bytes: &'a [u8], scratch: &'a mut Vec<f32>) -> &'a [f32] {
    match as_f32(bytes) {
        Some(s) => s,
        None => {
            *scratch = bytes
                .chunks_exact(4)
                .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
                .collect();
            scratch.as_slice()
        }
    }
}

/// View a byte slice as `&[u16]` without copying, iff little-endian and 2-byte
/// aligned. On such a slice `u[i] == u16::from_le_bytes(...)`, and a plain
/// `u[i] as f32` cast loop auto-vectorizes to a hardware widening convert —
/// which is why this path is much faster than byte-wise `from_le_bytes`.
fn as_u16(bytes: &[u8]) -> Option<&[u16]> {
    if cfg!(target_endian = "little") && bytes.as_ptr() as usize % 2 == 0 {
        Some(unsafe { std::slice::from_raw_parts(bytes.as_ptr() as *const u16, bytes.len() / 2) })
    } else {
        None
    }
}

/// View the output binary as `&mut [f32]`. OwnedBinary is 8-byte aligned, so
/// this is always sound for our allocations.
fn out_f32(bytes: &mut [u8]) -> &mut [f32] {
    unsafe { std::slice::from_raw_parts_mut(bytes.as_mut_ptr() as *mut f32, bytes.len() / 4) }
}

//==============================================================================
// SIMD kernel (f32)
//==============================================================================

simd_runtime_generate! {
    /// NDVI `(a-b)/(a+b)` into `out`, one fused SIMD pass. `0.0` where `a+b == 0`
    /// (masked select, so the divide's NaN/inf in those lanes is discarded).
    fn ndvi_f32_simd(a: &[f32], b: &[f32], out: &mut [f32]) {
        let zero = S::Vf32::set1(0.0);
        let w = S::Vf32::WIDTH;
        let n = a.len();
        let mut i = 0;
        while i + w <= n {
            let va = S::Vf32::load_from_slice(&a[i..]);
            let vb = S::Vf32::load_from_slice(&b[i..]);
            let denom = va + vb;
            let diff = va - vb;
            let ratio = diff / denom;
            let mask = denom.cmp_eq(zero);          // all-1s where denom == 0
            let vr = mask.blendv(ratio, zero);      // ratio where mask==0, else 0
            vr.copy_to_slice(&mut out[i..]);
            i += w;
        }
        while i < n {
            let d = a[i] + b[i];
            out[i] = if d == 0.0 { 0.0 } else { (a[i] - b[i]) / d };
            i += 1;
        }
    }
}

//==============================================================================
// Typed decode (scalar; auto-vectorized)
//==============================================================================

/// Decode a little-endian `u16` tile binary into a little-endian `f32` binary,
/// multiplying each sample by `scale` (`1.0` for a plain widening cast).
#[rustler::nif(schedule = "DirtyCpu")]
fn decode_u16_to_f32<'a>(env: Env<'a>, data: Binary<'a>, scale: f64) -> Result<Term<'a>, Error> {
    let src = data.as_slice();
    if src.is_empty() {
        return Ok((atoms::error(), atoms::empty()).encode(env));
    }
    if src.len() % 2 != 0 {
        return Ok((atoms::error(), atoms::odd_length()).encode(env));
    }
    let n = src.len() / 2;
    let scale = scale as f32;
    build_binary(env, n * 4, |ob| {
        let out = out_f32(ob);
        match as_u16(src) {
            Some(u) => {
                for i in 0..n {
                    out[i] = u[i] as f32 * scale;   // auto-vectorized widening
                }
            }
            None => {
                for i in 0..n {
                    out[i] = read_u16_le(src, i * 2) as f32 * scale;
                }
            }
        }
    })
}

//==============================================================================
// Fused indices
//==============================================================================

/// NDVI from two `u16` tile binaries: `(nir - red) / (nir + red)`, single fused
/// pass with `u16 -> f32` widening folded in. Returns an `f32` binary; `0.0`
/// where `nir + red == 0`. Scalar (auto-vectorized).
#[rustler::nif(schedule = "DirtyCpu")]
fn ndvi_u16<'a>(env: Env<'a>, nir: Binary<'a>, red: Binary<'a>) -> Result<Term<'a>, Error> {
    let a = nir.as_slice();
    let b = red.as_slice();
    if a.len() != b.len() {
        return Ok((atoms::error(), atoms::length_mismatch()).encode(env));
    }
    if a.is_empty() {
        return Ok((atoms::error(), atoms::empty()).encode(env));
    }
    if a.len() % 2 != 0 {
        return Ok((atoms::error(), atoms::odd_length()).encode(env));
    }
    let n = a.len() / 2;
    build_binary(env, n * 4, |ob| {
        let out = out_f32(ob);
        match (as_u16(a), as_u16(b)) {
            (Some(na), Some(nr)) => {
                for i in 0..n {
                    let nir_v = na[i] as f32;
                    let red_v = nr[i] as f32;
                    let denom = nir_v + red_v;
                    // Branchless select vectorizes; NaN from 0/0 is discarded.
                    out[i] = if denom == 0.0 { 0.0 } else { (nir_v - red_v) / denom };
                }
            }
            _ => {
                for i in 0..n {
                    let nir_v = read_u16_le(a, i * 2) as f32;
                    let red_v = read_u16_le(b, i * 2) as f32;
                    let denom = nir_v + red_v;
                    out[i] = if denom == 0.0 { 0.0 } else { (nir_v - red_v) / denom };
                }
            }
        }
    })
}

/// NDVI from two little-endian `f32` tile binaries: `(nir - red) / (nir + red)`,
/// SIMD single pass. Returns an `f32` binary; `0.0` where `nir + red == 0`.
#[rustler::nif(schedule = "DirtyCpu")]
fn ndvi_f32<'a>(env: Env<'a>, nir: Binary<'a>, red: Binary<'a>) -> Result<Term<'a>, Error> {
    let a = nir.as_slice();
    let b = red.as_slice();
    if a.len() != b.len() {
        return Ok((atoms::error(), atoms::length_mismatch()).encode(env));
    }
    if a.is_empty() {
        return Ok((atoms::error(), atoms::empty()).encode(env));
    }
    if a.len() % 4 != 0 {
        return Ok((atoms::error(), atoms::odd_length()).encode(env));
    }
    let n = a.len() / 4;
    let mut sa = Vec::new();
    let mut sb = Vec::new();
    let af = f32_input(a, &mut sa);
    let bf = f32_input(b, &mut sb);
    build_binary(env, n * 4, |ob| {
        ndvi_f32_simd(af, bf, out_f32(ob));
    })
}

//==============================================================================
// Edge padding (replicate / clamp)
//==============================================================================

/// Pad an `f32` tile by replicating its edge pixels: `left`/`top`/`right`/`bottom`
/// extra rows/cols of the nearest border value. Output is
/// `(w+left+right) × (h+top+bottom)`. Used to synthesize a convolution apron at
/// the scene border so `process_convolution` can produce a full-size result.
#[rustler::nif(schedule = "DirtyCpu")]
fn pad_replicate_f32<'a>(
    env: Env<'a>,
    src: Binary<'a>,
    w: usize,
    h: usize,
    left: usize,
    top: usize,
    right: usize,
    bottom: usize,
) -> Result<Term<'a>, Error> {
    if w == 0 || h == 0 || src.len() != w * h * 4 {
        return Ok((atoms::error(), atoms::bad_dims()).encode(env));
    }
    let ow = w + left + right;
    let oh = h + top + bottom;
    let mut ss = Vec::new();
    let s = f32_input(src.as_slice(), &mut ss);
    build_binary(env, ow * oh * 4, |ob| {
        let out = out_f32(ob);
        for oy in 0..oh {
            let sy = oy.saturating_sub(top).min(h - 1);
            let srow = sy * w;
            let orow = oy * ow;
            for ox in 0..ow {
                let sx = ox.saturating_sub(left).min(w - 1);
                out[orow + ox] = s[srow + sx];
            }
        }
    })
}

//==============================================================================
// 2-D convolution (valid cross-correlation)
//==============================================================================

/// "Valid" 2-D cross-correlation of an `f32` tile with a `kw × kh` `f32` kernel.
///
/// Output size is `(src_w - kw + 1) × (src_h - kh + 1)`: with a window read
/// `radius` pixels larger than the target tile on every side (the halo/apron),
/// the valid output is exactly the target tile — which is how tiled convolution
/// avoids seams. Cross-correlation (no kernel flip); for symmetric kernels
/// (blur, Gaussian) it equals convolution.
#[rustler::nif(schedule = "DirtyCpu")]
fn convolve_f32<'a>(
    env: Env<'a>,
    src: Binary<'a>,
    src_w: usize,
    src_h: usize,
    kernel: Binary<'a>,
    kw: usize,
    kh: usize,
) -> Result<Term<'a>, Error> {
    if kw == 0 || kh == 0 || src_w == 0 || src_h == 0 || kw > src_w || kh > src_h {
        return Ok((atoms::error(), atoms::bad_dims()).encode(env));
    }
    if src.len() != src_w * src_h * 4 || kernel.len() != kw * kh * 4 {
        return Ok((atoms::error(), atoms::length_mismatch()).encode(env));
    }
    let ow = src_w - kw + 1;
    let oh = src_h - kh + 1;
    let mut ss = Vec::new();
    let mut sk = Vec::new();
    let s = f32_input(src.as_slice(), &mut ss);
    let k = f32_input(kernel.as_slice(), &mut sk);
    build_binary(env, ow * oh * 4, |ob| {
        let out = out_f32(ob);
        for oy in 0..oh {
            for ox in 0..ow {
                let mut acc = 0.0f32;
                for ky in 0..kh {
                    let srow = (oy + ky) * src_w + ox;
                    let krow = ky * kw;
                    for kx in 0..kw {
                        acc += s[srow + kx] * k[krow + kx];
                    }
                }
                out[oy * ow + ox] = acc;
            }
        }
    })
}
