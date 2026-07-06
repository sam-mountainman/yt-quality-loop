#!/bin/bash
# UserPromptSubmit hook: session_id とループ状態を Claude に注入する
#
# HOOK SAFETY: hook は何があっても exit 0 しなければならない。
# set -euo pipefail は使わない。jq パースはすべて guard で囲む。
#
# 注入するのは最小限:
#   - YT_LOOP_SESSION_ID (skill がスクリプトに渡す用。1 行だけ)
#   - 自セッションのループが active な時だけ、進捗と停滞警告
# 元実装 (eval-loop) にあった .mso/agents/ 全走査は行わない
# (fork/parallel を廃止したので走査対象自体が存在しない)。

if ! command -v jq &>/dev/null; then
  # jq がなければ何も出力せず正常終了（hook を壊さない）
  exit 0
fi

INPUT=$(cat) || exit 0
CWD=$(echo "$INPUT" | jq -r '.cwd // "."' 2>/dev/null) || CWD="."
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || SESSION_ID=""

if [ -z "$SESSION_ID" ]; then
  exit 0
fi

if [[ "$SESSION_ID" =~ [/\\] ]] || [[ "$SESSION_ID" == *..* ]]; then
  exit 0
fi

STATE_FILE="$CWD/.yt-loop/sessions/$SESSION_ID/state.json"

MSG="YT_LOOP_SESSION_ID=$SESSION_ID"

if [ -f "$STATE_FILE" ] && [ "$(jq -r '.active' "$STATE_FILE" 2>/dev/null)" = "true" ]; then
  ITERATION=$(jq -r '.iteration' "$STATE_FILE" 2>/dev/null) || ITERATION="?"
  MAX=$(jq -r '.max_iterations' "$STATE_FILE" 2>/dev/null) || MAX="?"
  SCORE=$(jq -r '.latest_score // "none"' "$STATE_FILE" 2>/dev/null) || SCORE="none"
  THRESHOLD=$(jq -r '.threshold // 90' "$STATE_FILE" 2>/dev/null) || THRESHOLD="90"
  MSG="$MSG | YT loop active (iteration $ITERATION/$MAX, score: $SCORE/100, target: $THRESHOLD)."

  # --- Stale loop watchdog (自セッションのみ) ---
  # active なのに state.json が 30 分以上更新されていなければ停滞の可能性が高い。
  # state.json は全フェーズ遷移で書き換わるため mtime を生存信号に使う。
  # stat は GNU (-c) を先に試す: BSD stat の -c は無出力で即エラーになるが、
  # GNU stat の -f は filesystem status を stdout に吐いて値を汚染するため、この順でないと Linux で壊れる。
  NOW=$(date +%s)
  LMTIME=$(stat -c %Y "$STATE_FILE" 2>/dev/null || stat -f %m "$STATE_FILE" 2>/dev/null) || LMTIME=""
  if [[ "$LMTIME" =~ ^[0-9]+$ ]]; then
    AGE_MIN=$(( (NOW - LMTIME) / 60 ))
    if [ "$AGE_MIN" -ge 30 ]; then
      HOOK_DIR="$(cd "$(dirname "$0")" && pwd 2>/dev/null)" || HOOK_DIR=""
      MSG="$MSG | WARNING: loop appears STALLED (no update for ${AGE_MIN}m). Resume the iteration, or cancel: bash '$HOOK_DIR/loop-cancel.sh' '$STATE_FILE'"
    fi
  fi
fi

# plain text 出力 → Claude のコンテキストに追加される
echo "$MSG"
