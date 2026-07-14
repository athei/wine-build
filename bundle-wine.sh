#!/bin/bash
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
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

# ── Step 3: Bundle dynamic libraries ────────────────────────────────────
# Wine's .so modules dlopen these via @loader_path sonames (patched in Step 0).
# Transitive deps are loaded by dyld from their @loader_path install names.
echo "==> Step 3: Bundle dynamic libraries"
mkdir -p "$EXT_DIR"

# Direct deps: Wine dlopen's these by soname. build-wine.sh patches their
# sonames in config.h to @loader_path/../../external/<name>, so config.h is
# the authoritative (version-correct) list — resolve each against /usr/local/lib.
CONFIG_H="$BUILD_DIR/include/config.h"
if [ ! -f "$CONFIG_H" ]; then
    echo "Error: $CONFIG_H not found (run build-wine.sh first)"
    exit 1
fi
LIBS=()
for name in $(sed -n 's|.*"@loader_path/\.\./\.\./external/\([^"]*\)".*|\1|p' "$CONFIG_H"); do
    LIBS+=("/usr/local/lib/$name")
done
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

# ── Step 4: Verify ──────────────────────────────────────────────────────
echo "==> Step 4: Verify"

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
