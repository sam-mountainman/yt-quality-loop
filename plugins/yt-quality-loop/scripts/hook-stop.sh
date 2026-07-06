#!/bin/bash
# Stop hook: session_id でスコープした state を参照し、ループ継続/終了を判定する
#
# HOOK SAFETY: hook は何があっても exit 0 しなければならない。

if ! command -v jq &>/dev/null; then
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

# Used by sourced loop-control.sh
# shellcheck disable=SC2034
STATE_FILE="$CWD/.yt-loop/sessions/$SESSION_ID/state.json"
# shellcheck disable=SC2034
LOOP_LABEL="YT-loop iteration"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=loop-control.sh
source "$SCRIPT_DIR/loop-control.sh"
