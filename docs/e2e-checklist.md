# E2E チェックリスト

配布前に、この順番で確認します。

## 1. 静的検証

```bash
bash scripts/validate-packages.sh
```

確認するもの:

- shell syntax
- JSON syntax
- plugin manifest が指す `skills` / `agents` / `hooks` の存在
- Claude Code plugin validation
- Gemini CLI extension compatibility validation
- `git diff --check`

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

## 実測記録 (2026-07-06, codex-cli 0.132.0)

- `codex plugin add yt-quality-loop@yt-quality-loop`: ✅ (cache 1.4.0, hooks/skills 展開確認)
- `$yt-loop-hook` を `codex exec` で実走: hook 未発火 (plugin hook / repo hook とも、`--dangerously-bypass-hook-trust` 付きでも) → **スキルが検知して `$yt-loop` に自動フォールバックし、納品まで完走** (85点・自己採点開示付き・動画ブリーフ自動生成)。exec モードで hook は発火しない模様
- 対話モードの hook 発火: 未検証 (tmux 無し環境)。対話 Codex で `YT_LOOP_SESSION_ID` 注入の有無を確認すること
- 公式 docs 確認済み: PLUGIN_ROOT / CLAUDE_PLUGIN_ROOT が plugin hook に渡る、イベント名 PascalCase、decision:block 継続 — 実装は仕様適合

## 実測記録・追補 (2026-07-06, hook発火条件)

- `codex exec` / 対話TUI (CLI 0.132.0, `--dangerously-bypass-hook-trust` 付き) の両方で、plugin hook・repo hook (`.codex/hooks.json`) とも**発火せず** (dump hook による実測)。プラグインの UserPromptSubmit 注入もコンテキストに届かない (モデルに引用させて NONE を確認)
- bypass 無しの対話承認フローは未検証 — Codex Desktop アプリが `~/.codex/state_5.sqlite` をロックしており CLI 対話を並走できなかった (Desktop 常用環境では CLI 対話の同時起動不可の点も配布時の注意)
- ユーザー環境の `[hooks.state]` に trusted_hash 実績があるため、hook 自体はどこかの面 (Desktop/承認フロー) で機能する。`$yt-loop-hook` は plugin root 不在を検知して `$yt-loop` へ安全にフォールバックするため、発火しない環境でも実害なし (実測済み)
