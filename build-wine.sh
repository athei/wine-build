#!/bin/bash
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WINE_SRC="${WINE_SRC:-$ROOT/src}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
MINGW_DIR="${MINGW_DIR:-/opt/llvm-mingw}"

# ARM64X link libraries for linking ARM64X PE builtins, built and staged but
# never installed or run.
ARM64X_BUILD_DIR="${ARM64X_BUILD_DIR:-$ROOT/build-arm64x}"
ARM64X_LIB_DIR="${ARM64X_LIB_DIR:-$ROOT/dist/wine-arm64x}"

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

# Without this, clang takes the deployment target from whatever host is
# building, so the artifact's macOS floor was an accident of the runner image:
# cx-26.3.0-3 shipped minos 15.0 off the macos-15 runner, while a local build
# on macOS 27 produced minos 26.0. Pin it so CI and local builds agree and the
# floor does not move when the image is bumped. The SDK stays whatever the host
# has; only the minimum is fixed. GPTK's D3DMetal, the default for 64-bit
# D3D10 to D3D12, needs macOS 26.4, because it links libdxccontainer.dylib,
# which carries minos 26.4. So the bundle targets macOS 26, and a lower floor
# buys nothing for the default setup. compatdb has the same pin in
# .cargo/config.toml.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-26.0}"

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
# the patch, so check before every build, not just on --clean, and re-check
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

# Build. make runs natively even though the target is x86_64: clang is a
# universal binary and CC/CROSSCC above already pin `-arch x86_64`, so putting
# make under `arch -x86_64` only means translating every compiler invocation.
# A clean build measured 642s that way against 208s this way, producing the
# same 2843 artifacts at identical sizes. The tools the build generates for
# itself (winebuild, widl, wrc, makedep) are x86_64 and get exec'd through
# Rosetta from this arm64 make, which works and is a small share of the time.
# Configure above stays translated; that is where the host probing happens.
echo "==> Building Wine..."
make -j$(sysctl -n hw.ncpu)

if sonames_unpatched; then
    echo "==> config.h was regenerated during the build, re-patching and rebuilding..."
    patch_sonames
    make -j$(sysctl -n hw.ncpu)
fi

# The d3d9 test binaries, which bundle-wine.sh publishes so a consumer can run
# Wine's de-facto D3D9 conformance suite against its own d3d9 builtin without a
# Wine build tree of its own. The toplevel `all` happens to produce them today,
# but only as a side effect of programs/winetest embedding every test binary as
# a resource; naming the target keeps a bundle input a stated dependency instead
# of a by-product, and costs nothing when they are already built.
# `dlls/d3d9/tests/all` depends on exactly the two per-arch `d3d9_test.exe`.
echo "==> Building the d3d9 test binaries..."
make -j$(sysctl -n hw.ncpu) dlls/d3d9/tests/all

# Verify
echo "==> Build complete."
file "$BUILD_DIR/loader/wine"
"$BUILD_DIR/loader/wine" --version 2>/dev/null || true

# The ARM64X link libraries, from a second, separate tree. The output is two
# link archives, not a Wine: nothing here is runnable and none of it is
# installed. An ARM64X PE builtin needs a `libwinecrt0.a` to take its
# `unix_lib.o` from and a `libntdll.a` to import from, each with an ARM64 and
# an ARM64EC member, and that is all this produces. The Wine that eventually
# loads such a builtin is CrossOver's, not this one, and it ships no link
# archives of its own.
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
# of a full Wine build. Unlike the tree above, this one is arm64 in both host
# and target, so configure is not translated either.
echo "==> Building the ARM64X link libraries..."
if [ "$CLEAN" -eq 1 ]; then
    rm -rf "$ARM64X_BUILD_DIR"
fi
mkdir -p "$ARM64X_BUILD_DIR"
cd "$ARM64X_BUILD_DIR"

if [ "$CLEAN" -eq 1 ] || [ ! -f "$ARM64X_BUILD_DIR/Makefile" ]; then
    echo "==> Configuring the ARM64X link library tree (arm64ec,aarch64)..."
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
echo "==> Staging the ARM64X link libraries into $ARM64X_LIB_DIR ..."
mkdir -p "$ARM64X_LIB_DIR/lib/wine/aarch64-windows"
cp "$ARM64X_BUILD_DIR/dlls/winecrt0/aarch64-windows/libwinecrt0.a" \
   "$ARM64X_BUILD_DIR/dlls/ntdll/aarch64-windows/libntdll.a" \
   "$ARM64X_LIB_DIR/lib/wine/aarch64-windows/"

# An ARM64X link takes both halves from the same archive. A missing EC half
# means the ARM64X pairing did not happen and the archive holds ARM64 code
# only; a missing ARM64 half means the archive is not the paired one at all.
WINECRT0_MEMBERS="$("$MINGW_DIR/bin/llvm-ar" t "$ARM64X_LIB_DIR/lib/wine/aarch64-windows/libwinecrt0.a")"
for member in arm64ec-windows/unix_lib.o aarch64-windows/unix_lib.o; do
    grep -q "$member" <<<"$WINECRT0_MEMBERS" \
        || { echo "Error: staged libwinecrt0.a carries no $member"; exit 1; }
done
echo "==> ARM64X link libraries staged."
