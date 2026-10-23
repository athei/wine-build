#!/bin/bash
set -eo pipefail

# The Homebrew formulae of a CI build, at the newest versions Homebrew has,
# kept between runs. A hosted runner starts from its image every time, whose
# Homebrew has many formulae already, at the versions of the day the image
# was made, and installing the formulae in pins/brew-formulae with their
# dependencies takes long. So a run updates Homebrew's formula data, writes a
# manifest of the formulae the build needs as Homebrew has them now, and
# installs them on top of a directory the workflow caches: the kegs an
# earlier run added to the image, which are unpacked first, so that only
# what changed since is downloaded.
#
#   brew.sh update           update Homebrew's formula data (brew update)
#   brew.sh manifest <file>  write to <file> the formulae of the list and
#                            every formula they need at run time, one line
#                            each, sorted:
#                              <name> <version> rebuild=<n> bottle=<bottles>
#                                runner=<versions> linked=<version>
#                            <version> is the version Homebrew has, with its
#                            revision, which names the keg in the Cellar;
#                            rebuild and bottle (<tag>:<sha256>,...) describe
#                            the bottle for this macOS, and a formula without
#                            one is an error, since building it from source
#                            could take hours; runner= and linked= are the
#                            versions the runner has installed and linked
#   brew.sh install <dir> <manifest>
#                            bring every formula of <manifest> to the version
#                            it names. <dir> is empty, or holds what an
#                            earlier install wrote, for this manifest or an
#                            older one. Its kegs at the version <manifest>
#                            names are unpacked first, unless the runner has
#                            that version already, linked where the earlier
#                            install had linked them, and their post-install
#                            steps run (brew postinstall); older ones,
#                            and those of formulae <manifest> no longer
#                            names, are left out. Then every formula of
#                            <manifest> the runner has in an older version is
#                            upgraded and every one it lacks installed. When
#                            <dir> was for another manifest or anything was
#                            installed, <dir> is written anew:
#                              kegs.tar  every keg added to the image, as
#                                        Cellar/<name>/<version>, with the
#                                        links in opt/ that point at it, and
#                                        the files added to etc/ and var/ or
#                                        changed in etc/
#                              kegs      those kegs, as <name>/<version>
#                              opt       their links in opt/, as
#                                        <link> <name>/<version>
#                              linked    the names of those brew linked into
#                                        the prefix
#                              files     those files in etc/ and var/
#                              manifest  a copy of <manifest>
#   brew.sh check <manifest> exit unless pins/brew-formulae names every
#                            formula of DEPS_FORMULAE and MESA_FORMULAE
#                            (profile.sh), every formula of <manifest> is
#                            installed and linked at the version it names,
#                            brew outdated names none of them, and the tools
#                            the build takes from the prefix run
#
# install ends with check. A keg the install added is a version directory in
# the Cellar that was not there before it, whichever formula it belongs to,
# so the dependencies come along and the image's own kegs stay out. When the
# install upgraded a formula the image had, the next one unlinks the image's
# version and links the unpacked one, as the upgrade did; the old version
# stays in the Cellar unused, as brew leaves it with
# HOMEBREW_NO_INSTALL_CLEANUP. A keg-only formula (llvm) gets its opt link
# and nothing in the prefix's bin/ or lib/, as with brew install. The files
# in etc/ and var/ of a <dir> for the same manifest replace the runner's; of
# one for an older manifest, only those the runner lacks are unpacked, since
# a file the runner has may be newer than the cached one.
#
# The workflow keys the cache on the manifest. A run whose manifest has no
# cache of its own starts from the newest earlier one, so it downloads only
# the formulae that changed. Nothing upgrades a formula outside the manifest.
# With the check of dependents off, upgrading a dependency that formulae
# outside the manifest share breaks one of them only when the library's
# install name changes, and a later step that runs it then fails visibly.
# A bottle Homebrew rebuilt at the same version changes the manifest but is
# poured only where the runner lacks the formula, as brew upgrade leaves a
# formula at its version alone; Homebrew ships fixes as new versions or
# revisions, which the check catches. The script never touches a prefix
# other than DEPS_PREFIX, and it is meant for a runner, not for a Mac whose
# Homebrew somebody maintains.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# DEPS_PREFIX, DEPS_FORMULAE, MESA_FORMULAE and PINS_DIR.
# shellcheck source=../lib/profile.sh
. "$SCRIPT_DIR/lib/profile.sh"

