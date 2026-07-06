#!/bin/bash
set -euo pipefail
# validate-packages.sh — 配布パッケージの静的検証をまとめて実行する。

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "== shell syntax =="
find . -name '*.sh' -type f -not -path './.git/*' -print0 | xargs -0 -n1 bash -n

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
claude plugin validate plugins/yt-quality-loop --strict

echo "== gemini extension compatibility =="
if command -v gemini >/dev/null 2>&1; then
  gemini extensions validate antigravity-plugin >/dev/null
else
  echo "SKIP: gemini CLI not found"
fi

echo "== git whitespace =="
git diff --check

echo "validate-packages: ok"
