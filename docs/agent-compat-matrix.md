# Agent Compatibility Matrix

Last checked: 2026-07-13

This document is the source of truth for what this repository assumes about Claude Code, Codex, Cursor, and Antigravity. Do not rely on an AI agent's memory when changing cross-agent packaging. Check the official docs, update the checked date, and record what was actually tested.

## Summary

| Host | Package surface | Skills | Agents / subagents | Hooks | This repo's package | Recommended mode |
|---|---|---|---|---|---|---|
| Claude Code | Claude plugin | Yes | Subagents via Claude Code/plugin surfaces | Yes | `plugins/yt-quality-loop/` | Primary hook-driven loop |
| Codex | Codex plugin with `.codex-plugin/plugin.json` | Yes | Custom subagents | Yes; non-managed hooks require trust | `codex-plugin/` | `$yt-loop-hook` is the deterministic-gate path; `$yt-loop` is the no-hook fallback |
| Cursor | Cursor plugin / skills / agents | Yes | Subagents | Yes | `cursor-plugin/` | Skill fallback path; verify GUI plugin load |
| Antigravity | Antigravity plugin | Yes | Subagents | Platform-dependent; do not assume Claude/Codex hook parity | `antigravity-plugin/` | Skill fallback path; verify GUI or `agy` where available |

## OS Compatibility

| OS/runtime | Status | Notes |
|---|---|---|
| macOS | Verified static + deterministic E2E | Bash compatibility path and Node control plane are both tested locally. |
| Linux | Supported by design | Same Bash/Node assumptions as macOS; verify in CI before claiming a specific distro. |
| Windows WSL | Supported by design | Use the Bash compatibility path inside Ubuntu/WSL (`jq` required for Bash scripts). |
| Windows native (PowerShell/cmd) | Supported for the control plane | Hooks, state updates, eval validation, mechanical checks, fingerprinting, final report, and multi-vendor judge execution use Node without Bash/jq. GUI host loading still needs real app verification. |

## Optional Fable Integration

| Mode | Expected behavior | Verification status |
|---|---|---|
| Codex Plan mode + `fable-mcp` available | Use Fable by default for criteria, brief, anchors, and plan review before the loop starts. | Instruction-level support. Fable MCP auth/runtime is external to this repo. |
| Normal mode + explicit `Fable` / `Fable5` / `フェイブル` / `evaluator: fable` | Use Fable only when explicitly requested. | Instruction-level support. Falls back to the normal fresh evaluator if unavailable. |
| Scoring with `evaluator: fable` | Keep the selected `evaluator_skill` as the scoring contract and set `evaluator_runtime` to `fable`; pass task, criteria, artifact, profile, brief, anchors, and the eval JSON contract only. Do not pass threshold, iteration, past scores, past feedback, or pass/fail expectations. | Deterministic validation remains covered by `validate-eval`, Stop hook, and `loop-judge`; Fable auth is not part of CI. |

## Official Sources

| Host | Sources |
|---|---|
| Codex | [Build plugins](https://learn.chatgpt.com/docs/build-plugins), [Hooks](https://learn.chatgpt.com/docs/hooks), [Subagents](https://developers.openai.com/codex/subagents) |
| Cursor | [Skills](https://cursor.com/docs/skills), [Hooks](https://cursor.com/docs/hooks), [Subagents](https://cursor.com/docs/subagents) |
| Antigravity | [Plugins](https://antigravity.google/docs/cli/plugins), [Skills](https://antigravity.google/docs/skills), [Subagents](https://antigravity.google/docs/cli/subagents) |
| Fable MCP | [sam-mountainman/fable-mcp](https://github.com/sam-mountainman/fable-mcp) |

## Local Verification Policy

Before claiming support for a host, record two different things:

1. **Static compatibility**: manifests parse, referenced paths exist, bundled skills/agents/hooks are present, and vendor validators pass where available.
2. **Runtime compatibility**: the actual app or CLI sees the plugin and can call `yt-loop` or the equivalent skill.

Static compatibility is enough to ship an experimental package, but not enough to write "verified in Cursor" or "verified in Antigravity GUI". GUI load checks are manual unless the vendor provides a stable headless validator.

## Known Behavior

### Codex

- Codex plugins can package skills, hooks, and custom subagents.
- Plugin hooks must be trusted by the host before execution. Installing/enabling a plugin is not the same as trusting its hooks.
- This repo keeps `$yt-loop` as the stable fallback. `$yt-loop-hook` must detect missing hook context and fall back safely.
- Historical local measurement on CLI 0.132.0 found non-firing hooks. On 2026-07-13, CLI 0.144.1 `codex exec --dangerously-bypass-hook-trust` fired the Stop hook. Treat the old result as historical; current official docs and current-version probes take precedence.
- The installed v1.7.1 plugin bundle was also exercised: UserPromptSubmit injected the real session id and Codex emitted Stop hook events in the same `codex exec` run.
- Multi-vendor judges use the cross-platform Node runner. Claude defaults to model alias `fable`; Codex/Grok resolve and pin a CLI model id when possible. Unresolved defaults are disclosed as `configured-unpinned`, not presented as pinned. Explicitly requested but unavailable providers remain visible as failed judges. MCP servers are optional reviewer/evaluator integrations, not the deterministic judge runner.

### Cursor

- Cursor has skills, hooks, and subagents as first-class concepts.
- This repo packages `cursor-plugin/skills/yt-loop/` and `cursor-plugin/agents/yt-quality-evaluator.md`.
- Do not claim GUI verification until Cursor has loaded `cursor-plugin/.cursor-plugin/plugin.json` and the skill/agent are visible in the app.

### Antigravity

- Antigravity has plugin, skill, and subagent concepts.
- This repo packages `antigravity-plugin/plugin.json` as the main manifest and keeps `gemini-extension.json` for compatibility.
- If `agy` is unavailable, only static manifest compatibility and Gemini-extension compatibility can be claimed.

## Update Checklist

When a future change touches cross-agent packaging:

- Update this matrix with the official source and checked date.
- Run `bash scripts/probe-agent-platforms.sh`.
- Run `bash scripts/validate-packages.sh && bash scripts/e2e-smoke.sh`.
- Run `node scripts/e2e-smoke-node.js` on Windows native or in CI `windows-latest`.
- If a GUI check was not actually performed, write "not GUI verified" instead of implying support.
