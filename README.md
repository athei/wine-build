# wine-build

Builds a native arm64 Wine for macOS from
[athei/wine](https://github.com/athei/wine), upstream Wine with our own
series, and bundles it into a self-contained, relocatable `wine/` tree. x86
programs, i386 and x86_64, run under [FEX](https://github.com/FEX-Emu/FEX)
in the same process. Direct3D goes through per-process selectable
implementations (DXMT, mtld3d, wined3d), chosen by `compatdb.so`, a library
built from [`compatdb/`](compatdb). Direct3D 12 is vkd3d-proton on Vulkan.

- [docs/arm64.md](docs/arm64.md): how the build works: the sources, FEX,
  DXMT, vkd3d-proton, Vulkan, the signed loader app, what the bundle step
  checks.
- [docs/compatdb.md](docs/compatdb.md): rules, `WINE_COMPATDB`, recipes,
  logging.
- [docs/maintenance.md](docs/maintenance.md): internals, floors, pins,
  upgrade checklist.

## Getting a build

The `arm64-*` [releases](https://github.com/athei/wine-build/releases)
carry the bundle and, in a second archive, its PE files before their
symbols were stripped. The [release workflow](.github/workflows/release.yml)
builds them, and a `compatdb-*` release is the bundle of an `arm64-*` one
with only `compatdb.so` replaced ([releases](docs/maintenance.md#releases)).
The loader is signed by a certificate of the team that the provisioning
profile in [`signing/`](signing) belongs to
([loader app](docs/arm64.md#loader-app)). To build the bundle locally, see
[Building](#building).

The `cx-*` releases are the x86_64 Wine this repository built before, run
under Rosetta. They are frozen and kept for comparison.

The minimum macOS is `MACOS_FLOOR` in [`profile.sh`](bin/lib/profile.sh).

## Bundle layout

| Path | Contents |
|------|----------|
| `bin/` | What `make install` creates; `bin/wine` is a symlink to the loader in `wine.app` |
| `lib/wine/aarch64-windows/`, `lib/wine/i386-windows/` | Wine's PE modules, FEX's emulator DLLs (also as `xtajit.dll` and `xtajit64.dll`, the names Wine loads), and fake-module markers for the Direct3D DLLs |
| `lib/wine/aarch64-unix/` | Wine's unix modules, `compatdb.so`, DXMT's `winemetal.so` and FEX's unix halves |
| `lib/wine/aarch64-unix/wine.app/` | The loader, its `Info.plist` and the embedded provisioning profile ([loader app](docs/arm64.md#loader-app)) |
| `lib/wine/dxgi/<impl>/`, `lib/wine/d3d9/<impl>/` | One tree per Direct3D implementation (see [Direct3D backends](#direct3d-backends)) |
| `lib/wine/x86_64-windows/` | Full bundle only: the x86_64 link libraries of the [Wine SDK](docs/arm64.md#wine-sdk). Nothing reads the directory at run time |
| `lib/wine/tests/i386-windows/`, `lib/wine/tests/x86_64-windows/` | Full bundle only: Wine's graphics conformance tests as `<name>_test.exe`, for testing the bundle's Direct3D, OpenGL and Vulkan stack ([graphics tests](docs/arm64.md#graphics-tests)) |
| `lib/wine/tests/VERSION` | Full bundle only: one line, the `wine --version` string of the Wine the tests were built from, the same as the bundle's own `bin/wine --version` |
| `lib/external/` | Bundled dylibs, the Vulkan loader, KosmicKrisp, and Mesa's EGL with Zink ([OpenGL](docs/arm64.md#opengl)) |
| `share/vulkan/icd.d/` | KosmicKrisp's manifest, naming the driver by a path relative to the manifest |

An x64 process runs as ARM64EC, and Wine looks up its builtins in
`aarch64-windows`, so the 64-bit modules of every Direct3D tree live under
`<impl>/aarch64-windows/`. They are all ARM64X, so the default-dir markers
of their names are hybrid ones, which x64 and native ARM64 processes both
accept, and the bundle step fails on any file in an `aarch64-windows`
directory that an x64 process would load but not run natively
([Direct3D trees](docs/maintenance.md#direct3d-trees)).

## Runtime configuration

### Environment variables

| Variable | Effect |
|----------|--------|
| `WINE_COMPATDB` | Extra or changed compatdb rules for the whole process tree. Format: [docs/compatdb.md](docs/compatdb.md#wine_compatdb) |
| `WINEDLLOVERRIDES` | Works as in Wine, but cannot undo an override compatdb adds; use a rule ([recipes](docs/compatdb.md#recipes)) |
| `WINEMSYNC` | Unset or a non-zero number: msync is on. Any other value (`0`, empty, not a number): off, and Wine synchronizes through wineserver requests as upstream Wine does. Only the wineserver reads it ([runtime](docs/arm64.md#runtime)) |
| `WINENCPU` | Limits the number of processors Wine reports to programs, for those that misbehave with many. A value of 0, one that is not a number, or one above the real count is ignored ([runtime](docs/arm64.md#runtime)) |
| `FEX_HARDWARE_TSO` | Unset or `1`: FEX runs x86 code with the hardware x86 memory ordering (TSO) instead of emulating it with ordered loads and stores. The ordering is a per-thread mode: FEX switches a thread to it whenever the thread enters x86 code and back at the syscalls and unix calls of x86 code, since native code runs slower in it. `0`: FEX emulates the ordering. Any other value logs an error and FEX emulates the ordering |
| `FEX_HOSTFEATURES` | FEX's host feature overrides. x86_64 programs, which run as ARM64EC, run without AFP (the Arm floating-point behaviour FEX uses to match x86) by default, because the floating-point mode would have to change on every call between x86 code and native code, which costs more than AFP saves. `enableafp` turns it back on. i386 programs keep AFP |
| `VK_DRIVER_FILES` | Unset: ntdll sets it to the bundle's `share/vulkan/icd.d`, so the Vulkan loader uses the bundled KosmicKrisp and no driver installed elsewhere on the Mac. Set: the loader uses the manifests it names instead. ntdll also leaves it unset when the caller sets `VK_ICD_FILENAMES` or `VK_ADD_DRIVER_FILES`; the loader then uses those, and the bundled driver is not added to them ([Vulkan](docs/arm64.md#vulkan)) |
| `MESA_KK_EXPERIMENTAL` | Which of Mesa's own experimental features KosmicKrisp advertises. The features Direct3D 12 and OpenGL through Zink need are always on in this build, whatever it says ([Vulkan](docs/arm64.md#vulkan)) |
| `VKD3D_CONFIG`, `VKD3D_DEBUG` and vkd3d-proton's other variables | vkd3d-proton's settings, as [upstream](https://github.com/HansKristian-Work/vkd3d-proton#readme) describes them. A compatdb `env` rule sets one for one game ([recipes](docs/compatdb.md#recipes)). compatdb's built-in `vkd3d-proton-min-latency` rule sets `VKD3D_SWAPCHAIN_MIN_LATENCY_FRAMES` in every process that does not have it already, so a value exported where the process starts wins ([environment defaults](docs/compatdb.md#environment-defaults)) |
| `WINE_D3D_CONFIG` | wined3d's settings, as in Wine. `renderer=vulkan` puts wined3d on KosmicKrisp. compatdb's `wined3d=vulkan` sets it for one game, keeping the variable's other options; the programs that game starts inherit it unless a rule for them sets `wined3d` ([wined3d on Vulkan](docs/compatdb.md#wined3d-on-vulkan)) |

### Direct3D backends

| Family | APIs | Rule value | Tree | Chosen by |
|--------|------|------------|------|-----------|
| `dxgi` | D3D10, D3D11, D3D12 | `dxmt` ([DXMT](https://github.com/athei/dxmt), D3D12 from [vkd3d-proton](https://github.com/athei/vkd3d-proton)) | `lib/wine/dxgi/dxmt/` | The built-in rule `dxmt`, for every process |
| `dxgi` | D3D10, D3D10.1, D3D11 | `wined3d` | `lib/wine/dxgi/wined3d/` | A rule that asks for it, or no rule at all, as in upstream Wine |
| `d3d9` | D3D9 | `mtld3d` ([mtld3d](https://github.com/athei/mtld3d)) | `lib/wine/d3d9/mtld3d/` | The built-in rule `mtld3d`, for every process |
| `d3d9` | D3D9 | `wined3d` | `lib/wine/d3d9/wined3d/` | A rule that asks for it, or no rule at all, as in upstream Wine |

- compatdb.so prepends one tree per family to every process's builtin search
  path, so a process sees one coherent set of modules. To pick a tree per
  game, see [recipes](docs/compatdb.md#recipes).
- The default directories hold only fake-module markers for the Direct3D
  DLLs, so a process gets Direct3D only through the tree compatdb.so
  prepends. The bundle always ships `compatdb.so`; a process without it has
  no Direct3D.
- D3D10, D3D11 and D3D12 form one family because they create their device
  or swapchain through one `dxgi.dll` and only work with their own
  implementation's copy.
- D3D12 is vkd3d-proton, which runs on Vulkan, on KosmicKrisp. Its DLLs sit
  in the `dxmt` tree, and DXMT's `dxgi.dll` presents its swapchains
  ([vkd3d-proton](docs/arm64.md#vkd3d-proton)). The `wined3d` tree has no
  D3D12: a game that a rule gives `dxgi=wined3d` cannot load `d3d12.dll`.
  Wine's own D3D12 is left out of the bundle.
- A game that can use both D3D12 and D3D11 and prefers D3D12 gets
  vkd3d-proton instead of DXMT's D3D11. A rule can hide D3D12 from one
  game and keep DXMT ([recipes](docs/compatdb.md#recipes)).
- DXMT's, vkd3d-proton's and mtld3d's 64-bit modules are ARM64X: an x64
  game loads their ARM64EC half and a native ARM64 program their ARM64
  half, so they run natively in either, and only their i386 modules run
  under FEX with the game ([DXMT](docs/arm64.md#dxmt),
  [vkd3d-proton](docs/arm64.md#vkd3d-proton),
  [mtld3d](docs/arm64.md#mtld3d)).
- A native ARM64 program gets the same trees, DXMT for `dxgi` and mtld3d
  for `d3d9`, and a rule can give it either tree of each family
  ([native ARM64 programs](docs/compatdb.md#native-arm64-programs)). It
  can load a Direct3D name only where its marker is a hybrid one, which
  every name has while every tree is ARM64X
  ([limitations](docs/arm64.md#limitations)).
- D3D8 and DirectDraw stay on wined3d. Which modules each tree holds is in
  Step 4 of [`bundle-wine.sh`](bin/bundle-wine.sh).
- wined3d draws through OpenGL. The compatdb setting `wined3d` can put it
  on Vulkan for one game; it applies to every wined3d user in the process
  ([wined3d on Vulkan](docs/compatdb.md#wined3d-on-vulkan)).

### Defaults that differ from Wine

Each row decided by a rule is a built-in compatdb rule that matches every
process and can be changed per game or globally. The other rows are not
compatdb rules, on purpose: msync is the wineserver's, which starts before
compatdb.so loads in any process; FEX's memory ordering and AFP are
emulator settings, not compatibility settings; KosmicKrisp's features are
what Direct3D 12 and OpenGL through Zink need, so nothing turns them off;
and the Vulkan driver choice keeps the bundle self-contained, so it is
ntdll's, before any rule.

| Behavior | Default in this bundle | Decided by |
|----------|------------------------|------------|
| D3D10, D3D11 and D3D12 | DXMT, and vkd3d-proton for D3D12, instead of wined3d, which has no D3D12 here | Rule `dxmt` ([Direct3D backends](#direct3d-backends)) |
| D3D9 | mtld3d instead of wined3d | Rule `mtld3d` ([Direct3D backends](#direct3d-backends)) |
| DPI awareness | Every process is system-aware | Rule `dpi-aware` ([recipes](docs/compatdb.md#recipes)) |
| Address space | Every 32-bit process gets 4 GB, even without the large-address-aware flag | Rule `large-address-aware` ([recipes](docs/compatdb.md#recipes)) |
| Raw mouse input | Raw input and DirectInput take mouse movement from GameController, in the device's own counts, instead of from the cursor, which macOS accelerates and scales for retina: mouselook is linear | Rule `gcmouse` ([GameController mice](docs/compatdb.md#gamecontroller-mice)) |
| x87 precision under FEX | FEX emulates every program's x87 code with reduced precision | Rule `fex-x87-reduced-precision` ([built-in environment rules](docs/compatdb.md#built-in-environment-rules)) |
| No-execute | Permanently on in every 32-bit process, even when its executable or a DLL lacks the `NX_COMPAT` flag, for which Wine would turn it off | Rule `force-nx` ([no-execute](docs/compatdb.md#no-execute)) |
| Synchronization | CrossOver's msync is on: synchronization objects use Mach semaphores and shared memory | The wineserver of [our Wine](https://github.com/athei/wine) at [`wine-src.ref`](pins/wine-src.ref); `WINEMSYNC=0` where the session starts turns it off ([runtime](docs/arm64.md#runtime)) |
| x86 memory ordering | FEX runs a thread's x86 code with the hardware x86 memory ordering (TSO), switching per thread | [Our FEX](https://github.com/athei/FEX) at [`fex-src.ref`](pins/fex-src.ref); `FEX_HARDWARE_TSO` ([environment variables](#environment-variables)) |
| AFP in x86_64 programs | FEX runs x86_64 programs, which run as ARM64EC, without AFP | [Our FEX](https://github.com/athei/FEX) at [`fex-src.ref`](pins/fex-src.ref); `FEX_HOSTFEATURES` ([environment variables](#environment-variables)) |
| KosmicKrisp's experimental features | Advertised whatever `MESA_KK_EXPERIMENTAL` says | [Our Mesa](https://github.com/athei/mesa) at [`mesa-src.ref`](pins/mesa-src.ref) ([Vulkan](docs/arm64.md#vulkan)) |
| Vulkan driver | Only the bundled KosmicKrisp: ntdll points `VK_DRIVER_FILES` at the bundle's manifest unless the caller sets `VK_DRIVER_FILES`, `VK_ICD_FILENAMES` or `VK_ADD_DRIVER_FILES` | ntdll of [our Wine](https://github.com/athei/wine) at [`wine-src.ref`](pins/wine-src.ref) ([environment variables](#environment-variables), [Vulkan](docs/arm64.md#vulkan)) |
| OpenGL | Mesa's EGL with Zink on KosmicKrisp instead of Apple's OpenGL; no OpenGL on a Mac without a Metal 4 GPU unless a rule gives the program `opengl=cgl` | Rule `opengl-egl` ([OpenGL](docs/arm64.md#opengl), [recipes](docs/compatdb.md#recipes)) |
| D3D12 frame latency handles | A game that waits on one runs extra frames ahead, so an Apple GPU keeps its clock up; more input latency | Rule `vkd3d-proton-min-latency` ([built-in environment rules](docs/compatdb.md#built-in-environment-rules)) |
| Mono and Gecko | Disabled (`mscoree,mshtml=`): no install prompt, and an installed wine-mono, Gecko or native .NET stays disabled too | Rule `no-mono-gecko` ([recipes](docs/compatdb.md#recipes)) |

## Building

### Requirements

What the build needs is in [docs/arm64.md](docs/arm64.md#requirements): an
Apple Silicon Mac, the arm64 Homebrew with the formulae in
[`pins/brew-formulae`](pins/brew-formulae), Xcode's Metal toolchain,
llvm-mingw, Rust with the `aarch64-apple-darwin` target, for
`compatdb.so`, and the signing identity of the loader's
provisioning profile.

### Commands

```bash
bin/build-wine.sh    # Mesa and the Vulkan loader, Wine, the SDK, then FEX, DXMT and vkd3d-proton
bin/bundle-wine.sh   # assemble the bundle (see Layout)
```

| Script | Flag | Effect |
|--------|------|--------|
| `build-wine.sh` | none | Incremental build; configure runs only when the build directory has no Makefile, and in the x86 tree of the [Wine SDK](docs/arm64.md#wine-sdk) also when its configure arguments or `WINE_SRC` (the source path) changed. Mesa, FEX, DXMT and vkd3d-proton are not built at all while what they staged is current ([commands](docs/arm64.md#commands)) |
| `build-wine.sh` | `--clean` | Wipes the build directories and what they staged first, and is passed on to `build-mesa.sh`, `build-fex.sh`, `build-dxmt.sh` and `build-vkd3d-proton.sh`; the only way to pick up changed configure flags or deployment target, except in the x86 tree of the [Wine SDK](docs/arm64.md#wine-sdk), which is configured again whenever its flags or `WINE_SRC` change |
| `bundle-wine.sh` | `--dest <dir>` | Writes `<dir>/wine` instead of the bundle in the [layout](#layout). Either way it asks before it deletes an existing one, unless `--yes` |
| `bundle-wine.sh` | `--yes` | Deletes an existing bundle without asking, for an unattended run. A directory that is not empty and has no `bin/wine` is still refused |
| `bundle-wine.sh` | `--runtime-only` | No development files; the flavor to put into an application |
| `bundle-wine.sh` | `--compatdb-only` | Rebuilds `compatdb.so` into the existing bundle only (the default one, or `<dir>/wine` with `--dest`); no prompt, no `make install`, no Wine build needed; `--runtime-only` is ignored. It refuses a bundle without Vulkan ([what the bundle step checks](docs/arm64.md#what-the-bundle-step-checks)) |
| `bundle-wine.sh` | `--strict-floor` | A Mach-O that needs a newer macOS than the floor is an error instead of a warning ([Homebrew libraries and the floor](docs/arm64.md#homebrew-libraries-and-the-floor)) |
| `bundle-wine.sh` | `--symbols` | Also keeps the PE files as they were before their symbols were stripped, in `wine-symbols` next to the bundle |

`usage()` and the argument parsing in
[`build-wine.sh`](bin/build-wine.sh) and
[`bundle-wine.sh`](bin/bundle-wine.sh) are authoritative.
`build-mesa.sh`, `build-fex.sh`, `build-dxmt.sh` and
`build-vkd3d-proton.sh` also run alone
([commands](docs/arm64.md#commands)).

### Repository

| Path | What it holds |
|------|---------------|
| [`bin/`](bin) | The build and bundle scripts; [`bin/lib/profile.sh`](bin/lib/profile.sh) holds the settings and helpers they share, [`bin/ci/`](bin/ci) what the release workflows run besides them |
| [`pins/`](pins) | The pinned inputs: [`redist.env`](pins/redist.env), the refs of the sources the build checks out, and the Homebrew formulae a CI build installs |
| [`.github/workflows/`](.github/workflows) | The release workflows ([releases](docs/maintenance.md#releases)) |
| [`compatdb/`](compatdb) | The Cargo workspace of `compatdb.so` and the `compatdb-table` crate ([docs/compatdb.md](docs/compatdb.md)); run cargo there |
| [`smoke/`](smoke) | The programs the bundle step builds and runs to check the bundle |
| [`signing/`](signing) | The loader's provisioning profile |
| [`docs/`](docs) | The documentation this README links to |

### Layout

Everything lives beside this repository, in the directory that holds it
(the root; `WINE_BUILD_ROOT` names another, for a checkout kept elsewhere):

| Path | What it is |
|------|------------|
| `scripts/` | The checkout of this repository, [wine-build](https://github.com/athei/wine-build), named `scripts` locally |
| `src/` | The Wine source, a checkout of athei/wine |
| `src-fex/` | The FEX checkout |
| `src-mesa/` | The Mesa checkout, for the Vulkan driver |
| `cache/` | Downloaded redistributables |
| `build/<component>/` | One tree per intermediate: the Wine build, its SDK and the x86 tree for its link libraries and tests, FEX, DXMT, vkd3d-proton and Mesa with the Vulkan loader. DXMT's and vkd3d-proton's trees hold their own clones of the source |
| `dist/wine` | The bundle |
| `dist/wine-symbols` | With `--symbols`, the bundle's PE files before their symbols were stripped (Step 4e of [`bundle-wine.sh`](bin/bundle-wine.sh)); not part of the bundle |

The name of each tree is set in [`profile.sh`](bin/lib/profile.sh),
with the variable that overrides it ([paths](docs/arm64.md#paths)). The
scripts mark each build tree they make with a `.wine-build-tree` file and
refuse to fill or delete a directory that is not empty and has no such
marker, so an override cannot point them at something else (`claim_tree`
in [`profile.sh`](bin/lib/profile.sh)). The exception is an unmarked
tree from before markers existed, which is adopted when its parent is
`build/` or another tree and it is not a git checkout.

### Configure policy

- Every optional dependency is `--without-*` unless re-enabled with
  `--with-*` in [`build-wine.sh`](bin/build-wine.sh), so a missing
  package fails configure instead of silently changing the feature set.
- `--with-opengl` makes configure require EGL, the one OpenGL library it
  looks for without X11. It finds Mesa's, which `build-mesa.sh` builds with
  Zink, through the `egl.pc` that script stages; the Mac driver links
  Apple's OpenGL framework on its own. Zink is only used through the Mac
  driver's EGL driver, which our Wine series adds
  ([OpenGL](docs/arm64.md#opengl)).
- Wine's Vulkan is on, on the loader and KosmicKrisp `build-mesa.sh` builds
  ([Vulkan](docs/arm64.md#vulkan)). The bundle does not ship Wine's own
  D3D12 modules; D3D12 is vkd3d-proton's.
