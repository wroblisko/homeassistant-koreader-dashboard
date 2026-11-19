#!/usr/bin/env bash
# Link homedash.koplugin into a KOReader emulator build and run it.
#
#   scripts/dev.sh run [profile]
#   scripts/dev.sh shots [en]
#   scripts/dev.sh mock
#   scripts/dev.sh run real [profile]
#   scripts/dev.sh shots real [refused|timeout]
#
# `shots en` uses dev/config.mock.en.lua (English labels, lang = "en") and writes
# out/en-<name>.png instead of out/<name>.png.
#
# Real mode talks to your Home Assistant. It needs your own dev/config.real.lua
# (copy dev/config.real.example.lua, git-ignored), HOMEDASH_HA_URL (required) and
# a token file (HOMEDASH_TOKEN_FILE, default ~/.homedash-token). No mock is started.
# `shots real` always sets HOMEDASH_ACTIONS=off (buttons never call HA),
# writes out/real-<profile>.png and skips the mock-only shots.
# `shots real refused|timeout` takes one kindle shot against 127.0.0.1:1
# (connection refused) or 192.0.2.1:8123 (timeout): out/real-refused.png,
# out/real-timeout.png. `run real` leaves actions ON (confirm dialogs apply);
# export HOMEDASH_ACTIONS=off to disable them.
#
# Profiles (device pixels):
#   kindle                600x800   @ 167 dpi
#   legacy-paperwhite     758x1024  @ 212 dpi
#   kindle-paperwhite     1072x1448 @ 300 dpi
#
# `run` and `shots` start scripts/mock_ha.py in the background on
# HOMEDASH_MOCK_PORT (default 18123) unless HOMEDASH_HA_URL is already set.
# They export HOMEDASH_HA_URL and, when unset, HOMEDASH_CONFIG=<repo>/dev/config.mock.lua.
# The mock is killed on exit. `mock` runs it in the foreground with --live.
#
# `run` does not rebuild (`./kodev run --no-build`). The process environment
# is inherited, so HOMEDASH_* variables set by the caller reach the emulator.
# Both commands pass a start directory (default $REPO/out/home, override with
# HOMEDASH_HOME_DIR) so the file browser does not list $HOME.
#
# `run` uses `-s <profile>`. HOMEDASH_REAL_PIXELS=1 (Retina Macs) switches to
# `-W/-H` = device size and `-D` = 2x device DPI: SDL renders the window at 2x,
# so KOReader sees a 2x framebuffer at 2x DPI and lays out exactly like the
# device (halving W/H instead made KOReader think the screen was 300x400).
#
# `shots` is headless (SDL_VIDEO_DRIVER=offscreen) and exits KOReader after
# each shot. It writes the three profile PNGs plus kindle-error.png,
# kindle-unavailable.png, kindle-action.png and kindle-action-all.png.
# On macOS it checks the PNG pixel size with sips and prints OK or MISMATCH.
# Override the per-profile limit with HOMEDASH_SHOT_TIMEOUT (seconds, default 60).
# The action shots wait about 8s after the dashboard opens. On timeout only the
# process tree this script started is killed; other emulator windows are left alone.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KOREADER_SRC="${KOREADER_SRC:-$(dirname "$ROOT")/koreader-src}"
SHOT_TIMEOUT="${HOMEDASH_SHOT_TIMEOUT:-60}"
MOCK_PORT="${HOMEDASH_MOCK_PORT:-18123}"
MOCK_PID=""
PROFILES=(kindle legacy-paperwhite kindle-paperwhite)
SHOT_SUMMARY=()
SHOT_FAILED=0
# Prefix of the PNG names written by `shots` ("en-" for `shots en`).
SHOT_PREFIX=""

usage() {
    cat <<EOF
Usage:
  scripts/dev.sh run [kindle|legacy-paperwhite|kindle-paperwhite]
  scripts/dev.sh shots [en]
  scripts/dev.sh mock
  scripts/dev.sh run real [profile]
  scripts/dev.sh shots real [refused|timeout]

KOREADER_SRC defaults to ../koreader-src (a sibling of this repo).
HOMEDASH_HOME_DIR   start directory (default: <repo>/out/home)
HOMEDASH_REAL_PIXELS=1
                    run with -W/-H halved and -D at the device DPI
HOMEDASH_SHOT_TIMEOUT
                    seconds each shots profile may run (default 60)
HOMEDASH_MOCK_PORT  mock port (default 18123)
HOMEDASH_HA_URL     when already set, run/shots do not start a mock (required for real mode)
HOMEDASH_CONFIG     lua config (default, with the mock: <repo>/dev/config.mock.lua)
EOF
}

