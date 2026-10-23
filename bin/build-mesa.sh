#!/bin/bash
set -e

# Builds the Vulkan stack of the Wine and stages it in MESA_DIST:
#
#   lib/libvulkan.1.dylib            the Khronos Vulkan loader, which
#                                    win32u.so loads
#   lib/libvulkan.dylib              a link to it, what -lvulkan finds
#   lib/libvulkan_kosmickrisp.dylib  KosmicKrisp, Mesa's Vulkan driver on Metal
#   lib/libEGL.1.dylib               Mesa's EGL, OpenGL through Zink on
#                                    KosmicKrisp, which win32u.so loads
#   lib/libEGL.dylib                 a link to it, what -lEGL finds
#   lib/libgallium-<version>.dylib   Mesa's gallium library with Zink, which
#                                    libEGL.1.dylib links; Zink opens the
#                                    loader next to it
#   lib/pkgconfig/egl.pc             what Wine's configure finds EGL with
#   share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json
#                                    the driver's manifest, which names the
#                                    driver by a path relative to itself
#   LOADER_COMMIT                    the loader's source commit
#   KEY                              what the dist was built from
#                                    (dist_key in profile.sh)
#   COMMIT                           Mesa's source commit
#
# Mesa comes from athei/mesa (upstream Mesa plus our topic commits,
# originally from Hadron's patches; MESA_REPO names another repository) at
# the ref in mesa-src.ref (a branch, tag or commit). Called by build-wine.sh
# before Wine's configure, which links against this loader and finds EGL
# here; running it alone rebuilds the Vulkan and OpenGL stack only.
# bundle-wine.sh installs from MESA_DIST.
#
# The loader is built from the Vulkan-Loader and Vulkan-Headers tags pinned
# in redist.env, for the floor: Homebrew's vulkan-loader bottle needs a newer
# macOS.
#
# KosmicKrisp is built in two stages. Its build compiles the driver's OpenCL
# C kernels with three tools of its own (mesa_clc, vtn_bindgen2, kk_clc),
# which link LLVM, SPIRV-LLVM-Translator and SPIRV-Tools, and Homebrew has
# those only as libraries for the host's macOS. Stage 1 builds just those
# tools against them, for the host. Stage 2 builds the driver for the floor
# with LLVM and SPIRV-Tools off and the tools of stage 1 named in its native
# file, so the driver links system libraries only. Mesa's build scripts need
# Python modules, which come from a virtual environment in MESA_BUILD_DIR, at
# the versions redist.env pins.
#
# Nothing is built when MESA_DIST is complete and has the KEY this run would
# write (skip_current_dist in profile.sh). --clean builds the driver tree and
# MESA_DIST from scratch. Like build-dxmt.sh's LLVM, what does not depend on
# Mesa's source is kept while its key matches: the loader and header clones,
# the built loader, the Python environment and the stage 1 tools.
# --print-key prints that KEY and exits (print_dist_key).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

CLEAN=0
PRINT_KEY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --clean) CLEAN=1; shift ;;
        --print-key) PRINT_KEY=1; shift ;;
        *) echo "Usage: $0 [--clean | --print-key]"; exit 1 ;;
    esac
done

# profile.sh names Mesa's repository and clone, says where the trees go and
# pins the floor.
# shellcheck source=lib/profile.sh
. "$SCRIPT_DIR/lib/profile.sh"
# shellcheck source=../pins/redist.env
. "$PINS_DIR/redist.env"

MESA_REF="$(tr -d '[:space:]' < "$PINS_DIR/mesa-src.ref")"
if [ -z "$MESA_REF" ]; then
    echo "Error: $PINS_DIR/mesa-src.ref is empty"
    exit 1
fi

