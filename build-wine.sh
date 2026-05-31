#!/bin/bash
set -e

WINE_SRC="/Users/alex/Developer/wine/src"
BUILD_DIR="/Users/alex/Developer/wine/build"
MINGW_DIR="/opt/llvm-mingw"

if [ ! -f "$WINE_SRC/configure" ]; then
    echo "Error: Wine source not found at $WINE_SRC"
    exit 1
fi

if [ ! -x "$MINGW_DIR/bin/x86_64-w64-mingw32-clang" ]; then
    echo "Error: llvm-mingw not found at $MINGW_DIR"
    exit 1
fi
export PATH="$PATH:$MINGW_DIR/bin"

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
        --with-coreaudio \
        --with-gnutls \
        --with-mingw \
        --with-opencl \
        --with-sdl \
        --with-unwind \
        --without-alsa \
        --without-capi \
        --without-cups \
        --without-dbus \
        --without-ffmpeg \
        --without-fontconfig \
        --without-gettext \
        --without-gphoto \
        --without-gssapi \
        --without-gstreamer \
        --without-hwloc \
        --without-inotify \
        --without-krb5 \
        --without-netapi \
        --without-oss \
        --without-pcap \
        --without-pcsclite \
        --without-pulse \
        --without-sane \
        --without-udev \
        --without-usb \
        --without-v4l2 \
        --without-vulkan \
        --without-wayland \
        --without-x \
        CC="clang -arch x86_64" \
        CROSSCC="clang -arch x86_64" \
        --host=x86_64-apple-darwin \
        PKG_CONFIG_PATH="/usr/local/lib/pkgconfig" \
        CFLAGS="-I/usr/local/include" \
        LDFLAGS="-L/usr/local/lib"
else
    echo "==> Skipping configure (already configured, use --clean to reconfigure)"
fi

# Patch sonames for relocatable bundle (only on clean builds, after configure generates config.h)
if [ "$CLEAN" -eq 1 ]; then
    echo "==> Patching sonames in config.h for @loader_path relocation..."
    sed -i '' \
        -e 's|"libfreetype\.6\.dylib"|"@loader_path/../../external/libfreetype.6.dylib"|' \
        -e 's|"libgnutls\.30\.dylib"|"@loader_path/../../external/libgnutls.30.dylib"|' \
        -e 's|"libSDL2-2\.0\.0\.dylib"|"@loader_path/../../external/libSDL2-2.0.0.dylib"|' \
        "$BUILD_DIR/include/config.h"
fi

# Build
echo "==> Building Wine..."
arch -x86_64 make -j$(sysctl -n hw.ncpu)

# Verify
echo "==> Build complete."
file "$BUILD_DIR/loader/wine"
"$BUILD_DIR/loader/wine" --version 2>/dev/null || true
