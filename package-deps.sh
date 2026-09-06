#!/bin/bash
set -e

# Builds the x86_64 dependency prefix that the release workflow unpacks into
# /usr/local, and which CI can no longer produce for itself.
#
# Homebrew has stopped shipping x86_64 macOS bottles: gmp, sdl2-compat and
# sdl3 have none at all, and the rest stop at the sonoma tag. Installing them
# on a runner therefore means compiling from source, which took 48 minutes
# when it worked and failed outright once gmp's formula could no longer be
# fetched: the runners resolve neither ftpmirror.gnu.org nor gmplib.org.
#
# So the tree is built once here, on a machine that already has an Intel
# Homebrew, and mirrored as a release asset. The libraries come from Homebrew's
# sonoma bottles, so they carry a minos of 14.0, below the 15.0 that
# build-wine.sh pins; building them from source on a current macOS would raise
# that floor instead. Upload the result with:
#
#   gh release create deps-<date> --title ... dist/wine-deps-macos-x86_64.tar.xz
#
# then point DEPS_URL and DEPS_SHA256 in .github/workflows/release.yml at it.
#
# gmp is the exception: it is the one formula with no x86_64 bottle at all, so
# Homebrew compiles it here and stamps it with this machine's macOS version.
# cx-26.3.0-8 shipped a libgmp with a minos of 26.0 for exactly that reason,
# which would have failed to load on anything older. It is rebuilt below
# against MACOS_FLOOR, and every Mach-O in the staged tree is checked against
# that floor before the archive is written.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${PREFIX:-/usr/local}"
BREW="${BREW:-$PREFIX/bin/brew}"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
OUT="$OUT_DIR/wine-deps-macos-x86_64.tar.xz"

# The libraries Wine links against plus the one build tool that has to be
# x86_64-adjacent; everything else in the closure comes along automatically.
ROOTS=(freetype gnutls sdl2-compat sdl3 bison)

# Must match MACOSX_DEPLOYMENT_TARGET in build-wine.sh.
MACOS_FLOOR="${MACOS_FLOOR:-15.0}"

GMP_VERSION="6.3.0"
GMP_URL="https://ftp.gnu.org/gnu/gmp/gmp-$GMP_VERSION.tar.xz"
GMP_SHA256="a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898"

if [ ! -x "$BREW" ]; then
    echo "Error: no Homebrew at $BREW"
    echo "This needs the x86_64 Homebrew, not the native one."
    exit 1
fi

# A native-arch brew here would hand us arm64 libraries that CI cannot link.
BREW_ARCH=$(arch -x86_64 "$BREW" config 2>/dev/null | awk '/^HOMEBREW_PREFIX/{print $2}')
if [ "$BREW_ARCH" != "$PREFIX" ]; then
    echo "Error: $BREW reports prefix '$BREW_ARCH', expected '$PREFIX'"
    exit 1
fi

echo "==> Checking the roots are installed..."
for f in "${ROOTS[@]}"; do
    if [ ! -d "$PREFIX/Cellar/$f" ]; then
        echo "Error: $f is not installed in $PREFIX"
        echo "Run: arch -x86_64 $BREW install ${ROOTS[*]}"
        exit 1
    fi
done

echo "==> Resolving the runtime closure..."
DEPS=$(HOMEBREW_NO_AUTO_UPDATE=1 arch -x86_64 "$BREW" deps --union "${ROOTS[@]}" 2>/dev/null)
FORMULAE=$(printf '%s\n' "${ROOTS[@]}" $DEPS | sort -u)
echo "$FORMULAE" | tr '\n' ' '; echo

# Cellar trees and their opt/ aliases, as paths relative to the prefix so the
# archive untars straight over /usr/local.
LIST=$(mktemp)
GMP_WORK=""
trap 'rm -f "$LIST" "$CELLARS"' EXIT
CELLARS=$(mktemp)
for f in $FORMULAE; do
    [ -d "$PREFIX/Cellar/$f" ] || { echo "Error: $f not installed"; exit 1; }
    echo "Cellar/$f" >> "$LIST"
    echo "$PREFIX/Cellar/$f" >> "$CELLARS"
    [ -e "$PREFIX/opt/$f" ] && echo "opt/$f" >> "$LIST"
done

