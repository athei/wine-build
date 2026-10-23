#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# ROOT, the layout, the paths and the floor (MACOS_FLOOR, the deployment
# target build-wine.sh builds with, which every Mach-O is checked against).
# shellcheck source=lib/profile.sh
. "$SCRIPT_DIR/lib/profile.sh"
CACHE_DIR="${CACHE_DIR:-$ROOT/cache}"
MINGW_DIR="${MINGW_DIR:-/opt/llvm-mingw}"

# The pins of every third-party input (MTLD3D_URL/MTLD3D_SHA256 etc.).
# shellcheck source=../pins/redist.env
. "$PINS_DIR/redist.env"
DIST_DIR=""
RUNTIME_ONLY=0
COMPATDB_ONLY=0
STRICT_FLOOR=0
WITH_SYMBOLS=0
ASSUME_YES=0
# Whether wine.app gets a secure timestamp, which needs Apple's timestamp
# server. LOADER_TIMESTAMP=0 signs without one, for an offline local build;
# such a bundle cannot be notarized.
LOADER_TIMESTAMP="${LOADER_TIMESTAMP:-1}"
case "$LOADER_TIMESTAMP" in
    0|1) ;;
    *) echo "Error: LOADER_TIMESTAMP must be 0 or 1, not '$LOADER_TIMESTAMP'"; exit 1 ;;
esac

# `make install` may rebuild any stale targets, including PE modules that need mingw.
if [ -d "$MINGW_DIR/bin" ]; then
    export PATH="$PATH:$MINGW_DIR/bin"
fi

usage() {
    echo "Usage: $0 [--dest <dir>] [--runtime-only] [--compatdb-only] [--strict-floor] [--symbols] [--yes]"
    exit 1
}

# --dest names the directory the bundle goes into as <dir>/wine; without it,
# its place in the layout (BUNDLE_DEST in profile.sh). --compatdb-only
# replaces compatdb.so in the bundle already at <dir>/wine and leaves
# everything else alone. --runtime-only is accepted alongside it and ignored,
# since it only affects what a full bundle installs. --strict-floor turns a
# Mach-O that needs a newer macOS than MACOS_FLOOR into an error instead of a
# warning, for a CI or release build. The bundled libraries are Homebrew's
# bottles, which carry the minos of the macOS they were poured for, so they
# meet the floor only on a host of the floor's major version, where such a
# build has to run (docs/arm64.md). A local build on a newer macOS gets
# newer bottles and is not distributed, so a warning is enough there.
# --symbols keeps the PE files as they were before Step 4e stripped them in
# <dir>/wine-symbols. --yes deletes an existing bundle at <dir>/wine without
# asking first, for a run nobody watches.
while [ $# -gt 0 ]; do
    case "$1" in
        --dest) [ $# -ge 2 ] || usage; DIST_DIR="$2"; shift 2 ;;
        --runtime-only) RUNTIME_ONLY=1; shift ;;
        --compatdb-only) COMPATDB_ONLY=1; shift ;;
        --strict-floor) STRICT_FLOOR=1; shift ;;
        --symbols) WITH_SYMBOLS=1; shift ;;
        --yes) ASSUME_YES=1; shift ;;
        *) usage ;;
    esac
done

if [ -z "$DIST_DIR" ]; then
    DIST_DIR="$BUNDLE_DEST"
fi
# One spelling of the directory for every path built from it. The host EGL
# check compares the paths dyld reports for the libraries it loaded, which
# have symlinks resolved and no doubled slashes, with paths under WINE_DIR,
# so a --dest of ".../Resources/" (".../Resources//wine") or one through a
# symlink would fail it. Step 1 also runs make in BUILD_DIR, where a
# relative --dest would name another directory.
DIST_DIR=$(absolute_path "$DIST_DIR")

WINE_DIR="$DIST_DIR/wine"
# The PE files' symbols (Step 4e, with --symbols), next to the bundle and
# never in it.
SYMBOLS_DIR="$DIST_DIR/wine-symbols"
unixdir="$WINE_DIR/lib/wine/$UNIX_DIR"
COMPATDB_BUILD="$BUILD_DIR/compatdb/$RUST_TARGET/release/libcompatdb.dylib"

TMP_DIR=$(mktemp -d)
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# in_list <word> <list>: succeed when <word> is one of the space-separated
# words in <list>.
in_list() {
    case " $2 " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

# family_impls <family>: print the trees of <family> (dxgi or d3d9), in the
# order a default-dir marker prefers them (DXGI_IMPLS or D3D9_IMPLS).
family_impls() {
    if [ "$1" = dxgi ]; then echo "$DXGI_IMPLS"; else echo "$D3D9_IMPLS"; fi
}

# family_dlls <family> <arch-dir>: print the name, without .dll, of every DLL
# that a tree of <family> in the bundle has in <arch-dir>, once each, sorted:
# the names the default dir holds markers for.
family_dlls() {
    local impl f
    for impl in $(family_impls "$1"); do
        for f in "$WINE_DIR/lib/wine/$1/$impl/$2"/*.dll; do
            if [ -f "$f" ]; then basename "$f" .dll; fi
        done
    done | sort -u
}

# check_trees_arm64x: exit unless every 64-bit DLL of every Direct3D tree in
# the bundle is ARM64X (pe_is_arm64x), naming each one that is not.
# compatdb.so gives every arch, native ARM64 included, either tree of each
# family, and one default-dir marker serves every tree of a family, so every
# 64-bit name gets a hybrid marker (Step 4, the markers), which x64 and
# native ARM64 processes both accept, and only an ARM64X module behind it
# serves both. An x86_64 or ARM64EC-only build would serve x64 processes
# only. Exits, through pe_is_arm64x, on a DLL llvm-readobj cannot read.
check_trees_arm64x() {
    local family impl f bad=0
    for family in dxgi d3d9; do
        for impl in $(family_impls "$family"); do
            for f in "$WINE_DIR/lib/wine/$family/$impl/$PE64_DIR"/*.dll; do
                [ -f "$f" ] || continue
                if ! pe_is_arm64x "$f"; then
                    echo "  ERROR: ${f#"$WINE_DIR"/} is not ARM64X (PE machine $(pe_machine "$f"))"
                    bad=1
                fi
            done
        done
    done
    if [ "$bad" -ne 0 ]; then
        echo "Error: every 64-bit DLL of a Direct3D tree has to be ARM64X"
        exit 1
    fi
}

# Timing. time_mark <label> ends the interval of the previous mark and starts
# one for <label>; print_timings lists them all, in order, at the end. Wall
# time in milliseconds, through perl since bash 3.2 has no subsecond clock.
TIMINGS=()
TIMING_LABEL=""
TIMING_START=0
now_ms() {
    perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'
}
time_mark() {
    local now
    now=$(now_ms)
    if [ -n "$TIMING_LABEL" ]; then
        TIMINGS+=("$((now - TIMING_START))|$TIMING_LABEL")
    fi
    TIMING_LABEL="$1"
    TIMING_START=$now
}
print_timings() {
    local entry total=0
    time_mark ""
    echo "==> Time per step"
    for entry in "${TIMINGS[@]}"; do
        printf '  %8.1fs  %s\n' "$(echo "${entry%%|*}" | awk '{print $1 / 1000}')" "${entry#*|}"
        total=$((total + ${entry%%|*}))
    done
    printf '  %8.1fs  total\n' "$(echo "$total" | awk '{print $1 / 1000}')"
}

# fetch <url> <sha256> [name]: download an artifact into $CACHE_DIR, or reuse
# the cached copy when its checksum still matches the pin. Prints the local
# path. The cached file is named after the URL's last component unless <name>
# is given, which is for URLs that end in a generic name such as LICENSE.
# A cached copy that no longer matches is stale (a bump that kept the file
# name, as mtld3d.tar.xz does) and is replaced. A fresh download that does
# not match is an error, not a retry: either the pin in redist.env is wrong
# or the download is, and both need a human. Downloads land in a .part file
# first, so an interrupted run never leaves a plausible-looking file behind.
fetch() {
    local url="$1" want="$2" name="${3:-}"
    local target got
    [ -n "$name" ] || name=$(basename "$url")
    target="$CACHE_DIR/$name"
    if [ -f "$target" ]; then
        got=$(shasum -a 256 "$target" | cut -d' ' -f1)
        if [ "$got" = "$want" ]; then
            echo "    $name (cached)" >&2
            echo "$target"
            return 0
        fi
        echo "    $name: cached copy does not match redist.env, re-downloading" >&2
        rm -f "$target"
    fi
    echo "    $name (downloading)" >&2
    mkdir -p "$CACHE_DIR"
    curl -fsSL --retry 3 -o "$target.part" "$url"
    got=$(shasum -a 256 "$target.part" | cut -d' ' -f1)
    if [ "$got" != "$want" ]; then
        rm -f "$target.part"
        echo "Error: $name checksum mismatch" >&2
        echo "  expected $want" >&2
        echo "  got      $got" >&2
        echo "  from     $url" >&2
        return 1
    fi
    mv "$target.part" "$target"
    echo "$target"
}

# pe_scan: read NUL-separated paths on stdin and print, for each that is a PE
# image, "<path>\t<symbol table offset>\t<symbol count>" from its COFF
# header, sorted by path. A PE image is an MZ file whose e_lfanew points at a
# PE signature, not only an MZ file: Wine's .fon fonts are MZ files with a
# 16-bit NE header. One perl process reads the headers of every file, rather
# than a few processes per file.
pe_scan() {
    perl -0 -ne '
        chomp;
        my $f = $_;
        open(my $h, "<", $f) or next;
        binmode $h;
        my ($mz, $coff);
        next unless read($h, $mz, 64) == 64 && substr($mz, 0, 2) eq "MZ";
        seek($h, unpack("V", substr($mz, 60, 4)), 0) or next;
        next unless read($h, $coff, 24) == 24 && substr($coff, 0, 4) eq "PE\0\0";
        my ($ptr, $count) = unpack("VV", substr($coff, 12, 8));
        print "$f\t$ptr\t$count\n";
    ' | LC_ALL=C sort
}

# strip_pe <rel>...: strip each PE file <rel> (a path in the bundle) in
# place, as Step 4e describes, keeping the unstripped copy in SYMBOLS_DIR
# with --symbols. Runs in parallel batches under xargs, so it reports
# instead of exiting: an error goes to $STRIP_ERRORS/<n> and leaves the file
# as it was. Prints the path of every file it changed.
strip_pe() {
    local rel f out
    for rel in "$@"; do
        f="$WINE_DIR/$rel"
        out="$STRIP_WORK/$(printf '%s' "$rel" | tr '/' '%')"
        if ! "$MINGW_DIR/bin/llvm-strip" --strip-all -o "$out" "$f" 2>"$out.err" \
            && ! drop_coff_symtab "$f" "$out"; then
            { echo "Error: cannot strip $rel:"; cat "$out.err"; } > "$STRIP_ERRORS/${out##*/}"
            rm -f "$out" "$out.err"
            continue
        fi
        if cmp -s "$f" "$out"; then
            rm -f "$out" "$out.err"
            continue
        fi
        if head -c 128 "$f" | grep -qa "Wine builtin DLL" \
            && ! head -c 128 "$out" | grep -qa "Wine builtin DLL"; then
            echo "Error: stripping $rel lost its builtin marker" > "$STRIP_ERRORS/${out##*/}"
            rm -f "$out" "$out.err"
            continue
        fi
        if [ "$WITH_SYMBOLS" -eq 1 ]; then
            if ! mkdir -p "$SYMBOLS_DIR/$(dirname "$rel")" || ! cp -p "$f" "$SYMBOLS_DIR/$rel"; then
                echo "Error: cannot keep the unstripped $rel in $SYMBOLS_DIR" > "$STRIP_ERRORS/${out##*/}"
                rm -f "$out" "$out.err"
                continue
            fi
        fi
        if ! cp "$out" "$f"; then
            echo "Error: cannot replace $rel with its stripped copy" > "$STRIP_ERRORS/${out##*/}"
            rm -f "$out" "$out.err"
            continue
        fi
        rm -f "$out" "$out.err"
        echo "$rel"
    done
}

# pe_debug_files <file>...: print each of the PE files that has .debug_*
# sections, and "!<file>" for one llvm-objdump cannot read. One llvm-objdump
# reads the whole batch; only when it fails is each file read on its own, to
# tell which one it was.
pe_debug_files() {
    local out f
    if out=$("$MINGW_DIR/bin/llvm-objdump" -h "$@" 2>&1); then
        awk '
            /:\tfile format / { cur = $0; sub(/:\tfile format .*/, "", cur); seen = 0; next }
            / \.debug_/ && !seen { print cur; seen = 1 }
        ' <<< "$out"
        return 0
    fi
    for f in "$@"; do
        if out=$("$MINGW_DIR/bin/llvm-objdump" -h "$f" 2>&1); then
            if grep -q ' \.debug_' <<< "$out"; then echo "$f"; fi
        else
            echo "!$f"
        fi
    done
}

# coff_symtab <pe-file>: print where the file's COFF symbol table starts,
# its symbol count and where the string table after it ends, as file
# offsets; "0 0 0" when the header points at no table.
coff_symtab() {
    local pe ptr count strings
    pe=$(od -An -tu4 -j60 -N4 "$1" | tr -d ' ')
    ptr=$(od -An -tu4 -j$((pe + 12)) -N4 "$1" | tr -d ' ')
    count=$(od -An -tu4 -j$((pe + 16)) -N4 "$1" | tr -d ' ')
    if [ "$ptr" -eq 0 ] && [ "$count" -eq 0 ]; then
        echo "0 0 0"
        return
    fi
    strings=$(od -An -tu4 -j$((ptr + count * 18)) -N4 "$1" | tr -d ' ')
    echo "$ptr $count $((ptr + count * 18 + ${strings:-0}))"
}

# drop_coff_symtab <pe-file> <out>: write <pe-file> to <out> without its COFF
# symbol table, by cutting the file where the table starts and clearing the
# header's pointer and count. Fails unless the table and its strings end the
# file and the file has no .debug_* sections, which would need llvm-strip.
drop_coff_symtab() {
    local pe ptr count end sections
    read -r ptr count end < <(coff_symtab "$1")
    [ "$ptr" -ne 0 ] && [ "$end" -eq "$(stat -f %z "$1")" ] || return 1
    sections=$("$MINGW_DIR/bin/llvm-objdump" -h "$1" 2>&1) || return 1
    if grep -q ' \.debug_' <<< "$sections"; then
        return 1
    fi
    pe=$(od -An -tu4 -j60 -N4 "$1" | tr -d ' ')
    head -c "$ptr" "$1" > "$2" || return 1
    printf '\0\0\0\0\0\0\0\0' | dd of="$2" bs=1 seek=$((pe + 12)) conv=notrunc 2>/dev/null
}

# The helpers below exit on failure instead of returning a status. Call them
# as plain statements, never inside `if` or before `||`: either would turn
# off set -e for everything they run.

# build_compatdb: build the compatdb/ crate and install it as
# $unixdir/compatdb.so. profile.sh exports MACOSX_DEPLOYMENT_TARGET, which
# cargo hands to rustc and which takes precedence over the same pin in
# compatdb/.cargo/config.toml; cargo only reads that file from the working
# directory upward, hence the subshell in the workspace all the same.
# --locked builds the versions Cargo.lock names, and fails at once when the
# file does not match Cargo.toml instead of rewriting it. The new file is
# copied next to the old one and renamed over it, so a Wine process that has
# the old library mapped keeps a valid mapping instead of a file that changes
# underneath it.
build_compatdb() {
    if ! command -v cargo >/dev/null; then
        echo "Error: cargo not found (compatdb.so needs a Rust toolchain with the"
        echo "$RUST_TARGET target: rustup target add $RUST_TARGET)"
        exit 1
    fi
    if command -v rustup >/dev/null \
        && ! rustup target list --installed | grep -x "$RUST_TARGET" >/dev/null; then
        echo "Error: the Rust target $RUST_TARGET is not installed"
        echo "(rustup target add $RUST_TARGET)"
        exit 1
    fi
    (cd "$REPO_DIR/compatdb" && CARGO_TARGET_DIR="$BUILD_DIR/compatdb" \
        cargo build --quiet --release --locked --manifest-path "$REPO_DIR/compatdb/Cargo.toml" \
            -p compatdb --target "$RUST_TARGET")
    echo "    $UNIX_DIR/compatdb.so"
    cp "$COMPATDB_BUILD" "$unixdir/compatdb.so.new"
    mv -f "$unixdir/compatdb.so.new" "$unixdir/compatdb.so"
}

# check_no_leaks <file>...: report every file whose load commands still
# reference one of LEAK_PREFIXES and set LEAKED=1. Paths that do not exist
# (a glob that matched nothing) are skipped. The caller resets LEAKED and
# acts on it.
check_no_leaks() {
    local f p
    for f in "$@"; do
        [ -e "$f" ] || continue
        for p in $LEAK_PREFIXES; do
            if otool -L "$f" 2>/dev/null | grep "$p" >/dev/null; then
                echo "  ERROR: $(basename "$f") still references $p"
                LEAKED=1
            fi
        done
    done
}

# rpath_entries <dylib>: print the LC_RPATH entries of <dylib>, one per line.
rpath_entries() {
    otool -l "$1" | awk '$1 == "cmd" { r = ($2 == "LC_RPATH") } r && $1 == "path" { print $2 }'
}

