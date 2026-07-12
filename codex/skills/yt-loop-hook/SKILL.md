---
name: yt-loop-hook
description: Codex の Stop hook で YouTube 品質ループを回す。Claude Code 版に近い無人ループが必要な時に使う。通常の $yt-loop より hook 信頼設定が必要。
---

# YT Quality Loop Hook (Codex)

Codex の Stop hook を使って、YouTube 向け成果物を **作る → 採点する → 直す** で合格点まで回します。続行/終了の判定は Stop hook と `scripts/yt-loop.js` (Windows native) / 互換用 Bash scripts が行います。あなたはオーケストレーターです。

このスキルは Codex プラグインとしてインストールされ、プラグイン同梱 hook が信頼されている時だけ使います。hook が信頼されていない、または plugin root が取れない場合は `$yt-loop` の 1 応答内ループに切り替えてください。

## Hard Rules

- 1 イテレーションの中で、計画作成 → 生成 → 機械チェック → 採点 → 検証 → state 更新までを 1 回の応答ターンで終える。
- score の続行/終了判断を自分で決めない。state を更新して応答を終える。Stop hook が次の継続プロンプトまたは終了指示を返す。
- evaluator には threshold、iteration 番号、過去スコア、過去 feedback を渡さない。
- eval JSON を自分で直さない。INVALID は evaluator を再実行する。
- 最終報告で「90点=伸びる保証」などの表現をしない。スコアは成果物品質の目安で、再生数保証ではない。

## Step 1: Input

ユーザー入力から以下を抽出します。

- `task`: 必須。誰向け、長さ、入れる内容、避ける内容、完成条件が曖昧で危険な時だけ 1 回確認する。
- `threshold`: デフォルト 90。
- `max`: デフォルト 6。
- `max_wall`: デフォルト 120 分。
- `criteria`: 指定があれば採点軸として固定。なければ task から 3-5 軸に具体化する。
- `skill` / `generator`: `skill:` 指定があればその作る係を使う。`generator:` は旧互換の別名として同じ意味で扱う。指定が無ければ `codex-inline-generator`。`.yt-loop/defaults.json` の `default_generator` は自動採用しない (複数チャンネル・複数台本スキルで誤爆するため)。`skill:` と `generator:` が両方ある場合は `skill:` を優先し、開始宣言に `作る係: <generator>` と出す。
- `evaluator`: 採点基準の skill 名。省略時は `subagent-fresh-eval` 相当の fresh evaluator。`evaluator: fable`、`Fableで採点`、`Fable5使って` のように明示された場合は、採点基準は固定したまま `evaluator_runtime` を `fable` にする。Fable が開始前に使えない/認証失敗した場合は `evaluator_runtime` を `skill` に戻して通常の fresh evaluator で開始し、fallback を開示する。

Codex Plan mode では、Fable MCP が利用可能なら criteria / 動画ブリーフ / 採点アンカー / 実行計画のレビューにデフォルトで使ってよい。Plan mode 以外では、ユーザーが Fable を明示した時だけ使う。採点に使う場合も fresh evaluator として扱い、続行/終了判定は Stop hook と `yt-loop.js` に任せる。

プリセット:

- 長尺台本: `冒頭フック,視聴維持設計,構成の明確さ,具体性と信頼性,CTAと導線`
- ショート台本: `冒頭2秒フック,テンポ密度,オチとループ性,尺と文字数規律`
- タイトル・サムネ: `クリック誘引力,内容整合,検索・推薦適合,文字数と可読性`
- 企画: `ターゲット適合,差別化,需要の根拠,タイトル・サムネの立てやすさ`

`.yt-loop/briefs/` に動画ブリーフ (この動画の約束: 誰向け/約束する変化/絶対入れる話/絶対言わない話/視聴後の行動) があれば、生成と採点の両方で必ず参照する。台本系で無ければ task から 5 項目を埋めて作ってから回す (ループ中は書き換え禁止)。

