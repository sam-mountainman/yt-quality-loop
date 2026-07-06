#!/bin/bash
set -euo pipefail
# mark-fresh.sh — 採点サブエージェント/子プロセスが eval JSON を書いた直後に実行し、
# fresh 証明マーカー (eval JSON の sha256) を残す。
# Usage: mark-fresh.sh <run_dir> <NNN>
#
# 実行するのは「採点した本人 (サブエージェント / codex exec)」のみ。
# メインのエージェントが自己採点した eval に対してこれを実行するのは
# fresh 証明の偽造 (PASS 詐欺) — その場合はマーカー無しのまま judge の
# SELF-SCORED 開示に従うこと。
# 注意: これは同一権限で動く以上「壁」ではなくトリップワイヤ。改ざんは防げないが、
# 「黙って自己採点で通す」を正規の手順から排除する。

RUN_DIR="${1:?usage: mark-fresh.sh <run_dir> <NNN>}"
NNN="${2:?usage: mark-fresh.sh <run_dir> <NNN>}"

EVAL_FILE="$RUN_DIR/turn-$NNN-eval.json"
MARKER="$RUN_DIR/turn-$NNN-eval.fresh"

[ -f "$EVAL_FILE" ] || { echo "ERROR: eval not found: $EVAL_FILE" >&2; exit 1; }

if command -v shasum &>/dev/null; then
  shasum -a 256 "$EVAL_FILE" | cut -d' ' -f1 > "$MARKER"
elif command -v sha256sum &>/dev/null; then
  sha256sum "$EVAL_FILE" | cut -d' ' -f1 > "$MARKER"
else
  echo "ERROR: no sha256 tool (shasum/sha256sum)" >&2
  exit 1
fi

echo "marked fresh: $MARKER"