mtime_of() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"
}

# Device pixels and DPI. Prints "width height dpi".
profile_geometry() {
    case "$1" in
        kindle) printf '%s\n' "600 800 167" ;;
        legacy-paperwhite) printf '%s\n' "758 1024 212" ;;
        kindle-paperwhite) printf '%s\n' "1072 1448 300" ;;
        *)
            echo "error: unknown profile: $1" >&2
            return 1
            ;;
    esac
}

emulator_home_dir() {
    printf '%s\n' "${HOMEDASH_HOME_DIR:-$ROOT/out/home}"
}

find_emulator_dir() {
    local newest="" newest_mtime=0 d mtime
    shopt -s nullglob
    for d in "$KOREADER_SRC"/koreader-emulator-*/koreader; do
        if [[ -d "$d/plugins" ]]; then
            mtime="$(mtime_of "$d")"
            if [[ "$mtime" -gt "$newest_mtime" ]]; then
                newest_mtime="$mtime"
                newest="$d"
            fi
        fi
    done
    shopt -u nullglob
    if [[ -z "$newest" ]]; then
        echo "error: no emulator build at $KOREADER_SRC/koreader-emulator-*/koreader" >&2
        echo "Build it first: cd \"$KOREADER_SRC\" && ./kodev build" >&2
        exit 1
    fi
    printf '%s\n' "$newest"
}

link_plugin() {
    local emu="$1"
    local dest="$emu/plugins/homedash.koplugin"
    local src="$ROOT/homedash.koplugin"
    if [[ ! -d "$src" ]]; then
        echo "error: plugin directory missing: $src" >&2
        exit 1
    fi
    if [[ -L "$dest" ]]; then
        local current
        current="$(readlink "$dest")"
        if [[ "$current" == "$src" ]]; then
            echo "homedash: plugin link ok ($dest)"
            return 0
        fi
        rm "$dest"
    elif [[ -e "$dest" ]]; then
        echo "error: $dest exists and is not a symlink; refusing to replace it" >&2
        exit 1
    fi
    ln -s "$src" "$dest"
    echo "homedash: linked $src -> $dest"
}

require_kodev() {
    if [[ ! -d "$KOREADER_SRC" ]]; then
        echo "error: KOREADER_SRC is not a directory: $KOREADER_SRC" >&2
        exit 1
    fi
    if [[ ! -x "$KOREADER_SRC/kodev" ]]; then
        echo "error: kodev not found in $KOREADER_SRC" >&2
        exit 1
    fi
}

cleanup_mock() {
    if [[ -n "${MOCK_PID}" ]] && kill -0 "$MOCK_PID" 2>/dev/null; then
        kill "$MOCK_PID" 2>/dev/null || true
        wait "$MOCK_PID" 2>/dev/null || true
    fi
    MOCK_PID=""
}

trap cleanup_mock EXIT

start_mock() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo "error: python3 is required to run the mock" >&2
        return 1
    fi
    if ! command -v curl >/dev/null 2>&1; then
        echo "error: curl is required to wait for the mock" >&2
        return 1
    fi
    mkdir -p "$ROOT/out"
    local log="$ROOT/out/mock_ha.log"
    echo "homedash: starting mock on port ${MOCK_PORT} (log ${log})"
    python3 "$ROOT/scripts/mock_ha.py" --port "$MOCK_PORT" >"$log" 2>&1 &
    MOCK_PID=$!
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if curl -sf "http://127.0.0.1:${MOCK_PORT}/__mock/calls" >/dev/null; then
            return 0
        fi
        if ! kill -0 "$MOCK_PID" 2>/dev/null; then
            echo "error: mock exited; see ${log}" >&2
            MOCK_PID=""
            return 1
        fi
        sleep 0.5
    done
    echo "error: mock did not answer on port ${MOCK_PORT}; see ${log}" >&2
    return 1
}

# Start the mock unless the caller already pointed at an HA URL.
prepare_backend() {
    if [[ -n "${HOMEDASH_HA_URL:-}" ]]; then
        echo "homedash: HOMEDASH_HA_URL is set (${HOMEDASH_HA_URL}); not starting a mock"
        return 0
    fi
    start_mock
    export HOMEDASH_HA_URL="http://127.0.0.1:${MOCK_PORT}"
    if [[ -z "${HOMEDASH_CONFIG:-}" ]]; then
        export HOMEDASH_CONFIG="$ROOT/dev/config.mock.lua"
    fi
    echo "homedash: mock ${HOMEDASH_HA_URL} config ${HOMEDASH_CONFIG}"
}

