# shellcheck shell=bash
# The settings build-wine.sh, bundle-wine.sh, build-fex.sh, build-mesa.sh,
# build-dxmt.sh, build-vkd3d-proton.sh and the CI scripts in ci/ share, and
# the helpers they use.
# Source it with SCRIPT_DIR set to bin/ of this repository; it sets
# everything as it is sourced. REPO_DIR is the repository itself, PINS_DIR
# its pins/ (redist.env and the *-src.ref files).
#
# The build is a native arm64 Wine (aarch64, arm64ec and i386 PE) with FEX as
# the x86 emulator.
#
# Everything lives under ROOT, the directory that holds this repository: the
# sources (the Wine checkout in src/, FEX in src-fex/, Mesa in src-mesa/),
# downloads (cache/), every intermediate under build/, one directory per
# component, and the bundle in dist/wine. WINE_BUILD_ROOT overrides ROOT,
# for a checkout kept elsewhere (a worktree) that should use the same trees.
#
# A path set below as "${NAME:-default}" is overridden by an environment
# variable of the same name. MACOSX_DEPLOYMENT_TARGET may raise the floor but
# not lower it.
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PINS_DIR="$REPO_DIR/pins"
ROOT="${WINE_BUILD_ROOT:-$(cd "$REPO_DIR/.." && pwd)}"
# Where the build trees go by default, and where claim_tree adopts an
# unmarked one.
BUILD_TOP="$ROOT/build"

# macos_newer <a> <b>: succeed when macOS version <a> is newer than <b>.
# Major, minor and patch are compared as numbers and a missing part counts as
# 0, so 26.4 is newer than 15.0 and 15 is not newer than 15.0.
macos_newer() {
    local a1 a2 a3 b1 b2 b3
    IFS=. read -r a1 a2 a3 <<< "$1"
    IFS=. read -r b1 b2 b3 <<< "$2"
    [ $(( ${a1:-0} * 10000 + ${a2:-0} * 100 + ${a3:-0} )) -gt \
      $(( ${b1:-0} * 10000 + ${b2:-0} * 100 + ${b3:-0} )) ]
}