# dir_in_bundle <dir>: succeed when <dir> exists and lies inside WINE_DIR,
# with symlinks resolved on both sides.
dir_in_bundle() {
    local dir top
    dir=$(cd "$1" 2>/dev/null && pwd -P) || return 1
    top=$(cd "$WINE_DIR" && pwd -P)
    case "$dir/" in
        "$top"/*) return 0 ;;
    esac
    return 1
}

# rpath_dep_source <dep> <src>: print the file that the @rpath dependency
# <dep> of the library <src> names where <src> is installed, outside the
# bundle: the first <rpath>/<name> that exists for an LC_RPATH entry of
# <src>, with @loader_path read as the directory of <src>, first as it is
# named and then with its symlinks resolved, and otherwise
# DEPS_PREFIX/lib/<name>. An entry dyld cannot read here (@executable_path)
# is skipped. What it prints may not exist; the caller checks.
rpath_dep_source() {
    local name="${1#@rpath/}" src="$2" rp dir cand
    while IFS= read -r rp; do
        case "$rp" in
            @loader_path|@loader_path/*)
                for dir in "$(dirname "$src")" "$(dirname "$(realpath "$src")")"; do
                    cand="$dir${rp#@loader_path}/$name"
                    if [ -f "$cand" ]; then echo "$cand"; return; fi
                done
                ;;
            /*)
                if [ -f "$rp/$name" ]; then echo "$rp/$name"; return; fi
                ;;
        esac
    done < <(rpath_entries "$src")
    echo "$DEPS_PREFIX/lib/$name"
}

# check_rpath_deps <dylib>...: report every @rpath dependency of the dylibs
# in lib/external that does not resolve inside the bundle through one of the
# dylib's own LC_RPATH entries, and set LEAKED=1. Step 3 rewrites each one
# it copies to @loader_path, so any left over would be resolved by dyld
# against whatever the host has, or not at all.
check_rpath_deps() {
    local f dep name rp dir found
    for f in "$@"; do
        [ -e "$f" ] || continue
        for dep in $(otool -L "$f" | tail -n +3 | awk '{print $1}'); do
            case "$dep" in
                @rpath/*) ;;
                *) continue ;;
            esac
            name="${dep#@rpath/}"
            found=0
            while IFS= read -r rp; do
                case "$rp" in
                    @loader_path|@loader_path/*)
                        dir="$(dirname "$f")${rp#@loader_path}"
                        if dir_in_bundle "$dir" && [ -f "$dir/$name" ]; then
                            found=1
                            break
                        fi
                        ;;
                esac
            done < <(rpath_entries "$f")
            if [ "$found" -eq 0 ]; then
                echo "  ERROR: $(basename "$f") loads $dep, which no LC_RPATH entry of it resolves inside the bundle"
                LEAKED=1
            fi
        done
    done
}

# check_dylibs_load <dylib>...: dlopen each dylib, in a process of its own
# with no DYLD_* variable set, so that dyld resolves its dependencies from
# the bundle as Wine's modules do, and exit naming every one that does not
# load. A missing dependency otherwise only shows when Wine tries the
# library at run time, and Wine falls back without it (no FreeType, for
# one). The program comes from smoke/dlopen.c.
check_dylibs_load() {
    local f bad=0
    xcrun clang -O2 -o "$TMP_DIR/dlopen" "$REPO_DIR/smoke/dlopen.c"
    for f in "$@"; do
        if ! env -u DYLD_LIBRARY_PATH -u DYLD_FALLBACK_LIBRARY_PATH \
                -u DYLD_FRAMEWORK_PATH -u DYLD_FALLBACK_FRAMEWORK_PATH \
                -u DYLD_INSERT_LIBRARIES "$TMP_DIR/dlopen" "$f"; then
            bad=1
        fi
    done
    if [ "$bad" -ne 0 ]; then
        echo "Error: bundled libraries do not load; the bundle is not self-contained"
        exit 1
    fi
}

# check_minos <path>...: report every Mach-O under the paths whose minos is
# newer than MACOS_FLOOR, then exit with --strict-floor or warn without it.
# This looks at executables, .dylib and .so files, and skips files with no
# LC_BUILD_VERSION (not Mach-O, or too old to have one). For a universal file
# the newest slice counts. If no file had a minos at all, nothing was
# checked, which is an error with or without --strict-floor.
check_minos() {
    local f rel minos bad=0 checked=0
    if ! command -v otool >/dev/null; then
        echo "Error: otool not found (it comes with the Xcode command line tools)"
        exit 1
    fi
    while IFS= read -r f; do
        rel=${f#"$WINE_DIR"/}
        minos=$(otool -arch all -l "$f" 2>/dev/null | awk '
            $1 == "cmd" && $2 == "LC_BUILD_VERSION" { v = 1 }
            v && $1 == "minos" {
                split($2, p, ".")
                k = p[1] * 10000 + p[2] * 100 + p[3]
                if (k > max) { max = k; s = $2 }
                v = 0
            }
            END { if (s != "") print s }')
        [ -n "$minos" ] || continue
        checked=$((checked + 1))
        if macos_newer "$minos" "$MACOS_FLOOR"; then
            echo "  too new: minos $minos, floor $MACOS_FLOOR  $rel"
            bad=1
        fi
    done < <(find "$@" -type f \( -perm +111 -o -name '*.dylib' -o -name '*.so' \))
    if [ "$checked" -eq 0 ]; then
        echo "Error: no Mach-O with an LC_BUILD_VERSION found under $*"
        echo "(otool -l printed no minos for any file, so nothing was checked)"
        exit 1
    fi
    if [ "$bad" -eq 0 ]; then
        echo "  $checked Mach-O files meet the floor (macOS $MACOS_FLOOR)."
        return 0
    fi
    if [ "$STRICT_FLOOR" -eq 1 ]; then
        echo "Error: the above need a newer macOS than the floor"
        exit 1
    fi
    echo "  WARNING: the above need a newer macOS than the floor and will not"
    echo "  load on older systems (--strict-floor makes this an error)"
}

# check_floor_newer_imports: exit if a unix module, the loader or wineserver
# imports a function of FLOOR_NEWER_FUNCS (profile.sh) while the floor is
# below that function's version. profile.sh keeps such functions from
# configure, but a build tree configured before that, or one whose configure
# ran without the override, still calls them, weak-imported, and minos does
# not show it. The unix modules of the default dir (DXMT's winemetal.so
# among them, which the dxmt tree links to) and of the d3d9 trees are
# checked. A path that resolves to a file already checked (the loader's
# symlinks) is skipped. A module that checks availability before it calls
# the function would be flagged as well, although it is safe; none in the
# bundle does that today.
check_floor_newer_imports() {
    local func name f real rel syms seen checked=0 bad=0 files=()
    if ! command -v nm >/dev/null; then
        echo "Error: nm not found (it comes with the Xcode command line tools)"
        exit 1
    fi
    files=("$WINE_DIR/bin/wine" "$WINE_DIR/bin/wineserver" "$unixdir/wine"
           "$unixdir"/*.so
           "$WINE_DIR"/lib/wine/d3d9/*/"$UNIX_DIR"/*.so)
    for func in $FLOOR_NEWER_FUNCS; do
        macos_newer "${func#*:}" "$MACOS_FLOOR" || continue
        checked=$((checked + 1))
        name=${func%%:*}
        seen=$'\n'
        for f in "${files[@]}"; do
            [ -e "$f" ] || continue
            real=$(perl -MCwd=abs_path -e 'print abs_path(shift)' "$f")
            case "$seen" in *$'\n'"$real"$'\n'*) continue ;; esac
            seen+="$real"$'\n'
            rel=${f#"$WINE_DIR"/}
            syms=$(nm -u "$f" 2>"$TMP_DIR/nm.err") || {
                echo "Error: nm cannot read $rel:"
                cat "$TMP_DIR/nm.err"
                exit 1
            }
            if grep -qx "_$name" <<< "$syms"; then
                echo "  ERROR: $rel imports $name, a function newer than the floor"
                echo "    (macOS has it from ${func#*:} on, the floor is $MACOS_FLOOR)."
                echo "    $(floor_import_hint "$rel")"
                bad=1
            fi
        done
    done
    if [ "$checked" -eq 0 ]; then
        echo "  No function of FLOOR_NEWER_FUNCS is newer than the floor $MACOS_FLOOR; nothing to check."
        return 0
    fi
    if [ "$bad" -ne 0 ]; then
        echo "Error: the modules above import functions newer than the floor"
        exit 1
    fi
    echo "  No module imports a function of FLOOR_NEWER_FUNCS newer than the floor."
}

# floor_import_hint <rel>: what to do about the module <rel> (a path in the
# bundle) importing a function newer than the floor, by where it comes from.
floor_import_hint() {
    case "$1" in
        lib/wine/d3d9/*)
            echo "It comes from the mtld3d release pinned in redist.env, which needs the fix." ;;
        */compatdb.so)
            echo "It is compatdb.so, which this script builds from compatdb/; fix the crate." ;;
        */winemetal.so)
            echo "It is DXMT's, built by build-dxmt.sh; fix DXMT or how it is built." ;;
        */libwow64fex.so|*/libarm64ecfex.so)
            echo "It is FEX's, built by build-fex.sh; fix FEX or how it is built." ;;
        *)
            echo "It comes from the Wine build, which configure set up without the"
            echo "    FLOOR_NEWER_FUNCS overrides: run build-wine.sh with --clean." ;;
    esac
}

# run_limited <seconds> <log> <command>...: run the command with its output in
# <log>, and stop it with SIGALRM after <seconds>; the alarm survives exec,
# so the command may start with env. Sets RUN_STATUS to its exit status; 142
# (128 + SIGALRM) means the alarm fired. perl, because macOS has no
# timeout(1).
run_limited() {
    local secs="$1" log="$2"
    shift 2
    RUN_STATUS=0
    perl -e 'alarm shift; exec @ARGV or die "exec: $!\n"' "$secs" "$@" >"$log" 2>&1 \
        || RUN_STATUS=$?
}

# check_hybrid_markers: exit unless the default dir's marker of every 64-bit
# name a Direct3D tree supplies is a hybrid one. A native ARM64 process
# rejects an AMD64 placeholder (docs/arm64.md, Limitations), and compatdb.so
# gives such a process the dxmt and mtld3d trees by default, so with an AMD64
# marker it could not load that name. A bundle from before the dxmt or
# mtld3d tree was ARM64X has such markers; --compatdb-only runs this before
# it replaces compatdb.so, so it leaves such a bundle as it was, and the
# smoke test runs it first. The markers and not the trees are read, since a
# tree can change after the bundle step (a development install of mtld3d)
# without its marker following.
check_hybrid_markers() {
    local family dll f bad=0
    for family in dxgi d3d9; do
        for dll in $(family_dlls "$family" "$PE64_DIR"); do
            f="$WINE_DIR/lib/wine/$PE64_DIR/$dll.dll"
            if ! pe_is_arm64x "$f"; then
                echo "Error: the marker $PE64_DIR/$dll.dll is not a hybrid one (PE machine $(pe_machine "$f")),"
                echo "  so a native ARM64 program cannot load $dll.dll from any $family tree"
                bad=1
            fi
        done
    done
    if [ "$bad" -ne 0 ]; then
        echo "This bundle predates ARM64X builds of every Direct3D tree; bundle the"
        echo "whole build instead of using --compatdb-only."
        exit 1
    fi
}

# check_rules_read <label> <log>: exit unless compatdb.so read the
# WINE_COMPATDB rules of the run <label> logged in <log> without a warning.
# It ignores a field it cannot read and applies the rest of the record, so a
# smoke rule with a key or value it does not know would otherwise still run.
check_rules_read() {
    if grep -q "compatdb: .*warning:" "$2"; then
        echo "Error: compatdb.so could not read every WINE_COMPATDB rule of $1"
        grep "compatdb: .*warning:" "$2"
        smoke_stop
        exit 1
    fi
}

# check_default_trees <log>: exit unless compatdb.so reported in <log> the
# tree the built-in dxmt and mtld3d rules give every process, the first of
# each family's list in profile.sh, which is the same for every arch. The
# "(from ...)" lines only appear once it found and prepended them.
check_default_trees() {
    local want dxgi_want d3d9_want
    dxgi_want="dxgi = ${DXGI_IMPLS%% *} (from"
    d3d9_want="d3d9 = ${D3D9_IMPLS%% *} (from"
    for want in "$dxgi_want" "$d3d9_want"; do
        if ! grep -q "compatdb: .*$want" "$1"; then
            echo "Error: compatdb.so did not report '$want'"
            grep "compatdb:" "$1" || echo "  (no compatdb lines at all)"
            exit 1
        fi
    done
    echo "  compatdb.so loads and finds its trees."
}

# smoke_test: run the bundled wine through the signed loader and check that
# native, x86_64 and i386 programs run, the last two under FEX.
# Every run has a time limit, since an emulator problem tends to show as a
# hang rather than an error. The caller's WINE_COMPATDB and WINE_D3D_CONFIG
# and every WINEMSYNC*, FEX_*, VK_*, VKD3D_*, MESA_*, MTL_* and METAL_*
# variable are dropped so that the built-in rules and the defaults of Wine,
# FEX, the Vulkan loader, vkd3d-proton, KosmicKrisp and Metal decide; only
# vkd3d-proton's pipeline cache is moved into the prefix.
# The checks that need a Vulkan device change on a Mac without a Metal 4 GPU
# (metal4_probe), and the ones that need an OpenGL context on a Mac without
# an accelerated OpenGL renderer (gl_probe). Each probe decides only its own
# checks.
smoke_test() {
    local version log arch cc exe marker markers var dlls
    local wine_env=(env -u WINE_COMPATDB -u WINE_D3D_CONFIG)
    for var in $(compgen -e | grep -E '^(WINEMSYNC|FEX_|VK_|VKD3D_|MESA_|MTL_|METAL_)'); do
        wine_env+=(-u "$var")
    done
    wine_env+=(WINEPREFIX="$TMP_DIR/prefix" WINEDLLOVERRIDES="mscoree,mshtml=" WINEDEBUG=-all)
    # vkd3d-proton writes its pipeline cache into the working directory
    # unless told otherwise, which would leave a vkd3d-proton.cache in the
    # caller's directory (or BUILD_DIR, where a full bundle runs this). The
    # prefix goes away with TMP_DIR. vkd3d-proton maps a unix path to Z:.
    wine_env+=(VKD3D_SHADER_CACHE_PATH="$TMP_DIR/prefix")
    # Before any Wine process runs, so a failure leaves no wineserver behind.
    check_hybrid_markers
    version=$("$WINE_DIR/bin/wine" --version) || {
        echo "Error: bundled wine failed to run"
        exit 1
    }
    echo "  Testing: $version"
    metal4_probe
    if [ "$METAL4" -eq 1 ]; then
        echo "  Metal 4 GPU for KosmicKrisp: $METAL_DEVICES"
    else
        echo "  No Metal 4 GPU ($METAL_DEVICES): skipping the checks that need a"
        echo "  KosmicKrisp device. vulkan.exe and d3d12.exe have to find the driver and no"
        echo "  GPU instead, and wined3d.exe does not run with wined3d on Vulkan."
    fi
    gl_probe
    bundle_egl
    if [ "$BUNDLE_EGL" -eq 0 ]; then
        echo "  This bundle has no EGL: OpenGL is Apple's only."
    fi
    # compatdb's built-in opengl-egl rule asks winemac.drv for Mesa's EGL,
    # which gives no OpenGL without Zink. There, the runs that need OpenGL
    # give their program a WINE_COMPATDB rule with opengl=cgl, which wins
    # over the built-in rule for that program, and expect Apple's renderer
    # (GL_SETTING, which check_wined3d_device adds to its programs' rules;
    # check_wgl_runs chooses for itself).
    GL_SETTING=""
    if [ "$ZINK_GL" -eq 1 ]; then
        echo "  OpenGL runs on Zink, through compatdb's opengl=egl."
    else
        GL_SETTING=";opengl=cgl"
        echo "  No Zink: with compatdb's opengl=egl wgl.exe must get no OpenGL, and the runs"
        echo "  that need OpenGL get a rule with opengl=cgl for Apple's."
    fi
    if [ "$ACCEL_GL" -eq 1 ]; then
        echo "  Accelerated Apple OpenGL renderer for winemac.drv: $GL_RENDERERS"
    else
        echo "  No accelerated Apple OpenGL renderer ($GL_RENDERERS): wgl.exe does not run"
        echo "  with opengl=cgl."
        if [ "$ZINK_GL" -eq 0 ]; then
            echo "  wined3d.exe has to find no adapter on wined3d's default renderer instead of"
            echo "  creating a device there."
        fi
    fi
    # Outside Wine, so before the prefix boots.
    check_egl_host

    # wineboot creates the prefix here, so the limit is generous. The Mono
    # and Gecko installers are kept out so nothing pops a dialog.
    time_mark "smoke: prefix boot"
    echo "  Booting a throwaway prefix..."
    log="$TMP_DIR/smoke.log"
    run_limited 600 "$log" "${wine_env[@]}" "$WINE_DIR/bin/wine" cmd /c exit
    smoke_check "the prefix boot (cmd /c exit)" 600 "$log"
    # compatdb.so logs a block in every process; `wine --version` never loads
    # ntdll, so these lines are the first proof that the library loads.
    if ! grep -q "compatdb:" "$log"; then
        echo "Error: compatdb.so wrote no log lines while the prefix booted"
        cat "$log"
        smoke_stop
        exit 1
    fi
    # msync is on by default, and the caller's WINEMSYNC* variables are
    # dropped above. The wineserver the boot started writes "msync: up and
    # running." to stderr, whatever WINEDEBUG says, only once its launchd
    # service is registered and msync is on; when registration fails it
    # prints an "msync: error:" line and runs without msync. Its other
    # "msync: error:" lines are failures too, while the "msync: error
    # setting ..." lines (no colon) only report a thread scheduling policy
    # it could not set and are not. A bundle whose wineserver has no msync
    # at all can only be one from before it, which --compatdb-only may meet
    # and skips; a full bundle without it was built from a Wine source that
    # lacks it, which is an error.
    if [ "$COMPATDB_ONLY" -eq 1 ] && ! grep -qaF "msync: up and running." "$WINE_DIR/bin/wineserver"; then
        echo "  Skipping the msync check: this wineserver predates msync."
    elif ! grep -qF "msync: up and running." "$log" || grep -q "^msync: error:" "$log"; then
        echo "Error: the wineserver of the prefix boot did not start msync:"
        grep "msync" "$log" || echo "  (no msync lines at all)"
        smoke_stop
        exit 1
    else
        echo "  The wineserver runs msync."
    fi

    # A program that crashes would otherwise wait in winedbg's crash dialog
    # until the time limit, and look like a hang. Without the dialog winedbg
    # writes the backtrace to the log and the program exits at once.
    log="$TMP_DIR/crash-dialog.log"
    run_limited 120 "$log" "${wine_env[@]}" "$WINE_DIR/bin/wine" reg add \
        'HKCU\Software\Wine\WineDbg' /v ShowCrashDialog /t REG_DWORD /d 0 /f
    smoke_check "turning winedbg's crash dialog off (reg add)" 120 "$log"

    time_mark "smoke: i386 cmd.exe under FEX"
    echo "  Starting the i386 cmd.exe under FEX..."
    log="$TMP_DIR/wow64.log"
    run_limited 120 "$log" "${wine_env[@]}" "$WINE_DIR/bin/wine" 'C:\windows\syswow64\cmd.exe' /c exit
    smoke_check "the i386 cmd.exe" 120 "$log"

    # One console program per PE architecture in SMOKE_PE_ARCHS, built here so
    # the test does not depend on what the prefix happens to contain. Each
    # prints a marker naming the architecture it was compiled for, then loads
    # the DLLs it is given and says whether all of them loaded. Its compatdb
    # lines say which trees it got: the ones the built-in dxmt and mtld3d
    # rules give every arch (compatdb/src/builtin.rs). An x86
    # program loads dxgi.dll and d3d9.dll. A native ARM64 program also loads
    # winemetal.dll and mtld3d.dll, which only the dxmt and mtld3d trees
    # have, so the loads show that the ARM64 halves of DXMT's and mtld3d's
    # ARM64X DLLs came in through the hybrid placeholders of their names
    # (Step 4, the markers), which check_hybrid_markers has checked above.
    for arch in $SMOKE_PE_ARCHS; do
        cc="$MINGW_DIR/bin/$arch-w64-mingw32-clang"
        exe="$TMP_DIR/hello-$arch.exe"
        "$cc" -O2 -o "$exe" "$REPO_DIR/smoke/hello.c"
        if [ "$arch" != aarch64 ]; then
            dlls=(dxgi.dll d3d9.dll)
        else
            dlls=(dxgi.dll winemetal.dll d3d9.dll mtld3d.dll)
        fi
        time_mark "smoke: hello.exe $arch"
        echo "  Running hello.exe for $arch..."
        log="$TMP_DIR/hello-$arch.log"
        run_limited 120 "$log" "${wine_env[@]}" "$WINE_DIR/bin/wine" "$exe" "${dlls[@]}"
        smoke_check "hello.exe for $arch" 120 "$log"
        markers=("wine-build smoke test: hello from $arch"
                 "wine-build smoke test: $arch loads ${dlls[*]}")
        for marker in "${markers[@]}"; do
            if ! grep -q "$marker" "$log"; then
                echo "Error: hello.exe for $arch did not print '$marker'"
                cat "$log"
                smoke_stop
                exit 1
            fi
        done
        grep "wine-build smoke test: $arch " "$log" | sed 's/^/    /'
        check_default_trees "$log"
    done
    echo "  Loading each Direct3D tree's modules..."
    check_tree_loads x86_64 "${wine_env[@]}"
    check_tree_loads i686 "${wine_env[@]}"
    check_tree_loads aarch64 "${wine_env[@]}"
    # --compatdb-only has already refused a bundle without Vulkan
    # (check_vulkan_present), so every bundle that gets here has it.
    # OpenGL first: on an older bundle, which --compatdb-only can meet and
    # whose KosmicKrisp fails vulkan.exe, it still gets checked.
    check_wgl_runs "${wine_env[@]}"
    check_vulkan_runs "${wine_env[@]}"
    # A bundle from before vkd3d-proton has no D3D12, which --compatdb-only
    # may meet and skips, as it skips msync; a full bundle always has it.
    if [ "$COMPATDB_ONLY" -eq 1 ] && [ ! -f "$WINE_DIR/lib/wine/dxgi/dxmt/$PE64_DIR/d3d12.dll" ]; then
        echo "  Skipping the D3D12 check: this bundle predates vkd3d-proton."
    else
        check_d3d12_runs "${wine_env[@]}"
    fi
    check_wined3d_device "${wine_env[@]}"
    smoke_stop
    echo "  Programs for $SMOKE_PE_ARCHS run and load their Direct3D trees."
}

