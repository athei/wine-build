#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
CACHE_DIR="${CACHE_DIR:-$ROOT/cache}"
MINGW_DIR="${MINGW_DIR:-/opt/llvm-mingw}"

# URL and SHA-256 of every third-party artifact (GPTK_URL/GPTK_SHA256 etc.).
# shellcheck source=redist.env
. "$SCRIPT_DIR/redist.env"
DIST_DIR=""
RUNTIME_ONLY=0

# `make install` may rebuild any stale targets, including PE modules that need mingw.
if [ -d "$MINGW_DIR/bin" ]; then
    export PATH="$PATH:$MINGW_DIR/bin"
fi

usage() {
    echo "Usage: $0 --dest <dir> [--runtime-only]"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dest) DIST_DIR="$2"; shift 2 ;;
        --runtime-only) RUNTIME_ONLY=1; shift ;;
        *) usage ;;
    esac
done

if [ -z "$DIST_DIR" ]; then
    echo "Error: --dest is required"
    usage
fi

# fetch <url> <sha256>: download an artifact into $CACHE_DIR, or reuse the
# cached copy when its checksum still matches the pin. Prints the local path.
# A cached copy that no longer matches is stale (a bump that kept the file
# name, as mtld3d.tar.xz does) and is replaced. A fresh download that does
# not match is an error, not a retry: either the pin in redist.env is wrong
# or the download is, and both need a human. Downloads land in a .part file
# first, so an interrupted run never leaves a plausible-looking file behind.
fetch() {
    local url="$1" want="$2"
    local name target got
    name=$(basename "$url")
    target="$CACHE_DIR/$name"
    if [ -f "$target" ]; then
        got=$(shasum -a 256 "$target" | cut -d' ' -f1)
        if [ "$got" = "$want" ]; then
            echo "    $name (cached)" >&2
            echo "$target"
            return 0
        fi
        echo "    $name: cached copy does not match redist.env, re-downloading" >&2
        rm -f "$target"
    fi
    echo "    $name (downloading)" >&2
    mkdir -p "$CACHE_DIR"
    curl -fsSL --retry 3 -o "$target.part" "$url"
    got=$(shasum -a 256 "$target.part" | cut -d' ' -f1)
    if [ "$got" != "$want" ]; then
        rm -f "$target.part"
        echo "Error: $name checksum mismatch" >&2
        echo "  expected $want" >&2
        echo "  got      $got" >&2
        echo "  from     $url" >&2
        return 1
    fi
    mv "$target.part" "$target"
    echo "$target"
}

# ── Step 0: Clean previous bundle ──────────────────────────────────────
WINE_DIR="$DIST_DIR/wine"
if [ -d "$WINE_DIR" ]; then
    echo "Will delete existing bundle: $WINE_DIR"
    read -r -p "Continue? [y/N] " confirm
    case "$confirm" in
        [yY]) rm -rf "$WINE_DIR" ;;
        *) echo "Aborted."; exit 1 ;;
    esac
fi
mkdir -p "$DIST_DIR"

# ── Step 1: Staged install ──────────────────────────────────────────────
cd "$BUILD_DIR"
if [ "$RUNTIME_ONLY" -eq 1 ]; then
    echo "==> Step 1: Staged install (runtime only)"
    arch -x86_64 make install-lib DESTDIR="$DIST_DIR"
else
    echo "==> Step 1: Staged install with DESTDIR"
    arch -x86_64 make install DESTDIR="$DIST_DIR"
fi

# ── Step 2: Flatten prefix ──────────────────────────────────────────────
echo "==> Step 2: Flatten prefix"
mv "$DIST_DIR/usr/local" "$DIST_DIR/wine"
rm -rf "$DIST_DIR/usr"

EXT_DIR="$WINE_DIR/lib/external"

