#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MINGW_DIR="${MINGW_DIR:-/opt/llvm-mingw}"

usage() {
    echo "Usage: $0 [--clean]"
    exit 1
}

CLEAN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --clean) CLEAN=1; shift ;;
        *) usage ;;
    esac
done

# shellcheck source=lib/profile.sh
. "$SCRIPT_DIR/lib/profile.sh"

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

# The floor is pinned in profile.sh, which exports it as
# MACOSX_DEPLOYMENT_TARGET for everything built below. The SDK stays whatever
# the host has; only the minimum is fixed.
check_sdk_floor
check_deps_formulae

# Clean if requested
if [ "$CLEAN" -eq 1 ]; then
    echo "==> Cleaning build directory..."
fi
claim_tree "$BUILD_DIR" wine "$CLEAN"

# With WINE_BUILD_CCACHE, Wine's configure and make run with a directory of
# ccache links ahead of PATH (ccache_bin_dir in profile.sh): clang, which CC
# names, and the llvm-mingw compilers configure looks for first. The build
# scripts called below get the PATH without it: DXMT's and vkd3d-proton's
# cross files must find llvm-mingw's own compilers, and FEX and Mesa take
# ccache their own way.
WINE_PATH="$PATH"
if [ -n "$WINE_CCACHE" ]; then
    ccache_bin_dir "$BUILD_DIR/ccache-bin" clang aarch64-w64-mingw32-clang \
        arm64ec-w64-mingw32-clang i686-w64-mingw32-gcc x86_64-w64-mingw32-gcc
    WINE_PATH="$BUILD_DIR/ccache-bin:$PATH"
fi

# build-fex.sh, build-mesa.sh, build-dxmt.sh and build-vkd3d-proton.sh read
# the same profile.sh and take --clean the same way.
SUB_FLAGS=()
if [ "$CLEAN" -eq 1 ]; then
    SUB_FLAGS=(--clean)
fi

# The Vulkan loader and driver, built first: configure links against the
# loader build-mesa.sh stages (the LDFLAGS in profile.sh name its directory
# first), and records its soname.
"$SCRIPT_DIR/build-mesa.sh" "${SUB_FLAGS[@]}"

# Every optional dependency is switched off unless it is switched back on
# here, so a package missing from the dependency prefix fails configure
# instead of silently changing the feature set. The list covers every
# --with-*/--without-* package of `configure --help`, except: pthread, which
# is required; gettextpo, which is off unless asked for (--without-gettextpo
# would only skip a header probe and change config.h for nothing); and the
# options that name a path rather than a package. The X extensions are moot
# under --without-x and denied anyway, so nothing depends on that. Vulkan
# runs on the loader and KosmicKrisp build-mesa.sh built. OpenGL is EGL,
# Mesa's, also built by build-mesa.sh and found through its egl.pc: with
# --without-x the only library --with-opengl makes configure look for is
# EGL, and the Mac driver links Apple's OpenGL framework on its own.
CONFIGURE_ALLOWLIST=(
    --with-coreaudio
    --with-freetype
    --with-gnutls
    --with-mingw
    --with-opencl
    --with-opengl
    --with-sdl
    --with-vulkan
    --without-alsa
    --without-capi
    --without-cups
    --without-dbus
    --without-ffmpeg
    --without-fontconfig
    --without-gettext
    --without-gphoto
    --without-gssapi
    --without-gstreamer
    --without-hwloc
    --without-inotify
    --without-krb5
    --without-netapi
    --without-oss
    --without-pcap
    --without-pcsclite
    --without-pulse
    --without-sane
    --without-udev
    --without-usb
    --without-v4l2
    --without-va
    --without-wayland
    --without-x
    --without-xcomposite
    --without-xcursor
    --without-xfixes
    --without-xinerama
    --without-xinput
    --without-xinput2
    --without-xrandr
    --without-xrender
    --without-xshape
    --without-xshm
    --without-xxf86vm
)

# Configure (skip if already configured unless --clean was passed)
cd "$BUILD_DIR"
if [ "$CLEAN" -eq 1 ] || [ ! -f "$BUILD_DIR/Makefile" ]; then
    echo "==> Configuring Wine..."
    PATH="$WINE_PATH" "$WINE_SRC/configure" \
        --enable-archs="$WINE_ARCHS" \
        "${CONFIGURE_ALLOWLIST[@]}" \
        "${CONFIGURE_TOOLCHAIN[@]}"
