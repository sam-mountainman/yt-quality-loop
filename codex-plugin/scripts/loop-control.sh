#!/bin/bash
# loop-control.sh — Stop hook 本体ロジック (hook-stop.sh から source される)
#
# 呼び出し側が以下を設定してから source する。
#   STATE_FILE:  state.json の絶対パス
#   LOOP_LABEL:  ログ用ラベル
#
# HOOK SAFETY: hook は何があっても exit 0 しなければならない。
#
# 判定の心臓部は整数比較 (score/threshold, iteration/max, 経過時間, 進捗ゼロ)。
# ただし「合格」だけは主張を検証してから通す:
#   eval JSON の実在 → 契約検証 (validate-eval) → score の直読 → 機械チェック再実行
#   → ものさし指紋 (fingerprint) の照合。
# orchestrator が書いた latest_score は「合格主張のシグナル」であって、合格の根拠にしない。

if [ ! -f "$STATE_FILE" ]; then
  exit 0
fi

ACTIVE=$(jq -r '.active' "$STATE_FILE" 2>/dev/null) || ACTIVE="false"
if [ "$ACTIVE" != "true" ]; then
  exit 0
fi

ITERATION=$(jq -r '.iteration' "$STATE_FILE" 2>/dev/null) || ITERATION="0"
MAX=$(jq -r '.max_iterations' "$STATE_FILE" 2>/dev/null) || MAX="6"
THRESHOLD=$(jq -r '.threshold // 90' "$STATE_FILE" 2>/dev/null) || THRESHOLD="90"
SCORE=$(jq -r '.latest_score // "null"' "$STATE_FILE" 2>/dev/null) || SCORE="null"
TASK=$(jq -r '.task // "task not set"' "$STATE_FILE" 2>/dev/null) || TASK="task not set"
PHASE=$(jq -r '.phase // "plan"' "$STATE_FILE" 2>/dev/null) || PHASE="plan"
EVAL_ITER=$(jq -r '.evaluated_iteration // "null"' "$STATE_FILE" 2>/dev/null) || EVAL_ITER="null"
STARTED_AT=$(jq -r '.started_at // "null"' "$STATE_FILE" 2>/dev/null) || STARTED_AT="null"
MAX_WALL=$(jq -r '.max_wall_minutes // 0' "$STATE_FILE" 2>/dev/null) || MAX_WALL="0"
REPAIR=$(jq -r '.eval_repair_attempts // 0' "$STATE_FILE" 2>/dev/null) || REPAIR="0"
MECH_NG=$(jq -r '.mech_ng // false' "$STATE_FILE" 2>/dev/null) || MECH_NG="false"
MECH_COUNT=$(jq -r '.mech_ng_count // 0' "$STATE_FILE" 2>/dev/null) || MECH_COUNT="0"
TURNS_DIR=$(jq -r '.turns_dir // ""' "$STATE_FILE" 2>/dev/null) || TURNS_DIR=""
CRITERIA=$(jq -r '.criteria // ""' "$STATE_FILE" 2>/dev/null) || CRITERIA=""
EVAL_SKILL=$(jq -r '.evaluator_skill // ""' "$STATE_FILE" 2>/dev/null) || EVAL_SKILL=""
FP=$(jq -r '.config_fingerprint // ""' "$STATE_FILE" 2>/dev/null) || FP=""
PROJECT_DIR=$(jq -r '.project_dir // ""' "$STATE_FILE" 2>/dev/null) || PROJECT_DIR=""

if [ "$SCORE" != "null" ]; then
  if ! [[ "$SCORE" =~ ^-?[0-9]+$ ]]; then
    SCORE="null"
  fi
fi
if ! [[ "$THRESHOLD" =~ ^[0-9]+$ ]]; then THRESHOLD="90"; fi
if ! [[ "$ITERATION" =~ ^[0-9]+$ ]]; then ITERATION="0"; fi
if ! [[ "$MAX" =~ ^[0-9]+$ ]]; then MAX="6"; fi
if ! [[ "$REPAIR" =~ ^[0-9]+$ ]]; then REPAIR="0"; fi
if ! [[ "$MECH_COUNT" =~ ^[0-9]+$ ]]; then MECH_COUNT="0"; fi

CONTROL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || CONTROL_DIR=""

NOW=$(date +%s)