# ── Step 2b: Bundle the d3d9 test binaries ──────────────────────────────
# Wine's `make install` skips test binaries, so copy the two `d3d9_test.exe`
# in by hand. They are the de-facto D3D9 conformance suite, and shipping them
# lets a consumer gate its own d3d9 builtin against the suite with nothing but
# this bundle (no Wine build tree, which is what a CI job has). Plain PEs that
# `wine` executes, so they are NOT builtin-marked, and they live outside the
# per-arch module directories the loader searches by module name.
#
# Development files only: the runtime-only bundle goes into an application, and
# a test suite has no business there.
if [ "$RUNTIME_ONLY" -eq 0 ]; then
    echo "==> Step 2b: Bundle the d3d9 test binaries"
    for arch in i386-windows x86_64-windows; do
        src="$BUILD_DIR/dlls/d3d9/tests/$arch/d3d9_test.exe"
        if [ ! -f "$src" ]; then
            echo "Error: $src not found (run build-wine.sh first)"
            exit 1
        fi
        echo "    $arch/d3d9_test.exe"
        mkdir -p "$WINE_DIR/lib/wine/tests/$arch"
        cp "$src" "$WINE_DIR/lib/wine/tests/$arch/"
    done
fi

# ── Step 3: Bundle dynamic libraries ────────────────────────────────────
# Wine's .so modules dlopen these via @loader_path sonames (patched in Step 0).
# Transitive deps are loaded by dyld from their @loader_path install names.
echo "==> Step 3: Bundle dynamic libraries"
mkdir -p "$EXT_DIR"

# Direct deps: Wine dlopen's these by soname. build-wine.sh patches their
# sonames in config.h to @loader_path/../../external/<name>, so config.h is
# the authoritative (version-correct) list; resolve each against /usr/local/lib.
# Deduplicated, since one library can back several defines.
CONFIG_H="$BUILD_DIR/include/config.h"
if [ ! -f "$CONFIG_H" ]; then
    echo "Error: $CONFIG_H not found (run build-wine.sh first)"
    exit 1
fi
LIBS=()
for name in $(sed -n 's|.*"@loader_path/\.\./\.\./external/\([^"]*\)".*|\1|p' "$CONFIG_H" | sort -u); do
    LIBS+=("/usr/local/lib/$name")