else
    echo "==> Skipping configure (already configured, use --clean to reconfigure)"
fi

# Patch sonames for relocatable bundle. config.status regenerates config.h
# whenever configure changes (e.g. after a source update), silently reverting
# the patch, so check before every build, not just on --clean, and re-check
# after make in case the build itself triggered a regeneration.
#
# Patched are the defines of the libraries the --with-* packages above load
# by soname, and only those, so the result does not depend on what else the
# host has installed. configure also probes a few libraries it has no
# --without-* for; when it does not find one it writes a placeholder define
# (FALLBACK_SONAMES), which stays as it is. Any other define means configure
# found a library the allowlist does not account for, and stops the build.
# The Vulkan loader and Mesa's EGL are patched ones; the bundle step takes
# them from MESA_DIST.
BUNDLED_SONAMES="SONAME_LIBEGL SONAME_LIBFREETYPE SONAME_LIBGNUTLS SONAME_LIBSDL2 SONAME_LIBVULKAN"
FALLBACK_SONAMES="SONAME_LIBODBC=libodbc.dylib"
CONFIG_H="$BUILD_DIR/include/config.h"
soname_value() { # <define>: its string value in config.h, or nothing
    sed -n "s|^#define $1 \"\\(.*\\)\"\$|\\1|p" "$CONFIG_H"
}
check_soname_defines() {
    local def value
    for def in $BUNDLED_SONAMES; do
        if [ -z "$(soname_value "$def")" ]; then
            echo "Error: config.h has no $def; configure did not find the library, or the"
            echo "build tree was configured before it was enabled (run with --clean)"
            exit 1
        fi
    done
    for def in $(sed -n 's|^#define \(SONAME_LIB[A-Z0-9_]*\) .*|\1|p' "$CONFIG_H"); do
        case " $BUNDLED_SONAMES " in *" $def "*) continue ;; esac
        value=$(soname_value "$def")
        case " $FALLBACK_SONAMES " in *" $def=$value "*) continue ;; esac
        echo "Error: configure found $value for $def, which the allowlist does not"
        echo "account for; uninstall it from $DEPS_PREFIX or add it to the allowlist"
        exit 1
    done
}
unpatched_sonames() {
    local def value
    for def in $BUNDLED_SONAMES; do
        value=$(soname_value "$def")
        case "$value" in
            lib*) echo "$value" ;;
        esac
    done
}
patch_sonames() {
    local name
    echo "==> Patching sonames in config.h for @loader_path relocation..."
    for name in $(unpatched_sonames); do
        echo "    $name"
        sed -i '' "s|\"${name//./\\.}\"|\"@loader_path/../../external/$name\"|" "$CONFIG_H"
    done
    if [ -n "$(unpatched_sonames)" ]; then
        echo "Error: config.h still names these libraries bare after patching:"
        unpatched_sonames
        exit 1
    fi
}
check_soname_defines
if [ -n "$(unpatched_sonames)" ]; then
    patch_sonames
fi

echo "==> Building Wine..."
PATH="$WINE_PATH" make -j$(sysctl -n hw.ncpu)

if [ -n "$(unpatched_sonames)" ]; then
    echo "==> config.h was regenerated during the build, re-patching and rebuilding..."
    check_soname_defines
    patch_sonames
    PATH="$WINE_PATH" make -j$(sysctl -n hw.ncpu)
fi

# Verify
echo "==> Build complete."
file "$BUILD_DIR/loader/wine"
"$BUILD_DIR/loader/wine" --version 2>/dev/null || true

# ── The Wine SDK ─────────────────────────────────────────────────────────
# PE code built outside Wine (DXMT, mtld3d) links against Wine's
# libwinecrt0.a, for the unix_lib.o its unix calls go through, and imports
# from libntdll.a (DXMT also from libdbghelp.a), each for the architecture of
# that code.

# link_libs <pe-dir>: print the paths, relative to a build tree, of the three
# archives for <pe-dir>.
link_libs() {
    echo "libs/winecrt0/$1/libwinecrt0.a dlls/ntdll/$1/libntdll.a dlls/dbghelp/$1/libdbghelp.a"
}

