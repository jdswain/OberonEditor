#!/usr/bin/env bash
# build-oberon.sh — Xcode pre-build phase that compiles the Oberon
# side of oed for the active iOS target and bundles the result into
# a static library Xcode's link step picks up.
#
# Stages:
#   1. Pick the target triple from Xcode's PLATFORM_NAME + ARCHS.
#   2. Compile the runtime stubs (oc/runtime/ios/*.Mod) — these are
#      shared across all Oberon-on-iOS apps; recompiled here per
#      target triple because the oc compiler stamps the triple into
#      every .o.
#   3. Compile each oed src/*.Mod (skip *Test.Mod).
#   4. Compile the runtime sidecars (oc/runtime/ios/*.c) via the
#      iOS clang against the right SDK.
#   5. ar all .o files into liboed_oberon.a under BUILT_PRODUCTS_DIR
#      so the linker resolves it via OTHER_LDFLAGS.
#
# Always-runs (project.yml sets basedOnDependencyAnalysis: false).
# Re-runs are fast enough for scaffold-grade work; tighten with
# input/output lists later when the iteration loop justifies it.

set -euo pipefail

# ---- Paths ------------------------------------------------------

# All paths are relative to oed/ios/ (SRCROOT under Xcode). The
# compiler and runtime live in the sibling oc/ checkout.
OED_REPO="${SRCROOT}/.."
OC_REPO="${OED_REPO}/../oc"

OC="${OC:-${OC_REPO}/bin/oc}"
OC_RT="${OC_REPO}/runtime/ios"
OED_SRC="${OED_REPO}/src"

OBJ_DIR="${DERIVED_FILE_DIR}/oberon"
LIB_PATH="${BUILT_PRODUCTS_DIR}/liboed_oberon.a"

[ -x "$OC" ]      || { echo "error: oc compiler not found at $OC"; exit 1; }
[ -d "$OC_RT" ]   || { echo "error: runtime/ios not found at $OC_RT"; exit 1; }
[ -d "$OED_SRC" ] || { echo "error: oed src not found at $OED_SRC"; exit 1; }

mkdir -p "$OBJ_DIR" "$(dirname "$LIB_PATH")"

# ---- Target stamp ----------------------------------------------

# oc emits intermediates alongside the .Mod files. When a previous
# build for a different target left .smb files in place, the compiler
# refuses to overwrite them ("new symbol file inhibited"). Mirror the
# posix-stamp / wasm-stamp pattern from oed/Makefile: track the last
# triple compiled, wipe stale artifacts when it changes.
clear_stale_objs() {
    rm -f "$1"/*.o "$1"/*.ll "$1"/*.smb "$1"/*.deps
}

case "${PLATFORM_NAME}" in
    iphoneos)         triple_arch="arm64";   triple_os="ios15.0" ;;
    iphonesimulator)  triple_arch="${ARCHS%% *}"; triple_os="ios15.0-simulator" ;;
    *) echo "error: unsupported PLATFORM_NAME=${PLATFORM_NAME}"; exit 1 ;;
esac
TRIPLE="${triple_arch}-apple-${triple_os}"
SDK_PATH="$(xcrun --sdk "${PLATFORM_NAME}" --show-sdk-path)"
CLANG="$(xcrun --sdk "${PLATFORM_NAME}" -f clang)"

echo "build-oberon: triple=${TRIPLE} sdk=${SDK_PATH}"
echo "build-oberon: oc=${OC}"
echo "build-oberon: obj_dir=${OBJ_DIR}"

STAMP_FILE="${OED_REPO}/bin/.target"
mkdir -p "${OED_REPO}/bin"
if [ ! -f "$STAMP_FILE" ] || [ "$(cat "$STAMP_FILE")" != "$TRIPLE" ]; then
    echo "build-oberon: target changed → ${TRIPLE}; clearing stale .smb/.o"
    clear_stale_objs "$OC_RT"
    clear_stale_objs "$OED_SRC"
    echo "$TRIPLE" > "$STAMP_FILE"
fi

# ---- Compile Oberon (runtime stubs + oed src) ------------------

# The compiler emits .o / .ll / .smb / .deps alongside each .Mod;
# they're gitignored. Running it from a working dir keeps outputs
# scoped to that dir.

compile_dir() {
    local dir="$1"; shift
    local names=("$@")
    pushd "$dir" >/dev/null
    for m in "${names[@]}"; do
        echo "build-oberon: compile ${dir##*/}/${m}.Mod"
        # -s forces a fresh .smb write. We always recompile every
        # module (no input/output dependency tracking yet), and the
        # oc compiler has a latent bug where the no-change branch
        # leaves the .smb file's key field zeroed on disk — flipping
        # the file hash every other run and tripping a subsequent
        # "new symbol file inhibited" error. -s sidesteps it.
        "$OC" -target "$TRIPLE" -s "${m}.Mod"
    done
    popd >/dev/null
}

# Runtime stubs in dependency order (Controls imports TUI).
compile_dir "$OC_RT" Out Env TUI Files Controls

# oed sources — list explicitly to skip *Test.Mod and pin the
# topological order. Matches the OED_DEPS list in oed/Makefile.
OED_MODS=(
    Strings Buffer Lines Directive Schema Csv Doc Viewers
    BufList Collection Expr Mini Motion Render Search
    Project KillRing Links History FileOps FileBrowser
    TableView FormView SpreadsheetView
    Oed
)
compile_dir "$OED_SRC" "${OED_MODS[@]}"

# ---- Compile runtime C sidecars -------------------------------

# Single -target carries the platform + min-version + simulator
# variant in one place — cleaner than the awkward
# -miphonesimulator-version-min flag which isn't on every clang.
CFLAGS=(
    -target "${TRIPLE}"
    -arch "${triple_arch}"
    -isysroot "${SDK_PATH}"
    -O2
    -c
)

for src in runtime.c TUI_rt.c Out_rt.c Env_rt.c; do
    echo "build-oberon: compile runtime/${src}"
    "$CLANG" "${CFLAGS[@]}" -o "${OBJ_DIR}/${src%.c}.o" "${OC_RT}/${src}"
done

# ---- Archive ---------------------------------------------------

# Collect every .o we produced (runtime + oed src + C sidecars)
# into a single static library. The shell glob expands relative
# to the .Mod-adjacent emission sites; copy into OBJ_DIR first
# so ar gets a single tidy directory.

cp "${OC_RT}"/*.o "${OBJ_DIR}/"
cp "${OED_SRC}"/*.o "${OBJ_DIR}/"

rm -f "${LIB_PATH}"
ar rcs "${LIB_PATH}" "${OBJ_DIR}"/*.o

echo "build-oberon: wrote ${LIB_PATH} ($(stat -f %z "${LIB_PATH}") bytes)"