HEADERS_SRC="$MESA_BUILD_DIR/vulkan-headers"
HEADERS_BUILD="$MESA_BUILD_DIR/vulkan-headers-build"
HEADERS_PREFIX="$MESA_BUILD_DIR/vulkan-headers-install"
LOADER_SRC="$MESA_BUILD_DIR/vulkan-loader"
LOADER_BUILD="$MESA_BUILD_DIR/vulkan-loader-build"
LOADER_PREFIX="$MESA_BUILD_DIR/vulkan-loader-install"
VENV="$MESA_BUILD_DIR/venv"
TOOLS_BUILD="$MESA_BUILD_DIR/tools"
DRIVER_BUILD="$MESA_BUILD_DIR/driver"
DRIVER_PREFIX="$MESA_BUILD_DIR/driver-install"
ICD_JSON=kosmickrisp_mesa_icd.aarch64.json
# The stage 1 tools, as build targets of the tools tree.
TOOLS="src/compiler/clc/mesa_clc src/compiler/spirv/vtn_bindgen2 src/kosmickrisp/clc/kk_clc"

# ── Preflight ───────────────────────────────────────────────────────────
for tool in git meson ninja cmake pkg-config python3 plutil; do
    if ! command -v "$tool" >/dev/null; then
        case $tool in
            pkg-config) echo "Error: pkg-config not found (brew install pkgconf)" ;;
            python3) echo "Error: python3 not found (brew install python)" ;;
            plutil) echo "Error: plutil not found (it comes with macOS)" ;;
            *) echo "Error: $tool not found (brew install $tool)" ;;
        esac
        exit 1
    fi
done
# By path, since stage 2 runs them with Homebrew off PATH.
MESON=$(command -v meson)
NINJA=$(command -v ninja)
# What the stage 1 tools link (MESA_FORMULAE in profile.sh). What stage 2
# builds needs none of them.
missing=""
for f in $MESA_FORMULAE; do
    [ -d "$DEPS_PREFIX/opt/$f" ] || missing="$missing $f"
done
if [ -n "$missing" ]; then
    echo "Error: not installed in $DEPS_PREFIX:$missing"
    echo "Run: $DEPS_PREFIX/bin/brew install$missing"
    exit 1
fi
LLVM_CONFIG="$DEPS_PREFIX/opt/llvm/bin/llvm-config"
if [ ! -x "$LLVM_CONFIG" ]; then
    echo "Error: no llvm-config at $LLVM_CONFIG"
    exit 1
fi
# Mesa's GLSL compiler needs a newer bison than macOS's 2.3; Wine's configure
# takes the same one (DEPS_FORMULAE).
BISON="$DEPS_PREFIX/opt/bison/bin/bison"
if [ ! -x "$BISON" ]; then
    echo "Error: no bison at $BISON (brew install bison)"
    exit 1
fi
# macOS's own flex is new enough, and Homebrew's is keg-only; it is named in
# the native file so a flex elsewhere on PATH is not taken.
FLEX=/usr/bin/flex
if [ ! -x "$FLEX" ]; then
    echo "Error: no flex at $FLEX (install the Xcode command line tools)"
    exit 1
fi
check_sdk_floor

# Only Apple's compilers, named in the native files, and none of the
# caller's flags or pkg-config paths, which would reach both stages. Each
# stage sets the pkg-config search it needs.
unset CC CXX OBJC OBJCXX CFLAGS CXXFLAGS OBJCFLAGS CPPFLAGS LDFLAGS \
      PKG_CONFIG_PATH PKG_CONFIG_LIBDIR

# ── Dist ────────────────────────────────────────────────────────────────
# mesa_key <commit>: the KEY of a MESA_DIST built from <commit>. Besides the
# commit, what the loader's key and the setup keys of the two trees below
# hold, as far as it is known before anything is built: the pinned loader and
# headers, the floor, the Python modules and Python, the versions of the
# Homebrew libraries the stage 1 tools link, bison and flex; and Apple's
# clang and the macOS SDK, which compile all of it. The stage 1 tools are fixed by these
# inputs, so their hash, which stage 2's key holds, is left out. The
# versions are read once, here, as the Python environment goes ahead of
# PATH below.
MESA_KEY_INPUTS="headers=$VULKAN_HEADERS_GIT_COMMIT loader=$VULKAN_LOADER_GIT_COMMIT floor=$MACOS_FLOOR"
MESA_KEY_INPUTS+=" requirements=$MESA_PYTHON_REQUIREMENTS"
MESA_KEY_INPUTS+=" python=$(python3 -c 'import platform; print(platform.python_version())')"
MESA_KEY_INPUTS+=" llvm=$("$LLVM_CONFIG" --version)"
MESA_KEY_INPUTS+=" spirv=$(PKG_CONFIG_PATH="$DEPS_PREFIX/lib/pkgconfig" pkg-config --modversion LLVMSPIRVLib SPIRV-Tools | paste -sd ' ' -)"
MESA_KEY_INPUTS+=" bison=$(cc_version "$BISON") flex=$(cc_version "$FLEX") cc=$(cc_version /usr/bin/clang)"
MESA_KEY_INPUTS+=" $(sdk_key)"
mesa_key() {
    dist_key "$SCRIPT_DIR/build-mesa.sh" "mesa=$1" "$MESA_KEY_INPUTS"
}
MESA_WANT=$(src_ref_commit mesa-src.ref "$MESA_REPO")
print_dist_key "$MESA_WANT" mesa-src.ref mesa_key

