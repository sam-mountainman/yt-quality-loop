#!/bin/bash
set -euo pipefail
# final-report.sh — state.json から納品物コピーと最終レポートを決定論的に生成する。
# Usage: final-report.sh <state_file> [output_file]

STATE="${1:?usage: final-report.sh <state_file> [output_file]}"
OUT_FILE="${2:-}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found" >&2; exit 1; }
[ -f "$STATE" ] || { echo "ERROR: state not found: $STATE" >&2; exit 1; }

PROJECT_DIR="$(jq -r '.project_dir // "."' "$STATE")"
TURNS_DIR="$(jq -r '.turns_dir // ""' "$STATE")"
BEST_ITER="$(jq -r '.best_iteration // "null"' "$STATE")"
BEST_SCORE="$(jq -r '.best_score // "null"' "$STATE")"
ENDED_REASON="$(jq -r '.ended_reason // "unknown"' "$STATE")"
THRESHOLD="$(jq -r '.threshold // 90' "$STATE")"
CRITERIA="$(jq -r '.criteria // ""' "$STATE")"
EVAL_SKILL="$(jq -r '.evaluator_skill // ""' "$STATE")"
BRIEF_FILE="$(jq -r '.brief_file // ""' "$STATE")"
ANCHORS_FILE="$(jq -r '.anchors_file // ""' "$STATE")"
JUDGES_UNAVAILABLE="$(jq -r '.judges_unavailable // ""' "$STATE")"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

hash_of() { { shasum -a 256 "$1" 2>/dev/null || sha256sum "$1" 2>/dev/null; } | cut -d' ' -f1; }

if [ -z "$OUT_FILE" ]; then
  OUT_FILE="$PROJECT_DIR/yt-loop-output-$(date +%Y%m%d-%H%M%S).md"
fi

echo "# YT Quality Loop Final Report"
echo ""
echo "- State: $STATE"
echo "- Ended reason: $ENDED_REASON"
echo "- Threshold: $THRESHOLD"
[ -n "$BRIEF_FILE" ] && [ "$BRIEF_FILE" != "null" ] && echo "- Brief: $BRIEF_FILE"
[ -n "$ANCHORS_FILE" ] && [ "$ANCHORS_FILE" != "null" ] && echo "- Anchors: $ANCHORS_FILE (次回同じ軸なら anchors: 指定で再利用可)"
[ -n "$JUDGES_UNAVAILABLE" ] && [ "$JUDGES_UNAVAILABLE" != "null" ] && echo "- ⚠ ループ開始時に不在だった明示ジャッジ: $JUDGES_UNAVAILABLE"

# --- 報告の裏取り: state の自己申告を信じず、現物と照合してから権威づけする ---
VERIFY_FAILS=()
if [[ "$BEST_ITER" =~ ^[0-9]+$ ]]; then
  V_NNN="$(printf '%03d' "$BEST_ITER")"
  V_FILE="$TURNS_DIR/turn-$V_NNN-output.md"
  V_EVAL="$TURNS_DIR/turn-$V_NNN-eval.json"
  # 成果物すり替え検知 (終了理由を問わず)
  STORED_SHA="$(jq -r --arg n "$V_NNN" '(.artifact_hashes // {})[$n] // ""' "$STATE" 2>/dev/null || echo "")"
  if [ -n "$STORED_SHA" ] && [ -f "$V_FILE" ] && [ "$(hash_of "$V_FILE")" != "$STORED_SHA" ]; then
    VERIFY_FAILS+=("best 成果物が採点後に変更されている ($V_FILE)")
  fi
  # eval JSON の直読照合 (best_score は state の自己申告なので現物と突き合わせる)
  E_SCORE="$(jq -r '.score // "null"' "$V_EVAL" 2>/dev/null || echo null)"
  if ! [[ "$E_SCORE" =~ ^[0-9]+$ ]] || [ "$E_SCORE" != "$BEST_SCORE" ]; then
    VERIFY_FAILS+=("best_score ($BEST_SCORE) が eval JSON の実値 ($E_SCORE) と一致しない")
  fi
  if [ "$ENDED_REASON" = "threshold_met" ]; then
    SCHEMA="$SELF_DIR/../skills/$EVAL_SKILL/eval-schema.json"; [ -f "$SCHEMA" ] || SCHEMA="-"
    if [ -f "$SELF_DIR/validate-eval.sh" ] && ! bash "$SELF_DIR/validate-eval.sh" "$V_EVAL" "$SCHEMA" "$THRESHOLD" "$CRITERIA" >/dev/null 2>&1; then
      VERIFY_FAILS+=("best eval が契約検証に落ちる")
    fi
    # 確認採点の実在: 外部ジャッジ (judges) の有効な確認があればそれで足りる。無ければ host フォーク確認を要求
    JUDGES_CONF="$(jq -r '.judges // "host"' "$STATE" 2>/dev/null || echo "host")"
    EXT_CONF_OK=""
    for _j in claude codex grok; do
      case ",$JUDGES_CONF," in *",$_j,"*) ;; *) continue ;; esac
      CJ="$TURNS_DIR/turn-$V_NNN-eval-confirm-$_j.json"
      MJ="$TURNS_DIR/turn-$V_NNN-eval-confirm-$_j.fresh"
      if [ -f "$CJ" ] && [ -f "$MJ" ] && [ "$(cat "$MJ" 2>/dev/null)" = "$(hash_of "$CJ")" ] \
         && [ "$(hash_of "$V_EVAL")" != "$(hash_of "$CJ")" ]; then
        EXT_CONF_OK="yes"
      fi
    done
    if [ "$EXT_CONF_OK" != "yes" ]; then
      C_FILE="$TURNS_DIR/turn-$V_NNN-eval-confirm.json"
      if [ ! -f "$C_FILE" ]; then
        VERIFY_FAILS+=("確認採点が存在しない (合格主張には host フォーク確認か外部ジャッジ確認が必須)")
      elif [ "$(hash_of "$V_EVAL")" = "$(hash_of "$C_FILE")" ]; then
        VERIFY_FAILS+=("確認採点が本採点のコピー")
      fi
    fi
    if [ -f "$SELF_DIR/fingerprint.sh" ]; then
      FP_STORED="$(jq -r '.config_fingerprint // ""' "$STATE" 2>/dev/null || echo "")"
      FP_NOW="$(bash "$SELF_DIR/fingerprint.sh" "$STATE" 2>/dev/null || echo "")"
      if [ -z "$FP_STORED" ] || { [ -n "$FP_NOW" ] && [ "$FP_NOW" != "$FP_STORED" ]; }; then
        VERIFY_FAILS+=("ものさしの指紋が不一致または未記録")
      fi
    fi
  fi
