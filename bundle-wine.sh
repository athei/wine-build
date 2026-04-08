#!/bin/bash
set -e

BUILD_DIR="/Users/alex/Developer/wine/build"
DIST_DIR=""
RUNTIME_ONLY=0

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

# Direct deps (Wine dlopen's these by soname)
LIBS=(
    /usr/local/lib/libfreetype.6.dylib
    /usr/local/lib/libgnutls.30.dylib
    /usr/local/lib/libSDL2-2.0.0.dylib
    /usr/local/lib/libMoltenVK.dylib
)

# Transitive deps (found via otool -L on the above)
LIBS+=(
    /usr/local/opt/libpng/lib/libpng16.16.dylib
    /usr/local/opt/gettext/lib/libintl.8.dylib
    /usr/local/opt/p11-kit/lib/libp11-kit.0.dylib
    /usr/local/opt/libidn2/lib/libidn2.0.dylib
    /usr/local/opt/libunistring/lib/libunistring.5.dylib
    /usr/local/opt/libtasn1/lib/libtasn1.6.dylib
    /usr/local/opt/nettle/lib/libhogweed.6.dylib
    /usr/local/opt/nettle/lib/libnettle.8.dylib
    /usr/local/opt/gmp/lib/libgmp.10.dylib
)

echo "  Copying dylibs..."
for lib in "${LIBS[@]}"; do
    if [ -f "$lib" ]; then
        name=$(basename "$lib")
        echo "    $name"
        cp -L "$lib" "$EXT_DIR/$name"
    else
        echo "    WARNING: $lib not found, skipping"
    fi
done
chmod +w "$EXT_DIR"/*.dylib

# Check for missed transitive deps
echo "  Checking for missed transitive deps..."
MISSED=0
for dylib in "$EXT_DIR"/*.dylib; do
    for dep in $(otool -L "$dylib" | tail -n +2 | awk '{print $1}'); do
        case "$dep" in
            /usr/lib/*|/System/*|@*) ;;
            /usr/local/*)
                depname=$(basename "$dep")
                if [ ! -f "$EXT_DIR/$depname" ]; then
                    echo "    MISSING: $depname (needed by $(basename "$dylib")) from $dep"
                    MISSED=1
                fi
                ;;
        esac
    done
done
[ $MISSED -eq 0 ] && echo "    None missed."

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
        echo "  WARNING: $(basename "$dylib") still references /usr/local/"
        LEAKED=1
    fi
done
# Check .so modules
for so in "$WINE_DIR"/lib/wine/x86_64-unix/*.so; do
    if otool -L "$so" 2>/dev/null | grep -q "/usr/local/"; then
        echo "  WARNING: $(basename "$so") still references /usr/local/"
        LEAKED=1
    fi
done
[ $LEAKED -eq 0 ] && echo "  All binaries clean — no /usr/local references."

echo "  Testing: $("$WINE_DIR/bin/wine" --version 2>/dev/null || echo 'FAILED')"

echo ""
echo "==> Done! Distribution is at:"
echo "    $DIST_DIR/wine/"
if [ "$RUNTIME_ONLY" -eq 1 ]; then
    echo "    (runtime only — no development files)"
fi
