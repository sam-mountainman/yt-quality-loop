#!/usr/bin/env node
/*
 * Cross-platform E2E smoke for the Node control plane.
 * This is the Windows-native counterpart to scripts/e2e-smoke.sh.
 */

const fs = require("fs");
const os = require("os");
const path = require("path");
const assert = require("assert");
const { spawnSync } = require("child_process");

const ROOT = path.resolve(__dirname, "..");

function runNode(pluginRoot, args, options = {}) {
  const script = path.join(pluginRoot, "scripts", "yt-loop.js");
  const result = spawnSync(process.execPath, [script, ...args], {
    input: options.input || undefined,
    encoding: "utf8",
    env: { ...process.env, ...options.env, PLUGIN_ROOT: pluginRoot, CLAUDE_PLUGIN_ROOT: pluginRoot },
  });
  if (result.status !== 0) {
    throw new Error(`node ${script} ${args.join(" ")} failed\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`);
  }
  return result.stdout;
}

function runJudge(pluginRoot, args, options = {}) {
  const script = path.join(pluginRoot, "scripts", "confirm-judges.js");
  const result = spawnSync(process.execPath, [script, ...args], {
    encoding: "utf8",
    env: { ...process.env, ...options.env, PLUGIN_ROOT: pluginRoot, CLAUDE_PLUGIN_ROOT: pluginRoot },
  });
  if (result.status !== 0) {
    throw new Error(`node ${script} ${args.join(" ")} failed\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`);
  }
  return result.stdout;
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function writeJson(file, data) {
  fs.writeFileSync(file, `${JSON.stringify(data, null, 2)}\n`, "utf8");
}

function smoke(pluginRoot) {
  if (!fs.existsSync(path.join(pluginRoot, "scripts", "yt-loop.js"))) {
    throw new Error(`plugin Node control plane not found: ${pluginRoot}`);
  }

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "yt-quality-loop-node-"));
  const sid = "node-hook-smoke";
  try {
    console.log(`== node hook start (${pluginRoot}) ==`);
    const startOut = runNode(pluginRoot, ["loop-start", tmp, "2", "90", sid, "--max-wall-minutes", "5"]);
    const stateLine = startOut.split(/\r?\n/).find((line) => line.startsWith("State file:"));
    assert(stateLine, "State file line missing");
    const stateFile = stateLine.replace(/^State file:\s*/, "");
    let state = readJson(stateFile);
    const turnsDir = state.turns_dir;
    assert(fs.existsSync(stateFile), "state not initialized");
    assert(fs.existsSync(turnsDir), "turns dir not initialized");

    console.log("== node write deterministic state/anchors/artifact/eval ==");
    const anchors = path.join(path.dirname(stateFile), "criteria-anchors.md");
    fs.writeFileSync(anchors, [
      "## 冒頭フック",
      "- 90+: 冒頭1文目に視聴者の悩みが明示される",
      "## 構成の明確さ",
      "- 90+: 結論→手順→注意点の順で並ぶ",
      "## 具体性と信頼性",
      "- 90+: 手順に実例が1つ以上ある",
      "",
    ].join("\n"), "utf8");

    const judgeStub = path.join(tmp, "judge-stub.js");
    fs.writeFileSync(judgeStub, [
      "const fs = require('fs');",
      "if (process.argv.includes('--version')) { console.log('judge-stub 1.0'); process.exit(0); }",
      "const promptIndex = process.argv.indexOf('--prompt-file');",
      "if (process.env.YT_JUDGE_STUB_CAPTURE && promptIndex >= 0) fs.writeFileSync(process.env.YT_JUDGE_STUB_CAPTURE, fs.readFileSync(process.argv[promptIndex + 1], 'utf8'));",
      "console.log(JSON.stringify({score:92,quality:{overall:92,breakdown:{'冒頭フック':91,'構成の明確さ':93,'具体性と信頼性':92}},feedback:'独立確認では冒頭の悩み提示と結論先行が明確です。具体例も含まれています。注意点に根拠を一文追加すればさらに堅くなりますが、公開前の基準には達しています。',evaluator_skill:'subagent-fresh-eval'}));",
      "",
    ].join("\n"), "utf8");
    const judgeCmd = path.join(tmp, "judge-stub.cmd");
    if (process.platform === "win32") {
      fs.writeFileSync(judgeCmd, `@echo off\r\n"${process.execPath}" "%~dp0judge-stub.js" %*\r\n`, "utf8");
    }
    const judgeEnv = {
      YT_JUDGE_GROK_BIN: process.platform === "win32" ? judgeCmd : process.execPath,
      YT_JUDGE_GROK_ARGS_JSON: JSON.stringify(process.platform === "win32" ? [] : [judgeStub]),
      YT_JUDGE_GROK_MODEL: "grok-test",
    };

    runNode(pluginRoot, [
      "state-config",
      stateFile,
      "--task",
      "テスト用のYouTube台本",
      "--criteria",
      "冒頭フック,構成の明確さ,具体性と信頼性",
      "--evaluator",
      "subagent-fresh-eval",
      "--runtime",
      "codex-hook",
      "--anchors",
      anchors,
    ]);

    console.log("== node configure external judge ==");
    runJudge(pluginRoot, ["--configure", stateFile, "--selection", "host+grok", "--host-vendor", "codex"], { env: judgeEnv });

    runNode(pluginRoot, ["fingerprint", stateFile, "--record"]);

    fs.writeFileSync(path.join(turnsDir, "turn-000-output.md"), [
      "# テスト台本",
      "冒頭で視聴者の悩みを提示し、結論、手順、注意点、CTAの順に説明する。",
      "",
    ].join("\n"), "utf8");

    writeJson(path.join(turnsDir, "turn-000-eval.json"), {
      score: 91,
      quality: {
        overall: 91,
        breakdown: {
          "冒頭フック": 90,
          "構成の明確さ": 92,
          "具体性と信頼性": 91,
        },
      },
      feedback: "冒頭で視聴者の悩みを示し、構成も明確です。さらに実例を一つ増やすと信頼性が上がりますが、公開前の合格水準には達しています。",
      evaluator_skill: "subagent-fresh-eval",
    });
    runNode(pluginRoot, [
      "state-eval-result",
      stateFile,
      "0",
      "91",
      "--artifact",
      path.join(turnsDir, "turn-000-output.md"),
    ]);

    console.log("== node external judge ==");
    const judgeOut = runJudge(pluginRoot, [stateFile], { env: judgeEnv });
    assert(judgeOut.includes("JUDGE:grok MODEL:grok-test SCORE:92"), `unexpected judge output:\n${judgeOut}`);
    assert(fs.existsSync(path.join(turnsDir, "turn-000-eval-confirm-grok.fresh")));

    console.log("== node stop hook threshold_met ==");
    const stopOut = runNode(pluginRoot, ["hook-stop"], {
      input: JSON.stringify({ cwd: tmp, session_id: sid, hook_event_name: "Stop" }),
    });
    const stopJson = JSON.parse(stopOut);
    assert.strictEqual(stopJson.decision, "block");
    assert(stopJson.reason.includes("threshold_met"));
    state = readJson(stateFile);
    assert.strictEqual(state.active, false);
    assert.strictEqual(state.ended_reason, "threshold_met");

    console.log("== node final report ==");
    const delivered = path.join(tmp, "delivered.md");
    const reportOut = runNode(pluginRoot, ["final-report", stateFile, delivered]);
    assert(reportOut.includes(`Deliverable: ${delivered}`));
    assert(reportOut.includes("Best score: 91"));
    assert(reportOut.includes("grok model: grok-test"));
    assert(fs.statSync(delivered).size > 0);

    console.log("== node hookless context fallback ==");
    const hooklessDir = path.join(tmp, "hookless");
    fs.mkdirSync(hooklessDir, { recursive: true });
    const hooklessState = path.join(hooklessDir, "state.json");
    const uniqueTask = "HOOKLESS_TASK_FROM_TASK_MD";
    const uniqueAnchor = "HOOKLESS_ANCHOR_FROM_DEFAULT_FILE";
    fs.writeFileSync(path.join(hooklessDir, "task.md"), uniqueTask, "utf8");
    fs.writeFileSync(path.join(hooklessDir, "criteria-anchors.md"), uniqueAnchor, "utf8");
    fs.writeFileSync(path.join(hooklessDir, "turn-000-output.md"), "# hookless artifact\n", "utf8");
    writeJson(path.join(hooklessDir, "turn-000-eval.json"), { score: 91 });
    writeJson(hooklessState, {
      judges: "host,grok",
      judge_models: { grok: "grok-test" },
      criteria: "冒頭フック,構成の明確さ,具体性と信頼性",
      evaluator_skill: "subagent-fresh-eval",
      threshold: 90,
      iteration: 0,
      evaluated_iteration: 0,
    });
    const capture = path.join(hooklessDir, "captured-prompt.txt");
    runJudge(pluginRoot, [hooklessState], { env: { ...judgeEnv, YT_JUDGE_STUB_CAPTURE: capture } });
    const capturedPrompt = fs.readFileSync(capture, "utf8");
    assert(capturedPrompt.includes(uniqueTask), "task.md fallback missing from judge prompt");
    assert(capturedPrompt.includes(uniqueAnchor), "criteria-anchors.md fallback missing from judge prompt");

    console.log("== node explicit unavailable judge remains visible ==");
    const missingBin = path.join(tmp, "definitely-missing-judge-command");
    const unavailableEnv = { YT_JUDGE_GROK_BIN: missingBin, YT_JUDGE_GROK_MODEL: "grok-test" };
    runJudge(pluginRoot, ["--configure", hooklessState, "--selection", "host+grok", "--host-vendor", "codex"], { env: unavailableEnv });
    const unavailableState = readJson(hooklessState);
    assert.strictEqual(unavailableState.judges, "host,grok");
    assert.strictEqual(unavailableState.judges_unavailable, "grok");
    const unavailableOut = runJudge(pluginRoot, [hooklessState], { env: unavailableEnv });
    assert(unavailableOut.includes("JUDGE:grok MODEL:grok-test FAILED:CLI not found"));
    assert(fs.existsSync(path.join(hooklessDir, "turn-000-eval-confirm-grok.failed")));
    const unavailableReport = runNode(pluginRoot, ["final-report", hooklessState]);
    assert(unavailableReport.includes("ループ開始時に不在だった明示ジャッジ: grok"));

    console.log("== node threshold zero remains zero ==");
    const zeroDir = path.join(tmp, "threshold-zero");
    fs.mkdirSync(zeroDir, { recursive: true });
    const zeroStart = runNode(pluginRoot, ["loop-start", zeroDir, "1", "0", `${sid}-zero`]);
    const zeroState = zeroStart.split(/\r?\n/).find((line) => line.startsWith("State file:")).replace(/^State file:\s*/, "");
    const zeroReport = runNode(pluginRoot, ["final-report", zeroState]);
    assert(zeroReport.includes("- Threshold: 0"));

    console.log("== node hook prompt submit ==");
    const promptOut = runNode(pluginRoot, ["hook-prompt-submit"], {
      input: JSON.stringify({ cwd: tmp, session_id: sid, hook_event_name: "UserPromptSubmit" }),
    });
    assert(promptOut.includes(`YT_LOOP_SESSION_ID=${sid}`));

    console.log(`e2e-smoke-node (${pluginRoot}): ok`);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

const targets = process.argv.slice(2);
if (targets.length === 0) {
  smoke(path.join(ROOT, "plugins", "yt-quality-loop"));
  smoke(path.join(ROOT, "codex-plugin"));
  console.log("e2e-smoke-node: ok (plugins + codex-plugin)");
} else {
  for (const target of targets) smoke(path.resolve(target));
}