# check_vulkan_present: exit unless the bundle has the Vulkan loader,
# KosmicKrisp and its manifest, naming each one that is missing. compatdb.so
# does not disable vulkan-1, so in a bundle without Vulkan a game's own
# vulkan-1.dll would load and find no driver, and the smoke test's Vulkan
# checks need it anyway. --compatdb-only runs it before it builds anything,
# since it may meet a bundle from before Vulkan; a full bundle checks the
# same files in Step 5.
check_vulkan_present() {
    local f missing=0
    for f in share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json \
             lib/external/libvulkan.1.dylib lib/external/libvulkan_kosmickrisp.dylib; do
        if [ ! -e "$WINE_DIR/$f" ]; then
            echo "Error: $WINE_DIR/$f is missing"
            missing=1
        fi
    done
    if [ "$missing" -ne 0 ]; then
        echo "This bundle has no Vulkan. compatdb.so does not disable a"
        echo "game's own vulkan-1.dll, which would find no driver, and the smoke test"
        echo "needs Vulkan. Bundle the whole build instead of using --compatdb-only."
        exit 1
    fi
}

# check_wined3d_device <env-command>...: build smoke/wined3d.c for x86_64 and
# i686 and run it twice in the booted throwaway prefix, with the winediag
# channel on, on which wined3d reports a renderer it was told to use. The
# i686 program creates a Direct3D 8 device, which always goes through
# wined3d. Wine builds no 64-bit d3d8.dll ("configure: Disable d3d8.dll on
# 64-bit targets."), so the x86_64 program is built with SMOKE_D3D9 and
# creates a Direct3D 9 device instead, with a WINE_COMPATDB rule giving it
# the wined3d d3d9 tree in both runs, which compatdb.so must report in each,
# or the run would not go through wined3d. In the first run, where only that
# rule is added to the built-in ones, each program must create a device and
# wined3d must not report the Vulkan renderer: wined3d on Vulkan is opt-in,
# and <env-command> drops the caller's WINE_D3D_CONFIG. In the second the
# program's rule also sets wined3d=vulkan, as a rule for a game does, and
# wined3d must report the Vulkan renderer and the program create its device
# on it. wined3d does not fall back to OpenGL when its Vulkan adapter fails,
# so the second run is what shows the opt-in works. It needs a KosmicKrisp
# device, so on a Mac without a Metal 4 GPU (metal4_probe) only the first
# run happens. The first needs an OpenGL context, which winemac.drv gets
# from Zink with a Metal 4 GPU and a bundle with EGL (ZINK_GL, bundle_egl),
# through compatdb's opengl=egl, and otherwise only from an accelerated
# Apple renderer, for which smoke_test sets GL_SETTING to opengl=cgl, which
# goes into the program's rule. With neither (gl_probe) it must fail the
# way a missing renderer makes it fail instead (check_wined3d_no_gl). The
# second does not use OpenGL and still happens on a Mac with a Metal 4 GPU.
check_wined3d_device() {
    local arch exe log want api flags rule tree
    for arch in x86_64 i686; do
        exe="$TMP_DIR/wined3d-$arch.exe"
        rule="name=smoke;exe=$(basename "$exe")$GL_SETTING"
        # The compatdb line each run must show for the tree the program's
        # rule asks for; none for d3d8, which no tree decides.
        if [ "$arch" = x86_64 ]; then
            api=d3d9
            flags=(-DSMOKE_D3D9)
            rule+=";d3d9=wined3d"
            tree="compatdb: .*d3d9 = wined3d (from"
        else
            api=d3d8
            flags=()
            tree=""
        fi
        "$MINGW_DIR/bin/$arch-w64-mingw32-clang" -O2 "${flags[@]}" -o "$exe" "$REPO_DIR/smoke/wined3d.c"
        time_mark "smoke: wined3d.exe $arch ($api)"
        if [ "$ZINK_GL" -eq 0 ] && [ "$ACCEL_GL" -eq 0 ]; then
            check_wined3d_no_gl "$arch" "$api" "$exe" "$rule" "$tree" "$@"
        else
            echo "  Running wined3d.exe for $arch ($api) with the default renderer..."
            log="$TMP_DIR/wined3d-$arch.log"
            run_limited 120 "$log" "$@" WINEDEBUG=-all,err+winediag \
                WINE_COMPATDB="$rule" "$WINE_DIR/bin/wine" "$exe"
            smoke_check "wined3d.exe for $arch ($api)" 120 "$log"
            check_rules_read "wined3d.exe for $arch ($api)" "$log"
            if ! grep -q "wine-build smoke test: $arch $api device on " "$log" \
                || grep -q "err:winediag:.*Using the Vulkan renderer\." "$log"; then
                echo "Error: wined3d.exe for $arch did not create a $api device on wined3d's default renderer"
                cat "$log"
                smoke_stop
                exit 1
            fi
            if [ -n "$tree" ] && ! grep -q "$tree" "$log"; then
                echo "Error: compatdb.so did not give wined3d.exe for $arch the wined3d d3d9 tree"
                echo "its rule asks for (no '$tree' line), so the run proves nothing about wined3d"
                cat "$log"
                smoke_stop
                exit 1
            fi
            grep "wine-build smoke test: $arch " "$log" | sed 's/^/    /'
        fi
        # wined3d on Vulkan needs a KosmicKrisp device (metal4_probe).
        [ "$METAL4" -eq 1 ] || continue
        time_mark "smoke: wined3d.exe $arch ($api) on Vulkan"
        echo "  Running wined3d.exe for $arch ($api) with wined3d on Vulkan..."
        log="$TMP_DIR/wined3d-vulkan-$arch.log"
        run_limited 120 "$log" "$@" WINEDEBUG=-all,err+winediag \
            WINE_COMPATDB="$rule;wined3d=vulkan" "$WINE_DIR/bin/wine" "$exe"
        smoke_check "wined3d.exe for $arch ($api) with wined3d on Vulkan" 120 "$log"
        check_rules_read "wined3d.exe for $arch ($api) with wined3d on Vulkan" "$log"
        for want in "wine-build smoke test: $arch $api device on " \
                    "err:winediag:.*Using the Vulkan renderer\." ${tree:+"$tree"}; do
            if ! grep -q "$want" "$log"; then
                echo "Error: wined3d.exe for $arch ($api) with wined3d on Vulkan did not print '$want'"
                cat "$log"
                smoke_stop
                exit 1
            fi
        done
        grep "wine-build smoke test: $arch " "$log" | sed 's/^/    /'
    done
}

# check_wined3d_no_gl <arch> <api> <exe> <rules> <tree> <env-command>...:
# run the wined3d.exe <exe> for <arch> as check_wined3d_device's first run
# does, with the WINE_COMPATDB rules <rules>, on a Mac without an accelerated
# OpenGL renderer, with wined3d's errors and the OpenGL driver's errors and
# warnings in the log, and exit unless it failed as wined3d_no_gl describes,
# had FreeType, did not report the Vulkan renderer or a failure to load
# OpenGL (an error of macdrv_OpenGLInit), and, when <tree> is not empty, got
# the compatdb line <tree> for its wined3d tree. That still shows that the
# program's <api> DLL, wined3d, winemac.drv and Apple's OpenGL all load; only
# the accelerated renderer is missing. A failure prints the log without the
# driver's warnings about each GL function it did not find, which run to
# thousands of lines when its OpenGL does not start.
check_wined3d_no_gl() {
    local arch="$1" api="$2" exe="$3" rules="$4" tree="$5" log want
    shift 5
    echo "  Running wined3d.exe for $arch ($api), which must find no accelerated OpenGL renderer..."
    log="$TMP_DIR/wined3d-$arch.log"
    run_limited 120 "$log" "$@" WINEDEBUG=-all,err+winediag,err+wgl,warn+wgl,err+d3d \
        WINE_COMPATDB="$rules" "$WINE_DIR/bin/wine" "$exe"
    if [ "$RUN_STATUS" -eq 142 ]; then
        echo "Error: wined3d.exe for $arch ($api) did not exit within 120 seconds"
    elif [ "$RUN_STATUS" -eq 0 ]; then
        echo "Error: wined3d.exe for $arch created a $api device, though smoke/opengl.m found no"
        echo "accelerated OpenGL renderer"
    elif grep "err:wgl:macdrv_OpenGLInit" "$log" >/dev/null; then
        echo "Error: winemac.drv could not load OpenGL in wined3d.exe for $arch ($api)"
    elif grep "err:winediag:.*Using the Vulkan renderer\." "$log" >/dev/null; then
        echo "Error: wined3d.exe for $arch ($api) reported the Vulkan renderer, which is opt-in"
    elif ! wined3d_no_gl "$arch" "$api" "$RUN_STATUS" "$log"; then
        echo "Error: wined3d.exe for $arch ($api) failed (status $RUN_STATUS), but not with wined3d"
        echo "finding no adapter after winemac.drv found no accelerated OpenGL renderer"
    elif [ -n "$tree" ] && ! grep "$tree" "$log" >/dev/null; then
        echo "Error: compatdb.so did not give wined3d.exe for $arch the wined3d d3d9 tree"
        echo "its rule asks for (no '$tree' line), so the run proves nothing about wined3d"
    else
        check_freetype "wined3d.exe for $arch ($api)" "$log"
        check_rules_read "wined3d.exe for $arch ($api)" "$log"
        grep "wine-build smoke test: $arch " "$log" | sed 's/^/    /'
        echo "    winemac.drv found no accelerated OpenGL renderer, and wined3d no adapter."
        return 0
    fi
    want=':warn:wgl:display_funcs_init [^ ]* not found\.'
    grep -v "$want" "$log" || true
    echo "(left out: $(grep -c "$want" "$log" || true) lines of display_funcs_init's 'not found.' warnings)"
    smoke_stop
    exit 1
}

# wined3d_no_gl <arch> <api> <status> <log>: succeed when the wined3d.exe
# for <arch> and <api> exited with <status> 1 after printing in <log> that
# its Direct3DCreate8 or Direct3DCreate9 found no adapter, and the debug
# output in <log> says that winemac.drv's request for an accelerated
# renderer failed with kCGLBadPixelFormat (10002) and that wined3d then got
# no OpenGL context for its adapter. That is the failure a Mac without such
# a renderer gives; OpenGL that does not load fails earlier, with other
# messages.
wined3d_no_gl() {
    local arch="$1" api="$2" status="$3" log="$4" want
    [ "$status" -eq 1 ] || return 1
    # Only text without a digit, CGL's name for the error, may follow its
    # number, so that an error such as 100020 does not count.
    for want in "wine-build smoke test: $arch Direct3DCreate${api#d3d} failed: wined3d has no adapter" \
                "warn:wgl:init_context CGLChoosePixelFormat() failed with error 10002[^0-9]*\$" \
                "err:d3d:wined3d_adapter_gl_init Failed to get a GL context"; do
        grep "$want" "$log" >/dev/null || return 1
    done
}

# check_vulkan_runs <env-command>...: build smoke/vulkan.c for x86_64 and
# i686 and run it in the booted throwaway prefix, and exit unless each finds
# a Vulkan device that offers VK_EXT_transform_feedback, one of the features
# our KosmicKrisp always advertises, with no MESA_KK_EXPERIMENTAL set (the
# caller's is dropped). Headless: the program creates no surface. The
# device is found through vulkan-1.dll, winevulkan, the loader win32u.so
# loads from lib/external and the manifest in share/vulkan/icd.d, which
# ntdll names in VK_DRIVER_FILES since <env-command> drops the caller's VK_*
# variables. On a Mac without a Metal 4 GPU (METAL4=0, see metal4_probe)
# KosmicKrisp finds no device, so each run must fail the way a missing
# device makes it fail (check_vulkan_no_gpu) instead.
check_vulkan_runs() {
    local arch exe log want
    for arch in x86_64 i686; do
        exe="$TMP_DIR/vulkan-$arch.exe"
        "$MINGW_DIR/bin/$arch-w64-mingw32-clang" -O2 -o "$exe" "$REPO_DIR/smoke/vulkan.c"
        time_mark "smoke: vulkan.exe $arch"
        if [ "$METAL4" -eq 0 ]; then
            check_vulkan_no_gpu "$arch" "$exe" "$@"
            continue
        fi
        echo "  Running vulkan.exe for $arch..."
        log="$TMP_DIR/vulkan-$arch.log"
        run_limited 120 "$log" "$@" "$WINE_DIR/bin/wine" "$exe"
        # A bundle from before the always-on features, which --compatdb-only
        # can meet, got them from MESA_KK_EXPERIMENTAL, which compatdb.so no
        # longer sets.
        if [ "$RUN_STATUS" -ne 0 ] && grep "does not offer VK_EXT_transform_feedback" "$log" >/dev/null; then
            echo "  This bundle's KosmicKrisp advertises transform feedback only when"
            echo "  MESA_KK_EXPERIMENTAL names it, which compatdb.so no longer sets: it predates the"
            echo "  Mesa fork's always-on features. Bundle the whole build instead of using --compatdb-only."
        fi
        smoke_check "vulkan.exe for $arch" 120 "$log"
        want="wine-build smoke test: $arch vulkan device "
        if ! grep -q "$want" "$log"; then
            echo "Error: vulkan.exe for $arch did not print '$want'"
            cat "$log"
            smoke_stop
            exit 1
        fi
        grep "wine-build smoke test: $arch " "$log" | sed 's/^/    /'
    done
}

# check_vulkan_no_gpu <arch> <exe> <env-command>...: run the vulkan.exe
# <exe> for <arch> as check_vulkan_runs does, on a Mac without a Metal 4
# GPU, with the Vulkan loader's errors, warnings and driver search in the
# log, and exit unless it failed as vulkan_no_gpu describes and had
# FreeType. That still shows that vulkan-1.dll, winevulkan, the loader, the
# manifest and the driver all load; only the device is missing.
check_vulkan_no_gpu() {
    local arch="$1" exe="$2" log
    shift 2
    echo "  Running vulkan.exe for $arch, which must find the bundled driver and no GPU..."
    log="$TMP_DIR/vulkan-$arch.log"
    run_limited 120 "$log" "$@" VK_LOADER_DEBUG=error,warn,driver "$WINE_DIR/bin/wine" "$exe"
    if [ "$RUN_STATUS" -eq 142 ]; then
        echo "Error: vulkan.exe for $arch did not exit within 120 seconds"
    elif [ "$RUN_STATUS" -eq 0 ]; then
        echo "Error: vulkan.exe for $arch found a Vulkan device, though smoke/metal4.m found no Metal 4 GPU"
    elif ! vulkan_no_gpu "$arch" "$RUN_STATUS" "$log"; then
        echo "Error: vulkan.exe for $arch failed (status $RUN_STATUS), but not with vkCreateInstance"
        echo "result -3 after the Vulkan loader read the bundled manifest and found no GPU"
    else
        check_freetype "vulkan.exe for $arch" "$log"
        grep "wine-build smoke test: $arch " "$log" | sed 's/^/    /'
        echo "    The Vulkan loader read the bundled manifest, and the driver found no GPU."
        return 0
    fi
    cat "$log"
    smoke_stop
    exit 1
}

# vulkan_no_gpu <arch> <status> <log>: succeed when the vulkan.exe for
# <arch> exited with <status> 1 after printing in <log> that vkCreateInstance
# returned -3 (VK_ERROR_INITIALIZATION_FAILED), and the Vulkan loader's
# debug output in <log> says it read the bundled KosmicKrisp manifest and
# found no valid GPU. The loader only reaches that point with a driver
# loaded: one that does not load, or a manifest it cannot find, leaves it
# with no driver at all, which is another result and another message.
vulkan_no_gpu() {
    local arch="$1" status="$2" log="$3" want
    [ "$status" -eq 1 ] || return 1
    # The number has to end the line, so that a result such as -30 does not
    # count; Wine's text-mode output may end the line with a CR.
    for want in "wine-build smoke test: $arch vkCreateInstance failed, result -3[^0-9]*\$" \
                "Found ICD manifest file .*/share/vulkan/icd\.d/kosmickrisp_mesa_icd\.aarch64\.json" \
                "Failed to detect any valid GPUs"; do
        grep "$want" "$log" >/dev/null || return 1
    done
}

# check_d3d12_runs <env-command>...: build smoke/d3d12.c for x86_64, i686
# and aarch64 and run it in the booted throwaway prefix, and exit unless each
# gets the default dxmt tree from compatdb.so and goes through every step:
# vkd3d-proton's devices on DXMT's adapter, a swapchain DXMT presents for a
# visible window, a clear read back, resizes, a frame latency handle, and
# the swapchains Windows refuses. The log must also show the minimum frame
# latency of compatdb's vkd3d-proton-min-latency rule twice: in compatdb's
# env line, and in vkd3d-proton's report for the waitable swapchain, which
# shows the variable reached it. vkd3d-proton reaches KosmicKrisp through
# winevulkan and the bundled loader, as vulkan.exe does. On a Mac without a
# Metal 4 GPU (METAL4=0, see metal4_probe) KosmicKrisp has no device, so
# each run must fail creating its first device instead (check_d3d12_no_gpu).
check_d3d12_runs() {
    local arch exe log want
    for arch in x86_64 i686 aarch64; do
        exe="$TMP_DIR/d3d12-$arch.exe"
        "$MINGW_DIR/bin/$arch-w64-mingw32-clang" -O2 -o "$exe" "$REPO_DIR/smoke/d3d12.c"
        time_mark "smoke: d3d12.exe $arch"
        if [ "$METAL4" -eq 0 ]; then
            check_d3d12_no_gpu "$arch" "$exe" "$@"
            continue
        fi
        echo "  Running d3d12.exe for $arch..."
        log="$TMP_DIR/d3d12-$arch.log"
        run_limited 120 "$log" "$@" "$WINE_DIR/bin/wine" "$exe"
        smoke_check "d3d12.exe for $arch" 120 "$log"
        for want in "wine-build smoke test: $arch d3d12 works on " \
                    "compatdb: .*dxgi = ${DXGI_IMPLS%% *} (from" \
                    "compatdb: .*env VKD3D_SWAPCHAIN_MIN_LATENCY_FRAMES=2, rule [^:]*: set" \
                    "vkd3d-proton:.*Allowing a frame latency of at least 2 frames"; do
            if ! grep -q "$want" "$log"; then
                echo "Error: d3d12.exe for $arch did not print '$want'"
                cat "$log"
                smoke_stop
                exit 1
            fi
        done
        grep "wine-build smoke test: $arch " "$log" | sed 's/^/    /'
        echo "    vkd3d-proton: $(grep -m 1 -o "Allowing a frame latency of at least 2 frames" "$log")"
    done
}