# check_arm64x_archive <libwinecrt0.a>: exit unless the archive carries both
# halves an ARM64X link takes from it. A missing EC half means arm64ec was not
# paired with aarch64 and the archive holds ARM64 code only; a missing ARM64
# half means the archive is not the paired one at all.
check_arm64x_archive() {
    local members member
    members="$("$MINGW_DIR/bin/llvm-ar" t "$1")"
    for member in arm64ec-windows/unix_lib.o aarch64-windows/unix_lib.o; do
        grep -q "$member" <<<"$members" \
            || { echo "Error: $1 carries no $member"; exit 1; }
    done
}

# The Wine SDK: one directory, in the layout of an installed Wine, that
# DXMT's i386 build reads (-Dwine_install_path), with Wine's graphics tests
# (GRAPHICS_TESTS in profile.sh) under lib/wine/tests. The bundle carries the
# same files, which is where mtld3d's builds read them. bin/winebuild and the
# aarch64-windows and i386-windows archives come from the build itself: its
# aarch64-windows archives are ARM64X, since arm64ec is paired with aarch64
# there (makedep's native_archs and hybrid_archs), so one set under
# aarch64-windows carries both halves. The x86_64-windows archives are the
# one thing that build cannot make (ARM64EC is not x64, and an x64 object
# does not link against it). A second configure of the Wine source for the
# x86 architectures, reusing the build's tools, makes them: only those
# archives and the graphics tests are built, and no unix dependency is
# wanted, so every package is switched off. Configure still probes the host
# side, but runs natively, arm64 in host and target. The tests are there
# because makedep writes test rules only for the architectures a tree is
# configured for, and the build has no x86_64 and tests disabled; the i386
# archives still come from the build. WINE_COMMIT names the source commit,
# which build-dxmt.sh and bundle-wine.sh compare.
X86LIBS_WITHOUT=(
    --without-alsa --without-capi --without-coreaudio --without-cups
    --without-dbus --without-ffmpeg --without-fontconfig --without-freetype
    --without-gettext --without-gnutls --without-gphoto --without-gssapi
    --without-gstreamer --without-hwloc --without-inotify --without-krb5
    --without-netapi --without-opencl --without-oss --without-pcap
    --without-pcsclite --without-pulse --without-sane --without-sdl
    --without-udev --without-usb --without-v4l2 --without-va
    --without-vulkan --without-wayland --without-x
)
# shellcheck disable=SC2054 # the comma list is one argument
X86LIBS_CONFIGURE=(--enable-archs=i386,x86_64 --with-mingw "${X86LIBS_WITHOUT[@]}"
                   --host="$HOST_TRIPLE" --with-wine-tools="$BUILD_DIR"
                   CC="clang -arch arm64" BISON="$DEPS_PREFIX/opt/bison/bin/bison")
# The tree is configured again from scratch whenever the Wine source or
# these arguments differ from the ones it was configured with, which
# .configure-key records (build-dxmt.sh does the same for its meson trees
# with .setup-key), so a change here needs no --clean of the whole build.
# The tree only holds what this step builds.
X86LIBS_KEY="$WINE_SRC ${X86LIBS_CONFIGURE[*]}"
if [ "$CLEAN" -eq 1 ] || [ ! -f "$X86LIBS_BUILD_DIR/Makefile" ] \
    || [ "$(cat "$X86LIBS_BUILD_DIR/.configure-key" 2>/dev/null)" != "$X86LIBS_KEY" ]; then
    echo "==> Configuring the x86 link library and test tree $X86LIBS_BUILD_DIR..."
    claim_tree "$X86LIBS_BUILD_DIR" x86libs 1
    (cd "$X86LIBS_BUILD_DIR" && PATH="$WINE_PATH" "$WINE_SRC/configure" "${X86LIBS_CONFIGURE[@]}")
    echo "$X86LIBS_KEY" > "$X86LIBS_BUILD_DIR/.configure-key"
else
    claim_tree "$X86LIBS_BUILD_DIR" x86libs
    echo "==> Skipping configure of $X86LIBS_BUILD_DIR (configured with these arguments)"
fi

# test_exe <pe-dir> <name>: print the path, relative to a build tree, of the
# test executable of dlls/<name>/tests for <pe-dir>.
test_exe() {
    echo "dlls/$2/tests/$1/$2_test.exe"
}
read -ra X86LIBS_TARGETS <<< "$(link_libs x86_64-windows)"
for pe in $TEST_PE_DIRS; do
    for t in $(graphics_tests "$pe"); do
        X86LIBS_TARGETS+=("$(test_exe "$pe" "$t")")
    done