# --- ループ終了時の最終指示 (1 回だけ block を出す) ---
# max/時間切れ/進捗ゼロ等で終わった時、これが無いと「ベスト版を納品して最終報告する」
# 主体が存在しない (orchestrator は既に応答を終えている)。active=false を書いた後に
# 出すので、次の Stop では二重発火しない。
emit_final_block() {
  local label="$1"
  local best_iter best_score best_line
  best_iter=$(jq -r '.best_iteration // "null"' "$STATE_FILE" 2>/dev/null) || best_iter="null"
  best_score=$(jq -r '.best_score // "null"' "$STATE_FILE" 2>/dev/null) || best_score="null"
  if [[ "$best_iter" =~ ^[0-9]+$ ]]; then
    best_line="Best: iteration $best_iter (score $best_score) -> $TURNS_DIR/turn-$(printf '%03d' "$best_iter")-output.md"
  else
    best_line="Best: none (合格評価が一度も無かったため納品できるベスト版はない。$TURNS_DIR のログをユーザーに案内する)"
  fi
  local report_cmd="bash '$CONTROL_DIR/final-report.sh' '$STATE_FILE'"
  local reason="[$LOOP_LABEL ENDED: $label]
STATE_FILE=$STATE_FILE
$best_line
Final step — do ALL of this now in one response, then end it:
1. Run this command and use its output as the source of truth for delivery and reporting:
   $report_cmd
2. Report in Japanese: 成果物パス、最終/ベストスコアと quality.breakdown、スコア推移、終了理由 ($label)、最後の feedback に残った改善余地。
3. Add these two notes if the report did not already include them: 「納品物を手直ししたら /yt-profile 更新 で次回に反映できます」「スコアは同一成果物でも±数点ブレます (90点=伸びる保証ではありません)」
Do NOT restart the loop."
  jq -n --arg reason "$reason" '{"decision":"block","reason":$reason}' 2>/dev/null
}

finalize() {
  jq --arg r "$1" '.active = false | .ended_reason = $r' "$STATE_FILE" > "$STATE_FILE.tmp.$$" \
    && mv "$STATE_FILE.tmp.$$" "$STATE_FILE" 2>/dev/null
}

# --- Never-started cleanup (静かに閉じる。納品物が無いので final block は出さない) ---
if { [ -z "$TASK" ] || [ "$TASK" = "task not set" ]; } && [ "$ITERATION" = "0" ] && [ "$SCORE" = "null" ]; then
  if [[ "$STARTED_AT" =~ ^[0-9]+$ ]] && [ $((NOW - STARTED_AT)) -lt 600 ]; then
    exit 0
  fi
  finalize "never_started"
  exit 0
fi

# --- Wall-clock budget (時間の停止条件) ---
# 例外: ちょうど合格主張が来ている場合は下の pass gate (検証) に任せる。
# 機械チェック NG (mech_ng) は合格主張ではないので例外にしない。
if [[ "$STARTED_AT" =~ ^[0-9]+$ ]] && [[ "$MAX_WALL" =~ ^[1-9][0-9]*$ ]]; then
  if [ $((NOW - STARTED_AT)) -ge $((MAX_WALL * 60)) ]; then
    if [ "$PHASE" = "eval" ] && [ "$SCORE" != "null" ] && [ "$SCORE" -ge "$THRESHOLD" ] 2>/dev/null \
       && [ "$MECH_NG" != "true" ] \
       && { [ "$EVAL_ITER" = "null" ] || [ "$EVAL_ITER" = "$ITERATION" ]; }; then
      : # pass claim on this very evaluation — let the pass gate verify it below
    else
      finalize "wall_clock_exceeded"
      emit_final_block "wall_clock_exceeded (時間上限 ${MAX_WALL} 分)"
      exit 0
    fi
  fi
fi

# --- Phase gate ---
if [ "$PHASE" != "eval" ]; then
  exit 0
fi

# --- Invalid eval output repair ---
if [ "$SCORE" = "null" ] && [ "$MECH_NG" != "true" ]; then
  if [ "$REPAIR" -ge 2 ]; then
    finalize "invalid_eval_output"
    emit_final_block "invalid_eval_output (評価出力の修復に2回失敗)"
    exit 0
  fi
  jq '.eval_repair_attempts = ((.eval_repair_attempts // 0) + 1)' "$STATE_FILE" > "$STATE_FILE.tmp.$$" \
    && mv "$STATE_FILE.tmp.$$" "$STATE_FILE" 2>/dev/null
  EVAL_FILE_HINT="$TURNS_DIR/turn-$(printf '%03d' "$ITERATION")-eval.json"
  REASON="[$LOOP_LABEL $ITERATION/$MAX | INVALID EVAL OUTPUT]
