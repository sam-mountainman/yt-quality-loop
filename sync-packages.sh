#!/bin/bash
set -euo pipefail
# sync-packages.sh — スキル/agent/hook の正本を各プラットフォームの
# プラグインパッケージへコピーする。配布前に必ずこれを実行すること。
#
# 正本:
#   codex/skills/yt-loop/          (Hook を使わない全環境フォールバック)
#   codex/skills/yt-loop-hook/     (Codex Stop hook 駆動)
#   agents/                        (Cursor/Antigravity 向け agent 定義)
#   codex/agents/                  (Codex custom agent 定義)
#   plugins/yt-quality-loop/scripts (Hook 駆動ループ制御)
#   codex/hooks/                   (Codex plugin hook manifest)
# 配布先:
#   codex-plugin/        (Codex plugin)
#   cursor-plugin/       (Cursor plugin)
#   antigravity-plugin/  (Antigravity plugin — 実験的)

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

HOOK_SKILL_SRC="$ROOT/codex/skills/yt-loop-hook"
if [ -d "$HOOK_SKILL_SRC" ]; then
  DEST="$ROOT/codex-plugin/skills/yt-loop-hook"
  rm -rf "$DEST"
  mkdir -p "$DEST"
  cp -R "$HOOK_SKILL_SRC"/. "$DEST"/
  echo "synced -> codex-plugin/skills/yt-loop-hook"
fi

AGENT_SRC="$ROOT/agents"
if [ -d "$AGENT_SRC" ]; then
  for pkg in cursor-plugin antigravity-plugin; do
    DEST="$ROOT/$pkg/agents"
    rm -rf "$DEST"
    mkdir -p "$DEST"
    cp -R "$AGENT_SRC"/. "$DEST"/
    echo "synced -> $pkg/agents"
  done
fi

CODEX_AGENT_SRC="$ROOT/codex/agents"
if [ -d "$CODEX_AGENT_SRC" ]; then
  DEST="$ROOT/codex-plugin/agents"
  rm -rf "$DEST"
  mkdir -p "$DEST"
  cp -R "$CODEX_AGENT_SRC"/. "$DEST"/
  echo "synced -> codex-plugin/agents"
fi

CODEX_HOOK_SRC="$ROOT/codex/hooks"
if [ -d "$CODEX_HOOK_SRC" ]; then
  DEST="$ROOT/codex-plugin/hooks"
  rm -rf "$DEST"
  mkdir -p "$DEST"
  cp -R "$CODEX_HOOK_SRC"/. "$DEST"/
  echo "synced -> codex-plugin/hooks"
fi

HOOK_SCRIPT_SRC="$ROOT/plugins/yt-quality-loop/scripts"
if [ -d "$HOOK_SCRIPT_SRC" ]; then
  DEST="$ROOT/codex-plugin/scripts"
  rm -rf "$DEST"
  mkdir -p "$DEST"
  cp -R "$HOOK_SCRIPT_SRC"/. "$DEST"/
  # Hook 版 Codex の subagent fresh-marker 用。Claude 版 scripts には無いので追加する。
  cp "$ROOT/codex/skills/yt-loop/scripts/mark-fresh.sh" "$DEST/mark-fresh.sh"
  find "$DEST" -name "*.sh" -exec chmod +x {} \;
  echo "synced -> codex-plugin/scripts"
fi

echo "done."
