#!/bin/bash
set -euo pipefail
# install-skills.sh — yt-loop スキルを各 AI エージェント環境にインストールする
#
# Usage: install-skills.sh [codex|cursor|antigravity|all] [プロジェクトパス]
#
#   codex       → ~/.agents/skills (グローバル。旧 ~/.codex/skills があればそちらにも)
#   cursor      → <プロジェクトパス>/.cursor/skills (プロジェクト単位)
#   antigravity → <プロジェクトパス>/.agent/skills (プロジェクト単位)
#   all         → 上記すべて (デフォルト)
#
# プロジェクトパス省略時はカレントディレクトリ。
# Claude Code はこのスクリプトではなくプラグイン (README 参照) を使うこと。

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/skills"
[ -d "$SRC_DIR" ] || { echo "ERROR: skills directory not found: $SRC_DIR"; exit 1; }

ENV="${1:-all}"
PROJECT="${2:-$PWD}"

install_to() {
  local target="$1"
  mkdir -p "$target"
  cp -R "$SRC_DIR"/. "$target"/
  find "$target/yt-loop/scripts" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
  echo "installed -> $target"
}

case "$ENV" in
  codex)
    install_to "$HOME/.agents/skills"
    if [ -d "$HOME/.codex/skills" ]; then
      install_to "$HOME/.codex/skills"
    fi
    ;;
  cursor)
    install_to "$PROJECT/.cursor/skills"
    ;;
  antigravity)
    install_to "$PROJECT/.agent/skills"
    ;;
  all)
    install_to "$HOME/.agents/skills"
    if [ -d "$HOME/.codex/skills" ]; then
      install_to "$HOME/.codex/skills"
    fi
    install_to "$PROJECT/.cursor/skills"
    install_to "$PROJECT/.agent/skills"
    ;;
  *)
    echo "usage: install-skills.sh [codex|cursor|antigravity|all] [プロジェクトパス]" >&2
    exit 1
    ;;
esac

echo ""
echo "完了。使い方:"
echo "  Codex:       \$yt-loop 台本: ○○ (threshold: 90)   ※ /skills で一覧確認"
echo "  Cursor:      チャットで「yt-loop で台本を合格まで磨いて: ○○」と依頼 (自動発動)"
echo "  Antigravity: 同上"
echo ""
echo "採点の「まっさらな別の頭」には codex CLI を使います (無ければ自己採点に自動フォールバック)。"
echo "無人実行 (ターミナルから直接、codex CLI 必須):"
echo "  bash yt-loop-runner.sh \"<task>\" [threshold] [max] [criteria]"
