#!/bin/bash
set -e

WINE_SRC="/Users/alex/Developer/wine/src"
BUILD_DIR="/Users/alex/Developer/wine/build"

if [ ! -f "$WINE_SRC/configure" ]; then
    echo "Error: Wine source not found at $WINE_SRC"
    exit 1
fi

# Parse flags
CLEAN=0
if [ "$1" = "--clean" ]; then
    CLEAN=1
fi

# Clean if requested
if [ "$CLEAN" -eq 1 ]; then
    echo "==> Cleaning build directory..."
    rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR"

# Configure (skip if already configured unless --clean was passed)
cd "$BUILD_DIR"
if [ "$CLEAN" -eq 1 ] || [ ! -f "$BUILD_DIR/Makefile" ]; then
    echo "==> Configuring Wine..."
    arch -x86_64 "$WINE_SRC/configure" \
        --enable-archs=i386,x86_64 \
        CC="clang -arch x86_64" \
        CROSSCC="clang -arch x86_64" \
        --host=x86_64-apple-darwin \
        PKG_CONFIG_PATH="/usr/local/lib/pkgconfig" \
        CFLAGS="-I/usr/local/include" \
        LDFLAGS="-L/usr/local/lib"
else
    echo "==> Skipping configure (already configured, use --clean to reconfigure)"
fi

# Build
echo "==> Building Wine..."
arch -x86_64 make -j$(sysctl -n hw.ncpu)

# Verify
echo "==> Build complete."
file "$BUILD_DIR/loader/wine"
"$BUILD_DIR/loader/wine" --version 2>/dev/null || true