# Real mode: no mock, your own real config. Fails early with a hint when
# something is missing.
prepare_real() {
    local cfg="$ROOT/dev/config.real.lua"
    local tf="${HOMEDASH_TOKEN_FILE:-$HOME/.homedash-token}"
    if [[ ! -f "$cfg" ]]; then
        echo "error: dev/config.real.lua not found (it is git-ignored and yours alone)." >&2
        echo "Create it with: cp dev/config.real.example.lua dev/config.real.lua" >&2
        echo "then edit the entity ids. See docs/development.md." >&2
        exit 1
    fi
    if [[ -z "${HOMEDASH_HA_URL:-}" ]]; then
        echo "error: set HOMEDASH_HA_URL, e.g. HOMEDASH_HA_URL=http://192.168.1.10:8123" >&2
        exit 1
    fi
    if [[ ! -s "$tf" ]]; then
        echo "error: token file missing or empty: $tf" >&2
        echo "Create a long-lived token in Home Assistant and save it there (chmod 600)," >&2
        echo "or set HOMEDASH_TOKEN_FILE. See docs/development.md." >&2
        exit 1
    fi
    export HOMEDASH_CONFIG="$cfg"
    echo "homedash: REAL mode, config ${HOMEDASH_CONFIG}, url ${HOMEDASH_HA_URL}"
}

mock_post() {
    curl -sf -X POST "http://127.0.0.1:${MOCK_PORT}$1" \
        -H 'Content-Type: application/json' \
        --data "$2" >/dev/null
}

# PIDs in the tree rooted at $1, leaves first, so a later reparent cannot hide
# a child we already recorded. Never matches processes outside this tree.
process_tree() {
    local root="$1"
    local child
    local children=""
    children="$(pgrep -P "$root" 2>/dev/null || true)"
    for child in $children; do
        process_tree "$child"
    done
    printf '%s\n' "$root"
}

# Signal every pid in the tree snapshotted before the first kill. A process
# group signal is sent only when $1 is that group's leader (the background
# job started with set -m). Other emulators are not in this tree.
kill_launched_tree() {
    local root="$1"
    local sig="$2"
    shift 2
    local pgid=""
    pgid="$(ps -o pgid= -p "$root" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ -n "$pgid" && "$pgid" == "$root" ]]; then
        kill "-$sig" -"$pgid" 2>/dev/null || true
    fi
    local pid
    for pid in "$@"; do
        kill "-$sig" "$pid" 2>/dev/null || true
    done
}

# Run a command in its own process group and kill that tree after `secs`.
# Returns the command's status, or 124 on timeout.
run_with_timeout() {
    local secs="$1"
    shift
    set -m +b
    "$@" &
    local pid=$!
    local waited=0 rc=0
    while kill -0 "$pid" 2>/dev/null; do
        if [[ "$waited" -ge "$secs" ]]; then
            echo "homedash: timed out after ${secs}s" >&2
            local tree=()
            local line
            while IFS= read -r line; do
                [[ -n "$line" ]] && tree+=("$line")
            done < <(process_tree "$pid")
            echo "homedash: stopping the emulator this script started (${#tree[@]} processes)" >&2
            kill_launched_tree "$pid" TERM "${tree[@]}"
            sleep 2
            kill_launched_tree "$pid" KILL "${tree[@]}"
            wait "$pid" 2>/dev/null || true
            set +m
            return 124
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "$pid" || rc=$?
    set +m
    return "$rc"
}

# macOS: compare PNG pixels to the profile. Elsewhere sips is absent and the
# check is skipped. Prints OK or MISMATCH.
# Returns 0 on OK, 1 on mismatch, 2 when sips is not available.
check_png_size() {
    local png="$1"
    local expect_w="$2"
    local expect_h="$3"
    if ! command -v sips >/dev/null 2>&1; then
        echo "homedash: size check skipped (no sips): $png"
        return 2
    fi
    local info w h
    if ! info="$(sips -g pixelWidth -g pixelHeight "$png" 2>/dev/null)"; then
        echo "homedash: MISMATCH unreadable (expected ${expect_w}x${expect_h}) $png" >&2
        return 1
    fi
    w="$(printf '%s\n' "$info" | awk '/pixelWidth:/ { print $2; exit }')"
    h="$(printf '%s\n' "$info" | awk '/pixelHeight:/ { print $2; exit }')"
    if [[ "$w" == "$expect_w" && "$h" == "$expect_h" ]]; then
        echo "homedash: OK ${w}x${h} $png"
        return 0
    fi
    echo "homedash: MISMATCH ${w:-?}x${h:-?} (expected ${expect_w}x${expect_h}) $png" >&2
    return 1
}

