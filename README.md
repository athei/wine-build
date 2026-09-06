# wine-build

Scripts for building Wine from source on macOS as an x86_64 binary and
bundling it into a self-contained, relocatable distribution with WoW64
(i386+x86_64). Sources come from [athei/wine](https://github.com/athei/wine),
CrossOver Wine with custom patches on top. Direct3D does not go through
wined3d by default: the bundle ships Apple's D3DMetal, DXMT and mtld3d as
per-process selectable implementations, plus the small library that selects
them.

## Build pipeline

```bash
./build-wine.sh                       # Step 1: compile (arch -x86_64)
./bundle-wine.sh --dest /path/to/out  # Step 2: relocatable wine/ tree
```

`build-wine.sh` configures and compiles Wine into the build directory. It is
incremental; `--clean` wipes the build directory first, which is also the only
way to pick up changed configure flags. Before and after every build it makes
sure the sonames in `config.h` point at `@loader_path/../../external/`, since
`config.status` silently regenerates the file after a source update. It also
builds the two `d3d9_test.exe` binaries the bundle carries, and a second,
arm64ec+aarch64 configured tree that yields only `libwinecrt0.a` and
`libntdll.a` under `dist/wine-arm64ec/lib/wine/aarch64-windows/`: link
libraries for arm64ec builtins that CrossOver's arm64 Wine will load, nothing
runnable.

`bundle-wine.sh` turns the build output into a distributable `wine/` tree:
staged `make install`, prefix flattened, dylibs copied into `lib/external/`
with `@loader_path` install names, the Direct3D implementations and
`compatdb.so` installed, then a verification pass that ends by booting a
throwaway prefix. `--runtime-only` skips the SDK files and the test binaries;
that is the flavor that goes into an application.

The `d3d9_test.exe` binaries land in `lib/wine/tests/{i386,x86_64}-windows/`,
outside the directories the loader searches, and are plain PEs. Wine's
`dlls/d3d9/tests` is the de-facto D3D9 conformance suite, so a consumer
(mtld3d's CI) can gate its own `d3d9.dll` against it with nothing but this
bundle.

### Paths

| Variable    | Default           | Used by       |
|-------------|-------------------|---------------|
| `WINE_SRC`  | `../src`          | build         |
| `BUILD_DIR` | `../build`        | build, bundle |
| `MINGW_DIR` | `/opt/llvm-mingw` | build, bundle |
| `CACHE_DIR` | `../cache`        | bundle        |

### Requirements

- Apple Silicon with Rosetta, or an Intel Mac. Everything compiles under
  `arch -x86_64`.
- x86_64 Homebrew in `/usr/local/` (not the ARM one in `/opt/homebrew/`):
  `freetype gnutls sdl2-compat sdl3`, plus `bison` 3.0 or newer and `pkgconf`.
- [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) at `MINGW_DIR` for the
  PE modules. Its `bin/` is appended to `PATH`, never prepended: it carries an
  unprefixed `clang` targeting MinGW that would break configure's host compiler
  detection.
- A Rust toolchain with the `x86_64-apple-darwin` target, for `compatdb.so`.

Configure uses a strict allowlist: every optional dependency is `--without-*`
and only re-enabled with `--with-*`, so a missing package fails configure
loudly instead of silently changing the feature set. Never pass
`--with-opengl` on macOS; it triggers an EGL probe that always fails there,
and the Mac driver links `-framework OpenGL` on its own. Vulkan is off
(`--without-vulkan`): nothing in the bundle needs it, and wined3d serves D3D8
and DDraw through its GL backend.

## Relocation

`build-wine.sh` patches the `SONAME_LIB*` defines in `config.h` to
`@loader_path/../../external/<lib>` before compiling, so Wine's `.so` modules
in `lib/wine/x86_64-unix/` find the bundled dylibs in `lib/external/` through
dyld alone. The bundle step then copies each dylib and its `/usr/local`
closure into `lib/external/`, rewrites their install names to `@loader_path/`,
and verifies that no `/usr/local/` reference survives. There is no launcher
binary and no `DYLD_FALLBACK_LIBRARY_PATH`; `bin/` is exactly what
`make install` creates, `bin/wine` being the preloader and the convenience
programs symlinks to it.

## Releases

[.github/workflows/release.yml](.github/workflows/release.yml) builds on a
`macos-26` runner (Apple Silicon, Rosetta, x86_64 Homebrew, pinned llvm-mingw)
whenever a `cx-*` tag is pushed and attaches
`wine-<tag>-macos-x86_64.tar.xz` to a draft release. Tags are named after the
CrossOver version of the sources plus a build revision, so `cx-26.2.0-0` is
the first build from CrossOver 26.2.0. [`wine-src.ref`](wine-src.ref) pins the
branch, tag or commit of athei/wine that gets built.

1. Push the desired source state to athei/wine.
2. Point `wine-src.ref` at it and push to `main`.
3. `git tag cx-26.2.0-0 && git push origin cx-26.2.0-0`.
4. Review and publish the draft release.

Homebrew has stopped building x86_64 macOS bottles, so the Rosetta Homebrew at
`/usr/local` would compile gmp, gnutls, sdl2-compat and sdl3 from source on
every run, which is around 50 minutes and depends on gmplib.org staying up. The
workflow caches the whole `/usr/local` prefix under a fixed key instead. An
existing cache key is never overwritten, so bump the `-v1` in
`Cache x86_64 Homebrew` by hand whenever the formula list changes, or the new
formula will not be there.

## No-execute

Wine turned data execution prevention off for a whole process as soon as any
loaded module lacked the `NX_COMPAT` flag, a DLL included. Turning it off
makes every readable mapping executable for the rest of the process, and
under Rosetta each fresh writable and executable page costs a Mach round trip
on first touch, so a 32-bit program with one 2000s-era DLL turns into a fault
storm on every allocation
([#3](https://github.com/athei/wine-build/issues/3)). The patched tree
decides from the main executable alone, as Windows does: a DLL without the
flag changes nothing. `WINE_DISABLE_NX_COMPAT=1` keeps no-execute on even
when the executable itself lacks the flag; a compatdb `env` rule sets it per
game.

## Direct3D

Every Direct3D implementation lives in its own tree under `lib/wine`, and the
default `<arch>-windows` directories hold only fake-module markers for the
DLLs involved. `compatdb.so` prepends one tree per API family to the builtin
search path of every process, so a process sees exactly one coherent set of
modules, nothing is ever mixed, and switching is purely additive.

There are two families because D3D10, D3D10.1, D3D11 and D3D12 all create
their device through one `dxgi.dll` and only work with their own
implementation's copy, while neither D3D9 implementation touches DXGI at all.
D3D8 and DDraw have no alternative to wined3d and stay in the default dirs.

| Family | Tree | Contents | Default |
|--------|------|----------|---------|
| `dxgi` | `lib/wine/dxgi/gptk/` | Apple D3DMetal: dxgi, d3d10, d3d11, d3d12, nvapi64, nvngx; plus Wine's d3d10core and d3d10_1, which return `E_FAIL` on its dxgi but keep D3D10 probes from failing to load. x86_64 only. | x86_64 |
| `dxgi` | `lib/wine/dxgi/dxmt/` | DXMT: dxgi, d3d10core, d3d11, winemetal for both arches; plus Wine's d3d10 and d3d10_1. | i386 |
| `dxgi` | `lib/wine/dxgi/wined3d/` | Wine's dxgi, d3d10, d3d10core, d3d10_1, d3d11 for both arches. No d3d12, which needs Vulkan. | |
| `d3d9` | `lib/wine/d3d9/mtld3d/` | [mtld3d](https://github.com/athei/mtld3d): d3d9 and mtld3d for both arches, one x86_64 `mtld3d.so`. | both |
| `d3d9` | `lib/wine/d3d9/wined3d/` | Wine's d3d9 for both arches. Needs only `wined3d.dll`, which is in the default dir. | |

Each tree has `<arch>-windows/` and, where the implementation has a unix half,
`x86_64-unix/`. D3DMetal's unix modules are symlinks to
`lib/external/libd3dshared.dylib`; DXMT's and mtld3d's single x86_64 `.so`
also serves the i386 PE modules through wow64 entry points. `winemetal.so`
stays in `lib/wine/x86_64-unix/` as the shared DXMT backend. `nvngx` is
Apple's `nvngx-on-metalfx`, renamed because that is the name games load when
they probe for DLSS.

The bundle step deletes what a `--without-vulkan` build can no longer serve:
`vulkan-1` and `winevulkan` on both arches, `d3d12`/`d3d12core` for i386 and
`d3d12core` for x86_64.

### compatdb.so

`lib/wine/x86_64-unix/compatdb.so` is built from the [`compatdb/`](compatdb)
crate in this repository (a Cargo workspace: `compatdb-table` holds the pure
rule logic, `compatdb` the cdylib around it). Wine's ntdll dlopens
`<ntdll_dir>/compatdb.so` in every process before any PE code runs, the slot
CrossOver's own compat database uses. The library reads the process's image
name and version resource, resolves the rules that match, and applies them:

- `dxgi` and `d3d9`: which tree to prepend. Unset means the defaults in the
  table above. An implementation that does not exist for the process's
  architecture (`gptk` on i386) degrades to that architecture's default with
  a log line, so `dxgi = gptk` in a rule reads as "GPTK where it exists".
- `dll_overrides`: `WINEDLLOVERRIDES`-style `names=order` entries, added
  through ntdll's load-order hook.
- `arguments`: text appended to the command line unless already present,
  which leaves a Chromium child that inherited its parent's switches alone.
- `env`: `NAME=value` entries written into the process's environment block
  and its unix environment; an empty value removes the variable.

Rules match on the image basename (case-insensitive, or `*` for every
process) plus optional case-insensitive substrings of the version resource's
`CompanyName`, `ProductName` and `OriginalFilename`. Every matching rule
applies, folded least specific first (wildcard, then basename, then
fingerprinted), so a scalar ends up with the most specific rule's value and
the lists accumulate. The built-in rules, all pinned by version resource:

- `rockstar-launcher` (`Launcher.exe`, Rockstar Games): `dxgi = wined3d`,
  because the launcher needs a real D3D10.1 device and D3DMetal has none.
- `rockstar-social-club-ui` (`SocialClubHelper.exe`, Take-Two):
  `--in-process-gpu`, since a CEF GPU process cannot paint into another
  process's window under winemac.
- `steam-web-helper` (`steamwebhelper.exe`, Valve): `--in-process-gpu
  --disable-gpu --disable-software-rasterizer`, the same problem plus GPU
  rendering off.
- `gta-iv` (`GTAIV.exe`, Rockstar Games): `-availablevidmem 2048.0`, which
  overrides the game's broken video-memory detection.

#### WINE_COMPATDB

Whatever starts the process tree can add or change rules through the
`WINE_COMPATDB` environment variable. The value is a `v=3` header line
followed by one rule per line; each rule is `key=value` fields joined by `;`:

```
v=3
name=my-game;exe=Game.exe;company=Some Vendor;d3d9=wined3d;env=MTLD3D_CONFIG=adapter.spoof=amd
name=rockstar-launcher;dxgi=dxmt
name=steam-web-helper;enabled=false
```

Keys: `name` (required), `exe`, `company`, `product`, `original_filename`,
`dxgi`, `d3d9`, `dll_overrides`, `arguments`, `env` (repeatable, value
`NAME=value`) and `enabled`. Inside a value, `%`, `;`, CR, LF and other
control characters are percent-encoded (`%3B` for `;`); everything else,
including `=`, passes through. A rule naming a built-in rule is merged into it
(a set scalar wins, lists append), so an override needs only the fields it
changes; `enabled=false` drops the rule of that name; a new rule needs an
`exe`. A header other than `v=3` makes the library ignore the whole value with
a diagnostic, which is what keeps a format change safe for long-lived
processes. A malformed line is skipped, never fatal.

The library writes `compatdb:` lines to wine's stderr: one block per process
with the image name, its version fingerprint, the rules that matched, the
trees it prepended, the overrides it added, and any parse diagnostics. To
confirm a tree took effect, look at the running process's mapped files
(`lsof -p <pid> | grep -i dxgi.dll`): a path under `lib/wine/dxgi/<impl>/` or
`lib/wine/d3d9/<impl>/` proves it.

### Where the files come from

[`redist.env`](redist.env) pins one URL and one SHA-256 per artifact.
`bundle-wine.sh` downloads each into `CACHE_DIR` and reuses the cached copy as
long as its checksum still matches the pin; a mismatch is an error, never a
silent re-download, so a bump changes both lines. The release workflow caches
the same directory keyed on the pin file's hash.

DXMT and mtld3d come from their GitHub releases. Apple's Game Porting Toolkit
download needs an Apple ID session, so the unmodified dmg is attached to a
`gptk-<version>` release on this repository (those tags do not trigger the
release workflow) and the pin points there; upgrading means downloading the
new image by hand and creating a new `gptk-*` release. Apple's license
(shipped as `lib/external/D3DMetal-License.rtf`) allows distributing the
Redistributables unmodified for non-commercial purposes, which is why the
files are copied byte for byte: no `install_name_tool`, no re-signing, and the
dylib closure walk never touches them, which is why the Direct3D step runs
after the dylib step.

### What the Wine side provides

The patched tree at athei/wine carries the glue:

- `dlls/winemac.drv/d3dmetal.c` exports `macdrv_functions`, the window, Metal
  and monitor helpers D3DMetal and DXMT `dlsym` out of `winemac.so`.
- `dlls/ntdll/ntdll.spec` exports `__wine_unix_call`, which D3DMetal's PE
  halves look up at runtime.
- `dlls/ntdll/unix/loader.c` `init_non_native_support()` dlopens
  `libd3dshared.dylib` and records its `__TEXT` range, which selects the
  ms-ABI unix call entry for calls arriving from Apple code; without it they
  take the sysv entry and crash. It defaults to
  `<ntdll_dir>/../../external/libd3dshared.dylib`, with
  `CX_APPLEGPTK_LIBD3DSHARED_PATH` as an override, and runs on the first
  native PE load.
- `dlls/ntdll/unix/loader.c` dlopens `compatdb.so` and exports
  `prepend_dll_path` and `add_load_order_override` for it.
- `dlls/ntdll/loader.c` decides no-execute from the main executable alone
  instead of turning it off for the process as soon as any module lacks
  `NX_COMPAT`; see [No-execute](#no-execute).
- `loader/wine.inf.in` registers `atidxx64.dll`, `nvapi64.dll` and
  `nvngx.dll` as fake DLLs.

### Caveats

- `macdrv_functions` is a private contract with no version field.
  `d3dmetal.c` asserts `sizeof(struct macdrv_functions_t) == 192` and
  `sizeof(struct d3dmetal_macdrv_win_data) == 120`; a mismatch with a newer
  GPTK or DXMT drop is a crash inside their code, not an error message. Check
  it on every GPTK, DXMT or CrossOver bump.
- `init_non_native_support()` is gated on Sonoma or later, and GPTK 4.0 wants
  macOS 15.
- D3DMetal's client surface goes through `get_win_data(hwnd)`, so it is
  same-process only. Cross-process presentation (Steam's CEF GPU process
  drawing into the browser window) still needs `--in-process-gpu`.
- A builtin only loads if its placeholder exists in the prefix, and wineboot
  stamps placeholders for what is in `lib/wine/<arch>-windows` when the prefix
  is created. The markers in the default dirs cover every DLL the trees
  supply, so a new prefix is complete; a builtin name added later (a
  development install of mtld3d into `lib/wine/d3d9/mtld3d/`, or a mod) needs
  a `wineboot -u` only if its name is new. A bundle redeploy wipes `lib/wine`,
  so such additions have to be reinstalled after one.