STATE_FILE=$STATE_FILE
The evaluation phase finished but latest_score is not a valid integer.
Repair now: re-run the evaluator skill as a fresh fork so it writes a genuine $EVAL_FILE_HINT. Do NOT edit the eval JSON or write the score yourself — only the evaluator writes it. Then write the evaluator's score back to latest_score in STATE_FILE (keep phase=\"eval\") and end your response."
  jq -n --arg reason "$REASON" '{"decision":"block","reason":$reason}' 2>/dev/null || exit 0
  exit 0
fi

# --- Double-fire guard ---
if [ "$EVAL_ITER" != "null" ] && [ "$EVAL_ITER" != "$ITERATION" ]; then
  exit 0
fi

NNN=$(printf '%03d' "$ITERATION")
EVAL_FILE="$TURNS_DIR/turn-$NNN-eval.json"
ARTIFACT_FILE="$TURNS_DIR/turn-$NNN-output.md"

hash_of() {
  { shasum -a 256 "$1" 2>/dev/null || sha256sum "$1" 2>/dev/null; } | cut -d' ' -f1
}

# --- feedback コピペ検知 ---
# 前イテレーションと一言一句同じ feedback は「採点した振り」の典型。
# 修復パス (evaluator の再実行) に回す。mech_ng の機械 feedback は対象外。
if [ "$MECH_NG" != "true" ] && [ "$ITERATION" -gt 0 ] && [ -f "$EVAL_FILE" ]; then
  PREV_EVAL_FILE="$TURNS_DIR/turn-$(printf '%03d' $((ITERATION - 1)))-eval.json"
  if [ -f "$PREV_EVAL_FILE" ]; then
    CUR_FB=$(jq -r '.feedback // ""' "$EVAL_FILE" 2>/dev/null) || CUR_FB=""
    PREV_FB=$(jq -r '.feedback // ""' "$PREV_EVAL_FILE" 2>/dev/null) || PREV_FB=""
    PREV_MECH=$(jq -r '.mechanical // false' "$PREV_EVAL_FILE" 2>/dev/null) || PREV_MECH="false"
    if [ -n "$CUR_FB" ] && [ "$CUR_FB" = "$PREV_FB" ] && [ "$PREV_MECH" != "true" ]; then
      if [ "$REPAIR" -ge 2 ]; then
        finalize "invalid_eval_output"
        emit_final_block "invalid_eval_output (feedback が前回と完全一致 — 採点のコピペ)"
        exit 0
      fi
      jq '.eval_repair_attempts = ((.eval_repair_attempts // 0) + 1)' "$STATE_FILE" > "$STATE_FILE.tmp.$$" \
        && mv "$STATE_FILE.tmp.$$" "$STATE_FILE" 2>/dev/null
      REASON="[$LOOP_LABEL $ITERATION/$MAX | EVAL REJECTED: feedback is identical to the previous iteration (copy-paste)]
STATE_FILE=$STATE_FILE
Re-run the evaluator as a fresh fork so it actually reads and evaluates $ARTIFACT_FILE. Do NOT edit the eval JSON by hand. Then write the evaluator's score back and end your response."
      jq -n --arg reason "$REASON" '{"decision":"block","reason":$reason}' 2>/dev/null || exit 0
      exit 0
    fi
  fi
fi

