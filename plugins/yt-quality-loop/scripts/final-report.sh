#!/bin/bash
set -euo pipefail
# final-report.sh — state.json から納品物コピーと最終レポートを決定論的に生成する。
# Usage: final-report.sh <state_file> [output_file]

STATE="${1:?usage: final-report.sh <state_file> [output_file]}"
OUT_FILE="${2:-}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found" >&2; exit 1; }
[ -f "$STATE" ] || { echo "ERROR: state not found: $STATE" >&2; exit 1; }

PROJECT_DIR="$(jq -r '.project_dir // "."' "$STATE")"
TURNS_DIR="$(jq -r '.turns_dir // ""' "$STATE")"
BEST_ITER="$(jq -r '.best_iteration // "null"' "$STATE")"
BEST_SCORE="$(jq -r '.best_score // "null"' "$STATE")"
ENDED_REASON="$(jq -r '.ended_reason // "unknown"' "$STATE")"
THRESHOLD="$(jq -r '.threshold // 90' "$STATE")"

if [ -z "$OUT_FILE" ]; then
  OUT_FILE="$PROJECT_DIR/yt-loop-output-$(date +%Y%m%d-%H%M%S).md"
fi

echo "# YT Quality Loop Final Report"
echo ""
echo "- State: $STATE"
echo "- Ended reason: $ENDED_REASON"
echo "- Threshold: $THRESHOLD"

if ! [[ "$BEST_ITER" =~ ^[0-9]+$ ]]; then
  echo "- Deliverable: none"
  echo ""
  echo "## 次に直すこと"
  echo ""
  echo "合格評価が一度も無かったため納品物はコピーしていません。task に「誰向け / 長さ / 入れる内容 / 完成条件」を足して再実行してください。"
  exit 0
fi

BEST_NNN="$(printf '%03d' "$BEST_ITER")"
BEST_FILE="$TURNS_DIR/turn-$BEST_NNN-output.md"
BEST_EVAL="$TURNS_DIR/turn-$BEST_NNN-eval.json"

if [ ! -s "$BEST_FILE" ]; then
  echo "- Deliverable: missing ($BEST_FILE)"
  exit 1
fi

mkdir -p "$(dirname "$OUT_FILE")"
cp "$BEST_FILE" "$OUT_FILE"

echo "- Deliverable: $OUT_FILE"
echo "- Best iteration: $BEST_ITER"
echo "- Best score: $BEST_SCORE"
echo ""

echo "## スコア推移"
echo ""
scores=()
if [ -n "$TURNS_DIR" ] && [ -d "$TURNS_DIR" ]; then
  while IFS= read -r file; do
    s="$(jq -r '.score // empty' "$file" 2>/dev/null || true)"
    if [[ "$s" =~ ^[0-9]+$ ]]; then
      scores+=("$s")
    fi
  done < <(find "$TURNS_DIR" -name 'turn-*-eval.json' -type f | sort)
fi
if [ "${#scores[@]}" -gt 0 ]; then
  joined="${scores[0]}"
  for ((idx=1; idx<${#scores[@]}; idx++)); do
    joined="$joined -> ${scores[$idx]}"
  done
  printf '%s\n' "$joined"
else
  echo "記録なし"
fi

echo ""
echo "## 内訳"
echo ""
if [ -f "$BEST_EVAL" ]; then
  jq -r '(.quality.breakdown // {}) | to_entries[] | "- \(.key): \(.value)"' "$BEST_EVAL" 2>/dev/null || true
fi

echo ""
echo "## 残った改善余地"
echo ""
if [ -f "$BEST_EVAL" ]; then
  jq -r '.feedback // "記録なし"' "$BEST_EVAL" 2>/dev/null || echo "記録なし"
else
  echo "記録なし"
fi

self_scored="$(jq -r '(.self_scored // []) | join(", ")' "$STATE" 2>/dev/null || true)"
if [ -n "$self_scored" ]; then
  echo ""
  echo "## 採点メモ"
  echo ""
  echo "自己採点に落ちた周回: $self_scored"
  echo "これは fresh な採点係が使えなかった時のフォールバックです。fresh 採点より甘くなる可能性があります。"
fi

echo ""
echo "## 次回への反映"
echo ""
echo "- 納品物を手直ししたら /yt-profile 更新 で直しを次回に反映できます。"
echo "- スコアは同一成果物でも±数点ブレます。90点は再生数保証ではなく、公開前の品質基準です。"