# The trees this script deletes and recreates are fixed paths in
# MESA_BUILD_DIR. MESA_DIST is inside it unless overridden, so it is claimed
# on its own, and so is MESA_DIST.part below.
claim_tree "$MESA_BUILD_DIR" mesa
if [ "$CLEAN" -eq 1 ]; then
    echo "==> Cleaning the KosmicKrisp driver tree and $MESA_DIST..."
    remove_tree "$DRIVER_BUILD" "$DRIVER_PREFIX"
fi
claim_tree "$MESA_DIST" mesa-dist "$CLEAN"
skip_current_dist "$MESA_DIST" Mesa "$MESA_WANT" mesa_key

# ── Source ──────────────────────────────────────────────────────────────
# As in build-fex.sh: the ref is fetched from MESA_REPO by URL, on every run
# that builds, and a tree with local changes is refused rather than reset. git is kept
# from asking for credentials, so an unattended run fails instead of
# waiting.
echo "==> Mesa source: $MESA_REPO $MESA_REF"
if [ ! -e "$MESA_SRC/.git" ]; then
    GIT_TERMINAL_PROMPT=0 git clone "$MESA_REPO" "$MESA_SRC"
fi
if [ -n "$(git -C "$MESA_SRC" status --porcelain --untracked-files=no)" ]; then
    echo "Error: $MESA_SRC has local changes; commit or stash them first"
    git -C "$MESA_SRC" status --short --untracked-files=no
    exit 1
fi
GIT_TERMINAL_PROMPT=0 git -C "$MESA_SRC" fetch --quiet "$MESA_REPO" "$MESA_REF"
git -C "$MESA_SRC" checkout --quiet --detach FETCH_HEAD
MESA_COMMIT=$(git -C "$MESA_SRC" rev-parse HEAD)
echo "    at $MESA_COMMIT"

# ── Vulkan loader ───────────────────────────────────────────────────────
# Built once per key: the two pinned commits and the floor. LOADER_PREFIX/KEY
# records it, and a loader built for another key, or none, is built again
# from fresh trees. The headers are installed into a prefix of their own,
# and the loader's configure is pointed at their CMake package, so it can
# only take these and not the arm64 Homebrew's.
LOADER_KEY="headers=$VULKAN_HEADERS_GIT_COMMIT loader=$VULKAN_LOADER_GIT_COMMIT floor=$MACOS_FLOOR"
if [ "$(cat "$LOADER_PREFIX/KEY" 2>/dev/null)" = "$LOADER_KEY" ]; then
    echo "==> Vulkan loader $VULKAN_LOADER_GIT_TAG: built already"