# The Wine source: upstream Wine with our series, a checkout of athei/wine.
WINE_SRC="${WINE_SRC:-$ROOT/src}"
BUILD_DIR="${BUILD_DIR:-$BUILD_TOP/wine}"
# What bundle-wine.sh writes <dest>/wine into without --dest.
BUNDLE_DEST="$ROOT/dist"
HOST_TRIPLE=aarch64-apple-darwin
WINE_ARCHS=arm64ec,aarch64,i386
# The arm64 Homebrew. Configure finds the libraries here and the bundle
# copies them from here.
DEPS_PREFIX=/opt/homebrew
DEPS_FORMULAE="freetype gnutls sdl2-compat sdl3 bison pkgconf"
# What the host tools of build-mesa.sh's first stage link, from the same
# prefix. A CI build installs the formulae of both lists, and the build tools,
# from pins/brew-formulae.
MESA_FORMULAE="llvm spirv-llvm-translator spirv-tools"
# Mesa's repository (upstream Mesa plus our topic commits, for its Vulkan
# driver KosmicKrisp), the local clone build-mesa.sh checks out mesa-src.ref
# in, its trees, and the Vulkan loader and driver as build-mesa.sh stages
# them for the bundle. Set ahead of the configure flags, which name
# MESA_DIST.
MESA_REPO="${MESA_REPO:-https://github.com/athei/mesa}"
MESA_SRC="${MESA_SRC:-$ROOT/src-mesa}"
MESA_BUILD_DIR="${MESA_BUILD_DIR:-$BUILD_TOP/mesa}"
MESA_DIST="${MESA_DIST:-$MESA_BUILD_DIR/dist}"
# WINE_BUILD_CCACHE: the absolute path of a ccache to run the compilers
# through. Unset, the default, no compiler goes through ccache. Set,
# WINE_CCACHE is that path, and the scripts run through it Wine's unix and
# PE compilers (ccache_bin_dir, which build-wine.sh puts ahead of PATH),
# Mesa's (its native files) and FEX's (CMake's compiler launcher). Each
# tree follows a change of it on the next run, without --clean. ccache
# takes CCACHE_DIR, CCACHE_MAXSIZE and its other settings from the
# environment, except two set here for every compile:
#  - CCACHE_BASEDIR is ROOT, so ccache hashes the paths under it relative to
#    it, and a tree in another place can use the same cache.
#  - CCACHE_COMPILERCHECK names the compilers by version: Apple's clang and
#    llvm-mingw's, by the first line of their --version. ccache's default is
#    the size and time of the file it runs, which for Apple's clang is the
#    /usr/bin shim that stays the same when Xcode changes, and for llvm-mingw
#    the wrapper script every target shares. ccache hashes the name it runs
#    as well, which tells llvm-mingw's targets apart, and
#    MACOSX_DEPLOYMENT_TARGET and DEVELOPER_DIR.
WINE_CCACHE="${WINE_BUILD_CCACHE:-}"
if [ -n "$WINE_CCACHE" ]; then
    case "$WINE_CCACHE" in
        /*) ;;
        *) echo "Error: WINE_BUILD_CCACHE=$WINE_CCACHE is not an absolute path"; exit 1 ;;
    esac
    if [ ! -x "$WINE_CCACHE" ]; then
        echo "Error: WINE_BUILD_CCACHE=$WINE_CCACHE is not an executable"
        exit 1
    fi
    export CCACHE_BASEDIR="$ROOT"
    CCACHE_COMPILERCHECK="string:cc=$(/usr/bin/clang --version 2>/dev/null | head -n 1)"
    CCACHE_COMPILERCHECK+=" mingw=$("${MINGW_DIR:-/opt/llvm-mingw}/bin/clang" --version 2>/dev/null | head -n 1)"
    export CCACHE_COMPILERCHECK
fi

# ccache_bin_dir <dir> <compiler>...: make <dir>, emptied first, a directory
# of links named <compiler> to WINE_CCACHE. Run as one of them, ccache
# compiles with the next program of that name on PATH, so a directory of
# them ahead of PATH puts ccache in front of those compilers while
# configure and the Makefiles keep naming them as they do without it: Wine's
# configure takes llvm-mingw's compilers in its MSVC mode only when it finds
# them on PATH itself, and in its mingw mode when <arch>_CC names them.
ccache_bin_dir() {
    local dir="$1" cc
    shift
    remove_tree "$dir"
    mkdir -p "$dir"
    for cc in "$@"; do
        ln -s "$WINE_CCACHE" "$dir/$cc"
    done
}
# Configure arguments on top of the allowlist in build-wine.sh: the
# toolchain and where the dependencies are. Tests are left out: with them,
# the build's `make` would build every Wine test, and the ones the bundle
# carries (GRAPHICS_TESTS) come from the link-library tree. macOS ships bison
# 2.3, too old for Wine. The include path goes into CPPFLAGS so configure
# keeps its default -g -O2 CFLAGS.
# Putting $DEPS_PREFIX first in both search paths keeps clang and ld from
# taking an x86_64 header or library from /usr/local, which they search by
# default. Ahead of it, $MESA_DIST/lib holds the Vulkan loader build-mesa.sh
# built, so configure's -lvulkan test links that one: it succeeds without
# Homebrew's vulkan-loader and does not link Homebrew's libvulkan.dylib where
# it is installed. The soname define is the bare file name either way; that
# the bundle carries this loader is the bundle step's doing. Mesa's EGL is
# found the same way, through the egl.pc build-mesa.sh stages in
# $MESA_DIST/lib/pkgconfig, ahead of Homebrew's search path.
CONFIGURE_TOOLCHAIN=(CC="clang -arch arm64"
                     --host="$HOST_TRIPLE"
                     --disable-tests
                     BISON="$DEPS_PREFIX/opt/bison/bin/bison"
                     PKG_CONFIG_PATH="$MESA_DIST/lib/pkgconfig:$DEPS_PREFIX/lib/pkgconfig"
                     CPPFLAGS="-I$DEPS_PREFIX/include"
                     LDFLAGS="-L$MESA_DIST/lib -L$DEPS_PREFIX/lib")
# Path prefixes no bundled Mach-O may still load from. An x86_64 library
# from /usr/local cannot load into an arm64 process, so a reference to it is
# as much a leak as one to the arm64 Homebrew.
LEAK_PREFIXES="/usr/local/ /opt/homebrew/"
# The floor every Mach-O is held to. The loader's cross-architecture
# entitlement needs macOS 26.4, so nothing in this bundle aims lower.
MACOS_FLOOR=26.4
if [ -n "$MACOSX_DEPLOYMENT_TARGET" ]; then
    if macos_newer "$MACOS_FLOOR" "$MACOSX_DEPLOYMENT_TARGET"; then
        echo "Error: MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET is below the floor $MACOS_FLOOR"
        exit 1
    fi
    MACOS_FLOOR="$MACOSX_DEPLOYMENT_TARGET"
fi
# Functions Wine's configure checks for that the macOS SDK declares, but
# that macOS only has from a release above the floor, as <function>:<macOS
# version>. configure finds them in the SDK, Wine calls them without an
# availability check, and so the linker weak-imports them and on an older
# macOS the call jumps to address 0 (pipe2 is what ntdll's server_pipe()
# calls first in every process). While the floor is below a function's
# version, configure is told the function is missing, and Wine uses the older
# calls it has for that case. The macOS 27 SDK declares pipe2 as available
# from macOS 27 on, above this floor; an older SDK has no pipe2, so there the
# override changes nothing.
FLOOR_NEWER_FUNCS="pipe2:27.0"
for floor_func in $FLOOR_NEWER_FUNCS; do
    if macos_newer "${floor_func#*:}" "$MACOS_FLOOR"; then
        CONFIGURE_TOOLCHAIN+=("ac_cv_func_${floor_func%%:*}=no")
    fi
done
unset floor_func
export MACOSX_DEPLOYMENT_TARGET="$MACOS_FLOOR"
UNIX_DIR=aarch64-unix
# An x64 process runs as ARM64EC, and Wine looks up its builtins in
# aarch64-windows only, so the 64-bit PE modules of every Direct3D tree go
# there too. They have to be ARM64X, so that native ARM64 programs can load
# them as well, and nothing in an aarch64-windows directory may be code an
# x64 process would not run natively (check_pe64_native).
PE64_DIR=aarch64-windows
RUST_TARGET=aarch64-apple-darwin
# The Direct3D trees, in the order a default-dir marker prefers them. Each
# name is a tree under lib/wine/dxgi or lib/wine/d3d9.
DXGI_IMPLS="dxmt wined3d"
D3D9_IMPLS="mtld3d wined3d"
# The link-library tree for the x86_64 PE archives and the graphics tests,
# and the Wine SDK build-wine.sh stages from it and the main build.
X86LIBS_BUILD_DIR="${X86LIBS_BUILD_DIR:-$BUILD_TOP/x86libs}"
WINE_SDK_DIR="${WINE_SDK_DIR:-$BUILD_TOP/sdk}"
# Wine's graphics conformance tests, by the directory under dlls/ whose
# tests/ they are. The Wine SDK and a full bundle carry each as
# lib/wine/tests/<pe-dir>/<name>_test.exe for both TEST_PE_DIRS, the x86
# code games run, so the bundle's Direct3D, OpenGL and Vulkan stack can be
# tested in place. A name with a :<pe-dir> suffix is built for that one only:
# Wine builds no 64-bit d3d8.dll (enable_d3d8 in its configure.ac), and so no
# 64-bit d3d8 test.
GRAPHICS_TESTS="ddraw d3d8:i386-windows d3d9 d3d10 d3d10_1 d3d10core d3d11 d3d12 dxgi d2d1 opengl32 vulkan-1"
TEST_PE_DIRS="i386-windows x86_64-windows"

# graphics_tests <pe-dir>: print the name of every test of GRAPHICS_TESTS
# that is built for <pe-dir>, one per line.
graphics_tests() {
    local t
    for t in $GRAPHICS_TESTS; do
        case "$t" in
            *:*) [ "${t#*:}" = "$1" ] || continue; t=${t%%:*} ;;
        esac
        echo "$t"
    done
}
# DXMT's repository (upstream DXMT plus our commits), which build-dxmt.sh
# clones into DXMT_BUILD_DIR and checks out dxmt-src.ref in, its trees, the
# LLVM libraries it links, and DXMT as build-dxmt.sh stages it for the
# bundle.
DXMT_REPO="${DXMT_REPO:-https://github.com/athei/dxmt}"
DXMT_BUILD_DIR="${DXMT_BUILD_DIR:-$BUILD_TOP/dxmt}"
DXMT_LLVM="${DXMT_LLVM:-$DXMT_BUILD_DIR/llvm15}"
DXMT_DIST="${DXMT_DIST:-$DXMT_BUILD_DIR/dist}"
# vkd3d-proton's repository (upstream vkd3d-proton plus our commits), which
# build-vkd3d-proton.sh clones into VKD3D_PROTON_BUILD_DIR and checks out
# vkd3d-proton-src.ref in, its trees, and its D3D12 DLLs as
# build-vkd3d-proton.sh stages them for the bundle.
VKD3D_PROTON_REPO="${VKD3D_PROTON_REPO:-https://github.com/athei/vkd3d-proton}"
VKD3D_PROTON_BUILD_DIR="${VKD3D_PROTON_BUILD_DIR:-$BUILD_TOP/vkd3d-proton}"
VKD3D_PROTON_DIST="${VKD3D_PROTON_DIST:-$VKD3D_PROTON_BUILD_DIR/dist}"
# FEX's repository, the local clone build-fex.sh checks out fex-src.ref in,
# its build trees, and FEX as build-fex.sh stages it for the bundle.
FEX_REPO="${FEX_REPO:-https://github.com/athei/FEX}"
FEX_SRC="${FEX_SRC:-$ROOT/src-fex}"
FEX_BUILD_DIR="${FEX_BUILD_DIR:-$BUILD_TOP/fex}"
FEX_DIST="${FEX_DIST:-$FEX_BUILD_DIR/dist}"
LOADER_PROFILE="${LOADER_PROFILE:-$REPO_DIR/signing/loader.provisionprofile}"
# The llvm-mingw targets the smoke test builds smoke/hello.c for and runs:
# native, and the two x86 ones FEX emulates.
SMOKE_PE_ARCHS="aarch64 x86_64 i686"
# Where `make install` puts the tree under DESTDIR. Wine's default --prefix,
# which configure is never given; the bundle step moves this directory to
# <dest>/wine.
INSTALL_PREFIX=/usr/local

# The file that marks a directory as a tree these scripts made and may
# delete. It holds the tree's name.
TREE_MARKER=.wine-build-tree

# canonical_path <dir>: <dir> with symlinks, . and .. resolved, or as given
# when it does not exist.
canonical_path() {
    if [ -d "$1" ]; then
        (cd "$1" && pwd -P)
    else
        echo "$1"
    fi
}

# absolute_path <path>: <path> as an absolute path without trailing slashes,
# its longest existing directory prefix with symlinks, . and .. resolved and
# the rest, which does not exist yet, appended one component at a time. A
# path relative to the working directory is taken from there.
absolute_path() {
    local path="$1" rest="" top
    case "$path" in
        /*) ;;
        *) path="$PWD/$path" ;;
    esac
    while [ ! -d "$path" ]; do
        rest="/$(basename "$path")$rest"
        path=$(dirname "$path")
    done
    top=$(cd "$path" && pwd -P)
    path="${top%/}$rest"
    echo "${path:-/}"
}

# claim_tree <dir> <name> [<wipe>]: make <dir> the tree <name>, emptied first
# when <wipe> is 1, and mark it. Every tree a script fills or deletes goes
# through here first, since an override can point one anywhere. Exit unless
# <dir> is missing, empty, or marked as that same tree. A directory with no
# marker is also taken when its parent is BUILD_TOP or another tree: the default
# places of trees made before there were markers. A git checkout never is.
claim_tree() {
    local dir="$1" mark="$2" found parent
    if [ -z "$dir" ]; then
        echo "Error: no directory for the tree '$mark'"
        exit 1
    elif [ -f "$dir/$TREE_MARKER" ]; then
        found=$(cat "$dir/$TREE_MARKER")
        if [ "$found" != "$mark" ]; then
            echo "Error: $dir is the tree '$found', not '$mark'"
            exit 1
        fi
    elif [ -e "$dir" ] && [ -n "$(ls -A "$dir")" ]; then
        parent=$(dirname "$(canonical_path "$dir")")
        if [ -e "$dir/.git" ] || { [ "$parent" != "$(canonical_path "$BUILD_TOP")" ] \
            && [ ! -f "$parent/$TREE_MARKER" ]; }; then
            echo "Error: $dir is not empty and has no $TREE_MARKER, so these scripts did not make it."
            echo "Refusing to use it; remove it or point the override elsewhere."
            exit 1
        fi
    fi
    if [ "${3:-0}" -eq 1 ]; then
        remove_tree "$dir"
    fi
    mkdir -p "$dir"
    echo "$mark" > "$dir/$TREE_MARKER"
}

# check_sdk_floor: exit unless the macOS SDK is at least MACOS_FLOOR. Code
# that needs a newer macOS than the SDK knows cannot be compiled against it.
check_sdk_floor() {
    local sdk
    sdk=$(xcrun --show-sdk-version 2>/dev/null) || {
        echo "Error: xcrun cannot report the macOS SDK version (install the Xcode command line tools)"
        exit 1
    }
    if macos_newer "$MACOS_FLOOR" "$sdk"; then
        echo "Error: the macOS SDK is $sdk, older than the floor $MACOS_FLOOR"
        exit 1
    fi
}

# remove_tree <path>...: rm -rf, tried again when it fails. macOS can write a
# .DS_Store into a directory (a Finder window showing it is enough) while rm
# is emptying it, and rm then stops with "Directory not empty"; a second
# attempt removes the latecomer. A third failure is real and exits.
remove_tree() {
    local try
    for try in 1 2; do
        if rm -rf "$@" 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    rm -rf "$@"
}

# pe_machine <file>: print the COFF Machine field of a PE image as four hex
# digits: 8664 for x86_64, 014c for i386, aa64 for ARM64 (an ARM64X image
# says aa64 too). The PE header starts at the offset stored at 0x3c, and the
# field follows its four-byte signature. od reads both little-endian, as the
# host is.
pe_machine() {
    local off
    off=$(od -An -tu4 -j60 -N4 "$1" | tr -d ' ')
    od -An -tx2 -j$((off + 4)) -N2 "$1" | tr -d ' '
}

# pe_is_arm64x <file>: succeed when the PE image is ARM64X: an ARM64 image
# (pe_machine aa64) whose load config points at ARM64EC (CHPE) metadata, so
# that a native ARM64 process loads its ARM64 half and an x64 process, which
# runs as ARM64EC, its ARM64EC half. llvm-readobj names the format of such an
# image COFF-ARM64X, and only when it found that metadata; a plain ARM64
# image is COFF-ARM64. It comes from llvm-mingw (MINGW_DIR, as the scripts
# set it). A file it cannot read exits instead of counting as "not ARM64X",
# which would silently pick the x64-only path, so call this directly, not in
# a command substitution, where the exit would only end the subshell.
pe_is_arm64x() {
    local readobj="${MINGW_DIR:-/opt/llvm-mingw}/bin/llvm-readobj" out
    [ "$(pe_machine "$1")" = aa64 ] || return 1
    if ! out=$("$readobj" --coff-load-config "$1" 2>&1); then
        echo "Error: $readobj cannot read $1:"
        echo "$out"
        exit 1
    fi
    grep -qx "Format: COFF-ARM64X" <<< "$out"
}

# The plain ARM64 DLLs of PE64_DIR that hold code and still pass
# check_pe64_native: the host side of WoW64, which only a 32-bit process
# loads, into its native ARM64 half, and no x64 process ever does. wow64.dll
# and wow64win.dll are Wine's (built for aarch64 only), libwow64fex.dll is
# FEX's i386 emulator, and xtajit.dll the copy of it under the name Wine's
# wow64 loads.
PE64_WOW64_HOST="wow64.dll wow64win.dll libwow64fex.dll xtajit.dll"

# check_pe64_native <wine-dir>: succeed when an x64 process, which runs as
# ARM64EC and looks up its 64-bit modules in PE64_DIR, can load nothing from
# a PE64_DIR directory of the bundle at <wine-dir> (the default one and every
# Direct3D tree's) that would not run natively. Every real PE file there
# (placeholders, with "Wine placeholder DLL" at 0x40, are skipped, and so is
# every file that is not a PE image) must have an ARM64EC view: ARM64X
# (COFF-ARM64X, as pe_is_arm64x tells) or ARM64EC (COFF-ARM64EC, the AMD64
# machine with ARM64EC metadata in its load config). llvm-readobj names the
# format of each from its machine and load config. A plain ARM64 file
# (COFF-ARM64), which only a native ARM64 process can load, passes only when
# no x64 process loads it as code:
#  - a program (.exe, .com), which runs as its own native process;
#  - a file with no code: no section that holds code or is executable
#    (IMAGE_SCN_CNT_CODE, IMAGE_SCN_MEM_EXECUTE) and no entry point. Such a
#    file is only ever read for its data, as Wine's resource-only DLLs,
#    type libraries (.tlb) and themes (.msstyles) are;
#  - one of PE64_WOW64_HOST.
# Everything else fails, x86_64 code without an ARM64EC view (COFF-x86-64)
# above all, which an x64 process would run under FEX. Prints one line per
# file that fails and a summary when none does; needs llvm-readobj from
# llvm-mingw (MINGW_DIR).
#
# It fails as well when it finds no real PE file at all, and when find
# fails: a scan that read nothing would pass for a clean bundle. It runs in
# a subshell for the pipefail that tells a failed find.
check_pe64_native() (
    set -o pipefail
    readobj="${MINGW_DIR:-/opt/llvm-mingw}/bin/llvm-readobj"
    find "$1/lib/wine" -path "*/$PE64_DIR/*" -type f -print0 \
        | perl -0 -e '
            use strict;
            use warnings;
            my ($root, $pe64, $readobj, @host) = @ARGV;
            my %host = map { lc($_) => 1 } @host;
            my (%placeholder, %code, @real);
            while (my $f = <STDIN>) {
                chomp $f;
                open(my $h, "<", $f) or die "Error: cannot open $f: $!\n";
                binmode $h;
                my ($mz, $hdr, $opt, $sect);
                next unless read($h, $mz, 0x60) == 0x60 && substr($mz, 0, 2) eq "MZ";
                seek($h, unpack("V", substr($mz, 60, 4)), 0) or next;
                next unless read($h, $hdr, 24) == 24 && substr($hdr, 0, 4) eq "PE\0\0";
                if (substr($mz, 0x40, 20) eq "Wine placeholder DLL") {
                    $placeholder{$f} = 1;
                    next;
                }
                my $nsect = unpack("v", substr($hdr, 6, 2));
                my $optsize = unpack("v", substr($hdr, 20, 2));
                die "Error: $f has a truncated PE header\n"
                    unless $optsize >= 20 && read($h, $opt, $optsize) == $optsize;
                my $code = unpack("V", substr($opt, 16, 4)) != 0;
                for (1 .. $nsect) {
                    die "Error: $f has a truncated section table\n" unless read($h, $sect, 40) == 40;
                    $code = 1 if unpack("V", substr($sect, 36, 4)) & 0x20000020;
                }
                $code{$f} = $code;
                push @real, $f;
            }
            # One llvm-readobj per batch; it prints "File:" and the top-level
            # "Format:" for each file (a hybrid view follows, indented).
            my (%format, @todo);
            @todo = @real;
            while (my @batch = splice(@todo, 0, 64)) {
                open(my $p, "-|", $readobj, @batch) or die "Error: cannot run $readobj: $!\n";
                local $/ = "\n";
                my $cur;
                while (<$p>) {
                    if (/^File: (.*)$/) { $cur = $1; }
                    elsif (/^Format: (\S+)$/ && defined $cur) { $format{$cur} //= $1; }
                }
                close($p);
            }
            my (@bad, %n);
            for my $f (sort @real) {
                (my $rel = $f) =~ s{^\Q$root\E/}{};
                (my $base = lc $f) =~ s{.*/}{};
                my $fmt = $format{$f} // "";
                if ($fmt eq "COFF-ARM64X" || $fmt eq "COFF-ARM64EC") {
                    $n{$fmt}++;
                } elsif ($fmt eq "COFF-ARM64") {
                    if ($base =~ /\.(exe|com)$/) { $n{program}++; }
                    elsif (!$code{$f}) { $n{nocode}++; }
                    elsif ($host{$base}) { $n{host}++; }
                    else { push @bad, "$rel is plain ARM64 code (COFF-ARM64), which an x64 process cannot load"; }
                } elsif ($fmt eq "") {
                    push @bad, "$rel cannot be read by llvm-readobj";
                } else {
                    push @bad, "$rel is $fmt without an ARM64EC view, which an x64 process would not run natively";
                }
            }
            if (@bad) {
                print "  ERROR: $_\n" for @bad;
                exit 1;
            }
            if (!@real) {
                print "  ERROR: no PE file found in the $pe64 dirs under $root/lib/wine\n";
                exit 1;
            }
            printf "  %d PE files in the %s dirs run natively in an x64 process or are never loaded into one:\n"
                 . "    %d ARM64X, %d ARM64EC, plain ARM64: %d programs, %d without code, %d of the WoW64 host;"
                 . " %d placeholders skipped.\n",
                scalar(@real), $pe64, $n{"COFF-ARM64X"} // 0, $n{"COFF-ARM64EC"} // 0,
                $n{program} // 0, $n{nocode} // 0, $n{host} // 0, scalar(keys %placeholder);
        ' "$1" "$PE64_DIR" "$readobj" $PE64_WOW64_HOST
)

