#!/bin/bash
# count-chars.sh — 日本語対応の文字数カウント
# Usage: count-chars.sh <file> [raw|spoken]
#
# raw (デフォルト): ファイル全文の文字数
# spoken: 読み上げに乗らない要素を除外して数える (python3 必須。無ければ raw に縮退):
#   HTML コメント / コードフェンス行 / 見出し行 (#) / 【...】演出メモ / 空白・改行
#   → 「演出メモや見出しで文字数を水増しする」対策。尺の実測はこちらを使う
#
# wc -m はロケールが UTF-8 でないとバイト数を返す (日本語だと約3倍の値になる)。
# python3 があれば python3 で数え、無ければ UTF-8 ロケールを指定した wc -m に落とす。

F="${1:?usage: count-chars.sh <file> [raw|spoken]}"
MODE="${2:-raw}"
[ -f "$F" ] || { echo "0"; exit 1; }

if command -v python3 &>/dev/null; then
  python3 - "$F" "$MODE" <<'PYEOF' 2>/dev/null && exit 0
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
if sys.argv[2] == "spoken":
    text = re.sub(r'<!--.*?-->', '', text, flags=re.DOTALL)   # HTML コメント
    lines = []
    in_fence = False
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence or s.startswith("#"):
            continue
        lines.append(line)
    text = "\n".join(lines)
    text = re.sub(r'【[^】]*】', '', text)                      # 演出メモ
    text = re.sub(r'\s', '', text)                              # 空白・改行
print(len(text))
PYEOF
fi
if [ "$MODE" = "spoken" ]; then
  echo "NOTICE: python3 が無いため spoken モードは使えません — raw で数えます" >&2
fi
# python3 が無い場合: 実在する UTF-8 ロケールを選んで wc -m (存在しないロケール指定は
# 環境によりバイト数計測に落ちて日本語が約3倍になる)
LOC=$(locale -a 2>/dev/null | grep -i -m1 -E '^(C|en_US|ja_JP)\.utf-?8$' || true)
if [ -n "$LOC" ]; then
  LC_ALL="$LOC" wc -m < "$F" 2>/dev/null | tr -d '[:space:]'
else
  wc -m < "$F" 2>/dev/null | tr -d '[:space:]'
fi