# --- 機械チェック NG の継続 (score ではなくフラグで判定する) ---
# threshold との比較・prev_score 更新・進捗ゼロ判定には一切関与させない
# (センチネル値が実スコア系列を汚染する事故の防止)。3 回連続で NG なら打ち切り。
if [ "$MECH_NG" = "true" ]; then
  MECH_COUNT=$((MECH_COUNT + 1))
  if [ "$MECH_COUNT" -ge 3 ]; then
    finalize "mechanical_check_failed"
    emit_final_block "mechanical_check_failed (機械チェックNGが3回連続 — task か mechanical-checks.json の見直しが必要)"
    exit 0
  fi
  NEXT_ITERATION=$((ITERATION + 1))
  if [ "$NEXT_ITERATION" -ge "$MAX" ]; then
    jq --argjson i "$NEXT_ITERATION" '.iteration = $i' "$STATE_FILE" > "$STATE_FILE.tmp.$$" \
      && mv "$STATE_FILE.tmp.$$" "$STATE_FILE" 2>/dev/null
    finalize "max_iterations"
    emit_final_block "max_iterations (上限 $MAX 回)"
    exit 0
  fi
  MECH_FEEDBACK=""
  [ -f "$EVAL_FILE" ] && MECH_FEEDBACK=$(jq -r '.feedback // ""' "$EVAL_FILE" 2>/dev/null) || MECH_FEEDBACK=""
  jq --argjson i "$NEXT_ITERATION" --argjson mc "$MECH_COUNT" \
    '.iteration = $i | .phase = "plan" | .latest_score = null | .evaluated_iteration = null | .eval_repair_attempts = 0 | .mech_ng = false | .mech_ng_count = $mc' \
    "$STATE_FILE" > "$STATE_FILE.tmp.$$" \
    && mv "$STATE_FILE.tmp.$$" "$STATE_FILE" 2>/dev/null
  NNN_NEXT=$(printf '%03d' "$NEXT_ITERATION")
  REASON="[$LOOP_LABEL $NEXT_ITERATION/$MAX | MECHANICAL CHECK FAILED (streak $MECH_COUNT/3)]
STATE_FILE=$STATE_FILE
TURNS_DIR=$TURNS_DIR
Task: $TASK
Mechanical violations (must fix — これはスクリプト判定なので言い訳は通らない):
$MECH_FEEDBACK
Next actions (do all in ONE response, then end it):
1. Write the next plan to $TURNS_DIR/turn-$NNN_NEXT-plan.md (fix ONLY the mechanical violations first).
2. Launch the generator skill, then run the mechanical check again (3c-0).
3. If mechanical check passes, launch the evaluator; validate and write the score back; end your response."
  jq -n --arg reason "$REASON" '{"decision":"block","reason":$reason}' 2>/dev/null || exit 0
  exit 0
fi

