#!/usr/bin/env node
/*
 * Cross-platform control plane for yt-quality-loop.
 *
 * The existing *.sh scripts remain the macOS/Linux/WSL compatibility path.
 * This file mirrors their state/eval/artifact contract without jq, bash, or
 * Unix-only utilities so Windows native hosts can run the loop hooks.
 */

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { spawnSync } = require("child_process");

const SCRIPT_DIR = __dirname;

function unixNow() {
  return Math.floor(Date.now() / 1000);
}

function pad3(value) {
  return String(Number(value) || 0).padStart(3, "0");
}

function isIntString(value) {
  return /^-?[0-9]+$/.test(String(value));
}

function isUintString(value) {
  return /^[0-9]+$/.test(String(value));
}

function isPosIntString(value) {
  return /^[1-9][0-9]*$/.test(String(value));
}

function charLen(value) {
  return Array.from(String(value)).length;
}

function readText(file, fallback = "") {
  try {
    return fs.readFileSync(file, "utf8");
  } catch {
    return fallback;
  }
}

function writeText(file, text) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, text, "utf8");
}

function readJson(file, fallback = null) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return fallback;
  }
}

function writeJsonAtomic(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.tmp.${process.pid}.${Date.now()}`;
  fs.writeFileSync(tmp, `${JSON.stringify(data, null, 2)}\n`, "utf8");
  fs.renameSync(tmp, file);
}

function fileExists(file) {
  try {
    return fs.statSync(file).isFile();
  } catch {
    return false;
  }
}

function dirExists(file) {
  try {
    return fs.statSync(file).isDirectory();
  } catch {
    return false;
  }
}

function sha256Buffer(buffer) {
  return crypto.createHash("sha256").update(buffer).digest("hex");
}

function sha256File(file) {
  return sha256Buffer(fs.readFileSync(file));
}

function sha256Parts(parts) {
  const h = crypto.createHash("sha256");
  for (const part of parts) {
    h.update(part);
  }
  return h.digest("hex");
}

function moveTurnFilesToArchive(turnsDir, sessionDir) {
  if (!dirExists(turnsDir)) return;
  const names = fs.readdirSync(turnsDir).filter((name) => name.startsWith("turn-"));
  if (names.length === 0) return;
  const d = new Date();
  const stamp = [
    d.getFullYear(),
    String(d.getMonth() + 1).padStart(2, "0"),
    String(d.getDate()).padStart(2, "0"),
    "-",
    String(d.getHours()).padStart(2, "0"),
    String(d.getMinutes()).padStart(2, "0"),
    String(d.getSeconds()).padStart(2, "0"),
  ].join("");
  const archiveDir = path.join(sessionDir, `archive-${stamp}`);
  fs.mkdirSync(archiveDir, { recursive: true });
  for (const name of names) {
    try {
      fs.renameSync(path.join(turnsDir, name), path.join(archiveDir, name));
    } catch {
      // Best-effort archive. Old leftovers should never break loop start.
    }
  }
}

function sanitizeSessionId(sessionId) {
  return !!sessionId && !/[\\/]/.test(sessionId) && !String(sessionId).includes("..");
}

function getSchemaFile(evaluatorSkill) {
  if (!evaluatorSkill || evaluatorSkill === "null") return "-";
  const candidate = path.join(SCRIPT_DIR, "..", "skills", evaluatorSkill, "eval-schema.json");
  return fileExists(candidate) ? candidate : "-";
}

function splitCriteria(criteria) {
  return String(criteria || "")
    .split(",")
    .map((x) => x.trim())
    .filter(Boolean);
}

function inLines(lines, value) {
  return lines.includes(value);
}

function validateEvalData(evalFile, schemaFile = "-", threshold = 90, criteria = "") {
  const errors = [];
  if (!fileExists(evalFile)) {
    return [`eval file not found: ${evalFile}`];
  }

  const ev = readJson(evalFile, null);
  if (!ev || typeof ev !== "object" || Array.isArray(ev)) {
    return [`eval file is not valid JSON: ${evalFile}`];
  }

  if (!isUintString(threshold)) {
    errors.push(`threshold is not an integer: ${threshold}`);
  }

  const score = ev.score;
  if (!Number.isInteger(score) || score < 0 || score > 100) {
    errors.push(`score must be an integer 0-100, got: '${score === undefined ? "" : score}'`);
  }

  const overall = ev.quality && ev.quality.overall;
  if (overall !== score) {
    errors.push(`quality.overall (${overall === undefined ? "missing" : overall}) must equal score (${score})`);
  }

  if (typeof ev.feedback !== "string" || charLen(ev.feedback) < 60) {
    errors.push("feedback must be a string of >= 60 chars (どこを・なぜ・どう直すか)");
  }

  if (Number.isInteger(score) && Object.prototype.hasOwnProperty.call(ev, "passed")) {
    const expected = score >= Number(threshold);
    if (ev.passed !== expected) {
      errors.push(`passed (${String(ev.passed)}) must be ${String(expected)} (score ${score} vs threshold ${threshold})`);
    }
  }

  let schema = null;
  if (schemaFile !== "-" && fileExists(schemaFile)) {
    schema = readJson(schemaFile, null);
  }

  let requiredKeys = [];
  if (schema && Array.isArray(schema.breakdown_keys)) {
    requiredKeys = schema.breakdown_keys.map((x) => x && x.key).filter(Boolean);
  }
  if (requiredKeys.length === 0 && criteria) {
    requiredKeys = splitCriteria(criteria);
  }

  const breakdown = ev.quality && ev.quality.breakdown && typeof ev.quality.breakdown === "object"
    ? ev.quality.breakdown
    : {};
  if (requiredKeys.length > 0) {
    const actualKeys = Object.keys(breakdown);
    for (const k of requiredKeys) {
      if (!inLines(actualKeys, k)) errors.push(`breakdown is missing required key: '${k}'`);
    }
    for (const k of actualKeys) {
      if (!inLines(requiredKeys, k)) {
        errors.push(`breakdown has an extra key not in the contract: '${k}' (new findings go to feedback, not breakdown)`);
      }
    }
    for (const [k, v] of Object.entries(breakdown)) {
      if (typeof v !== "number" || v < 0 || v > 100) {
        errors.push(`breakdown value for '${k}' must be a number 0-100`);
      }
    }
  }

  if (schema) {
    if (schema.skill && ev.evaluator_skill !== schema.skill) {
      errors.push(`evaluator_skill ('${ev.evaluator_skill || ""}') must be '${schema.skill}'`);
    }

    const keys = Array.isArray(schema.breakdown_keys) ? schema.breakdown_keys : [];
    if (keys.length > 0 && keys.every((k) => Object.prototype.hasOwnProperty.call(k, "weight"))) {
      const totalWeight = keys.reduce((sum, k) => sum + Number(k.weight || 0), 0);
      if (totalWeight > 0) {
        const weighted = keys.reduce((sum, k) => sum + Number(k.weight || 0) * Number(breakdown[k.key] || 0), 0) / totalWeight;
        if (typeof overall === "number" && overall > weighted + 5) {
          errors.push(`overall exceeds weighted average + 5 (NG overall=${overall} weighted_avg=${Math.floor(weighted)}) — 総合判断は致命傷を薄める方向 (上振れ) には使えない`);
        }
      }
    }
  }

  return errors;
}

function countChars(file, mode = "raw") {
  if (!fileExists(file)) return 0;
  let text = readText(file);
  if (mode === "spoken") {
    text = text.replace(/<!--[\s\S]*?-->/g, "");
    const lines = [];
    let inFence = false;
    for (const line of text.split(/\r?\n/)) {
      const s = line.trim();
      if (s.startsWith("```")) {
        inFence = !inFence;
        continue;
      }
      if (inFence || s.startsWith("#")) continue;
      lines.push(line);
    }
    text = lines.join("\n");
    text = text.replace(/【[^】]*】/g, "");
    text = text.replace(/\s/g, "");
  }
  return charLen(text);
}