launch_kodev() {
    # A background mock has to outlive kodev, so the shell must stay to run
    # the EXIT trap. With no mock, replace this process as before.
    if [[ -n "${MOCK_PID}" ]]; then
        ./kodev run "$@"
        return
    fi
    exec ./kodev run "$@"
}

cmd_run() {
    local real=0
    if [[ "${1:-}" == "real" ]]; then
        real=1
        shift
    fi
    local profile="${1:-kindle}"
    if [[ $# -gt 1 ]]; then
        usage >&2
        exit 1
    fi
    local geom w h dpi
    if ! geom="$(profile_geometry "$profile")"; then
        usage >&2
        exit 1
    fi
    read -r w h dpi <<<"$geom"
    require_kodev
    local emu home_dir
    emu="$(find_emulator_dir)"
    link_plugin "$emu"
    home_dir="$(emulator_home_dir)"
    mkdir -p "$home_dir"
    if [[ "$real" -eq 1 ]]; then
        prepare_real
    else
        prepare_backend
    fi
    cd "$KOREADER_SRC"
    # --no-build is kodev's flag: run the existing emulator binary.
    if [[ "${HOMEDASH_REAL_PIXELS:-}" == "1" ]]; then
        # On a Retina Mac the SDL window renders at 2x (a 600x800 window is a
        # 1200x1600 framebuffer). Doubling the DPI keeps the layout identical
        # to the device; the window stays the device's size in points.
        local win_dpi=$((dpi * 2))
        echo "homedash: retina ${w}x${h} window, framebuffer $((w*2))x$((h*2)) @ ${win_dpi} dpi (start ${home_dir})"
        launch_kodev --no-build -W "$w" -H "$h" -D "$win_dpi" "$home_dir"
        return
    fi
    echo "homedash: profile ${profile} (start ${home_dir})"
    launch_kodev --no-build -s "$profile" "$home_dir"
}

take_shot() {
    local profile="$1"
    local png="$2"
    local home_dir="$3"
    local expect_w expect_h status size_rc
    read -r expect_w expect_h _ <<<"$(profile_geometry "$profile")"
    rm -f "$png"
    echo "homedash: screenshot profile ${profile} -> ${png} (expect ${expect_w}x${expect_h}, start ${home_dir})"
    export HOMEDASH_SCREENSHOT="$png"
    status=0
    (
        cd "$KOREADER_SRC"
        run_with_timeout "$SHOT_TIMEOUT" \
            ./kodev run --no-build -s "$profile" "$home_dir"
    ) || status=$?
    if [[ ! -f "$png" ]]; then
        echo "homedash: MISSING ${png} (emulator exit ${status})" >&2
        SHOT_SUMMARY+=("MISSING ${png}")
        SHOT_FAILED=1
        return 0
    fi
    size_rc=0
    check_png_size "$png" "$expect_w" "$expect_h" || size_rc=$?
    if [[ "$size_rc" -eq 0 ]]; then
        SHOT_SUMMARY+=("OK      ${png}")
    elif [[ "$size_rc" -eq 2 ]]; then
        SHOT_SUMMARY+=("SKIP    ${png}")
    else
        SHOT_SUMMARY+=("MISMATCH ${png}")
        SHOT_FAILED=1
    fi
    return 0
}

check_action_calls() {
    local needle="$1"
    local calls
    if ! calls="$(curl -sf "http://127.0.0.1:${MOCK_PORT}/__mock/calls")"; then
        echo "homedash: could not read /__mock/calls" >&2
        SHOT_FAILED=1
        return 0
    fi
    echo "homedash: GET /__mock/calls"
    printf '%s\n' "$calls"
    if [[ "$calls" == *script.turn_on* && "$calls" == *"$needle"* ]]; then
        echo "homedash: mock calls OK (${needle})"
        return 0
    fi
    echo "homedash: mock calls MISSING script.turn_on ${needle}" >&2
    SHOT_FAILED=1
    return 0
}

cmd_shots_real() {
    local variant="${1:-}"
    case "$variant" in
        ""|refused|timeout) ;;
        *) usage >&2; exit 1 ;;
    esac
    require_kodev
    local emu home_dir profile
    emu="$(find_emulator_dir)"
    link_plugin "$emu"
    home_dir="$(emulator_home_dir)"
    mkdir -p "$ROOT/out" "$home_dir"
    prepare_real
    export HOMEDASH_ACTIONS=off
    unset HOMEDASH_AUTOACTION
    export SDL_VIDEO_DRIVER=offscreen
    export HOMEDASH_AUTOOPEN=1
    export HOMEDASH_EXIT_AFTER_SHOT=1
    SHOT_SUMMARY=()
    SHOT_FAILED=0
    case "$variant" in
        refused)
            export HOMEDASH_HA_URL="http://127.0.0.1:1"
            take_shot kindle "$ROOT/out/real-refused.png" "$home_dir"
            ;;
        timeout)
            export HOMEDASH_HA_URL="http://192.0.2.1:8123"
            take_shot kindle "$ROOT/out/real-timeout.png" "$home_dir"
            ;;
        *)
            for profile in "${PROFILES[@]}"; do
                take_shot "$profile" "$ROOT/out/real-${profile}.png" "$home_dir"
            done
            ;;
    esac
    echo
    echo "Screenshots:"
    local line
    for line in "${SHOT_SUMMARY[@]}"; do
        echo "  $line"
    done
    if [[ "$SHOT_FAILED" -ne 0 ]]; then
        exit 1
    fi
}

