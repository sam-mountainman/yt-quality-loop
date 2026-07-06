---
name: yt-loop-hook
description: Codex の Stop hook で YouTube 品質ループを回す。Claude Code 版に近い無人ループが必要な時に使う。通常の $yt-loop より hook 信頼設定が必要。
---

# YT Quality Loop Hook (Codex)

Codex の Stop hook を使って、YouTube 向け成果物を **作る → 採点する → 直す** で合格点まで回します。続行/終了の判定は Stop hook と `scripts/loop-control.sh` が行います。あなたはオーケストレーターです。

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

プリセット:

- 長尺台本: `冒頭フック,視聴維持設計,構成の明確さ,具体性と信頼性,CTAと導線`
- ショート台本: `冒頭2秒フック,テンポ密度,オチとループ性,尺と文字数規律`
- タイトル・サムネ: `クリック誘引力,内容整合,検索・推薦適合,文字数と可読性`
- 企画: `ターゲット適合,差別化,需要の根拠,タイトル・サムネの立てやすさ`

`.yt-loop/briefs/` に動画ブリーフ (この動画の約束: 誰向け/約束する変化/絶対入れる話/絶対言わない話/視聴後の行動) があれば、生成と採点の両方で必ず参照する。台本系で無ければ task から 5 項目を埋めて作ってから回す (ループ中は書き換え禁止)。

`.yt-loop/channel-profile.md` があれば必ず読み、台本系は `冒頭フック,視聴維持設計,構成の型の遵守,口調・文体の一致,具体性と信頼性` を優先します。

## Step 2: Start State

UserPromptSubmit hook が `YT_LOOP_SESSION_ID=<id>` をコンテキストに注入します。見つからない場合は hook が未信頼または未ロードです。`$yt-loop` に切り替えるよう案内して止めます。

plugin root は次で決めます。

```bash
PLUGIN_ROOT_RESOLVED="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"
```

空なら hook 版は使えません。

開始:

```bash
bash "$PLUGIN_ROOT_RESOLVED/scripts/loop-start.sh" "$(pwd)" <max> <threshold> <YT_LOOP_SESSION_ID> --max-wall-minutes <max_wall>
```

出力の `State file:` から `STATE_FILE` を取得します。続けて task / criteria / runtime / evaluator を state に書き、ものさしの指紋を記録します。

```bash
jq --arg task "<task>" \
   --arg criteria "<criteria>" \
   --arg eval "yt_quality_evaluator" \
   '.task=$task | .criteria=$criteria | .runtime="codex-hook" | .evaluator_skill=$eval | .generator_skill="codex-inline-generator"' \
   "<STATE_FILE>" > "<STATE_FILE>.tmp" && mv "<STATE_FILE>.tmp" "<STATE_FILE>"
bash "$PLUGIN_ROOT_RESOLVED/scripts/fingerprint.sh" "<STATE_FILE>" --record
```

ユーザーには 1 行だけ見通しを出し、そのまま Step 3 へ進みます。

## Step 3: One Iteration

### 3a. Load State And Plan

`STATE_FILE` から `turns_dir`, `iteration`, `task`, `criteria` を読む。`turn-NNN-plan.md` に、Goal / Analysis / Changes / Self-check を書く。2 周目以降は前回 eval の feedback だけを使い、過去スコアは見ない。

### 3b. Generate Artifact

`turn-NNN-output.md` にそのまま使える完成版を書く。2 周目以降は前回成果物を土台にし、feedback に対応する変更だけを入れる。`.yt-loop/channel-profile.md` があれば、構成の型・口調・NGリストを守る。

生成にサブエージェントを使う場合は、task、plan、前回成果物パス、profile パス、出力先 `turn-NNN-output.md` だけを渡し、「それ以外のファイルは触らない」と指示する。

### 3c. Mechanical Check

`<project>/.yt-loop/mechanical-checks.json` があれば:

```bash
bash "$PLUGIN_ROOT_RESOLVED/scripts/check-mechanical.sh" "$ARTIFACT_FILE" "$RULES"
```

NG の場合、evaluator を起動しない。`turn-NNN-eval.json` に mechanical NG と feedback を書き、`state.phase="eval"`, `mech_ng=true`, `evaluated_iteration=<ITER>`, `latest_score=null` にして応答終了。Stop hook が次周へ送る。

### 3d. Evaluate With Fresh Context

最優先は Codex subagent です。`yt_quality_evaluator` custom agent が利用できる場合はそれをスポーンします。使えない場合でも通常の subagent を fresh evaluator としてスポーンします。最後のフォールバックだけ `codex exec` 相当または自己採点にします。

サブエージェントに渡すもの:

- task 原文または task.md のパス
- criteria の固定キー
- 採点対象 `turn-NNN-output.md`
- eval JSON 出力先 `turn-NNN-eval.json`
- profile パスがある場合のみ
- fresh marker コマンド: `bash "$PLUGIN_ROOT_RESOLVED/scripts/mark-fresh.sh" <TURNS_DIR> <NNN>` に相当する、同梱またはスキル版の marker コマンド

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
bash "$PLUGIN_ROOT_RESOLVED/scripts/validate-eval.sh" "$EVAL_FILE" "-" "$THRESHOLD" "$CRITERIA"
```

通ったら `latest_score`, `phase="eval"`, `evaluated_iteration`, `best_score`, `best_iteration`, `artifact_hashes[NNN]` を更新して 1-2 行で応答終了します。合否判定は Stop hook に任せます。

## Step 4: Stop Hook Final Block

Stop hook が `[YT-loop iteration ENDED: ...]` を返したら、指示どおりベスト成果物を `./yt-loop-output-<datetime>.md` にコピーし、日本語で次を報告します。

まず、終了指示に含まれる `STATE_FILE` を使って次を実行します。

```bash
bash "$PLUGIN_ROOT_RESOLVED/scripts/final-report.sh" "<STATE_FILE>"
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