done
if [ ${#LIBS[@]} -eq 0 ]; then
    echo "Error: no @loader_path sonames in $CONFIG_H: the build is not"
    echo "relocatable (config.h lost its soname patches). Re-run build-wine.sh."
    exit 1
fi
# Homebrew's "libSDL2" is sdl2-compat, a shim that loads real SDL3 at runtime
# via @loader_path/libSDL3.dylib, so SDL3 must sit beside it in the bundle.
LIBS+=(/usr/local/lib/libSDL3.dylib)

echo "  Copying direct deps..."
MISSED=0
for lib in "${LIBS[@]}"; do
    name=$(basename "$lib")
    if [ -f "$lib" ]; then
        echo "    $name"
        cp -L "$lib" "$EXT_DIR/$name"
    else
        echo "    MISSING: $name from $lib"
        MISSED=1
    fi
done

# Transitive deps: walk the otool -L closure, copying every /usr/local
# dependency until no new ones appear. Line 2 of otool -L is the dylib's
# own install name, not a dependency, so skip it.
echo "  Copying transitive deps..."
while :; do
    added=0
    for dylib in "$EXT_DIR"/*.dylib; do
        for dep in $(otool -L "$dylib" | tail -n +3 | awk '{print $1}'); do
            case "$dep" in
                /usr/local/*)
                    depname=$(basename "$dep")
                    if [ -f "$EXT_DIR/$depname" ]; then
                        :
                    elif [ -f "$dep" ]; then
                        echo "    $depname (needed by $(basename "$dylib"))"
                        cp -L "$dep" "$EXT_DIR/$depname"
                        added=1
                    else
                        echo "    MISSING: $depname (needed by $(basename "$dylib")) from $dep"
                        MISSED=1
                    fi
                    ;;
            esac
        done
    done
    [ $added -eq 0 ] && break
done
if [ $MISSED -ne 0 ]; then
    echo "Error: required libraries are missing, bundle would not be self-contained"
    exit 1
fi
chmod +w "$EXT_DIR"/*.dylib

# Fix install names so bundled dylibs reference each other via @loader_path
echo "  Fixing install names..."
for dylib in "$EXT_DIR"/*.dylib; do
    name=$(basename "$dylib")
    install_name_tool -id "@loader_path/$name" "$dylib"
    for dep in $(otool -L "$dylib" | tail -n +2 | awk '{print $1}'); do
        case "$dep" in
            /usr/local/*)
                depname=$(basename "$dep")
                if [ -f "$EXT_DIR/$depname" ]; then
                    install_name_tool -change "$dep" "@loader_path/$depname" "$dylib"
                fi
                ;;
        esac
    done
done

# ── Step 4: Direct3D backends ───────────────────────────────────────────
# Direct3D comes from three third-party implementations that talk to Metal
# directly, plus Wine's own wined3d as the fallback for each: Apple's D3DMetal
# (Game Porting Toolkit) for x86_64 D3D10-12, DXMT for the i386 half of that,
# which Apple does not cover, and mtld3d for D3D9 on both. Every one of them
# lives in its own tree under lib/wine/dxgi/<impl> or lib/wine/d3d9/<impl>;
# the default dirs hold only fake-module markers, and compatdb.so (Step 4b)
# picks one tree per family per process. D3D8 and DDraw stay on wined3d only.
#
# Deliberately after Step 3: that step's dependency walk, chmod and
# install_name_tool loops all iterate $EXT_DIR/*.dylib, and none of them may
# touch the Apple-signed libd3dshared.dylib. Staging afterwards keeps them out
# of reach without any exemption logic. Nothing below rewrites install names,
# re-signs, or walks the otool closure.
echo "==> Step 4: Direct3D backends"

# All three are downloaded (or taken from the cache) before anything is
# installed, so a bad pin fails the run before the tree is half-modified.
echo "  Fetching artifacts into $CACHE_DIR..."
GPTK_DMG=$(fetch "$GPTK_URL" "$GPTK_SHA256")
DXMT_TAR=$(fetch "$DXMT_URL" "$DXMT_SHA256")
MTLD3D_TAR=$(fetch "$MTLD3D_URL" "$MTLD3D_SHA256")

TMP_DIR=$(mktemp -d)
GPTK_MNT="$TMP_DIR/gptk"
cleanup() {
    if [ -d "$GPTK_MNT" ]; then
        hdiutil detach "$GPTK_MNT" -quiet 2>/dev/null || true
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# Wine's own D3D12 (vkd3d) and Vulkan modules cannot work in a build configured
# --without-vulkan, and x86_64 D3D12 is D3DMetal's below. Drop them rather than
# ship modules that advertise an API they cannot serve. d3d10core stays on both
# arches: i386's is replaced by DXMT, and on x86_64 it is Wine's, loaded only by
# the wined3d side tree (D3DMetal's dxgi cannot back it, so the default GPTK
# stack never reaches it).
echo "  Removing the modules Vulkan removal orphans..."
for dead in \
    i386-windows/vulkan-1.dll \
    i386-windows/winevulkan.dll \
    i386-windows/d3d12.dll \
    i386-windows/d3d12core.dll \
    x86_64-windows/vulkan-1.dll \
    x86_64-windows/winevulkan.dll \
    x86_64-windows/d3d12core.dll \
    x86_64-unix/winevulkan.so
do
    if [ -e "$WINE_DIR/lib/wine/$dead" ]; then
        echo "    $dead"
        rm -f "$WINE_DIR/lib/wine/$dead"
    fi
done

# D3DMetal, straight off the GPTK image. Apple's license allows redistributing
# the Redistributables unmodified for non-commercial purposes, so the files are
# copied byte for byte, signatures and all. `ditto` preserves the symlinks
# (each x86_64-unix/*.so points at ../../external/libd3dshared.dylib) and the
# framework's _CodeSignature directory; `cp -R` would not.
# The image carries a click-through license agreement, which hdiutil prompts
# for on stdin and would otherwise block a CI run forever. The here-string
# answers it and PAGER keeps the agreement text from being paged.
echo "  Mounting $(basename "$GPTK_DMG")..."
mkdir -p "$GPTK_MNT"
PAGER=cat hdiutil attach "$GPTK_DMG" \
    -readonly -nobrowse -noautoopen -mountpoint "$GPTK_MNT" -quiet <<< "Y"

# Located rather than hardcoded, so a renamed volume or a reshuffled image does
# not silently install nothing.
GPTK_LIB=$(find "$GPTK_MNT" -maxdepth 4 -type d -path '*/redist/lib' -print -quit)
if [ -z "$GPTK_LIB" ]; then
    echo "Error: no redist/lib directory on $(basename "$GPTK_DMG")"
    exit 1
fi

echo "  Installing D3DMetal (x86_64 d3d10/d3d11/d3d12/dxgi)..."
ditto "$GPTK_LIB/external" "$EXT_DIR"
ditto "$GPTK_LIB/wine/x86_64-unix" "$WINE_DIR/lib/wine/x86_64-unix"
ditto "$GPTK_LIB/wine/x86_64-windows" "$WINE_DIR/lib/wine/x86_64-windows"

# nvngx is what games look for when probing DLSS; Apple ships its MetalFX
# implementation under a descriptive name that no game ever loads. wine.inf
# already registers nvapi64.dll and nvngx.dll as fake DLLs.
echo "    nvngx-on-metalfx -> nvngx"
mv -f "$WINE_DIR/lib/wine/x86_64-windows/nvngx-on-metalfx.dll" \
      "$WINE_DIR/lib/wine/x86_64-windows/nvngx.dll"
rm -f "$WINE_DIR/lib/wine/x86_64-unix/nvngx-on-metalfx.so"
ln -sf ../../external/libd3dshared.dylib "$WINE_DIR/lib/wine/x86_64-unix/nvngx.so"

GPTK_LICENSE=$(find "$GPTK_MNT" -maxdepth 2 -iname 'License.rtf' -print -quit)
if [ -n "$GPTK_LICENSE" ]; then
    echo "    D3DMetal-License.rtf"
    cp "$GPTK_LICENSE" "$EXT_DIR/D3DMetal-License.rtf"
else
    echo "Error: no License.rtf on $(basename "$GPTK_DMG")"
    exit 1
fi

hdiutil detach "$GPTK_MNT" -quiet
rmdir "$GPTK_MNT" 2>/dev/null || true

# DXMT covers the 32-bit half Apple does not ship. Its x86_64-windows DLLs are
# deliberately left out: 64-bit is D3DMetal's. The single x86_64-unix
# winemetal.so serves the i386 PE modules through its wow64 entry points, so
# there is no i386-unix half to install (and in new WoW64 there is no such
# directory anyway).
echo "  Installing DXMT (i386 d3d10core/d3d11/dxgi)..."
mkdir -p "$TMP_DIR/dxmt"
tar xzf "$DXMT_TAR" -C "$TMP_DIR/dxmt"
DXMT_SRC=$(find "$TMP_DIR/dxmt" -mindepth 1 -maxdepth 1 -type d -print -quit)
if [ -z "$DXMT_SRC" ]; then
    echo "Error: $(basename "$DXMT_TAR") has no top-level directory"
    exit 1
fi
echo "    $(basename "$DXMT_SRC")"
cp "$DXMT_SRC"/i386-windows/*.dll "$WINE_DIR/lib/wine/i386-windows/"
cp "$DXMT_SRC"/x86_64-unix/winemetal.so "$WINE_DIR/lib/wine/x86_64-unix/"

# mtld3d's tarball mirrors the lib/wine layout under wine/, but the files are
# named explicitly rather than copied wholesale: wine/<arch>-windows also
# carries mtld3d.fake.dll, the prefix marker for installs into an existing
# prefix, and aarch64-unix/ is for an arm64 Wine, which this is not. The
# prefixes this bundle creates get their markers from wine.inf's wildcard over
# the default dirs (stamped below).
echo "  Unpacking mtld3d..."
mkdir -p "$TMP_DIR/mtld3d"
tar xf "$MTLD3D_TAR" -C "$TMP_DIR/mtld3d"
MTLD3D_SRC="$TMP_DIR/mtld3d/wine"
if [ ! -d "$MTLD3D_SRC" ]; then
    echo "Error: $(basename "$MTLD3D_TAR") has no wine/ directory"
    exit 1
fi

# ── Direct3D: everything additive under dxgi/<impl> and d3d9/<impl> ─────
# The default <arch>-windows dirs ship NO real Direct3D. compatdb.so always
# loads and prepends exactly one tree per family per process (the arch
# default, or a database override) via prepend_dll_path, so a DXGI stack is
# never mixed and nothing is ever removed. Each implementation is a
# self-contained tree; the default dirs keep only fake-module markers so
# wineboot's 11,,* wildcard stamps the system32/syswow64 placeholder every
# builtin needs.
echo "  Building Direct3D trees under dxgi/<impl> and d3d9/<impl>..."
WINEBUILD="$BUILD_DIR/tools/winebuild/winebuild"
d3d64="$WINE_DIR/lib/wine/x86_64-windows"
d3d32="$WINE_DIR/lib/wine/i386-windows"
unix64="$WINE_DIR/lib/wine/x86_64-unix"
tree="$WINE_DIR/lib/wine/dxgi"
d3d9tree="$WINE_DIR/lib/wine/d3d9"

# wined3d (both arches): Wine's own dxgi/d3d10/d3d10core/d3d11/d3d10_1 from the
# build tree. No d3d12 (vkd3d is unusable --without-vulkan); wined3d.dll itself
# stays in the default dir (the GL engine, shared, reached by fall-through).
for arch in i386-windows x86_64-windows; do
    dest="$tree/wined3d/$arch"
    mkdir -p "$dest"
    for dll in dxgi d3d10 d3d10core d3d11 d3d10_1; do
        src="$BUILD_DIR/dlls/$dll/$arch/$dll.dll"
        if [ ! -f "$src" ]; then
            echo "Error: $src not found (run build-wine.sh first)"
            exit 1
        fi
        cp "$src" "$dest/"
    done
done

# gptk (x86_64): D3DMetal's dxgi/d3d10/d3d11/d3d12 (+ nvngx/nvapi64), moved out
# of the default dir, their unixlib symlinks re-pointed at the deeper path.
gw="$tree/gptk/x86_64-windows"
gu="$tree/gptk/x86_64-unix"
mkdir -p "$gw" "$gu"
for dll in dxgi d3d10 d3d11 d3d12 nvngx nvapi64; do
    mv -f "$d3d64/$dll.dll" "$gw/$dll.dll"
    rm -f "$unix64/$dll.so"
    ln -sf ../../../../external/libd3dshared.dylib "$gu/$dll.so"
done
# D3DMetal ships no d3d10core/d3d10_1; Wine's were reachable by GPTK processes
# in the old default dir (they return E_FAIL on GPTK's dxgi but must be present
# so anything probing D3D10 keeps its old behaviour rather than failing to
# load). Pure PE, no unixlib.
cp "$BUILD_DIR/dlls/d3d10core/x86_64-windows/d3d10core.dll" "$gw/"
cp "$BUILD_DIR/dlls/d3d10_1/x86_64-windows/d3d10_1.dll"     "$gw/"

# dxmt (x86_64 + i386): DXMT's dxgi/d3d10core/d3d11/winemetal plus Wine's
# d3d10/d3d10_1. The single x86_64 winemetal.so is shared by both via a symlink;
# an i386 process finds it under the tree's x86_64-unix (its wow64 unixlib).
dx64="$tree/dxmt/x86_64-windows"
dxu="$tree/dxmt/x86_64-unix"
dx32="$tree/dxmt/i386-windows"
mkdir -p "$dx64" "$dxu" "$dx32"
cp "$DXMT_SRC"/x86_64-windows/dxgi.dll \
   "$DXMT_SRC"/x86_64-windows/d3d10core.dll \
   "$DXMT_SRC"/x86_64-windows/d3d11.dll \
   "$DXMT_SRC"/x86_64-windows/winemetal.dll \
   "$dx64/"
cp "$BUILD_DIR/dlls/d3d10/x86_64-windows/d3d10.dll"     "$dx64/"
cp "$BUILD_DIR/dlls/d3d10_1/x86_64-windows/d3d10_1.dll" "$dx64/"
ln -sf ../../../x86_64-unix/winemetal.so "$dxu/winemetal.so"
cp "$DXMT_SRC"/i386-windows/dxgi.dll \
   "$DXMT_SRC"/i386-windows/d3d10core.dll \
   "$DXMT_SRC"/i386-windows/d3d11.dll \
   "$DXMT_SRC"/i386-windows/winemetal.dll \
   "$dx32/"
cp "$BUILD_DIR/dlls/d3d10/i386-windows/d3d10.dll"     "$dx32/"
cp "$BUILD_DIR/dlls/d3d10_1/i386-windows/d3d10_1.dll" "$dx32/"

# Empty the default dirs of the rest of the stack (real impls now live in the
# trees above): Wine's d3d10core/d3d10_1 on x86_64, DXMT's whole i386 set. GPTK
# was moved above. winemetal.so stays in x86_64-unix (shared backend).
rm -f "$d3d64/d3d10core.dll" "$d3d64/d3d10_1.dll"
rm -f "$d3d32"/dxgi.dll "$d3d32"/d3d10.dll "$d3d32"/d3d10core.dll \
      "$d3d32"/d3d10_1.dll "$d3d32"/d3d11.dll "$d3d32"/winemetal.dll

# D3D9, the second family: mtld3d (the default on both arches) and Wine's own.
# mtld3d's d3d9.dll bridges to its mtld3d.dll, whose unix half is the single
# x86_64 mtld3d.so that also serves the i386 PE through its wow64 entry points.
# wined3d's d3d9.dll needs only wined3d.dll, which stays in the default dir.
# Wine's d3d9.dll that `make install` put in the default dirs is the one file
# both trees would shadow, so it goes and a marker takes its place below.
echo "    d3d9/mtld3d, d3d9/wined3d"
for arch in i386-windows x86_64-windows; do
    mkdir -p "$d3d9tree/mtld3d/$arch" "$d3d9tree/wined3d/$arch"
    cp "$MTLD3D_SRC/$arch/d3d9.dll" "$MTLD3D_SRC/$arch/mtld3d.dll" \
       "$d3d9tree/mtld3d/$arch/"
    src="$BUILD_DIR/dlls/d3d9/$arch/d3d9.dll"
    if [ ! -f "$src" ]; then
        echo "Error: $src not found (run build-wine.sh first)"
        exit 1
    fi
    cp "$src" "$d3d9tree/wined3d/$arch/"
done
mkdir -p "$d3d9tree/mtld3d/x86_64-unix"
cp "$MTLD3D_SRC/x86_64-unix/mtld3d.so" "$d3d9tree/mtld3d/x86_64-unix/"
rm -f "$d3d64/d3d9.dll" "$d3d32/d3d9.dll"

# Fake-module markers in the default dirs. wineboot's 11,,* wildcard stamps a
# system32/syswow64 placeholder for each, which is what lets the prepended tree
# supply the real DLL (a builtin will not load without its placeholder). Each
# marker mirrors the exports of the real DLL it stands in for.
echo "  Stamping fake-module markers in the default dirs..."
mark() { # <out-dir> <32|64> <real-dll> <name>
    "$WINEBUILD" --fake-module -o "$1/$4.dll" -m"$2" --dll "$3"
}
for dll in dxgi d3d10 d3d10core d3d10_1 d3d11 d3d12 winemetal nvngx nvapi64; do
    for t in gptk/x86_64-windows dxmt/x86_64-windows wined3d/x86_64-windows; do
        if [ -f "$tree/$t/$dll.dll" ]; then mark "$d3d64" 64 "$tree/$t/$dll.dll" "$dll"; break; fi
    done
done
for dll in dxgi d3d10 d3d10core d3d10_1 d3d11 winemetal; do
    for t in dxmt/i386-windows wined3d/i386-windows; do
        if [ -f "$tree/$t/$dll.dll" ]; then mark "$d3d32" 32 "$tree/$t/$dll.dll" "$dll"; break; fi
    done
done
for dll in d3d9 mtld3d; do
    mark "$d3d64" 64 "$d3d9tree/mtld3d/x86_64-windows/$dll.dll" "$dll"
    mark "$d3d32" 32 "$d3d9tree/mtld3d/i386-windows/$dll.dll" "$dll"
done

# ── Step 4b: Compat database ────────────────────────────────────────────
# compatdb.so is what turns the trees above into a working Direct3D: ntdll
# dlopens <ntdll_dir>/compatdb.so in every process (the slot CrossOver hack
# 24067 provides) and the library prepends one dxgi/ and one d3d9/ tree,
# chosen per process from its built-in rules plus whatever WINE_COMPATDB
# carries. Built here from the compatdb/ crate; x86_64 only, because that is
# the only Wine in this bundle.
echo "==> Step 4b: Compat database"
if ! command -v cargo >/dev/null; then
    echo "Error: cargo not found (compatdb.so needs a Rust toolchain with the"
    echo "x86_64-apple-darwin target: rustup target add x86_64-apple-darwin)"
    exit 1
fi
CARGO_TARGET_DIR="$BUILD_DIR/compatdb" \
    cargo build --quiet --release --manifest-path "$SCRIPT_DIR/Cargo.toml" \
        -p compatdb --target x86_64-apple-darwin
echo "    x86_64-unix/compatdb.so"
cp "$BUILD_DIR/compatdb/x86_64-apple-darwin/release/libcompatdb.dylib" \
   "$unix64/compatdb.so"

# ── Step 5: Verify ──────────────────────────────────────────────────────
echo "==> Step 5: Verify"

echo "  wine binary: $(file "$WINE_DIR/bin/wine" | sed 's|.*/||')"

# Check bundled dylibs have no /usr/local refs
LEAKED=0
for dylib in "$EXT_DIR"/*.dylib; do
    if otool -L "$dylib" | grep -q "/usr/local/"; then
        echo "  ERROR: $(basename "$dylib") still references /usr/local/"
        LEAKED=1
    fi
done
# Check .so modules, including the side-tree unix libs (symlinks resolve to the
# real x86_64-unix modules, so this also proves the side-tree links are intact).
for so in "$WINE_DIR"/lib/wine/x86_64-unix/*.so \
          "$WINE_DIR"/lib/wine/dxgi/*/x86_64-unix/*.so \
          "$WINE_DIR"/lib/wine/d3d9/*/x86_64-unix/*.so; do
    [ -e "$so" ] || continue
    if otool -L "$so" 2>/dev/null | grep -q "/usr/local/"; then
        echo "  ERROR: $(basename "$so") still references /usr/local/"
        LEAKED=1
    fi
done
if [ $LEAKED -ne 0 ]; then
    echo "Error: bundle is not self-contained"
    exit 1
fi
echo "  All binaries clean, no /usr/local references."

# The Direct3D backends, which are copied in rather than built and so are not
# covered by anything the build would have caught.
MISSING=0
for want in \
    "lib/external/D3DMetal.framework/Versions/A/D3DMetal" \
    "lib/external/libd3dshared.dylib" \
    "lib/wine/x86_64-unix/compatdb.so" \
    "lib/wine/x86_64-unix/winemetal.so" \
    "lib/wine/dxgi/gptk/x86_64-windows/dxgi.dll" \
    "lib/wine/dxgi/gptk/x86_64-windows/d3d12.dll" \
    "lib/wine/dxgi/gptk/x86_64-unix/d3d11.so" \
    "lib/wine/dxgi/gptk/x86_64-unix/nvngx.so" \
    "lib/wine/dxgi/wined3d/x86_64-windows/dxgi.dll" \
    "lib/wine/dxgi/wined3d/x86_64-windows/d3d10_1.dll" \
    "lib/wine/dxgi/wined3d/i386-windows/dxgi.dll" \
    "lib/wine/dxgi/wined3d/i386-windows/d3d10_1.dll" \
    "lib/wine/dxgi/dxmt/x86_64-windows/dxgi.dll" \
    "lib/wine/dxgi/dxmt/x86_64-windows/winemetal.dll" \
    "lib/wine/dxgi/dxmt/x86_64-unix/winemetal.so" \
    "lib/wine/dxgi/dxmt/i386-windows/dxgi.dll" \
    "lib/wine/dxgi/dxmt/i386-windows/winemetal.dll" \
    "lib/wine/d3d9/mtld3d/x86_64-unix/mtld3d.so" \
    "lib/wine/d3d9/mtld3d/i386-windows/mtld3d.dll" \
    "lib/wine/d3d9/mtld3d/x86_64-windows/mtld3d.dll" \
    "lib/wine/d3d9/wined3d/i386-windows/d3d9.dll" \
    "lib/wine/d3d9/wined3d/x86_64-windows/d3d9.dll" \
    "lib/wine/x86_64-windows/dxgi.dll" \
    "lib/wine/i386-windows/dxgi.dll" \
    "lib/wine/x86_64-windows/d3d9.dll" \
    "lib/wine/i386-windows/d3d9.dll"
do
    # -e follows symlinks, so this also proves the GPTK .so links resolve.
    if [ ! -e "$WINE_DIR/$want" ]; then
        echo "  ERROR: missing $want"
        MISSING=1
    fi
done
# A d3d9.dll named like mtld3d's could still be Wine's; only a byte comparison
# proves the right copy landed in the tree.
for arch in i386-windows x86_64-windows; do
    if ! cmp -s "$MTLD3D_SRC/$arch/d3d9.dll" "$d3d9tree/mtld3d/$arch/d3d9.dll"; then
        echo "  ERROR: d3d9/mtld3d/$arch/d3d9.dll is not mtld3d's"
        MISSING=1
    fi
done
if [ $MISSING -ne 0 ]; then
    echo "Error: Direct3D backends are not installed correctly"
    exit 1
fi
echo "  D3DMetal, DXMT, mtld3d, wined3d and compatdb.so in place."

WINE_VERSION=$("$WINE_DIR/bin/wine" --version) || {
    echo "Error: bundled wine failed to run"
    exit 1
}
echo "  Testing: $WINE_VERSION"

# `wine --version` never loads ntdll, so it proves nothing about compatdb.so.
# Booting a throwaway prefix does: the library logs one block per process, and
# its "(from ...)" lines only appear once it found and prepended the trees. The
# Mono and Gecko installers are kept out so nothing pops a dialog.
echo "  Booting a throwaway prefix to check compatdb.so..."
SMOKE_LOG="$TMP_DIR/smoke.log"
WINEPREFIX="$TMP_DIR/prefix" WINEDLLOVERRIDES="mscoree,mshtml=" WINEDEBUG=-all \
    "$WINE_DIR/bin/wine" cmd /c exit >/dev/null 2>"$SMOKE_LOG" || {
    echo "Error: bundled wine failed to boot a prefix"
    cat "$SMOKE_LOG"
    exit 1
}
# The server is persistent, so it has to be told to go rather than waited for.
WINEPREFIX="$TMP_DIR/prefix" "$WINE_DIR/bin/wineserver" -k 2>/dev/null || true
for want in "dxgi = gptk (from" "d3d9 = mtld3d (from"; do
    if ! grep -q "compatdb: .*$want" "$SMOKE_LOG"; then
        echo "Error: compatdb.so did not report '$want'"
        grep "compatdb:" "$SMOKE_LOG" || echo "  (no compatdb lines at all)"
        exit 1
    fi
done
echo "  compatdb.so loads and finds its trees."

echo ""
echo "==> Done! Distribution is at:"
echo "    $DIST_DIR/wine/"
if [ "$RUNTIME_ONLY" -eq 1 ]; then
    echo "    (runtime only, no development files)"
fi
