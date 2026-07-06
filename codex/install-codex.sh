#!/bin/bash
# install-codex.sh — 後方互換ラッパー。実体は install-skills.sh (codex/cursor/antigravity 対応)
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install-skills.sh" codex
