#!/bin/bash
set -e

# Builds DXMT for the bundle from athei/dxmt (upstream DXMT with our commits
# on top; DXMT_REPO names another repository) at the ref in dxmt-src.ref (a
# branch, tag or commit) and stages it in DXMT_DIST, in the layout of a Wine
# install's lib/wine:
#
#   aarch64-windows/{dxgi,d3d10core,d3d11,winemetal}.dll   ARM64X
#   i386-windows/{dxgi,d3d10core,d3d11,winemetal}.dll      i386
#   aarch64-unix/winemetal.so
#   KEY          what the dist was built from (dist_key in profile.sh)
#   COMMIT       the source commit
#   DESCRIBE     its `git describe`, the version string DXMT builds into d3d11.dll
#   WINE_COMMIT  the Wine source commit it was linked against
#
# Called by build-wine.sh, after the Wine build and the Wine SDK, which this
# links against. bundle-wine.sh installs from DXMT_DIST.
#
# The 64-bit DLLs are ARM64X, built with DXMT's own build-arm64ec.txt cross
# file, whose -marm64x has the arm64ec llvm-mingw compile every source for
# ARM64EC and for ARM64 and link both halves into one image. An x64 game
# runs as ARM64EC, so it loads the ARM64EC half, and DXMT's code runs
# natively in it instead of under FEX; only the game's own x86 code is
# emulated. A native ARM64 program loads the ARM64 half. Wine looks up both
# kinds of 64-bit builtin in aarch64-windows, where they are staged. The
# configure takes the link libraries (libwinecrt0.a, libntdll.a,
# libdbghelp.a) from the Wine build tree (-Dwine_build_path), whose
# aarch64-windows archives are ARM64X themselves, and the same tree's
# winebuild marks the DLLs as builtins.
#
# The same tree builds the unix half, the arm64 winemetal.so. DXMT builds it
# as a native target of its meson project, with the architecture taken from
# the cross file, -arch arm64 under build-arm64ec.txt, and links it against
# the Wine build tree's winemac.so and ntdll.so. So the 64-bit DLLs and the
# .so come out of one meson tree, from one commit, as their private call
# interface needs.
#
# The i386 DLLs are x86 code, built with DXMT's build-win32.txt and
# llvm-mingw against the Wine SDK (-Dwine_install_path): its i386
# libwinecrt0.a, libntdll.a, libdbghelp.a and winebuild. A 32-bit game runs
# under WoW64 and FEX, and these DLLs run there with it, emulated. Only the
# DLLs and the targets that mark them as Wine builtins are built in that
# tree: the default targets include a winemetal.so, which there is built for
# x86_64 (DXMT takes -arch arm64 only for an aarch64 cross file) and cannot
# link against this Wine's arm64 libraries. It uses the same checkout as the
# 64-bit tree, so the i386 DLLs match the .so too.
#
# winemetal.so needs LLVM 15: it links airconv_dep_darwin, the static airconv
# library (DXMT's DXBC to Metal shader converter) that
# src/airconv/darwin/meson.build builds natively against native_llvm_path.
# The PE side only takes airconv's headers (airconv_forward_dep) unless
# build_airconv_for_windows is set, which it is not, but its configure still
# requires native_llvm_path to exist, so both trees point at DXMT_LLVM.
# There is no arm64 LLVM 15 to install, so its static libraries are built
# from the pinned tag into DXMT_LLVM, following Hadron's recipe, and reused
# while the pin stays.
#
# Nothing is built, LLVM included, when DXMT_DIST is complete and has the
# KEY this run would write (skip_current_dist in profile.sh). --clean wipes
# the DXMT checkout, trees and DXMT_DIST first (not DXMT_LLVM, which takes
# long to build and does not depend on anything here). --print-key prints
# that KEY and exits (print_dist_key); it needs the Wine source, not the
# Wine build.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MINGW_DIR="${MINGW_DIR:-/opt/llvm-mingw}"

CLEAN=0
PRINT_KEY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --clean) CLEAN=1; shift ;;
        --print-key) PRINT_KEY=1; shift ;;
        *) echo "Usage: $0 [--clean | --print-key]"; exit 1 ;;
    esac
done