function countOccurrences(text, word) {
  if (!word) return 0;
  let count = 0;
  let pos = 0;
  while (true) {
    const found = text.indexOf(word, pos);
    if (found === -1) break;
    count += 1;
    pos = found + word.length;
  }
  return count;
}

function endingStreakMessage(text, limit) {
  const sentences = text.split(/[。！？!?\n]/).map((s) => s.trim()).filter(Boolean);
  const endings = sentences.map((s) => Array.from(s).slice(-2).join("")).filter((s) => s.length > 0);
  let streak = 1;
  let prev = null;
  let worst = 1;
  let at = "";
  for (const ending of endings) {
    if (ending === prev) {
      streak += 1;
      if (streak > worst) {
        worst = streak;
        at = ending;
      }
    } else {
      streak = 1;
    }
    prev = ending;
  }
  if (worst > limit) return { ok: false, message: `NG: 同じ文末「${at}」が ${worst} 連続 (許容 ${limit})` };
  return { ok: true, message: `INFO: 文末連続 最大 ${worst} (許容 ${limit})` };
}

function checkMechanicalData(artifact, rulesFile) {
  const lines = [];
  if (!fileExists(artifact)) {
    return { ok: false, output: `NG: artifact not found: ${artifact}\n` };
  }
  if (!fileExists(rulesFile)) {
    return { ok: true, output: `SKIP: rules file not found (${rulesFile}) — A層チェックなし\n` };
  }
  const rules = readJson(rulesFile, null);
  if (!rules || typeof rules !== "object" || Array.isArray(rules)) {
    return { ok: false, output: `NG: rules file is not valid JSON: ${rulesFile}\n` };
  }

  let fail = false;
  const countMode = rules.count_mode === "spoken" ? "spoken" : "raw";
  const chars = countChars(artifact, countMode);
  const min = Number(rules.min_chars || 0);
  const max = Number(rules.max_chars || 0);
  if (Number.isInteger(min) && min > 0 && chars < min) {
    lines.push(`NG: 文字数 ${chars} 字 < 下限 ${min} 字`);
    fail = true;
  }
  if (Number.isInteger(max) && max > 0 && chars > max) {
    lines.push(`NG: 文字数 ${chars} 字 > 上限 ${max} 字`);
    fail = true;
  }
  lines.push(`INFO: 文字数実測 ${chars} 字 (mode: ${countMode})`);

  const text = readText(artifact);
  if (Array.isArray(rules.forbidden_words)) {
    for (const word of rules.forbidden_words) {
      const hits = countOccurrences(text, String(word));
      if (hits > 0) {
        lines.push(`NG: 禁止ワード「${word}」が ${hits} 回出現`);
        fail = true;
      }
    }
  }

  const streak = Number(rules.max_ending_streak || 0);
  if (Number.isInteger(streak) && streak > 0) {
    const result = endingStreakMessage(text, streak);
    lines.push(result.message);
    if (!result.ok) fail = true;
  }

  if (fail) {
    lines.push("RESULT: A層 NG — 即差し戻し (B層採点は行わない)");
  } else {
    lines.push("RESULT: A層 OK");
  }
  return { ok: !fail, output: `${lines.join("\n")}\n` };
}

function fingerprintValue(stateFile) {
  if (!fileExists(stateFile)) throw new Error(`state not found: ${stateFile}`);
  const state = readJson(stateFile, {});
  const projectDir = state.project_dir || ".";
  const brief = state.brief_file || "";
  const anchors = state.anchors_file || "";
  const evaluatorSkill = state.evaluator_skill || "";
  const parts = [];
  parts.push(JSON.stringify([
    state.threshold,
    state.criteria,
    state.generator_skill,
    state.evaluator_skill,
    state.evaluator_runtime || "skill",
    state.judges || "host",
    state.host_vendor || "other",
    state.judge_models || {},
    state.max_iterations,
    state.brief_file,
    state.anchors_file,
  ]));
  parts.push(readText(path.join(projectDir, ".yt-loop", "channel-profile.md")));
  parts.push(readText(path.join(projectDir, ".yt-loop", "mechanical-checks.json")));
  if (brief && brief !== "null") parts.push(readText(brief));
  if (anchors && anchors !== "null") parts.push(readText(anchors));
  if (evaluatorSkill && evaluatorSkill !== "null") {
    parts.push(readText(path.join(SCRIPT_DIR, "..", "skills", evaluatorSkill, "SKILL.md")));
    parts.push(readText(path.join(SCRIPT_DIR, "..", "skills", evaluatorSkill, "eval-schema.json")));
  }
  return sha256Parts(parts);
}

function block(reason) {
  process.stdout.write(`${JSON.stringify({ decision: "block", reason })}\n`);
}

function finalize(stateFile, reason) {
  const state = readJson(stateFile, {});
  state.active = false;
  state.ended_reason = reason;
  writeJsonAtomic(stateFile, state);
}

function makeFinalBlock(stateFile, loopLabel, label) {
  const state = readJson(stateFile, {});
  const turnsDir = state.turns_dir || "";
  const bestIter = state.best_iteration;
  const bestScore = state.best_score;
  let bestLine;
  if (Number.isInteger(bestIter)) {
    bestLine = `Best: iteration ${bestIter} (score ${bestScore}) -> ${path.join(turnsDir, `turn-${pad3(bestIter)}-output.md`)}`;
  } else {
    bestLine = `Best: none (合格評価が一度も無かったため納品できるベスト版はない。${turnsDir} のログをユーザーに案内する)`;
  }
  const reportCmd = `node "${path.join(SCRIPT_DIR, "yt-loop.js")}" final-report "${stateFile}"`;
  return `[${loopLabel} ENDED: ${label}]
STATE_FILE=${stateFile}
${bestLine}
Final step — do ALL of this now in one response, then end it:
1. Run this command and use its output as the source of truth for delivery and reporting:
   ${reportCmd}
2. Report in Japanese: 成果物パス、最終/ベストスコアと quality.breakdown、スコア推移、終了理由 (${label})、最後の feedback に残った改善余地。
3. Add these two notes if the report did not already include them: 「納品物を手直ししたら /yt-profile 更新 で次回に反映できます」「スコアは同一成果物でも±数点ブレます (90点=伸びる保証ではありません)」
Do NOT restart the loop.`;
}

function emitFinalBlock(stateFile, loopLabel, label) {
  block(makeFinalBlock(stateFile, loopLabel, label));
}