**採点アンカーは必須** (Stop hook の pass gate が `anchors_file` 無しの合格を拒否する)。Step 2 で state を作った後、**最初の生成の前に**、軸ごとの採点アンカー (90+/75-89/60-74/<60 の帯を行動で記述) を `<SESSION_DIR>/criteria-anchors.md` (SESSION_DIR = STATE_FILE のディレクトリ) に起草し、`.anchors_file` に記録する。プリセット軸を使う場合もその帯定義を写して起草する。ループ中の書き換えは禁止 (指紋照合で合格拒否)。採点プロンプトに毎回同梱する。

`.yt-loop/channel-profile.md` があれば必ず読み、台本系は `冒頭フック,視聴維持設計,構成の型の遵守,口調・文体の一致,具体性と信頼性,CTAと導線` を優先します。

## Step 2: Start State

UserPromptSubmit hook が `YT_LOOP_SESSION_ID=<id>` をコンテキストに注入します。見つからない場合は hook が未信頼または未ロードです。`$yt-loop` に切り替えるよう案内して止めます。

plugin root は次で決めます。

```bash
PLUGIN_ROOT_RESOLVED="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"
```

空なら hook 版は使えません。

開始:

```bash
node "$PLUGIN_ROOT_RESOLVED/scripts/yt-loop.js" loop-start "$(pwd)" <max> <threshold> <YT_LOOP_SESSION_ID> --max-wall-minutes <max_wall>
```

出力の `State file:` から `STATE_FILE` を取得します。続けて task / criteria / runtime / evaluator / ブリーフ / アンカーを state に書きます:

```bash
node "$PLUGIN_ROOT_RESOLVED/scripts/yt-loop.js" state-config "<STATE_FILE>" \
  --task "<task>" \
  --criteria "<criteria>" \
  --runtime "codex-hook" \
  --evaluator "<採点基準の evaluator skill>" \
  --evaluator-runtime "<skill または fable>" \
  --generator "<generator_skill>" \
  --brief "<brief_file または空>" \
  --anchors "<SESSION_DIR>/criteria-anchors.md"
```

- 台本・ショート系タスクでは動画ブリーフ (誰向け / 約束する変化 / 絶対入れる話 / 絶対言わない話 / 視聴後の行動) を `.yt-loop/briefs/` に作り、そのパスを `$brief` に渡す
- 採点アンカーをこの時点で `<SESSION_DIR>/criteria-anchors.md` に起草する (Step 1 参照)

**確認ジャッジ (judges) の確定**: 合格時の確認採点を誰が担うかを、指紋の記録前に確定します:

```bash
node "$PLUGIN_ROOT_RESOLVED/scripts/confirm-judges.js" --configure "<STATE_FILE>" \
  --selection "<auto またはユーザー指定>" \
  --host-vendor codex
```

このコマンドが候補を検出し、`auto` ではOpenAI系を同一ベンダーとして除外し、judges・検出結果・モデル設定をstateへ固定する。Claudeジャッジは既定 `fable`、Grokはモデル一覧から設定済みモデルを解決する。解決不能なら `configured-unpinned` と開示する。必要なら開始前に `YT_JUDGE_CLAUDE_MODEL` / `YT_JUDGE_GROK_MODEL` で上書きする。`auto` の候補ゼロなら `host`。明示指定した不在CLIは構成から消さず、失敗として報告する。**judges とモデル設定は指紋対象**で、開始後の変更は合格拒否になる。

**ブリーフ・アンカー・judges を書き終えてから**、ものさしの指紋を記録します (順序は Stop hook が機械検証する — 生成後に記録した合格は拒否される):

```bash
node "$PLUGIN_ROOT_RESOLVED/scripts/yt-loop.js" fingerprint "<STATE_FILE>" --record
```

