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
