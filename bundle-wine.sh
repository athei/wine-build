#!/bin/bash
set -e

BUILD_DIR="/Users/alex/Developer/wine-build"
DIST_DIR="/Users/alex/Developer/wine-dist"
WINE_VERSION="11.4"

# ── Step 1: Staged install ──────────────────────────────────────────────
echo "==> Step 1: Staged install with DESTDIR"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
cd "$BUILD_DIR"
arch -x86_64 make install-lib DESTDIR="$DIST_DIR"

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

# ── Step 3b: Create wrapper scripts ─────────────────────────────────────
# Wine installs bin/wine as a Mach-O binary and all other programs as symlinks
# to it. We move the real binaries to libexec/ and create shell wrappers that
# set DYLD_FALLBACK_LIBRARY_PATH so dlopen() finds our bundled libs.
echo "  Creating wrapper scripts..."
mkdir -p "$WINE_DIR/libexec"
mv "$WINE_DIR/bin/wine" "$WINE_DIR/libexec/wine"
mv "$WINE_DIR/bin/wineserver" "$WINE_DIR/libexec/wineserver"
rm -f "$WINE_DIR/bin/"*

# wine wrapper
cat > "$WINE_DIR/bin/wine" << 'EOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export DYLD_FALLBACK_LIBRARY_PATH="$WINE_ROOT/lib/external${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"
export WINELOADER="$WINE_ROOT/libexec/wine"
exec "$WINE_ROOT/libexec/wine" "$@"
EOF
chmod +x "$WINE_DIR/bin/wine"

# wineserver wrapper
cat > "$WINE_DIR/bin/wineserver" << 'EOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export DYLD_FALLBACK_LIBRARY_PATH="$WINE_ROOT/lib/external${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"
exec "$WINE_ROOT/libexec/wineserver" "$@"
EOF
chmod +x "$WINE_DIR/bin/wineserver"

# Program wrappers (winecfg, regedit, etc. — Wine uses argv[0] to determine the program)
for prog in msidb msiexec notepad regedit regsvr32 wineboot winecfg wineconsole winedbg winefile winemine winepath; do
    cat > "$WINE_DIR/bin/$prog" << INNEREOF
#!/bin/bash
SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
WINE_ROOT="\$(cd "\$SCRIPT_DIR/.." && pwd)"
export DYLD_FALLBACK_LIBRARY_PATH="\$WINE_ROOT/lib/external\${DYLD_FALLBACK_LIBRARY_PATH:+:\$DYLD_FALLBACK_LIBRARY_PATH}"
export WINELOADER="\$WINE_ROOT/libexec/wine"
exec "\$WINE_ROOT/libexec/wine" $prog "\$@"
INNEREOF
    chmod +x "$WINE_DIR/bin/$prog"
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

# ── Step 5: Create archive ──────────────────────────────────────────────
echo "==> Step 5: Create archive"
cd "$DIST_DIR"
tar -czf "wine-${WINE_VERSION}-x86_64-macos.tar.gz" wine/
ls -lh "wine-${WINE_VERSION}-x86_64-macos.tar.gz"

echo ""
echo "==> Done! Distribution is at:"
echo "    $DIST_DIR/wine/"
echo "    $DIST_DIR/wine-${WINE_VERSION}-x86_64-macos.tar.gz"