function loopControl(stateFile, loopLabel = "YT-loop iteration") {
  if (!fileExists(stateFile)) return;
  let state = readJson(stateFile, {});
  if (state.active !== true) return;

  let iteration = isUintString(state.iteration) ? Number(state.iteration) : 0;
  let max = isUintString(state.max_iterations) ? Number(state.max_iterations) : 6;
  let threshold = isUintString(state.threshold) ? Number(state.threshold) : 90;
  let score = Number.isInteger(state.latest_score) ? state.latest_score : null;
  const task = state.task || "task not set";
  const phase = state.phase || "plan";
  const evalIter = state.evaluated_iteration === null || state.evaluated_iteration === undefined ? null : state.evaluated_iteration;
  const startedAt = isUintString(state.started_at) ? Number(state.started_at) : null;
  const maxWall = isUintString(state.max_wall_minutes) ? Number(state.max_wall_minutes) : 0;
  let repair = isUintString(state.eval_repair_attempts) ? Number(state.eval_repair_attempts) : 0;
  let mechCount = isUintString(state.mech_ng_count) ? Number(state.mech_ng_count) : 0;
  const mechNg = state.mech_ng === true;
  const turnsDir = state.turns_dir || "";
  const criteria = state.criteria || "";
  const evalSkill = state.evaluator_skill || "";
  const projectDir = state.project_dir || "";
  const now = unixNow();

  if ((!task || task === "task not set") && iteration === 0 && score === null) {
    if (startedAt && now - startedAt < 600) return;
    finalize(stateFile, "never_started");
    return;
  }

  if (startedAt && maxWall > 0 && now - startedAt >= maxWall * 60) {
    const passClaim = phase === "eval" && score !== null && score >= threshold && !mechNg
      && (evalIter === null || evalIter === iteration);
    if (!passClaim) {
      finalize(stateFile, "wall_clock_exceeded");
      emitFinalBlock(stateFile, loopLabel, `wall_clock_exceeded (時間上限 ${maxWall} 分)`);
      return;
    }
  }

  if (phase !== "eval") return;

  if (score === null && !mechNg) {
    if (repair >= 2) {
      finalize(stateFile, "invalid_eval_output");
      emitFinalBlock(stateFile, loopLabel, "invalid_eval_output (評価出力の修復に2回失敗)");
      return;
    }
    state.eval_repair_attempts = repair + 1;
    writeJsonAtomic(stateFile, state);
    const hint = path.join(turnsDir, `turn-${pad3(iteration)}-eval.json`);
    block(`[${loopLabel} ${iteration}/${max} | INVALID EVAL OUTPUT]
STATE_FILE=${stateFile}
The evaluation phase finished but latest_score is not a valid integer.
Repair now: re-run the evaluator skill as a fresh fork so it writes a genuine ${hint}. Do NOT edit the eval JSON or write the score yourself — only the evaluator writes it. Then write the evaluator's score back to latest_score in STATE_FILE (keep phase="eval") and end your response.`);
    return;
  }

  if (evalIter !== null && evalIter !== iteration) return;

  const nnn = pad3(iteration);
  const evalFile = path.join(turnsDir, `turn-${nnn}-eval.json`);
  const artifactFile = path.join(turnsDir, `turn-${nnn}-output.md`);

  if (!mechNg && iteration > 0 && fileExists(evalFile)) {
    const prevEvalFile = path.join(turnsDir, `turn-${pad3(iteration - 1)}-eval.json`);
    if (fileExists(prevEvalFile)) {
      const cur = readJson(evalFile, {});
      const prev = readJson(prevEvalFile, {});
      const curFb = cur.feedback || "";
      const prevFb = prev.feedback || "";
      if (curFb && curFb === prevFb && prev.mechanical !== true) {
        if (repair >= 2) {
          finalize(stateFile, "invalid_eval_output");
          emitFinalBlock(stateFile, loopLabel, "invalid_eval_output (feedback が前回と完全一致 — 採点のコピペ)");
          return;
        }
        state.eval_repair_attempts = repair + 1;
        writeJsonAtomic(stateFile, state);
        block(`[${loopLabel} ${iteration}/${max} | EVAL REJECTED: feedback is identical to the previous iteration (copy-paste)]
STATE_FILE=${stateFile}
Re-run the evaluator as a fresh fork so it actually reads and evaluates ${artifactFile}. Do NOT edit the eval JSON by hand. Then write the evaluator's score back and end your response.`);
        return;
      }
    }
  }

  if (mechNg) {
    mechCount += 1;
    if (mechCount >= 3) {
      finalize(stateFile, "mechanical_check_failed");
      emitFinalBlock(stateFile, loopLabel, "mechanical_check_failed (機械チェックNGが3回連続 — task か mechanical-checks.json の見直しが必要)");
      return;
    }
    const next = iteration + 1;
    if (next >= max) {
      state.iteration = next;
      writeJsonAtomic(stateFile, state);
      finalize(stateFile, "max_iterations");
      emitFinalBlock(stateFile, loopLabel, `max_iterations (上限 ${max} 回)`);
      return;
    }
    const ev = fileExists(evalFile) ? readJson(evalFile, {}) : {};
    state.iteration = next;
    state.phase = "plan";
    state.latest_score = null;
    state.evaluated_iteration = null;
    state.eval_repair_attempts = 0;
    state.mech_ng = false;
    state.mech_ng_count = mechCount;
    writeJsonAtomic(stateFile, state);
    block(`[${loopLabel} ${next}/${max} | MECHANICAL CHECK FAILED (streak ${mechCount}/3)]
STATE_FILE=${stateFile}
TURNS_DIR=${turnsDir}
Task: ${task}
Mechanical violations (must fix — これはスクリプト判定なので言い訳は通らない):
${ev.feedback || ""}
Next actions (do all in ONE response, then end it):
1. Write the next plan to ${path.join(turnsDir, `turn-${pad3(next)}-plan.md`)} (fix ONLY the mechanical violations first).
2. Launch the generator skill, then run the mechanical check again (3c-0).
3. If mechanical check passes, launch the evaluator; validate and write the score back; end your response.`);
    return;
  }

  if (score !== null && score >= threshold) {
    let verifyFail = "";
    let evalScore = null;
    if (!fileExists(evalFile)) {
      verifyFail = `eval JSON not found: ${evalFile}`;
    }
    if (!verifyFail) {
      const ev = readJson(evalFile, {});
      evalScore = ev.score;
      if (!Number.isInteger(evalScore) || evalScore < threshold) {
        verifyFail = `eval JSON score ('${evalScore === undefined ? "null" : evalScore}') does not support the pass claim (state says ${score})`;
      }
    }
    if (!verifyFail) {
      const errors = validateEvalData(evalFile, getSchemaFile(evalSkill), threshold, criteria);
      if (errors.length > 0) verifyFail = "eval JSON failed contract validation (validate-eval)";
    }
    if (!verifyFail) {
      const rules = path.join(projectDir, ".yt-loop", "mechanical-checks.json");
      if (fileExists(rules)) {
        const result = checkMechanicalData(artifactFile, rules);
        if (!result.ok) verifyFail = "mechanical check failed on the passing artifact";
      }
    }
    if (!verifyFail) {
      const stored = state.artifact_hashes && state.artifact_hashes[nnn];
      if (stored && fileExists(artifactFile)) {
        const cur = sha256File(artifactFile);
        if (cur && cur !== stored) verifyFail = "artifact was modified after evaluation (採点後に成果物が変更されている)";
      }
    }
    if (!verifyFail) {
      const fp = state.config_fingerprint;
      if (!fp || fp === "null") {
        verifyFail = "config fingerprint not recorded (Step 2 の fingerprint --record が未実行)";
      } else {
        const curFp = fingerprintValue(stateFile);
        if (curFp && curFp !== fp) {
          verifyFail = "scoring config (threshold/criteria/profile/mechanical rules/brief/anchors/evaluator定義) changed mid-loop — ものさしの途中変更は合格にできない";
        }
      }
    }
    if (!verifyFail) {
      const recAt = Number(state.fingerprint_recorded_at || 0);
      const firstOut = path.join(turnsDir, "turn-000-output.md");
      if (recAt > 0 && fileExists(firstOut)) {
        const mtime = Math.floor(fs.statSync(firstOut).mtimeMs / 1000);
        if (mtime < recAt) verifyFail = "config fingerprint was recorded AFTER generation started — ものさしは最初の生成の前に固定する";
      }
    }
    if (!verifyFail) {
      const runtime = state.runtime || "";
      const anchors = state.anchors_file || "";
      if ((evalSkill === "assign-yt-evaluator" || runtime === "codex-hook") && (!anchors || anchors === "null")) {
        verifyFail = "anchors_file is not set — 自由 criteria は採点アンカー (90/75の目盛り) を起草・固定してから回す";
      }
    }
    // 確認採点。judges に外部ジャッジ (claude/codex/grok) があれば確認採点の席は外部ベンダーが担う:
    //   有効な外部採点 1 つ → min 規則の席替え / 2 つ以上 → 下側中央値 (2/3 合意)。採用は min(本採点, 集計)。
    //   外部が全滅した時だけ host フォーク確認に降格 (開示付き。fail-open しない)。
    let finalScore = evalScore;
    let judgeNote = "";
    const judgesConf = String(state.judges || "host");
    const extList = ["claude", "codex", "grok"].filter((j) => (`,${judgesConf},`).includes(`,${j},`));
    const extScores = [];
    const extFailed = [];
    if (!verifyFail && extList.length > 0) {
      for (const j of extList) {
        const cj = path.join(turnsDir, `turn-${nnn}-eval-confirm-${j}.json`);
        const mj = path.join(turnsDir, `turn-${nnn}-eval-confirm-${j}.fresh`);
        const fj = path.join(turnsDir, `turn-${nnn}-eval-confirm-${j}.failed`);
        if (fileExists(cj)) {
          if (!fileExists(mj) || readText(mj).trim() !== sha256File(cj)) {
            extFailed.push(`${j}:整合マーカーなし`);
          } else if (sha256File(evalFile) === sha256File(cj)) {
            extFailed.push(`${j}:本採点のコピー`);
          } else if (validateEvalData(cj, getSchemaFile(evalSkill), threshold, criteria).length > 0) {
            extFailed.push(`${j}:契約違反`);
          } else {
            const jsc = readJson(cj, {}).score;
            if (Number.isInteger(jsc)) extScores.push(jsc);
            else extFailed.push(`${j}:score不正`);
          }
        } else if (fileExists(fj)) {
          extFailed.push(`${j}:${readText(fj).replace(/\n/g, " ").slice(0, 60)}`);
        } else {
          verifyFail = `external confirmation for judge '${j}' not found — 合格主張の前に confirm-judges.js を実行する (fail-open はしない)`;
          break;
        }
      }
    }
    if (!verifyFail && extList.length > 0 && extScores.length > 0) {
      const sorted = [...extScores, evalScore].sort((a, b) => a - b);
      const cnt = sorted.length;
      const jmin = sorted[0];
      let agg;
      let jrule;
      if (cnt >= 3) {
        agg = sorted[Math.floor((cnt - 1) / 2)]; // 下側中央値
        jrule = "median";
      } else {
        agg = jmin;
        jrule = "min";
      }
      if (agg < threshold) {
        verifyFail = `external confirmation (${jrule}=${agg} / eval=${evalScore} ext=${extScores.join(" ")}) is below threshold — 低い方を採用してループを続行する (合格主張しない)`;
      } else {
        if (agg < finalScore) finalScore = agg;
        judgeNote = ` / JUDGES: ${extList.join(" ")} (rule=${jrule}, eval=${evalScore}, ext=${extScores.join(" ")}, min=${jmin})`;
        if (extFailed.length > 0) judgeNote += ` / JUDGE FAILED: ${extFailed.join(" ")} (最終報告で開示)`;
        state.judge_confirm = { judges: extList.join(" "), ext_scores: extScores.join(" "), rule: jrule, adopted: finalScore, failed: extFailed.join(" ") };
      }
    } else if (!verifyFail) {
      if (extList.length > 0) {
        judgeNote = ` / JUDGES DEGRADED: 外部確認採点が全滅 (${extFailed.join(" ")}) — host フォーク確認に降格 (最終報告で必ず開示)`;
        state.judge_confirm = { judges: extList.join(" "), ext_scores: "", rule: "host-degraded", failed: extFailed.join(" ") };
      }
      const confirmFile = path.join(turnsDir, `turn-${nnn}-eval-confirm.json`);
      if (!fileExists(confirmFile)) {
        verifyFail = `confirmation eval not found (${confirmFile}) — 合格主張には確認採点 (3d-2) が必要`;
      } else if (sha256File(evalFile) === sha256File(confirmFile)) {
        verifyFail = "confirmation eval is byte-identical to the primary eval — コピーは確認採点ではない";
      } else {
        const errors = validateEvalData(confirmFile, getSchemaFile(evalSkill), threshold, criteria);
        if (errors.length > 0) {
          verifyFail = "confirmation eval failed contract validation";
        } else {
          const cscore = readJson(confirmFile, {}).score;
          if (!Number.isInteger(cscore)) verifyFail = "confirmation eval score is not an integer";
          else if (cscore < threshold) verifyFail = `confirmation score (${cscore}) is below threshold — 低い方を採用してループを続行する (合格主張しない)`;
          else if (cscore < finalScore) finalScore = cscore;
        }
      }
    }
    if (!verifyFail) {
      let selfNote = "";
      if ((state.runtime || "") === "codex-hook") {
        const marker = path.join(turnsDir, `turn-${nnn}-eval.fresh`);
        const ok = fileExists(marker) && readText(marker).trim() === sha256File(evalFile);
        if (!ok) {
          selfNote = " / SELF-SCORED (fresh 証明なし — 最終報告で必ず開示)";
          state.self_scored = Array.isArray(state.self_scored) ? state.self_scored : [];
          state.self_scored.push(iteration);
        }
      }
      state.latest_score = finalScore;
      if (state.best_score === null || state.best_score === undefined || finalScore > state.best_score) {
        state.best_score = finalScore;
        state.best_iteration = iteration;
      }
      writeJsonAtomic(stateFile, state);
      finalize(stateFile, "threshold_met");
      emitFinalBlock(stateFile, loopLabel, `threshold_met (合格 — 検証済み: eval 直読 / 契約 / 機械チェック / hash / 指紋 / 確認採点)${selfNote}${judgeNote}`);
      return;
    }
    if (repair >= 2) {
      finalize(stateFile, "pass_verification_failed");
      emitFinalBlock(stateFile, loopLabel, `pass_verification_failed (${verifyFail})`);
      return;
    }
    state.eval_repair_attempts = repair + 1;
    writeJsonAtomic(stateFile, state);
    block(`[${loopLabel} ${iteration}/${max} | PASS CLAIM REJECTED]
STATE_FILE=${stateFile}
Reason: ${verifyFail}
Re-run the evaluator skill as a fresh fork so it writes a genuine eval JSON to ${evalFile}. Do NOT edit the eval JSON, the criteria/profile, or the state score by hand. Then write the evaluator's score to latest_score (keep phase="eval") and end your response.`);
    return;
  }

  const next = iteration + 1;
  if (next >= max) {
    state.iteration = next;
    writeJsonAtomic(stateFile, state);
    finalize(stateFile, "max_iterations");
    emitFinalBlock(stateFile, loopLabel, `max_iterations (上限 ${max} 回)`);
    return;
  }

  let prevScore = Number.isInteger(state.prev_score) ? state.prev_score : null;
  let npCount = isUintString(state.no_progress_count) ? Number(state.no_progress_count) : 0;
  if (prevScore !== null && score !== null && score <= prevScore) npCount += 1;
  else npCount = 0;
  if (npCount >= 2) {
    finalize(stateFile, "no_progress");
    emitFinalBlock(stateFile, loopLabel, "no_progress (2回連続でスコアが上がらない — task か基準の見直しをユーザーに相談)");
    return;
  }

  state.iteration = next;
  state.phase = "plan";
  state.latest_score = null;
  state.evaluated_iteration = null;
  state.eval_repair_attempts = 0;
  state.prev_score = score;
  state.no_progress_count = npCount;
  state.mech_ng = false;
  state.mech_ng_count = 0;
  writeJsonAtomic(stateFile, state);

  const prevEval = fileExists(evalFile) ? (readJson(evalFile, {}).feedback || "") : "";
  let reason = `[${loopLabel} ${next}/${max} | current score: ${score === null ? "none" : score} out of 100 (passing threshold: ${threshold}, NOT the max)]
STATE_FILE=${stateFile}
TURNS_DIR=${turnsDir}
Continue the plan -> generator -> evaluator loop. Task: ${task}`;
  if (prevEval) reason += `\nPrevious eval feedback: ${prevEval}`;
  reason += `
Next actions (do all in ONE response, then end it):
1. Write the next plan to ${path.join(turnsDir, `turn-${pad3(next)}-plan.md`)} (reflect the feedback above).
2. Launch the generator skill with a fresh context JSON.
3. Run the mechanical check (3c-0) if rules exist; if NG, write the mech eval + state flags and end your response.
4. Launch the evaluator skill with a fresh context JSON.
5. Validate the eval JSON (validate-eval), write the score back to STATE_FILE (latest_score + evaluated_iteration, phase="eval"), update best_score/best_iteration, then end your response with a 1-2 line summary.`;
  block(reason);
}

