#!/bin/bash
set -euo pipefail
# loop-judge.sh — 続行/終了の判定を「人と AI からシェルの整数比較へ」渡す心臓部 (スキル環境版)
# Usage: loop-judge.sh <run_dir> <NNN>
#
# 出力 (1 行目が判定):
#   CONTINUE ...       : 次のイテレーションへ (feedback を続けて表示)
#   STOP ...           : ループ終了 (理由と best を表示)
#   INVALID ...        : eval JSON が契約違反 (evaluator を再実行して再判定)
#   ALREADY_JUDGED ... : 同じ turn を二重判定しようとした (state は変更しない)
#
# AI はこの判定に一切関わらない。やっているのは整数比較と契約検証だけ。

RUN_DIR="${1:?usage: loop-judge.sh <run_dir> <NNN>}"
NNN="${2:?usage: loop-judge.sh <run_dir> <NNN>}"

if ! command -v jq &>/dev/null; then
  echo "INVALID: jq not found"
  exit 1
fi

STATE="$RUN_DIR/state.json"
EVAL_FILE="$RUN_DIR/turn-$NNN-eval.json"

[ -f "$STATE" ] || { echo "INVALID: state not found: $STATE"; exit 1; }

best_line() {
  local bi bs
  bi=$(jq -r '.best_iteration // "null"' "$STATE" 2>/dev/null || echo null)
  bs=$(jq -r '.best_score // "null"' "$STATE" 2>/dev/null || echo null)
  if [[ "$bi" =~ ^[0-9]+$ ]]; then
    echo "BEST: iter $bi (score $bs) -> $RUN_DIR/turn-$(printf '%03d' "$bi")-output.md"
  else
    echo "BEST: none (合格評価なし — 納品できるベスト版はない)"
  fi
}

ACTIVE=$(jq -r '.active' "$STATE" 2>/dev/null || echo false)
if [ "$ACTIVE" != "true" ]; then
  echo "STOP: loop is not active (ended_reason: $(jq -r '.ended_reason' "$STATE"))"
  best_line
  exit 0
fi

# --- 二重判定ガード (同じ turn で judge を 2 回呼んでも state を壊さない) ---
LAST_JUDGED=$(jq -r '.last_judged_nnn // ""' "$STATE" 2>/dev/null || echo "")
if [ "$LAST_JUDGED" = "$NNN" ]; then
  echo "ALREADY_JUDGED: turn $NNN は判定済み (state 変更なし)。iteration $(jq -r '.iteration' "$STATE")/$(jq -r '.max_iterations' "$STATE"), latest_score $(jq -r '.latest_score' "$STATE") — 前回の判定に従って次へ進むこと"
  exit 0
fi

[ -f "$EVAL_FILE" ] || { echo "INVALID: eval file not found: $EVAL_FILE"; exit 1; }

# --- eval JSON の契約検証 (グッドハート対策の型枠) ---
if ! jq -e . "$EVAL_FILE" >/dev/null 2>&1; then
  echo "INVALID: eval file is not valid JSON"
  exit 1
fi
SCORE=$(jq -r '.score' "$EVAL_FILE" 2>/dev/null || echo "")
if ! [[ "$SCORE" =~ ^[0-9]+$ ]] || [ "$SCORE" -gt 100 ]; then
  echo "INVALID: score must be an integer 0-100, got: '$SCORE'"
  exit 1
fi
OVERALL=$(jq -r '.quality.overall // "missing"' "$EVAL_FILE" 2>/dev/null || echo missing)
if [ "$OVERALL" != "$SCORE" ]; then
  echo "INVALID: quality.overall ($OVERALL) must equal score ($SCORE)"
  exit 1
fi
FEEDBACK_OK=$(jq -r 'if (.feedback | type) == "string" and (.feedback | length) >= 60 then "yes" else "no" end' "$EVAL_FILE" 2>/dev/null || echo no)
if [ "$FEEDBACK_OK" != "yes" ]; then
  echo "INVALID: feedback must be a string of >= 60 chars (直し方が返らないループは同じ失敗を繰り返すだけ)"
  exit 1
fi

