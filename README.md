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
builds the two `d3d9_test.exe` binaries the bundle carries, and the ARM64X
link libraries: a second tree, configured with `arm64ec,aarch64` so the
archives carry both ARM64 and ARM64EC members, that yields only
`libwinecrt0.a` and `libntdll.a` under
`dist/wine-arm64x/lib/wine/aarch64-windows/`. They are for linking ARM64X PE
builtins that CrossOver's arm64 Wine will load, which ships no link archives
of its own. Nothing in that tree is runnable.

`bundle-wine.sh` turns the build output into a distributable `wine/` tree:
staged `make install`, prefix flattened, dylibs copied into `lib/external/`
with `@loader_path` install names, the Direct3D implementations and
`compatdb.so` installed, then a verification pass that ends by booting a
throwaway prefix. `--runtime-only` skips the SDK files and the test binaries;
that is the flavor that goes into an application.

`--compatdb-only` updates the bundle already at `<dest>/wine` instead of
building a new one: it builds `compatdb.so`, replaces the installed copy,
checks the new library for `/usr/local/` references and boots a prefix as a
full bundle does. There is no prompt, nothing is deleted, `make install` does
not run, and the Wine build directory is not needed, so it works on an
unpacked release tarball as well. It keeps whatever flavor the bundle already
has; `--runtime-only` is accepted next to it and ignored.

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

With `--compatdb-only`, `BUILD_DIR` only hosts cargo's target directory,
`$BUILD_DIR/compatdb`.

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

There are two kinds of release. Both attach a complete bundle as
`wine-<tag>-macos-x86_64.tar.xz` to a draft release, with the same `wine/`
layout, so a consumer does not need to tell them apart.

[.github/workflows/release.yml](.github/workflows/release.yml) builds Wine on
a GitHub-hosted Apple Silicon runner with Rosetta, the x86_64 dependency
prefix and llvm-mingw whenever a `cx-*` tag is pushed; the runner image and
the llvm-mingw version are set in the workflow. Tags are named after the
CrossOver version of the sources plus a build revision, so `cx-26.2.0-0` is
the first build from CrossOver 26.2.0. [`wine-src.ref`](wine-src.ref) pins the
branch, tag or commit of athei/wine that gets built. The bundle includes
`compatdb.so` built from the same commit of this repository, and the release
notes name that commit.

1. Push the desired source state to athei/wine.
2. Point `wine-src.ref` at it and push to `main`.
3. `git tag cx-26.2.0-0 && git push origin cx-26.2.0-0`.
4. Review and publish the draft release.

[.github/workflows/release-compatdb.yml](.github/workflows/release-compatdb.yml)
runs when a `compatdb-*` tag is pushed and does not build Wine. It downloads
the tarball of the newest published `cx-*` release (drafts and pre-releases
are never used), checks it against the digest GitHub recorded for the asset,
and runs `bundle-wine.sh --compatdb-only` on it with the tagged commit. It
takes a few minutes instead of hours. The release notes name the tagged commit
and the `cx-*` release the Wine came from. To use a different base, or to
build an existing tag again, run it by hand:

```bash
gh workflow run release-compatdb.yml -f tag=compatdb-2026-10-01 -f base=cx-26.3.0-6
```

`base` is optional and must be a published `cx-*` release. `gh release create`
refuses a tag that already has a release, so delete the old draft before
running it again for the same tag.

A change confined to `compatdb/` (new rules, a fix in the library) can go out
as `compatdb-*`. Anything that needs the Wine side to change, such as a new
ntdll export for compatdb to call or a new tree under `lib/wine`, needs a
`cx-*` release. Tag `cx-*` from a `main` that already contains the compatdb
changes, since that release builds `compatdb.so` from its own commit.

A published `compatdb-*` release can become the one GitHub marks as Latest.
Anything that fetches the latest release has to filter by tag prefix rather
than rely on that marker.

[`build-wine.sh`](build-wine.sh) exports a fixed `MACOSX_DEPLOYMENT_TARGET`,
and [`.cargo/config.toml`](.cargo/config.toml) sets the same value for
`compatdb.so`. Without the pin clang takes the deployment target from whatever
host is building, which made the tarball's macOS floor an accident of the
runner image: `cx-26.3.0-3` shipped `minos 15.0` off the `macos-15` runner
while a local build on macOS 27 produced `minos 26.0`. The SDK is still
whatever the build host has; only the minimum is fixed. Check this pin still
holds whenever the runner image is bumped.