# wine_src_commit: print the commit WINE_SRC is at, with "-dirty" appended
# when tracked files differ from it, so a Wine SDK and what links against it
# can be matched to one source state.
wine_src_commit() {
    local commit
    commit=$(git -C "$WINE_SRC" rev-parse HEAD)
    if [ -n "$(git -C "$WINE_SRC" status --porcelain --untracked-files=no)" ]; then
        commit="$commit-dirty"
    fi
    echo "$commit"
}

# src_ref_commit <ref-file> <repo>: print the commit the ref in <ref-file>
# (a file in PINS_DIR, such as fex-src.ref) names in <repo>: the ref itself
# when it is a full commit hash, else the tag (peeled, for an annotated one)
# or branch of that name, preferring a tag as git does. Prints nothing when
# the ref cannot be resolved, also when <repo> wants credentials: git is not
# allowed to ask for them.
src_ref_commit() {
    local ref
    ref=$(tr -d '[:space:]' < "$PINS_DIR/$1")
    if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
        echo "$ref"
        return 0
    fi
    GIT_TERMINAL_PROMPT=0 git ls-remote "$2" "$ref" 2>/dev/null | awk -v ref="$ref" '
        $2 == "refs/tags/" ref "^{}" { peeled = $1 }
        $2 == "refs/tags/" ref { tag = $1 }
        $2 == "refs/heads/" ref { head = $1 }
        END { if (peeled != "") print peeled; else if (tag != "") print tag; else if (head != "") print head }'
}