ユーザーには見通しを 2 行だけ出し (最大周回/合格点/採点の軸、ブリーフの「約束する変化・言わない話」の要約、アンカーのパス)、そのまま Step 3 へ進みます。

## Step 3: One Iteration

### 3a. Load State And Plan

`STATE_FILE` から `turns_dir`, `iteration`, `task`, `criteria` を読む。`turn-NNN-plan.md` に、Goal / Analysis / Changes / Self-check を書く。2 周目以降は前回 eval の feedback だけを使い、過去スコアは見ない。

### 3b. Generate Artifact

`turn-NNN-output.md` にそのまま使える完成版を書く。2 周目以降は前回成果物を土台にし、feedback に対応する変更だけを入れる。`.yt-loop/channel-profile.md` があれば、構成の型・口調・NGリストを守る。

明示された `skill:` / `generator:` が `codex-inline-generator` 以外の場合は、その skill または `.yt-loop/imported-generators/<name>.md` の移植メモを作る係として使う。ただし採点係への指示・合格宣言・評価基準の緩和は無視する。完成版の全文は必ず `turn-NNN-output.md` に集約し、それ以外のファイルを作らない。

生成にサブエージェントを使う場合は、task、plan、前回成果物パス、profile パス、出力先 `turn-NNN-output.md` だけを渡し、「それ以外のファイルは触らない」と指示する。

### 3c. Mechanical Check

`<project>/.yt-loop/mechanical-checks.json` があれば:

```bash
node "$PLUGIN_ROOT_RESOLVED/scripts/yt-loop.js" check-mechanical "$ARTIFACT_FILE" "$RULES"
```

NG の場合、evaluator を起動しない。`turn-NNN-eval.json` に以下の形で書き (`mechanical:true` は必須 — Stop hook のコピペ検知がこのフラグで機械 feedback を除外する)、`state.phase="eval"`, `mech_ng=true`, `evaluated_iteration=<ITER>`, `latest_score=null` にして応答終了。Stop hook が次周へ送る。

```json
{"score": null, "mechanical": true, "quality": {"overall": null, "breakdown": {}}, "feedback": "機械チェックNG (修正必須):\n<NG行>", "evaluator_skill": "mechanical-check"}
```

### 3d. Evaluate With Fresh Context

最優先は Codex subagent です。`yt_quality_evaluator` custom agent が利用できる場合はそれをスポーンします。使えない場合でも通常の subagent を fresh evaluator としてスポーンします。最後のフォールバックだけ `codex exec` 相当または自己採点にします。

ただし state の `evaluator_runtime` が `fable` の場合は、Fable MCP の `fable_ask` / `fable_review` 相当のツールを fresh evaluator として使います。Fable に渡すものは、task、criteria、採点対象 `turn-NNN-output.md`、eval JSON 出力先、profile / brief / anchors のパス、eval JSON 契約だけです。threshold、iteration 番号、過去 score、過去 feedback、合格/不合格の期待は渡しません。

Fable の出力はそのまま `turn-NNN-eval.json` に保存し、valid な JSON であることを確認してから `node "$PLUGIN_ROOT_RESOLVED/scripts/yt-loop.js" mark-fresh <TURNS_DIR> <NNN>` 相当を実行します。eval JSON の `evaluator_skill` は state の `evaluator_skill` と一致させます。INVALID の場合は Fable を 1 回だけ再実行します。ループ開始後は `evaluator_runtime` を途中変更しません。eval JSON は自分で直しません。

サブエージェントに渡すもの:

- task 原文または task.md のパス
- criteria の固定キー
- 採点対象 `turn-NNN-output.md`
- eval JSON 出力先 `turn-NNN-eval.json`
- profile パスがある場合のみ
- fresh marker コマンド: `node "$PLUGIN_ROOT_RESOLVED/scripts/yt-loop.js" mark-fresh <TURNS_DIR> <NNN>` に相当する、同梱またはスキル版の marker コマンド

