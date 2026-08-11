.PHONY: build build_if_needed test bench docs clean

# Per-platform NIF name: rast-<os>-<arch>. Erlang loads NIFs as .so on every
# Unix (macOS included) and .dll on Windows, so the built .dylib is copied to .so.
ifeq ($(OS),Windows_NT)
    OS_TAG   := windows
    NIF_EXT  := dll
    BUILT    := rast.dll
    UNAME_M  := $(PROCESSOR_ARCHITECTURE)
else
    UNAME_S := $(shell uname -s)
    UNAME_M := $(shell uname -m)
    NIF_EXT := so
    ifeq ($(UNAME_S),Darwin)
        OS_TAG := darwin
        BUILT  := librast.dylib
    else
        OS_TAG := linux
        BUILT  := librast.so
    endif
endif

ifeq ($(filter arm64 aarch64 ARM64,$(UNAME_M)),)
    ARCH_TAG := x86_64
else
    ARCH_TAG := aarch64
endif

NIF_NAME := rast-$(OS_TAG)-$(ARCH_TAG).$(NIF_EXT)

# Locate cargo: prefer PATH, fall back to the default rustup location.
CARGO := $(shell command -v cargo 2>/dev/null || echo $(HOME)/.cargo/bin/cargo)

build:
	cd native/rast && $(CARGO) build --release
	mkdir -p priv
	cp native/rast/target/release/$(BUILT) priv/$(NIF_NAME)

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