# The staged dists. build-mesa.sh, build-fex.sh, build-dxmt.sh and
# build-vkd3d-proton.sh each stage what the bundle takes from them in a
# directory of its own (MESA_DIST, FEX_DIST, DXMT_DIST, VKD3D_PROTON_DIST)
# with two records: KEY, one line naming everything the dist was built from
# (dist_key), and COMMIT, the source commit, written last, so a dist without
# it is incomplete. Before it fetches anything, each script asks the
# repository what its ref names now (src_ref_commit) and builds nothing when
# its dist is complete and has the KEY it would write for that commit
# (skip_current_dist). --clean deletes the dist, so it always builds. With
# --print-key, each prints that KEY and exits instead (print_dist_key), and
# release.yml keys its cache of the dist on it.

# dist_key [--hash <file>]... <script> <input>...: print, on one line, the
# KEY <script> writes into its dist: the SHA-256 of <script>, of this file
# and of each --hash <file>, which together say how the dist and what it
# links against are built (options, flags, the floor), and each <input>: the
# source commit and what else the dist is built from that none of the files
# fixes, such as the version of a compiler or of a library a build tool
# links.
dist_key() {
    local files=() hash
    while [ "$1" = --hash ]; do
        files+=("$2")
        shift 2
    done
    files=("$1" "${files[@]}" "$SCRIPT_DIR/lib/profile.sh")
    shift
    hash=$(cat "${files[@]}" | shasum -a 256 | cut -d' ' -f1)
    echo "scripts=$hash $*"
}