function loopStart(args) {
  const cwd = args[0] || ".";
  const max = args[1] || "6";
  const threshold = args[2] || "90";
  const sessionId = args[3];
  if (!sessionId) throw new Error("session_id is required");
  let maxWall = "120";
  for (let i = 4; i < args.length; i++) {
    if (args[i] === "--max-wall-minutes") {
      maxWall = args[i + 1];
      i += 1;
    } else if (String(args[i]).startsWith("--")) {
      throw new Error(`unknown option: '${args[i]}'`);
    }
  }
  if (!isPosIntString(max)) throw new Error(`max_iterations must be a positive integer, got: '${max}'`);
  if (!isUintString(threshold) || Number(threshold) > 100) throw new Error(`threshold must be an integer 0-100, got: '${threshold}'`);
  if (!sanitizeSessionId(sessionId)) throw new Error(`session_id must not contain path separators or '..': '${sessionId}'`);
  if (!/^(0|[1-9][0-9]*)$/.test(String(maxWall))) throw new Error(`--max-wall-minutes must be a non-negative integer (0 = disabled), got: '${maxWall}'`);
  if (!dirExists(cwd)) throw new Error(`Working directory does not exist: ${cwd}`);

  const projectDir = fs.realpathSync(cwd);
  const sessionDir = path.join(projectDir, ".yt-loop", "sessions", sessionId);
  const turnsDir = path.join(sessionDir, "turns");
  const stateFile = path.join(sessionDir, "state.json");
  const existing = readJson(stateFile, null);
  if (existing && existing.active === true) {
    console.log(`YT loop already active (iteration ${existing.iteration}/${existing.max_iterations}). Cancel first with /yt-loop-cancel`);
    return;
  }
  moveTurnFilesToArchive(turnsDir, sessionDir);
  fs.mkdirSync(turnsDir, { recursive: true });
  writeJsonAtomic(stateFile, {
    loop_type: "yt-quality",
    active: true,
    iteration: 0,
    max_iterations: Number(max),
    threshold: Number(threshold),
    started_at: unixNow(),
    max_wall_minutes: Number(maxWall),
    ended_reason: null,
    session_id: sessionId,
    project_dir: projectDir,
    task: "",
    criteria: "",
    generator_skill: "assign-yt-generator",
    evaluator_skill: "assign-yt-evaluator",
    evaluator_runtime: "skill",
    judges: "host",
    judges_detected: "",
    host_vendor: "other",
    judge_models: {},
    latest_score: null,
    evaluated_iteration: null,
    eval_repair_attempts: 0,
    best_score: null,
    best_iteration: null,
    prev_score: null,
    no_progress_count: 0,
    mech_ng: false,
    mech_ng_count: 0,
    config_fingerprint: null,
    anchors_file: null,
    turns_dir: turnsDir,
    phase: "plan",
    latest_plan: null,
  });
  console.log(`YT loop ACTIVATED (max: ${max}, threshold: ${threshold}, wall: ${maxWall}min, session: ${sessionId})`);
  console.log(`Turns dir: ${turnsDir}`);
  console.log(`State file: ${stateFile}`);
}

