#!/bin/bash
set -euo pipefail
# YT quality loop を開始する
# Usage: loop-start.sh <cwd> <max_iterations> <threshold> <session_id> [--max-wall-minutes <N>]
#
# デフォルト: max 6 回 / threshold 90 点 / wall-clock 120 分。
# 3 重の停止条件 (点数・回数・時間) を必ず全部持つ — どれか 1 つだけだと
# 「無限ループ」「早期妥協」「良し悪しを見ないまま終了」のどれかの事故になる。

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq が見つかりません。このプラグインは jq (JSON 処理ツール) が必要です。" >&2
  echo "  macOS:        brew install jq" >&2
  echo "  Windows(WSL): sudo apt install jq" >&2
  exit 1
fi

CWD="${1:-.}"
MAX="${2:-6}"
THRESHOLD="${3:-90}"
SESSION_ID="${4:?session_id is required}"

MAX_WALL_MINUTES="120"
shift 4 || true
while [ $# -gt 0 ]; do
  case "$1" in
    --max-wall-minutes)
      MAX_WALL_MINUTES="${2:?--max-wall-minutes requires a value}"
      shift 2
      ;;
    --*)
      echo "ERROR: unknown option: '$1'" >&2
      exit 1
      ;;
    *)
      shift
      ;;
  esac
done

# --- 入力バリデーション ---
if ! [[ "$MAX" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: max_iterations must be a positive integer, got: '$MAX'" >&2
  exit 1
fi

if ! [[ "$THRESHOLD" =~ ^[0-9]+$ ]] || [ "$THRESHOLD" -gt 100 ]; then
  echo "ERROR: threshold must be an integer 0-100, got: '$THRESHOLD'" >&2
  exit 1
fi

if [[ "$SESSION_ID" =~ [/\\] ]] || [[ "$SESSION_ID" == *..* ]]; then
  echo "ERROR: session_id must not contain path separators or '..': '$SESSION_ID'" >&2
  exit 1
fi

# leading zero は --argjson が invalid JSON として拒否するため regex 側で弾く
if ! [[ "$MAX_WALL_MINUTES" =~ ^(0|[1-9][0-9]*)$ ]]; then
  echo "ERROR: --max-wall-minutes must be a non-negative integer (0 = disabled), got: '$MAX_WALL_MINUTES'" >&2
  exit 1
fi

if [ ! -d "$CWD" ]; then
  echo "ERROR: Working directory does not exist: $CWD" >&2
  exit 1
fi

PROJECT_DIR="$(cd "$CWD" && pwd)"
SESSION_DIR="$PROJECT_DIR/.yt-loop/sessions/$SESSION_ID"
TURNS_DIR="$SESSION_DIR/turns"
STATE_FILE="$SESSION_DIR/state.json"

# 既にアクティブなら警告して止める (二重起動防止)
if [ -f "$STATE_FILE" ] && [ "$(jq -r '.active' "$STATE_FILE" 2>/dev/null)" = "true" ]; then
  ITER=$(jq -r '.iteration' "$STATE_FILE")
  MMAX=$(jq -r '.max_iterations' "$STATE_FILE")
  echo "YT loop already active (iteration $ITER/$MMAX). Cancel first with /yt-loop-cancel"
  exit 0
fi

# 前回のターン履歴をアーカイブ（同一セッションで再ループ時の残骸と混ざるのを防ぐ。
# 元実装は rm -f で消していたが、成果物ごと消えるのはもったいないので退避に変更）
if [ -d "$TURNS_DIR" ] && ls "$TURNS_DIR"/turn-* >/dev/null 2>&1; then
  ARCHIVE_DIR="$SESSION_DIR/archive-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$ARCHIVE_DIR"
  mv "$TURNS_DIR"/turn-* "$ARCHIVE_DIR"/ 2>/dev/null || true
fi
mkdir -p "$TURNS_DIR"

jq -n \
  --argjson max "$MAX" \
  --argjson threshold "$THRESHOLD" \
  --argjson started_at "$(date +%s)" \
  --argjson max_wall "$MAX_WALL_MINUTES" \
  --arg session_id "$SESSION_ID" \
  --arg project_dir "$PROJECT_DIR" \
  --arg turns_dir "$TURNS_DIR" \
  '{
    loop_type: "yt-quality",
    active: true,
    iteration: 0,
    max_iterations: $max,
    threshold: $threshold,
    started_at: $started_at,
    max_wall_minutes: $max_wall,
    ended_reason: null,
    session_id: $session_id,
    project_dir: $project_dir,
    task: "",
    criteria: "",
    generator_skill: "assign-yt-generator",
    evaluator_skill: "assign-yt-evaluator",
    latest_score: null,
    evaluated_iteration: null,
    eval_repair_attempts: 0,
    best_score: null,
    best_iteration: null,
    prev_score: null,
    no_progress_count: 0,
    mech_ng: false,
    mech_ng_count: 0,
    config_fingerprint: null,
    turns_dir: $turns_dir,
    phase: "plan",
    latest_plan: null
  }' > "$STATE_FILE.tmp.$$" && mv "$STATE_FILE.tmp.$$" "$STATE_FILE"

echo "YT loop ACTIVATED (max: $MAX, threshold: $THRESHOLD, wall: ${MAX_WALL_MINUTES}min, session: $SESSION_ID)"
echo "Turns dir: $TURNS_DIR"
echo "State file: $STATE_FILE"
