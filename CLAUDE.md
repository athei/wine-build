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

**build-wine.sh** — Configures and compiles Wine from `../src` into `../build`. Uses Homebrew x86_64 deps from `/usr/local/`. Incremental by default (preserves `../build` between runs). Pass `--clean` to wipe the build directory first for a full rebuild.

**bundle-wine.sh** — Takes the build output and creates a distributable `wine/` tree. Requires `--dest <dir>`. Steps: staged install → flatten prefix → bundle dylibs (copy, fix install names with `@loader_path`) → compile launcher → verify.

## Launcher Architecture

`wine-launcher.c` is a compiled x86_64 C binary that replaces what were previously per-program shell wrapper scripts. It lives at `libexec/wine-launcher` in the distribution.

- Every program in `bin/` (wine, wineserver, winecfg, regedit, etc.) is a symlink to `../libexec/wine-launcher`
- The launcher reads `argv[0]` basename to decide what to exec:
  - `wine`/`wine64` → `libexec/wine`
  - `wineserver` → `libexec/wineserver`
  - Dev tools (winegcc, widl, etc.) → `libexec/<tool>`
  - Everything else (winecfg, regedit, etc.) → `libexec/wine <basename>`
- Sets `DYLD_FALLBACK_LIBRARY_PATH` to `lib/external/` and `WINELOADER` before exec

## Key Details

- All compilation uses `arch -x86_64` — this is an x86_64-only build running under Rosetta on Apple Silicon
- Dependencies come from Homebrew x86_64 (`/usr/local/`), not ARM (`/opt/homebrew/`)
- Bundled dylibs go in `lib/external/` with install names rewritten to `@loader_path/`
- The bundle script verifies no `/usr/local/` references leak into the final distribution