# check_d3d12_no_gpu <arch> <exe> <env-command>...: run the d3d12.exe <exe>
# for <arch> as check_d3d12_runs does, on a Mac without a Metal 4 GPU, with
# the Vulkan loader's errors, warnings and driver search in the log, and exit
# unless it exited with 6 after D3D12CreateDevice on DXMT's adapter returned
# E_FAIL (0x80004005), which is what vkd3d-proton makes of the instance the
# Vulkan loader cannot create, and the loader read the bundled manifest and
# found no GPU, as for vulkan.exe (vulkan_no_gpu). That still shows that
# d3d12.dll, d3d12core.dll, DXMT's dxgi.dll, winevulkan and the loader load.
check_d3d12_no_gpu() {
    local arch="$1" exe="$2" log want
    shift 2
    echo "  Running d3d12.exe for $arch, which must find DXMT's adapter and no Vulkan device..."
    log="$TMP_DIR/d3d12-$arch.log"
    run_limited 120 "$log" "$@" VK_LOADER_DEBUG=error,warn,driver "$WINE_DIR/bin/wine" "$exe"
    if [ "$RUN_STATUS" -eq 142 ]; then
        echo "Error: d3d12.exe for $arch did not exit within 120 seconds"
    elif [ "$RUN_STATUS" -eq 0 ]; then
        echo "Error: d3d12.exe for $arch created a D3D12 device, though smoke/metal4.m found no Metal 4 GPU"
    elif [ "$RUN_STATUS" -ne 6 ]; then
        echo "Error: d3d12.exe for $arch failed (status $RUN_STATUS) before or after its first device"
    else
        for want in "wine-build smoke test: $arch D3D12CreateDevice on the dxgi adapter failed, 0x80004005[^0-9a-f]*\$" \
                    "Found ICD manifest file .*/share/vulkan/icd\.d/kosmickrisp_mesa_icd\.aarch64\.json" \
                    "Failed to detect any valid GPUs"; do
            if ! grep "$want" "$log" >/dev/null; then
                echo "Error: d3d12.exe for $arch failed its first device, but did not print '$want'"
                cat "$log"
                smoke_stop
                exit 1
            fi
        done
        check_freetype "d3d12.exe for $arch" "$log"
        grep "wine-build smoke test: $arch " "$log" | sed 's/^/    /'
        echo "    vkd3d-proton found DXMT's adapter, and the Vulkan loader no GPU."
        return 0
    fi
    cat "$log"
    smoke_stop
    exit 1
}

# bundle_egl: set BUNDLE_EGL to 1 when the bundle has Mesa's EGL in
# lib/external, and MESA_GALLIUM to the name of the one gallium library next
# to it, which carries Mesa's version, and BUNDLE_EGL to 0 when it has no
# EGL, as a bundle from before EGL that --compatdb-only meets. A full bundle
# always has it (Step 5 checks). ZINK_GL is 1 when the Mac driver's OpenGL
# runs on Zink with compatdb's opengl=egl: the bundle has EGL and a
# GPU supports the Metal 4 family (metal4_probe, which has to run first).
bundle_egl() {
    local lib gallium=()
    BUNDLE_EGL=0
    ZINK_GL=0
    [ -f "$EXT_DIR/libEGL.1.dylib" ] || return 0
    for lib in "$EXT_DIR"/libgallium-*.dylib; do
        [ -f "$lib" ] && gallium+=("$(basename "$lib")")
    done
    if [ ${#gallium[@]} -ne 1 ]; then
        echo "Error: lib/external has libEGL.1.dylib and ${#gallium[@]} libgallium-*.dylib, not one"
        exit 1
    fi
    MESA_GALLIUM=${gallium[0]}
    BUNDLE_EGL=1
    ZINK_GL=$METAL4
}

# check_egl_host: build smoke/egl.c for the host and run it on the bundle's
# lib/external/libEGL.1.dylib, outside Wine, with nothing in its environment
# but VK_DRIVER_FILES naming the bundle's manifest directory, as ntdll sets
# it. Exit unless it made an OpenGL context current on Zink on KosmicKrisp
# (the renderer names both) and loaded libEGL, the gallium library, the
# Vulkan loader and the driver from lib/external, and from nowhere else. This
# shows the chain resolves inside the bundle before Wine is involved. It
# needs a KosmicKrisp device, so on a Mac without a Metal 4 GPU
# (metal4_probe) it is skipped, and so it is for a bundle without EGL
# (bundle_egl).
check_egl_host() {
    local log="$TMP_DIR/egl.log" lib want status=0
    if [ "$BUNDLE_EGL" -eq 0 ]; then
        echo "  Skipping the host EGL check: this bundle has no EGL."
        return 0
    elif [ "$METAL4" -eq 0 ]; then
        echo "  Skipping the host EGL check: Zink needs a KosmicKrisp device."
        return 0
    fi
    xcrun clang -O2 -o "$TMP_DIR/egl" "$REPO_DIR/smoke/egl.c"
    echo "  Running the host EGL check on lib/external/libEGL.1.dylib..."
    env -i PATH=/usr/bin:/bin VK_DRIVER_FILES="$WINE_DIR/share/vulkan/icd.d" \
        "$TMP_DIR/egl" "$EXT_DIR/libEGL.1.dylib" >"$log" 2>&1 || status=$?
    if [ "$status" -ne 0 ]; then
        echo "Error: smoke/egl.c failed on the bundle's EGL (status $status)"
        cat "$log"
        exit 1
    fi
    if ! grep "^egl: GL_RENDERER: zink .*MESA_KOSMICKRISP" "$log" >/dev/null; then
        echo "Error: the bundle's EGL did not give a context on Zink on KosmicKrisp"
        cat "$log"
        exit 1
    fi
    for lib in libEGL.1.dylib "$MESA_GALLIUM" libvulkan.1.dylib libvulkan_kosmickrisp.dylib; do
        want="egl: loaded $EXT_DIR/$lib"
        if ! grep -xF "$want" "$log" >/dev/null; then
            echo "Error: smoke/egl.c did not load lib/external/$lib"
            cat "$log"
            exit 1
        fi
    done
    if grep "^egl: loaded " "$log" | grep -vF "egl: loaded $EXT_DIR/" >/dev/null; then
        echo "Error: smoke/egl.c loaded an EGL, gallium or Vulkan library from outside the bundle"
        cat "$log"
        exit 1
    fi
    grep "^egl: GL_" "$log" | sed 's/^egl: /    /'
}

# check_wgl_runs <env-command>...: build smoke/wgl.c for each arch of
# SMOKE_PE_ARCHS and run it in the booted throwaway prefix (run_wgl). It
# opens a window and creates a legacy, a 4.x core and a compatibility
# context, each of which must clear, read back and swap, and whose renderer
# must contain the string it is given. <env-command> drops the caller's
# WINE_COMPATDB, so compatdb's built-in opengl-egl rule decides: it asks
# winemac.drv for Mesa's EGL, which runs on Zink when the bundle has EGL and
# a GPU supports the Metal 4 family (ZINK_GL, see bundle_egl), and gives no
# OpenGL at all otherwise, since winemac.drv does not fall back from EGL.
# With Zink each arch runs by default, where the renderer must be Zink and
# the compatdb log must show the rule's opengl=egl. Without Zink it runs by
# default once to show that EGL is still the default there and gets no
# context (check_wgl_no_egl). Then, with an accelerated OpenGL renderer
# (gl_probe), each arch runs with a WINE_COMPATDB rule for wgl.exe with
# opengl=cgl, which wins over the built-in rule, where the renderer must be
# Apple's.
check_wgl_runs() {
    local arch exe
    for arch in $SMOKE_PE_ARCHS; do
        exe="$TMP_DIR/wgl-$arch.exe"
        "$MINGW_DIR/bin/$arch-w64-mingw32-clang" -O2 -o "$exe" "$REPO_DIR/smoke/wgl.c" \
            -lopengl32 -lgdi32
        if [ "$ZINK_GL" -eq 1 ]; then
            run_wgl "$arch" "$exe" zink default "$@"
        else
            check_wgl_no_egl "$arch" "$exe" "$@"
        fi
        if [ "$ACCEL_GL" -eq 1 ]; then
            run_wgl "$arch" "$exe" Apple cgl "$@" \
                WINE_COMPATDB="name=smoke;exe=$(basename "$exe");opengl=cgl"
        fi
    done
    if [ "$ACCEL_GL" -eq 0 ]; then
        echo "  No wgl.exe run on Apple's OpenGL: no accelerated OpenGL renderer."
    fi
}

# check_wgl_no_egl <arch> <exe> <env-command>...: on a Mac without Zink, run
# the wgl.exe <exe> for <arch> under <env-command> with nothing chosen, and
# exit unless compatdb's built-in opengl-egl rule handed opengl=egl to it,
# winemac.drv said that EGL did not start and OpenGL is disabled, and
# wgl.exe found no pixel format (exit status 2, FAIL_PIXEL_FORMAT in
# smoke/wgl.c) after its window came up. Any other failure, the window
# included, fails the step. That shows EGL is the default there too, and
# that the cgl runs get Apple's renderer only because their rule asks for
# it.
check_wgl_no_egl() {
    local arch="$1" exe="$2" log
    shift 2
    time_mark "smoke: wgl.exe $arch (egl without Zink)"
    echo "  Running wgl.exe for $arch with nothing chosen, which must get no OpenGL without Zink..."
    log="$TMP_DIR/wgl-$arch-egl.log"
    run_limited 120 "$log" "$@" WINEDEBUG=-all,err+winediag "$WINE_DIR/bin/wine" "$exe"
    if [ "$RUN_STATUS" -eq 142 ]; then
        echo "Error: wgl.exe for $arch with nothing chosen did not exit within 120 seconds"
    elif ! grep -q "compatdb: .*opengl = egl, rule opengl-egl$" "$log"; then
        echo "Error: compatdb.so did not hand opengl=egl to wgl.exe for $arch"
    elif ! grep -q "err:winediag:.*compatdb asks for Mesa's EGL, but .*; OpenGL is disabled" "$log"; then
        echo "Error: winemac.drv did not say that Mesa's EGL failed and OpenGL is disabled in"
        echo "wgl.exe for $arch with opengl=egl"
    elif [ "$RUN_STATUS" -ne 2 ] || ! grep -q "wine-build smoke test: $arch no pixel format" "$log"; then
        echo "Error: wgl.exe for $arch with opengl=egl and no OpenGL did not stop at its"
        echo "pixel format (status $RUN_STATUS, not 2)"
    else
        check_freetype "wgl.exe for $arch with nothing chosen" "$log"
        check_rules_read "wgl.exe for $arch with nothing chosen" "$log"
        echo "    opengl=egl from compatdb, and no OpenGL (status $RUN_STATUS)."
        return 0
    fi
    cat "$log"
    smoke_stop
    exit 1
}

# run_wgl <arch> <exe> <renderer> <name> <env-command>...: run the wgl.exe
# <exe> for <arch> under <env-command>, as the run <name>, and exit unless
# it ran cleanly with every context on a renderer containing <renderer>. The
# default run must also show that compatdb handed over the built-in rule's
# opengl=egl, and the cgl run that it handed over its own rule's opengl=cgl
# and read that rule without a warning.
run_wgl() {
    local arch="$1" exe="$2" want="$3" name="$4" log line
    shift 4
    time_mark "smoke: wgl.exe $arch ($name)"
    echo "  Running wgl.exe for $arch ($name), which must get the $want renderer..."
    log="$TMP_DIR/wgl-$arch-$name.log"
    run_limited 120 "$log" "$@" "$WINE_DIR/bin/wine" "$exe" "$want"
    smoke_check "wgl.exe for $arch ($name)" 120 "$log"
    case "$name" in
        default) line="compatdb: .*opengl = egl, rule opengl-egl$" ;;
        cgl)
            line="compatdb: .*opengl = cgl, rule smoke$"
            check_rules_read "wgl.exe for $arch ($name)" "$log"
            ;;
    esac
    if ! grep -q "$line" "$log"; then
        echo "Error: wgl.exe for $arch ($name) has no compatdb line '$line'"
        cat "$log"
        smoke_stop
        exit 1
    fi
    if ! grep -q "wine-build smoke test: $arch OpenGL contexts work" "$log"; then
        echo "Error: wgl.exe for $arch ($name) did not print 'wine-build smoke test: $arch OpenGL contexts work'"
        cat "$log"
        smoke_stop
        exit 1
    fi
    grep "wine-build smoke test: $arch .*\(GL_RENDERER\|GL_VERSION\|swap interval\)" "$log" \
        | sed 's/^/    /'
}

# metal4_probe: set METAL4 to 1 when this Mac has a Metal device that
# supports MTLGPUFamilyMetal4, the only kind KosmicKrisp uses, and to 0 when
# it has none, such as a virtual machine's paravirtual GPU. METAL_DEVICES
# gets what smoke/metal4.m printed: the device KosmicKrisp would take, or
# every device there is. Without one, the smoke test cannot check what needs
# a Vulkan device, and says so. Only the hardware decides this; nothing
# skips those checks on a Mac that has such a device.
metal4_probe() {
    local status=0
    xcrun clang -O2 -fobjc-arc -framework Foundation -framework Metal \
        -o "$TMP_DIR/metal4" "$REPO_DIR/smoke/metal4.m"
    METAL_DEVICES=$("$TMP_DIR/metal4") || status=$?
    case "$status" in
        0) METAL4=1 ;;
        1) METAL4=0 ;;
        *) echo "Error: smoke/metal4.m failed (status $status)"; exit 1 ;;
    esac
}

# gl_probe: set ACCEL_GL to 1 when this Mac has an accelerated OpenGL
# renderer for the main display, the only kind winemac.drv asks for, and to
# 0 when it has none, such as a virtual machine whose only renderer is
# Apple's software one. GL_RENDERERS gets what smoke/opengl.m printed: the
# renderer winemac.drv would get, or every renderer of the main display.
# Without one, wined3d cannot run on OpenGL, and the smoke test says so.
# Only the hardware decides this, independently of metal4_probe; nothing
# skips the OpenGL check on a Mac that has such a renderer.
gl_probe() {
    local status=0
    xcrun clang -O2 -fobjc-arc -framework Foundation -framework CoreGraphics -framework OpenGL \
        -o "$TMP_DIR/opengl" "$REPO_DIR/smoke/opengl.m"
    GL_RENDERERS=$("$TMP_DIR/opengl") || status=$?
    case "$status" in
        0) ACCEL_GL=1 ;;
        1) ACCEL_GL=0 ;;
        *) echo "Error: smoke/opengl.m failed (status $status)"; exit 1 ;;
    esac
}

# smoke_check <what> <seconds> <log>: after run_limited, exit with the log
# unless the run ended cleanly and Wine had FreeType (check_freetype).
smoke_check() {
    if [ "$RUN_STATUS" -eq 142 ]; then
        echo "Error: $1 did not exit within $2 seconds"
    elif [ "$RUN_STATUS" -ne 0 ]; then
        echo "Error: $1 failed under the bundled wine (status $RUN_STATUS)"
    else
        check_freetype "$1" "$3"
        return 0
    fi
    cat "$3"
    smoke_stop
    exit 1
}

# check_freetype <what> <log>: exit with the log if Wine said in it that it
# cannot load FreeType. win32u then runs without it, with no TrueType fonts,
# and the program itself still succeeds, so its status shows nothing. Wine
# prints the message whatever WINEDEBUG says.
check_freetype() {
    if grep -F "Wine cannot find the FreeType font library" "$2" >/dev/null; then
        echo "Error: $1 ran without FreeType: Wine could not load the bundled libfreetype"
    else
        return 0
    fi
    cat "$2"
    smoke_stop
    exit 1
}

# smoke_stop: stop the throwaway prefix's wineserver, which is persistent
# and has to be told to go rather than waited for.
smoke_stop() {
    WINEPREFIX="$TMP_DIR/prefix" "$WINE_DIR/bin/wineserver" -k 2>/dev/null || true
}