function readStdin() {
  try {
    return fs.readFileSync(0, "utf8");
  } catch {
    return "";
  }
}

function hookStop() {
  try {
    const input = JSON.parse(readStdin() || "{}");
    const cwd = input.cwd || ".";
    const sessionId = input.session_id || "";
    if (!sanitizeSessionId(sessionId)) return;
    const stateFile = path.join(cwd, ".yt-loop", "sessions", sessionId, "state.json");
    loopControl(stateFile, "YT-loop iteration");
  } catch {
    // Hook safety: never fail the host.
  }
}

function hookPromptSubmit() {
  try {
    const input = JSON.parse(readStdin() || "{}");
    const cwd = input.cwd || ".";
    const sessionId = input.session_id || "";
    if (!sanitizeSessionId(sessionId)) return;
    const stateFile = path.join(cwd, ".yt-loop", "sessions", sessionId, "state.json");
    let msg = `YT_LOOP_SESSION_ID=${sessionId}`;
    const state = readJson(stateFile, null);
    if (state && state.active === true) {
      msg += ` | YT loop active (iteration ${state.iteration}/${state.max_iterations}, score: ${state.latest_score == null ? "none" : state.latest_score}/100, target: ${state.threshold == null ? 90 : state.threshold}).`;
      try {
        const ageMin = Math.floor((Date.now() - fs.statSync(stateFile).mtimeMs) / 60000);
        if (ageMin >= 30) {
          const cancelCmd = `node "${path.join(SCRIPT_DIR, "yt-loop.js")}" loop-cancel "${stateFile}"`;
          msg += ` | WARNING: loop appears STALLED (no update for ${ageMin}m). Resume the iteration, or cancel: ${cancelCmd}`;
        }
      } catch {
        // Ignore stat errors.
      }
    }
    console.log(msg);
  } catch {
    // Hook safety.
  }
}

