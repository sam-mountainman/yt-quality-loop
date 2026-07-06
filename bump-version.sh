#!/bin/bash
set -euo pipefail
# bump-version.sh — 散在する version フィールドを一括更新する
# Usage: bump-version.sh <x.y.z>
# 更新後は sync-packages.sh と zip 再生成を忘れないこと (AGENTS.md 参照)

V="${1:?usage: bump-version.sh <x.y.z>}"
[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: version must be x.y.z, got: $V" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES=(
  "$ROOT/.claude-plugin/marketplace.json"
  "$ROOT/.cursor-plugin/marketplace.json"
  "$ROOT/plugins/yt-quality-loop/.claude-plugin/plugin.json"
  "$ROOT/codex-plugin/.codex-plugin/plugin.json"
  "$ROOT/cursor-plugin/.cursor-plugin/plugin.json"
  "$ROOT/antigravity-plugin/plugin.json"
  "$ROOT/antigravity-plugin/gemini-extension.json"
)
for f in "${FILES[@]}"; do
  [ -f "$f" ] || { echo "SKIP (not found): $f"; continue; }
  perl -pi -e 's/"version": "[0-9]+\.[0-9]+\.[0-9]+"/"version": "'"$V"'"/g' "$f"
  jq -e . "$f" >/dev/null
  echo "bumped -> $f"
done
echo "done: $V (次: bash sync-packages.sh && zip 再生成)"