BREW="$DEPS_PREFIX/bin/brew"
LIST="$PINS_DIR/brew-formulae"
# No update of brew's formula data other than the explicit one of `update`,
# so every later command works from the data the manifest was written from;
# no cleanup of old versions; no check of the formulae that depend on an
# upgraded one, which would upgrade or reinstall formulae outside the
# manifest.
BREW_ENV=(env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
          HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 HOMEBREW_NO_ENV_HINTS=1)

usage() {
    echo "Usage: $0 update | manifest <file> | install <dir> <manifest> | check <manifest>"
    exit 1
}

# formulae: print the formulae LIST names, one per line, without its
# comments.
formulae() {
    awk '{ sub(/#.*/, ""); for (i = 1; i <= NF; i++) print $i }' "$LIST"
}

# formula_json <name>...: brew's JSON of the formulae <name>, from the formula
# data of the last update, with what is installed of each.
formula_json() {
    "${BREW_ENV[@]}" "$BREW" info --json=v2 --formula "$@"
}

# closure: print the formulae of LIST and every formula they need at run
# time, recursively, one per line, sorted, as Homebrew's formula data has
# them. brew deps would read the dependencies of an installed formula from its
# install receipt, which are those of the installed version, so the walk
# takes each formula's dependencies from its JSON instead, until no new one
# appears. Run in a command substitution, where errexit is off, so a failure
# returns explicitly.
closure() {
    local names=() next
    next=$(formulae | LC_ALL=C sort -u)
    while :; do
        read -ra names <<< "$(echo "$next" | tr '\n' ' ')"
        next=$(formula_json "${names[@]}" | jq -r '.formulae[] |
            .full_name, .dependencies[], .recommended_dependencies[]' |
            LC_ALL=C sort -u) || {
            echo "Error: brew info --json=v2 fails for: ${names[*]}" >&2
            return 1
        }
        [ "$next" != "$(printf '%s\n' "${names[@]}")" ] || break
    done
    echo "$next"
}

# manifest_names <manifest>: print the formulae of <manifest>, one per line.
manifest_names() {
    awk 'NF { print $1 }' "$1"
}

# kegs: print every keg in the Cellar as <name>/<version>, sorted.
kegs() {
    local k
    for k in "$DEPS_PREFIX"/Cellar/*/*; do
        if [ -d "$k" ]; then echo "${k#"$DEPS_PREFIX"/Cellar/}"; fi
    done | LC_ALL=C sort
}

# opt_links: print every link in the prefix's opt/ that points at a keg, as
# <link> <name>/<version>: the formula's own, and those of its aliases.
opt_links() {
    local l t
    for l in "$DEPS_PREFIX"/opt/*; do
        [ -L "$l" ] || continue
        t=$(readlink "$l")
        case "$t" in
            ../Cellar/*/*) echo "${l##*/} ${t#../Cellar/}" ;;
        esac
    done
}

