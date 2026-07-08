#!/bin/bash
set -euo pipefail
# validate-packages.sh — 配布パッケージの静的検証をまとめて実行する。

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# claude CLI など Node 製 CLI は Node 20+ が必要。PATH の先頭が古い node (nvm の
# 旧バージョン等) だと /v 正規表現フラグで即死するため、新しい node を前置する。
if command -v node >/dev/null 2>&1; then
  NODE_MAJOR=$(node -v 2>/dev/null | sed "s/^v\\([0-9]*\\).*/\\1/")
  if [ -n "$NODE_MAJOR" ] && [ "$NODE_MAJOR" -lt 20 ] 2>/dev/null; then
    NEWNODE=$(ls -d "$HOME"/.nvm/versions/node/v2[0-9]*/bin 2>/dev/null | sort -V | tail -1)
    if [ -n "$NEWNODE" ]; then
      export PATH="$NEWNODE:$PATH"
      echo "NOTICE: node $(node -v) を使用 (旧 node は claude CLI を壊すため差し替え)"
    else
      echo "WARNING: node が v20 未満です。claude plugin validate が失敗する可能性があります" >&2
    fi
  fi
fi

echo "== shell syntax =="
find . -name '*.sh' -type f -not -path './.git/*' -print0 | xargs -0 -n1 bash -n

echo "== node syntax =="
find . -name '*.js' -type f -not -path './.git/*' -print0 | xargs -0 -n1 node --check

echo "== json syntax =="
find . -name '*.json' -type f -not -path './.git/*' -print0 | xargs -0 -n1 jq empty

echo "== manifest paths =="
node <<'NODE'
const fs = require('fs');
const checks = [
  ['codex-plugin/.codex-plugin/plugin.json', 'codex-plugin'],
  ['cursor-plugin/.cursor-plugin/plugin.json', 'cursor-plugin'],
  ['antigravity-plugin/plugin.json', 'antigravity-plugin'],
];

for (const [file, base] of checks) {
  const json = JSON.parse(fs.readFileSync(file, 'utf8'));
  for (const key of ['skills', 'agents', 'hooks']) {
    if (!json[key]) continue;
    const values = Array.isArray(json[key]) ? json[key] : [json[key]];
    for (const value of values) {
      if (typeof value !== 'string') {
        throw new Error(`${file}: ${key} must be a string path`);
      }
      if (!value.startsWith('./')) {
        throw new Error(`${file}: ${key} must be relative and start with ./: ${value}`);
      }
      const target = `${base}/${value.slice(2)}`;
      if (!fs.existsSync(target)) {
        throw new Error(`${file}: ${key} target missing: ${target}`);
      }
    }
  }
  for (const [label, value] of [
    ['icon', json.icon],
    ['logo', json.logo],
    ['interface.logo', json.interface && json.interface.logo],
    ['interface.logoDark', json.interface && json.interface.logoDark],
    ['interface.composerIcon', json.interface && json.interface.composerIcon],
  ]) {
    if (!value) continue;
    if (typeof value !== 'string') {
      throw new Error(`${file}: ${label} must be a string path`);
    }
    const normalized = value.startsWith('./') ? value.slice(2) : value;
    if (normalized.startsWith('/') || normalized.includes('..')) {
      throw new Error(`${file}: ${label} must stay inside plugin root: ${value}`);
    }
    const target = `${base}/${normalized}`;
    if (!fs.existsSync(target)) {
      throw new Error(`${file}: ${label} target missing: ${target}`);
    }
  }
}

for (const file of [
  'agents/yt-quality-evaluator.md',
  'cursor-plugin/agents/yt-quality-evaluator.md',
  'antigravity-plugin/agents/yt-quality-evaluator.md',
]) {
  const text = fs.readFileSync(file, 'utf8');
  if (!/^---\nname: .+\ndescription: .+\n---/m.test(text)) {
    throw new Error(`${file}: missing name/description frontmatter`);
  }
}
NODE

echo "== claude plugin =="
if command -v claude >/dev/null 2>&1; then
  claude plugin validate plugins/yt-quality-loop --strict
else
  echo "SKIP: claude CLI not found"
fi

echo "== gemini extension compatibility =="
if command -v gemini >/dev/null 2>&1; then
  gemini extensions validate antigravity-plugin >/dev/null
else
  echo "SKIP: gemini CLI not found"
fi

echo "== git whitespace =="
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git diff --check
else
  echo "SKIP: not a git worktree"
fi

echo "validate-packages: ok"