# profile.sh names the Wine build tree and SDK to link against, DXMT_REPO,
# DXMT_BUILD_DIR, DXMT_LLVM, DXMT_DIST and the floor; redist.env pins LLVM.
# shellcheck source=lib/profile.sh
. "$SCRIPT_DIR/lib/profile.sh"
# shellcheck source=../pins/redist.env
. "$PINS_DIR/redist.env"

DXMT_REF="$(tr -d '[:space:]' < "$PINS_DIR/dxmt-src.ref")"
if [ -z "$DXMT_REF" ]; then
    echo "Error: $PINS_DIR/dxmt-src.ref is empty"
    exit 1
fi

DXMT_SRC="$DXMT_BUILD_DIR/src"
PE_DLLS="dxgi d3d10core d3d11 winemetal"

# ── Preflight ───────────────────────────────────────────────────────────
for tool in git meson ninja cmake xxd; do
    if ! command -v "$tool" >/dev/null; then
        echo "Error: $tool not found (brew install $tool)"
        exit 1
    fi
done
if ! xcrun -sdk macosx -f metal >/dev/null 2>&1; then
    echo "Error: no Metal compiler (xcrun metal); install Xcode and its Metal toolchain"
    exit 1
fi

# ── Dist ────────────────────────────────────────────────────────────────
# dxmt_key <commit>: the KEY of a DXMT_DIST built from <commit>. Besides the
# commit, what dxmt_setup below configures a tree again for: the Wine
# commit, whose build and SDK it links against, the LLVM commit and
# llvm-mingw's clang; how that Wine build is made, build-wine.sh, which the
# key hashes with this script; llvm-mingw's release; and what compiles
# winemetal.so and its shaders, which that key leaves out: Apple's clang,
# the macOS SDK, the Metal compiler and the floor.
WINE_COMMIT=$(wine_src_commit)
dxmt_key() {
    dist_key --hash "$SCRIPT_DIR/build-wine.sh" "$SCRIPT_DIR/build-dxmt.sh" "dxmt=$1" \
        "wine=$WINE_COMMIT" "llvm=$LLVM15_GIT_COMMIT" "$(mingw_key)" \
        "cc=$(cc_version /usr/bin/clang)" "$(sdk_key)" \
        "metal=$(xcrun -sdk macosx metal --version 2>/dev/null | head -n 1)" "floor=$MACOS_FLOOR"
}
DXMT_WANT=$(src_ref_commit dxmt-src.ref "$DXMT_REPO")
print_dist_key "$DXMT_WANT" dxmt-src.ref dxmt_key

# The checkouts and meson trees this script deletes and recreates are fixed
# paths in DXMT_BUILD_DIR. DXMT_LLVM and DXMT_DIST are inside it unless
# overridden, so they are claimed on their own, and so is DXMT_LLVM.part
# below.
claim_tree "$DXMT_BUILD_DIR" dxmt
claim_tree "$DXMT_LLVM" dxmt-llvm
# win64 and unix are the x86_64 PE and arm64 unix trees of the layout before
# the arm64x tree, which nothing builds any more.
if [ "$CLEAN" -eq 1 ]; then
    echo "==> Cleaning the DXMT trees..."
    remove_tree "$DXMT_SRC" "$DXMT_BUILD_DIR/arm64x" "$DXMT_BUILD_DIR/win32" \
                "$DXMT_BUILD_DIR/win64" "$DXMT_BUILD_DIR/unix"
fi
claim_tree "$DXMT_DIST" dxmt-dist "$CLEAN"
# A Wine source with uncommitted changes is one state ("-dirty") however
# those changes move, so a dist built against one is never taken as
# current; the build is then incremental.
case "$WINE_COMMIT" in
    *-dirty) ;;
    *) skip_current_dist "$DXMT_DIST" DXMT "$DXMT_WANT" dxmt_key ;;
esac

if [ ! -f "$BUILD_DIR/Makefile" ]; then
    echo "Error: no Wine build at $BUILD_DIR (run build-wine.sh first)"
    exit 1
fi
# The 64-bit tree links winemetal.so against the two .so files and the
# ARM64X DLLs against the build's ARM64X archives, and marks them as
# builtins with its winebuild.
for f in dlls/winemac.drv/winemac.so dlls/ntdll/ntdll.so \
         "dlls/ntdll/$PE64_DIR/libntdll.a" "dlls/dbghelp/$PE64_DIR/libdbghelp.a" \
         "libs/winecrt0/$PE64_DIR/libwinecrt0.a" tools/winebuild/winebuild; do
    if [ ! -f "$BUILD_DIR/$f" ]; then
        echo "Error: $BUILD_DIR/$f not found (run build-wine.sh first)"
        exit 1
    fi