function loopCancel(args) {
  let reason = "";
  const positional = [];
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--reason") {
      reason = args[i + 1] || "";
      i += 1;
    } else {
      positional.push(args[i]);
    }
  }
  if (reason === "passed") reason = "threshold_met";
  if (reason && !["threshold_met", "max_iterations", "cancelled"].includes(reason)) {
    throw new Error(`--reason must be one of passed|threshold_met|max_iterations|cancelled, got: '${reason}'`);
  }
  let stateFile;
  if (positional.length === 1) {
    stateFile = positional[0];
  } else {
    const cwd = positional[0] || ".";
    const sessionId = positional[1];
    if (!sanitizeSessionId(sessionId)) throw new Error(`session_id must not contain path separators or '..': '${sessionId}'`);
    stateFile = path.join(cwd, ".yt-loop", "sessions", sessionId, "state.json");
  }
  if (!fileExists(stateFile)) {
    console.log(`No state file found: ${stateFile}`);
    return;
  }
  const state = readJson(stateFile, {});
  if (state.active !== true) {
    console.log("No active YT loop.");
    return;
  }
  if (reason === "threshold_met") {
    const ok = typeof state.latest_score === "number" && typeof state.threshold === "number" && state.latest_score >= state.threshold;
    if (!ok) {
      console.error("WARNING: --reason passed/threshold_met but latest_score < threshold (or non-numeric) — falling back to auto-detect");
      reason = "";
    }
  }
  state.active = false;
  if (!state.ended_reason) {
    if (reason) state.ended_reason = reason;
    else if (typeof state.latest_score === "number" && typeof state.threshold === "number" && state.latest_score >= state.threshold) state.ended_reason = "threshold_met";
    else state.ended_reason = "cancelled";
  }
  if (typeof state.evaluated_iteration === "number" && (typeof state.iteration !== "number" || state.evaluated_iteration > state.iteration)) {
    state.iteration = state.evaluated_iteration;
  }
  writeJsonAtomic(stateFile, state);
  const next = readJson(stateFile, {});
  console.log(`YT loop finalized (reason: ${next.ended_reason}).`);
  console.log(`Summary: iteration ${next.iteration}, latest_score ${next.latest_score}, best iter ${next.best_iteration} (score ${next.best_score})`);
}

function sortedFiles(dir, predicate) {
  if (!dirExists(dir)) return [];
  return fs.readdirSync(dir)
    .filter(predicate)
    .sort()
    .map((name) => path.join(dir, name));
}