# --- Pass gate: 合格主張の検証 ---
# latest_score >= threshold は「主張」。eval JSON を直読し、契約検証・機械チェック・
# ものさし指紋をすべて通った時だけ threshold_met にする。
if [ "$SCORE" != "null" ] && [ "$SCORE" -ge "$THRESHOLD" ] 2>/dev/null; then
  VERIFY_FAIL=""
  EVAL_SCORE=""
  if [ ! -f "$EVAL_FILE" ]; then
    VERIFY_FAIL="eval JSON not found: $EVAL_FILE"
  fi
  if [ -z "$VERIFY_FAIL" ]; then
    EVAL_SCORE=$(jq -r '.score // "null"' "$EVAL_FILE" 2>/dev/null) || EVAL_SCORE="null"
    if ! [[ "$EVAL_SCORE" =~ ^[0-9]+$ ]] || [ "$EVAL_SCORE" -lt "$THRESHOLD" ]; then
      VERIFY_FAIL="eval JSON score ('$EVAL_SCORE') does not support the pass claim (state says $SCORE)"
    fi
  fi
  if [ -z "$VERIFY_FAIL" ] && [ -n "$CONTROL_DIR" ] && [ -f "$CONTROL_DIR/validate-eval.sh" ]; then
    SCHEMA_FILE="$CONTROL_DIR/../skills/$EVAL_SKILL/eval-schema.json"
    [ -f "$SCHEMA_FILE" ] || SCHEMA_FILE="-"
    if ! bash "$CONTROL_DIR/validate-eval.sh" "$EVAL_FILE" "$SCHEMA_FILE" "$THRESHOLD" "$CRITERIA" >/dev/null 2>&1; then
      VERIFY_FAIL="eval JSON failed contract validation (validate-eval.sh)"
    fi
  fi
  if [ -z "$VERIFY_FAIL" ] && [ -n "$PROJECT_DIR" ] && [ -f "$PROJECT_DIR/.yt-loop/mechanical-checks.json" ] \
     && [ -n "$CONTROL_DIR" ] && [ -f "$CONTROL_DIR/check-mechanical.sh" ]; then
    if ! bash "$CONTROL_DIR/check-mechanical.sh" "$ARTIFACT_FILE" "$PROJECT_DIR/.yt-loop/mechanical-checks.json" >/dev/null 2>&1; then
      VERIFY_FAIL="mechanical check failed on the passing artifact"
    fi
  fi
  # 採点後の成果物すり替え検知: 3e で記録した artifact のハッシュと現物を照合する
  if [ -z "$VERIFY_FAIL" ]; then
    STORED_SHA=$(jq -r --arg n "$NNN" '(.artifact_hashes // {})[$n] // ""' "$STATE_FILE" 2>/dev/null) || STORED_SHA=""
    if [ -n "$STORED_SHA" ] && [ -f "$ARTIFACT_FILE" ]; then
      CUR_SHA=$(hash_of "$ARTIFACT_FILE") || CUR_SHA=""
      if [ -n "$CUR_SHA" ] && [ "$CUR_SHA" != "$STORED_SHA" ]; then
        VERIFY_FAIL="artifact was modified after evaluation (採点後に成果物が変更されている)"
      fi
    fi
  fi
  if [ -z "$VERIFY_FAIL" ] && [ -n "$CONTROL_DIR" ] && [ -f "$CONTROL_DIR/fingerprint.sh" ]; then
    if [ -z "$FP" ] || [ "$FP" = "null" ]; then
      VERIFY_FAIL="config fingerprint not recorded (Step 2 の fingerprint.sh --record が未実行)"
    else
      CUR_FP=$(bash "$CONTROL_DIR/fingerprint.sh" "$STATE_FILE" 2>/dev/null) || CUR_FP=""
      if [ -n "$CUR_FP" ] && [ "$CUR_FP" != "$FP" ]; then
        VERIFY_FAIL="scoring config (threshold/criteria/profile/mechanical rules/brief/anchors/evaluator定義) changed mid-loop — ものさしの途中変更は合格にできない"
      fi
    fi
  fi
  # 起草順序の照合: 指紋の記録は最初の生成より前でなければならない
  # (生成後に記録すると「今の成果物が高く出るものさし」を引ける)
  if [ -z "$VERIFY_FAIL" ]; then
    REC_AT=$(jq -r '.fingerprint_recorded_at // ""' "$STATE_FILE" 2>/dev/null) || REC_AT=""
    FIRST_OUT="$TURNS_DIR/turn-000-output.md"
    if [[ "$REC_AT" =~ ^[0-9]+$ ]] && [ -f "$FIRST_OUT" ]; then
      OUT_MTIME=$(stat -c %Y "$FIRST_OUT" 2>/dev/null || stat -f %m "$FIRST_OUT" 2>/dev/null) || OUT_MTIME=""
      if [[ "$OUT_MTIME" =~ ^[0-9]+$ ]] && [ "$OUT_MTIME" -lt "$REC_AT" ]; then
        VERIFY_FAIL="config fingerprint was recorded AFTER generation started — ものさしは最初の生成の前に固定する"
      fi
    fi
  fi
  # 自由 criteria (汎用 evaluator / codex-hook) は採点アンカー必須
  RUNTIME=$(jq -r '.runtime // ""' "$STATE_FILE" 2>/dev/null) || RUNTIME=""
  if [ -z "$VERIFY_FAIL" ]; then
    ANCH=$(jq -r '.anchors_file // ""' "$STATE_FILE" 2>/dev/null) || ANCH=""
    if { [ "$EVAL_SKILL" = "assign-yt-evaluator" ] || [ "$RUNTIME" = "codex-hook" ]; } \
       && { [ -z "$ANCH" ] || [ "$ANCH" = "null" ]; }; then
      VERIFY_FAIL="anchors_file is not set — 自由 criteria は採点アンカー (90/75の目盛り) を起草・固定してから回す"
    fi
  fi
  # 確認採点の実在と一致: 合格主張には独立した 2 回目の採点が必要 (ガチャ合格・省略の封鎖)
  # judges に外部ジャッジ (fable=claude / codex / grok) がある場合、確認採点の席は外部ベンダーが担う:
  #   有効な外部採点 1 つ → min(本採点, 外部) >= threshold (現行 min 規則の席替え)
  #   有効な外部採点 2 つ以上 → 本採点+外部の下側中央値 >= threshold (2/3 合意)。採用は min(本採点, 中央値)
  # 外部が全滅 (.failed) した時だけ従来の host フォーク確認に降格する (降格は開示。fail-open はしない)。
  FINAL_SCORE="$EVAL_SCORE"
  JUDGES=$(jq -r '.judges // "host"' "$STATE_FILE" 2>/dev/null) || JUDGES="host"
  EXT_LIST=""
  for _j in fable codex grok; do
    case ",$JUDGES," in *",$_j,"*) EXT_LIST="$EXT_LIST$_j ";; esac
  done
  JUDGE_NOTE=""
  EXT_SCORES=""
  EXT_FAILED=""
  if [ -z "$VERIFY_FAIL" ] && [ -n "$EXT_LIST" ]; then
    SCHEMA_J="$CONTROL_DIR/../skills/$EVAL_SKILL/eval-schema.json"
    [ -f "$SCHEMA_J" ] || SCHEMA_J="-"
    for _j in $EXT_LIST; do
      CJ="$TURNS_DIR/turn-$NNN-eval-confirm-$_j.json"
      MJ="$TURNS_DIR/turn-$NNN-eval-confirm-$_j.fresh"
      FJ="$TURNS_DIR/turn-$NNN-eval-confirm-$_j.failed"
      if [ -f "$CJ" ]; then
        if [ ! -f "$MJ" ] || [ "$(cat "$MJ" 2>/dev/null)" != "$(hash_of "$CJ")" ]; then
          EXT_FAILED="$EXT_FAILED$_j:fresh証明なし "
        elif [ "$(hash_of "$EVAL_FILE")" = "$(hash_of "$CJ")" ]; then
          EXT_FAILED="$EXT_FAILED$_j:本採点のコピー "
        elif ! bash "$CONTROL_DIR/validate-eval.sh" "$CJ" "$SCHEMA_J" "$THRESHOLD" "$CRITERIA" >/dev/null 2>&1; then
          EXT_FAILED="$EXT_FAILED$_j:契約違反 "
        else
          JSC=$(jq -r '.score // "null"' "$CJ" 2>/dev/null) || JSC="null"
          if [[ "$JSC" =~ ^[0-9]+$ ]]; then
            EXT_SCORES="$EXT_SCORES$JSC "
          else
            EXT_FAILED="$EXT_FAILED$_j:score不正 "
          fi
        fi
      elif [ -f "$FJ" ]; then
        EXT_FAILED="$EXT_FAILED$_j:$(tr -d '\n' < "$FJ" 2>/dev/null | head -c 60) "
      else
        VERIFY_FAIL="external confirmation for judge '$_j' not found — 合格主張の前に confirm-judges.sh を実行する (fail-open はしない)"
        break
      fi
    done
  fi
  if [ -z "$VERIFY_FAIL" ] && [ -n "$EXT_LIST" ] && [ -n "$EXT_SCORES" ]; then
    # 外部ジャッジ集計 (有効な外部採点があるので host フォーク確認は席替えで不要)
    SORTED=$(printf '%s\n' $EXT_SCORES "$EVAL_SCORE" | sort -n)
    CNT=$(printf '%s\n' "$SORTED" | wc -l | tr -d ' ')
    JMIN=$(printf '%s\n' "$SORTED" | head -1)
    if [ "$CNT" -ge 3 ]; then
      AGG=$(printf '%s\n' "$SORTED" | sed -n "$(( (CNT + 1) / 2 ))p")   # 下側中央値
      JRULE="median"
    else
      AGG="$JMIN"; JRULE="min"
    fi
    if [ "$AGG" -lt "$THRESHOLD" ] 2>/dev/null; then
      VERIFY_FAIL="external confirmation ($JRULE=$AGG / eval=$EVAL_SCORE ext=${EXT_SCORES% }) is below threshold — 低い方を採用してループを続行する (合格主張しない)"
    else
      [ "$AGG" -lt "$FINAL_SCORE" ] && FINAL_SCORE="$AGG"
      JUDGE_NOTE=" / JUDGES: ${EXT_LIST% } (rule=$JRULE, eval=$EVAL_SCORE, ext=${EXT_SCORES% }, min=$JMIN)"
      [ -n "$EXT_FAILED" ] && JUDGE_NOTE="$JUDGE_NOTE / JUDGE FAILED: ${EXT_FAILED% } (最終報告で開示)"
      jq --arg ext "${EXT_SCORES% }" --arg rule "$JRULE" --arg failed "${EXT_FAILED% }" \
         --arg judges "${EXT_LIST% }" --argjson adopted "$FINAL_SCORE" \
        '.judge_confirm = {judges:$judges, ext_scores:$ext, rule:$rule, adopted:$adopted, failed:$failed}' \
        "$STATE_FILE" > "$STATE_FILE.tmp.$$" && mv "$STATE_FILE.tmp.$$" "$STATE_FILE" 2>/dev/null
    fi
  elif [ -z "$VERIFY_FAIL" ]; then
    # host フォーク確認 (judges 未設定、または外部ジャッジ全滅による降格)
    if [ -n "$EXT_LIST" ]; then
      JUDGE_NOTE=" / JUDGES DEGRADED: 外部確認採点が全滅 (${EXT_FAILED% }) — host フォーク確認に降格 (最終報告で必ず開示)"
      jq --arg failed "${EXT_FAILED% }" --arg judges "${EXT_LIST% }" \
        '.judge_confirm = {judges:$judges, ext_scores:"", rule:"host-degraded", failed:$failed}' \
        "$STATE_FILE" > "$STATE_FILE.tmp.$$" && mv "$STATE_FILE.tmp.$$" "$STATE_FILE" 2>/dev/null
    fi
    CONFIRM_FILE="$TURNS_DIR/turn-$NNN-eval-confirm.json"
    if [ ! -f "$CONFIRM_FILE" ]; then
      VERIFY_FAIL="confirmation eval not found ($CONFIRM_FILE) — 合格主張には確認採点 (3d-2) が必要"
    elif [ "$(hash_of "$EVAL_FILE")" = "$(hash_of "$CONFIRM_FILE")" ]; then
      VERIFY_FAIL="confirmation eval is byte-identical to the primary eval — コピーは確認採点ではない"
    else
      SCHEMA_FILE2="$CONTROL_DIR/../skills/$EVAL_SKILL/eval-schema.json"
      [ -f "$SCHEMA_FILE2" ] || SCHEMA_FILE2="-"
      if ! bash "$CONTROL_DIR/validate-eval.sh" "$CONFIRM_FILE" "$SCHEMA_FILE2" "$THRESHOLD" "$CRITERIA" >/dev/null 2>&1; then
        VERIFY_FAIL="confirmation eval failed contract validation"
      else
        CSCORE=$(jq -r '.score // "null"' "$CONFIRM_FILE" 2>/dev/null) || CSCORE="null"
        if ! [[ "$CSCORE" =~ ^[0-9]+$ ]]; then
          VERIFY_FAIL="confirmation eval score is not an integer"
        elif [ "$CSCORE" -lt "$THRESHOLD" ]; then
          VERIFY_FAIL="confirmation score ($CSCORE) is below threshold — 低い方を採用してループを続行する (合格主張しない)"
        elif [ "$CSCORE" -lt "$FINAL_SCORE" ]; then
          FINAL_SCORE="$CSCORE"
        fi
      fi
    fi
  fi
  if [ -z "$VERIFY_FAIL" ]; then
    # codex-hook 経路: fresh 証明マーカーが無い/不一致の合格は SELF-SCORED として開示する (拒否はしない)
    SELF_NOTE=""
    if [ "$RUNTIME" = "codex-hook" ]; then
      MARKER="$TURNS_DIR/turn-$NNN-eval.fresh"
      MOK="false"
      if [ -f "$MARKER" ] && [ "$(cat "$MARKER" 2>/dev/null)" = "$(hash_of "$EVAL_FILE")" ]; then
        MOK="true"
      fi
      if [ "$MOK" != "true" ]; then
        SELF_NOTE=" / SELF-SCORED (fresh 証明なし — 最終報告で必ず開示)"
        jq --argjson i "$ITERATION" '.self_scored = ((.self_scored // []) + [$i])' \
          "$STATE_FILE" > "$STATE_FILE.tmp.$$" && mv "$STATE_FILE.tmp.$$" "$STATE_FILE" 2>/dev/null
      fi
    fi
    jq --argjson s "$FINAL_SCORE" --argjson i "$ITERATION" \
      '.latest_score = $s
       | (if (.best_score == null or $s > .best_score) then .best_score = $s | .best_iteration = $i else . end)' \
      "$STATE_FILE" > "$STATE_FILE.tmp.$$" && mv "$STATE_FILE.tmp.$$" "$STATE_FILE" 2>/dev/null
    finalize "threshold_met"
    emit_final_block "threshold_met (合格 — 検証済み: eval 直読 / 契約 / 機械チェック / hash / 指紋 / 確認採点)$SELF_NOTE$JUDGE_NOTE"
    exit 0
  fi
  # 合格主張が検証に落ちた
  if [ "$REPAIR" -ge 2 ]; then
    finalize "pass_verification_failed"
    emit_final_block "pass_verification_failed ($VERIFY_FAIL)"
    exit 0
  fi
  jq '.eval_repair_attempts = ((.eval_repair_attempts // 0) + 1)' "$STATE_FILE" > "$STATE_FILE.tmp.$$" \
    && mv "$STATE_FILE.tmp.$$" "$STATE_FILE" 2>/dev/null
  REASON="[$LOOP_LABEL $ITERATION/$MAX | PASS CLAIM REJECTED]
