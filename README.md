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
build directory first for a full rebuild. Before (and after) every build it
ensures the sonames in `config.h` are patched to
`@loader_path/../../external/` paths for relocatable bundles — re-applying
the patch if `config.status` regenerated `config.h`, e.g. after a source
update. It also builds the two `d3d9_test.exe` binaries that the bundle carries,
naming that target explicitly rather than leaning on the toplevel `all`, which
produces them only as a side effect of `programs/winetest`.

**bundle-wine.sh** — Takes the build output and creates a distributable
`wine/` tree. Requires `--dest <dir>`. Pass `--runtime-only` to skip the
SDK/development files. Steps: staged install → flatten prefix → bundle d3d9
test binaries → bundle dylibs (copy, fix install names with `@loader_path`) →
download (cached) and install the Direct3D backends → verify.

The d3d9 test binaries land in `lib/wine/tests/{i386,x86_64}-windows/`, outside
the per-arch module directories the loader searches, and are not builtin-marked:
`wine` executes them as ordinary PEs. Wine's `dlls/d3d9/tests` is the de-facto
D3D9 conformance suite, so shipping it lets a consumer (mtld3d) gate its own
`d3d9.dll` builtin against the suite with nothing but this bundle, which is what
a CI job has. Skipped for `--runtime-only`, where the bundle goes into an
application.

### Paths

Both scripts default to a sibling layout relative to this repo and can be
overridden via environment variables:

| Variable     | Default            | Used by                |
|--------------|--------------------|------------------------|
| `WINE_SRC`   | `../src`           | build                  |
| `BUILD_DIR`  | `../build`         | build, bundle          |
| `MINGW_DIR`  | `/opt/llvm-mingw`  | build, bundle          |
| `CACHE_DIR`  | `../cache`         | bundle                 |

## Relocation strategy

Soname patching eliminates the need for `DYLD_FALLBACK_LIBRARY_PATH` and any
launcher binary. The `bin/` layout is left exactly as `make install` creates
it.

- **Soname patching**: `build-wine.sh` patches `SONAME_LIB*` defines
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
- Configured `--without-vulkan`. Nothing in the bundle needs it: D3D9-12 go
  through D3DMetal, DXMT and mtld3d (see Direct3D below), and wined3d falls
  back to its GL backend for D3D8 and older.
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

## Direct3D

D3D9, D3D10, D3D11 and D3D12 do not go through wined3d. Three third-party
implementations that target Metal directly are installed over Wine's own
builtins by `bundle-wine.sh`:

- **D3DMetal**, from Apple's Game Porting Toolkit, covers `d3d10`, `d3d11`,
  `d3d12` and `dxgi` for x86_64.
- **DXMT** covers `d3d10core`, `d3d11` and `dxgi` for i386, which Apple does
  not ship.
