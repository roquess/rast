%%%-------------------------------------------------------------------
%%% @doc rast_tiling — pure tile-grid geometry.
%%%
%%% Splits a `Width' × `Height' raster into a regular grid of `TileW' × `TileH'
%%% tiles. Right/bottom edge tiles are clipped to the raster bounds (partial
%%% tiles), so every pixel is covered exactly once and no tile reads out of
%%% bounds.
%%%
%%% No I/O, no processes — just arithmetic. This is the addressing layer the
%%% coordinator uses to drive windowed reads.
%%% @end
%%%-------------------------------------------------------------------
-module(rast_tiling).

-export([tile_grid/4, tile_count/4]).

-type tile() :: #{x := non_neg_integer(),
                  y := non_neg_integer(),
                  w := pos_integer(),
                  h := pos_integer()}.

-export_type([tile/0]).

%% @doc Number of tiles covering a `Width' × `Height' raster with `TileW' ×
%% `TileH' tiles (edge tiles included).
-spec tile_count(pos_integer(), pos_integer(), pos_integer(), pos_integer()) ->
        non_neg_integer().
tile_count(Width, Height, TileW, TileH)
        when Width > 0, Height > 0, TileW > 0, TileH > 0 ->
    ceil_div(Width, TileW) * ceil_div(Height, TileH).

%% @doc List every tile window, row-major (left-to-right, top-to-bottom).
%% Each tile is `#{x, y, w, h}' in pixel coordinates; edge tiles are clipped.
-spec tile_grid(pos_integer(), pos_integer(), pos_integer(), pos_integer()) ->
        [tile()].
tile_grid(Width, Height, TileW, TileH)
        when Width > 0, Height > 0, TileW > 0, TileH > 0 ->
    [ #{x => X, y => Y,
        w => min(TileW, Width  - X),
        h => min(TileH, Height - Y)}
      || Y <- lists:seq(0, Height - 1, TileH),
         X <- lists:seq(0, Width  - 1, TileW) ].

%%%===================================================================
%%% Internal
%%%===================================================================

-spec ceil_div(pos_integer(), pos_integer()) -> pos_integer().
ceil_div(A, B) -> (A + B - 1) div B.
