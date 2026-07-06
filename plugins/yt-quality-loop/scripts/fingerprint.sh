#!/bin/bash
set -euo pipefail
# fingerprint.sh — 「ものさし」の指紋を取る / 照合用に記録する
# Usage: fingerprint.sh <state_file>            # 現在の指紋を stdout に出す
#        fingerprint.sh <state_file> --record   # state.json の config_fingerprint に記録 (未記録時のみ)
#
# 指紋の対象 = threshold / criteria / generator_skill / evaluator_skill / max_iterations
#            + channel-profile.md の中身 + mechanical-checks.json の中身
#            + brief_file (動画ブリーフ) の中身
#            + anchors_file (自由 criteria の採点アンカー) の中身
#            + evaluator_skill の SKILL.md / eval-schema.json (プリセットの目盛り本体)
#
# --record は fingerprint_recorded_at (epoch 秒) も記録する。pass gate はこれを
# turn-000-output.md の mtime と照合し、「生成後にものさしを固定した」合格を拒否する。
# ループの途中でこれらが変わっていたら、Stop hook の pass gate が合格を拒否する。
# 改ざんを防ぐ壁ではなく「点だけ上げる最短経路を必ず検知する」トリップワイヤ。

STATE="${1:?usage: fingerprint.sh <state_file> [--record]}"
MODE="${2:-}"

command -v jq &>/dev/null || { echo "ERROR: jq not found" >&2; exit 1; }
[ -f "$STATE" ] || { echo "ERROR: state not found: $STATE" >&2; exit 1; }

PROJ=$(jq -r '.project_dir // "."' "$STATE")

hash_stdin() {
  if command -v shasum &>/dev/null; then
    shasum -a 256 | cut -d' ' -f1
  elif command -v sha256sum &>/dev/null; then
    sha256sum | cut -d' ' -f1
  else
    # ハッシュツールが無い環境では指紋機能を無効化 (照合側は空を許容しない設計なので
    # 明示的にエラーにする)
    echo "NOHASH"
  fi
}

BRIEF=$(jq -r '.brief_file // ""' "$STATE" 2>/dev/null || echo "")
ANCHORS=$(jq -r '.anchors_file // ""' "$STATE" 2>/dev/null || echo "")
EVAL_SKILL=$(jq -r '.evaluator_skill // ""' "$STATE" 2>/dev/null || echo "")
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

HASH=$(
  {
    jq -r '[.threshold, .criteria, .generator_skill, .evaluator_skill, .max_iterations, .brief_file, .anchors_file] | @json' "$STATE" 2>/dev/null || true
    cat "$PROJ/.yt-loop/channel-profile.md" 2>/dev/null || true
    cat "$PROJ/.yt-loop/mechanical-checks.json" 2>/dev/null || true
    if [ -n "$BRIEF" ] && [ "$BRIEF" != "null" ]; then cat "$BRIEF" 2>/dev/null || true; fi
    if [ -n "$ANCHORS" ] && [ "$ANCHORS" != "null" ]; then cat "$ANCHORS" 2>/dev/null || true; fi
    # プリセット採点係の目盛り本体 (SKILL.md のアンカー帯 / schema の weight・固定キー) も対象。
    # ループ中にこれを書き換えて緩める抜け道を検知する
    if [ -n "$EVAL_SKILL" ] && [ "$EVAL_SKILL" != "null" ]; then
      cat "$SELF_DIR/../skills/$EVAL_SKILL/SKILL.md" 2>/dev/null || true
      cat "$SELF_DIR/../skills/$EVAL_SKILL/eval-schema.json" 2>/dev/null || true
    fi
  } | hash_stdin
)

if [ "$MODE" = "--record" ]; then
  EXISTING=$(jq -r '.config_fingerprint // ""' "$STATE" 2>/dev/null || echo "")
  if [ -n "$EXISTING" ] && [ "$EXISTING" != "null" ]; then
    echo "already recorded (config_fingerprint は上書きできない): $EXISTING"
    exit 1
  fi
  jq --arg fp "$HASH" --argjson at "$(date +%s)" '.config_fingerprint = $fp | .fingerprint_recorded_at = $at' "$STATE" > "$STATE.tmp.$$" && mv "$STATE.tmp.$$" "$STATE"
  echo "recorded: $HASH"
else
  echo "$HASH"
fi