# check_tree_loads <arch> <env-command>...: build smoke/hello.c for <arch>
# (x86_64, i686 or aarch64) and run it in the booted throwaway prefix once per
# Direct3D tree that has modules for it, with a WINE_COMPATDB rule that gives
# the program that tree, and exit unless compatdb.so reports the tree and the
# program loads every module in it, plus the other family's d3d9.dll or
# dxgi.dll. This is what proves the default-dir placeholders let each tree's
# modules into a process of that arch, for x86_64 and aarch64 (a native
# ARM64 program) through the hybrid placeholders of every 64-bit name (Step
# 4, the markers). While a dxgi tree has d3d12.dll, every dxgi tree gets a
# second run that must fail to load it (check_no_d3d12): one without D3D12
# as it is, and one with D3D12 with the rule that hides it from a game.
# <env-command> is the env invocation the runs start with; the rule is
# appended to it.
check_tree_loads() {
    local arch="$1" dir=i386-windows exe log family impl other names f want
    shift
    [ "$arch" = i686 ] || dir="$PE64_DIR"
    exe="$TMP_DIR/trees-$arch.exe"
    "$MINGW_DIR/bin/$arch-w64-mingw32-clang" -O2 -o "$exe" "$REPO_DIR/smoke/hello.c"
    for family in dxgi d3d9; do
        if [ "$family" = dxgi ]; then other=d3d9.dll; else other=dxgi.dll; fi
        for impl in $(family_impls "$family"); do
            [ -d "$WINE_DIR/lib/wine/$family/$impl/$dir" ] || continue
            names=()
            for f in "$WINE_DIR/lib/wine/$family/$impl/$dir"/*.dll; do
                names+=("$(basename "$f")")
            done
            names+=("$other")
            time_mark "smoke: $arch on $family/$impl"
            log="$TMP_DIR/trees-$arch-$family-$impl.log"
            run_limited 120 "$log" "$@" \
                WINE_COMPATDB="name=smoke;exe=$(basename "$exe");$family=$impl" \
                "$WINE_DIR/bin/wine" "$exe" "${names[@]}"
            smoke_check "the $arch program on the $family/$impl tree" 120 "$log"
            check_rules_read "the $arch program on the $family/$impl tree" "$log"
            for want in "compatdb: .*$family = $impl (from" \
                        "wine-build smoke test: $arch loads ${names[*]}"; do
                if ! grep -q "$want" "$log"; then
                    echo "Error: the $arch program on the $family/$impl tree did not print '$want'"
                    cat "$log"
                    smoke_stop
                    exit 1
                fi
            done
            echo "    $arch, $family=$impl: loads ${names[*]}"
            # A dxgi tree without D3D12 of its own (wined3d's) must not reach
            # vkd3d-proton's in another tree: the default dir has only the
            # marker of d3d12.dll, which Wine does not load as a module. On a
            # tree with D3D12, the recipe that hides it from one game
            # (docs/compatdb.md) must disable it through compatdb's
            # load-order hook and leave the tree's dxgi.dll alone.
            [ "$family" = dxgi ] && [ -f "$WINE_DIR/lib/wine/$dir/d3d12.dll" ] || continue
            if [ -f "$WINE_DIR/lib/wine/$family/$impl/$dir/d3d12.dll" ]; then
                check_no_d3d12 "$arch" "$exe" "$family=$impl;dll_overrides=d3d12,d3d12core=" \
                    "$family=$impl with d3d12 and d3d12core disabled" "$@"
            else
                check_no_d3d12 "$arch" "$exe" "$family=$impl" "$family=$impl" "$@"
            fi
        done
    done
}

# check_no_d3d12 <arch> <exe> <settings> <label> <env-command>...:
# run the hello.exe <exe> for <arch> with a WINE_COMPATDB rule for it made of
# <settings>, loading dxgi.dll and d3d12.dll, and exit unless dxgi.dll loads
# and d3d12.dll fails with 126 (ERROR_MOD_NOT_FOUND), which is what both a
# missing module and a disabled one give.
check_no_d3d12() {
    local arch="$1" exe="$2" settings="$3" label="$4" log want
    shift 4
    time_mark "smoke: $arch without d3d12 ($label)"
    log="$TMP_DIR/trees-$arch-no-d3d12-${settings%%;*}.log"
    log="${log//=/-}"
    run_limited 120 "$log" "$@" \
        WINE_COMPATDB="name=smoke;exe=$(basename "$exe");$settings" \
        "$WINE_DIR/bin/wine" "$exe" dxgi.dll d3d12.dll
    smoke_check "the $arch program loading d3d12.dll ($label)" 120 "$log"
    check_rules_read "the $arch program loading d3d12.dll ($label)" "$log"
    want="wine-build smoke test: $arch cannot load d3d12.dll, error 126[^0-9]*\$"
    if ! grep -q "$want" "$log" || grep -q "cannot load dxgi.dll" "$log"; then
        echo "Error: the $arch program ($label) did not load dxgi.dll and fail to load"
        echo "d3d12.dll with error 126"
        cat "$log"
        smoke_stop
        exit 1
    fi
    echo "    $arch, $label: dxgi.dll loads, d3d12.dll does not (error 126)"
}

# check_fex_build: exit unless build-fex.sh staged all of FEX in FEX_DIST
# from the commit fex-src.ref names now: the COMMIT it wrote last. Needs the
# network, to resolve a branch or tag.
check_fex_build() {
    local f built want
    built=$(cat "$FEX_DIST/COMMIT" 2>/dev/null) || {
        echo "Error: $FEX_DIST has no COMMIT; build-fex.sh has not staged it (run build-wine.sh)"
        exit 1
    }
    want=$(src_ref_commit fex-src.ref "$FEX_REPO")
    if [ -z "$want" ]; then
        echo "Error: cannot resolve fex-src.ref ($(tr -d '[:space:]' < "$PINS_DIR/fex-src.ref")) in $FEX_REPO"
        exit 1
    fi
    if [ "$built" != "$want" ]; then
        echo "Error: FEX was built from $built, but fex-src.ref now names $want"
        echo "(run build-fex.sh)"
        exit 1
    fi
    for f in "$PE64_DIR/libwow64fex.dll" "$PE64_DIR/libarm64ecfex.dll" \
             "$UNIX_DIR/libwow64fex.so" "$UNIX_DIR/libarm64ecfex.so"; do
        if [ ! -f "$FEX_DIST/$f" ]; then
            echo "Error: no $f in $FEX_DIST (run build-fex.sh)"
            exit 1
        fi
    done
    echo "  FEX: $built"
}

# check_mesa_build: exit unless build-mesa.sh staged the Vulkan loader,
# KosmicKrisp and EGL with Zink completely, Mesa from the commit mesa-src.ref
# names now and the loader from the pinned one, and set MESA_GALLIUM to the
# name of the gallium library libEGL.1.dylib loads, which carries Mesa's
# version. Needs the network, to resolve a branch or tag.
check_mesa_build() {
    local f built want lib
    local gallium=()
    built=$(cat "$MESA_DIST/COMMIT" 2>/dev/null) || {
        echo "Error: $MESA_DIST has no COMMIT; build-mesa.sh has not staged it (run build-wine.sh)"
        exit 1
    }
    want=$(src_ref_commit mesa-src.ref "$MESA_REPO")
    if [ -z "$want" ]; then
        echo "Error: cannot resolve mesa-src.ref ($(tr -d '[:space:]' < "$PINS_DIR/mesa-src.ref")) in $MESA_REPO"
        exit 1
    fi
    if [ "$built" != "$want" ]; then
        echo "Error: Mesa was built from $built, but mesa-src.ref now names $want"
        echo "(run build-mesa.sh)"
        exit 1
    fi
    if [ "$(cat "$MESA_DIST/LOADER_COMMIT" 2>/dev/null)" != "$VULKAN_LOADER_GIT_COMMIT" ]; then
        echo "Error: the Vulkan loader in $MESA_DIST was not built from $VULKAN_LOADER_GIT_COMMIT (run build-mesa.sh)"
        exit 1
    fi
    for f in lib/libvulkan.1.dylib lib/libvulkan_kosmickrisp.dylib lib/libEGL.1.dylib \
             share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json; do
        if [ ! -f "$MESA_DIST/$f" ]; then
            echo "Error: no $f in $MESA_DIST (run build-mesa.sh)"
            exit 1
        fi
    done
    for lib in "$MESA_DIST"/lib/libgallium-*.dylib; do
        [ -f "$lib" ] && gallium+=("$(basename "$lib")")
    done
    if [ ${#gallium[@]} -ne 1 ]; then
        echo "Error: $MESA_DIST/lib has ${#gallium[@]} libgallium-*.dylib, not one (run build-mesa.sh)"
        exit 1
    fi
    MESA_GALLIUM=${gallium[0]}
    echo "  Mesa: $built, Vulkan loader $VULKAN_LOADER_GIT_TAG, $MESA_GALLIUM"
}

# check_vulkan: exit unless the bundle's Vulkan hangs together: the driver
# manifest names the bundled KosmicKrisp by a path that resolves from its
# directory, the loader and the driver export their entry points, and ntdll
# points the loader at the manifest's directory (it names VK_DRIVER_FILES).
check_vulkan() {
    local icd lib f sym
    icd="$WINE_DIR/share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json"
    lib=$(plutil -extract ICD.library_path raw -o - "$icd" 2>/dev/null) || {
        echo "Error: share/vulkan/icd.d/$(basename "$icd") is missing or has no ICD.library_path"
        exit 1
    }
    case "$lib" in
        /*) echo "Error: $(basename "$icd") names the driver by the absolute path $lib"; exit 1 ;;
    esac
    if [ ! -f "$(dirname "$icd")/$lib" ]; then
        echo "Error: $(basename "$icd") names $lib, which does not resolve from share/vulkan/icd.d"
        exit 1
    fi
    for f in libvulkan.1.dylib:_vkGetInstanceProcAddr libvulkan.1.dylib:_vkCreateMetalSurfaceEXT \
             libvulkan_kosmickrisp.dylib:_vk_icdGetInstanceProcAddr; do
        sym=${f#*:}
        if ! nm -gU "$EXT_DIR/${f%%:*}" 2>/dev/null | awk '{print $NF}' | grep -xF "$sym" >/dev/null; then
            echo "Error: lib/external/${f%%:*} does not export $sym"
            exit 1
        fi
    done
    if ! grep -qaF VK_DRIVER_FILES "$unixdir/ntdll.so"; then
        echo "Error: $UNIX_DIR/ntdll.so does not name VK_DRIVER_FILES; the Wine tree is missing"
        echo "the ntdll change that points the Vulkan loader at share/vulkan/icd.d"
        exit 1
    fi
    echo "  The Vulkan manifest names lib/external/$(basename "$lib"), and ntdll sets VK_DRIVER_FILES."
}

# check_compat_hooks: exit unless ntdll exports the hooks compatdb.so hands
# the settings of its built-in force-nx and opengl-egl rules to:
# set_compat_force_nx and set_compat_opengl. Without them compatdb.so only
# logs that a hook is missing, and every 32-bit program without NX_COMPAT
# runs with no-execute off and every process gets Apple's OpenGL. Run for a
# full bundle and, before anything is replaced, for --compatdb-only, whose
# bundle may predate the hooks and then needs a full bundle step.
check_compat_hooks() {
    local hook
    for hook in set_compat_force_nx set_compat_opengl; do
        if ! nm -gU "$unixdir/ntdll.so" 2>/dev/null | awk '{print $NF}' | grep -xF "_$hook" >/dev/null; then
            echo "Error: $UNIX_DIR/ntdll.so does not export $hook; the Wine of this bundle"
            echo "predates the hook through which compatdb.so hands that setting over (bundle"
            echo "the whole build)"
            exit 1
        fi
    done
    echo "  ntdll exports set_compat_force_nx and set_compat_opengl."
}

# check_egl: exit unless OpenGL through Zink hangs together in the bundle:
# win32u.so opens lib/external/libEGL.1.dylib, which exports what win32u
# loads first and links the gallium library next to it, and the gallium
# library opens the Vulkan loader next to it: Zink dlopens
# "@rpath/libvulkan.1.dylib", and the gallium library's one LC_RPATH,
# @loader_path, which Step 3 keeps as it names lib/external itself,
# resolves that there.
check_egl() {
    local sym rpaths
    if ! grep -aF "@loader_path/../../external/libEGL.1.dylib" "$unixdir/win32u.so" >/dev/null; then
        echo "Error: $UNIX_DIR/win32u.so does not open @loader_path/../../external/libEGL.1.dylib"
        echo "(SONAME_LIBEGL missing from config.h or not patched; run build-wine.sh --clean)"
        exit 1
    fi
    for sym in _eglGetProcAddress _eglCreateWindowSurface; do
        if ! nm -gU "$EXT_DIR/libEGL.1.dylib" 2>/dev/null | awk '{print $NF}' | grep -xF "$sym" >/dev/null; then
            echo "Error: lib/external/libEGL.1.dylib does not export $sym"
            exit 1
        fi
    done
    if ! otool -L "$EXT_DIR/libEGL.1.dylib" | awk '{print $1}' | grep -xF "@loader_path/$MESA_GALLIUM" >/dev/null; then
        echo "Error: lib/external/libEGL.1.dylib does not load @loader_path/$MESA_GALLIUM"
        exit 1
    fi
    rpaths=$(otool -l "$EXT_DIR/$MESA_GALLIUM" | awk '$1 == "cmd" { r = ($2 == "LC_RPATH") } r && $1 == "path" { print $2 }')
    if ! grep -aF "@rpath/libvulkan.1.dylib" "$EXT_DIR/$MESA_GALLIUM" >/dev/null \
        || [ "$rpaths" != "@loader_path" ]; then
        echo "Error: lib/external/$MESA_GALLIUM does not open @rpath/libvulkan.1.dylib with"
        echo "@loader_path as its only LC_RPATH (it has: ${rpaths:-none})"
        exit 1
    fi
    echo "  win32u.so opens lib/external/libEGL.1.dylib, which loads $MESA_GALLIUM, which opens the Vulkan loader."
}

# check_wine_sdk: exit unless the Wine SDK build-wine.sh staged is for the
# Wine source as it is now, which DXMT's DLLs were linked against and whose
# x86_64 link libraries and graphics tests a full bundle carries, and, for a
# full bundle, holds every test of GRAPHICS_TESTS and their VERSION (an SDK
# staged before the tests or VERSION were has a current WINE_COMMIT and lacks
# them).
check_wine_sdk() {
    local pe t
    if [ "$(cat "$WINE_SDK_DIR/WINE_COMMIT" 2>/dev/null)" != "$(wine_src_commit)" ]; then
        echo "Error: the Wine SDK at $WINE_SDK_DIR is for $(cat "$WINE_SDK_DIR/WINE_COMMIT" 2>/dev/null || echo nothing),"
        echo "but $WINE_SRC is at $(wine_src_commit) (run build-wine.sh)"
        exit 1
    fi
    if [ "$RUNTIME_ONLY" -eq 0 ]; then
        for pe in $TEST_PE_DIRS; do
            for t in $(graphics_tests "$pe"); do
                if [ ! -f "$WINE_SDK_DIR/lib/wine/tests/$pe/${t}_test.exe" ]; then
                    echo "Error: the Wine SDK at $WINE_SDK_DIR has no lib/wine/tests/$pe/${t}_test.exe (run build-wine.sh)"
                    exit 1
                fi
            done
        done
        if [ ! -s "$WINE_SDK_DIR/lib/wine/tests/VERSION" ]; then
            echo "Error: the Wine SDK at $WINE_SDK_DIR has no lib/wine/tests/VERSION (run build-wine.sh)"
            exit 1
        fi
    fi
    echo "  Wine SDK: $(cat "$WINE_SDK_DIR/WINE_COMMIT")"
}

# check_dxmt_build: exit unless build-dxmt.sh staged all of DXMT from the
# commit dxmt-src.ref names now. The DLLs and winemetal.so share a private
# call interface, so they must be one build: the COMMIT build-dxmt.sh wrote
# last, and the DESCRIBE it recorded, which d3d11.dll carries as its version
# string. Needs the network, to resolve a branch or tag.
check_dxmt_build() {
    local f describe built want
    built=$(cat "$DXMT_DIST/COMMIT" 2>/dev/null) || {
        echo "Error: $DXMT_DIST has no COMMIT; build-dxmt.sh has not staged it (run build-wine.sh)"
        exit 1
    }
    want=$(src_ref_commit dxmt-src.ref "$DXMT_REPO")
    if [ -z "$want" ]; then
        echo "Error: cannot resolve dxmt-src.ref ($(tr -d '[:space:]' < "$PINS_DIR/dxmt-src.ref")) in $DXMT_REPO"
        exit 1
    fi
    if [ "$built" != "$want" ]; then
        echo "Error: DXMT was built from $built, but dxmt-src.ref now names $want"
        echo "(run build-dxmt.sh)"
        exit 1
    fi
    for f in "$PE64_DIR/dxgi.dll" "$PE64_DIR/d3d10core.dll" "$PE64_DIR/d3d11.dll" \
             "$PE64_DIR/winemetal.dll" i386-windows/dxgi.dll i386-windows/d3d10core.dll \
             i386-windows/d3d11.dll i386-windows/winemetal.dll "$UNIX_DIR/winemetal.so" DESCRIBE; do
        if [ ! -f "$DXMT_DIST/$f" ]; then
            echo "Error: no $f in $DXMT_DIST (run build-dxmt.sh)"
            exit 1
        fi
    done
    # Linked against this Wine source's winemac.so, ntdll.so and SDK.
    if [ "$(cat "$DXMT_DIST/WINE_COMMIT" 2>/dev/null)" != "$(wine_src_commit)" ]; then
        echo "Error: $DXMT_DIST was built against Wine $(cat "$DXMT_DIST/WINE_COMMIT" 2>/dev/null || echo unknown),"
        echo "but $WINE_SRC is at $(wine_src_commit) (run build-dxmt.sh)"
        exit 1
    fi
    describe=$(cat "$DXMT_DIST/DESCRIBE")
    for f in "$PE64_DIR/d3d11.dll" i386-windows/d3d11.dll; do
        if ! strings -a "$DXMT_DIST/$f" | grep -xF "$describe" >/dev/null; then
            echo "Error: $DXMT_DIST/$f is not DXMT $describe"
            exit 1
        fi
    done
    echo "  DXMT: $describe ($built)"
}

# check_vkd3d_proton_build: exit unless build-vkd3d-proton.sh staged both of
# vkd3d-proton's DLLs for both arches from the commit vkd3d-proton-src.ref
# names now: the COMMIT it wrote last. Its WINE_COMMIT is not compared: the
# DLLs link nothing of Wine, and the builtin mark winebuild gave them does
# not change with Wine. Needs the network, to resolve a branch or tag.
check_vkd3d_proton_build() {
    local f built want
    built=$(cat "$VKD3D_PROTON_DIST/COMMIT" 2>/dev/null) || {
        echo "Error: $VKD3D_PROTON_DIST has no COMMIT; build-vkd3d-proton.sh has not staged it (run build-wine.sh)"
        exit 1
    }
    want=$(src_ref_commit vkd3d-proton-src.ref "$VKD3D_PROTON_REPO")
    if [ -z "$want" ]; then
        echo "Error: cannot resolve vkd3d-proton-src.ref ($(tr -d '[:space:]' < "$PINS_DIR/vkd3d-proton-src.ref")) in $VKD3D_PROTON_REPO"
        exit 1
    fi
    if [ "$built" != "$want" ]; then
        echo "Error: vkd3d-proton was built from $built, but vkd3d-proton-src.ref now names $want"
        echo "(run build-vkd3d-proton.sh)"
        exit 1
    fi
    for f in "$PE64_DIR/d3d12.dll" "$PE64_DIR/d3d12core.dll" \
             i386-windows/d3d12.dll i386-windows/d3d12core.dll DESCRIBE; do
        if [ ! -f "$VKD3D_PROTON_DIST/$f" ]; then
            echo "Error: no $f in $VKD3D_PROTON_DIST (run build-vkd3d-proton.sh)"
            exit 1
        fi
    done
    echo "  vkd3d-proton: $(cat "$VKD3D_PROTON_DIST/DESCRIBE") ($built)"
}

# ── Loader app ──────────────────────────────────────────────────────────
# The arm64 loader needs com.apple.developer.cross-architecture-support,
# with which the kernel leaves most of the 4 GB __PAGEZERO replaceable, so
# Wine can claim the low address space its i386 code needs (the same
# entitlement gates the hardware x86 memory ordering FEX runs x86 code with,
# see FEX_HARDWARE_TSO in the environment variables of README.md). That
# entitlement is restricted: it is only honoured with a provisioning profile
# that grants it, embedded in an app bundle, and a signature by a
# certificate of the same team. So the loader moves into
# lib/wine/<unix>/wine.app and everything that starts a Wine process reaches
# it through a symlink. Everything about the signature comes from the
# profile in LOADER_PROFILE: the entitlements, the bundle identifier and the
# team whose certificate signs.

# loader_preflight: read LOADER_PROFILE and find the signing identity, or
# exit. Sets LOADER_PLIST (the decoded profile), LOADER_TEAM,
# LOADER_BUNDLE_ID, LOADER_IDENTITY (the certificate's SHA-1) and
# LOADER_IDENTITY_NAME. Runs before anything is deleted, so a bad profile
# costs nothing.
loader_preflight() {
    local expires now appid certs cert i id
    if [ ! -f "$LOADER_PROFILE" ]; then
        echo "Error: no provisioning profile at $LOADER_PROFILE"
        exit 1
    fi
    LOADER_PLIST="$TMP_DIR/loader-profile.plist"
    security cms -D -i "$LOADER_PROFILE" > "$LOADER_PLIST" 2>/dev/null || {
        echo "Error: $LOADER_PROFILE is not a signed provisioning profile"
        exit 1
    }
    # Both are ISO 8601 in UTC, so they compare as strings.
    expires=$(plutil -extract ExpirationDate raw -o - "$LOADER_PLIST" 2>/dev/null) || {
        echo "Error: the provisioning profile has no ExpirationDate"
        exit 1
    }
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if [[ "$expires" < "$now" ]]; then
        echo "Error: the provisioning profile expired on $expires"
        exit 1
    fi
    if [ "$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.cross-architecture-support' \
            "$LOADER_PLIST" 2>/dev/null)" != true ]; then
        echo "Error: the provisioning profile does not grant"
        echo "com.apple.developer.cross-architecture-support"
        exit 1
    fi
    LOADER_TEAM=$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$LOADER_PLIST" 2>/dev/null) || {
        echo "Error: the provisioning profile names no TeamIdentifier"
        exit 1
    }
    appid=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' \
            "$LOADER_PLIST" 2>/dev/null) || {
        echo "Error: the provisioning profile grants no com.apple.application-identifier"
        exit 1
    }
    LOADER_BUNDLE_ID=${appid#"$LOADER_TEAM".}
    if [ -z "$LOADER_TEAM" ] || [ "$LOADER_BUNDLE_ID" = "$appid" ]; then
        echo "Error: the application identifier $appid does not start with the team $LOADER_TEAM"
        exit 1
    fi
    # The identity is picked by SHA-1 rather than by name, since several
    # certificates can share a name: the first valid one of the profile's
    # team that is also one of the certificates the profile lists, since
    # macOS rejects the profile for a signature by any other.
    certs=""
    i=0
    while cert=$(plutil -extract "DeveloperCertificates.$i" raw -o - "$LOADER_PLIST" 2>/dev/null); do
        certs="$certs $(printf '%s' "$cert" | base64 --decode | shasum -a 1 | cut -d' ' -f1 | tr a-f A-F)"
        i=$((i + 1))
    done
    LOADER_IDENTITY=""
    for id in $(security find-identity -v -p codesigning \
                | awk -v team="($LOADER_TEAM)\"" 'index($0, team) { print $2 }'); do
        if in_list "$id" "$certs"; then
            LOADER_IDENTITY=$id
            break
        fi
    done
    if [ -z "$LOADER_IDENTITY" ]; then
        echo "Error: no valid code signing identity of team $LOADER_TEAM in the keychain"
        echo "is among the certificates the provisioning profile lists"
        exit 1
    fi
    LOADER_IDENTITY_NAME=$(security find-identity -v -p codesigning \
        | awk -v id="$LOADER_IDENTITY" '$2 == id { sub(/^[^"]*"/, ""); sub(/"$/, ""); print; exit }')
    echo "  Loader: $LOADER_BUNDLE_ID, signed by $LOADER_IDENTITY_NAME (profile expires $expires)."
}

# The entitlements the loader claims on top of the profile's, for the hardened
# runtime, which notarization and Mach9's install verification require. Each
# lifts a restriction of the runtime that Wine runs into:
#   cs.allow-jit                      FEX's code buffers are MAP_JIT memory
#                                     (MEM_EXTENDED_PARAMETER_WINE_UNIX_JIT)
#   cs.disable-executable-page-protection
#                                     ntdll gives anonymous memory an
#                                     executable protection (VirtualAlloc and
#                                     VirtualProtect with PAGE_EXECUTE_*), and
#                                     Windows code expects a
#                                     PAGE_EXECUTE_READWRITE page to be
#                                     writable and executable at once. It
#                                     covers what
#                                     cs.allow-unsigned-executable-memory
#                                     would allow, so that one is not claimed
#   cs.disable-library-validation     the unix modules, Homebrew's dylibs and
#                                     FEX's unixlibs are signed ad hoc, not by
#                                     the loader's team
#   device.audio-input                winecoreaudio's capture devices (voice
#                                     chat); the runtime denies the microphone
#                                     without it. Info.plist carries the
#                                     NSMicrophoneUsageDescription macOS
#                                     requires once the loader is the process
#                                     the microphone prompt is for; without it
#                                     macOS kills the process on access
# On macOS 27 a process with the cross-architecture entitlement runs Wine and
# FEX with only library validation disabled, but the first two are what
# Apple documents for what Wine does, and they keep it running if that
# relaxation goes. Not claimed: device.camera (this Wine has no video capture
# on macOS) and cs.allow-dyld-environment-variables (nothing in the bundle
# uses DYLD_* variables; the libraries are found through @loader_path).
LOADER_RUNTIME_ENTITLEMENTS="com.apple.security.cs.allow-jit
com.apple.security.cs.disable-executable-page-protection
com.apple.security.cs.disable-library-validation
com.apple.security.device.audio-input"

# package_loader: wrap the loader `make install` left in lib/wine/<unix>/wine
# into wine.app and sign it. Hadron's layout:
#   lib/wine/<unix>/wine.app/Contents/{MacOS/wine, Info.plist, embedded.provisionprofile}
#   lib/wine/<unix>/wine -> wine.app/Contents/MacOS/wine   (what ntdll execs)
#   bin/wine -> ../lib/wine/<unix>/wine.app/Contents/MacOS/wine
# The app is signed as a whole, without --deep (nothing inside it is code but
# the loader), with the hardened runtime and, unless LOADER_TIMESTAMP=0, a
# secure timestamp from Apple's server.
package_loader() {
    local app="$unixdir/wine.app" ents="$TMP_DIR/loader-entitlements.plist" version key
    if [ ! -f "$unixdir/wine" ] || [ -L "$unixdir/wine" ]; then
        echo "Error: no loader binary at $UNIX_DIR/wine"
        exit 1
    fi
    version=$("$unixdir/wine" --version 2>/dev/null | sed 's/^wine-//')
    [ -n "$version" ] || version=0
    mkdir -p "$app/Contents/MacOS"
    mv "$unixdir/wine" "$app/Contents/MacOS/wine"
    cp "$LOADER_PROFILE" "$app/Contents/embedded.provisionprofile"
    # Named Mach9, the launcher that runs this Wine: macOS shows the running
    # executable's bundle in the app menu, and a game process runs wine.app's
    # executable. The category and the Game Mode keys match Mach9's own
    # Info.plist, so a game the launcher starts gets Game Mode.
    cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>wine</string>
    <key>CFBundleIdentifier</key>
    <string>$LOADER_BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>Mach9</string>
    <key>CFBundleDisplayName</key>
    <string>Mach9</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.games</string>
    <key>LSSupportsGameMode</key>
    <true/>
    <key>GCSupportsGameMode</key>
    <true/>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$version</string>
    <key>CFBundleVersion</key>
    <string>$version</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MACOS_FLOOR</string>
    <key>NSPrincipalClass</key>
    <string>WineApplication</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>A Windows program running in Wine wants to record audio from the microphone.</string>
</dict>
</plist>
EOF
    ln -s wine.app/Contents/MacOS/wine "$unixdir/wine"
    rm -f "$WINE_DIR/bin/wine"
    ln -s "../lib/wine/$UNIX_DIR/wine.app/Contents/MacOS/wine" "$WINE_DIR/bin/wine"

    # Only what the loader needs: its identity and the cross-architecture
    # entitlement, all three granted by the profile, the custom x18 ABI,
    # which FEX needs because Windows code uses x18 as its TEB pointer, and
    # LOADER_RUNTIME_ENTITLEMENTS. Nothing else the profile allows (keychain
    # access groups) is claimed.
    rm -f "$ents"
    /usr/libexec/PlistBuddy \
        -c "Add :com.apple.application-identifier string $LOADER_TEAM.$LOADER_BUNDLE_ID" \
        -c "Add :com.apple.developer.team-identifier string $LOADER_TEAM" \
        -c 'Add :com.apple.developer.cross-architecture-support bool true' \
        -c 'Add :com.apple.security.custom-x18-abi-toggle bool true' \
        "$ents" >/dev/null
    for key in $LOADER_RUNTIME_ENTITLEMENTS; do
        /usr/libexec/PlistBuddy -c "Add :$key bool true" "$ents" >/dev/null
    done
    echo "    wine.app ($LOADER_BUNDLE_ID)"
    if ! codesign --force --options runtime "$(loader_timestamp_flag)" --sign "$LOADER_IDENTITY" \
            --entitlements "$ents" "$app"; then
        if [ "$LOADER_TIMESTAMP" = 1 ]; then
            echo "Error: signing wine.app failed; a secure timestamp needs Apple's timestamp"
            echo "server, so offline set LOADER_TIMESTAMP=0 (the result cannot be notarized)"
        else
            echo "Error: signing wine.app failed"
        fi
        exit 1
    fi
}

# loader_timestamp_flag: the codesign option for LOADER_TIMESTAMP.
loader_timestamp_flag() {
    if [ "$LOADER_TIMESTAMP" = 1 ]; then echo --timestamp; else echo --timestamp=none; fi
}

# check_loader_app: fail unless wine.app carries a valid signature by the
# profile's team with the entitlements package_loader gave it, and both entry
# points lead to it.
check_loader_app() {
    local app="$unixdir/wine.app" info signed="$TMP_DIR/signed-entitlements.plist" key want got pair
    if ! codesign --verify --strict "$app" 2>"$TMP_DIR/codesign.log"; then
        echo "Error: wine.app does not verify:"
        cat "$TMP_DIR/codesign.log"
        exit 1
    fi
    info=$(codesign -dvv "$app" 2>&1)
    if ! grep -qxF "Authority=$LOADER_IDENTITY_NAME" <<< "$info" \
        || ! grep -qxF "TeamIdentifier=$LOADER_TEAM" <<< "$info"; then
        echo "Error: wine.app is not signed by $LOADER_IDENTITY_NAME:"
        echo "$info"
        exit 1
    fi
    if ! grep -q '^CodeDirectory.*flags=.*runtime' <<< "$info"; then
        echo "Error: wine.app is not signed with the hardened runtime"
        exit 1
    fi
    if [ "$LOADER_TIMESTAMP" = 1 ] && ! grep -q '^Timestamp=' <<< "$info"; then
        echo "Error: wine.app's signature has no secure timestamp"
        exit 1
    fi
    codesign -d --entitlements - --xml "$app" > "$signed" 2>/dev/null
    # Exactly the set package_loader wrote: nothing missing, nothing extra.
    want=$(printf '%s\n' com.apple.application-identifier com.apple.developer.team-identifier \
               com.apple.developer.cross-architecture-support com.apple.security.custom-x18-abi-toggle \
               $LOADER_RUNTIME_ENTITLEMENTS | sort)
    got=$(/usr/libexec/PlistBuddy -c Print "$signed" 2>/dev/null \
              | sed -n 's/^    \([^ ]*\) = .*/\1/p' | sort)
    if [ "$got" != "$want" ]; then
        echo "Error: wine.app's entitlements are not the expected set:"
        diff <(echo "$want") <(echo "$got") | sed 's/^/    /'
        exit 1
    fi
    for key in com.apple.developer.cross-architecture-support com.apple.security.custom-x18-abi-toggle \
               $LOADER_RUNTIME_ENTITLEMENTS; do
        if [ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$signed" 2>/dev/null)" != true ]; then
            echo "Error: wine.app's signature does not set $key to true"
            exit 1
        fi
    done
    if [ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$signed" 2>/dev/null)" \
            != "$LOADER_TEAM.$LOADER_BUNDLE_ID" ]; then
        echo "Error: wine.app's application identifier is not $LOADER_TEAM.$LOADER_BUNDLE_ID"
        exit 1
    fi
    if [ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$signed" 2>/dev/null)" \
            != "$LOADER_TEAM" ]; then
        echo "Error: wine.app's team identifier is not $LOADER_TEAM"
        exit 1
    fi
    if [ "$(readlink "$WINE_DIR/bin/wine")" != "../lib/wine/$UNIX_DIR/wine.app/Contents/MacOS/wine" ] \
        || [ "$(readlink "$unixdir/wine")" != "wine.app/Contents/MacOS/wine" ]; then
        echo "Error: bin/wine and $UNIX_DIR/wine must be the symlinks into wine.app"
        exit 1
    fi
    # The Mach9 keys package_loader writes; the signature binds Info.plist,
    # which the strict verification above checks.
    for pair in CFBundleName=Mach9 CFBundleDisplayName=Mach9 \
                LSApplicationCategoryType=public.app-category.games \
                LSSupportsGameMode=true GCSupportsGameMode=true; do
        if [ "$(/usr/libexec/PlistBuddy -c "Print :${pair%%=*}" "$app/Contents/Info.plist" 2>/dev/null)" \
                != "${pair#*=}" ]; then
            echo "Error: wine.app's Info.plist does not set ${pair%%=*} to ${pair#*=}"
            exit 1
        fi
    done
    echo "  wine.app is named Mach9 and supports Game Mode."
    if [ "$LOADER_TIMESTAMP" = 1 ]; then
        echo "  wine.app is signed by $LOADER_IDENTITY_NAME with the hardened runtime, a secure timestamp"
    else
        echo "  wine.app is signed by $LOADER_IDENTITY_NAME with the hardened runtime, no secure timestamp"
        echo "  (LOADER_TIMESTAMP=0: it cannot be notarized)"
    fi
    echo "  and the cross-architecture entitlement."
}

