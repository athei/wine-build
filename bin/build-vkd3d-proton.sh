#!/bin/bash
set -e

# Builds vkd3d-proton, the Direct3D 12 implementation on Vulkan, for the
# bundle from athei/vkd3d-proton (upstream vkd3d-proton with our commits on
# top; VKD3D_PROTON_REPO names another repository) at the ref in
# vkd3d-proton-src.ref (a branch, tag or commit) and stages it in
# VKD3D_PROTON_DIST, in the layout of a Wine install's lib/wine:
#
#   aarch64-windows/{d3d12,d3d12core}.dll   ARM64X
#   i386-windows/{d3d12,d3d12core}.dll      i386
#   KEY          what the dist was built from (dist_key in profile.sh)
#   COMMIT       the source commit
#   DESCRIBE     its `git describe --tags`, the version vkd3d-proton's build
#                records for itself
#   WINE_COMMIT  the commit WINE_SRC was at (wine_src_commit) when the DLLs
#                were marked
#
# Called by build-wine.sh, after build-dxmt.sh. bundle-wine.sh installs from
# VKD3D_PROTON_DIST into the dxmt tree, next to DXMT's dxgi.dll, which
# presents vkd3d-proton's swapchains.
#
# The 64-bit DLLs are ARM64X, built with vkd3d-proton's own build-arm64x.txt
# cross file, whose -marm64x has the arm64ec llvm-mingw compile every source
# for ARM64EC and for ARM64 and link both halves into one image, as DXMT's
# build-arm64ec.txt does. An x64 game runs as ARM64EC and loads the ARM64EC
# half, so vkd3d-proton runs natively in it; a native ARM64 program loads the
# ARM64 half. Wine looks up both kinds of 64-bit builtin in aarch64-windows,
# where they are staged. The i386 DLLs are x86 code, built with
# build-win32.txt; a 32-bit game runs under WoW64 and FEX, and they run
# there with it, emulated.
#
# Unlike DXMT, vkd3d-proton links nothing of Wine: it is plain PE code on the
# mingw runtime, and it reaches Vulkan by loading winevulkan.dll or
# vulkan-1.dll at run time. It needs Wine only for winebuild. Wine ignores a
# DLL in its lib/wine directories that is not marked as a builtin, and
# vkd3d-proton's build has no step for that, so the staged copies are marked
# with `winebuild --builtin`: the 64-bit ones with the Wine build tree's
# winebuild, the i386 ones with the Wine SDK's, the same two DXMT's build
# uses. The mark does not depend on the Wine version, so a new Wine commit
# does not need a new vkd3d-proton build. WINE_COMMIT only records which
# commit WINE_SRC was at; the two winebuilds may come from an older build.
#
# vkd3d-proton compiles its internal shaders with glslang, from the arm64
# Homebrew (pins/brew-formulae).
#
# Nothing is built when VKD3D_PROTON_DIST is complete and has the KEY this
# run would write (skip_current_dist in profile.sh). --clean wipes the
# vkd3d-proton checkout, trees and VKD3D_PROTON_DIST first. --print-key
# prints that KEY and exits (print_dist_key).

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

# profile.sh names VKD3D_PROTON_REPO, VKD3D_PROTON_BUILD_DIR,
# VKD3D_PROTON_DIST, and the Wine build tree and SDK whose winebuild marks the
# DLLs.
# shellcheck source=lib/profile.sh
. "$SCRIPT_DIR/lib/profile.sh"

VKD3D_PROTON_REF="$(tr -d '[:space:]' < "$PINS_DIR/vkd3d-proton-src.ref")"
if [ -z "$VKD3D_PROTON_REF" ]; then
    echo "Error: $PINS_DIR/vkd3d-proton-src.ref is empty"
    exit 1
fi

VKD3D_PROTON_SRC="$VKD3D_PROTON_BUILD_DIR/src"
PE_DLLS="d3d12 d3d12core"
WINEBUILD64="$BUILD_DIR/tools/winebuild/winebuild"
WINEBUILD32="$WINE_SDK_DIR/bin/winebuild"

