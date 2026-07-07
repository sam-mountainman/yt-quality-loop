#!/bin/bash
# doctor.sh — yt-quality-loop のセットアップ診断 (機械チェック部分)
# Usage: doctor.sh <cwd>
# 常に exit 0。○/×/△ を印字する。

CWD="${1:-.}"
echo "== yt-quality-loop doctor =="

# jq (必須)
if command -v jq &>/dev/null; then
  echo "○ jq: $(jq --version 2>/dev/null)"
else
  echo "× jq が見つかりません → macOS: brew install jq / Windows(WSL): sudo apt install jq"
fi

# python3 (任意)
if command -v python3 &>/dev/null; then
  echo "○ python3: あり (文末連続の機械チェックが使える)"
else
  echo "△ python3: なし (任意。文末連続チェックだけスキップされ、採点係が代わりに見る)"
fi

# 状態ディレクトリの書き込み
if mkdir -p "$CWD/.yt-loop" 2>/dev/null && [ -w "$CWD/.yt-loop" ]; then
  echo "○ 状態ディレクトリ書き込み可: $CWD/.yt-loop"
else
  echo "× $CWD/.yt-loop に書き込めません (フォルダの権限を確認)"
fi

# チャンネルプロファイル (任意)
if [ -f "$CWD/.yt-loop/channel-profile.md" ]; then
  echo "○ チャンネルプロファイル: あり"
else
  echo "△ チャンネルプロファイル: 未作成 (/yt-profile で作ると台本の採点に「らしさ」が入る)"
fi

# 既定 generator (任意)
if [ -f "$CWD/.yt-loop/defaults.json" ]; then
  DEFAULT_GENERATOR=$(jq -r '.default_generator // empty' "$CWD/.yt-loop/defaults.json" 2>/dev/null || true)
  if [ -n "$DEFAULT_GENERATOR" ]; then
    echo "○ 既定 generator: $DEFAULT_GENERATOR (.yt-loop/defaults.json)"
  else
    echo "△ 既定 generator: defaults.json はありますが default_generator が空です"
  fi
else
  echo "△ 既定 generator: 未設定 (/yt-import-skill で既存台本スキルを登録できます)"
fi

# 機械チェックルール (任意)
if [ -f "$CWD/.yt-loop/mechanical-checks.json" ]; then
  if command -v jq &>/dev/null && jq -e . "$CWD/.yt-loop/mechanical-checks.json" >/dev/null 2>&1; then
    echo "○ 機械チェックルール: あり"
  else
    echo "× 機械チェックルール: あるが JSON が壊れている ($CWD/.yt-loop/mechanical-checks.json)"
  fi
else
  echo "△ 機械チェックルール: なし (任意。文字数・禁止ワードを機械判定したい場合に作る)"
fi

# 実行中ループ
if command -v jq &>/dev/null; then
  for f in "$CWD"/.yt-loop/sessions/*/state.json; do
    [ -f "$f" ] || continue
    if [ "$(jq -r '.active' "$f" 2>/dev/null)" = "true" ]; then
      echo "! 実行中のループ: $f (iter $(jq -r '.iteration' "$f" 2>/dev/null)/$(jq -r '.max_iterations' "$f" 2>/dev/null), score $(jq -r '.latest_score' "$f" 2>/dev/null))"
    fi
  done
fi

# validate-eval の自己テスト
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if command -v jq &>/dev/null && [ -f "$SCRIPT_DIR/validate-eval.sh" ]; then
  TMP=$(mktemp)
  echo '{"score":91,"quality":{"overall":91,"breakdown":{"test":91}},"feedback":"自己テスト用の十分な長さのfeedbackです。validate-eval.shが文字数条件とJSON契約を正しく通せるか確認します。","passed":true,"evaluator_skill":"selftest"}' > "$TMP"
  if bash "$SCRIPT_DIR/validate-eval.sh" "$TMP" - 90 >/dev/null 2>&1; then
    echo "○ 採点検証スクリプト (validate-eval.sh): 動作OK"
  else
    echo "× validate-eval.sh の自己テストに失敗"
  fi
  rm -f "$TMP"
fi

echo "== 診断完了 =="
exit 0