# The bundle's dylibs, for both a full bundle and --compatdb-only, whose
# smoke test reads them too.
EXT_DIR="$WINE_DIR/lib/external"

# ── compatdb-only: replace compatdb.so in an existing bundle ────────────
# For a change confined to the compatdb/ crate. Nothing is wiped, nothing is
# prompted for and nothing is read from $BUILD_DIR except cargo's target dir,
# so this works on any existing arm64 bundle, one this script built or one
# unpacked there.
if [ "$COMPATDB_ONLY" -eq 1 ]; then
    if [ ! -x "$WINE_DIR/bin/wine" ]; then
        echo "Error: no bundle at $WINE_DIR (--compatdb-only updates an existing"
        echo "arm64 bundle; build or unpack one there first)"
        exit 1
    fi
    check_vulkan_present
    check_hybrid_markers
    check_compat_hooks

    echo "==> Step 1: Build compatdb.so"
    build_compatdb

    # Same reason as Step 4f of a full bundle. A freshly linked file normally
    # carries no quarantine, so only remove it when it is there.
    echo "==> Step 2: Remove inherited quarantine"
    if xattr -p com.apple.quarantine "$unixdir/compatdb.so" >/dev/null 2>&1; then
        xattr -d com.apple.quarantine "$unixdir/compatdb.so"
    fi

    echo "==> Step 3: Verify"
    if ! cmp -s "$COMPATDB_BUILD" "$unixdir/compatdb.so"; then
        echo "Error: $UNIX_DIR/compatdb.so does not match the build output"
        exit 1
    fi
    echo "  compatdb.so: $(file -b "$unixdir/compatdb.so")"
    LEAKED=0
    check_no_leaks "$unixdir/compatdb.so"
    if [ $LEAKED -ne 0 ]; then
        echo "Error: compatdb.so is not self-contained"
        exit 1
    fi
    # Only compatdb.so: the rest of the bundle was not built here, and keeps
    # whatever floor it was built for.
    check_minos "$unixdir/compatdb.so"
    smoke_test

    echo ""
    echo "==> Done! compatdb.so updated in:"
    echo "    $WINE_DIR/"
    exit 0
fi

# ── Preflight ───────────────────────────────────────────────────────────
# What a full bundle needs beyond the Wine build, checked before Step 0
# deletes anything.
time_mark "Preflight"
echo "==> Preflight"
check_sdk_floor
check_deps_formulae
check_fex_build
check_wine_sdk
check_dxmt_build
check_vkd3d_proton_build
check_mesa_build
for arch in $SMOKE_PE_ARCHS x86_64 i686; do
    if [ ! -x "$MINGW_DIR/bin/$arch-w64-mingw32-clang" ]; then
        echo "Error: no $arch-w64-mingw32-clang in $MINGW_DIR/bin (the smoke test needs it)"
        exit 1
    fi
done
for tool in llvm-strip llvm-objdump; do
    if [ ! -x "$MINGW_DIR/bin/$tool" ]; then
        echo "Error: no $tool in $MINGW_DIR/bin (Step 4e needs it)"
        exit 1
    fi
done
if [ ! -x "$MINGW_DIR/bin/llvm-readobj" ]; then
    echo "Error: no llvm-readobj in $MINGW_DIR/bin (Step 4 needs it to tell ARM64X DLLs for the markers)"
    exit 1
fi
loader_preflight

time_mark "Step 0: Clean previous bundle"
# ── Step 0: Clean previous bundle ──────────────────────────────────────
# The bundle ships, so it carries no tree marker. Only a directory that looks
# like a bundle, one with a bin/wine, is offered for deletion. make install
# writes the tree under <dest>/<INSTALL_PREFIX>, which Step 2 moves away and
# then removes, so that directory must not be there already.
INSTALL_TOP="${INSTALL_PREFIX#/}"
INSTALL_TOP="${INSTALL_TOP%%/*}"
if [ -e "$DIST_DIR/$INSTALL_TOP" ]; then
    echo "Error: $DIST_DIR/$INSTALL_TOP exists and the staged install would go into it;"
    echo "remove it first if an interrupted run left it"
    exit 1
fi
if [ -d "$WINE_DIR" ]; then
    if [ ! -e "$WINE_DIR/bin/wine" ] && [ ! -L "$WINE_DIR/bin/wine" ] \
        && [ -n "$(ls -A "$WINE_DIR")" ]; then
        echo "Error: $WINE_DIR is not empty and has no bin/wine; not deleting what is not a bundle"
        exit 1
    fi
    echo "Will delete existing bundle: $WINE_DIR"
    if [ "$ASSUME_YES" -eq 0 ]; then
        read -r -p "Continue? [y/N] " confirm
        case "$confirm" in
            [yY]) ;;
            *) echo "Aborted."; exit 1 ;;
        esac
    fi
    remove_tree "$WINE_DIR"
fi
# The previous bundle's symbols go too, so a run that fails before Step 4e,
# or one without --symbols, cannot leave them next to a bundle they do not
# belong to.
if [ "$WITH_SYMBOLS" -eq 1 ]; then
    claim_tree "$SYMBOLS_DIR" symbols 1
elif [ -e "$SYMBOLS_DIR" ]; then
    claim_tree "$SYMBOLS_DIR" symbols 1
    remove_tree "$SYMBOLS_DIR"
fi
mkdir -p "$DIST_DIR"

# ── Step 1: Staged install ──────────────────────────────────────────────
time_mark "Step 1: Staged install"
cd "$BUILD_DIR"
if [ "$RUNTIME_ONLY" -eq 1 ]; then
    echo "==> Step 1: Staged install (runtime only)"
    make install-lib DESTDIR="$DIST_DIR"
else
    echo "==> Step 1: Staged install with DESTDIR"
    make install DESTDIR="$DIST_DIR"
fi

# ── Step 2: Flatten prefix ──────────────────────────────────────────────
time_mark "Step 2: Flatten prefix"
echo "==> Step 2: Flatten prefix"
mv "$DIST_DIR$INSTALL_PREFIX" "$WINE_DIR"
# Left behind is the empty parent of the prefix (/usr of /usr/local), unless
# a Finder window showing <dest> put a .DS_Store into it.
rm -f "$DIST_DIR/$INSTALL_TOP/.DS_Store"
rmdir "$DIST_DIR/$INSTALL_TOP"

