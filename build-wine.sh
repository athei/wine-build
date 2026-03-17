#!/bin/bash
set -e

WINE_SRC="/Users/alex/Developer/wine"
BUILD_DIR="/Users/alex/Developer/wine-build"

if [ ! -f "$WINE_SRC/configure" ]; then
    echo "Error: Wine source not found at $WINE_SRC"
    exit 1
fi

# Clean build directory (preserve .git if any, and this script's parent)
echo "==> Cleaning build directory..."
cd "$BUILD_DIR"
find . -maxdepth 1 ! -name '.' ! -name '..' -exec rm -rf {} +

# Configure
echo "==> Configuring Wine..."
cd "$BUILD_DIR"
arch -x86_64 "$WINE_SRC/configure" \
    --enable-archs=i386,x86_64 \
    CC="clang -arch x86_64" \
    CROSSCC="clang -arch x86_64" \
    --host=x86_64-apple-darwin \
    PKG_CONFIG_PATH="/usr/local/lib/pkgconfig" \
    CFLAGS="-I/usr/local/include" \
    LDFLAGS="-L/usr/local/lib"

# Build
echo "==> Building Wine..."
arch -x86_64 make -j$(sysctl -n hw.ncpu)

# Verify
echo "==> Build complete."
file "$BUILD_DIR/loader/wine"
"$BUILD_DIR/loader/wine" --version 2>/dev/null || true
