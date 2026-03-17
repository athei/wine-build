#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="/Users/alex/Developer/wine/build"
WINE_VERSION="11.4"
DIST_DIR=""

usage() {
    echo "Usage: $0 --dest <dir>"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dest) DIST_DIR="$2"; shift 2 ;;
        *) usage ;;
    esac
done

if [ -z "$DIST_DIR" ]; then
    echo "Error: --dest is required"
    usage
fi

# ── Step 1: Staged install ──────────────────────────────────────────────
echo "==> Step 1: Staged install with DESTDIR"
find "$DIST_DIR" -name .DS_Store -delete 2>/dev/null || true
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
cd "$BUILD_DIR"
arch -x86_64 make install DESTDIR="$DIST_DIR"

# ── Step 2: Flatten prefix ──────────────────────────────────────────────
echo "==> Step 2: Flatten prefix"
mv "$DIST_DIR/usr/local" "$DIST_DIR/wine"
rm -rf "$DIST_DIR/usr"

WINE_DIR="$DIST_DIR/wine"
EXT_DIR="$WINE_DIR/lib/external"

# ── Step 3: Bundle dynamic libraries ────────────────────────────────────
# Wine uses dlopen() to load these at runtime (see SONAME_LIB* in config.h).
# We bundle them and set DYLD_FALLBACK_LIBRARY_PATH via wrapper scripts.
echo "==> Step 3: Bundle dynamic libraries"
mkdir -p "$EXT_DIR"

# Direct deps (Wine dlopen's these by soname)
LIBS=(
    /usr/local/lib/libfreetype.6.dylib
    /usr/local/lib/libgnutls.30.dylib
    /usr/local/lib/libSDL2-2.0.0.dylib
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

# ── Step 3b: Compile launcher and replace wrappers ─────────────────────
# Instead of shell script wrappers, compile a small x86_64 C launcher that
# sets DYLD_FALLBACK_LIBRARY_PATH + WINELOADER and execs the real binary.
# It reads argv[0] basename to dispatch: wine→libexec/wine, wineserver→
# libexec/wineserver, anything else→libexec/wine <basename>.
LAUNCHER_SRC="$SCRIPT_DIR/wine-launcher.c"
echo "  Compiling launcher from $LAUNCHER_SRC..."
mkdir -p "$WINE_DIR/libexec"
arch -x86_64 clang -arch x86_64 -O2 -o "$WINE_DIR/libexec/wine-launcher" "$LAUNCHER_SRC"

echo "  Moving real binaries to libexec/..."
mv "$WINE_DIR/bin/wine" "$WINE_DIR/libexec/wine"
mv "$WINE_DIR/bin/wineserver" "$WINE_DIR/libexec/wineserver"
for tool in winegcc wineg++ winebuild widl winedump wmc wrc; do
    if [ -f "$WINE_DIR/bin/$tool" ]; then
        mv "$WINE_DIR/bin/$tool" "$WINE_DIR/libexec/$tool"
    fi
done
rm -f "$WINE_DIR/bin/"*

echo "  Creating launcher symlinks in bin/..."
for prog in wine wineserver msidb msiexec notepad regedit regsvr32 wineboot winecfg wineconsole winedbg winefile winemine winepath; do
    ln -s ../libexec/wine-launcher "$WINE_DIR/bin/$prog"
done
for tool in winegcc wineg++ winebuild widl winedump wmc wrc; do
    if [ -f "$WINE_DIR/libexec/$tool" ]; then
        ln -s ../libexec/wine-launcher "$WINE_DIR/bin/$tool"
    fi
done

# ── Step 4: Verify ──────────────────────────────────────────────────────
echo "==> Step 4: Verify"

echo "  wine binary: $(file "$WINE_DIR/libexec/wine" | sed 's|.*/||')"

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