- **[mtld3d](https://github.com/athei/mtld3d)** covers `d3d9` for both
  architectures.

wined3d stays, but only D3D8 and DDraw still reach it. With nothing left that
needs a Vulkan backend, the build is configured `--without-vulkan` and the
bundle step deletes the modules that could no longer work: `vulkan-1` and
`winevulkan` on both architectures, plus `d3d12`/`d3d12core` for i386 and
`d3d12core` for x86_64.

| Path | Source |
|------|--------|
| `lib/external/D3DMetal.framework`, `libd3dshared.dylib` | D3DMetal |
| `lib/wine/x86_64-unix/{d3d10,d3d11,d3d12,dxgi,nvapi64,nvngx}.so` | D3DMetal (symlinks to `../../external/libd3dshared.dylib`) |
| `lib/wine/x86_64-windows/{d3d10,d3d11,d3d12,dxgi,nvapi64,nvngx}.dll` | D3DMetal |
| `lib/wine/i386-windows/{d3d10core,d3d11,dxgi,winemetal}.dll` | DXMT |
| `lib/wine/x86_64-unix/winemetal.so` | DXMT |
| `lib/wine/{i386,x86_64}-windows/{d3d9,mtld3d}.dll` | mtld3d |
| `lib/wine/x86_64-unix/mtld3d.so` | mtld3d |

`nvngx` is Apple's `nvngx-on-metalfx`, renamed on install because that is the
name games load when they probe for DLSS; it maps onto MetalFX. There is no
i386 unix half for either DXMT or mtld3d: a single x86_64 `.so` serves the
32-bit PE modules through its wow64 entry points. mtld3d's `d3d9.dll` is the
builtin-marked flavor that replaces Wine's own; its tarball's native-override
variant, prefix markers and arm64 `.so` are not installed.

### Where the files come from

[`redist.env`](redist.env) pins one URL and one SHA-256 per artifact.
`bundle-wine.sh` downloads each into `CACHE_DIR` (`../cache` by default) and
reuses the cached copy on later runs as long as its checksum still matches
the pin; a mismatch is an error, never a silent re-download. Bumping a version
means changing both the URL and the checksum. The release workflow caches the
same directory keyed on the pin file's hash, so CI only downloads after a
bump.

DXMT and mtld3d come straight from their GitHub releases. The GPTK image
cannot: Apple's download needs an Apple ID session, so the unmodified dmg is
attached to a `gptk-<version>` release on this repository and the pin points
there. Upgrading it means downloading the new image by hand, creating a new
`gptk-*` release with it (those tags do not trigger the release workflow), and
repointing the pin. The image is mounted read-only and its `redist/lib`
located by search rather than by volume name.

Apple's license (`License.rtf`, shipped as `lib/external/D3DMetal-License.rtf`)
allows distributing the Redistributables unmodified for non-commercial
purposes, which is what covers both the mirror and the bundle. The files are
therefore copied byte for byte: no `install_name_tool`, no re-signing, and the
bundle's `/usr/local` closure walk never touches them, which is why the
Direct3D step runs after the dylib step rather than inside it.

### What the Wine side provides

The patched tree at [athei/wine](https://github.com/athei/wine) carries the
glue both implementations bind to:

- `dlls/winemac.drv/d3dmetal.c` exports `macdrv_functions`, a struct of window,
  Metal device/view/layer, registry and monitor helpers. D3DMetal and DXMT both
  `dlsym` it out of `winemac.so`.
- `dlls/ntdll/ntdll.spec` exports `__wine_unix_call` as a callable function
  (implemented as `__wine_unix_call_exported` in `dlls/ntdll/loader.c`).
  D3DMetal's PE halves look that name up at runtime; ordinary builtins get the
  call from `winecrt0` and never need the export.
- `dlls/ntdll/unix/loader.c` `init_non_native_support()` dlopens
  `libd3dshared.dylib` and records its `__TEXT` range, which `unix_private.h`
  uses to pick the ms-ABI unix call entry for calls arriving from Apple code.
  Without it those calls take the sysv entry and crash. It defaults to
  `<ntdll_dir>/../../external/libd3dshared.dylib` so the bundle needs no
  environment setup; `CX_APPLEGPTK_LIBD3DSHARED_PATH` still overrides it. It
  runs on the first native PE load, so a game triggers it via its own exe.
- `loader/wine.inf.in` registers `atidxx64.dll`, `nvapi64.dll` and `nvngx.dll`
  as fake DLLs.

### Caveats

- `macdrv_functions` is a private contract with no version field.
  `d3dmetal.c` asserts `sizeof(struct macdrv_functions_t) == 192` and
  `sizeof(struct d3dmetal_macdrv_win_data) == 120`; a mismatch with a newer
  GPTK or DXMT drop is a crash inside their code, not an error message. Check
  it on every GPTK, DXMT or CrossOver bump.
- `init_non_native_support()` is gated on Sonoma or later, and GPTK 4.0 itself
  wants macOS 15.
- D3DMetal's client surface goes through `get_win_data(hwnd)`, so it is
  same-process only. It does not fix cross-process presentation (Steam's CEF
  GPU process drawing into the browser window); that still needs
  `--in-process-gpu`.
- Every builtin has to be in `lib/wine/` before a prefix is created. Outside
  prefix bootstrap a builtin only loads if a file exists at the Windows path
  (`is_builtin_path()` returns FALSE once `is_prefix_bootstrap` is clear), and
  the `11,,*` wildcard in `wine.inf` only creates fake DLLs for what is present
  when wineboot runs. The bundled mtld3d release is in place from the start;
  anything added later (a development `make install` from the mtld3d tree,
  which overrides the bundled copy, or wow-mods) needs a `wineboot -u` if it
  brings a new builtin name. A bundle redeploy wipes `lib/wine`, so such
  additions have to be reinstalled after one.