The pin follows GPTK's D3DMetal, the default for 64-bit D3D10 to D3D12. It
links `libdxccontainer.dylib`, which needs a newer macOS than mtld3d and DXMT
do, so a lower floor buys nothing for the default setup. Wine picks up a
changed pin on the next `build-wine.sh --clean`, which is how CI always
builds.

The workflow does not install Homebrew. Homebrew has stopped shipping x86_64
macOS bottles (gmp, sdl2-compat and sdl3 have none at all, the rest stop at the
sonoma tag), so a runner would have to compile them from source: that took 48
minutes on `cx-26.3.0-3` and then stopped working altogether, because the
runners resolve neither `ftpmirror.gnu.org` nor `gmplib.org` and gmp's source
cannot be fetched there at all.

Instead [`package-deps.sh`](package-deps.sh) builds the x86_64 prefix once on a
machine that has an Intel Homebrew, and the result is mirrored as a release
asset that the workflow unpacks into `/usr/local`. It ships the packages
listed in `ROOTS` in [`package-deps.sh`](package-deps.sh) plus their runtime
closure, mostly taken from Homebrew's sonoma bottles, whose minimum macOS is
below every floor this repository pins.

gmp is the exception. It has no x86_64 bottle at all, so Homebrew compiles it
on whatever machine runs `package-deps.sh` and stamps it with that machine's
macOS: one packaging run produced a `libgmp` at `minos 26.0`, which would not
have loaded on anything older and would have taken gnutls down with it. The
script rebuilds gmp against its own `MACOS_FLOOR`, and then refuses to write
the archive if any Mach-O in the tree is newer than that floor. If another
formula loses its bottle, that check is what will catch it.

The `MACOS_FLOOR` set in [`package-deps.sh`](package-deps.sh) can be lower
than the deployment target in [`build-wine.sh`](build-wine.sh), and is.
Libraries built for an older macOS load in a Wine built for a newer one, so
the prefix only has to be no newer than Wine's floor, not equal to it. Raising
it would mean rebuilding and uploading the `deps-*` release for no gain.

To refresh it: `arch -x86_64 /usr/local/bin/brew upgrade` the formulae, run
`./package-deps.sh`, attach `dist/wine-deps-macos-x86_64.tar.xz` to a new
`deps-<date>` release, and point `DEPS_URL` and `DEPS_SHA256` in the workflow
at it. The one thing the prefix does not provide is `pkg-config`, which comes
from the runner image; the workflow fails loudly if it is missing rather than
building a Wine with the libraries silently absent.

## No-execute

