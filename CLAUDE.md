# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Scripts for building Wine from source on macOS as an x86_64 binary and bundling it into a self-contained, relocatable distribution with WoW64 (i386+x86_64). The Wine version is whatever source tree is checked out in `../src`. The `WINE_VERSION` variable in `bundle-wine.sh` must be updated to match.

## Build Pipeline

Two scripts run sequentially — build first, then bundle:

```bash
# Step 1: Build Wine from source (runs under arch -x86_64)
./build-wine.sh

# Step 2: Bundle into relocatable distribution
./bundle-wine.sh --dest /path/to/output
```

**build-wine.sh** — Configures and compiles Wine from `../src` into `../build`. Uses Homebrew x86_64 deps from `/usr/local/`. Incremental by default (preserves `../build` between runs). Pass `--clean` to wipe the build directory first for a full rebuild. On `--clean`, also patches sonames in `config.h` to use `@loader_path/../../external/` paths for relocatable bundles.

**bundle-wine.sh** — Takes the build output and creates a distributable `wine/` tree. Requires `--dest <dir>`. Steps: staged install → flatten prefix → bundle dylibs (copy, fix install names with `@loader_path`) → verify.

## Relocation Strategy

Soname patching eliminates the need for `DYLD_FALLBACK_LIBRARY_PATH` and any launcher binary. The `bin/` layout is left exactly as `make install` creates it.

- **Soname patching**: `build-wine.sh --clean` patches `SONAME_LIB*` defines in `config.h` to use `@loader_path/../../external/<lib>` paths before compiling. This makes Wine's .so modules in `lib/wine/x86_64-unix/` find bundled dylibs in `lib/external/` via dyld's `@loader_path` resolution.
- **bin/ layout**: Unchanged from `make install` — `bin/wine` is Wine's standard preloader, convenience programs (winecfg, regedit, etc.) are symlinks to it.
- No `libexec/` directory. No `DYLD_FALLBACK_LIBRARY_PATH` needed.

## Key Details

- All compilation uses `arch -x86_64` — this is an x86_64-only build running under Rosetta on Apple Silicon
- Dependencies come from Homebrew x86_64 (`/usr/local/`), not ARM (`/opt/homebrew/`)
- Bundled dylibs go in `lib/external/` with install names rewritten to `@loader_path/`
- The bundle script verifies no `/usr/local/` references leak into the final distribution