# cc_version <compiler>: print the first line of `<compiler> --version`,
# which names its version, or nothing when it does not run.
cc_version() {
    "$1" --version 2>/dev/null | head -n 1
}

# mingw_key: print, for a KEY, which llvm-mingw MINGW_DIR holds: its clang's
# version and its release, as the .llvm-mingw-version file that
# bin/ci/llvm-mingw.sh writes names it. A release can change its headers and
# runtime without a new clang, so where that file is missing, as in a tree
# unpacked by hand, the hash of the mingw-w64 version header stands in.
mingw_key() {
    local release f
    release=$(cat "$MINGW_DIR/.llvm-mingw-version" 2>/dev/null) || release=""
    if [ -z "$release" ]; then
        for f in "$MINGW_DIR/include/_mingw_mac.h" "$MINGW_DIR/generic-w64-mingw32/include/_mingw_mac.h"; do
            if [ -f "$f" ]; then
                release="header-$(shasum -a 256 < "$f" | cut -d' ' -f1)"
                break
            fi
        done
    fi
    echo "mingw=$(cc_version "$MINGW_DIR/bin/clang") mingw-release=${release:-unknown}"
}

# sdk_key: print, for a KEY, the macOS SDK the host compiles against: its
# version and build, which change with Xcode as Apple's clang may not.
sdk_key() {
    echo "sdk=$(xcrun --show-sdk-version 2>/dev/null) sdk-build=$(xcrun --show-sdk-build-version 2>/dev/null)"
}

