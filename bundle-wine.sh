#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
REDIST_DIR="${REDIST_DIR:-$SCRIPT_DIR/redist}"
MINGW_DIR="${MINGW_DIR:-/opt/llvm-mingw}"
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
# the authoritative (version-correct) list — resolve each against /usr/local/lib.
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
    echo "Error: no @loader_path sonames in $CONFIG_H — the build is not"
    echo "relocatable (config.h lost its soname patches). Re-run build-wine.sh."
    exit 1
fi
# Homebrew's "libSDL2" is sdl2-compat, a shim that loads real SDL3 at runtime
# via @loader_path/libSDL3.dylib — so SDL3 must sit beside it in the bundle.
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
# own install name, not a dependency — skip it.
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
    echo "Error: required libraries are missing — bundle would not be self-contained"
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
# D3D10-12 comes from two third-party implementations that talk to Metal
# directly, not from wined3d over Vulkan: Apple's D3DMetal (Game Porting
# Toolkit) for x86_64 and DXMT for i386, which Apple does not cover. wined3d
# stays behind D3D9 and below.
#
# Deliberately after Step 3: that step's dependency walk, chmod and
# install_name_tool loops all iterate $EXT_DIR/*.dylib, and none of them may
# touch the Apple-signed libd3dshared.dylib. Staging afterwards keeps them out
# of reach without any exemption logic. Nothing below rewrites install names,
# re-signs, or walks the otool closure.
echo "==> Step 4: Direct3D backends"

GPTK_DMG="$REDIST_DIR/gptk.dmg"
DXMT_TAR="$REDIST_DIR/dxmt.tar.gz"
for f in "$GPTK_DMG" "$DXMT_TAR"; do
    if [ ! -e "$f" ]; then
        echo "Error: $f not found"
        exit 1
    fi
done

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
# arches: i386's is replaced by DXMT, and Wine's d3d10_1 still reaches the
# x86_64 one over wined3d/GL.
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
# Check .so modules
for so in "$WINE_DIR"/lib/wine/x86_64-unix/*.so; do
    if otool -L "$so" 2>/dev/null | grep -q "/usr/local/"; then
        echo "  ERROR: $(basename "$so") still references /usr/local/"
        LEAKED=1
    fi
done
if [ $LEAKED -ne 0 ]; then
    echo "Error: bundle is not self-contained"
    exit 1
fi
echo "  All binaries clean — no /usr/local references."

# The Direct3D backends, which are copied in rather than built and so are not
# covered by anything the build would have caught.
MISSING=0
for want in \
    "lib/external/D3DMetal.framework/Versions/A/D3DMetal" \
    "lib/external/libd3dshared.dylib" \
    "lib/wine/x86_64-unix/d3d11.so" \
    "lib/wine/x86_64-unix/nvngx.so" \
    "lib/wine/x86_64-windows/d3d12.dll" \
    "lib/wine/x86_64-unix/winemetal.so" \
    "lib/wine/i386-windows/winemetal.dll" \
    "lib/wine/i386-windows/d3d11.dll"
do
    # -e follows symlinks, so this also proves the GPTK .so links resolve.
    if [ ! -e "$WINE_DIR/$want" ]; then
        echo "  ERROR: missing $want"
        MISSING=1
    fi
done
if [ $MISSING -ne 0 ]; then
    echo "Error: Direct3D backends are not installed correctly"
    exit 1
fi
echo "  D3DMetal and DXMT in place."

WINE_VERSION=$("$WINE_DIR/bin/wine" --version) || {
    echo "Error: bundled wine failed to run"
    exit 1
}
echo "  Testing: $WINE_VERSION"

echo ""
echo "==> Done! Distribution is at:"
echo "    $DIST_DIR/wine/"
if [ "$RUNTIME_ONLY" -eq 1 ]; then
    echo "    (runtime only — no development files)"
fi