# prefix_files [<stamp>]: print every file and symlink under the prefix's
# etc/ and var/, brew's own var/homebrew left out, relative to the prefix and
# sorted; with <stamp>, only those under etc/ changed after it. Bottles
# install their configuration there, and post-install steps write there (the
# certificate bundle of ca-certificates, which openssl@3's and gnutls's
# cert.pem point at), outside the kegs. A changed file is taken from etc/
# only, where an upgrade rewrites one the image had; var/ holds logs and
# state that anything on the runner may touch, so only its new files count.
prefix_files() {
    local d dirs=() top="etc var"
    if [ -n "${1:-}" ]; then top=etc; fi
    for d in $top; do
        if [ -d "$DEPS_PREFIX/$d" ]; then dirs+=("$d"); fi
    done
    [ ${#dirs[@]} -gt 0 ] || return 0
    (cd "$DEPS_PREFIX" && find "${dirs[@]}" -path var/homebrew -prune -o \
        \( -type f -o -type l \) ${1:+-newer "$1"} -print) | LC_ALL=C sort
}

# check_tools: run each tool the build takes from the prefix, as the scripts
# find it, and ask pkg-config for the packages Wine's configure and
# build-mesa.sh look up, so a keg that is in place but does not work fails
# here and not hours into the build.
check_tools() {
    local t
    for t in meson cmake ninja pkg-config ccache "$DEPS_PREFIX/opt/bison/bin/bison" \
             "$DEPS_PREFIX/opt/llvm/bin/llvm-config"; do
        if ! "$t" --version >/dev/null 2>&1; then
            echo "Error: $t --version fails:"
            "$t" --version || true
            exit 1
        fi
    done
    if ! PKG_CONFIG_PATH="$DEPS_PREFIX/lib/pkgconfig" pkg-config --exists \
            gnutls freetype2 sdl2 LLVMSPIRVLib SPIRV-Tools; then
        echo "Error: pkg-config does not find every package of gnutls freetype2 sdl2"
        echo "LLVMSPIRVLib SPIRV-Tools in $DEPS_PREFIX/lib/pkgconfig"
        exit 1
    fi
    echo "  meson, cmake, ninja, pkg-config, ccache, bison and llvm-config run, and pkg-config finds the packages."
}

check_brew() {
    if [ ! -x "$BREW" ]; then
        echo "Error: no Homebrew at $DEPS_PREFIX"
        exit 1
    fi
}

# check_manifest_file <manifest>: exit unless <manifest> names a formula.
check_manifest_file() {
    if [ -z "$(manifest_names "$1" 2>/dev/null)" ]; then
        echo "Error: $1 names no formula (write it with: $0 manifest $1)"
        exit 1
    fi
}

# check_versions <manifest>: exit unless every formula of <manifest> is at
# the version it names through its opt link, which the scripts use, and,
# where it is linked into the prefix, through that link, which is what the
# bundle step copies from lib/ and pkg-config finds; and unless brew outdated
# names none of them.
check_versions() {
    local name version rest have linked names=() wrong=() outdated status=0
    while read -r name version rest; do
        [ -n "$name" ] || continue
        names+=("$name")
        have=$(readlink "$DEPS_PREFIX/opt/$name" 2>/dev/null) || have=""
        have=${have##*/}
        if [ "$have" != "$version" ]; then
            wrong+=("$name ${have:-(not installed)}, Homebrew has $version")
        fi
        linked=$(readlink "$DEPS_PREFIX/var/homebrew/linked/$name" 2>/dev/null) || linked=""
        linked=${linked##*/}
        if [ -n "$linked" ] && [ "$linked" != "$version" ]; then
            wrong+=("$name linked at $linked, Homebrew has $version")
        fi
    done < "$1"
    if [ ${#wrong[@]} -gt 0 ]; then
        echo "Error: these formulae are not at the version of $1:"
        printf '    %s\n' "${wrong[@]}"
        exit 1
    fi
    # brew outdated fails when it names a formula, and also on an error.
    outdated=$("${BREW_ENV[@]}" "$BREW" outdated --formula --quiet "${names[@]}") || status=$?
    if [ -n "$outdated" ]; then
        echo "Error: brew outdated names formulae of $1:"
        awk '{ print "    " $0 }' <<< "$outdated"
        exit 1
    fi
    if [ $status -ne 0 ]; then
        echo "Error: brew outdated fails (exit status $status)"
        exit 1
    fi
    echo "  Every formula of $1 is installed and linked at the version Homebrew has, and none is outdated."
}

cmd_update() {
    check_brew
    echo "==> brew update"
    "${BREW_ENV[@]}" "$BREW" update
}

cmd_manifest() {
    local out="$1" all none names=()
    check_brew
    all=$(closure)
    read -ra names <<< "$(echo "$all" | tr '\n' ' ')"
    formula_json "${names[@]}" | jq -r '.formulae[] | [
        .full_name,
        .versions.stable + (if .revision > 0 then "_\(.revision)" else "" end),
        "rebuild=\(.bottle.stable.rebuild // 0)",
        "bottle=" + ([(.bottle.stable.files // {}) | to_entries[] |
                      "\(.key):\(.value.sha256)"] | sort |
                     if length > 0 then join(",") else "none" end),
        "runner=" + ([.installed[].version] | sort |
                     if length > 0 then join(",") else "none" end),
        "linked=\(.linked_keg // "none")"
    ] | join(" ")' | LC_ALL=C sort > "$out"
    check_manifest_file "$out"
    echo "==> Manifest ($out)"
    sed 's/^/    /' "$out"
    none=$(awk '$4 == "bottle=none" { printf " %s", $1 }' "$out")
    if [ -n "$none" ]; then
        echo "Error: Homebrew has no bottle for this macOS of:$none"
        echo "Building them from source would take too long; wait for the bottles."
        exit 1
    fi
}

cmd_check() {
    local manifest="$1" f absent="" missing=""
    check_manifest_file "$manifest"
    for f in $DEPS_FORMULAE $MESA_FORMULAE; do
        formulae | grep -xF "$f" >/dev/null || absent="$absent $f"
    done
    if [ -n "$absent" ]; then
        echo "Error: $LIST does not name$absent, which profile.sh lists"
        exit 1
    fi
    for f in $(formulae); do
        [ -d "$DEPS_PREFIX/opt/$f" ] || missing="$missing $f"
    done
    if [ -n "$missing" ]; then
        echo "Error: not installed in $DEPS_PREFIX:$missing"
        exit 1
    fi
    echo "  Every formula of $LIST is installed in $DEPS_PREFIX."
    check_versions "$manifest"
    check_tools
}

# unpack <dir> <manifest> <same>: unpack the kegs of <dir> at the version
# <manifest> names that the runner lacks, with their opt links, and link
# those the earlier install had linked, unlinking the runner's version
# first. <same> is 1 when <dir> was written for <manifest>: then all its
# files in etc/ and var/ are unpacked, otherwise only those the runner
# lacks. Then the post-install steps of the unpacked formulae run, as brew
# install runs them, since they write outside the keg (the certificate
# bundle of ca-certificates, a link to it in gnutls's etc/) what a file
# from the cache or the image can leave stale. Homebrew's JSON marks a
# formula with them by post_install_steps, or post_install_defined for a
# post_install method.
unpack() {
    local dir="$1" manifest="$2" same="$3" k state name f link keg json
    local members=() unlink=() relink=() names=() post=() picked=""
    echo "==> Unpacking the kegs in $dir"
    # Each keg, and whether it is at the version of the manifest.
    while read -r k state; do
        if [ "$state" != current ]; then
            echo "    $k (left out: $state)"
            continue
        fi
        if [ -e "$DEPS_PREFIX/Cellar/$k" ]; then
            echo "    $k (left out: the runner has it)"
            continue
        fi
        echo "    $k"
        name=${k%%/*}
        picked="$picked $k "
        names+=("$name")
        members+=("Cellar/$k")
        if [ -L "$DEPS_PREFIX/var/homebrew/linked/$name" ]; then
            unlink+=("$name")
        fi
        if grep -xF "$name" "$dir/linked" >/dev/null; then
            relink+=("$name")
        fi
    done < <(awk 'NR == FNR { v[$1] = $2; next }
        NF {
            n = $0; sub(/\/.*/, "", n); ver = substr($0, length(n) + 2)
            if (!(n in v)) print $0, "not in the manifest"
            else if (v[n] != ver) print $0, "the manifest has " v[n]
            else print $0, "current"
        }' "$manifest" "$dir/kegs")
    while read -r link keg; do
        case "$picked" in
            *" $keg "*) members+=("opt/$link") ;;
        esac
    done < "$dir/opt"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ "$same" = 1 ] || { [ ! -e "$DEPS_PREFIX/$f" ] && [ ! -L "$DEPS_PREFIX/$f" ]; }; then
            members+=("$f")
        fi
    done < "$dir/files"
    if [ ${#unlink[@]} -gt 0 ]; then
        "${BREW_ENV[@]}" "$BREW" unlink "${unlink[@]}"
    fi
    if [ ${#members[@]} -gt 0 ]; then
        tar -C "$DEPS_PREFIX" -xpf "$dir/kegs.tar" "${members[@]}"
    fi
    if [ ${#relink[@]} -gt 0 ]; then
        "${BREW_ENV[@]}" "$BREW" link --overwrite "${relink[@]}"
    fi
    [ ${#names[@]} -gt 0 ] || return 0
    json=$(formula_json "${names[@]}")
    read -ra post <<< "$(echo "$json" | jq -r '.formulae[] |
        select(.post_install_defined or ((.post_install_steps // []) | length > 0)) |
        .full_name' | tr '\n' ' ')"
    if [ ${#post[@]} -gt 0 ]; then
        echo "==> brew postinstall ${post[*]}"
        "${BREW_ENV[@]}" "$BREW" postinstall "${post[@]}"
    fi
}

# write_cache <dir> <manifest> <before> <before_files> <stamp>: write to
# <dir> every keg in the Cellar that is not in <before>, and the files in
# etc/ and var/ that are not in <before_files> or in etc/ changed after
# <stamp>.
write_cache() {
    local dir="$1" manifest="$2" before="$3" before_files="$4" stamp="$5"
    local added files k name f link keg paths=()
    added=$(LC_ALL=C comm -13 <(echo "$before") <(kegs))
    files=$({ LC_ALL=C comm -13 <(echo "$before_files") <(prefix_files)
              prefix_files "$stamp"; } | LC_ALL=C sort -u)
    echo "==> Writing the kegs added to the image to $dir"
    : > "$dir/kegs"
    : > "$dir/opt"
    : > "$dir/linked"
    : > "$dir/files"
    cp "$manifest" "$dir/manifest"
    while IFS= read -r k; do
        [ -n "$k" ] || continue
        name=${k%%/*}
        echo "    $k"
        echo "$k" >> "$dir/kegs"
        paths+=("Cellar/$k")
        if [ "$(readlink "$DEPS_PREFIX/var/homebrew/linked/$name" 2>/dev/null)" = "../../../Cellar/$k" ]; then
            echo "$name" >> "$dir/linked"
        fi
    done <<< "$added"
    while read -r link keg; do
        [ -n "$link" ] || continue
        echo "$link $keg" >> "$dir/opt"
        paths+=("opt/$link")
    done < <(awk 'NR == FNR { a[$0]; next } $2 in a' <(echo "$added") <(opt_links))
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        echo "    $f"
        echo "$f" >> "$dir/files"
        paths+=("$f")
    done <<< "$files"
    if [ ${#paths[@]} -eq 0 ]; then
        echo "    (none: the image has every formula at its version already)"
        tar -cf "$dir/kegs.tar" -T /dev/null
    else
        tar --no-mac-metadata -C "$DEPS_PREFIX" -cf "$dir/kegs.tar" "${paths[@]}"
    fi
}

cmd_install() {
    local dir="$1" manifest="$2" new="$1.new" json f same=0 cached=0
    local before before_files names=() upgrade=() install=()
    check_brew
    check_manifest_file "$manifest"
    mkdir -p "$dir"
    if [ -n "$(ls -A "$dir")" ]; then
        for f in kegs.tar kegs opt linked files manifest; do
            if [ ! -f "$dir/$f" ]; then
                echo "Error: $dir has no $f, so it is not what an earlier install wrote"
                exit 1
            fi
        done
        cached=1
        if cmp -s "$dir/manifest" "$manifest"; then
            same=1
        else
            echo "==> $dir was written for another manifest:"
            { diff "$dir/manifest" "$manifest" || true; } |
                sed -n 's/^> /    now /p; s/^< /    was /p'
        fi
    fi
    rm -rf "$new"
    mkdir -p "$new"
    before=$(kegs)
    before_files=$(prefix_files)
    touch "$new/.install-started"
    # A file the install writes gets a newer time than this; one it copies
    # from a bottle or the cache may keep its own, and is found by its name.
    sleep 1
    if [ $cached = 1 ]; then
        unpack "$dir" "$manifest" "$same"
    fi

    read -ra names <<< "$(manifest_names "$manifest" | tr '\n' ' ')"
    # Which formulae of the manifest the runner has in an older version, and
    # which it lacks.
    json=$(formula_json "${names[@]}")
    read -ra upgrade <<< "$(echo "$json" |
        jq -r '.formulae[] | select(.installed != [] and .outdated) | .full_name' | tr '\n' ' ')"
    read -ra install <<< "$(echo "$json" |
        jq -r '.formulae[] | select(.installed == []) | .full_name' | tr '\n' ' ')"
    if [ ${#upgrade[@]} -gt 0 ]; then
        echo "==> brew upgrade ${upgrade[*]}"
        "${BREW_ENV[@]}" "$BREW" upgrade --formula "${upgrade[@]}"
    fi
    if [ ${#install[@]} -gt 0 ]; then
        echo "==> brew install ${install[*]}"
        "${BREW_ENV[@]}" "$BREW" install --formula "${install[@]}"
    fi

    if [ $same = 1 ] && [ ${#upgrade[@]} -eq 0 ] && [ ${#install[@]} -eq 0 ]; then
        echo "==> $dir is up to date"
        rm -rf "$new"
    else
        write_cache "$new" "$manifest" "$before" "$before_files" "$new/.install-started"
        rm -f "$new/.install-started"
        rm -rf "$dir"
        mv "$new" "$dir"
    fi
    cmd_check "$manifest"
}

case "${1:-}" in
    update) [ $# -eq 1 ] || usage; cmd_update ;;
    manifest|check) [ $# -eq 2 ] || usage; "cmd_$1" "$2" ;;
    install) [ $# -eq 3 ] || usage; cmd_install "$2" "$3" ;;
    *) usage ;;
esac
