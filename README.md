# wine-build

Scripts for building Wine from source on macOS as an x86_64 binary and
bundling it into a self-contained, relocatable distribution with WoW64
(i386+x86_64). Sources come from [athei/wine](https://github.com/athei/wine)
(CrossOver Wine with custom patches on top).

## Build pipeline

Two scripts run sequentially — build first, then bundle:

```bash
# Step 1: Build Wine from source (runs under arch -x86_64)
./build-wine.sh

# Step 2: Bundle into relocatable distribution
./bundle-wine.sh --dest /path/to/output
```

**build-wine.sh** — Configures and compiles Wine into the build directory.
Uses Homebrew x86_64 deps from `/usr/local/`. Incremental by default
(preserves the build directory between runs). Pass `--clean` to wipe the
build directory first for a full rebuild. On `--clean`, also patches sonames
in `config.h` to use `@loader_path/../../external/` paths for relocatable
bundles.

**bundle-wine.sh** — Takes the build output and creates a distributable
`wine/` tree. Requires `--dest <dir>`. Pass `--runtime-only` to skip the
SDK/development files. Steps: staged install → flatten prefix → bundle
dylibs (copy, fix install names with `@loader_path`) → verify.

### Paths

Both scripts default to a sibling layout relative to this repo and can be
overridden via environment variables:

| Variable    | Default            | Used by                |
|-------------|--------------------|------------------------|
| `WINE_SRC`  | `../src`           | build                  |
| `BUILD_DIR` | `../build`         | build, bundle          |
| `MINGW_DIR` | `/opt/llvm-mingw`  | build, bundle          |

## Relocation strategy

Soname patching eliminates the need for `DYLD_FALLBACK_LIBRARY_PATH` and any
launcher binary. The `bin/` layout is left exactly as `make install` creates
it.

- **Soname patching**: `build-wine.sh --clean` patches `SONAME_LIB*` defines
  in `config.h` to use `@loader_path/../../external/<lib>` paths before
  compiling. This makes Wine's .so modules in `lib/wine/x86_64-unix/` find
  bundled dylibs in `lib/external/` via dyld's `@loader_path` resolution.
- **bin/ layout**: Unchanged from `make install` — `bin/wine` is Wine's
  standard preloader, convenience programs (winecfg, regedit, etc.) are
  symlinks to it.
- No `libexec/` directory. No `DYLD_FALLBACK_LIBRARY_PATH` needed.

## Key details

- All compilation uses `arch -x86_64` — this is an x86_64-only build running
  under Rosetta on Apple Silicon.
- Dependencies come from Homebrew x86_64 (`/usr/local/`), not ARM
  (`/opt/homebrew/`): `freetype gnutls sdl2-compat sdl3` plus `bison` ≥ 3.0
  and `pkgconf` as build tools.
- PE modules are cross-compiled with
  [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) (`MINGW_DIR`). Its
  `bin/` is **appended** to `PATH`, never prepended — it contains an
  unprefixed `clang` targeting MinGW that would break configure's host
  compiler detection.
- Configure uses a strict allowlist: every optional dependency is explicitly
  `--without-*` and only re-enabled via `--with-*`, so a missing package
  fails configure loudly instead of silently changing the feature set.
  Note: never pass `--with-opengl` on macOS — it triggers an EGL probe that
  always fails there; the Mac driver links `-framework OpenGL` on its own.
- Bundled dylibs go in `lib/external/` with install names rewritten to
  `@loader_path/`.
- The bundle script verifies no `/usr/local/` references leak into the final
  distribution and that the bundled `wine` runs.

## Releases

Releases are built by CI ([.github/workflows/release.yml](.github/workflows/release.yml))
on a `macos-15` runner, which mirrors the setup above (Apple Silicon +
Rosetta + x86_64 Homebrew).

[`wine-src.ref`](wine-src.ref) pins the branch, tag, or commit of
[athei/wine](https://github.com/athei/wine) that gets built.

Release tags follow the CrossOver version of the sources plus a build
revision: `cx-<crossover-version>-<revision>`, e.g. `cx-26.2.0-0` is the
first build based on CrossOver 26.2.0.

To cut a release:

1. Push the desired source state to a branch/tag on `athei/wine`.
2. Update `wine-src.ref` here to that ref and push to `main`.
3. Tag the commit: `git tag cx-26.2.0-0 && git push origin cx-26.2.0-0`.
4. CI builds the distribution and creates a **draft release** with
   `wine-cx-26.2.0-0-macos-x86_64.tar.xz` attached. Review and publish.
