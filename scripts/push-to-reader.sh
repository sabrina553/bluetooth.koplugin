#!/usr/bin/env bash
# Copy the working tree's plugin onto the PocketBook over SSH for quick testing.
# Backs up the reader's current copy first. Local helper, not tracked in git.
# Usage: scripts/push-to-reader.sh [ssh-host]   (default host alias: pocketbook)
set -euo pipefail

host="${1:-pocketbook}"
remote_dir=/mnt/ext1/applications/koreader/plugins
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backup="$HOME/.claude/file-backups/$(date +%F)/reader"

cd "$repo"

echo "Running tests..."
for t in tests/*_test.lua; do
    luajit "$t" >/dev/null || { echo "FAILED: $t" >&2; exit 1; }
done

mkdir -p "$backup"
ssh -o BatchMode=yes "$host" "cd $remote_dir && tar -cf - bluetooth.koplugin" | tar -xf - -C "$backup"
echo "Backed up reader copy to $backup/bluetooth.koplugin"

tar -cf - bluetooth.koplugin | ssh -o BatchMode=yes "$host" "cd $remote_dir && tar -xf -"
echo "Pushed. Restart KOReader on the reader to load it."
