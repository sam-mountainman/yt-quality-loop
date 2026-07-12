#!/bin/bash
set -euo pipefail
# guard-tests.sh — グッドハート対策ガードの挙動テスト (LLM を呼ばない決定論テスト)
#
# loop-control.sh / validate-eval.sh / loop-judge.sh の「点だけ上げる最短経路」封鎖が
# 生きていることを検証する。これらのスクリプトを変更したら必ずここを通すこと。
#
# 対象ガード:
#   G1  正規の合格 → threshold_met + ENDED block
#   G2  state のスコア水増し (eval JSON と不一致) → PASS CLAIM REJECTED
#   G3  ものさし改ざん (threshold をループ中に変更) → PASS CLAIM REJECTED (指紋)
#   G4  採点後の成果物すり替え → PASS CLAIM REJECTED (artifact hash)
#   G5  ブリーフ改ざん (絶対言わない話の削除) → PASS CLAIM REJECTED (指紋)
#   G6  feedback コピペ採点 → EVAL REJECTED (修復パス)
#   G7  機械チェック NG 3 連続 → mechanical_check_failed + ENDED
#   G8  進捗ゼロ (2 回連続スコア停滞) → no_progress + ENDED
#   G9  max 到達 → ENDED block (納品指示が必ず出る)
#   G10 採点アンカー改ざん (目盛りをループ中に緩める) → PASS CLAIM REJECTED (指紋)
#   G16 evaluator_runtime 改ざん (skill/fable 切替) → PASS CLAIM REJECTED (指紋)
#   G17-G22 多ベンダー確認採点 (judges): 欠落拒否 / min席替え / median合意 / 全滅降格 /
#           fail-open封鎖 / judges改ざん拒否 / fresh証明なし拒否 + CJ1 ランナー成果物
#   V1-V4 validate-eval: 加重平均上振れ拒否 / 下方向許容 / 軸過不足拒否 / 短文 feedback 拒否
#   J1-J4 codex loop-judge: 二重判定ガード / SELF-SCORED 検知 / マーカー有効 / コピペ拒否

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
P="$ROOT/plugins/yt-quality-loop"
CX="$ROOT/codex/skills/yt-loop/scripts"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found" >&2; exit 1; }

TMP="$(mktemp -d /tmp/yt-guard-tests.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
ok()   { echo "ok: $1"; }
# pipefail 下の `printf | grep -q` は grep の先行終了で printf が SIGPIPE(141) になり
# 条件が確率的に偽になる (実測でフレークの原因)。文字列照合はパイプを使わない。
has()  { case "$1" in *"$2"*) return 0;; *) return 1;; esac; }
bad()  {
  echo "FAIL: $1" >&2
  # 診断: 直近の hook 出力と state の要点 (グローバル $OUT / $S を参照)
  echo "  diag out_len=${#OUT} out_head=$(printf '%s' "${OUT:-}" | head -c 120 | tr '\n' ' ')" >&2
  [ -n "${S:-}" ] && [ -f "${S:-}" ] && echo "  diag state: $(jq -c '{active,iteration,evaluated_iteration,latest_score,ended_reason,eval_repair_attempts,no_progress_count,mech_ng_count}' "$S" 2>/dev/null)" >&2
  FAIL=1
}

# --- helpers ---------------------------------------------------------------

FB0='軸aは冒頭の2文が説明的で弱い。1文目に数字を置き、2文目で視聴者の損失を名指しする形に変えると前のめりになる。軸bは維持でよい。'
FB1='軸aは改善したが、まだ3文目のたとえ話が抽象的で視聴者が自分事にできない。日常の比喩を1つ入れ、その直後に手順の宣言を置くこと。'
FB2='軸bのまとめが重複している。最後の2文を1文に圧縮し、視聴後の行動をひとつだけ指定する形で締めること。軸aは維持でよい。'

new_loop() { # $1=session_id $2=max $3=threshold → stdout: state path
  local dir="$TMP/$1"
  mkdir -p "$dir"
  bash "$P/scripts/loop-start.sh" "$dir" "$2" "$3" "$1" >/dev/null
  local state="$dir/.yt-loop/sessions/$1/state.json"
  jq '.task="テスト" | .criteria="a,b"' "$state" > "$state.tmp" && mv "$state.tmp" "$state"
  echo "$state"
}