done
PATH="$WINE_PATH" make -C "$X86LIBS_BUILD_DIR" -j"$(sysctl -n hw.ncpu)" "${X86LIBS_TARGETS[@]}"

echo "==> Staging the Wine SDK into $WINE_SDK_DIR..."
claim_tree "$WINE_SDK_DIR" sdk 1
mkdir -p "$WINE_SDK_DIR/bin"
cp "$BUILD_DIR/tools/winebuild/winebuild" "$WINE_SDK_DIR/bin/"
for pe in "$PE64_DIR" i386-windows x86_64-windows; do
    tree="$BUILD_DIR"
    if [ "$pe" = x86_64-windows ]; then
        tree="$X86LIBS_BUILD_DIR"
    fi
    mkdir -p "$WINE_SDK_DIR/lib/wine/$pe"
    for lib in $(link_libs "$pe"); do
        cp "$tree/$lib" "$WINE_SDK_DIR/lib/wine/$pe/"
    done
done
check_arm64x_archive "$WINE_SDK_DIR/lib/wine/$PE64_DIR/libwinecrt0.a"
# The graphics tests, in lib/wine/tests/<pe-dir>/ as a full bundle carries
# them, so WINE_COMMIT covers them and their VERSION too. Plain executables,
# not builtins: Wine runs them by path. Each must be of its directory's
# machine.
for pe in $TEST_PE_DIRS; do
    case "$pe" in
        i386-windows) machine=014c ;;
        x86_64-windows) machine=8664 ;;
        *) echo "Error: TEST_PE_DIRS names $pe, whose PE machine this step does not know"; exit 1 ;;
    esac
    mkdir -p "$WINE_SDK_DIR/lib/wine/tests/$pe"
    for t in $(graphics_tests "$pe"); do
        f="$WINE_SDK_DIR/lib/wine/tests/$pe/${t}_test.exe"
        cp "$X86LIBS_BUILD_DIR/$(test_exe "$pe" "$t")" "$f"
        [ "$(pe_machine "$f")" = "$machine" ] \
            || { echo "Error: tests/$pe/${t}_test.exe has the PE machine $(pe_machine "$f"), not $machine"; exit 1; }
    done
done
# lib/wine/tests/VERSION: the `wine --version` string of the Wine the tests
# were built from, so a copy of lib/wine/tests taken alone still says which
# build it is (mtld3d's conformance runner reads its first line). ntdll prints
# wine_build for --version, which make writes into dlls/ntdll/unix/version.c
# from `git describe` of the source on every build, so the string is read
# from that file in the build tree, as compiled into the ntdll.so the bundle
# installs. The build's loader cannot be asked: it refuses to start outside
# the signed wine.app. The x86 tree builds the same WINE_SRC, so the string
# names the tests' source too.
tests_version=$(sed -n 's/^const char wine_build\[\] = "\(.*\)";$/\1/p' "$BUILD_DIR/dlls/ntdll/unix/version.c")
if [ -z "$tests_version" ]; then
    echo "Error: $BUILD_DIR/dlls/ntdll/unix/version.c defines no wine_build"
    exit 1
fi
echo "$tests_version" > "$WINE_SDK_DIR/lib/wine/tests/VERSION"
wine_src_commit > "$WINE_SDK_DIR/WINE_COMMIT"
echo "==> Wine SDK staged for $(cat "$WINE_SDK_DIR/WINE_COMMIT")."

# FEX, the x86 emulator, and DXMT, whose unix half and ARM64X DLLs link
# against this Wine's build tree and whose i386 DLLs link against the SDK,
# so both are built after them. vkd3d-proton, the D3D12 that goes into
# DXMT's tree, links nothing of Wine but is marked as a builtin with the
# build tree's and the SDK's winebuild.
"$SCRIPT_DIR/build-fex.sh" "${SUB_FLAGS[@]}"
"$SCRIPT_DIR/build-dxmt.sh" "${SUB_FLAGS[@]}"
"$SCRIPT_DIR/build-vkd3d-proton.sh" "${SUB_FLAGS[@]}"
