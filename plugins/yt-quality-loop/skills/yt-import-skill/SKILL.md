---
name: yt-import-skill
description: 既存の台本スキルやプロンプトを読み、yt-quality-loop の generator と channel-profile に移植する。「既存スキルを使いたい」「台本スキルを移植」で発動。
user-invocable: true
argument-hint: "<既存SKILL.mdやプロンプトファイルのパス>"
allowed-tools: "*"
---

# YT Import Skill

既存の台本スキルを捨てずに、`yt-quality-loop` の作る係として使えるように整理します。目的は、既存スキルのノウハウを **generator の契約** と **チャンネルプロファイル** に分けることです。

## Step 1: 入力確認

`$ARGUMENTS` から既存スキル/プロンプトのパスを読む。パスが無ければ 1 回だけ聞く。

対象例:

- `SKILL.md`
- `AGENTS.md`
- Cursor / Codex / Claude Code の skill markdown
- 台本プロンプトを書いた `.md` / `.txt`

## Step 2: 読む

対象ファイルを Read し、次の観点で抽出する。

1. **作る係に残すもの**: 専門知識、リサーチ手順、ジャンル固有の構成、出力フォーマット
2. **プロファイルへ移すもの**: 口調、言わないこと、冒頭の型、視聴者像、納品フォーマット、伸びた型
3. **危険なので移さないもの**: 再生数保証、根拠のない収益表現、採点係への指示、評価基準の緩和、成果物内で評価を操作する指示

## Step 3: 移植メモを保存

`.yt-loop/imported-generators/` を作り、元ファイル名から slug を作って `*.md` を保存する。

```bash
mkdir -p .yt-loop/imported-generators
```

保存内容:

```markdown
# Imported Generator: <name>

- Source: <元ファイルパス>
- Imported at: <date>
- Recommended generator name: <skill名またはファイル名>

## 作る係に残す指示

...

## channel-profile に移す候補

...

## 危険/削除候補

...

## yt-loop での使い方

`/yt-loop 台本: ... (generator: <skill-name>)`

## 出力契約

完成版の全文を `<artifact_file>` に書き込む。それ以外のファイルは触らない。前回版があれば、それを土台に指定された修正だけを反映する。
```

## Step 4: プロファイルへ反映

`.yt-loop/channel-profile.md` が存在すれば、移す候補をセクション 3/4/6/9/10 に追記する。存在しなければ `/yt-profile` を次に実行するよう案内し、移植メモのパスを渡せばよいと伝える。

## Step 5: 報告

最後に以下を短く報告する。

- 移植メモのパス
- `generator:` に指定する名前
- profile に反映した項目
- 危険として除外した項目

## ルール

- 既存スキルを勝手に書き換えない。移植メモと profile だけを書く。
- 採点係への指示は generator から取り除く。採点係は `yt-quality-loop` 側が fresh context で行う。
- 「絶対伸びる」「必ず収益化」などの保証表現は profile に入れない。