else
    echo "==> Vulkan headers: $VULKAN_HEADERS_GIT_URL $VULKAN_HEADERS_GIT_TAG"
    pinned_clone "$VULKAN_HEADERS_GIT_URL" "$VULKAN_HEADERS_GIT_TAG" "$VULKAN_HEADERS_GIT_COMMIT" "$HEADERS_SRC"
    remove_tree "$HEADERS_BUILD" "$HEADERS_PREFIX"
    cmake -S "$HEADERS_SRC" -B "$HEADERS_BUILD" -G Ninja \
        -DCMAKE_INSTALL_PREFIX="$HEADERS_PREFIX" \
        -DVULKAN_HEADERS_ENABLE_TESTS=OFF \
        -DVULKAN_HEADERS_ENABLE_MODULE=OFF >/dev/null
    cmake --install "$HEADERS_BUILD" >/dev/null
    HEADERS_CMAKE="$HEADERS_PREFIX/share/cmake/VulkanHeaders"
    if [ ! -f "$HEADERS_CMAKE/VulkanHeadersConfig.cmake" ]; then
        echo "Error: the Vulkan headers installed no CMake package at $HEADERS_CMAKE"
        exit 1
    fi

    echo "==> Vulkan loader: $VULKAN_LOADER_GIT_URL $VULKAN_LOADER_GIT_TAG"
    pinned_clone "$VULKAN_LOADER_GIT_URL" "$VULKAN_LOADER_GIT_TAG" "$VULKAN_LOADER_GIT_COMMIT" "$LOADER_SRC"
    remove_tree "$LOADER_BUILD"
    cmake -S "$LOADER_SRC" -B "$LOADER_BUILD" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=/usr/bin/clang \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_FLOOR" \
        -DVulkanHeaders_DIR="$HEADERS_CMAKE" \
        -DUPDATE_DEPS=OFF \
        -DBUILD_TESTS=OFF >/dev/null
    found=$(sed -n 's|^VulkanHeaders_DIR:[A-Z]*=||p' "$LOADER_BUILD/CMakeCache.txt")
    if [ "$(canonical_path "$found")" != "$(canonical_path "$HEADERS_CMAKE")" ]; then
        echo "Error: the loader's configure took the Vulkan headers from $found, not $HEADERS_CMAKE"
        exit 1
    fi
    cmake --build "$LOADER_BUILD"
    # Installed next to LOADER_PREFIX and renamed into place, so an
    # interrupted install never leaves a LOADER_PREFIX with a KEY behind.
    remove_tree "$LOADER_PREFIX.part"
    cmake --install "$LOADER_BUILD" --prefix "$LOADER_PREFIX.part" >/dev/null
    echo "$LOADER_KEY" > "$LOADER_PREFIX.part/KEY"
    remove_tree "$LOADER_PREFIX"
    mv "$LOADER_PREFIX.part" "$LOADER_PREFIX"
fi

# ── Python ──────────────────────────────────────────────────────────────
# Made again when the pinned requirements changed, or when it cannot import
# the modules, which is also what an upgraded Homebrew Python leaves behind.
# Its Python version is part of both setup keys below.
if [ "$(cat "$VENV/REQUIREMENTS" 2>/dev/null)" != "$MESA_PYTHON_REQUIREMENTS" ] \
    || ! "$VENV/bin/python3" -c 'import mako, packaging, yaml' 2>/dev/null; then
    echo "==> Python environment for Mesa's build scripts..."
    remove_tree "$VENV"
    python3 -m venv "$VENV"
    # shellcheck disable=SC2086 # one word per requirement
    "$VENV/bin/python3" -m pip install --quiet --disable-pip-version-check $MESA_PYTHON_REQUIREMENTS
    echo "$MESA_PYTHON_REQUIREMENTS" > "$VENV/REQUIREMENTS"
fi
export PATH="$VENV/bin:$PATH"
PYTHON_VERSION=$("$VENV/bin/python3" -c 'import platform; print(platform.python_version())')

# write_if_changed <file>: write stdin to <file>, but leave the file alone
# when it already holds that. meson regenerates a tree whenever its native
# file is newer, even with the same content.
write_if_changed() {
    cat > "$1.new"
    if cmp -s "$1.new" "$1"; then
        rm -f "$1.new"
    else
        mv "$1.new" "$1"
    fi
}

# mesa_setup <dir> <native-file> <option>...: configure a Mesa tree, again
# from scratch whenever its native file, its options, what it links from
# outside or the Mesa commit differs from what it was configured with (the
# key in .setup-key). meson would follow changes to Mesa's sources by itself,
# but a fresh setup after a new commit also applies the option defaults
# upstream changed, and fails on an option of ours upstream renamed.
mesa_setup() {
    local dir="$1" native="$2" key
    shift 2
    key="$(cat "$native") $* python=$PYTHON_VERSION mesa=$MESA_COMMIT ${SETUP_EXTRA:-}"
    if [ "$(cat "$dir/.setup-key" 2>/dev/null)" != "$key" ]; then
        remove_tree "$dir"
        "$MESON" setup "$dir" "$MESA_SRC" --native-file "$native" "$@" >/dev/null || {
            echo "Error: meson setup of $dir failed; see $dir/meson-logs/meson-log.txt"
            exit 1
        }
        echo "$key" > "$dir/.setup-key"
    fi
}