write_eval() { # $1=turns_dir $2=NNN $3=score $4=feedback
  jq -n --argjson s "$3" --arg fb "$4" \
    '{score:$s, quality:{overall:$s, breakdown:{a:($s-1), b:($s+1)}}, feedback:$fb, evaluator_skill:"e"}' \
    > "$1/turn-$2-eval.json"
}

set_eval_state() { # $1=state $2=iter $3=score
  jq --argjson i "$2" --argjson s "$3" '.phase="eval" | .latest_score=$s | .evaluated_iteration=$i' \
    "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

set_anchors() { # $1=state — アンカーを作って anchors_file に登録 (fingerprint --record の前に呼ぶ)
  local a
  a="$(dirname "$1")/criteria-anchors.md"
  printf '## a\n- 90+: 冒頭1文目に具体的な数字がある\n## b\n- 90+: まとめが1文で締まり行動をひとつ指定する\n' > "$a"
  jq --arg a "$a" '.anchors_file=$a' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

write_confirm() { # $1=turns_dir $2=NNN $3=score $4=feedback
  jq -n --argjson s "$3" --arg fb "$4" \
    '{score:$s, quality:{overall:$s, breakdown:{a:($s-1), b:($s+1)}}, feedback:$fb, evaluator_skill:"e"}' \
    > "$1/turn-$2-eval-confirm.json"
}

run_hook() { # $1=cwd $2=session_id → stdout: hook output
  printf '{"cwd":"%s","session_id":"%s","hook_event_name":"Stop"}' "$1" "$2" \
    | bash "$P/scripts/hook-stop.sh"
}

reason_of() { printf '%s' "$1" | jq -r '.reason // ""' 2>/dev/null || true; }

# --- G1: 正規合格 (アンカー + 確認採点つき。低い方=92 が採用される) -------------
S=$(new_loop g1 6 90); D="$TMP/g1"; T=$(jq -r '.turns_dir' "$S")
set_anchors "$S"
bash "$P/scripts/fingerprint.sh" "$S" --record >/dev/null
echo "本文" > "$T/turn-000-output.md"
write_eval "$T" 000 92 "$FB0"
write_confirm "$T" 000 93 "$FB1"
SHA=$( { shasum -a 256 "$T/turn-000-output.md" 2>/dev/null || sha256sum "$T/turn-000-output.md"; } | cut -d' ' -f1 )
jq --arg sha "$SHA" '.artifact_hashes={"000":$sha}' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
set_eval_state "$S" 0 92
OUT=$(run_hook "$D" g1)
if has "$(reason_of "$OUT")" "ENDED: threshold_met" \
   && [ "$(jq -r '.ended_reason' "$S")" = "threshold_met" ] \
   && [ "$(jq -r '.latest_score' "$S")" = "92" ]; then ok "G1 正規合格 (min採用) → ENDED"; else bad "G1 (reason: $(reason_of "$OUT" | head -1) / ended: $(jq -r '.ended_reason' "$S") / score: $(jq -r '.latest_score' "$S"))"; fi

# --- G2: スコア水増し --------------------------------------------------------
S=$(new_loop g2 6 90); D="$TMP/g2"; T=$(jq -r '.turns_dir' "$S")
bash "$P/scripts/fingerprint.sh" "$S" --record >/dev/null
echo "本文" > "$T/turn-000-output.md"
write_eval "$T" 000 80 "$FB0"          # eval は 80 点
set_eval_state "$S" 0 92               # state は 92 と主張
OUT=$(run_hook "$D" g2)
if has "$(reason_of "$OUT")" "PASS CLAIM REJECTED" \
   && [ "$(jq -r '.active' "$S")" = "true" ]; then ok "G2 スコア水増し → 拒否"; else bad "G2"; fi

# --- G3: threshold 改ざん ----------------------------------------------------
S=$(new_loop g3 6 90); D="$TMP/g3"; T=$(jq -r '.turns_dir' "$S")
bash "$P/scripts/fingerprint.sh" "$S" --record >/dev/null
echo "本文" > "$T/turn-000-output.md"
write_eval "$T" 000 80 "$FB0"
jq '.threshold=75' "$S" > "$S.tmp" && mv "$S.tmp" "$S"   # ループ中に緩める
set_eval_state "$S" 0 80
OUT=$(run_hook "$D" g3)
if has "$(reason_of "$OUT")" "changed mid-loop"; then ok "G3 threshold改ざん → 拒否"; else bad "G3"; fi

# --- G4: 成果物すり替え ------------------------------------------------------
S=$(new_loop g4 6 90); D="$TMP/g4"; T=$(jq -r '.turns_dir' "$S")
bash "$P/scripts/fingerprint.sh" "$S" --record >/dev/null
echo "採点された本文" > "$T/turn-000-output.md"
write_eval "$T" 000 93 "$FB0"
SHA=$( { shasum -a 256 "$T/turn-000-output.md" 2>/dev/null || sha256sum "$T/turn-000-output.md"; } | cut -d' ' -f1 )
jq --arg sha "$SHA" '.artifact_hashes={"000":$sha}' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
echo "採点後にすり替えた本文" > "$T/turn-000-output.md"
set_eval_state "$S" 0 93
OUT=$(run_hook "$D" g4)
if has "$(reason_of "$OUT")" "modified after evaluation"; then ok "G4 成果物すり替え → 拒否"; else bad "G4"; fi

# --- G5: ブリーフ改ざん ------------------------------------------------------
S=$(new_loop g5 6 90); D="$TMP/g5"; T=$(jq -r '.turns_dir' "$S")
mkdir -p "$D/.yt-loop/briefs"
printf '## 4. 絶対に言わない話\n- 有料プランの推奨\n' > "$D/.yt-loop/briefs/b.md"
jq --arg b "$D/.yt-loop/briefs/b.md" '.brief_file=$b' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
bash "$P/scripts/fingerprint.sh" "$S" --record >/dev/null
echo "本文" > "$T/turn-000-output.md"
write_eval "$T" 000 93 "$FB0"
printf '## 4. 絶対に言わない話\n(なし)\n' > "$D/.yt-loop/briefs/b.md"   # ループ中に約束を消す
set_eval_state "$S" 0 93
OUT=$(run_hook "$D" g5)
if has "$(reason_of "$OUT")" "changed mid-loop"; then ok "G5 ブリーフ改ざん → 拒否"; else bad "G5"; fi

# --- G6: feedback コピペ ------------------------------------------------------
S=$(new_loop g6 6 90); D="$TMP/g6"; T=$(jq -r '.turns_dir' "$S")
bash "$P/scripts/fingerprint.sh" "$S" --record >/dev/null
echo "本文0" > "$T/turn-000-output.md"; write_eval "$T" 000 80 "$FB0"; set_eval_state "$S" 0 80
run_hook "$D" g6 >/dev/null            # 継続 → iteration=1
echo "本文1" > "$T/turn-001-output.md"; write_eval "$T" 001 82 "$FB0"   # 同一 feedback
set_eval_state "$S" 1 82
OUT=$(run_hook "$D" g6)
if has "$(reason_of "$OUT")" "copy-paste" \
   && [ "$(jq -r '.iteration' "$S")" = "1" ]; then ok "G6 feedbackコピペ → 修復差し戻し"; else bad "G6 (reason: $(reason_of "$OUT" | head -1))"; fi

# --- G7: 機械チェック NG 3 連続 ------------------------------------------------
S=$(new_loop g7 9 90); D="$TMP/g7"; T=$(jq -r '.turns_dir' "$S")
bash "$P/scripts/fingerprint.sh" "$S" --record >/dev/null
ended=""
for i in 0 1 2; do
  NNN=$(printf '%03d' "$i")
  echo "本文$i" > "$T/turn-$NNN-output.md"
  jq -n '{score:null, mechanical:true, quality:{overall:null, breakdown:{}}, feedback:"機械チェックNG: 禁止ワード", evaluator_skill:"mechanical-check"}' > "$T/turn-$NNN-eval.json"
  jq --argjson i "$i" '.mech_ng=true | .latest_score=null | .phase="eval" | .evaluated_iteration=$i' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
  OUT=$(run_hook "$D" g7)
done
if [ "$(jq -r '.ended_reason' "$S")" = "mechanical_check_failed" ] \
   && has "$(reason_of "$OUT")" "ENDED: mechanical_check_failed"; then ok "G7 機械NG 3連続 → 終了+納品指示"; else bad "G7"; fi

# --- G8: 進捗ゼロ (feedback は毎回変える — コピペ検知と分離) ---------------------
S=$(new_loop g8 9 90); D="$TMP/g8"; T=$(jq -r '.turns_dir' "$S")
bash "$P/scripts/fingerprint.sh" "$S" --record >/dev/null
FBS=("$FB0" "$FB1" "$FB2")
for i in 0 1 2; do
  NNN=$(printf '%03d' "$i")
  echo "本文$i" > "$T/turn-$NNN-output.md"
  write_eval "$T" "$NNN" 85 "${FBS[$i]}"
  set_eval_state "$S" "$i" 85
  OUT=$(run_hook "$D" g8)
done
if [ "$(jq -r '.ended_reason' "$S")" = "no_progress" ] \
   && has "$(reason_of "$OUT")" "ENDED: no_progress"; then ok "G8 進捗ゼロ → 終了+納品指示"; else bad "G8 (reason: $(jq -r '.ended_reason' "$S"))"; fi

# --- G9: max 到達で必ず納品指示 -------------------------------------------------
S=$(new_loop g9 2 90); D="$TMP/g9"; T=$(jq -r '.turns_dir' "$S")
bash "$P/scripts/fingerprint.sh" "$S" --record >/dev/null
echo "本文0" > "$T/turn-000-output.md"; write_eval "$T" 000 70 "$FB0"; set_eval_state "$S" 0 70
run_hook "$D" g9 >/dev/null
echo "本文1" > "$T/turn-001-output.md"; write_eval "$T" 001 74 "$FB1"; set_eval_state "$S" 1 74
OUT=$(run_hook "$D" g9)
if [ "$(jq -r '.ended_reason' "$S")" = "max_iterations" ] \
   && has "$(reason_of "$OUT")" "Final step"; then ok "G9 max到達 → ENDED+納品指示"; else bad "G9"; fi

# --- G10: 採点アンカー改ざん ----------------------------------------------------
S=$(new_loop g10 6 90); D="$TMP/g10"; T=$(jq -r '.turns_dir' "$S")
ANCH="$(dirname "$S")/criteria-anchors.md"
printf '## a\n- 90+: 冒頭1文目に数字がある\n- 75-89: 数字はあるが2文目以降\n' > "$ANCH"
jq --arg a "$ANCH" '.anchors_file=$a' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
bash "$P/scripts/fingerprint.sh" "$S" --record >/dev/null
echo "本文" > "$T/turn-000-output.md"
write_eval "$T" 000 93 "$FB0"
printf '## a\n- 90+: なんとなく良い\n' > "$ANCH"   # ループ中に目盛りを緩める
set_eval_state "$S" 0 93
OUT=$(run_hook "$D" g10)
if has "$(reason_of "$OUT")" "changed mid-loop"; then ok "G10 アンカー改ざん → 拒否"; else bad "G10"; fi

# --- G11: final-report の裏取り (state 偽造 → VERIFY FAILED) --------------------
S=$(new_loop g11 6 90); D="$TMP/g11"; T=$(jq -r '.turns_dir' "$S")
echo "本文" > "$T/turn-000-output.md"
write_eval "$T" 000 87 "$FB0"
jq '.active=false | .ended_reason="threshold_met" | .best_score=92 | .best_iteration=0' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
RPT=$(bash "$P/scripts/final-report.sh" "$S" "$TMP/g11-out.md" 2>/dev/null || true)
if has "$RPT" "VERIFY FAILED"; then ok "G11 state偽造 → final-report が VERIFY FAILED"; else bad "G11"; fi

# --- G12: プリセット採点係の定義も指紋対象 (SKILL.md 改変 → 指紋が変わる) ---------
S=$(new_loop g12 6 90); D="$TMP/g12"
jq '.evaluator_skill="assign-yt-script-evaluator"' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
PRESET="$P/skills/assign-yt-script-evaluator/SKILL.md"
FP1=$(bash "$P/scripts/fingerprint.sh" "$S")
cp "$PRESET" "$TMP/preset.bak"
printf '\n<!-- tamper -->\n' >> "$PRESET"
FP2=$(bash "$P/scripts/fingerprint.sh" "$S")
cp "$TMP/preset.bak" "$PRESET"
FP3=$(bash "$P/scripts/fingerprint.sh" "$S")
if [ "$FP1" != "$FP2" ] && [ "$FP1" = "$FP3" ]; then ok "G12 プリセット定義の改変 → 指紋が変化 (復元で一致)"; else bad "G12"; fi

# --- G13: 確認採点の省略・コピー・低スコアの封鎖 ---------------------------------
S=$(new_loop g13 6 90); D="$TMP/g13"; T=$(jq -r '.turns_dir' "$S")
set_anchors "$S"
bash "$P/scripts/fingerprint.sh" "$S" --record >/dev/null
echo "本文" > "$T/turn-000-output.md"
write_eval "$T" 000 92 "$FB0"
set_eval_state "$S" 0 92
OUT=$(run_hook "$D" g13)
R1=""; has "$(reason_of "$OUT")" "confirmation eval not found" && R1="ok"
cp "$T/turn-000-eval.json" "$T/turn-000-eval-confirm.json"    # コピーで偽装
jq '.eval_repair_attempts=0' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
OUT=$(run_hook "$D" g13)
R2=""; has "$(reason_of "$OUT")" "byte-identical" && R2="ok"
write_confirm "$T" 000 85 "$FB1"                               # 確認が threshold 未満
jq '.eval_repair_attempts=0' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
OUT=$(run_hook "$D" g13)
R3=""; has "$(reason_of "$OUT")" "below threshold" && R3="ok"
if [ "$R1$R2$R3" = "okokok" ]; then ok "G13 確認採点の省略/コピー/低スコア → すべて拒否"; else bad "G13 ($R1/$R2/$R3)"; fi

# --- G14: 機械NG → 実採点で復帰 (カウンタのリセット) ------------------------------
S=$(new_loop g14 9 90); D="$TMP/g14"; T=$(jq -r '.turns_dir' "$S")
bash "$P/scripts/fingerprint.sh" "$S" --record >/dev/null
jq -n '{score:null, mechanical:true, quality:{overall:null, breakdown:{}}, feedback:"機械チェックNG: x", evaluator_skill:"mechanical-check"}' > "$T/turn-000-eval.json"
echo "本文0" > "$T/turn-000-output.md"
jq '.mech_ng=true | .latest_score=null | .phase="eval" | .evaluated_iteration=0' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
run_hook "$D" g14 >/dev/null
echo "本文1" > "$T/turn-001-output.md"; write_eval "$T" 001 80 "$FB1"; set_eval_state "$S" 1 80
run_hook "$D" g14 >/dev/null
if [ "$(jq -r '.mech_ng_count' "$S")" = "0" ] && [ "$(jq -r '.iteration' "$S")" = "2" ]; then ok "G14 機械NG→実採点で復帰 (streakリセット)"; else bad "G14 (mech_count=$(jq -r '.mech_ng_count' "$S") iter=$(jq -r '.iteration' "$S"))"; fi

# --- G15: loop-cancel の PASS 詐欺ガード ------------------------------------------
S=$(new_loop g15 6 90); D="$TMP/g15"
jq '.latest_score=85 | .evaluated_iteration=0' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
CANCEL_OUT=$(bash "$P/scripts/loop-cancel.sh" "$S" --reason passed 2>&1 || true)
if has "$CANCEL_OUT" "WARNING" && [ "$(jq -r '.ended_reason' "$S")" = "cancelled" ]; then ok "G15 cancel の合格自称 (85<90) → cancelled に降格"; else bad "G15 (ended: $(jq -r '.ended_reason' "$S"))"; fi

# --- G16: evaluator_runtime 改ざん ------------------------------------------------
S=$(new_loop g16 6 90); D="$TMP/g16"; T=$(jq -r '.turns_dir' "$S")
jq '.evaluator_runtime="skill"' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
set_anchors "$S"
bash "$P/scripts/fingerprint.sh" "$S" --record >/dev/null
echo "本文" > "$T/turn-000-output.md"
write_eval "$T" 000 93 "$FB0"
write_confirm "$T" 000 93 "$FB1"
SHA=$( { shasum -a 256 "$T/turn-000-output.md" 2>/dev/null || sha256sum "$T/turn-000-output.md"; } | cut -d' ' -f1 )
jq --arg sha "$SHA" '.artifact_hashes={"000":$sha} | .evaluator_runtime="fable"' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
set_eval_state "$S" 0 93
OUT=$(run_hook "$D" g16)
if has "$(reason_of "$OUT")" "changed mid-loop"; then ok "G16 evaluator_runtime改ざん → 拒否"; else bad "G16"; fi

# --- G17-G22: 多ベンダー確認採点 (judges) -------------------------------------------

write_ext_confirm() { # $1=turns_dir $2=NNN $3=judge $4=score $5=feedback
  jq -n --argjson s "$4" --arg fb "$5" \
    '{score:$s, quality:{overall:$s, breakdown:{a:($s-1), b:($s+1)}}, feedback:$fb, evaluator_skill:"e"}' \
    > "$1/turn-$2-eval-confirm-$3.json"
  { shasum -a 256 "$1/turn-$2-eval-confirm-$3.json" 2>/dev/null || sha256sum "$1/turn-$2-eval-confirm-$3.json"; } \
    | cut -d' ' -f1 > "$1/turn-$2-eval-confirm-$3.fresh"
}

pass_setup() { # $1=session_id $2=judges → S/D/T をセット (eval 92, artifact hash 済み)
  S=$(new_loop "$1" 6 90); D="$TMP/$1"; T=$(jq -r '.turns_dir' "$S")
  jq --arg j "$2" '.judges=$j' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
  set_anchors "$S"
  bash "$P/scripts/fingerprint.sh" "$S" --record >/dev/null
  echo "本文" > "$T/turn-000-output.md"
  write_eval "$T" 000 92 "$FB0"
  SHA=$( { shasum -a 256 "$T/turn-000-output.md" 2>/dev/null || sha256sum "$T/turn-000-output.md"; } | cut -d' ' -f1 )
  jq --arg sha "$SHA" '.artifact_hashes={"000":$sha}' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
  set_eval_state "$S" 0 92
}

# G17: 外部ジャッジ確認の欠落 → 拒否 (fail-open しない)
pass_setup g17 "host,grok"
OUT=$(run_hook "$D" g17)
if has "$(reason_of "$OUT")" "confirm-judges.sh" && [ "$(jq -r '.active' "$S")" = "true" ]; then
  ok "G17 外部ジャッジ確認の欠落 → 拒否"; else bad "G17"; fi

# G18: 外部1体 (min規則) — host フォーク確認なしで合格し、低い方 (91) を採用
pass_setup g18 "host,grok"
write_ext_confirm "$T" 000 grok 91 "$FB1"
OUT=$(run_hook "$D" g18)
if has "$(reason_of "$OUT")" "ENDED: threshold_met" \
   && has "$(reason_of "$OUT")" "rule=min" \
   && [ "$(jq -r '.latest_score' "$S")" = "91" ] \
   && [ "$(jq -r '.judge_confirm.rule' "$S")" = "min" ]; then
  ok "G18 外部1体min規則 → 合格 (91採用・hostフォーク不要)"; else bad "G18"; fi

# G19a: 外部2体 (下側中央値) — eval=92, fable=88, grok=91 → median 91 >= 90 で合格
pass_setup g19a "host,fable,grok"
write_ext_confirm "$T" 000 fable 88 "$FB1"
write_ext_confirm "$T" 000 grok 91 "$FB2"
OUT=$(run_hook "$D" g19a)
if has "$(reason_of "$OUT")" "ENDED: threshold_met" \
   && has "$(reason_of "$OUT")" "rule=median" \
   && [ "$(jq -r '.latest_score' "$S")" = "91" ]; then
  ok "G19a 外部2体median規則 → 合格 (中央値91採用)"; else bad "G19a"; fi

# G19b: 中央値が threshold 未満 → 拒否 (eval=92, fable=85, grok=89 → median 89)
pass_setup g19b "host,fable,grok"
write_ext_confirm "$T" 000 fable 85 "$FB1"
write_ext_confirm "$T" 000 grok 89 "$FB2"
OUT=$(run_hook "$D" g19b)
if has "$(reason_of "$OUT")" "below threshold" && [ "$(jq -r '.active' "$S")" = "true" ]; then
  ok "G19b 中央値がthreshold未満 → 拒否 (ループ続行)"; else bad "G19b"; fi

# G20a: 外部全滅 (.failed) + host フォーク確認あり → 降格して合格 (開示付き)
pass_setup g20a "host,grok"
printf 'CLI error or timeout' > "$T/turn-000-eval-confirm-grok.failed"
write_confirm "$T" 000 93 "$FB1"
OUT=$(run_hook "$D" g20a)
if has "$(reason_of "$OUT")" "ENDED: threshold_met" \
   && has "$(reason_of "$OUT")" "JUDGES DEGRADED" \
   && [ "$(jq -r '.judge_confirm.rule' "$S")" = "host-degraded" ]; then
  ok "G20a 外部全滅+host確認 → 降格合格 (開示付き)"; else bad "G20a"; fi

# G20b: 外部全滅 + host フォーク確認も無し → 拒否 (失敗で甘くならない)
pass_setup g20b "host,grok"
printf 'CLI error or timeout' > "$T/turn-000-eval-confirm-grok.failed"
OUT=$(run_hook "$D" g20b)
if has "$(reason_of "$OUT")" "confirmation eval not found" && [ "$(jq -r '.active' "$S")" = "true" ]; then
  ok "G20b 外部全滅+host確認なし → 拒否 (fail-openしない)"; else bad "G20b"; fi

# G21: judges 改ざん (記録後に外部ジャッジを外す) → 指紋不一致で拒否
pass_setup g21 "host,grok"
write_ext_confirm "$T" 000 grok 91 "$FB1"
jq '.judges="host"' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
write_confirm "$T" 000 93 "$FB2"
OUT=$(run_hook "$D" g21)
if has "$(reason_of "$OUT")" "changed mid-loop"; then ok "G21 judges改ざん → 拒否 (指紋)"; else bad "G21"; fi

# G22: fresh 証明なしの外部確認 → 失敗扱い (host確認も無ければ拒否)
pass_setup g22 "host,grok"
write_ext_confirm "$T" 000 grok 95 "$FB1"
rm -f "$T/turn-000-eval-confirm-grok.fresh"
OUT=$(run_hook "$D" g22)
if has "$(reason_of "$OUT")" "confirmation eval not found" && [ "$(jq -r '.active' "$S")" = "true" ]; then
  ok "G22 fresh証明なしの外部確認 → 失敗扱いで拒否"; else bad "G22"; fi

# CJ1: confirm-judges.sh ランナー (stub CLI 注入) — 成功で .json + .fresh、失敗で .failed
STUB="$TMP/stubbin"; mkdir -p "$STUB"
cat > "$STUB/grok-ok" <<'STUBEOF'
#!/bin/bash
printf '{"score":91,"quality":{"overall":91,"breakdown":{"a":90,"b":92}},"feedback":"軸aは冒頭の2文が説明的で弱い。1文目に数字を置き、2文目で視聴者の損失を名指しする形に変えると前のめりになる。軸bは維持でよい。","evaluator_skill":"e"}\n'
STUBEOF
cat > "$STUB/grok-ng" <<'STUBEOF'
#!/bin/bash
exit 1
STUBEOF
chmod +x "$STUB/grok-ok" "$STUB/grok-ng"
pass_setup cj1 "host,grok"
R1=""; R2=""
OUT=$(GROK_BIN="$STUB/grok-ok" bash "$P/scripts/confirm-judges.sh" "$S" 2>&1)
if has "$OUT" "JUDGE:grok SCORE:91" && has "$OUT" "RESULT:OK" \
   && [ -f "$T/turn-000-eval-confirm-grok.json" ] && [ -f "$T/turn-000-eval-confirm-grok.fresh" ]; then R1="ok"; fi
OUT=$(GROK_BIN="$STUB/grok-ng" bash "$P/scripts/confirm-judges.sh" "$S" 2>&1)
if has "$OUT" "JUDGE:grok FAILED" && has "$OUT" "RESULT:ALL_FAILED" \
   && [ -f "$T/turn-000-eval-confirm-grok.failed" ] && [ ! -f "$T/turn-000-eval-confirm-grok.json" ]; then R2="ok"; fi
if [ "$R1$R2" = "okok" ]; then ok "CJ1 confirm-judges.sh 成功/失敗の成果物"; else bad "CJ1 ($R1/$R2)"; fi

# --- V1-V4: validate-eval ------------------------------------------------------
SCHEMA="$P/skills/assign-yt-script-evaluator/eval-schema.json"
mk_script_eval() { # $1=overall $2=hook_score $3=out
  jq -n --argjson o "$1" --argjson h "$2" --arg fb "$FB0$FB1" \
    '{score:$o, quality:{overall:$o, breakdown:{"冒頭フック":$h,"視聴維持設計":95,"構成の明確さ":95,"具体性と信頼性":95,"CTAと導線":95}}, feedback:$fb, evaluator_skill:"assign-yt-script-evaluator"}' > "$3"
}
mk_script_eval 92 60 "$TMP/v1.json"
if ! bash "$P/scripts/validate-eval.sh" "$TMP/v1.json" "$SCHEMA" 90 >/dev/null 2>&1; then ok "V1 加重平均の上振れ → 拒否"; else bad "V1"; fi
mk_script_eval 78 60 "$TMP/v2.json"
if bash "$P/scripts/validate-eval.sh" "$TMP/v2.json" "$SCHEMA" 90 >/dev/null 2>&1; then ok "V2 下方向の総合判断 → 許容"; else bad "V2"; fi
jq -n --arg fb "$FB0" '{score:95, quality:{overall:95, breakdown:{a:95}}, feedback:$fb, evaluator_skill:"e"}' > "$TMP/v3.json"
if ! bash "$P/scripts/validate-eval.sh" "$TMP/v3.json" - 90 "a,b" >/dev/null 2>&1; then ok "V3 軸の欠落 → 拒否"; else bad "V3"; fi
jq -n '{score:95, quality:{overall:95, breakdown:{a:95,b:95}}, feedback:"短い", evaluator_skill:"e"}' > "$TMP/v4.json"
if ! bash "$P/scripts/validate-eval.sh" "$TMP/v4.json" - 90 "a,b" >/dev/null 2>&1; then ok "V4 短文feedback → 拒否"; else bad "V4"; fi
jq -n --arg fb "$FB0" '{score:85, quality:{overall:85, breakdown:{a:85,b:85}}, feedback:$fb, passed:true, evaluator_skill:"e"}' > "$TMP/v5.json"
if ! bash "$P/scripts/validate-eval.sh" "$TMP/v5.json" - 90 "a,b" >/dev/null 2>&1; then ok "V5 passed不整合 (85<90でtrue) → 拒否"; else bad "V5"; fi
mk_script_eval 88 88 "$TMP/v6.json"
jq '.evaluator_skill="fake-evaluator"' "$TMP/v6.json" > "$TMP/v6b.json"
if ! bash "$P/scripts/validate-eval.sh" "$TMP/v6b.json" "$SCHEMA" 90 >/dev/null 2>&1; then ok "V6 evaluator_skillなりすまし → 拒否"; else bad "V6"; fi

# --- J1-J4: codex loop-judge -----------------------------------------------------
OUTI=$( (cd "$TMP" && bash "$CX/loop-init.sh" "t" "a,b" 90 6) ); RUN="${OUTI##*RUN_DIR:}"
echo "本文" > "$RUN/turn-000-output.md"
jq -n --arg fb "$FB0" '{score:85, quality:{overall:85, breakdown:{a:84,b:86}}, feedback:$fb, evaluator_skill:"codex-fresh-eval"}' > "$RUN/turn-000-eval.json"
J1=$(bash "$CX/loop-judge.sh" "$RUN" 000)
if has "$J1" "SELF-SCORED"; then ok "J1 マーカー無し → SELF-SCORED開示"; else bad "J1"; fi
J2=$(bash "$CX/loop-judge.sh" "$RUN" 000)
if has "$J2" "ALREADY_JUDGED"; then ok "J2 二重判定 → ガード"; else bad "J2"; fi
echo "本文1" > "$RUN/turn-001-output.md"
jq -n --arg fb "$FB1" '{score:87, quality:{overall:87, breakdown:{a:86,b:88}}, feedback:$fb, evaluator_skill:"codex-fresh-eval"}' > "$RUN/turn-001-eval.json"
bash "$CX/mark-fresh.sh" "$RUN" 001 >/dev/null
J3=$(bash "$CX/loop-judge.sh" "$RUN" 001)
if ! has "$J3" "SELF-SCORED"; then ok "J3 マーカー有効 → 開示なし"; else bad "J3"; fi
echo "本文2" > "$RUN/turn-002-output.md"
jq -n --arg fb "$FB1" '{score:89, quality:{overall:89, breakdown:{a:88,b:90}}, feedback:$fb, evaluator_skill:"codex-fresh-eval"}' > "$RUN/turn-002-eval.json"
if ! bash "$CX/loop-judge.sh" "$RUN" 002 >/dev/null 2>&1; then ok "J4 feedbackコピペ → INVALID"; else bad "J4"; fi

# --------------------------------------------------------------------------------
if [ "$FAIL" -ne 0 ]; then
  echo "guard-tests: FAILED" >&2
  exit 1
fi
echo "guard-tests: ok (G1-G22, CJ1, V1-V6, J1-J4)"
