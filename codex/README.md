# Codex / Cursor / Antigravity で yt-quality-loop を使う

Claude Code 以外の 3 環境向けのガイドです。ループの仕組みは共通: **作る → 採点 (まっさらな別の頭) → シェルの整数比較で続行判定**。

2026-07-06 時点で確認した前提:

- **Codex**: プラグインは `codex-plugin/.codex-plugin/plugin.json`、skills、hooks を同梱できる。Stop hook は `decision: "block"` で継続プロンプトを作れるため、Claude Code 版に近い hook 駆動ループを実装済み。
- **Cursor**: `.cursor-plugin/plugin.json` で `skills` と `agents` を指す形式。公式サンプルに合わせて manifest と採点 agent を同梱。
- **Antigravity**: `plugin.json` を主マニフェストとして skills / agents を同梱。旧 Gemini CLI 互換の `gemini-extension.json` は残すが、主経路ではない。ローカルに `agy` が無いため実機検証は未実施。

## インストール

### Codex (プラグイン — 推奨)

```bash
codex plugin marketplace add <このフォルダのパス>     # または GitHub の owner/repo
# → プラグイン一覧から yt-quality-loop をインストール
```

リポジトリ同梱の `.agents/plugins/marketplace.json` が `codex-plugin/` を指しています。

Codex には 2 つの使い方があります。

| スキル | 使う場面 | 特徴 |
|---|---|---|
| `$yt-loop-hook` | Codex プラグインの hooks を信頼済み | Stop hook が応答終了ごとに継続/終了を機械判定。Claude Code 版に近い |
| `$yt-loop` | hooks を信頼していない / スキル直接コピー | 1 応答内で loop-judge.sh を呼ぶフォールバック。Cursor/Antigravity と同じ運用 |

Codex の plugin hooks は、インストール/有効化だけでは自動信頼されません。Codex の hook UI または `/hooks` 相当の確認画面で `yt-quality-loop` の hook 定義を確認して信頼してください。信頼しない場合は `$yt-loop` を使います。

Codex custom agent を直接使いたい場合は、フォールバックインストーラが `codex/agents/yt_quality_evaluator.toml` を `~/.codex/agents/` に入れます。

### Cursor (プラグイン)

同梱の `.cursor-plugin/marketplace.json` + `cursor-plugin/` がマーケットプレイス形式です。`cursor-plugin/.cursor-plugin/plugin.json` は `skills: "./skills/"` と `agents: "./agents/"` を指します。チーム/個人マーケットプレイスに追加するか、`/add-plugin` から導入してください。

### Antigravity (実験的)

`antigravity-plugin/` を Antigravity のプラグインとして配置します。`plugin.json` が主マニフェスト、`gemini-extension.json` は旧 Gemini CLI 互換の保険です。ローカル環境に `agy` が無いため、このパッケージは JSON/構造検証までで、実機インストール検証は未実施です。動かない場合は下のスキル直接コピーを使ってください。

### スキル直接コピー (全環境共通のフォールバック)

```bash
bash codex/install-skills.sh all          # Codex(グローバル) + Cursor/Antigravity(現在のフォルダ)
# 個別: bash codex/install-skills.sh codex | cursor | antigravity [プロジェクトパス]
```

| 環境 | インストール先 | 呼び出し方 |
|---|---|---|
| 環境 | インストール先 | 呼び出し方 |
|---|---|---|
| Codex CLI | `~/.agents/skills/` + `~/.codex/agents/` | `$yt-loop 台本: ○○ (threshold: 90)` |
| Cursor | `<プロジェクト>/.cursor/skills/` + `.cursor/agents/` | 「yt-loop で台本を合格まで磨いて: ○○」 |
| Antigravity | `<プロジェクト>/.agent/skills/` + `.agent/agents/` | 同上 |

## 採点の独立性について

採点は上から順の 3 段構えです:

1. **サブエージェント / custom agent (第1手段)** — Codex・Cursor・Antigravity の子エージェントを fresh context の採点係として使う。採点後に `mark-fresh.sh` で証明マーカー (`turn-NNN-eval.fresh`) を残す
2. **codex exec 子プロセス (第2手段)** — `fresh-eval.sh` が実行し、マーカーも自動で残る
3. **自己採点 (最終手段・原則不使用)** — 上記 2 つが使えない環境のみ。マーカーは残さない (偽造禁止) ため judge が `SELF-SCORED` と表示し、最終報告で必ず開示される。これは「Codex が普通に自己採点する」という意味ではなく、fresh 採点に落ちた時の事故開示

マーカーは同一権限で動く以上「壁」ではなくトリップワイヤです。目的は「黙って自己採点で通す」を正規手順から排除することです。

## 無人実行 (最も厳密な構成)

生成も採点も毎回まっさらな `codex exec` プロセスで実行します:

```bash
bash codex/yt-loop-runner.sh "AI初心者向け『ChatGPTの始め方』10分動画の台本" 90 6 "冒頭フック,視聴維持設計,構成の明確さ,具体性と信頼性,CTAと導線"
```

停止条件は Claude Code 版と同じ 4 つ (合格 / 回数 / 時間 / 進捗ゼロ)。`.yt-loop/channel-profile.md` があれば自動で同梱されます。

## デモと検証

- 運営者向けの説明デモ: `docs/demo-youtube-script-loop.md`
- 配布前チェックリスト: `docs/e2e-checklist.md`
- 静的検証: `bash scripts/validate-packages.sh`
- Hook 状態遷移スモーク: `bash scripts/e2e-smoke.sh`

## 開発者向け

正本:

- `codex/skills/yt-loop/`: hook を使わない全環境フォールバック
- `codex/skills/yt-loop-hook/`: Codex Stop hook 駆動
- `agents/`: Cursor / Antigravity の evaluator agent
- `codex/agents/`: Codex custom agent
- `plugins/yt-quality-loop/scripts/`: Claude Code / Codex hook 駆動ループ制御

編集したらリポジトリ直下で `bash sync-packages.sh` を実行して各プラグインパッケージ (codex-plugin / cursor-plugin / antigravity-plugin) に同期してください。

Codex hook 駆動は、Claude Code 用 `loop-start.sh` / `loop-control.sh` / `validate-eval.sh` / `fingerprint.sh` を `codex-plugin/scripts/` に同期して使います。Codex 公式 docs 上、plugin hooks には `PLUGIN_ROOT` と互換用 `CLAUDE_PLUGIN_ROOT` が渡り、Stop hook は JSON の `decision: "block"` で継続できます。
