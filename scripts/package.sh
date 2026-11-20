#!/usr/bin/env bash
# Build dist/homedash.koplugin-<version>.zip (and a copy dist/homedash.koplugin.zip)
# from homedash.koplugin/.
#
# The version is read from homedash.koplugin/_meta.lua (`version = "x.y.z"`).
# The zip has one top-level folder, homedash.koplugin/, so unzipping it into
# koreader/plugins/ installs the plugin. Editor and OS leftovers are left out,
# and so is any local homedash_config.lua (that file belongs in koreader/settings/).
#
#   bash scripts/package.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="homedash.koplugin"
META="$ROOT/$PLUGIN/_meta.lua"

if ! command -v zip >/dev/null 2>&1; then
    echo "error: zip is required" >&2
    exit 1
fi

version="$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$META" | head -n 1)"
if [[ -z "$version" ]]; then
    echo "error: no version = \"x.y.z\" in $META" >&2
    exit 1
fi

out_dir="$ROOT/dist"
zip_path="$out_dir/$PLUGIN-$version.zip"
mkdir -p "$out_dir"
# Rebuild from scratch so removed files do not linger in an old archive.
if [[ -e "$zip_path" ]]; then
    echo "package.sh: $zip_path exists; remove it to rebuild:" >&2
    echo "  rm \"$zip_path\"" >&2
    exit 1
fi

cd "$ROOT"
find "$PLUGIN" -type f \
    ! -name '.DS_Store' ! -name '*.swp' ! -name '*~' ! -name 'homedash_config.lua' \
    | LC_ALL=C sort \
    | zip -X -q "$zip_path" -@

# Stable name for https://github.com/<owner>/<repo>/releases/latest/download/homedash.koplugin.zip
cp "$zip_path" "$out_dir/$PLUGIN.zip"
echo "package.sh: $zip_path (+ $out_dir/$PLUGIN.zip)"
unzip -l "$zip_path" | tail -n +4 | sed '$d' | sed '$d'
