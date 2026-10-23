#!/bin/bash
set -e

# Builds FEX, the x86 emulator of the Wine, from athei/FEX (upstream FEX
# with our commits on top; FEX_REPO names another repository) at the ref in
# fex-src.ref (a branch, tag or commit). Called by build-wine.sh; running it
# alone rebuilds FEX only. Three CMake trees under FEX_BUILD_DIR,
# following Hadron's recipe:
#
#   wow64/    libwow64fex.dll, an aarch64 PE that runs i386 code under WoW64
#             (Wine loads it as xtajit.dll)
#   arm64ec/  libarm64ecfex.dll, an ARM64EC PE that runs x86_64 code
#             (Wine loads it as xtajit64.dll)
#   unixlib/  libwow64fex.so and libarm64ecfex.so, their macOS halves
#
# The four files are installed from the trees and staged in FEX_DIST, in the
# layout of a Wine install's lib/wine, which bundle-wine.sh installs from:
#
#   aarch64-windows/{libwow64fex,libarm64ecfex}.dll
#   aarch64-unix/{libwow64fex,libarm64ecfex}.so
#   KEY      what the dist was built from (dist_key in profile.sh)
#   COMMIT   the source commit
#
# Nothing is built when FEX_DIST is complete and has the KEY this run would
# write (skip_current_dist in profile.sh). --clean wipes FEX_BUILD_DIR and
# FEX_DIST first. --print-key prints that KEY and exits (print_dist_key).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MINGW_DIR="${MINGW_DIR:-/opt/llvm-mingw}"

CLEAN=0
PRINT_KEY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --clean) CLEAN=1; shift ;;
        --print-key) PRINT_KEY=1; shift ;;
        *) echo "Usage: $0 [--clean | --print-key]"; exit 1 ;;
    esac
done

# profile.sh names FEX's repository, clone and dist, says where the trees go
# and pins the floor of the unix half.
# shellcheck source=lib/profile.sh
. "$SCRIPT_DIR/lib/profile.sh"

FEX_REF="$(tr -d '[:space:]' < "$PINS_DIR/fex-src.ref")"
if [ -z "$FEX_REF" ]; then
    echo "Error: $PINS_DIR/fex-src.ref is empty"
    exit 1
fi

for tool in cmake ninja git; do
    if ! command -v "$tool" >/dev/null; then
        echo "Error: $tool not found (brew install $tool)"
        exit 1
    fi
done
for triple in aarch64-w64-mingw32 arm64ec-w64-mingw32; do
    if [ ! -x "$MINGW_DIR/bin/$triple-clang" ]; then
        echo "Error: llvm-mingw at $MINGW_DIR has no $triple toolchain"
        exit 1
    fi
done
# Appended, never prepended: llvm-mingw's bin/ has an unprefixed clang that
# would otherwise stand in for Apple's in the unixlib build.
export PATH="$PATH:$MINGW_DIR/bin"

# ── Dist ────────────────────────────────────────────────────────────────
# fex_key <commit>: the KEY of a FEX_DIST built from <commit>. Besides the
# commit, which fixes the submodules too, what the trees are built with:
# llvm-mingw for the PE halves, Apple's clang and the macOS SDK for the unix
# half, and the floor, which a MACOSX_DEPLOYMENT_TARGET can raise.
fex_key() {
    dist_key "$SCRIPT_DIR/build-fex.sh" "fex=$1" "$(mingw_key)" \
        "cc=$(cc_version /usr/bin/clang)" "$(sdk_key)" "floor=$MACOS_FLOOR"
}
FEX_WANT=$(src_ref_commit fex-src.ref "$FEX_REPO")
print_dist_key "$FEX_WANT" fex-src.ref fex_key

if [ "$CLEAN" -eq 1 ]; then
    echo "==> Cleaning $FEX_BUILD_DIR..."
fi
# FEX_DIST is inside FEX_BUILD_DIR unless overridden, so it is claimed on
# its own, and so is FEX_DIST.part below.
claim_tree "$FEX_BUILD_DIR" fex "$CLEAN"
claim_tree "$FEX_DIST" fex-dist "$CLEAN"
skip_current_dist "$FEX_DIST" FEX "$FEX_WANT" fex_key

# ── Source ──────────────────────────────────────────────────────────────
# The ref is fetched from FEX_REPO by URL, so this works the same whatever
# the local clone calls its remotes. A tree with local changes is refused
# rather than reset: those changes are somebody's work, and building from
# them would not be building the ref. Submodules are left out of that check
# because the update below moves them to the commits the ref records. git
# is kept from asking for credentials, so an unattended run fails instead of
# waiting.
echo "==> FEX source: $FEX_REPO $FEX_REF"
if [ ! -e "$FEX_SRC/.git" ]; then
    GIT_TERMINAL_PROMPT=0 git clone "$FEX_REPO" "$FEX_SRC"