# ── KosmicKrisp, stage 1: the host tools ────────────────────────────────
# Built for the host, not the floor: they run here and nowhere else, and
# the Homebrew libraries they link are newer than the floor anyway, found
# through the arm64 Homebrew's pkg-config files. The versions of those
# libraries are part of the key, since a tool linked against an upgraded one
# has to be linked again.
#
# The compilers of both native files, Apple's, go through ccache with
# WINE_BUILD_CCACHE (profile.sh), named by its path, since stage 2 runs with
# Homebrew off PATH. The native file is part of each setup key, so setting
# or unsetting it configures both trees again.
if [ -n "$WINE_CCACHE" ]; then
    NATIVE_CC="['$WINE_CCACHE', '/usr/bin/clang']"
    NATIVE_CXX="['$WINE_CCACHE', '/usr/bin/clang++']"
else
    NATIVE_CC="'/usr/bin/clang'"
    NATIVE_CXX="'/usr/bin/clang++'"
fi
echo "==> Building KosmicKrisp's host tools..."
write_if_changed "$MESA_BUILD_DIR/tools-native.ini" <<EOF
[binaries]
c = $NATIVE_CC
cpp = $NATIVE_CXX
objc = $NATIVE_CC
objcpp = $NATIVE_CXX
llvm-config = '$LLVM_CONFIG'
EOF
(
    unset MACOSX_DEPLOYMENT_TARGET
    export PKG_CONFIG_PATH="$DEPS_PREFIX/lib/pkgconfig"
    SETUP_EXTRA="llvm=$("$LLVM_CONFIG" --version)"
    SETUP_EXTRA+=" $(pkg-config --modversion LLVMSPIRVLib SPIRV-Tools | tr '\n' ' ')"
    mesa_setup "$TOOLS_BUILD" "$MESA_BUILD_DIR/tools-native.ini" \
        --buildtype=release \
        -Dplatforms=macos -Dvulkan-drivers=kosmickrisp -Dgallium-drivers= \
        -Dopengl=false -Dzstd=disabled \
        -Dmesa-clc=enabled -Dprecomp-compiler=enabled
    # shellcheck disable=SC2086 # one word per target
    ninja -C "$TOOLS_BUILD" $TOOLS
)

# ── KosmicKrisp, stage 2: the driver ────────────────────────────────────
# For the floor, which profile.sh exports as MACOSX_DEPLOYMENT_TARGET and
# the native file passes on as well. CoreGraphics is linked explicitly: the
# driver calls CGColorSpace functions, which it otherwise only finds through
# QuartzCore at run time, as flat-namespace imports. The key carries a hash
# of the stage 1 tools, since meson does not rebuild what they generated
# when they change.
#
# As with Wine's configure, every optional dependency is denied unless the
# driver needs it, so a library that happens to be installed cannot change
# what is built: each Mesa feature option that looks for an optional library
# is disabled here. The probes that have no option (libudev, lua, libelf,
# glslangValidator) find nothing in the arm64 Homebrew either: pkg-config
# searches nowhere (an empty PKG_CONFIG_LIBDIR), the native file names false
# as cmake, so meson's CMake lookup has no CMake to search with, and meson
# and ninja run with a PATH of the Python environment and the system
# directories only, so Homebrew's glslangValidator is not found and does not
# add the shaders it would compile (ASTC decoding) to the driver. A native
# file entry cannot deny a program: meson takes the entry as found without
# looking, and Mesa then runs it for its --version. Every other program the
# build runs is named in the native file. zlib stays, as Mesa's default,
# from the SDK.
#
# The same tree builds OpenGL through Zink on KosmicKrisp: Mesa's EGL
# (libEGL.1.dylib) and the gallium library with Zink it links
# (libgallium-<version>.dylib). EGL's surfaceless platform creates window
# surfaces on a CAMetalLayer, which Wine's Mac driver passes; win32u only
# binds desktop OpenGL through EGL, so GLES is not built. Zink loads the
# Vulkan loader by "@rpath/libvulkan.1.dylib", so the gallium library gets
# the one LC_RPATH the scripts allow, @loader_path, which finds the loader
# next to it here and in the bundle.
# Without LLVM, gallium's draw module runs its vertex shaders without LLVM
# too. GLX and GBM need X11 and DRM, which macOS has neither of; GLVND and
# VA-API are libraries the build would otherwise look for. The bison and flex
# versions are part of the key, since meson does not rebuild what they
# produced when they change.
echo "==> Building KosmicKrisp and Zink..."
min="-mmacosx-version-min=$MACOS_FLOOR"
write_if_changed "$MESA_BUILD_DIR/driver-native.ini" <<EOF
[binaries]
c = $NATIVE_CC
cpp = $NATIVE_CXX
objc = $NATIVE_CC
objcpp = $NATIVE_CXX
mesa_clc = '$TOOLS_BUILD/src/compiler/clc/mesa_clc'
vtn_bindgen2 = '$TOOLS_BUILD/src/compiler/spirv/vtn_bindgen2'
kk_clc = '$TOOLS_BUILD/src/kosmickrisp/clc/kk_clc'
bison = '$BISON'
flex = '$FLEX'
cmake = 'false'