# ── Step 2c: x86_64 link libraries ─────────────────────────────────────
# A full bundle carries Wine's link libraries, so it can serve as the Wine
# SDK of PE code built against it. `make install` puts those of the build's
# own PE architectures in place; the x86_64 ones, which an arm64 Wine cannot
# build, come from the Wine SDK build-wine.sh staged, so the bundle offers
# the same set as that SDK. The directory holds nothing else and nothing
# reads it at run time: on an arm64 host ntdll looks for an x64 builtin in
# aarch64-windows, and the loader and setupapi's fake-DLL install only pick
# .dll and .exe files that are PE images.
if [ "$RUNTIME_ONLY" -eq 0 ]; then
    time_mark "Step 2c: x86_64 link libraries"
    echo "==> Step 2c: x86_64 link libraries"
    mkdir -p "$WINE_DIR/lib/wine/x86_64-windows"
    for lib in "$WINE_SDK_DIR"/lib/wine/x86_64-windows/*.a; do
        echo "    x86_64-windows/$(basename "$lib")"
        cp "$lib" "$WINE_DIR/lib/wine/x86_64-windows/"
    done
fi

# ── Step 2d: Graphics tests ─────────────────────────────────────────────
# Wine's graphics conformance tests (GRAPHICS_TESTS in profile.sh), x86 code
# for i386 and x86_64, from the Wine SDK, so the bundle's Direct3D, OpenGL
# and Vulkan stack can be tested with nothing but the bundle. `make install`
# installs no tests. They go into lib/wine/tests/<pe-dir>/ under the name of
# their own machine, x86_64-windows and not PE64_DIR, where the 64-bit
# builtins live: plain executables that Wine runs by path, outside the
# directories it searches for modules. Development files only, like the
# link libraries. tests/VERSION, the `wine --version` string of the Wine they
# were built from, goes with them, so the directory taken alone still names
# its build; Step 5 checks it against this bundle's wine.
if [ "$RUNTIME_ONLY" -eq 0 ]; then
    time_mark "Step 2d: Graphics tests"
    echo "==> Step 2d: Graphics tests"
    for pe in $TEST_PE_DIRS; do
        mkdir -p "$WINE_DIR/lib/wine/tests/$pe"
        for t in $(graphics_tests "$pe"); do
            echo "    tests/$pe/${t}_test.exe"
            cp "$WINE_SDK_DIR/lib/wine/tests/$pe/${t}_test.exe" "$WINE_DIR/lib/wine/tests/$pe/"
        done
    done
    echo "    tests/VERSION"
    cp "$WINE_SDK_DIR/lib/wine/tests/VERSION" "$WINE_DIR/lib/wine/tests/"
fi

# ── Step 3: Bundle dynamic libraries ────────────────────────────────────
# Wine's .so modules dlopen these via @loader_path sonames (patched by
# build-wine.sh). Transitive deps are loaded by dyld from their @loader_path
# install names.
time_mark "Step 3: Bundle dynamic libraries"
echo "==> Step 3: Bundle dynamic libraries"
mkdir -p "$EXT_DIR"

# Direct deps: Wine dlopen's these by soname. build-wine.sh patches their
# sonames in config.h to @loader_path/../../external/<name>, so config.h is
# the authoritative (version-correct) list; resolve each against
# $DEPS_PREFIX/lib, except the Vulkan loader and EGL, which build-mesa.sh
# built for the floor into MESA_DIST. Deduplicated, since one library can
# back several defines.
CONFIG_H="$BUILD_DIR/include/config.h"
if [ ! -f "$CONFIG_H" ]; then
    echo "Error: $CONFIG_H not found (run build-wine.sh first)"
    exit 1
fi
LIBS=()
for name in $(sed -n 's|.*"@loader_path/\.\./\.\./external/\([^"]*\)".*|\1|p' "$CONFIG_H" | sort -u); do
    case "$name" in
        libvulkan.*|libEGL.*) LIBS+=("$MESA_DIST/lib/$name") ;;
        *) LIBS+=("$DEPS_PREFIX/lib/$name") ;;
    esac
done
if [ ${#LIBS[@]} -eq 0 ]; then
    echo "Error: no @loader_path sonames in $CONFIG_H: the build is not"
    echo "relocatable (config.h lost its soname patches). Re-run build-wine.sh."
    exit 1
fi
# Homebrew's "libSDL2" is sdl2-compat, a shim that loads real SDL3 at runtime
# via @loader_path/libSDL3.dylib, so SDL3 must sit beside it in the bundle.
LIBS+=("$DEPS_PREFIX/lib/libSDL3.dylib")
# The Vulkan driver, which the loader opens by the path in its manifest
# (Step 3c). It loads system libraries only, so the walk below adds nothing
# for it or the loader, and the install name and signature steps treat both
# like the rest.
LIBS+=("$MESA_DIST/lib/libvulkan_kosmickrisp.dylib")
# Mesa's gallium library with Zink, which libEGL.1.dylib loads by
# @loader_path, a reference the walk below does not follow. It opens the
# Vulkan loader next to it, in lib/external.
LIBS+=("$MESA_DIST/lib/$MESA_GALLIUM")

echo "  Copying direct deps..."
MISSED=0
for lib in "${LIBS[@]}"; do
    name=$(basename "$lib")
    if [ -f "$lib" ]; then
        echo "    $name"
        cp -L "$lib" "$EXT_DIR/$name"
    else
        echo "    MISSING: $name from $lib"
        MISSED=1
    fi
done

# Transitive deps: walk the otool -L closure of the libraries where they are
# installed, copying every $DEPS_PREFIX dependency and every @rpath one, until
# no new ones appear. An @rpath dependency is found the way dyld finds it
# for the installed library, through that library's LC_RPATH entries
# (rpath_dep_source); Homebrew links some libraries that way, such as
# brotli's, whose libbrotlidec loads @rpath/libbrotlicommon.1.dylib with the
# entry @loader_path/../lib. The walk reads the originals because those
# entries only resolve from there. Line 2 of otool -L is the dylib's own
# install name, not a dependency, so skip it.
echo "  Copying transitive deps..."
WALK=("${LIBS[@]}")
i=0
while [ $i -lt ${#WALK[@]} ]; do
    src="${WALK[$i]}"
    i=$((i + 1))
    # A direct dep that is missing was reported above.
    [ -f "$src" ] || continue
    for dep in $(otool -L "$src" | tail -n +3 | awk '{print $1}'); do
        case "$dep" in
            "$DEPS_PREFIX"/*) depsrc="$dep" ;;
            @rpath/*) depsrc=$(rpath_dep_source "$dep" "$src") ;;
            *) continue ;;
        esac
        depname=$(basename "$dep")
        if [ -f "$EXT_DIR/$depname" ]; then
            :
        elif [ -f "$depsrc" ]; then
            echo "    $depname (needed by $(basename "$src"))"
            cp -L "$depsrc" "$EXT_DIR/$depname"
            WALK+=("$depsrc")
        else
            echo "    MISSING: $depname (needed by $(basename "$src")) from $depsrc"
            MISSED=1
        fi
    done
done
if [ $MISSED -ne 0 ]; then
    echo "Error: required libraries are missing, bundle would not be self-contained"
    exit 1
fi
chmod +w "$EXT_DIR"/*.dylib

# Fix install names so bundled dylibs reference each other via @loader_path,
# the @rpath ones included. Then drop every LC_RPATH entry that does not
# name a directory inside the bundle, such as Homebrew's @loader_path/../lib,
# which from lib/external would point at the bundle's parent or at nothing,
# so that nothing is looked up outside the bundle through them.
echo "  Fixing install names..."
for dylib in "$EXT_DIR"/*.dylib; do
    name=$(basename "$dylib")
    install_name_tool -id "@loader_path/$name" "$dylib"
    for dep in $(otool -L "$dylib" | tail -n +2 | awk '{print $1}'); do
        case "$dep" in
            "$DEPS_PREFIX"/*|@rpath/*)
                depname=$(basename "$dep")
                if [ -f "$EXT_DIR/$depname" ]; then
                    install_name_tool -change "$dep" "@loader_path/$depname" "$dylib"
                fi
                ;;
        esac
    done
    for rp in $(rpath_entries "$dylib"); do
        case "$rp" in
            @loader_path|@loader_path/*)
                if dir_in_bundle "$EXT_DIR${rp#@loader_path}"; then continue; fi
                ;;
        esac
        echo "    $name: dropping the LC_RPATH entry $rp"
        install_name_tool -delete_rpath "$rp" "$dylib"
    done
done

# install_name_tool breaks the signature Homebrew's linker gave each dylib,
# and arm64 code with a broken signature is killed on load. An ad-hoc
# signature is enough for a library the signed loader loads: the loader runs
# with library validation disabled (LOADER_RUNTIME_ENTITLEMENTS).
echo "  Re-signing the relinked dylibs ad hoc..."
for dylib in "$EXT_DIR"/*.dylib; do
    codesign --force --sign - "$dylib" 2>/dev/null
done

# ── Step 3b: Remove Wine's D3D12 ────────────────────────────────────────
# Wine's own D3D12 (d3d12.dll and d3d12core.dll, on vkd3d) is never shipped.
# D3D12 comes from vkd3d-proton instead, whose DLLs Step 4 puts into the
# dxmt tree, next to DXMT's dxgi.dll, which presents its swapchains. The
# wined3d tree has no D3D12, so under dxgi=wined3d d3d12.dll does not load.
# d3d10core stays: the Direct3D trees of Step 4 take it over.
time_mark "Step 3b: D3D12 removal"
echo "==> Step 3b: Remove Wine's D3D12"
DEAD=(i386-windows/d3d12.dll i386-windows/d3d12core.dll
      "$PE64_DIR/d3d12.dll" "$PE64_DIR/d3d12core.dll")
for dead in "${DEAD[@]}"; do
    if [ -e "$WINE_DIR/lib/wine/$dead" ]; then
        echo "    $dead"
        rm -f "$WINE_DIR/lib/wine/$dead"
    fi
done

# ── Step 3c: Vulkan driver manifest ─────────────────────────────────────
# The loader finds KosmicKrisp through its manifest in share/vulkan/icd.d,
# the directory ntdll names in VK_DRIVER_FILES unless the caller set that
# variable. The manifest build-mesa.sh staged names the driver relative to
# MESA_DIST's layout; here it is pointed at lib/external, again relative to
# the manifest, which is how the loader reads a relative library_path, so the
# bundle stays relocatable.
time_mark "Step 3c: Vulkan driver manifest"
echo "==> Step 3c: Vulkan driver manifest"
ICD_DIR="$WINE_DIR/share/vulkan/icd.d"
ICD="$ICD_DIR/kosmickrisp_mesa_icd.aarch64.json"
ICD_LIBRARY=../../../lib/external/libvulkan_kosmickrisp.dylib
mkdir -p "$ICD_DIR"
cp "$MESA_DIST/share/vulkan/icd.d/$(basename "$ICD")" "$ICD"
plutil -replace ICD.library_path -string "$ICD_LIBRARY" "$ICD"
if [ "$(plutil -extract ICD.library_path raw -o - "$ICD")" != "$ICD_LIBRARY" ]; then
    echo "Error: $(basename "$ICD") does not name $ICD_LIBRARY after rewriting it"
    exit 1
fi
echo "    share/vulkan/icd.d/$(basename "$ICD") -> $ICD_LIBRARY"

# ── Step 4: Direct3D backends ───────────────────────────────────────────
# Direct3D comes from third-party implementations that talk to Metal
# directly, plus Wine's own wined3d as the fallback for each: DXMT for D3D10
# and D3D11, and mtld3d for D3D9. D3D12 is vkd3d-proton on Vulkan, in the
# dxmt tree only, with no wined3d fallback. The trees are DXGI_IMPLS and
# D3D9_IMPLS in profile.sh. Every one lives in its own tree under
# lib/wine/dxgi/<impl> or lib/wine/d3d9/<impl>, with <pe64>-windows,
# i386-windows and, where it has a unix half, <unix> subdirectories; the
# default dirs hold only fake-module markers, and compatdb.so (Step 4b)
# picks one tree per family per process.
# D3D8 and DDraw stay on wined3d only. Nothing below rewrites install names,
# re-signs, or walks the otool closure.
time_mark "Step 4: Direct3D backends"
echo "==> Step 4: Direct3D backends"

# Every download is fetched (or taken from the cache) before anything is
# installed, so a bad pin fails the run before the tree is half-modified.
# DXMT and vkd3d-proton are what build-dxmt.sh and build-vkd3d-proton.sh
# staged, as the preflight checked.
echo "  Fetching artifacts into $CACHE_DIR..."
if in_list mtld3d "$D3D9_IMPLS"; then
    MTLD3D_TAR=$(fetch "$MTLD3D_URL" "$MTLD3D_SHA256")
fi

WINEBUILD="$BUILD_DIR/tools/winebuild/winebuild"
d3d64="$WINE_DIR/lib/wine/$PE64_DIR"
d3d32="$WINE_DIR/lib/wine/i386-windows"
tree="$WINE_DIR/lib/wine/dxgi"
d3d9tree="$WINE_DIR/lib/wine/d3d9"

# wined3d (both arches): Wine's own dxgi/d3d10/d3d10core/d3d11/d3d10_1 from the
# build tree. No d3d12 (Step 3b); wined3d.dll itself stays in the default dir
# (the engine, shared, reached by fall-through).
if in_list wined3d "$DXGI_IMPLS"; then
    echo "  Building dxgi/wined3d from the Wine build..."
    for arch in i386-windows "$PE64_DIR"; do
        dest="$tree/wined3d/$arch"
        mkdir -p "$dest"
        for dll in dxgi d3d10 d3d10core d3d11 d3d10_1; do
            src="$BUILD_DIR/dlls/$dll/$arch/$dll.dll"
            if [ ! -f "$src" ]; then
                echo "Error: $src not found (run build-wine.sh first)"
                exit 1
            fi
            cp "$src" "$dest/"
        done
    done
fi

if in_list dxmt "$DXGI_IMPLS"; then
    # What build-dxmt.sh staged in DXMT_DIST, as the preflight checked.
    echo "  Installing DXMT..."
    echo "    $DXMT_DIST"

    # dxmt tree: DXMT's dxgi/d3d10core/d3d11/winemetal plus Wine's
    # d3d10/d3d10_1, for both arches. DXMT's 64-bit DLLs are ARM64X, like
    # Wine's in that directory, and go into the 64-bit dir, aarch64-windows,
    # where an x64 process (run as ARM64EC) and a native ARM64 one both look
    # for them. The single winemetal.so stays in the default unix dir, where
    # its @rpath finds winemac.so and ntdll.so, and serves the i386 PE
    # modules too through its wow64 entry points; the tree links to it.
    dx64="$tree/dxmt/$PE64_DIR"
    dxu="$tree/dxmt/$UNIX_DIR"
    dx32="$tree/dxmt/i386-windows"
    mkdir -p "$dx64" "$dxu" "$dx32"
    cp "$DXMT_DIST/$UNIX_DIR/winemetal.so" "$unixdir/"
    cp "$DXMT_DIST/$PE64_DIR/dxgi.dll" \
       "$DXMT_DIST/$PE64_DIR/d3d10core.dll" \
       "$DXMT_DIST/$PE64_DIR/d3d11.dll" \
       "$DXMT_DIST/$PE64_DIR/winemetal.dll" \
       "$dx64/"
    cp "$BUILD_DIR/dlls/d3d10/$PE64_DIR/d3d10.dll"     "$dx64/"
    cp "$BUILD_DIR/dlls/d3d10_1/$PE64_DIR/d3d10_1.dll" "$dx64/"
    ln -sf "../../../$UNIX_DIR/winemetal.so" "$dxu/winemetal.so"
    cp "$DXMT_DIST"/i386-windows/dxgi.dll \
       "$DXMT_DIST"/i386-windows/d3d10core.dll \
       "$DXMT_DIST"/i386-windows/d3d11.dll \
       "$DXMT_DIST"/i386-windows/winemetal.dll \
       "$dx32/"
    cp "$BUILD_DIR/dlls/d3d10/i386-windows/d3d10.dll"     "$dx32/"
    cp "$BUILD_DIR/dlls/d3d10_1/i386-windows/d3d10_1.dll" "$dx32/"

    # D3D12 in the same tree: vkd3d-proton's d3d12/d3d12core, ARM64X and
    # i386 like DXMT's, as build-vkd3d-proton.sh staged them in
    # VKD3D_PROTON_DIST. A D3D12 game creates its swapchain through this
    # tree's dxgi.dll, which presents vkd3d-proton's Vulkan swapchain, so the
    # two only work together and never go into the wined3d tree.
    echo "  Installing vkd3d-proton..."
    echo "    $VKD3D_PROTON_DIST"
    cp "$VKD3D_PROTON_DIST/$PE64_DIR/d3d12.dll" \
       "$VKD3D_PROTON_DIST/$PE64_DIR/d3d12core.dll" \
       "$dx64/"
    cp "$VKD3D_PROTON_DIST"/i386-windows/d3d12.dll \
       "$VKD3D_PROTON_DIST"/i386-windows/d3d12core.dll \
       "$dx32/"
fi

# D3D9, the second family: mtld3d and Wine's own. mtld3d's d3d9.dll bridges
# to its mtld3d.dll, whose unix half is a single mtld3d.so that also serves
# the i386 PE through its wow64 entry points. wined3d's d3d9.dll needs only
# wined3d.dll, which stays in the default dir.
if in_list mtld3d "$D3D9_IMPLS"; then
    # mtld3d's tarball mirrors the lib/wine layout under wine/, with an
    # x86_64-unix and an aarch64-unix mtld3d.so; the one for UNIX_DIR is
    # taken. It carries x86_64 and ARM64X builds of the 64-bit PE DLLs; the
    # ARM64X ones, in its aarch64-windows, go into the 64-bit dir, like
    # DXMT's, so an x64 game loads their ARM64EC half and a native ARM64
    # program their ARM64 half, and compatdb.so gives both mtld3d. They have
    # to be ARM64X for that, which check_trees_arm64x checks with every
    # other tree before the markers are stamped. Its x86_64 builds are not
    # used. The tarball's prefix-markers/ holds the system32, system32-arm64
    # and syswow64 placeholders for installs into an existing prefix and is
    # not used either: the prefixes this bundle creates get their markers
    # from wine.inf's wildcard over the default dirs (stamped below).
    echo "  Installing mtld3d..."
    mkdir -p "$TMP_DIR/mtld3d"
    tar xf "$MTLD3D_TAR" -C "$TMP_DIR/mtld3d"
    MTLD3D_SRC="$TMP_DIR/mtld3d/wine"
    if [ ! -d "$MTLD3D_SRC" ]; then
        echo "Error: $(basename "$MTLD3D_TAR") has no wine/ directory"
        exit 1
    fi
    for arch in i386-windows "$PE64_DIR"; do
        for dll in d3d9 mtld3d; do
            if [ ! -f "$MTLD3D_SRC/$arch/$dll.dll" ]; then
                echo "Error: $(basename "$MTLD3D_TAR") has no $arch/$dll.dll"
                exit 1
            fi
        done
        mkdir -p "$d3d9tree/mtld3d/$arch"
        cp "$MTLD3D_SRC/$arch/d3d9.dll" "$MTLD3D_SRC/$arch/mtld3d.dll" \
           "$d3d9tree/mtld3d/$arch/"
    done
    mkdir -p "$d3d9tree/mtld3d/$UNIX_DIR"
    cp "$MTLD3D_SRC/$UNIX_DIR/mtld3d.so" "$d3d9tree/mtld3d/$UNIX_DIR/"
fi
if in_list wined3d "$D3D9_IMPLS"; then
    for arch in i386-windows "$PE64_DIR"; do
        mkdir -p "$d3d9tree/wined3d/$arch"
        src="$BUILD_DIR/dlls/d3d9/$arch/d3d9.dll"
        if [ ! -f "$src" ]; then
            echo "Error: $src not found (run build-wine.sh first)"
            exit 1
        fi
        cp "$src" "$d3d9tree/wined3d/$arch/"
    done
fi

# ── Direct3D: fake-module markers in the default dirs ───────────────────
# The default <arch>-windows dirs ship NO real Direct3D. compatdb.so always
# loads and prepends exactly one tree per family per process (the arch
# default, or a database override) via prepend_dll_path, so a DXGI stack is
# never mixed and nothing is ever removed. Every module any tree of a family
# supplies is therefore taken out of the default dir (Wine's own copies from
# `make install`) and replaced by a fake-module marker. wineboot's 11,,*
# wildcard stamps a system32/syswow64 placeholder for each, which is what
# lets the prepended tree supply the real DLL (a builtin will not load
# without its placeholder). Each marker is made with `--dll` naming the real
# DLL of the first tree in the order of DXGI_IMPLS or D3D9_IMPLS that has it,
# but winebuild does not copy that DLL's exports into a fake module: the
# marker has no export table, and none is needed, since the loader only
# checks that the placeholder is there and which machine it says before it
# loads the real DLL. In i386-windows every marker is i386. In the 64-bit
# dir the placeholder's machine decides which module the loader accepts, and
# one placeholder serves every process and every tree of the family:
#  - An x64 process, which runs as ARM64EC, accepts an AMD64 placeholder, and
#    an ARM64 one only when its load config carries ARM64EC (CHPE) metadata.
#    A native ARM64 process rejects an AMD64 placeholder with error 193.
#  - An AMD64 placeholder makes the loader take the x64 view of the real
#    module, an ARM64 one lets the view follow the main image, so behind an
#    ARM64 placeholder with that metadata an ARM64X module serves both kinds
#    of process, each from its own half.
# So every 64-bit name gets such a hybrid marker (winebuild -marm64x), and
# every 64-bit DLL of every tree has to be ARM64X, which check_trees_arm64x
# makes sure of first. An AMD64 marker, which a native ARM64 program cannot
# get past (docs/arm64.md, Limitations), is no longer stamped: compatdb.so
# gives native ARM64 programs these trees too. Step 5 checks every marker's
# machine. An arm64 winebuild has no default PE target, hence the explicit
# -b.
time_mark "Step 4: fake-module markers"
check_trees_arm64x
echo "  Stamping fake-module markers in the default dirs..."
mark() { # <out-dir> <arch-dir> <real-dll> <name>
    if [ "$2" = i386-windows ]; then
        "$WINEBUILD" --fake-module -o "$1/$4.dll" -b i686-windows --dll "$3"
    else
        "$WINEBUILD" --fake-module -o "$1/$4.dll" -b aarch64-windows -marm64x --dll "$3"
    fi
}
for family in dxgi d3d9; do
    impls=$(family_impls "$family")
    for arch in i386-windows "$PE64_DIR"; do
        if [ "$arch" = i386-windows ]; then default="$d3d32"; else default="$d3d64"; fi
        for dll in $(family_dlls "$family" "$arch"); do
            rm -f "$default/$dll.dll"
            for impl in $impls; do
                real="$WINE_DIR/lib/wine/$family/$impl/$arch/$dll.dll"
                if [ -f "$real" ]; then mark "$default" "$arch" "$real" "$dll"; break; fi
            done
        done
    done
done

# ── Step 4b: Compat database ────────────────────────────────────────────
# compatdb.so is what turns the trees above into a working Direct3D: ntdll
# dlopens <ntdll_dir>/compatdb.so in every process and the library prepends
# one dxgi/ and one d3d9/ tree, chosen per process from its built-in rules
# plus whatever WINE_COMPATDB carries. Built here from the compatdb/ crate
# for RUST_TARGET.
time_mark "Step 4b: Compat database"
echo "==> Step 4b: Compat database"
build_compatdb

# ── Step 4d: FEX ────────────────────────────────────────────────────────
# FEX as build-fex.sh staged it in FEX_DIST, as the preflight checked: its
# emulator DLLs and their unix halves. Wine loads its x86 emulators as
# xtajit.dll (i386 under WoW64) and xtajit64.dll (x86_64 as ARM64EC) unless
# the registry names others, so FEX's DLLs are installed under their own
# names and as those two, replacing the stubs `make install` put there.
time_mark "Step 4d: FEX"
echo "==> Step 4d: FEX"
echo "    $FEX_DIST"
fexpe="$FEX_DIST/$PE64_DIR"
fexunix="$FEX_DIST/$UNIX_DIR"
echo "    $PE64_DIR/libwow64fex.dll, xtajit.dll"
cp "$fexpe/libwow64fex.dll" "$WINE_DIR/lib/wine/$PE64_DIR/"
cp "$fexpe/libwow64fex.dll" "$WINE_DIR/lib/wine/$PE64_DIR/xtajit.dll"
echo "    $PE64_DIR/libarm64ecfex.dll, xtajit64.dll"
cp "$fexpe/libarm64ecfex.dll" "$WINE_DIR/lib/wine/$PE64_DIR/"
cp "$fexpe/libarm64ecfex.dll" "$WINE_DIR/lib/wine/$PE64_DIR/xtajit64.dll"
echo "    $UNIX_DIR/libwow64fex.so, libarm64ecfex.so"
cp "$fexunix/libwow64fex.so" "$fexunix/libarm64ecfex.so" "$unixdir/"

# ── Step 4e: Split off PE symbols ───────────────────────────────────────
# Wine, DXMT and FEX are built with DWARF debug info, and most PE files also
# carry a COFF symbol table. Together they make up more than half the size
# of the PE modules and only serve a debugger or the symbolizing of a crash
# report, so the bundle ships none of them. Every PE file under lib/wine is
# stripped of both here. With --symbols the unstripped copy of each stripped
# file goes to <dest>/wine-symbols (cleared in Step 0), next to the bundle,
# under the same relative path: an address in
# lib/wine/<arch>-windows/foo.dll is looked up in
# wine-symbols/lib/wine/<arch>-windows/foo.dll. The files are stripped in
# parallel batches (strip_pe), and errors are listed sorted by file once all
# are done. llvm-strip keeps the DOS stub, which holds Wine's builtin
# marker, and handles ARM64X images. It cannot read the symbol table GNU ld
# writes for some i386 DLLs; there the table and its strings, which end the
# file, are cut off instead (drop_coff_symtab). Step 5 checks that no PE
# file kept either.
time_mark "Step 4e: Split off PE symbols"
echo "==> Step 4e: Split off PE symbols"
# mtld3d's DLLs as installed, for Step 5's comparison with the release.
if in_list mtld3d "$D3D9_IMPLS"; then
    for arch in i386-windows "$PE64_DIR"; do
        mkdir -p "$TMP_DIR/installed/$arch"
        cp -p "$d3d9tree/mtld3d/$arch/d3d9.dll" "$d3d9tree/mtld3d/$arch/mtld3d.dll" "$TMP_DIR/installed/$arch/"
    done
fi
# Every PE file, in parallel batches.
STRIP_WORK="$TMP_DIR/strip"
STRIP_ERRORS="$TMP_DIR/strip-errors"
mkdir -p "$STRIP_WORK" "$STRIP_ERRORS"
export WINE_DIR MINGW_DIR SYMBOLS_DIR WITH_SYMBOLS STRIP_WORK STRIP_ERRORS
export -f strip_pe drop_coff_symtab coff_symtab
# pipefail in a subshell, so a failing find or perl stops the step instead
# of handing xargs an empty list.
(
    set -o pipefail
    find "$WINE_DIR/lib/wine" -type f ! -name '*.a' -print0 | pe_scan | cut -f1 \
        | while IFS= read -r f; do
              printf '%s\0' "${f#"$WINE_DIR"/}"
          done \
        | xargs -0 -n 32 -P "$(sysctl -n hw.ncpu)" /bin/bash -c 'strip_pe "$@"' _ > "$TMP_DIR/stripped.list"
)
if [ -n "$(ls "$STRIP_ERRORS")" ]; then
    for e in $(ls "$STRIP_ERRORS" | LC_ALL=C sort); do
        cat "$STRIP_ERRORS/$e"
    done
    exit 1
fi
split=$(wc -l < "$TMP_DIR/stripped.list" | tr -d ' ')
if [ "$WITH_SYMBOLS" -eq 1 ]; then
    echo "    $split PE files stripped, their symbols in $SYMBOLS_DIR"
else
    echo "    $split PE files stripped (--symbols keeps a copy with their symbols)"
fi

# ── Step 4f: Remove inherited quarantine ──────────────────────────────
# Extracting and copying the checksum-verified downloads can preserve
# download quarantine, which blocks libraries such as winemetal.so at load time.
# Clear only that attribute from the assembled bundle before running it. Keep
# signatures and other metadata intact; -s acts on symlinks themselves so this
# cannot change a target outside the bundle.
time_mark "Step 4f: Remove inherited quarantine"
echo "==> Step 4f: Remove inherited quarantine"
if ! xattr -drs com.apple.quarantine "$WINE_DIR"; then
    echo "Error: failed to remove inherited quarantine from $WINE_DIR" >&2
    exit 1
fi

# ── Step 4g: Loader app ─────────────────────────────────────────────────
# Last of all that touches the loader, so nothing changes the signed bundle
# after it is sealed.
time_mark "Step 4g: Loader app"
echo "==> Step 4g: Loader app"
package_loader

# ── Step 5: Verify ──────────────────────────────────────────────────────
time_mark "Step 5: library references"
echo "==> Step 5: Verify"

echo "  wine binary: $(file -L "$WINE_DIR/bin/wine" | sed 's|.*/||')"