function finalReport(args) {
  const stateFile = args[0];
  if (!stateFile) throw new Error("usage: final-report <state_file> [output_file]");
  let outFile = args[1] || "";
  if (!fileExists(stateFile)) throw new Error(`state not found: ${stateFile}`);
  const state = readJson(stateFile, {});
  const projectDir = state.project_dir || ".";
  const turnsDir = state.turns_dir || "";
  const bestIter = state.best_iteration;
  const bestScore = state.best_score;
  const endedReason = state.ended_reason || "unknown";
  const threshold = state.threshold == null ? 90 : state.threshold;
  const criteria = state.criteria || "";
  const evalSkill = state.evaluator_skill || "";
  const evalRuntime = state.evaluator_runtime || "skill";
  const briefFile = state.brief_file || "";
  const anchorsFile = state.anchors_file || "";
  if (!outFile) {
    const d = new Date();
    const stamp = [
      d.getFullYear(),
      String(d.getMonth() + 1).padStart(2, "0"),
      String(d.getDate()).padStart(2, "0"),
      "-",
      String(d.getHours()).padStart(2, "0"),
      String(d.getMinutes()).padStart(2, "0"),
      String(d.getSeconds()).padStart(2, "0"),
    ].join("");
    outFile = path.join(projectDir, `yt-loop-output-${stamp}.md`);
  }

  const out = [];
  out.push("# YT Quality Loop Final Report", "");
  out.push(`- State: ${stateFile}`);
  out.push(`- Ended reason: ${endedReason}`);
  out.push(`- Threshold: ${threshold}`);
  out.push(`- Evaluator: ${evalSkill} (runtime: ${evalRuntime})`);
  if (briefFile && briefFile !== "null") out.push(`- Brief: ${briefFile}`);
  if (anchorsFile && anchorsFile !== "null") out.push(`- Anchors: ${anchorsFile} (次回同じ軸なら anchors: 指定で再利用可)`);
  if (state.judges_unavailable) out.push(`- ⚠ ループ開始時に不在だった明示ジャッジ: ${state.judges_unavailable}`);

  const verifyFails = [];
  if (Number.isInteger(bestIter)) {
    const nnn = pad3(bestIter);
    const bestFile = path.join(turnsDir, `turn-${nnn}-output.md`);
    const bestEval = path.join(turnsDir, `turn-${nnn}-eval.json`);
    const stored = state.artifact_hashes && state.artifact_hashes[nnn];
    if (stored && fileExists(bestFile) && sha256File(bestFile) !== stored) {
      verifyFails.push(`best 成果物が採点後に変更されている (${bestFile})`);
    }
    const evalScore = readJson(bestEval, {}).score;
    if (!Number.isInteger(evalScore) || evalScore !== bestScore) {
      verifyFails.push(`best_score (${bestScore}) が eval JSON の実値 (${evalScore === undefined ? "null" : evalScore}) と一致しない`);
    }
    if (endedReason === "threshold_met") {
      const errors = validateEvalData(bestEval, getSchemaFile(evalSkill), threshold, criteria);
      if (errors.length > 0) verifyFails.push("best eval が契約検証に落ちる");
      // 確認採点の実在: 外部ジャッジ (judges) の有効な確認があればそれで足りる
      const judgesConf = String(state.judges || "host");
      let extConfOk = false;
      for (const j of ["claude", "codex", "grok"]) {
        if (!(`,${judgesConf},`).includes(`,${j},`)) continue;
        const cj = path.join(turnsDir, `turn-${nnn}-eval-confirm-${j}.json`);
        const mj = path.join(turnsDir, `turn-${nnn}-eval-confirm-${j}.fresh`);
        if (fileExists(cj) && fileExists(mj) && readText(mj).trim() === sha256File(cj) && sha256File(bestEval) !== sha256File(cj)) {
          extConfOk = true;
        }
      }
      if (!extConfOk) {
        const cFile = path.join(turnsDir, `turn-${nnn}-eval-confirm.json`);
        if (!fileExists(cFile)) verifyFails.push("確認採点が存在しない (合格主張には host フォーク確認か外部ジャッジ確認が必須)");
        else if (sha256File(bestEval) === sha256File(cFile)) verifyFails.push("確認採点が本採点のコピー");
      }
      const storedFp = state.config_fingerprint || "";
      const nowFp = fingerprintValue(stateFile);
      if (!storedFp || (nowFp && nowFp !== storedFp)) verifyFails.push("ものさしの指紋が不一致または未記録");
    }
  }
  if (verifyFails.length > 0) {
    out.push("", "## ⚠ VERIFY FAILED — この報告の数字は信用できない", "");
    for (const v of verifyFails) out.push(`- ${v}`);
    out.push("", "state.json の値が現物と一致しません。正規のループ外で state が書き換えられた可能性があります。turns ディレクトリの実物を直接確認してください。");
  }

  if (!Number.isInteger(bestIter)) {
    out.push("- Deliverable: none");
    const latest = sortedFiles(turnsDir, (name) => /^turn-.*-output\.md$/.test(name)).pop();
    if (latest && fs.statSync(latest).size > 0) {
      const d = new Date();
      const stamp = [
        d.getFullYear(),
        String(d.getMonth() + 1).padStart(2, "0"),
        String(d.getDate()).padStart(2, "0"),
        "-",
        String(d.getHours()).padStart(2, "0"),
        String(d.getMinutes()).padStart(2, "0"),
        String(d.getSeconds()).padStart(2, "0"),
      ].join("");
      const draftFile = path.join(projectDir, `yt-loop-draft-${stamp}.md`);
      fs.copyFileSync(latest, draftFile);
      out.push(`- Draft (未採点・品質保証なし): ${draftFile}`);
    }
    out.push("", "## 次に直すこと", "", "合格評価が一度も無かったため、品質保証つきの納品物はありません (上の Draft は未採点の生成物です)。task に「誰向け / 長さ / 入れる内容 / 完成条件」を足して再実行してください。");
    console.log(out.join("\n"));
    return;
  }

  const bestNnn = pad3(bestIter);
  const bestFile = path.join(turnsDir, `turn-${bestNnn}-output.md`);
  const bestEval = path.join(turnsDir, `turn-${bestNnn}-eval.json`);
  if (!fileExists(bestFile) || fs.statSync(bestFile).size === 0) {
    out.push(`- Deliverable: missing (${bestFile})`);
    console.log(out.join("\n"));
    process.exitCode = 1;
    return;
  }
  fs.mkdirSync(path.dirname(outFile), { recursive: true });
  fs.copyFileSync(bestFile, outFile);
  out.push(`- Deliverable: ${outFile}`);
  out.push(`- Best iteration: ${bestIter}`);
  out.push(`- Best score: ${bestScore}`, "", "## スコア推移", "");
  const scores = sortedFiles(turnsDir, (name) => /^turn-.*-eval\.json$/.test(name))
    .map((file) => readJson(file, {}).score)
    .filter((s) => Number.isInteger(s));
  out.push(scores.length > 0 ? scores.join(" -> ") : "記録なし");
  out.push("", "## 内訳", "");
  const ev = readJson(bestEval, {});
  const breakdown = ev.quality && ev.quality.breakdown ? ev.quality.breakdown : {};
  for (const [k, v] of Object.entries(breakdown)) out.push(`- ${k}: ${v}`);
  out.push("", "## 残った改善余地", "", ev.feedback || "記録なし");
  if (Array.isArray(state.self_scored) && state.self_scored.length > 0) {
    out.push("", "## 採点メモ", "", `自己採点に落ちた周回: ${state.self_scored.join(", ")}`);
    out.push("これは fresh な採点係が使えなかった時のフォールバックです。fresh 採点より甘くなる可能性があります。");
  }
  // 確認採点 (judges) の開示: 誰が合格を確認したかを必ず見せる
  const rJudges = String(state.judges || "host");
  const jc = state.judge_confirm || null;
  if (rJudges !== "host" || jc) {
    out.push("", "## 確認採点 (judges)", "");
    out.push(`- 構成: ${rJudges}`);
    const models = state.judge_models && typeof state.judge_models === "object" ? state.judge_models : {};
    for (const [provider, model] of Object.entries(models)) out.push(`- ${provider} model: ${model || "configured-unpinned"}`);
    if (Object.values(models).some((model) => model === "configured-unpinned")) {
      out.push("- ⚠ configured-unpinned はCLI既定モデルを使ったため、モデルIDを固定・検証できていません");
    }
    const jd = String(state.judges_detected || "");
    if (jd && jd !== "null") {
      for (const j of ["claude", "codex", "grok"]) {
        if ((`,${jd},`).includes(`,${j},`) && !(`,${rJudges},`).includes(`,${j},`)) {
          out.push(`- ${j}: 検出済みだが不使用 (ユーザー指定)`);
        }
      }
    }
    if (jc && jc.rule) {
      out.push(`- 判定規則: ${jc.rule} / 外部スコア: ${jc.ext_scores || "-"} / 採用スコア: ${jc.adopted === undefined ? "-" : jc.adopted}`);
      if (jc.failed) out.push(`- ⚠ 失敗したジャッジ: ${jc.failed}`);
      if (jc.rule === "median") out.push("- 確認レベル: 3 (本採点 + 外部2ベンダー以上の下側中央値)");
      else if (jc.rule === "min") out.push("- 確認レベル: 2 (本採点 + 外部1ベンダーの min 採用)");
      else if (jc.rule === "host-degraded") out.push("- ⚠ 外部ジャッジ全滅のため host 確認に降格 (確認レベル: 1)");
      out.push("- 注: 確認レベルは採点経路の多様性であり、台本品質や再生数の確率ではありません。");
      const extNums = String(jc.ext_scores || "").split(/\s+/).filter((s) => /^[0-9]+$/.test(s)).map(Number);
      if (extNums.length >= 2) {
        const spread = Math.max(...extNums) - Math.min(...extNums);
        if (spread >= 10) out.push(`- ⚠ 外部ジャッジ間の点差が ${spread} 点 — 主観の効く成果物です。公開前に人間の最終確認を推奨`);
      }
    }
  }
  out.push("", "## 次回への反映", "");
  out.push("- 納品物を手直ししたら /yt-profile 更新 で直しを次回に反映できます。");
  out.push("- スコアは同一成果物でも±数点ブレます。90点は再生数保証ではなく、公開前の品質基準です。");
  console.log(out.join("\n"));
}

function markFresh(args) {
  const turnsDir = args[0];
  const nnn = pad3(args[1]);
  if (!turnsDir || !args[1]) throw new Error("usage: mark-fresh <turns_dir> <NNN>");
  const evalFile = path.join(turnsDir, `turn-${nnn}-eval.json`);
  if (!fileExists(evalFile)) throw new Error(`eval not found: ${evalFile}`);
  writeText(path.join(turnsDir, `turn-${nnn}-eval.fresh`), `${sha256File(evalFile)}\n`);
  console.log(`fresh marker recorded: ${path.join(turnsDir, `turn-${nnn}-eval.fresh`)}`);
}

function parseFlagArgs(args) {
  const out = {};
  for (let i = 0; i < args.length; i++) {
    const key = args[i];
    if (!String(key).startsWith("--")) continue;
    const name = String(key).slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase());
    out[name] = args[i + 1] === undefined ? "" : args[i + 1];
    i += 1;
  }
  return out;
}

function stateConfig(args) {
  const stateFile = args[0];
  if (!stateFile) throw new Error("usage: state-config <state_file> [--task ...] [--criteria ...] [--evaluator ...] [--evaluator-runtime skill|fable] [--judges host[,claude][,codex][,grok]] [--judge-models <json>] [--host-vendor ...] [--generator ...] [--brief ...] [--anchors ...] [--runtime ...]");
  const flags = parseFlagArgs(args.slice(1));
  const state = readJson(stateFile, {});
  if (Object.prototype.hasOwnProperty.call(flags, "task")) state.task = flags.task;
  if (Object.prototype.hasOwnProperty.call(flags, "criteria")) state.criteria = flags.criteria;
  if (Object.prototype.hasOwnProperty.call(flags, "evaluator")) state.evaluator_skill = flags.evaluator;
  if (Object.prototype.hasOwnProperty.call(flags, "evaluatorRuntime")) state.evaluator_runtime = flags.evaluatorRuntime || "skill";
  if (Object.prototype.hasOwnProperty.call(flags, "judges")) state.judges = flags.judges || "host";
  if (Object.prototype.hasOwnProperty.call(flags, "judgesDetected")) state.judges_detected = flags.judgesDetected || "";
  if (Object.prototype.hasOwnProperty.call(flags, "hostVendor")) state.host_vendor = flags.hostVendor || "other";
  if (Object.prototype.hasOwnProperty.call(flags, "judgeModels")) {
    try { state.judge_models = JSON.parse(flags.judgeModels || "{}"); }
    catch { throw new Error("--judge-models must be valid JSON"); }
  }
  if (Object.prototype.hasOwnProperty.call(flags, "generator")) state.generator_skill = flags.generator;
  if (Object.prototype.hasOwnProperty.call(flags, "brief")) state.brief_file = flags.brief ? flags.brief : null;
  if (Object.prototype.hasOwnProperty.call(flags, "anchors")) state.anchors_file = flags.anchors ? flags.anchors : null;
  if (Object.prototype.hasOwnProperty.call(flags, "runtime")) state.runtime = flags.runtime;
  writeJsonAtomic(stateFile, state);
  console.log(`state configured: ${stateFile}`);
}