STATE_FILE=$STATE_FILE
Reason: $VERIFY_FAIL
Re-run the evaluator skill as a fresh fork so it writes a genuine eval JSON to $EVAL_FILE. Do NOT edit the eval JSON, the criteria/profile, or the state score by hand. Then write the evaluator's score to latest_score (keep phase=\"eval\") and end your response."
  jq -n --arg reason "$REASON" '{"decision":"block","reason":$reason}' 2>/dev/null || exit 0
  exit 0
fi

NEXT_ITERATION=$((ITERATION + 1))

# max 到達 → 終了 + 最終指示
if [ "$NEXT_ITERATION" -ge "$MAX" ]; then
  jq --argjson i "$NEXT_ITERATION" '.iteration = $i' "$STATE_FILE" > "$STATE_FILE.tmp.$$" \
    && mv "$STATE_FILE.tmp.$$" "$STATE_FILE" 2>/dev/null
  finalize "max_iterations"
  emit_final_block "max_iterations (上限 $MAX 回)"
  exit 0
fi

# --- 進捗ゼロ検知 ---
# 2 回連続で総合点が上がらなければ堂々巡りの兆候。止めて人間に相談する。
PREV_SCORE=$(jq -r '.prev_score // "null"' "$STATE_FILE" 2>/dev/null) || PREV_SCORE="null"
NP_COUNT=$(jq -r '.no_progress_count // 0' "$STATE_FILE" 2>/dev/null) || NP_COUNT="0"
[[ "$NP_COUNT" =~ ^[0-9]+$ ]] || NP_COUNT="0"
if [[ "$PREV_SCORE" =~ ^-?[0-9]+$ ]] && [ "$SCORE" -le "$PREV_SCORE" ] 2>/dev/null; then
  NP_COUNT=$((NP_COUNT + 1))
