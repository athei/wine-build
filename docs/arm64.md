# The arm64 build

`build-wine.sh` and `bundle-wine.sh` build and bundle a native arm64 Wine
that runs x86 programs through [FEX](https://github.com/FEX-Emu/FEX). The
settings they share are in [`profile.sh`](../bin/lib/profile.sh). In short:

- The Wine source is upstream Wine with our own series on top, the branch
  [`arm64-patched`](https://github.com/athei/wine/tree/arm64-patched) of
  athei/wine. Some of its commits come from Hadron, and it carries
  CrossOver's msync (see [Runtime](#runtime)). It is configured against the
  arm64 Homebrew with the allowlist in
  [`build-wine.sh`](../bin/build-wine.sh), plus the configure results
  the floor overrides (`FLOOR_NEWER_FUNCS`,
  [macOS floors](maintenance.md#macos-floors)).
- `WINE_ARCHS` in `profile.sh` names the PE architectures: aarch64 with
  arm64ec, so that x64 code runs as ARM64EC, and i386 for WoW64.
- Upstream Wine turns no-execute off for a 32-bit process whose executable
  or one of its DLLs lacks the `NX_COMPAT` flag. With no-execute off, every
  readable page is executable, so FEX has to treat all writable memory as
  possible code and translates it again whenever it changes. compatdb's
  `force_nx` setting keeps no-execute permanently on, so the process cannot
  turn it off, and its built-in `force-nx` rule sets it for every process
  ([no-execute](compatdb.md#no-execute)). For a game that needs no-execute
  off, a compatdb rule gives it Wine's behaviour again
  ([recipes](compatdb.md#recipes)).
- FEX is upstream FEX with our own commits on top, from
  [athei/FEX](https://github.com/athei/FEX) at the ref
  [`fex-src.ref`](../pins/fex-src.ref) names. compatdb's built-in
  `fex-x87-reduced-precision` rule asks FEX for faster x87 emulation
  ([defaults](../README.md#defaults-that-differ-from-wine),
  [built-in environment rules](compatdb.md#built-in-environment-rules)).
- DXMT is built from our fork against this Wine (see [DXMT](#dxmt)), and
  vkd3d-proton, the D3D12 in DXMT's tree, from ours (see
  [vkd3d-proton](#vkd3d-proton)); mtld3d comes from its release (see
  [mtld3d](#mtld3d)). The trees the bundle carries are `DXGI_IMPLS` and
  `D3D9_IMPLS` in `profile.sh`.
- Wine's Vulkan is on, on KosmicKrisp, Mesa's Vulkan driver on Metal, and
  a Vulkan loader built for the floor (see [Vulkan](#vulkan)).
- A [Wine SDK](#wine-sdk) is staged for the PE code built outside Wine.
- The loader is wrapped in a signed app bundle, and Wine processes run with
  4K pages (see [Loader app](#loader-app)).

## Requirements

- An Apple Silicon Mac and a macOS SDK at least as new as `MACOS_FLOOR` in
  [`profile.sh`](../bin/lib/profile.sh).
- The arm64 Homebrew at `DEPS_PREFIX` (in `profile.sh`) with the formulae
  in [`brew-formulae`](../pins/brew-formulae): those of `DEPS_FORMULAE` and
  `MESA_FORMULAE` in `profile.sh`, which the scripts check for, and the
  build tools they run. A CI build installs exactly these. Only a host on
  the floor's major macOS version gets bottles that meet the floor (see
  [Homebrew libraries and the floor](#homebrew-libraries-and-the-floor)).
- Xcode's Metal toolchain (`xcrun metal`), for DXMT's shaders.
- [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) at `MINGW_DIR`,
  including its arm64ec toolchain. The scripts append its `bin/` to `PATH`;
  never prepend it, since its unprefixed `clang` breaks configure's host
  compiler detection. A CI build uses the release pinned in
  [`redist.env`](../pins/redist.env).
- Rust with the `aarch64-apple-darwin` target (`RUST_TARGET` in
  `profile.sh`), for `compatdb.so`.
- In the keychain, a code signing identity of the team that
  [`signing/loader.provisionprofile`](../signing/loader.provisionprofile)
  belongs to, whose certificate the profile lists.
- Network access for the bundle step, which resolves `fex-src.ref`,
  `mesa-src.ref`, `dxmt-src.ref` and `vkd3d-proton-src.ref` and gets the
  loader's secure timestamp. `build-fex.sh`, `build-mesa.sh`,
  `build-dxmt.sh` and `build-vkd3d-proton.sh` ask `FEX_REPO`, `MESA_REPO`,
  `DXMT_REPO` and `VKD3D_PROTON_REPO` for their ref on every run, and fetch
  it unless what they staged is current ([commands](#commands)), which
  needs the network unless the variable names a local clone.
  `build-vkd3d-proton.sh` needs it in any case for the submodules, which
  come from their upstream repositories. `build-mesa.sh` also needs it
  whenever it builds the Vulkan loader or the Python environment of Mesa's
  build scripts anew (a first run, or changed pins), to clone the loader
  and headers and install the Python modules.

## Commands

| Script | What it does |
|--------|--------------|
| `build-wine.sh` | Runs `build-mesa.sh`, builds Wine against the loader it staged, stages the [Wine SDK](#wine-sdk), then runs `build-fex.sh`, `build-dxmt.sh` and `build-vkd3d-proton.sh`; `--clean` is passed on to all four |
| [`build-mesa.sh`](../bin/build-mesa.sh) | Checks out the ref in [`mesa-src.ref`](../pins/mesa-src.ref) in `MESA_SRC` (refusing a tree with local changes), builds the Vulkan loader from the tags pinned in [`redist.env`](../pins/redist.env), KosmicKrisp, and Mesa's EGL with Zink, and stages them with the driver's manifest, an `egl.pc` for Wine's configure and their commits in `MESA_DIST` (see [Vulkan](#vulkan) and [OpenGL](#opengl)). Runs alone too |
| [`build-fex.sh`](../bin/build-fex.sh) | Checks out the ref in [`fex-src.ref`](../pins/fex-src.ref) in `FEX_SRC` (refusing a tree with local changes), builds FEX's emulator DLLs and their unix halves, and stages them with their commit in `FEX_DIST`. Runs alone too |
| [`build-dxmt.sh`](../bin/build-dxmt.sh) | Checks out the ref in [`dxmt-src.ref`](../pins/dxmt-src.ref) in its own clone, builds DXMT against the Wine build and SDK, and stages it with its commit and `git describe` in `DXMT_DIST`. Runs alone too, after a Wine build |
| [`build-vkd3d-proton.sh`](../bin/build-vkd3d-proton.sh) | Checks out the ref in [`vkd3d-proton-src.ref`](../pins/vkd3d-proton-src.ref) in its own clone, builds vkd3d-proton's D3D12 DLLs, marks them as builtins with the Wine build's and the SDK's `winebuild`, and stages them with their commit and `git describe` in `VKD3D_PROTON_DIST`. Runs alone too, after a Wine build |
| `bundle-wine.sh` | Assembles the bundle from the Wine build, the SDK, FEX, DXMT, vkd3d-proton, the Vulkan loader, KosmicKrisp and EGL, and the mtld3d release, signs the loader and runs the smoke test |

The flags are in the [README](../README.md#commands).

- Each staged directory, `MESA_DIST`, `FEX_DIST`, `DXMT_DIST` and
  `VKD3D_PROTON_DIST`, holds a `KEY` file next to its `COMMIT`: one line
  naming what it was built from, the source commit, the hash of the script
  that built it and of [`profile.sh`](../bin/lib/profile.sh) (for DXMT also
  of `build-wine.sh`, whose Wine build it links against), and the versions
  of the compilers, SDK and tools that script records (each script's key
  function says which). Before it fetches anything, the script asks
  its repository for the commit its ref names now, and builds nothing when
  the staged directory is complete and has the key it would write for that
  commit; it says so in a line of its own. `--clean` deletes the staged
  directory, so the script builds. DXMT is also built whenever the Wine
  source has uncommitted changes.
- `--print-key` makes each of the four scripts print that key and exit.

## Paths

Every tree lives under `build/` and the bundle in `dist/wine`, in the
[layout](../README.md#layout). Each variable below overrides the default
of the same name; the defaults are set in
[`profile.sh`](../bin/lib/profile.sh), except `MINGW_DIR` and
`CACHE_DIR`, which are set at the top of the scripts that use them. A
`MACOSX_DEPLOYMENT_TARGET` may raise the floor but not lower it.

| Variable | What it is |
|----------|------------|
| `WINE_SRC` | The Wine source, a checkout of athei/wine |
| `BUILD_DIR` | The Wine build tree; with `--compatdb-only` only cargo's target directory, `$BUILD_DIR/compatdb` |
| `X86LIBS_BUILD_DIR` | The x86 tree for the x86_64 archives and the [graphics tests](#graphics-tests) of the SDK |
| `WINE_SDK_DIR` | The [Wine SDK](#wine-sdk) |
| `FEX_REPO`, `FEX_SRC` | FEX repository and the local clone `build-fex.sh` checks out |
| `FEX_BUILD_DIR` | FEX's CMake trees and, by default, `FEX_DIST` |
| `FEX_DIST` | FEX's emulator DLLs and their unix halves as the bundle installs them, with the commit they were built from |
| `DXMT_REPO` | DXMT repository `build-dxmt.sh` fetches the ref from |
| `DXMT_BUILD_DIR` | DXMT's checkout, its meson trees (ARM64X PE with the arm64 unix half, and i386 PE) and, by default, `DXMT_LLVM` and `DXMT_DIST` |
| `DXMT_LLVM` | The LLVM static libraries `winemetal.so` links |
| `DXMT_DIST` | All of DXMT as the bundle installs it, with the commits it was built from |
| `VKD3D_PROTON_REPO` | vkd3d-proton repository `build-vkd3d-proton.sh` fetches the ref from |
| `VKD3D_PROTON_BUILD_DIR` | vkd3d-proton's checkout, its meson trees (ARM64X and i386 PE) and, by default, `VKD3D_PROTON_DIST` |
| `VKD3D_PROTON_DIST` | vkd3d-proton's DLLs as the bundle installs them, with the commits they were built from |
| `MESA_REPO`, `MESA_SRC` | Mesa repository and the local clone `build-mesa.sh` checks out |
| `MESA_BUILD_DIR` | The Vulkan loader's and headers' clones and trees, Mesa's two meson trees (the host tools, and KosmicKrisp with EGL and Zink), the Python environment and, by default, `MESA_DIST` |
| `MESA_DIST` | The Vulkan loader, KosmicKrisp and its manifest, EGL and the gallium library with Zink as the bundle installs them, the `egl.pc` Wine's configure reads, and the commits they were built from |
| `LOADER_PROFILE` | The provisioning profile the loader is signed for |
| `MINGW_DIR` | llvm-mingw |
| `CACHE_DIR` | Downloaded redistributables |

## Runtime

The variables are listed in the
[README](../README.md#environment-variables).

- msync is CrossOver's implementation of Windows synchronization objects
  for macOS, built on Mach semaphores and shared memory, which saves
  wineserver round trips.
- `WINEMSYNC=0` has to be in the environment of whatever starts the
  wineserver session, normally the launcher's first Wine process, and
  takes effect only for a new session. Every process of the session follows
  the wineserver's choice whatever its own environment says. A per-game
  compatdb `env` rule cannot turn msync off reliably: it reaches the game's
  process, which only starts the wineserver when no session is running yet.
- While msync is on, the wineserver prints `msync: up and running.` on its
  standard error when it starts and registers a launchd service named
  `wine-<dev>-<inode>-msync` while it runs; for a wineserver started from
  the GUI login session, `launchctl print gui/<uid>` lists it. With msync
  off neither appears.
- If the wineserver cannot register that service, it prints an
  `msync: error:` line saying msync is off for this wineserver and runs the
  session without msync. `msync: up and running.` then does not appear.
  The messages are in
  [`server/msync.c`](https://github.com/athei/wine/blob/arm64-patched/server/msync.c).
- `WINENCPU` belongs on the process that starts the session as well. Each
  process limits the count it reports itself, but the `CentralProcessor`
  registry keys and `NUMBER_OF_PROCESSORS` are written once per session,
  and FEX's emulated CPUID reads those keys, so a value set later for one
  game leaves them at the session's count.

## Wine SDK

PE code built outside Wine links against Wine's `libwinecrt0.a` (for the
`unix_lib.o` its unix calls go through) and `libntdll.a`, and runs
`winebuild` to mark itself a builtin. `build-wine.sh` stages one directory
with all of it, in the layout of an installed Wine, for every architecture
that code is built for, plus a `WINE_COMMIT` file naming the Wine source
commit. What goes in is the Wine SDK step of
[`build-wine.sh`](../bin/build-wine.sh).

- `bin/winebuild` and the `aarch64-windows` and `i386-windows` archives come
  from the build itself. Its `aarch64-windows` archives are ARM64X,
  carrying ARM64 and ARM64EC members, since arm64ec is paired with aarch64
  there.
- The `x86_64-windows` archives are what the arm64 build cannot make: x64
  objects do not link against ARM64EC ones. The x86 tree, a second
  configure of the same source for i386 and x86_64 that reuses the build's
  tools, builds just those and the [graphics tests](#graphics-tests).
  `build-wine.sh` configures that tree again from scratch whenever its
  configure arguments or `WINE_SRC` change, so neither needs a `--clean`.
- DXMT's i386 build reads it through `-Dwine_install_path`; its ARM64X
  build links against the build tree itself (see
  [`build-dxmt.sh`](../bin/build-dxmt.sh)).
- A full bundle carries the same files, so the bundle is an installed Wine
  with its SDK. [mtld3d](https://github.com/athei/mtld3d) builds against
  an installed Wine, not the SDK directory; its
  [`docs/BUILDING.md`](https://github.com/athei/mtld3d/blob/main/docs/BUILDING.md)
  names the variables and lists what else that build needs.
- `build-dxmt.sh` and the bundle step refuse an SDK whose `WINE_COMMIT` is
  not the Wine source's current commit.

### Graphics tests

The SDK and a full bundle carry Wine's graphics conformance tests, the
programs of `dlls/<name>/tests` in the Wine source, as
`lib/wine/tests/<pe-dir>/<name>_test.exe`. They exist to test the bundle's
own stack (mtld3d, DXMT, wined3d on OpenGL or on KosmicKrisp, the Vulkan
loader) with nothing but the bundle; mtld3d's conformance suite runs the
`d3d9_test.exe` of both directories.

- The list is `GRAPHICS_TESTS` in [`profile.sh`](../bin/lib/profile.sh):
  `ddraw`, `d3d8`, `d3d9`, `d3d10`, `d3d10_1`, `d3d10core`, `d3d11`,
  `d3d12`, `dxgi`, `d2d1`, `opengl32` and `vulkan-1`.
- Each is built for `i386-windows` and `x86_64-windows`, the x86 code games
  run, except `d3d8`, which is i386 only: Wine builds no 64-bit `d3d8.dll`.
  An x86_64 test runs as ARM64EC, as an x64 game does. There are no
  `aarch64-windows` tests: the games the bundle is for are x86 code.
- The main build has tests disabled, since its `make` would otherwise build
  every Wine test, and makedep writes test rules only for the architectures
  a tree is configured for. So the x86 tree builds them, by name.
- They are plain executables, not builtins, outside the directories Wine
  searches for modules, and Step 4e strips them like every PE file.
- `lib/wine/tests/VERSION` holds one line, the `wine --version` string of
  the Wine the tests were built from (`wine_build` in the build tree's
  `dlls/ntdll/unix/version.c`), so a copy of `lib/wine/tests` taken alone
  still names its build; mtld3d's conformance runner reads its first line.
- `d3d12_test.exe` runs against vkd3d-proton and DXMT's `dxgi.dll` from
  the `dxmt` tree ([vkd3d-proton](#vkd3d-proton)). It imports `d3d12.dll`,
  which only that tree has, so on the `wined3d` tree the loader stops it
  with `c0000135` (a missing DLL) and it exits with 53, as it did before
  the bundle had D3D12.

To run one against the bundle, in a prefix of its own, give the test's path
to the bundle's `wine`, with the names of the parts to run (all of them
without a name; the names are the `START_TEST` entries in the test's
sources):

```bash
WINEPREFIX=/tmp/gfx-prefix dist/wine/bin/wine \
    dist/wine/lib/wine/tests/x86_64-windows/d3d9_test.exe device
```

The test picks its Direct3D tree as a game does, through compatdb, so a
`WINE_COMPATDB` rule for `d3d9_test.exe` puts it on another tree
([recipes](compatdb.md#recipes)). It prints a summary line per part and
exits with the number of failed checks, at most 255.

## DXMT

- DXMT is [athei/dxmt](https://github.com/athei/dxmt) at the ref
  [`dxmt-src.ref`](../pins/dxmt-src.ref) names: upstream DXMT plus our
  commits, among them the `dxgi.dll` support for vkd3d-proton's swapchains
  ([vkd3d-proton](#vkd3d-proton)). As with Mesa, the ref is fetched from
  `DXMT_REPO`, so a commit that is only in a local clone is built only with
  `DXMT_REPO` set to that clone. `build-dxmt.sh` fetches it into a clone of
  its own in `DXMT_BUILD_DIR`, which it resets to the ref on every run.
- DXMT's own `d3d12.dll` is not built (`-Denable_d3d12=false`): D3D12 is
  vkd3d-proton's.
- The 64-bit DLLs are ARM64X, built with DXMT's own `build-arm64ec.txt`
  cross file against the Wine build tree, whose `aarch64-windows` archives
  are ARM64X too. An x64 game runs as ARM64EC and loads their ARM64EC half,
  so DXMT's own code runs natively and only the game's x86 code goes
  through FEX. A native ARM64 program loads their ARM64 half.
- The i386 DLLs are x86 code, built with DXMT's `build-win32.txt` against
  the [Wine SDK](#wine-sdk). A 32-bit game runs under WoW64 and FEX, and
  they run there with it.
- `winemetal.so` is arm64, linked against this Wine's `winemac.so` and
  `ntdll.so`. DXMT builds its unix half as a native target whose
  architecture follows the cross file, so it comes out of the same meson
  tree as the ARM64X DLLs.
- The DLLs and the `.so` share a private call interface, so they come from
  one checkout. `build-dxmt.sh` records the commit, its `git describe` (which
  DXMT also builds into `d3d11.dll` as its version) and the Wine commit it
  linked against; the bundle step checks them against what `dxmt-src.ref`
  names now, the DLLs and the Wine source. A meson tree is configured
  afresh, and so relinked, whenever the DXMT, Wine or LLVM commit, its
  options or llvm-mingw's clang change.
- `winemetal.so` contains DXMT's shader converter (airconv), which links
  LLVM; the PE side only uses its headers. `build-dxmt.sh` builds the LLVM
  static libraries from the tag pinned in
  [`redist.env`](../pins/redist.env) into `DXMT_LLVM`, records the commit
  there, and rebuilds them only when the pin changes; `--clean` keeps them.

## vkd3d-proton

- Direct3D 12 is vkd3d-proton,
  [athei/vkd3d-proton](https://github.com/athei/vkd3d-proton) at the ref
  [`vkd3d-proton-src.ref`](../pins/vkd3d-proton-src.ref) names: upstream
  vkd3d-proton plus our commits. Like DXMT, the ref is fetched from
  `VKD3D_PROTON_REPO` into a clone of `build-vkd3d-proton.sh`'s own; the
  submodules come from their upstream repositories at the commits the ref
  records.
- It translates D3D12 to Vulkan and runs on KosmicKrisp
  ([Vulkan](#vulkan)), which it finds through `winevulkan.dll` or
  `vulkan-1.dll`. The KosmicKrisp features it needs, which upstream Mesa
  counts as experimental, are always on in our Mesa ([Vulkan](#vulkan)).
- Our commits add `VKD3D_SWAPCHAIN_MIN_LATENCY_FRAMES`, the least frame
  latency a swapchain's frame latency handle allows. compatdb's built-in
  `vkd3d-proton-min-latency` rule sets a minimum frame latency for every
  process, with the value in
  [`compatdb/src/builtin.rs`](../compatdb/src/builtin.rs): at a latency of
  1 the CPU and the GPU take turns and an Apple GPU stays at a low clock
  ([built-in environment rules](compatdb.md#built-in-environment-rules)).
  The smoke test checks that vkd3d-proton reports it for its waitable
  swapchain.
- `d3d12.dll` and `d3d12core.dll` go into the `dxmt` tree. vkd3d-proton
  has no DXGI of its own: a game creates its swapchain through DXMT's
  `dxgi.dll`, which presents vkd3d-proton's Vulkan swapchain into the
  window, so the two are always loaded together. The `wined3d` tree has no
  D3D12, and under `dxgi=wined3d` `d3d12.dll` does not load (error 126),
  which the smoke test checks. Wine's own `d3d12.dll` and
  `d3d12core.dll`, on vkd3d, are removed in Step 3b of
  [`bundle-wine.sh`](../bin/bundle-wine.sh).
- The 64-bit DLLs are ARM64X, built with vkd3d-proton's own
  `build-arm64x.txt` cross file, and the i386 DLLs x86 code, built with
  `build-win32.txt`, both with llvm-mingw, as for DXMT. vkd3d-proton links
  nothing of Wine. Wine only loads a DLL from `lib/wine` that is marked as
  a builtin, so `build-vkd3d-proton.sh` marks the staged copies with
  `winebuild --builtin`, the Wine build's for the 64-bit DLLs and the
  SDK's for the i386 ones, and checks each DLL's machine, mark and exports.
- It records the commit, its `git describe` and the commit `WINE_SRC` was
  at; the bundle step checks the commit against what
  `vkd3d-proton-src.ref` names now. The Wine commit is only a record: the
  builtin mark does not change with Wine, so a new Wine needs no new
  vkd3d-proton build. A meson tree is configured afresh whenever the
  commit, its options, llvm-mingw's clang or glslang change.
- Its shaders are compiled with glslang from the arm64 Homebrew
  ([`brew-formulae`](../pins/brew-formulae)).

## mtld3d

- mtld3d comes from the release tarball pinned in
  [`redist.env`](../pins/redist.env), not built here. Its `wine/` directory
  mirrors `lib/wine`, and Step 4 of
  [`bundle-wine.sh`](../bin/bundle-wine.sh) takes `d3d9.dll` and
  `mtld3d.dll` from its `i386-windows` and `aarch64-windows` and
  `mtld3d.so` from its `aarch64-unix`. Its `x86_64-windows` and
  `x86_64-unix` builds are not used.
- The `aarch64-windows` DLLs are ARM64X builtins. An x64 game runs as
  ARM64EC and loads their ARM64EC half, so mtld3d's PE code runs natively
  and only the game's x86 code goes through FEX; a native ARM64 program
  loads their ARM64 half. The bundle step refuses a tarball whose
  `aarch64-windows` DLLs are not ARM64X, since compatdb.so gives native
  ARM64 programs the mtld3d tree
  ([native ARM64 programs](compatdb.md#native-arm64-programs)).
- The i386 DLLs are x86 code; a 32-bit game runs under WoW64 and FEX, and
  they run there with it. The one `mtld3d.so` serves them too, through its
  wow64 entry points.

## Vulkan

Wine's Vulkan (`vulkan-1.dll`, `winevulkan`) runs on KosmicKrisp, Mesa's
Vulkan driver on Metal, through the Khronos Vulkan loader. The default
Direct3D implementations, mtld3d and DXMT, go to Metal directly and do not
use it; D3D12 does, through vkd3d-proton ([vkd3d-proton](#vkd3d-proton)),
and wined3d can, per game (see below).

- Mesa is [athei/mesa](https://github.com/athei/mesa) at the ref
  [`mesa-src.ref`](../pins/mesa-src.ref) names: upstream Mesa plus our topic
  commits, originally from
  [Hadron's Mesa patches](https://github.com/Broyojo/hadron/tree/main/patches/mesa)
  and regrouped by topic. Commits of upstream merge requests that are not
  merged yet are carried under their original authors and dropped once
  upstream has them
  ([rebasing](maintenance.md#mesa-and-the-vulkan-loader)). Like FEX, the
  ref is fetched from `MESA_REPO`, so a commit that is only in the local
  clone is built only with `MESA_REPO` set to that clone.
- KosmicKrisp is built in two stages. The driver's build compiles its
  OpenCL C kernels with tools of Mesa's own, which link LLVM and the SPIR-V
  libraries, and Homebrew has those only for the host's macOS. The first
  stage builds just these tools, for the host; the second builds the driver
  for the floor with LLVM off and the tools of the first stage, so the
  driver links system libraries only. As with Wine's configure, the second
  stage disables every optional library the driver does not need, and runs
  meson and ninja with Homebrew off `PATH`, so what else Homebrew has
  installed cannot change the build. The second stage also builds EGL and
  the gallium library with Zink ([OpenGL](#opengl)).
- `build-mesa.sh --clean` builds the driver again from scratch. The loader,
  the Python environment and the first stage's tools are kept while what
  they were built from is unchanged, as `build-dxmt.sh` keeps its LLVM.
- The loader is built from source, from the Vulkan-Loader and
  Vulkan-Headers tags pinned in [`redist.env`](../pins/redist.env), because
  Homebrew's vulkan-loader bottle needs a newer macOS than the floor. The
  bundle step copies it from `MESA_DIST` into `lib/external/`, which is
  what keeps Homebrew's loader out of the bundle: `SONAME_LIBVULKAN` holds
  only the file name, whichever loader configure linked. `MESA_DIST/lib`
  comes first in the `LDFLAGS` of `profile.sh` so that configure's `-lvulkan`
  test succeeds against this loader, without Homebrew's installed, and
  does not link Homebrew's where it is.
- `win32u.so` loads the loader the first time something in the process
  needs Vulkan. That includes the display device refresh `explorer.exe`
  runs when a session starts: it loads the loader and KosmicKrisp and takes
  the GPU's name, memory size and UUID for the registry from them.
- The loader finds the driver through the manifest in
  `share/vulkan/icd.d/`, whose `library_path` is relative to the manifest,
  so the bundle stays relocatable. ntdll sets `VK_DRIVER_FILES` to that
  directory when the caller has set none of `VK_DRIVER_FILES`,
  `VK_ICD_FILENAMES` and `VK_ADD_DRIVER_FILES`, so the loader uses the
  bundled driver and no other driver installed on the Mac. A caller that
  sets one of them chooses the drivers itself: the bundled one is then not
  added, and has to be named there to be used
  ([environment variables](../README.md#environment-variables)).
- The features our topic commits add, device-generated commands,
  transform feedback and sparse resources, which Direct3D 12 and OpenGL
  through Zink need, are always advertised; no environment variable or
  compatdb rule turns them on or off. `MESA_KK_EXPERIMENTAL` keeps only
  Mesa's own experimental flags, which Mesa describes in
  [`docs/drivers/kosmickrisp.rst`](https://gitlab.freedesktop.org/mesa/mesa/-/blob/main/docs/drivers/kosmickrisp.rst);
  the bundle sets none of them.
- wined3d, Wine's own Direct3D, which serves the `wined3d` trees of both
  families and D3D8 and DirectDraw, keeps Wine's default OpenGL renderer,
  which runs on Zink where the Mac driver uses EGL ([OpenGL](#opengl)) and
  reaches Direct3D 11 there. Apple's OpenGL holds that renderer to a lower
  feature level. wined3d's Vulkan renderer runs on KosmicKrisp directly. It
  is not the default because wined3d on KosmicKrisp still crashes in many
  of Wine's conformance tests, and wined3d does not fall back to OpenGL
  when Vulkan fails. A compatdb rule with `wined3d=vulkan` turns it on for
  one game, for every wined3d user in that process, D3D8 and DirectDraw
  included
  ([wined3d on Vulkan](compatdb.md#wined3d-on-vulkan)).
- Wine's own `d3d12.dll` and `d3d12core.dll` are left out of the bundle;
  D3D12 is vkd3d-proton's.
- Not covered yet: DXVK. A program that wants Vulkan itself gets it.

## OpenGL

OpenGL runs on Zink, Mesa's OpenGL on Vulkan, on KosmicKrisp, through
Mesa's EGL, wherever KosmicKrisp has a GPU, instead of on Apple's OpenGL,
which stops at 4.1 core and 2.1 compatibility.

- `build-mesa.sh` builds `libEGL.1.dylib` and the gallium library with Zink
  that it links, in the same tree and for the same floor as KosmicKrisp,
  without GLES, GLX and GBM. The bundle step ships both in
  `lib/external/`.
- Wine's configure finds this EGL through the `egl.pc` in `MESA_DIST`, and
  `build-wine.sh` passes `--with-opengl`, so a build without it fails.
  `SONAME_LIBEGL` is patched to `lib/external/` like the Vulkan loader, and
  `win32u.so` loads it from there.
- Zink loads the Vulkan loader by `@rpath`; the gallium library's one
  `LC_RPATH`, `@loader_path`, resolves it to the bundled loader next to it,
  and the loader finds KosmicKrisp through `VK_DRIVER_FILES` as Wine's
  Vulkan does ([Vulkan](#vulkan)).
- Zink reports OpenGL above 2.1 only with transform feedback, which our
  KosmicKrisp always advertises ([Vulkan](#vulkan)).
- The Mac driver's EGL driver, part of our Wine series, takes the choice
  from compatdb's `opengl` setting, which ntdll stores for the process,
  when the process first uses OpenGL: `egl` for EGL, `cgl` for Apple's
  OpenGL, and Apple's OpenGL unset, as in upstream Wine. compatdb's
  built-in `opengl-egl` rule sets `egl` for every process
  ([OpenGL](compatdb.md#opengl)).
- With `egl` the Mac driver does not fall back: where EGL does not start,
  as on a Mac without a GPU of the Metal 4 family, where KosmicKrisp has no
  device, it logs a `winediag` message saying why and the process gets no
  OpenGL. There, a rule with `opengl=cgl` gives a program Apple's OpenGL
  ([recipes](compatdb.md#recipes)). A hosted CI runner is such a Mac, and
  the smoke test gives the programs that need OpenGL such a rule there
  ([what the bundle step checks](#what-the-bundle-step-checks)).

## Loader app

The loader needs `com.apple.developer.cross-architecture-support`. With it,
the kernel leaves most of the 4 GB `__PAGEZERO` as a mapping Wine can
replace, which Wine claims as its low reserved area for the i386 code that
runs under FEX. The kernel places the loader a random distance above 4 GB
and covers the space between 4 GB and the loader the same way, and the
loader reserves that area for Wine too, so that an x64 executable built for
0x100000000 without relocations can load there. The entitlement also lets a
process run with 4K pages instead of the host's 16K pages, and gates the
hardware x86 memory ordering FEX runs x86 code with (`FEX_HARDWARE_TSO`,
[environment variables](../README.md#environment-variables)). That
entitlement is honoured only through a provisioning profile embedded in an
app bundle and a signature by a certificate of the profile's team. Wine
does not run without it.

- Before Wine sets up its address space, the loader execs itself with 4K
  pages (`exec_with_4k_pages` in
  [`loader/main.c`](https://github.com/athei/wine/blob/arm64-patched/loader/main.c)).
  ntdll starts new Wine processes with 4K pages directly (`preloader_exec` in
  [`dlls/ntdll/unix/loader.c`](https://github.com/athei/wine/blob/arm64-patched/dlls/ntdll/unix/loader.c)),
  so they need no exec for the page size. Everything inside a Wine process,
  FEX included, then runs on 4K pages. Wine does not merge 4K Windows pages
  into 16K host pages, so page protections, guard pages, decommit and FEX's
  tracking of self-modifying code work on 4K pages, as on Windows. The
  wineserver and other plain Unix programs keep the default page size.
- When the kernel placed the loader too close to 4 GB to leave room for such
  an executable, the loader execs itself again for a new placement, keeping
  its 4K pages, a bounded number of times. This applies to every loader,
  whether ntdll or something else started it. If such an exec fails, the
  loader prints a warning and keeps its placement. The threshold and the
  limit are in
  [`loader/main.c`](https://github.com/athei/wine/blob/arm64-patched/loader/main.c).
- A loader without the entitlement would be killed in that exec without a
  message, so the loader checks for the entitlement first. Without it, the
  loader exits with an error saying it must run from the signed `wine.app`.
  There is no fallback to 16K pages.
- The bundle step moves the loader into `lib/wine/aarch64-unix/wine.app` and
  links both entry points to it: `lib/wine/aarch64-unix/wine`, which ntdll
  execs, and `bin/wine`.
- The app is named Mach9, the launcher this Wine runs under, and carries the
  games category and the Game Mode keys of Mach9's own `Info.plist`, so a
  game the launcher starts gets Game Mode. macOS takes the name in the app
  menu from the bundle of the running executable, which is `wine.app`. The
  bundle identifier stays the one the profile grants.
- The signature claims only what the loader needs: the application and team
  identifiers and the cross-architecture entitlement, all taken from the
  profile, the self-granted `com.apple.security.custom-x18-abi-toggle`, and
  the entitlements the hardened runtime needs for Wine and FEX, which
  `LOADER_RUNTIME_ENTITLEMENTS` in [`bundle-wine.sh`](../bin/bundle-wine.sh)
  lists with the reason for each. The bundle identifier is the application
  identifier without the team prefix. The identity of the profile's team in
  the keychain signs, passed by SHA-1.
- The app is signed once as a whole, without `--deep`, with the hardened
  runtime and a secure timestamp, as notarization and Mach9's install
  verification require. The timestamp needs Apple's timestamp server;
  `LOADER_TIMESTAMP=0` signs without one for an offline local build, and the
  bundle step reports which was used. Such a bundle cannot be notarized.
- `--compatdb-only` replaces `compatdb.so` outside the app, so the signature
  stays valid.

## What the bundle step checks

Before anything is deleted, the preflight checks the macOS SDK, the
formulae, the Wine SDK (staged from the current Wine source and, for a full
bundle, holding every [graphics test](#graphics-tests) and their
`VERSION`), the staged FEX (complete, and built from the commit
`fex-src.ref` names now, which it asks `FEX_REPO` for with
`git ls-remote`, so the step needs the network), the staged DXMT
(complete, built from the commit `dxmt-src.ref` names now, asked of
`DXMT_REPO` the same way, linked against the current Wine source, its DLLs
carrying the recorded version), the staged vkd3d-proton (complete, built
from the commit `vkd3d-proton-src.ref` names now, asked of
`VKD3D_PROTON_REPO`), the staged Vulkan loader, KosmicKrisp, EGL and one
gallium library (complete, Mesa built from the commit `mesa-src.ref` names
now, asked of `MESA_REPO` the same way, and the loader from the pinned
commit), the llvm-mingw compilers and tools the smoke test, the markers of
Step 4 and Step 4e use, and the provisioning profile (not expired,
granting the entitlement, with an identity of its team in the keychain).

After assembly:

- Inherited `com.apple.quarantine` is removed from the tree (and nothing
  else), so macOS does not block a copied library; a failure stops the
  bundle step.
- No dylib in `lib/external/`, no `.so` module, the tree unix modules
  included, and not the loader references any of the `LEAK_PREFIXES` in
  `profile.sh`.
- No dylib in `lib/external/` has an `@rpath/` dependency that does not
  resolve inside the bundle, and each of them loads with `dlopen` in a
  process of its own, built from [`smoke/dlopen.c`](../smoke/dlopen.c)
  ([relocation](maintenance.md#relocation)).
- The Direct3D trees, FEX, the Vulkan files, the loader app and, in a full
  bundle, the x86_64 link libraries and every graphics test are in place,
  with a tests `VERSION` equal to `bin/wine --version`; the mtld3d tree's
  `d3d9.dll` and `mtld3d.dll` are byte-identical to the release's, and
  `xtajit.dll` and `xtajit64.dll` are FEX's.
- Every 64-bit DLL of a Direct3D tree is ARM64X (checked in Step 4, before
  the markers are stamped), and every module of a tree has a fake-module
  marker in the default directory: i386 in `i386-windows`, hybrid in
  `aarch64-windows` ([Direct3D trees](maintenance.md#direct3d-trees)).
- Every real PE file in an `aarch64-windows` directory, the default one or
  a tree's, runs natively in an x64 process (ARM64X or ARM64EC) or is never
  loaded into one as code: a program, a file without code, or one of the
  WoW64 host DLLs. Each file that is neither is named, and the step fails
  ([Direct3D trees](maintenance.md#direct3d-trees)).
- No PE file has `.debug_*` sections or a COFF symbol table; Step 4e
  stripped them, keeping the unstripped files in `wine-symbols` next to the
  bundle with `--symbols`.
- No symlink in the tree dangles.
- The Vulkan loader, KosmicKrisp, its manifest and Wine's Vulkan modules
  are in place, the manifest's `library_path` resolves from its directory,
  the loader and the driver export their entry points, and `ntdll.so`
  names `VK_DRIVER_FILES`.
- `ntdll.so` exports `set_compat_force_nx` and `set_compat_opengl`, the
  hooks through which compatdb.so hands over `force_nx` and `opengl`.
- `win32u.so` opens `lib/external/libEGL.1.dylib`, which exports its entry
  points and loads the gallium library next to it, and the gallium library
  loads the Vulkan loader by `@rpath` with `@loader_path` as its only
  `LC_RPATH` ([OpenGL](#opengl)).
- `wine.app` verifies with `codesign --verify --strict`, is signed by the
  expected identity and team with the hardened runtime and, unless
  `LOADER_TIMESTAMP=0`, a secure timestamp, and carries exactly the
  entitlements above and the Mach9 keys in its `Info.plist`.
- The minimum macOS (`minos`) of every executable, `.dylib` and `.so` (the
  newest slice of a universal file) is at most the floor, see
  [macOS floors](maintenance.md#macos-floors). Without `--strict-floor`
  each file over the floor is a warning; with it, an error. A missing
  `otool`, or a run in which no file had a `minos`, is an error either way.
- No unix module, loader or `wineserver` imports a function of
  `FLOOR_NEWER_FUNCS` while the floor is below its version (see
  [macOS floors](maintenance.md#macos-floors)). That catches a Wine build
  tree configured before the override, which `minos` does not show.
- The smoke test, with the caller's `WINE_COMPATDB` and `WINE_D3D_CONFIG`
  and every `WINEMSYNC*`, `FEX_*`, `VK_*`, `VKD3D_*`, `MESA_*`, `MTL_*` and
  `METAL_*` variable dropped and vkd3d-proton's pipeline cache in the
  throwaway prefix, not the working directory
  (`VKD3D_SHADER_CACHE_PATH`): `wine --version`; a
  fresh prefix boots (`cmd /c exit`), with `compatdb:` lines and the
  wineserver's
  `msync: up and running.` line and no `msync: error:` line (with
  `--compatdb-only`, a wineserver without msync skips that check);
  winedbg's crash dialog is turned off in the prefix (`ShowCrashDialog`),
  so a program that crashes exits with a backtrace in the log instead of
  waiting for the time limit; the i386 `cmd.exe` runs; and
  [`smoke/hello.c`](../smoke/hello.c), compiled for each architecture in
  `SMOKE_PE_ARCHS`, prints its marker and must load its DLLs. Each one's
  compatdb lines must name the trees the built-in `dxmt` and `mtld3d` rules
  give every arch. The x86 programs load `dxgi.dll` and
  `d3d9.dll`; the native one also loads `winemetal.dll` and `mtld3d.dll`,
  which only the `dxmt` and `mtld3d` trees have. Before any of this runs,
  every 64-bit marker of a Direct3D name must be a hybrid one, which a
  native ARM64 process needs (see [Limitations](#limitations)). Then the
  x86_64, i686 and native programs load every module of each Direct3D tree
  in turn, the tree picked with a `WINE_COMPATDB` rule, which shows that
  the prefix placeholders made from the default-dir markers let each tree
  in, and on the `wined3d` dxgi tree `d3d12.dll` must fail to load with
  error 126. No run with a `WINE_COMPATDB` rule may log a compatdb
  warning, which would mean compatdb.so ignored part of the rule. Before
  the prefix boots, [`smoke/egl.c`](../smoke/egl.c), a
  host program, makes an OpenGL context current through the bundle's EGL
  without Wine, with only `VK_DRIVER_FILES` set, and must get Zink on
  KosmicKrisp with every EGL, gallium and Vulkan library loaded from
  `lib/external/`. After the tree loads, [`smoke/wgl.c`](../smoke/wgl.c),
  compiled for each architecture in `SMOKE_PE_ARCHS`, opens a window,
  creates a legacy, a 4.x core and a compatibility context, each of which
  must clear, read back and swap: by default, where compatdb's
  `opengl-egl` rule must have handed over `opengl=egl`, on a Zink
  renderer, and with a `WINE_COMPATDB` rule for the program with
  `opengl=cgl`, which compatdb must have handed over instead, on Apple's.
  Then
  [`smoke/vulkan.c`](../smoke/vulkan.c), compiled for x86_64 and i686,
  creates a Vulkan instance without a window and must find a device that
  offers transform feedback, with no `MESA_KK_EXPERIMENTAL`. Then
  [`smoke/d3d12.c`](../smoke/d3d12.c), compiled for x86_64, i686 and
  aarch64, must get the `dxmt` tree and go through D3D12 as a game does:
  devices on DXMT's adapter and without one, a swapchain for a visible
  window with a clear read back, presents, a resize, a frame latency
  handle, and the swapchains Windows refuses (its header lists the steps
  and their exit statuses). Last,
  [`smoke/wined3d.c`](../smoke/wined3d.c), compiled for x86_64 and i686,
  must create a device for a hidden window through wined3d twice, with the
  `winediag` channel on: with the default renderer, where wined3d must not
  report the Vulkan renderer, and with a `wined3d=vulkan` rule for the
  program, where it must. The i686 program uses Direct3D 8. Wine builds no
  64-bit `d3d8.dll`, so the x86_64 one uses Direct3D 9, with a rule giving
  it the `wined3d` d3d9 tree in both runs. KosmicKrisp only uses a GPU of
  the Metal 4 family, and a Mac without one, such as the virtual machine of
  a hosted CI runner, gives it no device. There, `vulkan.exe` has to fail
  creating its instance after the Vulkan loader read the bundled manifest
  and found no GPU, `d3d12.exe` has to fail creating its first device with
  `E_FAIL` after the same, the `wined3d=vulkan` runs and the host EGL
  check are left out, and Mesa's EGL, which the `opengl-egl` rule asks
  for, gives no OpenGL. So `wgl.exe` runs by default once per arch, where
  the rule must have handed over `opengl=egl` and the program must get no
  context, and the runs that need OpenGL, `wgl.exe` and the wined3d runs
  with the default renderer, give the program a rule with `opengl=cgl` for
  Apple's. The
  Mac driver only asks Apple's OpenGL for an accelerated renderer, and a
  Mac without one, such as the same virtual machine with only Apple's
  software renderer, gives wined3d no OpenGL context. There, `wgl.exe`
  does not run on Apple's OpenGL, and the wined3d runs with the default
  renderer have to fail creating the Direct3D object after the Mac
  driver's request for a renderer failed and wined3d got no context for
  its adapter, still with the `wined3d` d3d9 tree for the x86_64 one. The
  step decides each case from the hardware alone, with
  [`smoke/metal4.m`](../smoke/metal4.m) and
  [`smoke/opengl.m`](../smoke/opengl.m), one independent of the other,
  and says which checks it left out. Every run has a time limit, and
  none may print Wine's message that it cannot find FreeType: Wine then
  runs without TrueType fonts, and the program still succeeds.

With `--compatdb-only`, the bundle step:

- refuses a bundle that lacks the Vulkan loader, KosmicKrisp or its
  manifest, such as one from before this build had Vulkan, and names what
  is missing. compatdb.so does not disable `vulkan-1`, so in such a bundle
  a game's own `vulkan-1.dll` would load and find no driver, and the smoke
  test's Vulkan checks need Vulkan anyway. Such a bundle needs a full
  bundle step;
- refuses, before it replaces anything, a bundle whose 64-bit marker of a
  Direct3D name is not a hybrid one, such as one from before the `dxmt` and
  `mtld3d` trees were ARM64X: this compatdb.so gives native ARM64 programs
  those trees, which they could not load there. Such a bundle needs a full
  bundle step too;
- refuses, before it replaces anything, a bundle whose `ntdll.so` does not
  export `set_compat_force_nx` and `set_compat_opengl`: there this
  compatdb.so could not keep no-execute on or ask for Mesa's EGL, and every
  process would get Apple's OpenGL. Such a bundle needs a full bundle step
  too;
- builds `compatdb.so` and replaces the installed copy by copy and rename,
  so a running process keeps a valid mapping;
- removes quarantine from `compatdb.so` only, and only when it is there;
- checks that the installed file matches the build output, the
  `LEAK_PREFIXES` references and `minos` of `compatdb.so` only (the rest
  was not built here), and runs the smoke test. On a bundle from before
  vkd3d-proton, which has no `d3d12.dll` in the `dxmt` tree, it leaves out
  the D3D12 checks and says so;
- needs a bundle whose KosmicKrisp advertises its features without
  `MESA_KK_EXPERIMENTAL`, since this compatdb.so no longer sets it. On an
  older bundle `vulkan.exe` finds no transform feedback on a Mac with a
  Metal 4 GPU and the step stops with a hint to bundle the whole build. On
  a Mac without one, such as a hosted CI runner, `vulkan.exe` has to find
  no device anyway, so the transform feedback check does not apply there
  and an older bundle passes with only the checks above left out.

## Homebrew libraries and the floor

The libraries in `lib/external/` other than Mesa's (the Vulkan loader,
KosmicKrisp, EGL and the gallium library) are Homebrew's: the formulae in
`DEPS_FORMULAE` and their runtime closure, copied from `DEPS_PREFIX`.
Homebrew builds each bottle for one macOS major version, the bottle tag,
with the deployment target at that version's `.0` release, and pours the
bottle of the host's version. The host therefore decides whether those
libraries meet the floor:

- On a host of the floor's major version, every bottle's `minos` is below
  the floor. A CI or release build has to run on such a host, takes the
  libraries from Homebrew and passes `--strict-floor`, so a file above the
  floor fails the bundle step. The release workflows run on a runner of that
  version ([releases](maintenance.md#releases)).
- On a newer macOS, Homebrew pours that version's bottles, and the bundle
  step warns about each of them. That is expected for a local build, which
  is not distributed.
- A formula with no bottle for the host's version is compiled on the host
  and carries the host's full version as `minos`, which can be above the
  floor even on a host of its major version. `--strict-floor` stops such a
  bundle.
- Before moving such a build to another macOS version, check the bottles of
  that version: the formula's JSON at
  `formulae.brew.sh/api/formula/<name>.json` lists the bottle of every tag.
  `brew fetch --bottle-tag` may not know other tags, since brew's own API
  data can carry the host's tag only. Unpack each bottle and read its
  dylibs' `minos` with `vtool -show-build`.

Nothing from Homebrew is linked statically into a file the bundle ships.
Wine's unix modules load the libraries above by soname and link none of
them. Mesa's second stage is built with pkg-config searching nowhere and
Homebrew off `PATH`, and `build-mesa.sh` checks that the driver, EGL, the
gallium library and the loader load system libraries only, besides EGL
loading the gallium library next to it.
The static libraries that `winemetal.so` and the driver do link (DXMT's
LLVM, and DXMT's and Mesa's own archives) are built here for the floor. A
linked binary's `minos` does not show an object inside it that needs a
newer macOS; only the linker's warning that an object file `was built for
newer` macOS than the one being linked does. After adding a static
dependency, search a clean build's log for it.

## Limitations

- A native ARM64 program cannot load a Direct3D name whose marker in
  `aarch64-windows` is AMD64; the loader fails with error 193
  (`ERROR_BAD_EXE_FORMAT`). The prefix's placeholder for each name comes
  from that marker, and the placeholder's machine decides which module Wine
  looks for. The bundle step therefore gives every 64-bit Direct3D name a
  hybrid marker, which both kinds of process accept, and requires every
  64-bit module of every tree to be ARM64X (DXMT's, vkd3d-proton's,
  mtld3d's and Wine's are), so that it serves both
  ([Direct3D trees](maintenance.md#direct3d-trees)). A tree changed after
  the bundle step, such as by a development install of mtld3d, has to keep
  to that, or a native ARM64 program cannot load its module. Which tree a
  native ARM64 program gets is compatdb's choice
  ([native ARM64 programs](compatdb.md#native-arm64-programs)).

## Pinned inputs

| Input | Pinned in |
|-------|-----------|
| FEX | [`fex-src.ref`](../pins/fex-src.ref): a branch, tag or commit of `FEX_REPO` |
| mtld3d | [`redist.env`](../pins/redist.env), URL and SHA-256 of the release tarball |
| DXMT | [`dxmt-src.ref`](../pins/dxmt-src.ref): a branch, tag or commit of `DXMT_REPO` |
| vkd3d-proton | [`vkd3d-proton-src.ref`](../pins/vkd3d-proton-src.ref): a branch, tag or commit of `VKD3D_PROTON_REPO`; its submodules at the commits that ref records |
| LLVM for DXMT's `winemetal.so` | [`redist.env`](../pins/redist.env), tag and commit; `build-dxmt.sh` fails when the tag is not at the commit |
| Mesa (KosmicKrisp) | [`mesa-src.ref`](../pins/mesa-src.ref): a branch, tag or commit of `MESA_REPO` |
| Vulkan loader and headers | [`redist.env`](../pins/redist.env), tag and commit of each, from one SDK release; `build-mesa.sh` fails when a tag is not at its commit |
| Python modules of Mesa's build scripts | [`redist.env`](../pins/redist.env), as pip requirements with exact versions |
| Wine | Whatever `WINE_SRC` has checked out, normally [`arm64-patched`](https://github.com/athei/wine/tree/arm64-patched); nothing pins a commit. A CI build checks out the branch [`wine-src.ref`](../pins/wine-src.ref) names. The SDK and DXMT record the commit they were built against (with `-dirty` when tracked files differ, which counts all uncommitted states as one), and the bundle step refuses either when it is not the current one |
| Homebrew libraries | Not pinned: whatever the host's Homebrew has ([Homebrew libraries and the floor](#homebrew-libraries-and-the-floor)). A CI build installs the formulae in [`brew-formulae`](../pins/brew-formulae) at the newest versions Homebrew has when it runs ([Homebrew formulae](maintenance.md#homebrew-formulae)) |
| llvm-mingw | Of a CI build: [`redist.env`](../pins/redist.env), version and SHA-256 of the release archive. A local build uses `MINGW_DIR` |
| Provisioning profile | [`signing/loader.provisionprofile`](../signing/loader.provisionprofile); replace the file when it expires or the App ID changes |