done
# The SDK, which the i386 DLLs link against, must be the one staged from
# this Wine source, or they would link against another Wine's unix call
# setup.
if [ "$(cat "$WINE_SDK_DIR/WINE_COMMIT" 2>/dev/null)" != "$WINE_COMMIT" ]; then
    echo "Error: the Wine SDK at $WINE_SDK_DIR is for $(cat "$WINE_SDK_DIR/WINE_COMMIT" 2>/dev/null || echo nothing),"
    echo "but $WINE_SRC is at $WINE_COMMIT (run build-wine.sh)"
    exit 1
fi
for f in bin/winebuild lib/wine/i386-windows/libwinecrt0.a; do
    if [ ! -f "$WINE_SDK_DIR/$f" ]; then
        echo "Error: the Wine SDK at $WINE_SDK_DIR has no $f (run build-wine.sh)"
        exit 1
    fi
done

# Appended, never prepended: llvm-mingw's bin/ has an unprefixed clang that
# would otherwise replace Apple's as the native compiler. DXMT's cross files
# name the tools without a path, so check that each resolves into
# llvm-mingw and not to some other mingw earlier in PATH.
export PATH="$PATH:$MINGW_DIR/bin"
for triple in i686-w64-mingw32 arm64ec-w64-mingw32; do
    for tool in gcc g++ ar strip windres; do
        if [ "$(command -v "$triple-$tool")" != "$MINGW_DIR/bin/$triple-$tool" ]; then
            echo "Error: $triple-$tool does not resolve to $MINGW_DIR/bin"
            echo "  (found: $(command -v "$triple-$tool" || echo nothing))"
            exit 1
        fi
    done
done
# The check that the 64-bit DLLs are ARM64X (pe_is_arm64x) reads them with it.
if [ ! -x "$MINGW_DIR/bin/llvm-readobj" ]; then
    echo "Error: no llvm-readobj in $MINGW_DIR/bin"
    exit 1
fi

# ── LLVM 15 ─────────────────────────────────────────────────────────────
# Only the libraries airconv links: no targets, no tools. The libc++ define
# and the other options are Hadron's, which builds LLVM 15 with the same
# SDK; zstd is off so the result needs nothing from Homebrew. DXMT_LLVM/COMMIT
# records the commit they were built from; libraries from another one (a
# bumped pin), or none, are rebuilt.
if [ "$(cat "$DXMT_LLVM/COMMIT" 2>/dev/null)" != "$LLVM15_GIT_COMMIT" ]; then
    echo "==> Building LLVM 15 static libraries into $DXMT_LLVM..."
    remove_tree "$DXMT_LLVM" "$DXMT_BUILD_DIR/llvm-build"
    pinned_clone "$LLVM15_GIT_URL" "$LLVM15_GIT_TAG" "$LLVM15_GIT_COMMIT" "$DXMT_BUILD_DIR/llvm-project"
    cmake -S "$DXMT_BUILD_DIR/llvm-project/llvm" -B "$DXMT_BUILD_DIR/llvm-build" -G Ninja \
        -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
        -DCMAKE_INSTALL_PREFIX="$DXMT_LLVM" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_FLOOR" \
        -DLLVM_HOST_TRIPLE=arm64-apple-darwin \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_FLAGS="-D_LIBCPP_KEEP_TRANSITIVE_INCLUDES_LLVM23" \
        -DLLVM_ENABLE_ASSERTIONS=On \
        -DLLVM_ENABLE_ZSTD=Off \
        -DLLVM_TARGETS_TO_BUILD="" \
        -DLLVM_BUILD_TOOLS=Off \
        -DLLVM_INCLUDE_BENCHMARKS=Off \
        -DLLVM_INCLUDE_TESTS=Off \
        -DLLVM_INCLUDE_EXAMPLES=Off \
        -DLLVM_VERSION_PRINTER_SHOW_HOST_TARGET_INFO=Off >/dev/null
    cmake --build "$DXMT_BUILD_DIR/llvm-build"
    # Installed next to DXMT_LLVM and renamed into place, so an interrupted
    # install never leaves a DXMT_LLVM behind.
    claim_tree "$DXMT_LLVM.part" dxmt-llvm 1
    cmake --install "$DXMT_BUILD_DIR/llvm-build" --prefix "$DXMT_LLVM.part" >/dev/null
    echo "$LLVM15_GIT_COMMIT" > "$DXMT_LLVM.part/COMMIT"
    mv "$DXMT_LLVM.part" "$DXMT_LLVM"
    # The source and build trees are large and no longer needed.
    remove_tree "$DXMT_BUILD_DIR/llvm-build" "$DXMT_BUILD_DIR/llvm-project"