else
  NP_COUNT=0
fi
if [ "$NP_COUNT" -ge 2 ]; then
  finalize "no_progress"
  emit_final_block "no_progress (2回連続でスコアが上がらない — task か基準の見直しをユーザーに相談)"
  exit 0
fi

# iteration 更新 + リセット (次サイクルの plan 開始に備える。実評価が回ったので mech streak もリセット)
jq --argjson i "$NEXT_ITERATION" --argjson prev "$SCORE" --argjson np "$NP_COUNT" \
  '.iteration = $i | .phase = "plan" | .latest_score = null | .evaluated_iteration = null | .eval_repair_attempts = 0 | .prev_score = $prev | .no_progress_count = $np | .mech_ng = false | .mech_ng_count = 0' \
  "$STATE_FILE" > "$STATE_FILE.tmp.$$" \
  && mv "$STATE_FILE.tmp.$$" "$STATE_FILE" 2>/dev/null

# 前回レビューのフィードバック
PREV_EVAL=""
if [ -f "$EVAL_FILE" ]; then
  PREV_EVAL=$(jq -r '.feedback // "no feedback"' "$EVAL_FILE" 2>/dev/null) || PREV_EVAL=""
fi

NNN_NEXT=$(printf '%03d' "$NEXT_ITERATION")
REASON="[$LOOP_LABEL $NEXT_ITERATION/$MAX | current score: ${SCORE:-none} out of 100 (passing threshold: $THRESHOLD, NOT the max)]
STATE_FILE=$STATE_FILE
TURNS_DIR=$TURNS_DIR
Continue the plan -> generator -> evaluator loop. Task: $TASK"

if [ -n "$PREV_EVAL" ]; then
  REASON="$REASON
Previous eval feedback: $PREV_EVAL"
fi

REASON="$REASON
Next actions (do all in ONE response, then end it):
1. Write the next plan to $TURNS_DIR/turn-$NNN_NEXT-plan.md (reflect the feedback above).
2. Launch the generator skill with a fresh context JSON.
3. Run the mechanical check (3c-0) if rules exist; if NG, write the mech eval + state flags and end your response.
4. Launch the evaluator skill with a fresh context JSON.
5. Validate the eval JSON (validate-eval.sh), write the score back to STATE_FILE (latest_score + evaluated_iteration, phase=\"eval\"), update best_score/best_iteration, then end your response with a 1-2 line summary."

jq -n --arg reason "$REASON" '{"decision":"block","reason":$reason}' 2>/dev/null || exit 0
