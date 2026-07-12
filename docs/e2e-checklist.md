# E2E チェックリスト

配布前に、この順番で確認します。

## 1. 静的検証

```bash
bash scripts/validate-packages.sh
```

確認するもの:

- shell syntax
- Node syntax (`yt-loop.js`, `e2e-smoke-node.js`)
- JSON syntax
- plugin manifest が指す `skills` / `agents` / `hooks` の存在
- Claude Code plugin validation
- Gemini CLI extension compatibility validation
- `git diff --check`

## 1.5. エージェント環境プローブ

```bash
bash scripts/probe-agent-platforms.sh
```

確認するもの:

- `node` / `codex` / `claude` / `cursor` / `agy` / `gemini` / `gh` / `jq` の検出可否
- Codex plugin list 上の `yt-quality-loop@yt-quality-loop` の状態
- Cursor / Antigravity アプリの存在
- GUI 確認・別マシン確認として残るもの

## 2. Hook 状態遷移スモーク

```bash
bash scripts/e2e-smoke.sh
```

確認するもの:

- `loop-start.sh` が session-scoped state を作る
- `fingerprint.sh` がものさしを記録する
- `hook-stop.sh` が `threshold_met` を検証して `decision: "block"` を返す
- state が `active=false`, `ended_reason=threshold_met` になる
- `hook-prompt-submit.sh` が `YT_LOOP_SESSION_ID` を注入する

このスモークは LLM を呼びません。配布物の制御プレーンだけを決定論的に検査します。

## 2.5. Windows ネイティブ制御プレーン

Windows PowerShell / cmd では Bash に依存しない Node 経路を検証します。

```bash
node scripts/e2e-smoke-node.js
```

確認するもの:

- `yt-loop.js loop-start` が session-scoped state を作る
- `yt-loop.js state-config` / `state-eval-result` が jq 無しで state を更新する
- `yt-loop.js hook-stop` が `threshold_met` を検証して `decision: "block"` を返す
- `yt-loop.js final-report` が納品物とレポートを作る
- `yt-loop.js hook-prompt-submit` が `YT_LOOP_SESSION_ID` を注入する

この検証が通っても、Claude Code / Codex / Cursor / Antigravity の Windows GUI がプラグインを実際に読み込むかは別項目として確認する。

## 3. Codex 実機

```bash
# 初回のみ: マーケットプレイス登録 (リポジトリのパス or GitHub owner/repo)
codex plugin marketplace add <このリポジトリのパス>
codex plugin remove yt-quality-loop@yt-quality-loop || true
codex plugin add yt-quality-loop@yt-quality-loop
codex plugin list | grep yt-quality-loop
```

確認するもの:

- cache に `codex-plugin/hooks/hooks.json` が入る
- cache に `skills/yt-loop-hook/SKILL.md` が入る
- hook は Codex 側で信頼されるまで実行されないため、UI または `/hooks` 相当の画面で確認する

## 4. Cursor 実機

Cursor CLI には、この repo の plugin marketplace を headless validate する安定コマンドが無い場合があります。その場合は構造検証を通したうえで、Cursor アプリ側の `/add-plugin` で確認します。

確認するもの:

- `cursor-plugin/.cursor-plugin/plugin.json` が読まれる
- `skills/yt-loop/SKILL.md` が見える
- `agents/yt-quality-evaluator.md` が見える
- `yt-loop` を呼ぶと hook なしフォールバックとして動く

## 5. Antigravity 実機

このマシンに `agy` が無い場合は、`gemini extensions validate antigravity-plugin` までを確認済みにします。`agy` がある環境では Antigravity 側の plugin 認識を別途確認します。

確認するもの:

- `antigravity-plugin/plugin.json` が主マニフェストとして読まれる
- `skills/yt-loop/SKILL.md` が見える
- `agents/yt-quality-evaluator.md` が見える
- 旧 Gemini CLI 互換では `gemini-extension.json` が validate される

## Codex実測記録

- `codex plugin add yt-quality-loop@yt-quality-loop`: v1.7.1で再確認する
- **過去結果 (2026-07-06, CLI 0.132.0)**: `codex exec` でhook未発火。現行仕様の判定には使わない
- **現行結果 (2026-07-13, CLI 0.144.1)**: ユーザーStop hookを `codex exec --dangerously-bypass-hook-trust` で実行し、マーカーファイル作成を確認。公式hooks仕様とも一致
- v1.7.1をローカルマーケットプレイスからinstallし、plugin同梱UserPromptSubmitが実session idをモデルへ注入すること、同じturnでStop hookイベントが実行されることを確認
- 対話モードのplugin hook信頼フロー: `/hooks` で実機確認すること
- 公式 docs 確認済み: PLUGIN_ROOT / CLAUDE_PLUGIN_ROOT が plugin hook に渡る、イベント名 PascalCase、decision:block 継続 — 実装は仕様適合

### 過去記録 (0.132.0、参考のみ)

- `codex exec` / 対話TUI (CLI 0.132.0, `--dangerously-bypass-hook-trust` 付き) の両方で、plugin hook・repo hook (`.codex/hooks.json`) とも**発火せず** (dump hook による実測)。プラグインの UserPromptSubmit 注入もコンテキストに届かない (モデルに引用させて NONE を確認)
- bypass 無しの対話承認フローは未検証 — Codex Desktop アプリが `~/.codex/state_5.sqlite` をロックしており CLI 対話を並走できなかった (Desktop 常用環境では CLI 対話の同時起動不可の点も配布時の注意)
- 本番pluginでは `/hooks` で定義を確認・信頼し、`$yt-loop-hook` の実走でStop継続を確認する。管理ポリシーやhook無効時は `$yt-loop` へフォールバックする