# ── Preflight ───────────────────────────────────────────────────────────
for tool in git meson ninja; do
    if ! command -v "$tool" >/dev/null; then
        echo "Error: $tool not found (brew install $tool)"
        exit 1
    fi
done
# vkd3d-proton's meson.build takes either name, glslang first.
GLSLANG=$(command -v glslang || command -v glslangValidator || true)
if [ -z "$GLSLANG" ]; then
    echo "Error: glslang not found (brew install glslang)"
    exit 1
fi

# ── Dist ────────────────────────────────────────────────────────────────
# vkd3d_proton_key <commit>: the KEY of a VKD3D_PROTON_DIST built from
# <commit>, which fixes the submodules too, with what vkd3d_setup below
# configures a tree again for, llvm-mingw's clang and glslang, and
# llvm-mingw's release, whose headers and runtime the DLLs are built with.
# As there, the Wine commit is not part of it: the DLLs link nothing of
# Wine.
vkd3d_proton_key() {
    dist_key "$SCRIPT_DIR/build-vkd3d-proton.sh" "vkd3d-proton=$1" \
        "$(mingw_key)" "glslang=$(cc_version "$GLSLANG")"
}
VKD3D_PROTON_WANT=$(src_ref_commit vkd3d-proton-src.ref "$VKD3D_PROTON_REPO")
print_dist_key "$VKD3D_PROTON_WANT" vkd3d-proton-src.ref vkd3d_proton_key

# The checkout and meson trees this script deletes and recreates are fixed
# paths in VKD3D_PROTON_BUILD_DIR. VKD3D_PROTON_DIST is inside it unless
# overridden, so it is claimed on its own, and so is VKD3D_PROTON_DIST.part
# below.
claim_tree "$VKD3D_PROTON_BUILD_DIR" vkd3d-proton
if [ "$CLEAN" -eq 1 ]; then
    echo "==> Cleaning the vkd3d-proton trees..."
    remove_tree "$VKD3D_PROTON_SRC" "$VKD3D_PROTON_BUILD_DIR/arm64x" "$VKD3D_PROTON_BUILD_DIR/win32"
fi
claim_tree "$VKD3D_PROTON_DIST" vkd3d-proton-dist "$CLEAN"
skip_current_dist "$VKD3D_PROTON_DIST" vkd3d-proton "$VKD3D_PROTON_WANT" vkd3d_proton_key

if [ ! -x "$WINEBUILD64" ]; then
    echo "Error: $WINEBUILD64 not found (run build-wine.sh first)"
    exit 1
fi
if [ ! -x "$WINEBUILD32" ]; then
    echo "Error: the Wine SDK at $WINE_SDK_DIR has no bin/winebuild (run build-wine.sh)"
    exit 1
fi

# Appended, never prepended: llvm-mingw's bin/ has an unprefixed clang that
# would otherwise replace Apple's as the native compiler, which meson also
# looks for. vkd3d-proton's cross files name the tools without a path, so
# check that each resolves into llvm-mingw and not to some other mingw
# earlier in PATH. widl compiles vkd3d-proton's IDL files; meson prefers an
# unprefixed widl, which llvm-mingw does not have, over the prefixed one the
# cross files name, so one elsewhere in PATH is refused too.
export PATH="$PATH:$MINGW_DIR/bin"
for triple in i686-w64-mingw32 arm64ec-w64-mingw32; do
    for tool in gcc g++ ar strip widl; do
        if [ "$(command -v "$triple-$tool")" != "$MINGW_DIR/bin/$triple-$tool" ]; then
            echo "Error: $triple-$tool does not resolve to $MINGW_DIR/bin"
            echo "  (found: $(command -v "$triple-$tool" || echo nothing))"
            exit 1
        fi
    done
done
if command -v widl >/dev/null; then
    echo "Error: $(command -v widl) would take the place of llvm-mingw's widl; remove it from PATH"
    exit 1
fi
# The checks of the staged DLLs read them with it (pe_is_arm64x, exports).
if [ ! -x "$MINGW_DIR/bin/llvm-readobj" ]; then
    echo "Error: no llvm-readobj in $MINGW_DIR/bin"
    exit 1
fi