fi
if [ "${#VERIFY_FAILS[@]}" -gt 0 ]; then
  echo ""
  echo "## ⚠ VERIFY FAILED — この報告の数字は信用できない"
  echo ""
  for v in "${VERIFY_FAILS[@]}"; do echo "- $v"; done
  echo ""
  echo "state.json の値が現物と一致しません。正規のループ外で state が書き換えられた可能性があります。turns ディレクトリの実物を直接確認してください。"
fi

if ! [[ "$BEST_ITER" =~ ^[0-9]+$ ]]; then
  echo "- Deliverable: none"
  # 有効な採点は無かったが、生成物自体は残っている場合は未採点ドラフトとして案内する
  LATEST_OUT="$(find "$TURNS_DIR" -name 'turn-*-output.md' -type f 2>/dev/null | sort | tail -1)"
  if [ -n "$LATEST_OUT" ] && [ -s "$LATEST_OUT" ]; then
    DRAFT_FILE="$PROJECT_DIR/yt-loop-draft-$(date +%Y%m%d-%H%M%S).md"
    cp "$LATEST_OUT" "$DRAFT_FILE"
    echo "- Draft (未採点・品質保証なし): $DRAFT_FILE"
  fi
  echo ""
  echo "## 次に直すこと"
  echo ""
  echo "合格評価が一度も無かったため、品質保証つきの納品物はありません (上の Draft は未採点の生成物です)。task に「誰向け / 長さ / 入れる内容 / 完成条件」を足して再実行してください。"
  exit 0
fi

BEST_NNN="$(printf '%03d' "$BEST_ITER")"
BEST_FILE="$TURNS_DIR/turn-$BEST_NNN-output.md"
BEST_EVAL="$TURNS_DIR/turn-$BEST_NNN-eval.json"

if [ ! -s "$BEST_FILE" ]; then
  echo "- Deliverable: missing ($BEST_FILE)"
  exit 1
fi

mkdir -p "$(dirname "$OUT_FILE")"
cp "$BEST_FILE" "$OUT_FILE"

echo "- Deliverable: $OUT_FILE"
echo "- Best iteration: $BEST_ITER"
echo "- Best score: $BEST_SCORE"
echo ""

echo "## スコア推移"
echo ""
scores=()
if [ -n "$TURNS_DIR" ] && [ -d "$TURNS_DIR" ]; then
  while IFS= read -r file; do
    s="$(jq -r '.score // empty' "$file" 2>/dev/null || true)"
    if [[ "$s" =~ ^[0-9]+$ ]]; then
      scores+=("$s")
    fi
  done < <(find "$TURNS_DIR" -name 'turn-*-eval.json' -type f | sort)
