#!/usr/bin/env bash
# Copy homedash.koplugin to a device that runs KOReader's SSH server and verify it.
#
#   KINDLE_HOST=192.168.1.50 bash scripts/deploy.sh
#
# Environment:
#   KINDLE_HOST    required, the device's IP address
#   KINDLE_PORT    SSH port of KOReader's SSH server (default 2222)
#   KINDLE_USER    SSH user (default root)
#   KOREADER_DIR   KOReader directory on the device (default /mnt/us/koreader)
#   DRY_RUN=1      print what would run, change nothing
#
# On the device: Tools -> SSH server -> Start (allow connections), and put your
# public key into koreader/settings/SSH/authorized_keys.
#
# What it does:
#   1. replaces $KOREADER_DIR/plugins/homedash.koplugin with this checkout's copy
#      (tar piped through ssh; files removed from the plugin disappear on the device)
#   2. checks the md5 of every file on the device against the local one
# It never touches koreader/settings/ (your homedash_config.lua and token file
# live there). Restart KOReader afterwards so the new code is loaded.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="homedash.koplugin"
HOST="${KINDLE_HOST:-}"
PORT="${KINDLE_PORT:-2222}"
USER_NAME="${KINDLE_USER:-root}"
KODIR="${KOREADER_DIR:-/mnt/us/koreader}"
DRY_RUN="${DRY_RUN:-0}"

if [[ -z "$HOST" ]]; then
    echo "error: set KINDLE_HOST, e.g. KINDLE_HOST=192.168.1.50 bash scripts/deploy.sh" >&2
    exit 1
fi
if [[ ! -d "$ROOT/$PLUGIN" ]]; then
    echo "error: $ROOT/$PLUGIN not found" >&2
    exit 1
fi

SSH=(ssh -p "$PORT" -o ConnectTimeout=10 "$USER_NAME@$HOST")

md5_of_stdin() {
    if command -v md5sum >/dev/null 2>&1; then
        md5sum | awk '{print $1}'
    else
        md5 -r | awk '{print $1}'
    fi
}

cd "$ROOT"
files=()
while IFS= read -r f; do
    files+=("$f")
done < <(find "$PLUGIN" -type f ! -name '.DS_Store' ! -name '*.swp' ! -name '*~' ! -name 'homedash_config.lua' | LC_ALL=C sort)

# "<md5>  <path>" lines, as md5sum prints them.
sums="$(
    for f in "${files[@]}"; do
        printf '%s  %s\n' "$(md5_of_stdin <"$f")" "$f"
    done
)"

echo "deploy.sh: ${#files[@]} files -> $USER_NAME@$HOST:$PORT $KODIR/plugins/$PLUGIN"
if [[ "$DRY_RUN" == "1" ]]; then
    echo "deploy.sh: DRY_RUN, not connecting. Local md5 list:"
    printf '%s\n' "$sums"
    exit 0
fi

# Only the plugin folder is replaced; settings/ is never touched.
# COPYFILE_DISABLE / --no-xattrs: no macOS ._ files or pax xattr headers
# (old busybox tar on Kindles warns about them).
tar_opts=()
if tar --version 2>/dev/null | grep -qi bsdtar; then tar_opts=(--no-xattrs --no-mac-metadata); fi
COPYFILE_DISABLE=1 tar "${tar_opts[@]}" -cf - "${files[@]}" | "${SSH[@]}" "set -e; mkdir -p '$KODIR/plugins'; cd '$KODIR/plugins'; rm -rf '$PLUGIN'; tar -xf -"

echo "deploy.sh: verifying md5 on the device"
# Old busybox md5sum has no -c, so compare "<md5>  <path>" lists instead.
remote_sums="$("${SSH[@]}" "cd '$KODIR/plugins' && find '$PLUGIN' -type f | sort | while read -r f; do md5sum \"\$f\"; done")"
if diff <(printf '%s\n' "$sums" | LC_ALL=C sort) <(printf '%s\n' "$remote_sums" | LC_ALL=C sort) >/dev/null; then
    echo "deploy.sh: OK, all ${#files[@]} files match. Restart KOReader to load the new code."
else
    echo "deploy.sh: MISMATCH between local and device files:" >&2
    diff <(printf '%s\n' "$sums" | LC_ALL=C sort) <(printf '%s\n' "$remote_sums" | LC_ALL=C sort) >&2 || true
    exit 1
fi
