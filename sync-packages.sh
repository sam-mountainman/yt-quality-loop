#!/bin/bash
set -euo pipefail
# sync-packages.sh — スキルの正本 (codex/skills/yt-loop) を各プラットフォームの
# プラグインパッケージへコピーする。スキルを更新したら必ずこれを実行すること。
#
# 正本: codex/skills/yt-loop/  (Agent Skills 標準の SKILL.md + scripts)
# 配布先:
#   codex-plugin/skills/yt-loop/        (Codex プラグイン)
#   cursor-plugin/skills/yt-loop/       (Cursor プラグイン)
#   antigravity-plugin/skills/yt-loop/  (Antigravity プラグイン — 実験的)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/codex/skills/yt-loop"
[ -d "$SRC" ] || { echo "ERROR: source not found: $SRC"; exit 1; }

for pkg in codex-plugin cursor-plugin antigravity-plugin; do
  DEST="$ROOT/$pkg/skills/yt-loop"
  rm -rf "$DEST"
  mkdir -p "$DEST"
  cp -R "$SRC"/. "$DEST"/
  find "$DEST/scripts" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
  echo "synced -> $pkg/skills/yt-loop"
done

echo "done."