fi
if [ "${#scores[@]}" -gt 0 ]; then
  joined="${scores[0]}"
  for ((idx=1; idx<${#scores[@]}; idx++)); do
    joined="$joined -> ${scores[$idx]}"
  done
  printf '%s\n' "$joined"
else
  echo "記録なし"
fi

echo ""
echo "## 内訳"
echo ""
if [ -f "$BEST_EVAL" ]; then
  jq -r '(.quality.breakdown // {}) | to_entries[] | "- \(.key): \(.value)"' "$BEST_EVAL" 2>/dev/null || true
fi

echo ""
echo "## 残った改善余地"
echo ""
if [ -f "$BEST_EVAL" ]; then
  jq -r '.feedback // "記録なし"' "$BEST_EVAL" 2>/dev/null || echo "記録なし"
else
  echo "記録なし"
fi

self_scored="$(jq -r '(.self_scored // []) | join(", ")' "$STATE" 2>/dev/null || true)"
if [ -n "$self_scored" ]; then
  echo ""
  echo "## 採点メモ"
  echo ""
  echo "自己採点に落ちた周回: $self_scored"
  echo "これは fresh な採点係が使えなかった時のフォールバックです。fresh 採点より甘くなる可能性があります。"
fi

# --- 確認採点 (judges) の開示: 誰が合格を確認したかを必ず見せる ---
R_JUDGES="$(jq -r '.judges // "host"' "$STATE" 2>/dev/null || echo "host")"
JC_RULE="$(jq -r '.judge_confirm.rule // ""' "$STATE" 2>/dev/null || echo "")"
if [ "$R_JUDGES" != "host" ] || [ -n "$JC_RULE" ]; then
  echo ""
  echo "## 確認採点 (judges)"
  echo ""
  echo "- 構成: $R_JUDGES"
  JMODELS="$(jq -r '(.judge_models // {}) | to_entries[]? | "- \(.key) model: \(.value // \"configured-unpinned\")"' "$STATE" 2>/dev/null || true)"
  [ -n "$JMODELS" ] && printf '%s\n' "$JMODELS"
  if jq -e 'any((.judge_models // {})[]; . == "configured-unpinned")' "$STATE" >/dev/null 2>&1; then
    echo "- ⚠ configured-unpinned はCLI既定モデルを使ったため、モデルIDを固定・検証できていません"
  fi
  JD="$(jq -r '.judges_detected // ""' "$STATE" 2>/dev/null || echo "")"
  if [ -n "$JD" ] && [ "$JD" != "null" ]; then
    for _j in claude codex grok; do
      case ",$JD," in *",$_j,"*)
        case ",$R_JUDGES," in *",$_j,"*) ;; *) echo "- $_j: 検出済みだが不使用 (ユーザー指定)";; esac ;;
      esac
    done
  fi
  if [ -n "$JC_RULE" ]; then
    JC_EXT="$(jq -r '.judge_confirm.ext_scores // "-"' "$STATE" 2>/dev/null || echo "-")"
    JC_ADOPTED="$(jq -r '.judge_confirm.adopted // "-"' "$STATE" 2>/dev/null || echo "-")"
    echo "- 判定規則: $JC_RULE / 外部スコア: ${JC_EXT:--} / 採用スコア: $JC_ADOPTED"
    JC_FAILED="$(jq -r '.judge_confirm.failed // ""' "$STATE" 2>/dev/null || echo "")"
    [ -n "$JC_FAILED" ] && echo "- ⚠ 失敗したジャッジ: $JC_FAILED"
    case "$JC_RULE" in
      median) echo "- 確認レベル: 3 (本採点 + 外部2ベンダー以上の下側中央値)" ;;
      min) echo "- 確認レベル: 2 (本採点 + 外部1ベンダーの min 採用)" ;;
      host-degraded) echo "- ⚠ 外部ジャッジ全滅のため host 確認に降格 (確認レベル: 1)" ;;
    esac
    echo "- 注: 確認レベルは採点経路の多様性であり、台本品質や再生数の確率ではありません。"
    if [ -n "$JC_EXT" ] && [ "$JC_EXT" != "-" ] && [ "$JC_EXT" != "null" ]; then
      JC_SPREAD="$(printf '%s\n' $JC_EXT | sort -n | awk 'NR==1{min=$1} {max=$1} END{if (NR>0) print max-min; else print 0}')"
      if [[ "$JC_SPREAD" =~ ^[0-9]+$ ]] && [ "$JC_SPREAD" -ge 10 ]; then
        echo "- ⚠ 外部ジャッジ間の点差が ${JC_SPREAD} 点 — 主観の効く成果物です。公開前に人間の最終確認を推奨"
      fi
    fi
  fi
fi

echo ""
echo "## 次回への反映"
echo ""
echo "- 納品物を手直ししたら /yt-profile 更新 で直しを次回に反映できます。"
echo "- スコアは同一成果物でも±数点ブレます。90点は再生数保証ではなく、公開前の品質基準です。"