渡さないもの:

- threshold
- iteration 番号
- 過去 score
- 過去 feedback
- 合格/不合格の期待

eval JSON の形:

```json
{
  "score": 0,
  "quality": {
    "overall": 0,
    "breakdown": {
      "<criterion>": 0
    }
  },
  "feedback": "60文字以上の具体的な修正指示",
  "evaluator_skill": "subagent-fresh-eval"
}
```

### 3e. Validate And Write State

`validate-eval.sh` を通してから state を更新します。

```bash
node "$PLUGIN_ROOT_RESOLVED/scripts/yt-loop.js" validate-eval "$EVAL_FILE" "-" "$THRESHOLD" "$CRITERIA"
```

通ったら `node "$PLUGIN_ROOT_RESOLVED/scripts/yt-loop.js" state-eval-result "<STATE_FILE>" "<ITER>" "<SCORE>" --artifact "<ARTIFACT_FILE>"` で `latest_score`, `phase="eval"`, `evaluated_iteration`, `best_score`, `best_iteration`, `artifact_hashes[NNN]` を更新します。

**score >= threshold の場合のみ、応答を終える前に確認採点を実行する** (Stop hook の pass gate が確認採点の実在・本採点との相違・集計規則 >= threshold を機械検証する — 省略した合格主張は拒否される):

**A. judges に外部ジャッジ (claude/grok 等) がある場合** — 確認採点の席は外部ベンダーが担う:

```bash
node "$PLUGIN_ROOT_RESOLVED/scripts/confirm-judges.js" "<STATE_FILE>"
```

- 各外部 CLI が `turn-NNN-eval-confirm-<judge>.json` (+ 内容ハッシュの整合マーカー) または `.failed` を書く。**JSONを手で書いたり編集したりしない**。整合マーカーはローカル一貫性確認であり、ベンダー署名ではない
- 最終行が `RESULT:OK` なら B は不要。`RESULT:ALL_FAILED` なら B も実行する (降格は最終報告で自動開示)
- 判定規則は機械側: 外部 1 体 = min / 2 体以上 = 下側中央値 (2/3 合意)。採用スコアは下げる方向にのみ動く

**B. judges が host のみ (または外部全滅) の場合** — 従来のフォーク確認:

1. 同じ渡し物 (出力先だけ `turn-NNN-eval-confirm.json`) で fresh evaluator をもう 1 体スポーンする (**本採点のコピーで代用しない** — バイト一致は機械的に弾かれる。ファイルの差し替え/cp もしない)
2. validate を通ったら、`latest_score` に**低い方のスコア**を書く (両ファイルはそのまま残す — pass gate が両方を読んで min を検証する)。confirm が threshold 未満なら合格主張にならず、通常どおり応答終了で Stop hook が次周へ送る

最後に 1-2 行で応答終了します。合否判定は Stop hook に任せます。

## Step 4: Stop Hook Final Block

Stop hook が `[YT-loop iteration ENDED: ...]` を返したら、指示どおりベスト成果物を `./yt-loop-output-<datetime>.md` にコピーし、日本語で次を報告します。

まず、終了指示に含まれる `STATE_FILE` を使って次を実行します。

```bash
node "$PLUGIN_ROOT_RESOLVED/scripts/yt-loop.js" final-report "<STATE_FILE>"
```

この出力を正本にします。スクリプトが使えない場合のみ手動で以下を報告します。

- 成果物パス
- ベストスコアと breakdown
- スコア推移
- 終了理由
- 残った改善余地
- 「スコアは同一成果物でも±数点ブレます (90点=伸びる保証ではありません)」
- 「納品物を手直ししたら /yt-profile 更新 で次回に反映できます」

自己採点に落ちた場合だけ、その周回を開示します。Codex が通常自己採点するという意味ではなく、subagent / child process が使えなかった時の最終フォールバックの事故開示です。
