# 既存の台本スキルを活かす方法

すでに自分用の台本スキル、プロンプト、Claude/Codex/Cursor の Skill を持っている運営者向けの説明です。

結論: 既存スキルは捨てません。`yt-quality-loop` の **作る係** として使い、採点・差し戻し・合格判定だけをループ側に任せます。

## 使い方

```text
/yt-loop 台本: 新NISAの解説 10分 (generator: my-script-skill)
```

ただし、毎回書く必要はありません。`/yt-import-skill` を一度実行すると、既定 generator が `.yt-loop/defaults.json` に保存されます。以後は普通に:

```text
/yt-loop 台本: 新NISAの解説 10分
```

だけで、その generator が自動で使われます。

今回だけ別の generator を使う時:

```text
/yt-loop 台本: 新NISAの解説 10分 (generator: other-script-skill)
```

今回だけ標準 generator に戻す時:

```text
/yt-loop 台本: 新NISAの解説 10分 (generator: assign-yt-generator)
```

この時の分担:

- `my-script-skill`: 台本を書く
- `assign-yt-*-evaluator`: 台本を採点する
- `loop-control.sh`: 続行/終了を整数比較で決める
- `.yt-loop/channel-profile.md`: チャンネルらしさの基準を渡す

## 既存スキルが守るべき出力契約

既存スキルには、ループから次の指示が渡されます。

```text
完成版の全文を <artifact_file> に書き込むこと。
それ以外のファイルは作成・変更しないこと。
前回版がある場合は、それを土台に指定された修正だけを反映すること。
途中で質問せず最後まで自走すること。
```

この契約を守れないスキルは、最終的に標準 generator へフォールバックされます。フォールバックされた場合は最終報告に明記します。

## 移植すると強い情報

既存スキルの中で、次の情報は `/yt-profile` に移すと効果が高いです。

- 冒頭の型
- セクション構成
- よく使う言い回し
- 絶対に使わない言葉
- 視聴者の前提知識
- 過去に伸びた台本の共通点
- 投稿者が言いたくない主張
- 納品フォーマット

逆に、次の情報はスキル側に残しても構いません。

- 特定ジャンルの専門知識
- 事実確認の手順
- リサーチの手順
- 画像生成や編集など、台本以外の制作工程

## おすすめ構成

```text
my-script-skill       = 専門知識と書き方
.yt-loop/profile     = チャンネルらしさ
yt-quality-loop      = 採点・差し戻し・停止判定
```

こう分けると、既存スキルを配布せずに、運営者ごとのノウハウを守ったまま品質ループだけ共有できます。
