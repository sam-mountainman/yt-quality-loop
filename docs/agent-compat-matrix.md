# Agent Compatibility Matrix

Last checked: 2026-07-07

This document is the source of truth for what this repository assumes about Claude Code, Codex, Cursor, and Antigravity. Do not rely on an AI agent's memory when changing cross-agent packaging. Check the official docs, update the checked date, and record what was actually tested.

## Summary

| Host | Package surface | Skills | Agents / subagents | Hooks | This repo's package | Recommended mode |
|---|---|---|---|---|---|---|
| Claude Code | Claude plugin | Yes | Subagents via Claude Code/plugin surfaces | Yes | `plugins/yt-quality-loop/` | Primary hook-driven loop |
| Codex | Codex plugin with `.codex-plugin/plugin.json` | Yes | Custom subagents | Yes, but trust/UI behavior must be verified per host | `codex-plugin/` | `$yt-loop` fallback is the stable path; `$yt-loop-hook` is optional |
| Cursor | Cursor plugin / skills / agents | Yes | Subagents | Yes | `cursor-plugin/` | Skill fallback path; verify GUI plugin load |
| Antigravity | Antigravity plugin | Yes | Subagents | Platform-dependent; do not assume Claude/Codex hook parity | `antigravity-plugin/` | Skill fallback path; verify GUI or `agy` where available |

## Official Sources

| Host | Sources |
|---|---|
| Codex | [Build plugins](https://developers.openai.com/codex/plugins/build), [Hooks](https://developers.openai.com/codex/hooks), [Subagents](https://developers.openai.com/codex/subagents) |
| Cursor | [Skills](https://cursor.com/docs/skills), [Hooks](https://cursor.com/docs/hooks), [Subagents](https://cursor.com/docs/subagents) |
| Antigravity | [Plugins](https://antigravity.google/docs/cli/plugins), [Skills](https://antigravity.google/docs/skills), [Subagents](https://antigravity.google/docs/cli/subagents) |

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
- Historical local measurement in this repo found Codex CLI hook non-firing in some `codex exec` and interactive CLI paths. Treat hook support as host-version-dependent and probe before promising unattended hook behavior.

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
- If a GUI check was not actually performed, write "not GUI verified" instead of implying support.