[built-in options]
c_args = ['$min']
cpp_args = ['$min']
objc_args = ['$min']
c_link_args = ['$min', '-framework', 'CoreGraphics']
cpp_link_args = ['$min', '-framework', 'CoreGraphics']
objc_link_args = ['$min', '-framework', 'CoreGraphics']
EOF
(
    export PKG_CONFIG_LIBDIR=
    # meson finds ninja through NINJA when it is not on PATH.
    export NINJA
    export PATH="$VENV/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    # shellcheck disable=SC2086 # one word per target
    SETUP_EXTRA="tools=$(cd "$TOOLS_BUILD" && shasum -a 256 $TOOLS | cut -d' ' -f1 | tr '\n' ' ')"
    SETUP_EXTRA+=" bison=$("$BISON" --version | head -n 1) flex=$("$FLEX" --version | head -n 1)"
    mesa_setup "$DRIVER_BUILD" "$MESA_BUILD_DIR/driver-native.ini" \
        --prefix="$DRIVER_PREFIX" \
        --buildtype=release \
        -Dplatforms=macos -Dvulkan-drivers=kosmickrisp -Dgallium-drivers=zink \
        -Dopengl=true -Degl=enabled -Dgles1=disabled -Dgles2=disabled \
        -Dglx=disabled -Dgbm=disabled -Ddraw-use-llvm=false \
        -Dvulkan-loader-rpath=@loader_path \
        -Dmesa-clc=system -Dprecomp-compiler=system \
        -Dllvm=disabled -Dspirv-tools=disabled \
        -Dzstd=disabled -Ddisplay-info=disabled -Dexpat=disabled \
        -Dxmlconfig=disabled -Dvalgrind=disabled -Dlibunwind=disabled \
        -Dlmsensors=disabled -Dglvnd=disabled -Dgallium-va=disabled
    "$NINJA" -C "$DRIVER_BUILD"
    remove_tree "$DRIVER_PREFIX"
    "$NINJA" -C "$DRIVER_BUILD" install >/dev/null
)

# ── Stage ───────────────────────────────────────────────────────────────
# Into MESA_DIST.part, renamed into place once everything is checked, so an
# interrupted run never leaves a MESA_DIST behind that looks complete.
echo "==> Staging the Vulkan loader, KosmicKrisp and Zink into $MESA_DIST..."
part="$MESA_DIST.part"
claim_tree "$part" mesa-dist 1
mkdir -p "$part/lib/pkgconfig" "$part/share/vulkan/icd.d"
cp -L "$LOADER_PREFIX/lib/libvulkan.1.dylib" "$part/lib/"
ln -s libvulkan.1.dylib "$part/lib/libvulkan.dylib"
cp -L "$DRIVER_PREFIX/lib/libvulkan_kosmickrisp.dylib" "$part/lib/"
cp "$DRIVER_PREFIX/share/vulkan/icd.d/$ICD_JSON" "$part/share/vulkan/icd.d/"
# Mesa names the gallium library after its version, so it is found by
# pattern, and there has to be exactly one.
gallium=()
for lib in "$DRIVER_PREFIX"/lib/libgallium-*.dylib; do
    [ -f "$lib" ] && gallium+=("$(basename "$lib")")