# print_dist_key <commit> <ref-file> <key-function>: with --print-key
# (PRINT_KEY=1), print the KEY <key-function> gives for <commit>, the commit
# <ref-file> resolved to, and exit; exit with an error when it did not
# resolve. Without it, do nothing.
print_dist_key() {
    [ "${PRINT_KEY:-0}" -eq 1 ] || return 0
    if [ -z "$1" ]; then
        echo "Error: cannot resolve $2 ($(tr -d '[:space:]' < "$PINS_DIR/$2"))" >&2
        exit 1
    fi
    "$3" "$1"
    exit 0
}

# skip_current_dist <dir> <name> <commit> <key-function>: exit, saying so,
# when <dir> holds a complete dist from <commit>, the commit the ref names
# now (its COMMIT), whose KEY is the one <key-function> gives for <commit>.
# An empty <commit>, a ref that did not resolve, never matches: the script
# then fetches the ref and builds.
skip_current_dist() {
    local key
    [ -n "$3" ] && [ -f "$1/COMMIT" ] || return 0
    key=$("$4" "$3")
    if [ "$(cat "$1/COMMIT")" != "$3" ] || [ "$(cat "$1/KEY" 2>/dev/null)" != "$key" ]; then
        echo "==> $2: $1 is not $3 with the KEY it would get now; building"
        return 0
    fi
    echo "==> $2 $3 is staged in $1 with the KEY it would get now; not building it"
    echo "    (--clean builds it again)"
    exit 0
}

