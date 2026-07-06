#!/bin/bash
set -euo pipefail
# validate-eval.sh — evaluator が書いた採点 JSON を機械検証する (グッドハート対策の型枠)
# Usage: validate-eval.sh <eval_file> <schema_file|-> <threshold> [criteria]
#
# 検証に落ちた採点は「不合格 (score 無効)」として扱われる。
# evaluator が「合格です」と書いてきても、形が契約と違えば信じない。
# Stop hook の pass gate も合格判定の直前にこのスクリプトを再実行する。
#
# チェック内容:
#   1. eval_file が valid JSON である
#   2. .score が 0-100 の整数である
#   3. .quality.overall が .score と一致する (重み付けのブレを塞ぐ契約)
#   4. .feedback が 60 文字以上の文字列である (直し方が返らないループは RALPH と同じ)
#   5. .passed があれば score >= threshold と一致する (無くてもよい — 合否は機械が決める)
#   6. schema_file に breakdown_keys があれば、.quality.breakdown のキーが
#      その固定キーと過不足なく一致する。schema が無い場合でも criteria (第4引数、
#      カンマ区切り) があればそのキー集合で同じ検証を行う (汎用 evaluator の抜け穴封じ)
#   7. schema_file に skill 名があれば .evaluator_skill が一致する (なりすまし防止)
#   8. schema の全キーに weight があれば、overall <= 加重平均 + 5 を要求する
#      (「総合判断」の上方向乱用の封じ。下方向 = 致命傷を薄めない判断は自由のまま)
#
# 出力: OK なら "OK" / 違反があれば "INVALID: <理由>" を列挙して exit 1

EVAL_FILE="${1:?usage: validate-eval.sh <eval_file> <schema_file|-> <threshold> [criteria]}"
SCHEMA_FILE="${2:--}"
THRESHOLD="${3:?usage: validate-eval.sh <eval_file> <schema_file|-> <threshold> [criteria]}"
CRITERIA="${4:-}"

if ! command -v jq &>/dev/null; then
  echo "INVALID: jq not found"
  exit 1
fi

if [ ! -f "$EVAL_FILE" ]; then
  echo "INVALID: eval file not found: $EVAL_FILE"
  exit 1
fi

if ! jq -e . "$EVAL_FILE" >/dev/null 2>&1; then
  echo "INVALID: eval file is not valid JSON: $EVAL_FILE"
  exit 1
fi

if ! [[ "$THRESHOLD" =~ ^[0-9]+$ ]]; then
  echo "INVALID: threshold is not an integer: $THRESHOLD"
  exit 1
fi

ERRORS=()

# 2. score は 0-100 の整数
SCORE=$(jq -r '.score' "$EVAL_FILE" 2>/dev/null || echo "")
if ! [[ "$SCORE" =~ ^[0-9]+$ ]] || [ "$SCORE" -gt 100 ]; then
  ERRORS+=("score must be an integer 0-100, got: '$SCORE'")
fi

# 3. quality.overall == score
OVERALL=$(jq -r '.quality.overall // "missing"' "$EVAL_FILE" 2>/dev/null || echo "missing")
if [ "$OVERALL" != "$SCORE" ]; then
  ERRORS+=("quality.overall ($OVERALL) must equal score ($SCORE)")
fi

# 4. feedback は 60 文字以上
FEEDBACK_OK=$(jq -r 'if (.feedback | type) == "string" and (.feedback | length) >= 60 then "yes" else "no" end' "$EVAL_FILE" 2>/dev/null || echo no)
if [ "$FEEDBACK_OK" != "yes" ]; then
  ERRORS+=("feedback must be a string of >= 60 chars (どこを・なぜ・どう直すか)")
fi

# 5. passed は任意。あるなら score >= threshold と一致すること
if [[ "$SCORE" =~ ^[0-9]+$ ]]; then
  PASSED=$(jq -r 'if has("passed") then (.passed | tostring) else "absent" end' "$EVAL_FILE" 2>/dev/null || echo "absent")
  if [ "$PASSED" != "absent" ]; then
    EXPECT_PASSED="false"
    [ "$SCORE" -ge "$THRESHOLD" ] && EXPECT_PASSED="true"
    if [ "$PASSED" != "$EXPECT_PASSED" ]; then
      ERRORS+=("passed ($PASSED) must be $EXPECT_PASSED (score $SCORE vs threshold $THRESHOLD)")
    fi
  fi