fi
if [ -n "$(git -C "$FEX_SRC" status --porcelain --untracked-files=no --ignore-submodules=all)" ]; then
    echo "Error: $FEX_SRC has local changes; commit or stash them first"
    git -C "$FEX_SRC" status --short --untracked-files=no --ignore-submodules=all
    exit 1
fi
GIT_TERMINAL_PROMPT=0 git -C "$FEX_SRC" fetch --quiet "$FEX_REPO" "$FEX_REF"
git -C "$FEX_SRC" checkout --quiet --detach FETCH_HEAD
git -C "$FEX_SRC" submodule update --init --recursive
# A leading '+', '-' or 'U' marks a submodule that is not at the recorded
# commit, not checked out, or in conflict.
if git -C "$FEX_SRC" submodule status --recursive | grep '^[-+U]' >/dev/null; then
    echo "Error: FEX submodules do not match $FEX_REF:"
    git -C "$FEX_SRC" submodule status --recursive | grep '^[-+U]'
    exit 1
fi
FEX_COMMIT=$(git -C "$FEX_SRC" rev-parse HEAD)
echo "    at $FEX_COMMIT"
# Where the commit the trees were built from was recorded before FEX_DIST.
rm -f "$FEX_BUILD_DIR/COMMIT"

# ── PE halves ───────────────────────────────────────────────────────────
# FEX's own mingw toolchain file picks <triple>-clang from PATH. The install
# directory is where Wine looks for an aarch64 or ARM64EC builtin.
for target in wow64 arm64ec; do
    case $target in
        wow64)   triple=aarch64-w64-mingw32 ;;
        arm64ec) triple=arm64ec-w64-mingw32 ;;
    esac
    echo "==> Building FEX $target ($triple)..."
    cmake -S "$FEX_SRC" -B "$FEX_BUILD_DIR/$target" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_TOOLCHAIN_FILE="$FEX_SRC/Data/CMake/toolchain_mingw.cmake" \
        -DMINGW_TRIPLE=$triple \
        -DCMAKE_INSTALL_LIBDIR="lib/wine/$PE64_DIR" \
        -DENABLE_LTO=False -DENABLE_ASSERTIONS=False -DENABLE_JEMALLOC_GLIBC_ALLOC=False \
        -DBUILD_TESTING=False -DTUNE_ARCH=generic -DTUNE_CPU=none -DRANGES_NATIVE=OFF \
        >/dev/null
    cmake --build "$FEX_BUILD_DIR/$target"
done

# ── Unix half ───────────────────────────────────────────────────────────
# Apple's compilers named explicitly, held to the floor in profile.sh like
# the rest of the bundle.
echo "==> Building the FEX unixlib..."
cmake -S "$FEX_SRC/Source/Windows/UnixLib" -B "$FEX_BUILD_DIR/unixlib" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_FLOOR" \
    -DCMAKE_INSTALL_LIBDIR="lib/wine/$UNIX_DIR" \
    >/dev/null
cmake --build "$FEX_BUILD_DIR/unixlib"

# ── Stage ───────────────────────────────────────────────────────────────
# Each tree is installed, as CMake installs it for the paths set above, into
# a scratch prefix, since the install also carries headers, tools and data
# that have no place in a Wine tree, and only the four files are staged.
# They go into FEX_DIST.part, which is renamed into place once complete, so
# an interrupted or failed run never leaves a FEX_DIST that looks finished.
echo "==> Staging FEX into $FEX_DIST..."
install="$FEX_BUILD_DIR/install"
remove_tree "$install"
for t in wow64 arm64ec unixlib; do
    cmake --install "$FEX_BUILD_DIR/$t" --prefix "$install" >/dev/null
done
part="$FEX_DIST.part"
claim_tree "$part" fex-dist 1
mkdir -p "$part/$PE64_DIR" "$part/$UNIX_DIR"
for f in "$PE64_DIR/libwow64fex.dll" "$PE64_DIR/libarm64ecfex.dll" \
         "$UNIX_DIR/libwow64fex.so" "$UNIX_DIR/libarm64ecfex.so"; do
    if [ ! -f "$install/lib/wine/$f" ]; then
        echo "Error: the FEX install has no lib/wine/$f"
        exit 1
    fi
    cp "$install/lib/wine/$f" "$part/$f"
done
remove_tree "$install"
fex_key "$FEX_COMMIT" > "$part/KEY"
# Written last, so a staged directory without it is an incomplete one. The
# bundle step compares it with what fex-src.ref names.
echo "$FEX_COMMIT" > "$part/COMMIT"
remove_tree "$FEX_DIST"
mv "$part" "$FEX_DIST"
echo "==> FEX $FEX_COMMIT staged in $FEX_DIST."
