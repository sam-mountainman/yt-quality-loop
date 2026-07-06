#!/bin/bash
set -euo pipefail
# loop-init.sh — Codex 版 YT quality loop の状態を初期化する
# Usage: loop-init.sh <task> <criteria> [threshold] [max] [max_wall_minutes]

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq が見つかりません。macOS: brew install jq / WSL: sudo apt install jq" >&2
  exit 1
fi

TASK="${1:?usage: loop-init.sh <task> <criteria> [threshold] [max] [max_wall_minutes]}"
CRITERIA="${2:?usage: loop-init.sh <task> <criteria> [threshold] [max] [max_wall_minutes]}"
THRESHOLD="${3:-90}"
MAX="${4:-6}"
MAX_WALL="${5:-120}"

if ! [[ "$THRESHOLD" =~ ^[0-9]+$ ]] || [ "$THRESHOLD" -gt 100 ]; then
  echo "ERROR: threshold must be 0-100, got: '$THRESHOLD'" >&2
  exit 1
fi
if ! [[ "$MAX" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: max must be a positive integer, got: '$MAX'" >&2
  exit 1
fi
if ! [[ "$MAX_WALL" =~ ^(0|[1-9][0-9]*)$ ]]; then
  echo "ERROR: max_wall_minutes must be a non-negative integer, got: '$MAX_WALL'" >&2
  exit 1
fi

RUN_DIR="$PWD/.yt-loop/codex/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"

printf '%s\n' "$TASK" > "$RUN_DIR/task.md"

jq -n \
  --argjson threshold "$THRESHOLD" \
  --argjson max "$MAX" \
  --argjson max_wall "$MAX_WALL" \
  --argjson started_at "$(date +%s)" \
  --arg criteria "$CRITERIA" \
  '{
    active: true,
    iteration: 0,
    max_iterations: $max,
    threshold: $threshold,
    max_wall_minutes: $max_wall,
    started_at: $started_at,
    criteria: $criteria,
    latest_score: null,
    best_score: null,
    best_iteration: null,
    ended_reason: null
  }' > "$RUN_DIR/state.json"

echo "YT loop (codex) ACTIVATED (max: $MAX, threshold: $THRESHOLD, wall: ${MAX_WALL}min)"
echo "RUN_DIR:$RUN_DIR"
