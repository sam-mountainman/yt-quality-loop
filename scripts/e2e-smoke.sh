#!/bin/bash
set -euo pipefail
# e2e-smoke.sh — LLM を呼ばずに品質ループの状態遷移を検証する。
# Codex/Claude hook scripts が同じ state.json を正しく進められるかを確認する。

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 引数なし = 正本 (plugins/) と同期コピー (codex-plugin/) の両方を検証してから guard-tests を回す
if [ "$#" -eq 0 ]; then
  bash "$0" "$ROOT/plugins/yt-quality-loop"
  bash "$0" "$ROOT/codex-plugin"
  echo "== guard tests (goodhart対策の挙動) =="
  bash "$ROOT/scripts/guard-tests.sh"
  echo "e2e-smoke: ok (plugins + codex-plugin + guard-tests)"
  exit 0
fi

PLUGIN_ROOT="$1"

if [ ! -d "$PLUGIN_ROOT/scripts" ]; then
  echo "ERROR: plugin scripts not found: $PLUGIN_ROOT/scripts" >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found" >&2; exit 1; }

TMP="$(mktemp -d /tmp/yt-quality-loop-e2e.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
SID="codex-hook-smoke"

echo "== hook start =="
bash "$PLUGIN_ROOT/scripts/loop-start.sh" "$TMP" 2 90 "$SID" --max-wall-minutes 5 > "$TMP/start.out"
STATE="$(awk -F': ' '/State file:/ {print $2}' "$TMP/start.out")"
TURNS="$(jq -r '.turns_dir' "$STATE")"

if [ ! -f "$STATE" ] || [ ! -d "$TURNS" ]; then
  echo "ERROR: state/turns not initialized" >&2
  exit 1
fi

echo "== write deterministic state/anchors/artifact/eval =="
ANCHORS="$(dirname "$STATE")/criteria-anchors.md"
printf '## 冒頭フック\n- 90+: 冒頭1文目に視聴者の悩みが明示される\n## 構成の明確さ\n- 90+: 結論→手順→注意点の順で並ぶ\n## 具体性と信頼性\n- 90+: 手順に実例が1つ以上ある\n' > "$ANCHORS"

jq --arg task 'テスト用のYouTube台本' \
   --arg criteria '冒頭フック,構成の明確さ,具体性と信頼性' \
   --arg eval 'subagent-fresh-eval' \
   --arg anchors "$ANCHORS" \
   '.task=$task | .criteria=$criteria | .evaluator_skill=$eval | .runtime="codex-hook" | .anchors_file=$anchors' \
   "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"

# 指紋の記録は最初の生成物より前 (順序は pass gate が mtime で照合する)
bash "$PLUGIN_ROOT/scripts/fingerprint.sh" "$STATE" --record >/dev/null

cat > "$TURNS/turn-000-output.md" <<'EOF'
# テスト台本
冒頭で視聴者の悩みを提示し、結論、手順、注意点、CTAの順に説明する。
EOF

cat > "$TURNS/turn-000-eval.json" <<'EOF'
{
  "score": 91,
  "quality": {
    "overall": 91,
    "breakdown": {
      "冒頭フック": 90,
      "構成の明確さ": 92,
      "具体性と信頼性": 91
    }
  },
  "feedback": "冒頭で視聴者の悩みを示し、構成も明確です。さらに実例を一つ増やすと信頼性が上がりますが、公開前の合格水準には達しています。",
  "evaluator_skill": "subagent-fresh-eval"
}
EOF

cat > "$TURNS/turn-000-eval-confirm.json" <<'EOF'
{
  "score": 92,
  "quality": {
    "overall": 92,
    "breakdown": {
      "冒頭フック": 91,
      "構成の明確さ": 93,
      "具体性と信頼性": 92
    }
  },
  "feedback": "独立確認: 冒頭の悩み提示と結論先行の構成は基準どおり。注意点の項に根拠を1文足すとさらに堅くなるが、合格水準には達している。",
  "evaluator_skill": "subagent-fresh-eval"
}
EOF

jq '.phase="eval" | .latest_score=91 | .evaluated_iteration=0' \
  "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"

echo "== stop hook threshold_met =="
STOP_OUT="$TMP/stop.out"
printf '{"cwd":"%s","session_id":"%s","hook_event_name":"Stop"}' "$TMP" "$SID" \
  | bash "$PLUGIN_ROOT/scripts/hook-stop.sh" > "$STOP_OUT"

jq -e '.decision == "block" and (.reason | contains("threshold_met"))' "$STOP_OUT" >/dev/null
[ "$(jq -r '.active' "$STATE")" = "false" ]
[ "$(jq -r '.ended_reason' "$STATE")" = "threshold_met" ]

echo "== final report =="
REPORT_OUT="$TMP/report.out"
bash "$PLUGIN_ROOT/scripts/final-report.sh" "$STATE" "$TMP/delivered.md" > "$REPORT_OUT"
grep -q "Deliverable: $TMP/delivered.md" "$REPORT_OUT"
grep -q "Best score: 91" "$REPORT_OUT"
test -s "$TMP/delivered.md"

echo "== hook prompt submit =="
PROMPT_OUT="$TMP/prompt.out"
printf '{"cwd":"%s","session_id":"%s","hook_event_name":"UserPromptSubmit"}' "$TMP" "$SID" \
  | bash "$PLUGIN_ROOT/scripts/hook-prompt-submit.sh" > "$PROMPT_OUT"
grep -q "YT_LOOP_SESSION_ID=$SID" "$PROMPT_OUT"

echo "e2e-smoke ($PLUGIN_ROOT): ok"
