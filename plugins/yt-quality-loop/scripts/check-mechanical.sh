#!/bin/bash
set -euo pipefail
# check-mechanical.sh — 審査基準書 A層 (機械判定) をスクリプトで実行する
# Usage: check-mechanical.sh <artifact_file> <rules_json>
#
# 「AIがどう言い張っても機械的に×が出る」層。ラルフ・ウィガム・ループ
# (早すぎる完成宣言) への構造対策。1 項目でも NG なら exit 1 (即差し戻し)。
#
# rules_json の形式 (.yt-loop/mechanical-checks.json — /yt-profile が生成):
# {
#   "min_chars": 4500,            // 0 = 無効
#   "max_chars": 5500,            // 0 = 無効
#   "forbidden_words": ["ヤバい", "絶対", "100%"],
#   "max_ending_streak": 2        // 同じ文末の連続許容数 (0 = 無効)
# }

ARTIFACT="${1:?usage: check-mechanical.sh <artifact_file> <rules_json>}"
RULES="${2:?usage: check-mechanical.sh <artifact_file> <rules_json>}"

command -v jq &>/dev/null || { echo "NG: jq not found"; exit 1; }
[ -f "$ARTIFACT" ] || { echo "NG: artifact not found: $ARTIFACT"; exit 1; }

if [ ! -f "$RULES" ]; then
  echo "SKIP: rules file not found ($RULES) — A層チェックなし"
  exit 0
fi
jq -e . "$RULES" >/dev/null 2>&1 || { echo "NG: rules file is not valid JSON: $RULES"; exit 1; }

FAIL=0

# --- 文字数 ---
# wc -m 直呼びはロケール次第でバイト数を返すため count-chars.sh (python3 優先) を使う。
# rules の count_mode="spoken" なら、演出メモ・見出し・コメント・空白を除いた
# 「読み上げに乗る文字数」で判定する (水増し対策)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIN=$(jq -r '.min_chars // 0' "$RULES")
MAX=$(jq -r '.max_chars // 0' "$RULES")
COUNT_MODE=$(jq -r '.count_mode // "raw"' "$RULES")
[ "$COUNT_MODE" = "spoken" ] || COUNT_MODE="raw"
CHARS=$(bash "$SCRIPT_DIR/count-chars.sh" "$ARTIFACT" "$COUNT_MODE" || echo 0)
[[ "$CHARS" =~ ^[0-9]+$ ]] || CHARS=0
if [[ "$MIN" =~ ^[1-9][0-9]*$ ]] && [ "$CHARS" -lt "$MIN" ]; then
  echo "NG: 文字数 $CHARS 字 < 下限 $MIN 字"
  FAIL=1
fi
if [[ "$MAX" =~ ^[1-9][0-9]*$ ]] && [ "$CHARS" -gt "$MAX" ]; then
  echo "NG: 文字数 $CHARS 字 > 上限 $MAX 字"
  FAIL=1
fi
echo "INFO: 文字数実測 $CHARS 字 (mode: $COUNT_MODE)"

# --- 禁止ワード ---
# grep はマッチなしで exit 1 を返す。set -euo pipefail 下で拾うと
# 「違反ゼロの正常ケース」でスクリプトが死ぬため、必ず || true で握りつぶす。
while IFS= read -r word; do
  [ -n "$word" ] || continue
  HITS=$(grep -o -F "$word" "$ARTIFACT" 2>/dev/null | wc -l | tr -d '[:space:]' || true)
  [[ "$HITS" =~ ^[0-9]+$ ]] || HITS=0
  if [ "$HITS" -gt 0 ]; then
    echo "NG: 禁止ワード「$word」が ${HITS} 回出現"
    FAIL=1
  fi
done < <(jq -r '(.forbidden_words // []) | .[]' "$RULES")

# --- 同じ文末の連続 (python3 が無い環境ではスキップ) ---
STREAK=$(jq -r '.max_ending_streak // 0' "$RULES")
if [[ "$STREAK" =~ ^[1-9][0-9]*$ ]]; then
  if command -v python3 &>/dev/null; then
    RESULT=$(python3 - "$ARTIFACT" "$STREAK" <<'PYEOF'
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
limit = int(sys.argv[2])
sentences = [s.strip() for s in re.split(r'[。！？!?\n]', text) if s.strip()]
endings = [s[-2:] for s in sentences if len(s) >= 2]
streak, prev, worst, at = 1, None, 1, ""
for e in endings:
    if e == prev:
        streak += 1
        if streak > worst:
            worst, at = streak, e
    else:
        streak = 1
    prev = e
if worst > limit:
    print(f"NG: 同じ文末「{at}」が {worst} 連続 (許容 {limit})")
else:
    print(f"INFO: 文末連続 最大 {worst} (許容 {limit})")
PYEOF
) || RESULT="SKIP: 文末連続チェック失敗"
    echo "$RESULT"
    case "$RESULT" in NG:*) FAIL=1 ;; esac
  else
    echo "SKIP: python3 が無いため文末連続チェックをスキップ (審査AIが代わりに見ます)"
  fi
fi

if [ "$FAIL" -eq 1 ]; then
  echo "RESULT: A層 NG — 即差し戻し (B層採点は行わない)"
  exit 1
fi
echo "RESULT: A層 OK"
