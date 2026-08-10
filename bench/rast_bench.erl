%%%-------------------------------------------------------------------
%%% @doc rast_bench — bandwidth-oriented microbenchmark.
%%%
%%% For a memory-bound workload the only metric that matters is throughput in
%%% GB/s vs peak memory bandwidth (ARCHITECTURE.md §9). This harness reports
%%% bytes touched per second for each kernel on a realistic tile size, so a
%%% future SIMD version can be compared against this scalar baseline.
%%%
%%% Run: `make bench'  (or `rebar3 as bench shell` then `rast_bench:run().').
%%% @end
%%%-------------------------------------------------------------------
-module(rast_bench).

-export([run/0, run/1]).

-define(REPS, 50).

-type config() :: #{tile := pos_integer(), reps := pos_integer()}.

-spec run() -> ok.
%% @doc Default: 2048×2048 tile (16 MB as f32), 50 reps.
run() ->
    run(#{tile => 2048 * 2048, reps => ?REPS}).

-spec run(config()) -> ok.
run(#{tile := N, reps := Reps}) ->
    io:format("~n=== rast benchmark — ~s ===~n", [rast:version()]),
    io:format("tile=~w px  reps=~w~n~n", [N, Reps]),

    rand:seed(exsss, {42, 0, 0}),
    U16a = << <<(rand:uniform(65535)):16/unsigned-little>> || _ <- lists:seq(1, N) >>,
    U16b = << <<(rand:uniform(65535)):16/unsigned-little>> || _ <- lists:seq(1, N) >>,
    {ok, F32a} = rast:decode_u16(U16a, 1.0),
    {ok, F32b} = rast:decode_u16(U16b, 1.0),

    %% decode_u16_to_f32 (auto-vec): reads 2N bytes, writes 4N bytes.
    bench("decode_u16_to_f32 [auto-vec]", fun() -> rast:decode_u16(U16a, 1.0) end,
          Reps, N * 2 + N * 4),

    %% ndvi_u16 (auto-vec): reads 2*2N bytes, writes 4N bytes.
    bench("ndvi_u16          [auto-vec]", fun() -> rast:ndvi_u16(U16a, U16b) end,
          Reps, N * 4 + N * 4),

    %% ndvi_f32 (SIMD): reads 2*4N bytes, writes 4N bytes.
    bench("ndvi_f32          [SIMD]  ", fun() -> rast:ndvi_f32(F32a, F32b) end,
          Reps, N * 8 + N * 4),

    io:format("~n"),
    ok.

%%%===================================================================
%%% Helpers
%%%===================================================================

bench(Label, Fun, Reps, BytesPerRep) ->
    {ok, _} = Fun(),  %% warm up
    {UsTotal, _} = timer:tc(fun() ->
        [Fun() || _ <- lists:seq(1, Reps)]
    end),
    UsPer  = UsTotal / Reps,
    GBps   = (BytesPerRep / (UsPer / 1.0e6)) / 1.0e9,
    io:format("  ~s  ~10.2f us/tile   ~6.2f GB/s~n", [Label, UsPer, GBps]).