fi

# ── DXMT source ─────────────────────────────────────────────────────────
# DXMT_SRC is this script's own scratch clone, not somebody's work tree, so
# it is forced to the ref on every run that builds instead of being refused
# when it has changes, as FEX's and Mesa's checkouts are. As in build-fex.sh,
# the ref is
# fetched from DXMT_REPO by URL, so a clone made from another repository (a
# changed DXMT_REPO) still builds what DXMT_REPO has, and git is kept from
# asking for credentials. A full clone, not a shallow one, with every tag:
# `git describe` needs the history back to the last tag, and a fetch by URL
# brings no tags of its own.
echo "==> DXMT source: $DXMT_REPO $DXMT_REF"
if [ ! -e "$DXMT_SRC/.git" ]; then
    GIT_TERMINAL_PROMPT=0 git clone --quiet --no-checkout "$DXMT_REPO" "$DXMT_SRC"
fi
GIT_TERMINAL_PROMPT=0 git -C "$DXMT_SRC" fetch --quiet --force --tags "$DXMT_REPO"
GIT_TERMINAL_PROMPT=0 git -C "$DXMT_SRC" fetch --quiet "$DXMT_REPO" "$DXMT_REF"
git -C "$DXMT_SRC" -c advice.detachedHead=false checkout --quiet --force --detach FETCH_HEAD
GIT_TERMINAL_PROMPT=0 git -C "$DXMT_SRC" submodule update --quiet --init --recursive --force
DXMT_COMMIT=$(git -C "$DXMT_SRC" rev-parse HEAD)
DXMT_DESCRIBE=$(git -C "$DXMT_SRC" describe --always)
echo "    at $DXMT_COMMIT ($DXMT_DESCRIBE)"

# ── Meson trees ─────────────────────────────────────────────────────────
# dxmt_setup <dir> <cross-file> <option>...: configure a DXMT tree, again
# from scratch whenever what it links against differs from what it was
# configured with: the DXMT commit, the Wine commit (the SDK archives and
# winemac.so and ntdll.so come from it), the LLVM commit, the options, or
# llvm-mingw's clang, which compiles the PE side. A fresh tree relinks and
# recompiles everything, which ninja would not do on its own for a library
# or compiler that changed outside it. A Wine source with uncommitted
# changes is one state ("-dirty") however those changes move; rebuild with
# --clean after changing it.
#
# DXMT's own d3d12.dll is never built: D3D12 comes from vkd3d-proton, whose
# DLLs go into the same tree. Its option is off by default too; it is
# passed so a changed default cannot put a second d3d12.dll into the build.
CLANG_VERSION=$("$MINGW_DIR/bin/clang" --version | head -n 1)
dxmt_setup() {
    local dir="$1" cross="$2" key
    shift 2
    set -- -Denable_d3d12=false "$@"
    key="$DXMT_COMMIT wine=$WINE_COMMIT llvm=$(cat "$DXMT_LLVM/COMMIT") $cross $* clang=$CLANG_VERSION"
    if [ "$(cat "$dir/.setup-key" 2>/dev/null)" != "$key" ]; then
        remove_tree "$dir"
        meson setup "$dir" "$DXMT_SRC" --cross-file "$DXMT_SRC/$cross" \
            --buildtype release -Dnative_llvm_path="$DXMT_LLVM" "$@" >/dev/null
        echo "$key" > "$dir/.setup-key"
    fi
}

# The PE DLLs and the custom targets that run `winebuild --builtin` on them.
PE_TARGETS=(src/dxgi/dxgi.dll.postproc src/d3d10/d3d10core.dll.postproc
            src/d3d11/d3d11.dll.postproc src/winemetal/winemetal.dll.postproc)

