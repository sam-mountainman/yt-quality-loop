#!/bin/bash
set -euo pipefail
# install-skills.sh — yt-loop スキルを各 AI エージェント環境にインストールする
#
# Usage: install-skills.sh [codex|cursor|antigravity|all] [プロジェクトパス]
#
#   codex       → ~/.agents/skills + ~/.codex/agents
#   cursor      → <プロジェクトパス>/.cursor/skills + .cursor/agents
#   antigravity → <プロジェクトパス>/.agent/skills + .agent/agents
#   all         → 上記すべて (デフォルト)
#
# プロジェクトパス省略時はカレントディレクトリ。
# Claude Code はこのスクリプトではなくプラグイン (README 参照) を使うこと。

CODEX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$CODEX_DIR/skills"
CODEX_AGENT_DIR="$CODEX_DIR/agents"
SHARED_AGENT_DIR="$(cd "$CODEX_DIR/.." && pwd)/agents"
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

install_codex_agents() {
  [ -d "$CODEX_AGENT_DIR" ] || return 0
  mkdir -p "$HOME/.codex/agents"
  cp -R "$CODEX_AGENT_DIR"/. "$HOME/.codex/agents"/
  echo "installed -> $HOME/.codex/agents"
}

install_shared_agents() {
  local target="$1"
  [ -d "$SHARED_AGENT_DIR" ] || return 0
  mkdir -p "$target"
  cp -R "$SHARED_AGENT_DIR"/. "$target"/
  echo "installed -> $target"
}

case "$ENV" in
  codex)
    install_to "$HOME/.agents/skills"
    install_codex_agents
    if [ -d "$HOME/.codex/skills" ]; then
      install_to "$HOME/.codex/skills"
    fi
    ;;
  cursor)
    install_to "$PROJECT/.cursor/skills"
    install_shared_agents "$PROJECT/.cursor/agents"
    ;;
  antigravity)
    install_to "$PROJECT/.agent/skills"
    install_shared_agents "$PROJECT/.agent/agents"
    ;;
  all)
    install_to "$HOME/.agents/skills"
    install_codex_agents
    if [ -d "$HOME/.codex/skills" ]; then
      install_to "$HOME/.codex/skills"
    fi
    install_to "$PROJECT/.cursor/skills"
    install_shared_agents "$PROJECT/.cursor/agents"
    install_to "$PROJECT/.agent/skills"
    install_shared_agents "$PROJECT/.agent/agents"
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
echo "採点の「まっさらな別の頭」には subagent/custom agent を優先します。使えない時だけ codex exec → 自己採点(開示付き)に縮退します。"
echo "無人実行 (ターミナルから直接、codex CLI 必須):"
echo "  bash yt-loop-runner.sh \"<task>\" [threshold] [max] [criteria]"
