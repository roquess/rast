.PHONY: build build_if_needed test bench docs clean

# Auto-detect platform
ifeq ($(OS),Windows_NT)
    DLL_EXT := .dll
    NIF_NAME := rast.dll
else
    UNAME_S := $(shell uname -s)
    ifeq ($(UNAME_S),Linux)
        DLL_EXT := .so
        NIF_NAME := rast.so
    endif
    ifeq ($(UNAME_S),Darwin)
        DLL_EXT := .dylib
        NIF_NAME := rast.dylib
    endif
endif

# Locate cargo: prefer PATH, fall back to the default rustup location.
CARGO := $(shell command -v cargo 2>/dev/null || echo $(HOME)/.cargo/bin/cargo)

build:
	cd native/rast && $(CARGO) build --release
	mkdir -p priv
	cp native/rast/target/release/*$(DLL_EXT) priv/$(NIF_NAME)

build_if_needed:
	@if [ ! -f "priv/$(NIF_NAME)" ]; then $(MAKE) build; fi

test: build
	rebar3 ct

bench: build
	rebar3 as bench shell --eval "rast_bench:run(), halt()."

docs:
	rebar3 edoc

clean:
	rm -rf _build native/rast/target priv/*
