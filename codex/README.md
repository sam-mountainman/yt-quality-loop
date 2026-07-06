# Codex / Cursor / Antigravity で yt-quality-loop を使う

Claude Code 以外の 3 環境向けのガイドです。ループの仕組みは共通: **作る → 採点 (まっさらな別の頭) → `loop-judge.sh` の整数比較で続行判定**。これらの環境には Claude Code の Stop hook が無いため、ループは 1 つの応答の中で回ります。

## インストール

### Codex (プラグイン — 推奨)

```bash
codex plugin marketplace add <このフォルダのパス>     # または GitHub の owner/repo
# → プラグイン一覧から yt-quality-loop をインストール
```

リポジトリ同梱の `.agents/plugins/marketplace.json` が `codex-plugin/` を指しています。

### Cursor (プラグイン)

同梱の `.cursor-plugin/marketplace.json` + `cursor-plugin/` がマーケットプレイス形式です。チーム/個人マーケットプレイスに追加するか、`/add-plugin` から導入してください (Cursor 2.5 以降)。

### Antigravity (実験的)

`antigravity-plugin/` を Antigravity のプラグイン (旧 Gemini CLI 拡張) として配置します。マニフェスト形式は公式ドキュメントで要確認 — 動かない場合は下のスキル直接コピーを使ってください。

### スキル直接コピー (全環境共通のフォールバック)

```bash
bash codex/install-skills.sh all          # Codex(グローバル) + Cursor/Antigravity(現在のフォルダ)
# 個別: bash codex/install-skills.sh codex | cursor | antigravity [プロジェクトパス]
```

| 環境 | インストール先 | 呼び出し方 |
|---|---|---|
| Codex CLI | `~/.agents/skills/` | `$yt-loop 台本: ○○ (threshold: 90)` |
| Cursor | `<プロジェクト>/.cursor/skills/` | 「yt-loop で台本を合格まで磨いて: ○○」 |
| Antigravity | `<プロジェクト>/.agent/skills/` | 同上 |

## 採点の独立性について

採点は上から順の 3 段構えです:

1. **サブエージェント (第1手段)** — Codex ([subagents](https://developers.openai.com/codex/subagents))・Cursor ([subagents](https://cursor.com/docs/subagents))・Antigravity (Gemini CLI 由来) のネイティブなサブエージェントは fresh context で走るため、ループの経緯を知らない採点係になれる。採点後に `mark-fresh.sh` で証明マーカー (`turn-NNN-eval.fresh`) を残す
2. **codex exec 子プロセス (第2手段)** — `fresh-eval.sh` が実行し、マーカーも自動で残る
3. **自己採点 (最終手段・原則不使用)** — 上記 2 つが使えない環境のみ。マーカーは残さない (偽造禁止) ため judge が `SELF-SCORED` と表示し、最終報告で必ず開示される。自己採点は甘くなりがち — ここに落ちる環境なら無人ランナーの利用を推奨

マーカーは同一権限で動く以上「壁」ではなくトリップワイヤです (黙って自己採点で通す、を正規手順から排除するためのもの)。

## 無人実行 (最も厳密な構成)

生成も採点も毎回まっさらな `codex exec` プロセスで実行します:

```bash
bash codex/yt-loop-runner.sh "AI初心者向け『ChatGPTの始め方』10分動画の台本" 90 6 "冒頭フック,視聴維持設計,構成の明確さ,具体性と信頼性,CTAと導線"
```

停止条件は Claude Code 版と同じ 4 つ (合格 / 回数 / 時間 / 進捗ゼロ)。`.yt-loop/channel-profile.md` があれば自動で同梱されます。

## 開発者向け

スキルの正本は `codex/skills/yt-loop/` です。編集したらリポジトリ直下で `bash sync-packages.sh` を実行して各プラグインパッケージ (codex-plugin / cursor-plugin / antigravity-plugin) に同期してください。