# ── Source ──────────────────────────────────────────────────────────────
# As in build-dxmt.sh: VKD3D_PROTON_SRC is this script's own scratch clone,
# forced to the ref fetched from VKD3D_PROTON_REPO by URL on every run that
# builds, with every tag, since vkd3d-proton's build runs `git describe
# --tags` for its version. The submodules (dxil-spirv, with its own, and the
# Khronos headers) are fetched shallow at the commits the ref records;
# nothing describes them. git is kept from asking for credentials.
echo "==> vkd3d-proton source: $VKD3D_PROTON_REPO $VKD3D_PROTON_REF"
if [ ! -e "$VKD3D_PROTON_SRC/.git" ]; then
    GIT_TERMINAL_PROMPT=0 git clone --quiet --no-checkout "$VKD3D_PROTON_REPO" "$VKD3D_PROTON_SRC"
fi
GIT_TERMINAL_PROMPT=0 git -C "$VKD3D_PROTON_SRC" fetch --quiet --force --tags "$VKD3D_PROTON_REPO"
GIT_TERMINAL_PROMPT=0 git -C "$VKD3D_PROTON_SRC" fetch --quiet "$VKD3D_PROTON_REPO" "$VKD3D_PROTON_REF"
git -C "$VKD3D_PROTON_SRC" -c advice.detachedHead=false checkout --quiet --force --detach FETCH_HEAD
GIT_TERMINAL_PROMPT=0 git -C "$VKD3D_PROTON_SRC" submodule update --quiet --init --recursive --force --depth 1
# A leading '+', '-' or 'U' marks a submodule that is not at the recorded
# commit, not checked out, or in conflict.
if git -C "$VKD3D_PROTON_SRC" submodule status --recursive | grep '^[-+U]' >/dev/null; then
    echo "Error: vkd3d-proton submodules do not match $VKD3D_PROTON_REF:"
    git -C "$VKD3D_PROTON_SRC" submodule status --recursive | grep '^[-+U]'
    exit 1
fi
VKD3D_PROTON_COMMIT=$(git -C "$VKD3D_PROTON_SRC" rev-parse HEAD)
VKD3D_PROTON_DESCRIBE=$(git -C "$VKD3D_PROTON_SRC" describe --always --tags)
echo "    at $VKD3D_PROTON_COMMIT ($VKD3D_PROTON_DESCRIBE)"

# ── Meson trees ─────────────────────────────────────────────────────────
# vkd3d_setup <dir> <cross-file> <option>...: configure a vkd3d-proton tree,
# again from scratch whenever the commit, the options, llvm-mingw's clang or
# glslang differ from what it was configured with, as build-dxmt.sh does: a
# new compiler changes the code without a change ninja would see. Nothing
# in it links against Wine, so the Wine commit is not part of the key. The
# tests are not built.
CLANG_VERSION=$("$MINGW_DIR/bin/clang" --version | head -n 1)
GLSLANG_VERSION=$("$GLSLANG" --version | head -n 1)
vkd3d_setup() {
    local dir="$1" cross="$2" key
    shift 2
    set -- --buildtype release -Denable_tests=false "$@"
    key="$VKD3D_PROTON_COMMIT $cross $* clang=$CLANG_VERSION glslang=$GLSLANG_VERSION"
    if [ "$(cat "$dir/.setup-key" 2>/dev/null)" != "$key" ]; then
        remove_tree "$dir"
        meson setup "$dir" "$VKD3D_PROTON_SRC" --cross-file "$VKD3D_PROTON_SRC/$cross" "$@" >/dev/null
        echo "$key" > "$dir/.setup-key"
    fi
}

# Only the two DLLs; the default targets add nothing the bundle needs.
PE_TARGETS=(libs/d3d12/d3d12.dll libs/d3d12core/d3d12core.dll)

echo "==> Building vkd3d-proton's ARM64X PE DLLs..."
vkd3d_setup "$VKD3D_PROTON_BUILD_DIR/arm64x" build-arm64x.txt
ninja -C "$VKD3D_PROTON_BUILD_DIR/arm64x" "${PE_TARGETS[@]}"