Wine turned data execution prevention off for a whole process as soon as any
loaded module lacked the `NX_COMPAT` flag, a DLL included. Turning it off
makes every readable mapping executable for the rest of the process, and
under Rosetta each fresh writable and executable page costs a Mach round trip
on first touch, so a 32-bit program with one 2000s-era DLL turns into a fault
storm on every allocation
([#3](https://github.com/athei/wine-build/issues/3)). The patched tree
decides from the main executable alone, as Windows does: a DLL without the
flag changes nothing.

Under Rosetta no-execute is also permanently on, like the Windows AlwaysOn
policy: an executable without the flag keeps it, and a program that tries to
turn it off gets `STATUS_ACCESS_DENIED`. `WINE_DISABLE_NX_COMPAT=0` restores
the Windows behaviour for a game that really executes its data; any other
value keeps no-execute permanently on, on every host. A compatdb `env` rule
sets it per game.

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

The bundle step deletes the Vulkan and D3D12 modules that a
`--without-vulkan` build cannot back, rather than ship modules that advertise
an API they cannot serve. The list is in [`bundle-wine.sh`](bundle-wine.sh).

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
- `dpi_aware`: `true` makes the process DPI-aware (system-aware), `false`
  makes it unaware. The value is exactly `true` or `false`, case-sensitive.
  win32u applies a rule's value before it looks at the `AppCompatFlags\Layers`
  registry value and the manifest, and the first setting wins, so the rule
  beats both. Unset leaves the decision to them.
- `arguments`: text appended to the command line unless already present,
  which leaves a Chromium child that inherited its parent's switches alone.
- `env`: `NAME=value` entries written into the process's environment block
  and its unix environment; an empty value removes the variable.

Rules match on the image basename (case-insensitive, or `*` for every
process) plus optional case-insensitive substrings of the version resource's
`CompanyName`, `ProductName` and `OriginalFilename`. Every matching rule
applies, folded least specific first (wildcard, then basename, then
fingerprinted), so a scalar ends up with the most specific rule's value and
the lists accumulate.

The built-in rules are in
[`compatdb/src/builtin.rs`](compatdb/src/builtin.rs), each commented with the
reason it exists. Three of them, `no-vulkan`, `dpi-aware` and
`no-mono-gecko`, match every process (`exe` is `*`) and are described below.
The rest are pinned by version resource. They cover launchers that need a
real D3D10.1 device, which D3DMetal does not provide, embedded Chromium (CEF)
browsers whose GPU process cannot paint into another process's window under
winemac, and games that need a command-line switch to work around their own
detection code.

`no-vulkan` adds the override `vulkan-1=`, which disables the Vulkan loader.
The bundle has no Vulkan: Wine is built `--without-vulkan` and the bundle
step deletes the Vulkan modules (the list is in
[`bundle-wine.sh`](bundle-wine.sh)). A Vulkan loader that a game ships next
to its executable can therefore only fail. With the override, `vulkan-1.dll`
fails to load, and a game that has another renderer uses it.

`dpi-aware` sets `dpi_aware = true`, so every process under this build is
system-aware by default, including a plain `wine foo.exe`. An unaware program
on a scaled desktop gets its window and mouse coordinates scaled while display
modes are not, so a game that sizes itself from the mode list draws at one
size and reads the pointer at another. The default also caps a program that
asks for per-monitor awareness, by manifest or by its own call, at
system-aware, because the first context set for a process wins. A rule for
one executable with `dpi_aware=false` makes that program unaware again, and
`name=dpi-aware;enabled=false` restores upstream behaviour for every process:
the registry and the manifest decide.

`no-mono-gecko` adds the override `mscoree,mshtml=`, which keeps Wine from
prompting to install Mono and Gecko, in wineboot and in any process that
loads either. It is a separate rule so that disabling `no-vulkan` does not
bring the prompts back. The override disables both modules, not only the
prompts: ntdll consults the overrides compatdb adds before the registry
`DllOverrides` keys, so a wine-mono or Gecko installed in the prefix, or a
native .NET selected through the registry, stays disabled as well. A prefix
that needs one has two ways out: `name=no-mono-gecko;enabled=false`, or a
rule that adds `mscoree=n,b` (see [WINE_COMPATDB](#wine_compatdb)).

Several `*` rules are not a conflict. They are folded in table order, the
built-in ones first, and `duplicate_matchers` does not report them. That
order is also how a launch-wide override works: a `*` rule added through
`WINE_COMPATDB` comes after the built-in ones, so
`name=global;exe=*;dpi_aware=false` beats the `dpi-aware` default for every
process that no more specific rule covers.

#### WINE_COMPATDB

Whatever starts the process tree can add or change rules through the
`WINE_COMPATDB` environment variable. The value is a format header line
(`HEADER` in [`compatdb/table/src/lib.rs`](compatdb/table/src/lib.rs))
followed by one rule per line; each rule is `key=value` fields joined by `;`:

```
v=4
name=my-game;exe=Game.exe;company=Some Vendor;d3d9=wined3d;dpi_aware=false;env=MTLD3D_CONFIG=adapter.spoof=amd
name=rockstar-launcher;dxgi=dxmt
name=steam-web-helper;enabled=false
```

Keys: `name` (required), `exe`, `company`, `product`, `original_filename`,
`dxgi`, `d3d9`, `dpi_aware` (`true` or `false`), `dll_overrides`,
`arguments`, `env` (repeatable, value `NAME=value`) and `enabled`. A value
the library does not know for `dxgi`, `d3d9` or `dpi_aware` drops that rule
with a diagnostic; `dpi_aware` takes exactly `true` or `false`, so `TRUE` or
`1` is such a value. Inside a value, `%`, `;`, CR, LF and other control
characters are percent-encoded (`%3B` for `;`); everything else, including
`=`, passes through. A rule naming a built-in rule is merged into it (a set
scalar wins, lists append), so an override needs only the fields it changes;
`enabled=false` drops the rule of that name; a new rule needs an `exe`. A
malformed line is skipped, never fatal.

A header other than the one the library expects makes it ignore the whole
value with a diagnostic, which is what keeps a format change safe for
long-lived processes. It also means a `v=4` library drops the whole table of
a launcher that still sends `v=3`, so the launcher and `compatdb.so` have to
be updated together.

To let one game load its own Vulkan loader, give it a rule for its
executable that adds `vulkan-1=n`:

```
v=4
name=my-game;exe=Game.exe;dll_overrides=vulkan-1=n
```

The `*` rules are folded first, so the game's entry is added after
`vulkan-1=` and ntdll keeps the last entry for a module. To drop the built-in
rule for every process instead, use `name=no-vulkan;enabled=false`.
`WINEDLLOVERRIDES=vulkan-1=n` alone does not re-enable it: ntdll parses that
variable first, and an override compatdb adds replaces the entry for the same
module.

Mono and Gecko work the same way. A raw `WINEDLLOVERRIDES=mscoree=b` no
longer re-enables Mono, because the built-in `mscoree,mshtml=` replaces the
entry for the same module. A rule does:
`name=mono;exe=*;dll_overrides=mscoree=b` is folded after the built-in `*`
rules, and a rule for one executable is folded after every `*` rule. Use
`mscoree=n,b` instead to prefer a native .NET.
`name=no-mono-gecko;enabled=false` drops the built-in override for both
modules in every process, which hands the decision back to the registry.

The library writes `compatdb:` lines to wine's stderr: one block per process
with the image name, its version fingerprint, the rules that matched, the
trees it prepended, the overrides it added, the DPI awareness it set, and any
parse diagnostics. To confirm a tree took effect, look at the running
process's mapped files (`lsof -p <pid> | grep -i dxgi.dll`): a path under
`lib/wine/dxgi/<impl>/` or `lib/wine/d3d9/<impl>/` proves it.

### Where the files come from

[`redist.env`](redist.env) pins one URL and one SHA-256 per artifact.
`bundle-wine.sh` downloads each into `CACHE_DIR` and reuses the cached copy as
long as its checksum still matches the pin; a mismatch is an error, never a
silent re-download, so a bump changes both lines. The release workflow caches
the same directory keyed on the pin file's hash.

Before verification, the bundle step removes inherited `com.apple.quarantine`
attributes from the assembled `wine/` tree so macOS does not block a copied
library such as `winemetal.so`. Other attributes and code signatures are
preserved, and symlink targets outside the bundle are not touched. Failure to
remove quarantine stops the bundle step. Downloading the finished distribution
can apply quarantine again; this step only removes metadata inherited from
the build inputs.

DXMT and mtld3d come from their GitHub releases. Apple's Game Porting Toolkit
download needs an Apple ID session, so the unmodified dmg is attached to a
`gptk-<version>` release on this repository (those tags trigger neither
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
  `prepend_dll_path`, `add_load_order_override` and
  `set_compat_dpi_awareness` for it. The last one only stores the value;
  `dlls/win32u/sysparams.c` reads it through `ntdll_get_compat_dpi_awareness`
  when it first sets the process awareness. A `compatdb.so` running on an
  ntdll without the export logs that and ignores `dpi_aware`.
- `dlls/ntdll/loader.c` decides no-execute from the main executable alone
  instead of turning it off for the process as soon as any module lacks
  `NX_COMPAT`, and `dlls/ntdll/unix/process.c` keeps it permanently on under
  Rosetta; see [No-execute](#no-execute).
- `loader/wine.inf.in` registers `atidxx64.dll`, `nvapi64.dll` and
  `nvngx.dll` as fake DLLs.

### Caveats

- `macdrv_functions` is a private contract with no version field.
  `d3dmetal.c` asserts the sizes of `struct macdrv_functions_t` and
  `struct d3dmetal_macdrv_win_data`; a mismatch with a newer GPTK or DXMT
  drop is a crash inside their code, not an error message. Check it on every
  GPTK, DXMT or CrossOver bump.
- `init_non_native_support()` is gated on Sonoma or later, and D3DMetal
  needs a newer macOS than the rest of the bundle because it links
  `libdxccontainer.dylib`. That is what the deployment target in
  [`build-wine.sh`](build-wine.sh) follows.
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
