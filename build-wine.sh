#!/bin/bash
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WINE_SRC="${WINE_SRC:-$ROOT/src}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
MINGW_DIR="${MINGW_DIR:-/opt/llvm-mingw}"

# arm64ec link libraries, built and staged but never installed or run.
ARM64EC_BUILD_DIR="${ARM64EC_BUILD_DIR:-$ROOT/build-arm64ec}"
ARM64EC_LIB_DIR="${ARM64EC_LIB_DIR:-$ROOT/dist/wine-arm64ec}"

if [ ! -f "$WINE_SRC/configure" ]; then
    echo "Error: Wine source not found at $WINE_SRC"
    exit 1
fi

if [ ! -x "$MINGW_DIR/bin/x86_64-w64-mingw32-clang" ]; then
    echo "Error: llvm-mingw not found at $MINGW_DIR"
    exit 1
fi
export PATH="$PATH:$MINGW_DIR/bin"

if [ ! -x "$MINGW_DIR/bin/arm64ec-w64-mingw32-clang" ]; then
    echo "Error: llvm-mingw at $MINGW_DIR has no arm64ec toolchain"
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

# Patch sonames for relocatable bundle. config.status regenerates config.h
# whenever configure changes (e.g. after a source update), silently reverting
# the patch — so check before every build, not just on --clean, and re-check
# after make in case the build itself triggered a regeneration.
sonames_unpatched() {
    grep -qE '^#define SONAME_(LIBFREETYPE|LIBGNUTLS|LIBSDL2) "lib' "$BUILD_DIR/include/config.h"
}
patch_sonames() {
    echo "==> Patching sonames in config.h for @loader_path relocation..."
    sed -i '' \
        -e 's|"libfreetype\.6\.dylib"|"@loader_path/../../external/libfreetype.6.dylib"|' \
        -e 's|"libgnutls\.30\.dylib"|"@loader_path/../../external/libgnutls.30.dylib"|' \
        -e 's|"libSDL2-2\.0\.0\.dylib"|"@loader_path/../../external/libSDL2-2.0.0.dylib"|' \
        "$BUILD_DIR/include/config.h"
}
if sonames_unpatched; then
    patch_sonames
fi

# Build
echo "==> Building Wine..."
arch -x86_64 make -j$(sysctl -n hw.ncpu)

if sonames_unpatched; then
    echo "==> config.h was regenerated during the build — re-patching and rebuilding..."
    patch_sonames
    arch -x86_64 make -j$(sysctl -n hw.ncpu)
fi

# The d3d9 test binaries, which bundle-wine.sh publishes so a consumer can run
# Wine's de-facto D3D9 conformance suite against its own d3d9 builtin without a
# Wine build tree of its own. The toplevel `all` happens to produce them today,
# but only as a side effect of programs/winetest embedding every test binary as
# a resource; naming the target keeps a bundle input a stated dependency instead
# of a by-product, and costs nothing when they are already built.
# `dlls/d3d9/tests/all` depends on exactly the two per-arch `d3d9_test.exe`.
echo "==> Building the d3d9 test binaries..."
arch -x86_64 make -j$(sysctl -n hw.ncpu) dlls/d3d9/tests/all

# Verify
echo "==> Build complete."
file "$BUILD_DIR/loader/wine"
"$BUILD_DIR/loader/wine" --version 2>/dev/null || true

# The arm64ec link libraries, from a second, separate tree. Nothing here is a
# runnable Wine and none of it is installed: an arm64ec PE builtin needs a
# `libwinecrt0.a` to take its `unix_lib.o` from and a `libntdll.a` to import
# from, and that is all this produces. The Wine that eventually loads such a
# builtin is CrossOver's, not this one.
#
# arm64ec is paired with aarch64 so makedep sets up ARM64X (`native_archs` /
# `hybrid_archs`): the pair emits ONE set of libraries under `aarch64-windows`
# carrying both arches' objects, which is also where the loader looks, since
# `get_pe_dir` knows no arm64ec directory and redirects a hybrid module
# requested as AMD64 to the ARM64 one. arm64ec alone would build a standalone
# `arm64ec-windows` tree that no loader ever searches.
#
# Configure still probes the host side, so every unix dependency is switched
# off; only the two PE targets below are ever built, which is a small fraction
# of a full Wine build. Native arm64 throughout, so no `arch -x86_64` here.
echo "==> Building the arm64ec link libraries..."
if [ "$CLEAN" -eq 1 ]; then
    rm -rf "$ARM64EC_BUILD_DIR"
fi
mkdir -p "$ARM64EC_BUILD_DIR"
cd "$ARM64EC_BUILD_DIR"

if [ "$CLEAN" -eq 1 ] || [ ! -f "$ARM64EC_BUILD_DIR/Makefile" ]; then
    echo "==> Configuring Wine (arm64ec)..."
    "$WINE_SRC/configure" \
        --enable-archs=arm64ec,aarch64 \
        --with-mingw \
        --without-alsa --without-capi --without-coreaudio --without-cups \
        --without-dbus --without-ffmpeg --without-fontconfig --without-freetype \
        --without-gettext --without-gnutls --without-gphoto --without-gssapi \
        --without-gstreamer --without-hwloc --without-inotify --without-krb5 \
        --without-netapi --without-opencl --without-oss --without-pcap \
        --without-pcsclite --without-pulse --without-sane --without-sdl \
        --without-udev --without-unwind --without-usb --without-v4l2 \
        --without-vulkan --without-wayland --without-x \
        --host=aarch64-apple-darwin
else
    echo "==> Skipping configure (already configured, use --clean to reconfigure)"
fi

make -j$(sysctl -n hw.ncpu) \
    dlls/winecrt0/aarch64-windows/libwinecrt0.a \
    dlls/ntdll/aarch64-windows/libntdll.a

# Staged in the layout of an installed Wine, so a consumer can point its
# WINE_SDK at this directory and find the libraries where it expects them.
echo "==> Staging arm64ec libraries into $ARM64EC_LIB_DIR ..."
mkdir -p "$ARM64EC_LIB_DIR/lib/wine/aarch64-windows"
cp "$ARM64EC_BUILD_DIR/dlls/winecrt0/aarch64-windows/libwinecrt0.a" \
   "$ARM64EC_BUILD_DIR/dlls/ntdll/aarch64-windows/libntdll.a" \
   "$ARM64EC_LIB_DIR/lib/wine/aarch64-windows/"

# The EC half is what a consumer links; its absence would mean the ARM64X
# pairing did not happen and the archive holds ARM64 code only.
"$MINGW_DIR/bin/llvm-ar" t "$ARM64EC_LIB_DIR/lib/wine/aarch64-windows/libwinecrt0.a" \
    | grep -q "arm64ec-windows/unix_lib.o" \
    || { echo "Error: staged libwinecrt0.a carries no arm64ec unix_lib.o"; exit 1; }
echo "==> arm64ec libraries staged."