# Check that no bundled dylib or .so module still loads from a prefix outside
# the bundle, the side-tree unix libs included (symlinks resolve to the real
# modules in the default unix dir, so this also proves the side-tree links
# are intact).
LEAKED=0
check_no_leaks "$EXT_DIR"/*.dylib
check_no_leaks "$unixdir"/*.so \
               "$WINE_DIR"/lib/wine/dxgi/*/"$UNIX_DIR"/*.so \
               "$WINE_DIR"/lib/wine/d3d9/*/"$UNIX_DIR"/*.so \
               "$unixdir/wine.app/Contents/MacOS/wine"
check_rpath_deps "$EXT_DIR"/*.dylib
if [ $LEAKED -ne 0 ]; then
    echo "Error: bundle is not self-contained"
    exit 1
fi
echo "  All binaries clean, no ${LEAK_PREFIXES// / or } references, no @rpath dependency outside the bundle."
# With nothing left that points outside the bundle, a library that loads
# has found every dependency inside it.
check_dylibs_load "$EXT_DIR"/*.dylib
echo "  Every dylib in lib/external loads."

# The Direct3D backends and everything else copied in rather than built,
# which nothing the build does would have caught.
time_mark "Step 5: copied-in components"
WANT=("lib/wine/$UNIX_DIR/compatdb.so"
      "lib/wine/$PE64_DIR/dxgi.dll" "lib/wine/i386-windows/dxgi.dll"
      "lib/wine/$PE64_DIR/d3d9.dll" "lib/wine/i386-windows/d3d9.dll"
      "lib/wine/$PE64_DIR/xtajit.dll" "lib/wine/$PE64_DIR/xtajit64.dll"
      "lib/wine/$PE64_DIR/libwow64fex.dll" "lib/wine/$PE64_DIR/libarm64ecfex.dll"
      "lib/wine/$UNIX_DIR/libwow64fex.so" "lib/wine/$UNIX_DIR/libarm64ecfex.so"
      "lib/external/libvulkan.1.dylib" "lib/external/libvulkan_kosmickrisp.dylib"
      "lib/external/libEGL.1.dylib" "lib/external/$MESA_GALLIUM"
      "share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json"
      "lib/wine/$UNIX_DIR/winevulkan.so"
      "lib/wine/$PE64_DIR/vulkan-1.dll" "lib/wine/$PE64_DIR/winevulkan.dll"
      "lib/wine/i386-windows/vulkan-1.dll" "lib/wine/i386-windows/winevulkan.dll"
      "lib/wine/$UNIX_DIR/wine.app/Contents/MacOS/wine"
      "lib/wine/$UNIX_DIR/wine.app/Contents/Info.plist"
      "lib/wine/$UNIX_DIR/wine.app/Contents/embedded.provisionprofile")
if in_list dxmt "$DXGI_IMPLS"; then
    WANT+=("lib/wine/$UNIX_DIR/winemetal.so"
           "lib/wine/dxgi/dxmt/$PE64_DIR/dxgi.dll"
           "lib/wine/dxgi/dxmt/$PE64_DIR/winemetal.dll"
           "lib/wine/dxgi/dxmt/$UNIX_DIR/winemetal.so"
           "lib/wine/dxgi/dxmt/i386-windows/dxgi.dll"
           "lib/wine/dxgi/dxmt/i386-windows/winemetal.dll"
           "lib/wine/dxgi/dxmt/$PE64_DIR/d3d12.dll"
           "lib/wine/dxgi/dxmt/$PE64_DIR/d3d12core.dll"
           "lib/wine/dxgi/dxmt/i386-windows/d3d12.dll"
           "lib/wine/dxgi/dxmt/i386-windows/d3d12core.dll")
fi
if in_list wined3d "$DXGI_IMPLS"; then
    WANT+=("lib/wine/dxgi/wined3d/$PE64_DIR/dxgi.dll"
           "lib/wine/dxgi/wined3d/$PE64_DIR/d3d10_1.dll"
           "lib/wine/dxgi/wined3d/i386-windows/dxgi.dll"
           "lib/wine/dxgi/wined3d/i386-windows/d3d10_1.dll")
fi
if in_list mtld3d "$D3D9_IMPLS"; then
    WANT+=("lib/wine/d3d9/mtld3d/$UNIX_DIR/mtld3d.so"
           "lib/wine/d3d9/mtld3d/i386-windows/mtld3d.dll"
           "lib/wine/d3d9/mtld3d/$PE64_DIR/mtld3d.dll")
fi
if in_list wined3d "$D3D9_IMPLS"; then
    WANT+=("lib/wine/d3d9/wined3d/i386-windows/d3d9.dll"
           "lib/wine/d3d9/wined3d/$PE64_DIR/d3d9.dll")
fi
if [ "$RUNTIME_ONLY" -eq 0 ]; then
    WANT+=("lib/wine/x86_64-windows/libwinecrt0.a" "lib/wine/x86_64-windows/libntdll.a")
    for pe in $TEST_PE_DIRS; do
        for t in $(graphics_tests "$pe"); do
            WANT+=("lib/wine/tests/$pe/${t}_test.exe")
        done
    done
    WANT+=("lib/wine/tests/VERSION")
fi
MISSING=0
for want in "${WANT[@]}"; do
    # -e follows symlinks, so this also proves the tree .so links resolve.
    if [ ! -e "$WINE_DIR/$want" ]; then
        echo "  ERROR: missing $want"
        MISSING=1
    fi
done
# A d3d9.dll named like mtld3d's could still be Wine's, and either DLL could
# be another build of the tarball's (its x86_64 one); only a byte comparison
# proves the right copy landed in the tree. Step 4e kept a copy of both as
# they were installed, before stripping.
if in_list mtld3d "$D3D9_IMPLS"; then
    for arch in i386-windows "$PE64_DIR"; do
        for dll in d3d9 mtld3d; do
            if ! cmp -s "$MTLD3D_SRC/$arch/$dll.dll" "$TMP_DIR/installed/$arch/$dll.dll"; then
                echo "  ERROR: d3d9/mtld3d/$arch/$dll.dll is not the release's $arch/$dll.dll"
                MISSING=1
            fi
        done
    done
fi
# The emulator Wine loads by default has to be FEX, not the stub it replaced.
for pair in libwow64fex:xtajit libarm64ecfex:xtajit64; do
    if ! cmp -s "$WINE_DIR/lib/wine/$PE64_DIR/${pair%%:*}.dll" \
                "$WINE_DIR/lib/wine/$PE64_DIR/${pair##*:}.dll"; then
        echo "  ERROR: $PE64_DIR/${pair##*:}.dll is not FEX's ${pair%%:*}.dll"
        MISSING=1
    fi
done
# The tests' VERSION has to name the Wine this bundle runs, since both come
# from one build: its first line is what bin/wine --version prints.
if [ "$RUNTIME_ONLY" -eq 0 ] && [ -f "$WINE_DIR/lib/wine/tests/VERSION" ]; then
    tests_version=$(head -n 1 "$WINE_DIR/lib/wine/tests/VERSION")
    if ! wine_version=$("$WINE_DIR/bin/wine" --version) || [ -z "$wine_version" ]; then
        echo "  ERROR: bin/wine --version failed"
        MISSING=1
    elif [ "$tests_version" != "$wine_version" ]; then
        echo "  ERROR: lib/wine/tests/VERSION says $tests_version, but bin/wine --version prints $wine_version (run build-wine.sh)"
        MISSING=1
    fi
fi
if [ $MISSING -ne 0 ]; then
    echo "Error: copied-in components are not installed correctly"
    exit 1
fi
echo "  Direct3D trees (dxgi: $DXGI_IMPLS; d3d9: $D3D9_IMPLS) and the other copied-in components in place."

# Every name a Direct3D tree supplies has a marker in the default dir, with
# the machine Step 4 gives it: i386 in i386-windows, and a hybrid one (ARM64
# with ARM64EC metadata, which pe_is_arm64x tells) in the 64-bit dir. A
# marker of the wrong machine, which would keep one kind of process from the
# name, fails the step.
time_mark "Step 5: marker machines"
BADMARK=0
for family in dxgi d3d9; do
    for arch in i386-windows "$PE64_DIR"; do
        for dll in $(family_dlls "$family" "$arch"); do
            f="$WINE_DIR/lib/wine/$arch/$dll.dll"
            if [ ! -f "$f" ] || ! head -c 128 "$f" | grep -qa "Wine placeholder DLL"; then
                echo "  ERROR: $arch/$dll.dll is not a fake-module marker"
                BADMARK=1
            elif [ "$arch" = i386-windows ]; then
                if [ "$(pe_machine "$f")" != 014c ]; then
                    echo "  ERROR: the marker $arch/$dll.dll has the PE machine $(pe_machine "$f"), not 014c"
                    BADMARK=1
                fi
            elif ! pe_is_arm64x "$f"; then
                echo "  ERROR: the marker $arch/$dll.dll is not a hybrid one (PE machine $(pe_machine "$f"))"
                BADMARK=1
            fi
        done
    done
done
if [ $BADMARK -ne 0 ]; then
    echo "Error: the Direct3D markers in the default dirs do not have the machines Step 4 gives them"
    exit 1
fi
HYBRID_MARKERS="$(family_dlls dxgi "$PE64_DIR" | tr '\n' ' ')$(family_dlls d3d9 "$PE64_DIR" | tr '\n' ' ')"
echo "  Direct3D markers in place, hybrid in $PE64_DIR: ${HYBRID_MARKERS% }"

# An x64 process runs as ARM64EC and looks up its 64-bit modules in the
# PE64_DIR directories, the default one and every Direct3D tree's, so
# everything there that it can load has to run natively, and x86_64 code
# (which it would run under FEX) or plain ARM64 code (which it cannot load
# at all) must not land there by accident: check_pe64_native in profile.sh
# has the rule and what it lets through.
time_mark "Step 5: native 64-bit PE"
if ! check_pe64_native "$WINE_DIR"; then
    echo "Error: the $PE64_DIR dirs hold PE files that an x64 process would not run natively"
    exit 1
fi

# Step 4e stripped every PE file's symbols; none may be left. One header scan
# (pe_scan) finds the PE files and their COFF symbol tables, and llvm-objdump
# reads their section tables in parallel batches (pe_debug_files).
time_mark "Step 5: PE symbol check"
(
    set -o pipefail
    find "$WINE_DIR" -type f ! -name '*.a' -print0 | pe_scan > "$TMP_DIR/pe-scan"
)
# A scan that came back empty, or without a module every bundle has, read
# nothing and would pass for a clean bundle.
if ! cut -f1 "$TMP_DIR/pe-scan" | grep -xF "$WINE_DIR/lib/wine/$PE64_DIR/ntdll.dll" >/dev/null; then
    echo "  ERROR: the PE scan found $(wc -l < "$TMP_DIR/pe-scan" | tr -d ' ') files, not lib/wine/$PE64_DIR/ntdll.dll"
    exit 1
fi
: > "$TMP_DIR/pe-check"
: > "$TMP_DIR/pe-symboled"
while IFS=$'\t' read -r f ptr count; do
    rel="${f#"$WINE_DIR"/}"
    printf '%s\0' "$f" >> "$TMP_DIR/pe-check"
    if [ "$ptr" != 0 ] || [ "$count" != 0 ]; then
        echo "$rel" >> "$TMP_DIR/pe-symboled"
    fi
done < "$TMP_DIR/pe-scan"
export MINGW_DIR
export -f pe_debug_files
xargs -0 -n 64 -P "$(sysctl -n hw.ncpu)" /bin/bash -c 'pe_debug_files "$@"' _ \
    < "$TMP_DIR/pe-check" > "$TMP_DIR/pe-debug"
unreadable=$(grep '^!' "$TMP_DIR/pe-debug" | LC_ALL=C sort | head -1)
if [ -n "$unreadable" ]; then
    echo "  ERROR: llvm-objdump cannot read ${unreadable#!"$WINE_DIR"/}:"
    "$MINGW_DIR/bin/llvm-objdump" -h "${unreadable#!}" 2>&1 || true
    exit 1
fi
while IFS= read -r f; do
    echo "${f#"$WINE_DIR"/}" >> "$TMP_DIR/pe-symboled"
done < "$TMP_DIR/pe-debug"
if [ -s "$TMP_DIR/pe-symboled" ]; then
    echo "  ERROR: PE files with debug sections or a symbol table:"
    LC_ALL=C sort -u "$TMP_DIR/pe-symboled" | sed 's/^/    /'
    exit 1
fi
echo "  No PE file carries debug sections or a symbol table."

# A symlink whose target a step removed or never installed fails only at run
# time, or, inside wine.app, as a signature that does not verify.
time_mark "Step 5: dangling symlinks"
DANGLING=$(find "$WINE_DIR" -type l ! -exec test -e {} \; -print)
if [ -n "$DANGLING" ]; then
    echo "  ERROR: dangling symlinks:"
    echo "$DANGLING" | sed "s|^$WINE_DIR/|    |"
    exit 1
fi
echo "  No dangling symlinks."

time_mark "Step 5: Vulkan, EGL, compatdb hooks and loader signature"
check_vulkan
check_egl
check_compat_hooks
check_loader_app

# After everything above is in place, so the copied-in components and
# compatdb.so are checked as well as what Wine built.
time_mark "Step 5: minos"
echo "  Checking every Mach-O against macOS $MACOS_FLOOR..."
check_minos "$WINE_DIR"
if [ -n "$FLOOR_NEWER_FUNCS" ]; then
    check_floor_newer_imports
fi

smoke_test

echo ""
print_timings
echo "==> Done! Distribution is at:"
echo "    $DIST_DIR/wine/"
if [ "$RUNTIME_ONLY" -eq 1 ]; then
    echo "    (runtime only, no development files)"
fi
