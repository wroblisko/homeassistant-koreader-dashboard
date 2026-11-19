#!/usr/bin/env bash
# Run spec/ with busted.
#
# Prefers KOReader's real busted install when it exists. That binary lives
# under the base build triplet, not under base/spec/rocks:
#
#   B=$KOREADER_SRC/base/build/<triplet>   # a dir that has spec/rocks/bin/busted
#   eval "$($B/staging/bin/luarocks --tree $B/spec/rocks path)"
#   $B/spec/rocks/bin/busted --lpath='./homedash.koplugin/?.lua;<emulator>/common/?.lua' spec
#
# The emulator common/ directory (json.lua, dkjson.lua) is added so specs can
# decode spec/fixtures/ha/. If several triplets or emulator trees exist, the
# newest is used.
#
# Without a KOReader build (CI, a plain checkout) it falls back to `busted` on
# PATH, from the repo root, with --lpath ./homedash.koplugin/?.lua. JSON then
# comes from luarocks (`luarocks install busted dkjson`): the script applies
# `luarocks path` when luarocks is installed, so `require("dkjson")` works.
# A failure of KOReader's busted is not retried with the system binary.
#
# Extra arguments are forwarded to busted.
# KOREADER_SRC defaults to ../koreader-src (a sibling of this repo).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KOREADER_SRC="${KOREADER_SRC:-$(dirname "$ROOT")/koreader-src}"

mtime_of() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"
}

# Newest $KOREADER_SRC/base/build/* that contains busted and luarocks.
find_busted_build() {
    local newest="" newest_mtime=0 d mtime
    shopt -s nullglob
    for d in "$KOREADER_SRC"/base/build/*; do
        if [[ -x "$d/spec/rocks/bin/busted" && -x "$d/staging/bin/luarocks" ]]; then
            mtime="$(mtime_of "$d")"
            if [[ "$mtime" -gt "$newest_mtime" ]]; then
                newest_mtime="$mtime"
                newest="$d"
            fi
        fi
    done
    shopt -u nullglob
    if [[ -z "$newest" ]]; then
        return 1
    fi
    printf '%s\n' "$newest"
}

# Newest emulator common/ that ships json.lua or dkjson.lua.
find_json_dir() {
    local newest="" newest_mtime=0 d mtime
    shopt -s nullglob
    for d in "$KOREADER_SRC"/koreader-emulator-*/koreader/common; do
        if [[ -f "$d/json.lua" || -f "$d/dkjson.lua" ]]; then
            mtime="$(mtime_of "$d")"
            if [[ "$mtime" -gt "$newest_mtime" ]]; then
                newest_mtime="$mtime"
                newest="$d"
            fi
        fi
    done
    shopt -u nullglob
    printf '%s\n' "$newest"
}

lpath_arg() {
    local json_dir="$1"
    if [[ -n "$json_dir" ]]; then
        printf '%s\n' "./homedash.koplugin/?.lua;${json_dir}/?.lua"
        return
    fi
    printf '%s\n' "./homedash.koplugin/?.lua"
}

# True (or unknown) when some Lua can load a JSON module that the specs accept.
# Used only to warn in the system-busted fallback.
json_module_available() {
    local lua
    for lua in luajit lua5.1 lua; do
        if command -v "$lua" >/dev/null 2>&1; then
            "$lua" -e 'for _, n in ipairs({"rapidjson","json","dkjson"}) do if pcall(require, n) then os.exit(0) end end os.exit(1)' \
                >/dev/null 2>&1
            return $?
        fi
    done
    return 0
}

run_koreader_busted() {
    local build="$1"
    shift
    local luarocks="$build/staging/bin/luarocks"
    local busted="$build/spec/rocks/bin/busted"
    local json_dir lpath
    json_dir="$(find_json_dir)"
    lpath="$(lpath_arg "$json_dir")"
    echo "test.sh: using $busted" >&2
    if [[ -n "$json_dir" ]]; then
        echo "test.sh: JSON path $json_dir" >&2
    fi
    # luarocks prints `export LUA_PATH=...` (and LUA_CPATH / PATH).
    eval "$("$luarocks" --tree "$build/spec/rocks" path)"
    cd "$ROOT"
    "$busted" --lpath="$lpath" spec "$@"
}

run_system_busted() {
    if ! command -v busted >/dev/null 2>&1; then
        echo "error: KOReader busted not found, and system busted is not on PATH" >&2
        echo "Looked for \$KOREADER_SRC/base/build/*/spec/rocks/bin/busted" >&2
        echo "Install busted and dkjson (luarocks install busted dkjson) or build KOReader (docs/development.md)." >&2
        exit 1
    fi
    echo "test.sh: using system busted ($(command -v busted))" >&2
    # Make luarocks-installed modules (dkjson) visible, as `luarocks path` does.
    if command -v luarocks >/dev/null 2>&1; then
        eval "$(luarocks path 2>/dev/null)" || true
    fi
    local json_dir lpath
    json_dir="$(find_json_dir)"
    lpath="$(lpath_arg "$json_dir")"
    if [[ -z "$json_dir" ]] && ! json_module_available; then
        echo "test.sh: warning: no JSON module found; fixture specs need dkjson (luarocks install dkjson)" >&2
    fi
    cd "$ROOT"
    busted --lpath="$lpath" spec "$@"
}

main() {
    local build=""
    if [[ -d "$KOREADER_SRC/base/build" ]]; then
        build="$(find_busted_build || true)"
    fi
    if [[ -n "$build" ]]; then
        run_koreader_busted "$build" "$@"
        return
    fi
    run_system_busted "$@"
}

main "$@"
