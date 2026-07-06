#!/bin/bash
set -euo pipefail
# YT loop を finalize する (cancel / PASS / max_iterations の終端を一本化)
# Usage: loop-cancel.sh <state_file> [--reason <reason>]
#    or: loop-cancel.sh <cwd> <session_id> [--reason <reason>]
#
# --reason <passed|threshold_met|max_iterations|cancelled>
#   `passed` は `threshold_met` に正規化する (loop-control.sh の語彙と統一)。
#   passed/threshold_met は state の latest_score >= threshold で裏取りし、
#   不成立なら警告して auto-detect (cancelled) に落とす (PASS 詐欺ガード —
#   「合格しました」という自己申告を数値で検証する)。

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq が見つかりません (macOS: brew install jq)" >&2
  exit 1
fi

REASON=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --reason)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "ERROR: --reason requires a value (passed|threshold_met|max_iterations|cancelled)" >&2
        exit 1
      fi
      REASON="$2"
      shift 2
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

if [ -n "$REASON" ]; then
  case "$REASON" in
    passed) REASON="threshold_met" ;;
    threshold_met|max_iterations|cancelled) ;;
    *)
      echo "ERROR: --reason must be one of passed|threshold_met|max_iterations|cancelled, got: '$REASON'" >&2
      exit 1
      ;;
  esac
fi

# 引数が1つ → state_file パス直接指定 / 引数が2つ → cwd + session_id
if [ $# -eq 1 ]; then
  STATE_FILE="$1"
else
  CWD="${1:-.}"
  SESSION_ID="${2:?session_id is required}"
  if [[ "$SESSION_ID" =~ [/\\] ]] || [[ "$SESSION_ID" == *..* ]]; then
    echo "ERROR: session_id must not contain path separators or '..': '$SESSION_ID'" >&2
    exit 1
  fi
  STATE_FILE="$CWD/.yt-loop/sessions/$SESSION_ID/state.json"
fi

if [ ! -f "$STATE_FILE" ]; then
  echo "No state file found: $STATE_FILE"
  exit 0
fi

was_active="$(jq -r '.active' "$STATE_FILE" 2>/dev/null || echo false)"
if [ "$was_active" = "true" ]; then
  # PASS 詐欺ガード: --reason passed/threshold_met の主張は state の数値で裏取りする。
  if [ "$REASON" = "threshold_met" ]; then
    CLAIM_OK="$(jq -r 'if ((.latest_score | type) == "number") and ((.threshold | type) == "number")
                          and (.latest_score >= .threshold)
                       then "yes" else "no" end' "$STATE_FILE" 2>/dev/null || echo no)"
    if [ "$CLAIM_OK" != "yes" ]; then
      echo "WARNING: --reason passed/threshold_met but latest_score < threshold (or non-numeric) — falling back to auto-detect" >&2
      REASON=""
    fi
  fi
  # ended_reason の記録。--reason 指定があればそれ (裏取り済み)、なければ auto-detect。
  # 型チェック必須: jq は number < string なので文字列 score は常に >= threshold になる。
  # iteration 確定: evaluated_iteration が数値で iteration より進んでいれば採用 (後退はさせない)。
  jq --arg reason "$REASON" '
      .active = false
      | .ended_reason = (.ended_reason // (
          if $reason != "" then $reason
          elif ((.latest_score | type) == "number") and ((.threshold | type) == "number")
             and (.latest_score >= .threshold)
          then "threshold_met" else "cancelled" end))
      | (if ((.evaluated_iteration | type) == "number")
            and (((.iteration | type) != "number") or (.evaluated_iteration > .iteration))
         then .iteration = .evaluated_iteration else . end)' \
    "$STATE_FILE" > "$STATE_FILE.tmp.$$" && mv "$STATE_FILE.tmp.$$" "$STATE_FILE"
  echo "YT loop finalized (reason: $(jq -r '.ended_reason' "$STATE_FILE"))."
  echo "Summary: iteration $(jq -r '.iteration' "$STATE_FILE"), latest_score $(jq -r '.latest_score' "$STATE_FILE"), best iter $(jq -r '.best_iteration' "$STATE_FILE") (score $(jq -r '.best_score' "$STATE_FILE"))"
else
  echo "No active YT loop."
fi
