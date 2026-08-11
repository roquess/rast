%%%-------------------------------------------------------------------
%%% @doc rast_nif — native raster tile kernels.
%%%
%%% Low-level, binary-first, per-tile kernels implemented in Rust (see
%%% `native/rast/src/lib.rs'). All functions take and return little-endian
%%% binaries and run on dirty CPU schedulers.
%%%
%%% Prefer the {@link rast} façade in application code; this module is the raw
%%% NIF surface.
%%% @end
%%%-------------------------------------------------------------------
-module(rast_nif).

-export([
    decode_u16_to_f32/2,
    ndvi_u16/2,
    ndvi_f32/2,
    convolve_f32/6,
    pad_replicate_f32/7
]).

-on_load(init/0).

-define(APPNAME, rast).

%% @private
%% @doc Load the platform-specific prebuilt NIF. Each platform ships its own
%% file (`rast-<os>-<arch>') so a single hex package carries working binaries
%% for Linux, macOS (x86_64 + aarch64) and Windows without a filename clash
%% (Erlang loads NIFs as `.so' on every Unix, macOS included, and `.dll' on
%% Windows — so Linux and macOS could not otherwise share `rast.so').
init() ->
    PrivDir = case code:priv_dir(?APPNAME) of
                  {error, bad_name} ->
                      case filelib:is_dir(filename:join(["..", priv])) of
                          true  -> filename:join(["..", priv]);
                          false -> "priv"
                      end;
                  Dir ->
                      Dir
              end,
    Base = "rast-" ++ os_tag() ++ "-" ++ arch_tag(),
    erlang:load_nif(filename:join(PrivDir, Base), 0).

os_tag() ->
    case os:type() of
        {unix, darwin} -> "darwin";
        {win32, _}     -> "windows";
        {unix, _}      -> "linux"
    end.

arch_tag() ->
    Low = string:lowercase(erlang:system_info(system_architecture)),
    HasAarch = string:find(Low, "aarch64") =/= nomatch
        orelse string:find(Low, "arm64") =/= nomatch,
    case HasAarch of
        true  -> "aarch64";
        false -> "x86_64"   % Windows reports "win32"; default to x86_64
    end.

%% @doc Decode a little-endian `u16' tile binary to a little-endian `f32'
%% binary, multiplying each sample by `Scale' (`1.0' for a plain widening cast).
-spec decode_u16_to_f32(binary(), float()) -> {ok, binary()} | {error, term()}.
decode_u16_to_f32(_Data, _Scale) ->
    erlang:nif_error({not_loaded, [{module, ?MODULE}, {line, ?LINE}]}).

%% @doc NDVI `(NIR - Red) / (NIR + Red)' from two `u16' tile binaries, fused with
%% `u16 -> f32' widening. Returns an `f32' binary; `0.0' where `NIR + Red == 0'.
-spec ndvi_u16(binary(), binary()) -> {ok, binary()} | {error, term()}.
ndvi_u16(_Nir, _Red) ->
    erlang:nif_error({not_loaded, [{module, ?MODULE}, {line, ?LINE}]}).

%% @doc NDVI `(NIR - Red) / (NIR + Red)' from two little-endian `f32' tile
%% binaries. Returns an `f32' binary; `0.0' where `NIR + Red == 0'.
-spec ndvi_f32(binary(), binary()) -> {ok, binary()} | {error, term()}.
ndvi_f32(_Nir, _Red) ->
    erlang:nif_error({not_loaded, [{module, ?MODULE}, {line, ?LINE}]}).

%% @doc Valid 2-D cross-correlation of an `f32' tile (`SrcW × SrcH') with a
%% `KW × KH' `f32' kernel. Output is `(SrcW-KW+1) × (SrcH-KH+1)' `f32'.
-spec convolve_f32(binary(), pos_integer(), pos_integer(),
                   binary(), pos_integer(), pos_integer()) ->
        {ok, binary()} | {error, term()}.
convolve_f32(_Src, _SrcW, _SrcH, _Kernel, _KW, _KH) ->
    erlang:nif_error({not_loaded, [{module, ?MODULE}, {line, ?LINE}]}).

%% @doc Replicate-pad an `f32' tile by `Left'/`Top'/`Right'/`Bottom' rows/cols.
%% Output is `(W+Left+Right) × (H+Top+Bottom)'.
-spec pad_replicate_f32(binary(), pos_integer(), pos_integer(),
                        non_neg_integer(), non_neg_integer(),
                        non_neg_integer(), non_neg_integer()) ->
        {ok, binary()} | {error, term()}.
pad_replicate_f32(_Src, _W, _H, _Left, _Top, _Right, _Bottom) ->
    erlang:nif_error({not_loaded, [{module, ?MODULE}, {line, ?LINE}]}).
