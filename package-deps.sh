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

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${PREFIX:-/usr/local}"
BREW="${BREW:-$PREFIX/bin/brew}"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
OUT="$OUT_DIR/wine-deps-macos-x86_64.tar.xz"

# The libraries Wine links against plus the one build tool that has to be
# x86_64-adjacent; everything else in the closure comes along automatically.
ROOTS=(freetype gnutls sdl2-compat sdl3 bison)

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
echo "==> Archiving $(wc -l < "$LIST" | tr -d ' ') entries..."
mkdir -p "$OUT_DIR"
XZ_OPT="-T0 -9" tar -C "$PREFIX" -cJf "$OUT" -T "$LIST"

echo
echo "==> Wrote $OUT"
echo "    size:   $(du -h "$OUT" | cut -f1)"
echo "    sha256: $(shasum -a 256 "$OUT" | cut -d' ' -f1)"