# The 64-bit tree: the ARM64X DLLs, linked against the Wine build tree's
# ARM64X archives, and winemetal.so, whose target pulls in only native
# libraries (DXBCParserNative and the darwin airconv library).
echo "==> Building DXMT's ARM64X PE DLLs and arm64 winemetal.so..."
dxmt_setup "$DXMT_BUILD_DIR/arm64x" build-arm64ec.txt -Dwine_build_path="$BUILD_DIR"
ninja -C "$DXMT_BUILD_DIR/arm64x" "${PE_TARGETS[@]}" src/winemetal/unix/winemetal.so

echo "==> Building DXMT's i386 PE DLLs..."
dxmt_setup "$DXMT_BUILD_DIR/win32" build-win32.txt -Dwine_install_path="$WINE_SDK_DIR"
ninja -C "$DXMT_BUILD_DIR/win32" "${PE_TARGETS[@]}"

# ── Stage ───────────────────────────────────────────────────────────────
echo "==> Staging DXMT into $DXMT_DIST..."
claim_tree "$DXMT_DIST" dxmt-dist 1
mkdir -p "$DXMT_DIST/$PE64_DIR" "$DXMT_DIST/i386-windows" "$DXMT_DIST/$UNIX_DIR"
for dll in $PE_DLLS; do
    case $dll in
        d3d10core) dir=d3d10 ;;
        *) dir=$dll ;;
    esac
    cp "$DXMT_BUILD_DIR/arm64x/src/$dir/$dll.dll" "$DXMT_DIST/$PE64_DIR/"
    cp "$DXMT_BUILD_DIR/win32/src/$dir/$dll.dll" "$DXMT_DIST/i386-windows/"
done
cp "$DXMT_BUILD_DIR/arm64x/src/winemetal/unix/winemetal.so" "$DXMT_DIST/$UNIX_DIR/"

# A cross file that silently fell back to another compiler would still
# produce DLLs, only of the wrong machine, and an ARM64EC DLL linked without
# -marm64x would carry the x86_64 machine and no ARM64 half. So each 64-bit
# DLL must be ARM64X (the ARM64 machine with ARM64EC metadata, pe_is_arm64x)
# and each i386 one i386. Each DLL must also carry Wine's builtin marker,
# which the postproc targets put there.
for dll in $PE_DLLS; do
    f="$DXMT_DIST/$PE64_DIR/$dll.dll"
    if ! pe_is_arm64x "$f"; then
        echo "Error: $PE64_DIR/$dll.dll is not ARM64X (PE machine $(pe_machine "$f"))"
        exit 1
    fi
    f="$DXMT_DIST/i386-windows/$dll.dll"
    [ "$(pe_machine "$f")" = 014c ] \
        || { echo "Error: i386-windows/$dll.dll has the PE machine $(pe_machine "$f"), not 014c"; exit 1; }
    for f in "$PE64_DIR/$dll.dll" "i386-windows/$dll.dll"; do
        head -c 128 "$DXMT_DIST/$f" | grep -qa "Wine builtin DLL" \
            || { echo "Error: $f is not marked as a Wine builtin"; exit 1; }
    done
done
if [ "$(lipo -archs "$DXMT_DIST/$UNIX_DIR/winemetal.so")" != arm64 ]; then
    echo "Error: $UNIX_DIR/winemetal.so is not an arm64-only Mach-O"
    exit 1
fi
# The DLLs carry the describe output as their version string; checked here so
# the record and the build cannot disagree.
if ! strings -a "$DXMT_DIST/$PE64_DIR/d3d11.dll" | grep -xF "$DXMT_DESCRIBE" >/dev/null; then
    echo "Error: d3d11.dll does not carry the version $DXMT_DESCRIBE"
    exit 1
fi
echo "$DXMT_DESCRIBE" > "$DXMT_DIST/DESCRIBE"
echo "$WINE_COMMIT" > "$DXMT_DIST/WINE_COMMIT"
dxmt_key "$DXMT_COMMIT" > "$DXMT_DIST/KEY"
# Written last, so a staged directory without it is an incomplete one.
echo "$DXMT_COMMIT" > "$DXMT_DIST/COMMIT"
echo "==> DXMT $DXMT_DESCRIBE staged."
