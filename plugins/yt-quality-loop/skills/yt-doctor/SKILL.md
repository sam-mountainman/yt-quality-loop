---
name: yt-doctor
description: yt-quality-loop のセットアップ診断。「動かない」「ループが続かない」「セットアップ確認」「診断して」で発動。
user-invocable: true
allowed-tools: Bash, Read
---

# YT Doctor

インストール直後の確認や「ループが動かない」時の切り分けを行います。

## Step 1: hook の注入確認

このコンテキストに `YT_LOOP_SESSION_ID=` の行が注入されているか確認する。

- **ある** → hook は動いている。Step 2 へ
- **ない** → プラグインの hook が動いていない。以下を案内する:
  1. `/plugin` で yt-quality-loop がインストール済み・有効か確認
  2. インストール直後なら Claude Code を再起動 (hook は再起動後に有効になる)
  3. それでも出なければ `claude plugin validate <プラグインのパス> --strict` の結果を確認

## Step 2: 環境診断スクリプトの実行

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh .
```

出力をそのままユーザーに見せる。

## Step 3: 結果の案内

- **× がある** → 各項目の直し方を具体的に案内する (× の行に対処法が書いてある)
- **! (実行中ループ) がある** → 意図したものか確認し、不要なら `/yt-loop-cancel` を案内
- **すべて ○/△** → 「準備OKです。`/yt-loop <作りたいもの>` から始められます。台本なら先に `/yt-profile` を作るのがおすすめです」と伝える

△ は任意項目なので、直さなくても動く。押し付けない。