cmd_shots() {
    if [[ "${1:-}" == "real" ]]; then
        shift
        cmd_shots_real "$@"
        return
    fi
    if [[ "${1:-}" == "en" ]]; then
        shift
        SHOT_PREFIX="en-"
        if [[ -z "${HOMEDASH_CONFIG:-}" ]]; then
            export HOMEDASH_CONFIG="$ROOT/dev/config.mock.en.lua"
        fi
    fi
    if [[ $# -ne 0 ]]; then
        usage >&2
        exit 1
    fi
    require_kodev
    local emu home_dir profile
    emu="$(find_emulator_dir)"
    link_plugin "$emu"
    home_dir="$(emulator_home_dir)"
    mkdir -p "$ROOT/out" "$home_dir"
    prepare_backend

    # No window: SDL then reports the real framebuffer size (not Retina 2x).
    export SDL_VIDEO_DRIVER=offscreen
    export HOMEDASH_AUTOOPEN=1
    export HOMEDASH_EXIT_AFTER_SHOT=1
    unset HOMEDASH_AUTOACTION

    SHOT_SUMMARY=()
    SHOT_FAILED=0
    for profile in "${PROFILES[@]}"; do
        if [[ -n "${MOCK_PID}" ]]; then
            mock_post /__mock/reset '{}'
        fi
        take_shot "$profile" "$ROOT/out/${SHOT_PREFIX}${profile}.png" "$home_dir"
    done

    if [[ -n "${MOCK_PID}" ]]; then
        mock_post /__mock/reset '{}'
        mock_post /__mock/scenario '{"force_401":true}'
        take_shot kindle "$ROOT/out/${SHOT_PREFIX}kindle-error.png" "$home_dir"

        mock_post /__mock/reset '{}'
        mock_post /__mock/scenario '{"unavailable":true}'
        take_shot kindle "$ROOT/out/${SHOT_PREFIX}kindle-unavailable.png" "$home_dir"

        mock_post /__mock/reset '{}'
        export HOMEDASH_AUTOACTION=garage
        take_shot kindle "$ROOT/out/${SHOT_PREFIX}kindle-action.png" "$home_dir"
        unset HOMEDASH_AUTOACTION
        check_action_calls "script.otworz_garaz"

        mock_post /__mock/reset '{}'
        export HOMEDASH_AUTOACTION=all
        take_shot kindle "$ROOT/out/${SHOT_PREFIX}kindle-action-all.png" "$home_dir"
        unset HOMEDASH_AUTOACTION
        check_action_calls "script.otworz_wszystko"
    else
        echo "homedash: skipping error, unavailable and action shots (no mock)"
    fi

    echo
    echo "Screenshots:"
    local line
    for line in "${SHOT_SUMMARY[@]}"; do
        echo "  $line"
    done
    if [[ "$SHOT_FAILED" -ne 0 ]]; then
        exit 1
    fi
}

cmd_mock() {
    if [[ $# -ne 0 ]]; then
        usage >&2
        exit 1
    fi
    exec python3 "$ROOT/scripts/mock_ha.py" --port "$MOCK_PORT" --live
}

main() {
    local cmd="${1:-}"
    if [[ $# -gt 0 ]]; then
        shift
    fi
    case "$cmd" in
        run) cmd_run "$@" ;;
        shots) cmd_shots "$@" ;;
        mock) cmd_mock "$@" ;;
        -h|--help|help) usage ;;
        *)
            usage >&2
            exit 1
            ;;
    esac
}

main "$@"