done
if [ ${#gallium[@]} -ne 1 ]; then
    echo "Error: $DRIVER_PREFIX/lib has ${#gallium[@]} libgallium-*.dylib, not one: ${gallium[*]}"
    exit 1
fi
GALLIUM=${gallium[0]}
cp -L "$DRIVER_PREFIX/lib/libEGL.1.dylib" "$DRIVER_PREFIX/lib/$GALLIUM" "$part/lib/"
ln -s libEGL.1.dylib "$part/lib/libEGL.dylib"
chmod u+w "$part"/lib/*.dylib

# The install names both builds wrote are paths in their install prefixes.
# They become what bundle-wine.sh gives every bundled dylib, and libEGL's
# reference to the gallium library becomes one to the copy next to it. Since
# that invalidates the linker's signature, which arm64 code needs to load,
# each is signed again ad hoc, as the bundle step does.
install_name_tool -change "$DRIVER_PREFIX/lib/$GALLIUM" "@loader_path/$GALLIUM" \
    "$part/lib/libEGL.1.dylib" 2>/dev/null
for lib in libvulkan.1.dylib libvulkan_kosmickrisp.dylib libEGL.1.dylib "$GALLIUM"; do
    install_name_tool -id "@loader_path/$lib" "$part/lib/$lib" 2>/dev/null
    codesign --force --sign - "$part/lib/$lib" 2>/dev/null
done

# What Wine's configure finds EGL with: Mesa's egl.pc, with the prefix made
# relative to the file, so MESA_DIST is usable wherever it is, and without
# the include directory, which is not staged (Wine declares what it uses of
# EGL itself).
# shellcheck disable=SC2016 # ${pcfiledir} is pkg-config's variable
sed -e 's|^prefix=.*|prefix=${pcfiledir}/../..|' -e 's|^Cflags:.*|Cflags:|' \
    "$DRIVER_PREFIX/lib/pkgconfig/egl.pc" > "$part/lib/pkgconfig/egl.pc"
if ! PKG_CONFIG_LIBDIR="$part/lib/pkgconfig" pkg-config --libs egl | grep -F -- "-lEGL" >/dev/null; then
    echo "Error: the staged egl.pc does not give -lEGL"
    exit 1
fi

# Mesa writes the driver's absolute install path into the manifest. The
# loader reads a relative library_path as relative to the manifest, so the
# path from share/vulkan/icd.d to lib/ keeps MESA_DIST usable wherever it
# is; the bundle step rewrites it for the bundle's layout the same way.
icd="$part/share/vulkan/icd.d/$ICD_JSON"
plutil -replace ICD.library_path -string ../../../lib/libvulkan_kosmickrisp.dylib "$icd"
if [ "$(plutil -extract ICD.library_path raw -o - "$icd")" != ../../../lib/libvulkan_kosmickrisp.dylib ]; then
    echo "Error: $ICD_JSON does not name ../../../lib/libvulkan_kosmickrisp.dylib after rewriting it"
    exit 1
fi

# check_dylib [--loads <name>] [--rpath-loader-path] <file> <symbol>...:
# exit unless <file> is an arm64-only dylib held to the floor, named
# @loader_path/<its name>, loading system libraries only, without LC_RPATH,
# binding every import to a library (a flat-namespace import is looked up in
# whatever the process has loaded, and fails at run time where nothing
# provides it), and exporting each <symbol>. Two exceptions are allowed only
# where the caller names them: --loads <name> lets it load
# @loader_path/<name>, a library staged next to it and checked on its own
# (libEGL loads the gallium library so); --rpath-loader-path lets it have
# exactly one LC_RPATH, @loader_path, which resolves next to it (the gallium
# library, which loads the Vulkan loader by @rpath).
check_dylib() {
    local f name minos deps flat sym rpaths sibling="" rpath_ok=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --loads) sibling="$2"; shift 2 ;;
            --rpath-loader-path) rpath_ok=1; shift ;;
            *) break ;;
        esac
    done
    f="$1"
    name=$(basename "$f")
    shift
    if [ "$(lipo -archs "$f")" != arm64 ]; then
        echo "Error: $name is not an arm64-only Mach-O ($(lipo -archs "$f"))"
        exit 1
    fi
    minos=$(otool -l "$f" | awk '$1 == "cmd" && $2 == "LC_BUILD_VERSION" { v = 1 } v && $1 == "minos" { print $2; exit }')
    if [ -z "$minos" ] || macos_newer "$minos" "$MACOS_FLOOR"; then
        echo "Error: $name has minos '${minos:-none}', the floor is $MACOS_FLOOR"
        exit 1
    fi
    if [ "$(otool -D "$f" | tail -n +2)" != "@loader_path/$name" ]; then
        echo "Error: $name has the install name $(otool -D "$f" | tail -n +2)"
        exit 1
    fi
    deps=$(otool -L "$f" | tail -n +3 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/Library/)' || true)
    if [ -n "$sibling" ]; then
        if [ ! -f "$(dirname "$f")/$sibling" ]; then
            echo "Error: $sibling, which $name may load, is not staged next to it"
            exit 1
        fi
        deps=$(echo "$deps" | grep -vxF "@loader_path/$sibling" || true)
    fi
    if [ -n "$deps" ]; then
        echo "Error: $name loads libraries outside the system:"
        echo "$deps" | sed 's/^/    /'
        exit 1
    fi
    rpaths=$(otool -l "$f" | awk '$1 == "cmd" { r = ($2 == "LC_RPATH") } r && $1 == "path" { print $2 }')
    if [ -n "$rpaths" ] && { [ "$rpath_ok" -eq 0 ] || [ "$rpaths" != "@loader_path" ]; }; then
        echo "Error: $name has the LC_RPATH entries:"
        echo "$rpaths" | sed 's/^/    /'
        exit 1
    fi
    flat=$(nm -m -u "$f" | grep 'dynamically looked up' | grep -v 'weak external' || true)
    if [ -n "$flat" ]; then
        echo "Error: $name has flat-namespace imports:"
        echo "$flat" | sed 's/^/    /'
        exit 1
    fi
    for sym in "$@"; do
        if ! nm -gU "$f" | awk '{print $NF}' | grep -xF "$sym" >/dev/null; then
            echo "Error: $name does not export $sym"
            exit 1
        fi
    done
    echo "    $name: arm64, minos $minos, system libraries only, exports $*"
}
check_dylib "$part/lib/libvulkan.1.dylib" _vkGetInstanceProcAddr _vkCreateMetalSurfaceEXT
check_dylib "$part/lib/libvulkan_kosmickrisp.dylib" _vk_icdGetInstanceProcAddr
check_dylib --loads "$GALLIUM" "$part/lib/libEGL.1.dylib" _eglGetProcAddress _eglCreateWindowSurface
check_dylib --rpath-loader-path "$part/lib/$GALLIUM" _driCreateNewScreen3 _kopperSwapBuffers
# Zink opens the Vulkan loader by "@rpath/libvulkan.1.dylib", which the
# @loader_path LC_RPATH resolves to the copy next to the gallium library.
if ! grep -aF "@rpath/libvulkan.1.dylib" "$part/lib/$GALLIUM" >/dev/null \
    || [ "$(otool -l "$part/lib/$GALLIUM" | awk '$1 == "cmd" { r = ($2 == "LC_RPATH") } r && $1 == "path" { print $2 }')" != "@loader_path" ]; then
    echo "Error: $GALLIUM does not open @rpath/libvulkan.1.dylib with @loader_path as its LC_RPATH,"
    echo "so Zink would not find the Vulkan loader next to it"
    exit 1
fi
echo "    $GALLIUM opens the Vulkan loader next to it (@rpath, LC_RPATH @loader_path)"

echo "$VULKAN_LOADER_GIT_COMMIT" > "$part/LOADER_COMMIT"
mesa_key "$MESA_COMMIT" > "$part/KEY"
# Written last, so a staged directory without it is an incomplete one.
echo "$MESA_COMMIT" > "$part/COMMIT"
remove_tree "$MESA_DIST"
mv "$part" "$MESA_DIST"
echo "==> Mesa $MESA_COMMIT and the Vulkan loader $VULKAN_LOADER_GIT_TAG staged in $MESA_DIST."