# Homebrew's visible prefix is symlinks into the Cellar. Without them Wine's
# configure finds no headers, no .pc files and no bison. Keep every link that
# resolves into a Cellar tree we are shipping, and nothing else.
echo "==> Collecting prefix symlinks..."
for d in bin lib include share etc sbin Frameworks; do
    [ -d "$PREFIX/$d" ] || continue
    while IFS= read -r link; do
        target=$(cd "$(dirname "$link")" && realpath "$(readlink "$link")" 2>/dev/null) || continue
        while IFS= read -r cellar; do
            case "$target" in
                "$cellar"/*)
                    echo "${link#"$PREFIX"/}" >> "$LIST"
                    break
                    ;;
            esac
        done < "$CELLARS"
    done < <(find "$PREFIX/$d" -type l)
done

sort -u "$LIST" -o "$LIST"

STAGE=$(mktemp -d)
trap 'rm -f "$LIST" "$CELLARS"; rm -rf "$STAGE" "$GMP_WORK"' EXIT
echo "==> Staging $(wc -l < "$LIST" | tr -d ' ') entries..."
tar -C "$PREFIX" -cf - -T "$LIST" | tar -C "$STAGE" -xf -

# Homebrew builds gmp here, against this machine's macOS, because there is no
# x86_64 bottle to pour. Rebuild it against the floor and drop it in.
GMP_CELLAR="$STAGE/Cellar/gmp/$GMP_VERSION"
if [ ! -d "$GMP_CELLAR" ]; then
    echo "Error: expected gmp $GMP_VERSION in the closure, found $(ls "$STAGE/Cellar/gmp" 2>/dev/null)"
    echo "Update GMP_VERSION to match the installed formula."
    exit 1
fi

echo "==> Rebuilding gmp $GMP_VERSION against macOS $MACOS_FLOOR..."
GMP_WORK=$(mktemp -d)
GMP_TAR="$GMP_WORK/gmp.tar.xz"
curl -fsSL -o "$GMP_TAR" "$GMP_URL"
echo "$GMP_SHA256  $GMP_TAR" | shasum -a 256 -c - > /dev/null
tar -C "$GMP_WORK" -xJf "$GMP_TAR"

(
    cd "$GMP_WORK/gmp-$GMP_VERSION"
    # Same flags the formula uses. --prefix is the real Cellar path so libtool
    # embeds install names Homebrew's dependents already expect; DESTDIR keeps
    # the files out of the live prefix.
    MACOSX_DEPLOYMENT_TARGET="$MACOS_FLOOR" \
    CC="clang -arch x86_64" CXX="clang++ -arch x86_64" \
        ./configure --prefix="$PREFIX/Cellar/gmp/$GMP_VERSION" \
            --enable-cxx --with-pic \
            --build=x86_64-apple-darwin"$(uname -r | cut -d. -f1)" \
            --disable-dependency-tracking --disable-silent-rules > /dev/null
    MACOSX_DEPLOYMENT_TARGET="$MACOS_FLOOR" make -j"$(sysctl -n hw.ncpu)" > /dev/null
    make install DESTDIR="$GMP_WORK/dest" > /dev/null
) || { echo "Error: gmp rebuild failed"; exit 1; }

# Homebrew serves libraries from opt/, not Cellar/, and its dependents link
# against that path, so the rebuilt dylibs have to claim the same identity.
GMP_BUILT="$GMP_WORK/dest$PREFIX/Cellar/gmp/$GMP_VERSION"
for dylib in "$GMP_BUILT"/lib/*.dylib; do
    [ -f "$dylib" ] && [ ! -L "$dylib" ] || continue
    base=$(basename "$dylib")
    install_name_tool -id "$PREFIX/opt/gmp/lib/$base" "$dylib" 2>/dev/null
    otool -L "$dylib" | tail -n +2 | awk '{print $1}' | grep "Cellar/gmp/" | while read -r ref; do
        install_name_tool -change "$ref" "$PREFIX/opt/gmp/lib/$(basename "$ref")" "$dylib" 2>/dev/null
    done
done
rm -rf "$GMP_CELLAR/lib" "$GMP_CELLAR/include"
cp -R "$GMP_BUILT/lib" "$GMP_BUILT/include" "$GMP_CELLAR/"

# Nothing ships unless it can actually load on the floor we claim to support.
echo "==> Verifying every Mach-O against macOS $MACOS_FLOOR..."
FLOOR_MAJOR=${MACOS_FLOOR%%.*}
BAD=0
while IFS= read -r f; do
    minos=$(otool -l "$f" 2>/dev/null | awk '/LC_BUILD_VERSION/{v=1} v&&/minos/{print $2; exit}')
    [ -n "$minos" ] || continue
    if [ "${minos%%.*}" -gt "$FLOOR_MAJOR" ]; then
        echo "  too new: minos $minos  ${f#"$STAGE"/}"
        BAD=1
    fi
done < <(find "$STAGE" -type f -perm +111 -o -type f -name '*.dylib')
if [ "$BAD" -ne 0 ]; then
    echo
    echo "Error: the above were built against a newer macOS than $MACOS_FLOOR."
    echo "Homebrew has no x86_64 bottle for them either, so they were compiled"
    echo "on this machine. Rebuild them against the floor the way gmp is above."
    exit 1
fi
echo "    all clear"

echo "==> Archiving..."
mkdir -p "$OUT_DIR"
XZ_OPT="-T0 -9" tar -C "$STAGE" -cJf "$OUT" .

echo
echo "==> Wrote $OUT"
echo "    size:   $(du -h "$OUT" | cut -f1)"
echo "    sha256: $(shasum -a 256 "$OUT" | cut -d' ' -f1)"