function stateEvalResult(args) {
  const stateFile = args[0];
  const iterationRaw = args[1];
  const scoreRaw = args[2];
  if (!stateFile || iterationRaw === undefined || scoreRaw === undefined) {
    throw new Error("usage: state-eval-result <state_file> <iteration> <score|null> [--artifact <artifact_file>]");
  }
  if (!isUintString(iterationRaw)) throw new Error(`iteration must be a non-negative integer: ${iterationRaw}`);
  const iteration = Number(iterationRaw);
  let score = null;
  if (scoreRaw !== "null") {
    if (!isUintString(scoreRaw) || Number(scoreRaw) > 100) throw new Error(`score must be 0-100 or null: ${scoreRaw}`);
    score = Number(scoreRaw);
  }
  const flags = parseFlagArgs(args.slice(3));
  const state = readJson(stateFile, {});
  state.phase = "eval";
  state.latest_score = score;
  state.evaluated_iteration = iteration;
  state.mech_ng = false;
  if (score !== null) {
    if (state.best_score === null || state.best_score === undefined || score > state.best_score) {
      state.best_score = score;
      state.best_iteration = iteration;
    }
    if (flags.artifact && fileExists(flags.artifact)) {
      state.artifact_hashes = state.artifact_hashes && typeof state.artifact_hashes === "object" ? state.artifact_hashes : {};
      state.artifact_hashes[pad3(iteration)] = sha256File(flags.artifact);
    }
  }
  writeJsonAtomic(stateFile, state);
  console.log(`state eval result recorded: iteration ${iteration}, score ${score === null ? "null" : score}`);
}

function stateMechanicalNg(args) {
  const stateFile = args[0];
  const iterationRaw = args[1];
  if (!stateFile || iterationRaw === undefined) throw new Error("usage: state-mechanical-ng <state_file> <iteration>");
  if (!isUintString(iterationRaw)) throw new Error(`iteration must be a non-negative integer: ${iterationRaw}`);
  const state = readJson(stateFile, {});
  state.phase = "eval";
  state.latest_score = null;
  state.evaluated_iteration = Number(iterationRaw);
  state.mech_ng = true;
  writeJsonAtomic(stateFile, state);
  console.log(`state mechanical NG recorded: iteration ${iterationRaw}`);
}

function stateGet(args) {
  const stateFile = args[0];
  const key = args[1];
  if (!stateFile) throw new Error("usage: state-get <state_file> [key]");
  const state = readJson(stateFile, {});
  if (!key) {
    console.log(JSON.stringify(state, null, 2));
    return;
  }
  const value = key.split(".").reduce((cur, part) => (cur == null ? undefined : cur[part]), state);
  if (value === undefined || value === null) return;
  if (typeof value === "object") console.log(JSON.stringify(value));
  else console.log(String(value));
}

function platformDoctor() {
  console.log("# yt-quality-loop platform doctor");
  console.log(`- platform: ${process.platform}`);
  console.log(`- node: ${process.version}`);
  console.log(`- cwd: ${process.cwd()}`);
  if (process.platform === "win32") {
    console.log("- Windows native: OK for Node control plane (yt-loop.js)");
    console.log("- Bash control plane: optional only (Git Bash/WSL required)");
  } else {
    console.log("- Unix control plane: OK for Bash scripts");
    console.log("- Node control plane: OK");
  }
  const judgeRunner = path.join(SCRIPT_DIR, "confirm-judges.js");
  if (fileExists(judgeRunner)) {
    const detected = spawnSync(process.execPath, [judgeRunner, "--detect", "--json"], { encoding: "utf8", timeout: 15000 });
    let providers = [];
    if (detected.status === 0) {
      try { providers = JSON.parse(detected.stdout || "[]"); } catch { providers = []; }
    }
    const available = providers.filter((x) => x.available).map((x) => `${x.provider}(${x.model})`);
    console.log(`- external judges: ${available.length > 0 ? available.join(", ") : "none (optional)"}`);
  }
}

function main(argv = process.argv.slice(2)) {
  const cmd = argv[0];
  const args = argv.slice(1);
  switch (cmd) {
    case "loop-start": return loopStart(args);
    case "hook-stop": return hookStop();
    case "hook-prompt-submit": return hookPromptSubmit();
    case "loop-control": return loopControl(args[0], args[1] || "YT-loop iteration");
    case "validate-eval": {
      const errors = validateEvalData(args[0], args[1] || "-", args[2], args[3] || "");
      if (errors.length > 0) {
        for (const e of errors) console.log(`INVALID: ${e}`);
        process.exitCode = 1;
      } else {
        console.log("OK");
      }
      return;
    }
    case "check-mechanical": {
      const result = checkMechanicalData(args[0], args[1]);
      process.stdout.write(result.output);
      if (!result.ok) process.exitCode = 1;
      return;
    }
    case "count-chars": return console.log(countChars(args[0], args[1] || "raw"));
    case "fingerprint": {
      const stateFile = args[0];
      const mode = args[1] || "";
      const fp = fingerprintValue(stateFile);
      if (mode === "--record") {
        const state = readJson(stateFile, {});
        if (state.config_fingerprint && state.config_fingerprint !== "null") {
          console.log(`already recorded (config_fingerprint は上書きできない): ${state.config_fingerprint}`);
          process.exitCode = 1;
          return;
        }
        state.config_fingerprint = fp;
        state.fingerprint_recorded_at = unixNow();
        writeJsonAtomic(stateFile, state);
        console.log(`recorded: ${fp}`);
      } else {
        console.log(fp);
      }
      return;
    }
    case "final-report": return finalReport(args);
    case "loop-cancel": return loopCancel(args);
    case "mark-fresh": return markFresh(args);
    case "state-config": return stateConfig(args);
    case "state-eval-result": return stateEvalResult(args);
    case "state-mechanical-ng": return stateMechanicalNg(args);
    case "state-get": return stateGet(args);
    case "platform-doctor": return platformDoctor();
    default:
      console.error("usage: yt-loop.js <loop-start|hook-stop|hook-prompt-submit|loop-control|validate-eval|check-mechanical|count-chars|fingerprint|final-report|loop-cancel|mark-fresh|state-config|state-eval-result|state-mechanical-ng|state-get|platform-doctor> ...");
      process.exitCode = 2;
  }
}

module.exports = { main };

if (require.main === module) {
  try {
    main();
  } catch (err) {
    console.error(`ERROR: ${err && err.message ? err.message : err}`);
    process.exit(1);
  }
}