# feedback コピペ検知 (前 turn と一言一句同じ feedback = 採点した振り)
ITER_CHECK=$((10#$NNN))
if [ "$ITER_CHECK" -gt 0 ]; then
  PREV_EVAL_FILE="$RUN_DIR/turn-$(printf '%03d' $((ITER_CHECK - 1)))-eval.json"
  if [ -f "$PREV_EVAL_FILE" ]; then
    CUR_FB=$(jq -r '.feedback // ""' "$EVAL_FILE" 2>/dev/null || echo "")
    PREV_FB=$(jq -r '.feedback // ""' "$PREV_EVAL_FILE" 2>/dev/null || echo "")
    if [ -n "$CUR_FB" ] && [ "$CUR_FB" = "$PREV_FB" ]; then
      echo "INVALID: feedback is identical to the previous turn (copy-paste) — 採点をやり直すこと"
      exit 1
    fi
  fi
fi

# breakdown キーは criteria と過不足なく一致すること (点の取りやすい軸への逃げの封じ)
CRITERIA=$(jq -r '.criteria // ""' "$STATE" 2>/dev/null || echo "")
if [ -n "$CRITERIA" ]; then
  REQ=$(printf '%s' "$CRITERIA" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true)
  ACT=$(jq -r '(.quality.breakdown // {}) | keys_unsorted | join("\n")' "$EVAL_FILE" 2>/dev/null || echo "")
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    if ! printf '%s\n' "$ACT" | grep -qxF "$k"; then
      echo "INVALID: breakdown is missing required key: '$k'"
      exit 1
    fi
  done <<< "$REQ"
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    if ! printf '%s\n' "$REQ" | grep -qxF "$k"; then
      echo "INVALID: breakdown has an extra key not in criteria: '$k'"
      exit 1
    fi
  done <<< "$ACT"
fi

# --- fresh eval の証明確認 (自己採点の検知と開示 — 禁止はしない) ---
hash_file() {
  if command -v shasum &>/dev/null; then
    shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
  elif command -v sha256sum &>/dev/null; then
    sha256sum "$1" 2>/dev/null | cut -d' ' -f1
  else
    echo "NOHASH"
  fi
}
MARKER="$RUN_DIR/turn-$NNN-eval.fresh"
SELF_SCORED="true"
if [ -f "$MARKER" ]; then
  EXPECT=$(cat "$MARKER" 2>/dev/null || echo "")
  ACTUAL=$(hash_file "$EVAL_FILE")
  if [ -n "$EXPECT" ] && [ "$EXPECT" = "$ACTUAL" ]; then
    SELF_SCORED="false"
  fi
fi

THRESHOLD=$(jq -r '.threshold' "$STATE")
MAX=$(jq -r '.max_iterations' "$STATE")
[[ "$THRESHOLD" =~ ^[0-9]+$ ]] || { echo "INVALID: state threshold is not an integer"; exit 1; }
[[ "$MAX" =~ ^[1-9][0-9]*$ ]] || { echo "INVALID: state max_iterations is not a positive integer"; exit 1; }
ITER=$((10#$NNN))
STARTED_AT=$(jq -r '.started_at // 0' "$STATE")
MAX_WALL=$(jq -r '.max_wall_minutes // 0' "$STATE")
NOW=$(date +%s)

# --- 進捗ゼロ検知の材料 (2 回連続で点が上がらなければ堂々巡り) ---
PREV_SCORE=$(jq -r '.prev_score // "null"' "$STATE" 2>/dev/null || echo null)
NP_COUNT=$(jq -r '.no_progress_count // 0' "$STATE" 2>/dev/null || echo 0)
[[ "$NP_COUNT" =~ ^[0-9]+$ ]] || NP_COUNT=0
if [[ "$PREV_SCORE" =~ ^-?[0-9]+$ ]] && [ "$SCORE" -le "$PREV_SCORE" ]; then
  NP_COUNT=$((NP_COUNT + 1))
else
  NP_COUNT=0
fi

# --- state 更新 (latest / best / 進捗カウンタ / 判定済みマーク / 自己採点の記録) ---
jq --argjson s "$SCORE" --argjson i "$ITER" --argjson np "$NP_COUNT" \
   --arg nnn "$NNN" --argjson self "$SELF_SCORED" \
  '.latest_score = $s | .iteration = $i | .prev_score = $s | .no_progress_count = $np
   | .last_judged_nnn = $nnn
   | (if $self then .self_scored = ((.self_scored // []) + [$i]) else . end)
   | (if (.best_score == null or $s > .best_score) then .best_score = $s | .best_iteration = $i else . end)' \
  "$STATE" > "$STATE.tmp.$$" && mv "$STATE.tmp.$$" "$STATE"

self_note() {
  if [ "$SELF_SCORED" = "true" ]; then
    echo "NOTE: SELF-SCORED — この採点は fresh eval の証明 (turn-$NNN-eval.fresh) が無い。自己採点は甘くなりがち。最終報告で自己採点だったことを必ず開示すること"
  fi
}

BEST_ITER=$(jq -r '.best_iteration' "$STATE")
BEST_SCORE=$(jq -r '.best_score' "$STATE")
BEST_FILE="$RUN_DIR/turn-$(printf '%03d' "$BEST_ITER")-output.md"

finish() {
  local reason="$1" label="$2"
  jq --arg r "$reason" '.active = false | .ended_reason = $r' "$STATE" > "$STATE.tmp.$$" && mv "$STATE.tmp.$$" "$STATE"
  echo "STOP: $label"
  echo "BEST: iter $BEST_ITER (score $BEST_SCORE) -> $BEST_FILE"
  self_note
}

# --- 判定 (整数比較のみ) ---
if [ "$SCORE" -ge "$THRESHOLD" ]; then
  finish "threshold_met" "score $SCORE >= threshold $THRESHOLD — 合格"
  exit 0
fi

if [ $((ITER + 1)) -ge "$MAX" ]; then
  finish "max_iterations" "max iterations reached ($MAX) — best を納品して終了"
  exit 0
fi

if [[ "$STARTED_AT" =~ ^[1-9][0-9]*$ ]] && [[ "$MAX_WALL" =~ ^[1-9][0-9]*$ ]] \
   && [ $((NOW - STARTED_AT)) -ge $((MAX_WALL * 60)) ]; then
  finish "wall_clock_exceeded" "wall-clock ${MAX_WALL}min exceeded — best を納品して終了"
  exit 0
fi

if [ "$NP_COUNT" -ge 2 ]; then
  finish "no_progress" "2 回連続でスコアが上がらない (堂々巡り) — best を納品して人間に相談"
  exit 0
fi

NEXT=$(printf '%03d' $((ITER + 1)))
echo "CONTINUE: iteration $((ITER + 1))/$MAX (score $SCORE < threshold $THRESHOLD)"
echo "NEXT: turn-$NEXT-plan.md を書き、feedback を反映した turn-$NEXT-output.md を生成して再評価する"
self_note
echo "--- feedback ---"
jq -r '.feedback' "$EVAL_FILE"