# pinned_clone <url> <tag> <commit> <dir>: make <dir> a shallow clone of
# <tag> with its submodules, and exit unless the tag is at <commit>. An
# existing clone at another commit (a bumped pin) is replaced; it is the
# calling script's own scratch copy, never somebody's work tree. The
# submodules are brought to the recorded commits every time, so an
# interrupted earlier run cannot leave them missing.
pinned_clone() {
    local url="$1" tag="$2" commit="$3" dir="$4" head
    if [ -e "$dir/.git" ]; then
        head=$(git -C "$dir" rev-parse HEAD)
        if [ "$head" != "$commit" ]; then
            echo "    $dir is at $head, not $commit; cloning again"
            remove_tree "$dir"
        fi
    fi
    if [ ! -e "$dir/.git" ]; then
        echo "    cloning $url $tag"
        git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" "$url" "$dir"
        head=$(git -C "$dir" rev-parse HEAD)
        if [ "$head" != "$commit" ]; then
            echo "Error: $url $tag is at $head, redist.env pins $commit"
            exit 1
        fi
    fi
    git -C "$dir" submodule update --quiet --init --recursive --depth 1
}

# check_deps_formulae: exit unless every formula in DEPS_FORMULAE is
# installed in DEPS_PREFIX.
check_deps_formulae() {
    local f missing=""
    for f in $DEPS_FORMULAE; do
        [ -d "$DEPS_PREFIX/opt/$f" ] || missing="$missing $f"
    done
    if [ -n "$missing" ]; then
        echo "Error: not installed in $DEPS_PREFIX:$missing"
        echo "Run: $DEPS_PREFIX/bin/brew install$missing"
        exit 1
    fi
}