fi

# 6. 固定キー検証: schema 優先、無ければ criteria から
REQUIRED_KEYS=""
if [ "$SCHEMA_FILE" != "-" ] && [ -f "$SCHEMA_FILE" ]; then
  REQUIRED_KEYS=$(jq -r '[.breakdown_keys[]?.key] | join("\n")' "$SCHEMA_FILE" 2>/dev/null || echo "")
fi
if [ -z "$REQUIRED_KEYS" ] && [ -n "$CRITERIA" ]; then
  REQUIRED_KEYS=$(printf '%s' "$CRITERIA" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true)
fi
if [ -n "$REQUIRED_KEYS" ]; then
  ACTUAL_KEYS=$(jq -r '(.quality.breakdown // {}) | keys_unsorted | join("\n")' "$EVAL_FILE" 2>/dev/null || echo "")
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    if ! printf '%s\n' "$ACTUAL_KEYS" | grep -qxF "$k"; then
      ERRORS+=("breakdown is missing required key: '$k'")
    fi
  done <<< "$REQUIRED_KEYS"
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    if ! printf '%s\n' "$REQUIRED_KEYS" | grep -qxF "$k"; then
      ERRORS+=("breakdown has an extra key not in the contract: '$k' (new findings go to feedback, not breakdown)")
    fi
  done <<< "$ACTUAL_KEYS"
  BAD_VALUES=$(jq -r '(.quality.breakdown // {}) | to_entries[] | select((.value | type) != "number" or .value < 0 or .value > 100) | .key' "$EVAL_FILE" 2>/dev/null || echo "")
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    ERRORS+=("breakdown value for '$k' must be a number 0-100")
  done <<< "$BAD_VALUES"
fi

# 7. evaluator_skill のなりすまし防止 (schema がある場合のみ)
if [ "$SCHEMA_FILE" != "-" ] && [ -f "$SCHEMA_FILE" ]; then
  EXPECT_SKILL=$(jq -r '.skill // ""' "$SCHEMA_FILE" 2>/dev/null || echo "")
  if [ -n "$EXPECT_SKILL" ]; then
    ACTUAL_SKILL=$(jq -r '.evaluator_skill // ""' "$EVAL_FILE" 2>/dev/null || echo "")
    if [ "$ACTUAL_SKILL" != "$EXPECT_SKILL" ]; then
      ERRORS+=("evaluator_skill ('$ACTUAL_SKILL') must be '$EXPECT_SKILL'")
    fi
  fi

  # 8. 加重平均キャップ (schema の全キーに weight がある場合のみ)
  WEIGHT_CAP=$(jq -r --slurpfile ev "$EVAL_FILE" '
    (.breakdown_keys // []) as $bk
    | if ($bk | length) > 0 and ([$bk[] | has("weight")] | all) then
        ([$bk[] | .weight] | add) as $tw
        | if $tw > 0 then
            ([$bk[] | (.weight * (($ev[0].quality.breakdown[.key] // 0)))] | add / $tw) as $avg
            | if (($ev[0].quality.overall // 0) > ($avg + 5)) then
                "NG overall=\($ev[0].quality.overall) weighted_avg=\($avg | floor)"
              else "ok" end
          else "ok" end
      else "ok" end' "$SCHEMA_FILE" 2>/dev/null || echo "ok")
  if [ "$WEIGHT_CAP" != "ok" ]; then
    ERRORS+=("overall exceeds weighted average + 5 ($WEIGHT_CAP) — 総合判断は致命傷を薄める方向 (上振れ) には使えない")
  fi
fi

if [ "${#ERRORS[@]}" -gt 0 ]; then
  for e in "${ERRORS[@]}"; do
    echo "INVALID: $e"
  done
  exit 1
fi

echo "OK"