echo "==> Building vkd3d-proton's i386 PE DLLs..."
vkd3d_setup "$VKD3D_PROTON_BUILD_DIR/win32" build-win32.txt
ninja -C "$VKD3D_PROTON_BUILD_DIR/win32" "${PE_TARGETS[@]}"

# ── Stage ───────────────────────────────────────────────────────────────
# Staged next to VKD3D_PROTON_DIST and renamed into place once complete and
# checked, so an interrupted or failed run never leaves a VKD3D_PROTON_DIST
# that looks finished. The marks go on the staged copies, not the build
# trees' files, so ninja never sees its outputs changed.
echo "==> Staging vkd3d-proton into $VKD3D_PROTON_DIST..."
part="$VKD3D_PROTON_DIST.part"
claim_tree "$part" vkd3d-proton-dist 1
mkdir -p "$part/$PE64_DIR" "$part/i386-windows"
for dll in $PE_DLLS; do
    cp "$VKD3D_PROTON_BUILD_DIR/arm64x/libs/$dll/$dll.dll" "$part/$PE64_DIR/"
    cp "$VKD3D_PROTON_BUILD_DIR/win32/libs/$dll/$dll.dll" "$part/i386-windows/"
    "$WINEBUILD64" --builtin "$part/$PE64_DIR/$dll.dll"
    "$WINEBUILD32" --builtin "$part/i386-windows/$dll.dll"
done

# pe_export_views <file> <symbol>: print how many export tables of the PE
# image <file> name <symbol>: one per view, so 2 when both halves of an
# ARM64X image export it, and 1 for a plain image.
pe_export_views() {
    "$MINGW_DIR/bin/llvm-readobj" --coff-exports "$1" | grep -cxE " *Name: $2" || true
}

# A cross file that silently fell back to another compiler would still
# produce DLLs, only of the wrong machine, and one linked without -marm64x
# would carry the x86_64 or plain ARM64 machine and no second half. So each
# 64-bit DLL must be ARM64X (pe_is_arm64x) and each i386 one i386. Each must
# carry Wine's builtin marker, and export the entry points Wine's d3d12 has,
# in every view: d3d12.dll D3D12CreateDevice, which games call, and
# d3d12core.dll D3D12GetInterface and D3D12SDKVersion, through which
# d3d12.dll finds it.
for dll in $PE_DLLS; do
    f="$part/$PE64_DIR/$dll.dll"
    if ! pe_is_arm64x "$f"; then
        echo "Error: $PE64_DIR/$dll.dll is not ARM64X (PE machine $(pe_machine "$f"))"
        exit 1
    fi
    f="$part/i386-windows/$dll.dll"
    [ "$(pe_machine "$f")" = 014c ] \
        || { echo "Error: i386-windows/$dll.dll has the PE machine $(pe_machine "$f"), not 014c"; exit 1; }
    case $dll in
        d3d12) syms="D3D12CreateDevice" ;;
        d3d12core) syms="D3D12GetInterface D3D12SDKVersion" ;;
    esac
    for f in "$PE64_DIR/$dll.dll" "i386-windows/$dll.dll"; do
        head -c 128 "$part/$f" | grep -qa "Wine builtin DLL" \
            || { echo "Error: $f is not marked as a Wine builtin"; exit 1; }
        if [ "${f%%/*}" = "$PE64_DIR" ]; then views=2; else views=1; fi
        for sym in $syms; do
            n=$(pe_export_views "$part/$f" "$sym")
            if [ "$n" != "$views" ]; then
                echo "Error: $f exports $sym in $n of its $views views"
                exit 1
            fi
        done
    done
    echo "    $dll.dll: ARM64X and i386, Wine builtins, export $syms"
done

echo "$VKD3D_PROTON_DESCRIBE" > "$part/DESCRIBE"
wine_src_commit > "$part/WINE_COMMIT"
vkd3d_proton_key "$VKD3D_PROTON_COMMIT" > "$part/KEY"
# Written last, so a staged directory without it is an incomplete one.
echo "$VKD3D_PROTON_COMMIT" > "$part/COMMIT"
remove_tree "$VKD3D_PROTON_DIST"
mv "$part" "$VKD3D_PROTON_DIST"
echo "==> vkd3d-proton $VKD3D_PROTON_DESCRIBE staged."
