#!/bin/bash
# probe-agent-platforms.sh — Detect local host-agent support without relying on agent memory.
#
# This script is intentionally read-only. It reports installed CLIs/apps,
# package versions, and which checks can be performed on this machine.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

COMMON_PATHS=(
  /opt/homebrew/bin
  /usr/local/bin
  /usr/bin
  /bin
  /Applications/Codex.app/Contents/Resources
  /Applications/Cursor.app/Contents/MacOS
  /Applications/Antigravity.app/Contents/MacOS
)

find_cmd() {
  local name="$1"
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return 0
  fi
  local dir
  for dir in "${COMMON_PATHS[@]}"; do
    if [ -x "$dir/$name" ]; then
      printf '%s\n' "$dir/$name"
      return 0
    fi
  done
  return 1
}

print_cmd() {
  local name="$1"
  local path
  if path="$(find_cmd "$name")"; then
    printf 'OK   %-8s %s\n' "$name" "$path"
  else
    printf 'MISS %-8s not found\n' "$name"
  fi
}

version_of() {
  local name="$1"
  local path
  path="$(find_cmd "$name")" || return 0
  case "$name" in
    node) "$path" --version 2>/dev/null | head -1 ;;
    gh) "$path" --version 2>/dev/null | head -1 ;;
    jq) "$path" --version 2>/dev/null | head -1 ;;
    codex) "$path" --version 2>/dev/null | head -1 ;;
    claude) "$path" --version 2>/dev/null | head -1 ;;
    grok) "$path" --version 2>/dev/null | head -1 ;;
    gemini) "$path" --version 2>/dev/null | head -1 ;;
    agy) "$path" --version 2>/dev/null | head -1 ;;
    cursor) "$path" --version 2>/dev/null | head -1 ;;
  esac
}

manifest_version() {
  local file="$1"
  if [ -f "$file" ] && find_cmd jq >/dev/null 2>&1; then
    "$(find_cmd jq)" -r '.version // "n/a"' "$file" 2>/dev/null
  else
    printf 'n/a\n'
  fi
}

section() {
  printf '\n== %s ==\n' "$1"
}

section "Host commands"
for cmd in node jq gh claude codex grok cursor agy gemini; do
  print_cmd "$cmd"
done

section "Versions"
for cmd in node jq gh claude codex grok cursor agy gemini; do
  v="$(version_of "$cmd")"
  if [ -n "${v:-}" ]; then
    printf '%-8s %s\n' "$cmd" "$v"
  fi
done

section "OS runtime"
printf 'uname      %s\n' "$(uname -a 2>/dev/null || echo unknown)"
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*) printf 'windows    native-ish shell detected; prefer node scripts/yt-loop.js\n' ;;
  Linux*)
    if grep -qi microsoft /proc/version 2>/dev/null; then
      printf 'windows    WSL detected; Bash compatibility path is available if jq is installed\n'
    else
      printf 'linux      Bash/Node paths available\n'
    fi
    ;;
  Darwin*) printf 'macos      Bash/Node paths available\n' ;;
  *) printf 'unknown    verify Bash/Node paths manually\n' ;;
esac

section "GUI apps"
for app in /Applications/Codex.app /Applications/Cursor.app /Applications/Antigravity.app; do
  if [ -d "$app" ]; then
    printf 'OK   %s\n' "$app"
  else
    printf 'MISS %s\n' "$app"
  fi
done

section "Package versions"
printf 'claude-plugin     %s\n' "$(manifest_version plugins/yt-quality-loop/.claude-plugin/plugin.json)"
printf 'codex-plugin      %s\n' "$(manifest_version codex-plugin/.codex-plugin/plugin.json)"
printf 'cursor-plugin     %s\n' "$(manifest_version cursor-plugin/.cursor-plugin/plugin.json)"
printf 'antigravity       %s\n' "$(manifest_version antigravity-plugin/plugin.json)"
printf 'gemini-compat     %s\n' "$(manifest_version antigravity-plugin/gemini-extension.json)"

section "External judge candidates"
if [ -f plugins/yt-quality-loop/scripts/confirm-judges.js ] && command -v node >/dev/null 2>&1; then
  node plugins/yt-quality-loop/scripts/confirm-judges.js --detect --json
else
  printf 'SKIP Node judge runner not available\n'
fi

section "Static package checks"
if [ -x scripts/validate-packages.sh ]; then
  printf 'OK   scripts/validate-packages.sh present\n'
else
  printf 'MISS scripts/validate-packages.sh\n'
fi
if [ -x scripts/e2e-smoke.sh ]; then
  printf 'OK   scripts/e2e-smoke.sh present\n'
else
  printf 'MISS scripts/e2e-smoke.sh\n'
fi
if [ -f scripts/e2e-smoke-node.js ]; then
  printf 'OK   scripts/e2e-smoke-node.js present (Windows native control plane)\n'
else
  printf 'MISS scripts/e2e-smoke-node.js\n'
fi

section "Codex plugin state"
if codex_path="$(find_cmd codex)"; then
  tmp="$(mktemp)"
  if "$codex_path" plugin list >"$tmp" 2>/dev/null; then
    if awk '/yt-quality-loop@yt-quality-loop/ {found=1; print} END {exit found ? 0 : 1}' "$tmp"; then
      :
    else
      printf 'WARN yt-quality-loop not found in codex plugin list\n'
    fi
  else
    printf 'WARN codex plugin list failed\n'
  fi
  rm -f "$tmp"
else
  printf 'SKIP codex CLI not found\n'
fi

section "GitHub state"
if gh_path="$(find_cmd gh)"; then
  "$gh_path" auth status 2>&1 | sed 's/Token: .*/Token: *** masked ***/'
  if git remote get-url origin >/dev/null 2>&1; then
    printf 'origin %s\n' "$(git remote get-url origin)"
  else
    printf 'origin not configured\n'
  fi
else
  printf 'SKIP gh CLI not found\n'
fi

section "Manual checks still required"
printf '%s\n' '- Cursor GUI: load cursor-plugin/.cursor-plugin/plugin.json and confirm skill + agent visibility.'
printf '%s\n' '- Antigravity GUI: load antigravity-plugin/plugin.json and confirm skill + agent visibility.'
printf '%s\n' '- Windows native GUI: confirm the host loads plugin hooks and can run yt-loop.js + confirm-judges.js.'
printf '%s\n' '- Separate machine rehearsal: clone or unzip, then run validate + one yt-loop smoke path.'

printf '\nprobe-agent-platforms: done\n'
