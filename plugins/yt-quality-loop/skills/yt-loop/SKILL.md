---
name: yt-loop
description: YouTube向け成果物 (台本 / ショート台本 / タイトル・サムネ案 / 概要欄など) を、品質スコアが合格点に達するまで自動改善ループで作り込みたい場面で発動。「品質ループ」「合格まで磨いて」で発動。
user-invocable: true
argument-hint: "<作りたいものの説明> [threshold: 90] [max: 6] [criteria: 軸1,軸2,...]"
allowed-tools: "*"
---

# YT Quality Loop

あなたはオーケストレーターです。計画を自分で書き、assign-yt-generator (作る係) → assign-yt-evaluator 系 (採点する係) の 2 フェーズを制御し、品質基準を満たすまでループします。続行/終了の判定はあなたの仕事ではありません — Stop hook (シェルの整数比較) が行います。

**絶対ルール: 1 イテレーション内の全フェーズ (計画作成 → generator → evaluator → 検証 → スコア更新) は、1 回の応答ターンで途切れなく実行すること。フェーズ間でテキストだけ出力して応答を終了してはならない。**

## Step 1: 入力解析

ユーザーの入力 `$ARGUMENTS` から以下を抽出:

| 項目 | デフォルト | 説明 |
|------|-----------|------|
| **task** | (必須) | 作りたいものの説明。曖昧なら質問して具体化する |
| **threshold** | 90 | 合格点 (0-100) |
| **max** | 6 | 最大イテレーション回数 |
| **max_wall** | 120 (分) | 時間の上限 |
| **criteria** | evaluator 準拠 | 採点軸 (カンマ区切り、自由指定時のみ) |
| **evaluator** | 自動選択 | 採点する係の skill 名 (明示指定も可) |
| **generator** | `.yt-loop/defaults.json` の `default_generator`、無ければ `assign-yt-generator` | 作る係の skill 名。**ユーザーの既存の台本スキル名を指定できる** (例: `generator: my-script-skill`)。既存スキルはそのまま「作る係」の席に座り、採点と差し戻しはループが行う |

**既定 generator の検出**: ユーザーが `generator:` を明示しない場合、`.yt-loop/defaults.json` を読む。`default_generator` が non-empty ならそれを generator として使う。これにより、既存台本スキルを毎回 `(generator: ...)` と書く必要はない。

```bash
[ -f .yt-loop/defaults.json ] && jq -r '.default_generator // empty' .yt-loop/defaults.json || true
```

明示された `generator:` は常に defaults より優先する。今回だけ標準 generator に戻したい場合は `generator: assign-yt-generator` と指定する。ループ開始宣言には、既定 generator を使った場合も `作る係: <generator> (既定)` と出す。

**カスタム generator の red-flag 検査**: `generator:` が非デフォルトの場合、ループ開始前にそのスキルの SKILL.md 原本を grep で検査する:

```bash
grep -nE "採点|評価|eval|点数|基準を満た|クリア済|チェック済" "<そのスキルのSKILL.mdパス>" | head -5
```

ヒットがあれば開始宣言に 1 行警告を添える: 「⚠ このスキルには採点・評価に触れる指示が含まれます (該当行)。成果物に『基準クリア済み』等の注記を埋め込む指示は採点係が減点対象として扱います」。ヒットゼロなら何も言わない。

**チャンネルプロファイルの検出** (evaluator 選択の前に必ず確認):

```bash
[ -f .yt-loop/channel-profile.md ] && echo "PROFILE:$(pwd)/.yt-loop/channel-profile.md" || echo "PROFILE:none"
```

**evaluator の自動選択** (task の内容 + プロファイル有無から判定):

| task に含まれる内容 | evaluator | 採点軸 |
|---|---|---|
| 長尺動画の台本 + **プロファイルあり** | `assign-yt-channel-evaluator` | 固定 6 軸 (型遵守・口調一致を含む) |
| 長尺動画の台本・構成・トークスクリプト | `assign-yt-script-evaluator` | 固定 5 軸 (eval-schema.json) |
| ショート動画・Shorts・リール・60秒 | `assign-yt-shorts-evaluator` | 固定 4 軸 (eval-schema.json) |
| タイトル案・サムネ文言・サムネコピー | `assign-yt-title-evaluator` | 固定 4 軸 (eval-schema.json) |
| 企画・ネタ出し・動画アイデアのリスト | `assign-yt-planning-evaluator` | 固定 4 軸 (eval-schema.json) |
| それ以外 (概要欄・コミュニティ投稿など) | `assign-yt-evaluator` (汎用) | criteria から動的生成 |

台本系タスクでプロファイルが **ない** 場合は、ループ開始前に 1 行だけ案内する (ループは止めない):「先に `/yt-profile` でチャンネルプロファイルを作ると、"チャンネルらしさ" が採点軸に入ります」。ショート・タイトル系でもプロファイルがあれば、コンテキストに `profile_file` を渡す (口調・NG リストが generator と採点係に届く)。

汎用 evaluator を使う場合で criteria が未指定なら、task の性質に応じて 3-5 軸を自分で設定する (例: 概要欄なら「検索キーワード適合, 冒頭 2 行の要約力, リンク導線, 文字数規律」)。**「いい感じ」「良い」のような曖昧語を軸にしない。** アルバイトの人がチェックリストで○×を付けられる粒度、または観点として言語化された粒度に落とすこと。

**task の具体化**: task には「誰向けか / 長さ・分量 / 何を入れて何を入れないか / 何ができたら完成か」が含まれているのが理想。欠けていて推測が危うい場合のみユーザーに 1 回だけ確認する。

**動画ブリーフ (台本系タスクのみ)**: task が薄いままループに入ると「一般的に良い台本」に収束する。台本・ショート系タスクでは、ループ開始前にこの動画 1 本の設計書を `.yt-loop/briefs/` に固定する:

1. task に `brief: <パス>` の指定があればそれを使う
2. なければ、同梱の `brief-template.md` の 5 項目 (誰向け / 約束する変化 / 絶対入れる話 / 絶対言わない話 / 視聴後の行動) を task から埋める。**task から埋められるならユーザーに聞かずに自動生成してよい** (上の「1 回だけ確認」をこの 5 項目のヒアリングに充ててもよい)
3. `.yt-loop/briefs/$(date +%Y%m%d-%H%M)-<slug>.md` に Write し、そのパスを Step 2 で state に記録する

```bash
mkdir -p .yt-loop/briefs
cat "${CLAUDE_PLUGIN_ROOT}/skills/yt-loop/brief-template.md"
```

ブリーフは作る係と採点係の両方に渡る (「約束した変化を回収したか」「言わない話に触れていないか」が採点根拠になる)。タイトル・サムネ文言が既に決まっている場合は必ずブリーフに書く — 台本はその約束を回収する義務を負う。台本系以外 (概要欄・タイトル案など) ではブリーフは不要。

## Step 2: 初期化

UserPromptSubmit hook が `YT_LOOP_SESSION_ID=<id>` をコンテキストに注入しています。この値を使います。

**YT_LOOP_SESSION_ID が見つからない場合**: 「プラグインが正しくインストールされているか確認してください (/plugin で yt-quality-loop が有効か、/yt-doctor で診断)」と案内して停止。

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/loop-start.sh" "$(pwd)" <max> <threshold> <YT_LOOP_SESSION_ID>
```

ユーザーが max_wall を指定した場合のみ `--max-wall-minutes <N>` を末尾に付ける。cwd は必ず `$(pwd)` で明示する (hook はセッションの cwd から state を探すため、途中で cd しないこと)。

出力の **"State file:" の行から STATE_FILE のパスを取得して、以降すべてそのパスを使うこと。**

次に state.json に task / criteria / evaluator / generator / ブリーフを書き込む (**指紋の記録はまだしない** — アンカー起草の後):

```bash
jq --arg task "<task>" --arg criteria "<criteria>" --arg eval "<evaluator_skill>" --arg gen "<generator_skill>" --arg brief "<brief_file または空>" \
   '.task=$task | .criteria=$criteria | .evaluator_skill=$eval | .generator_skill=$gen | .brief_file=(if $brief == "" then null else $brief end)' \
   "<STATE_FILE>" > "<STATE_FILE>.tmp" && mv "<STATE_FILE>.tmp" "<STATE_FILE>"
```

generator / evaluator が未指定なら state.json のデフォルト値のまま (jq から省略してよい)。

**採点アンカーの起草 (汎用 evaluator = 自由 criteria の時は必須)**: 自作/自動設定した criteria には 90 点/75 点の目盛りが無く、採点が周回ごとにブレる。軸ごとの採点アンカーを起草して固定する (**Stop hook の pass gate は、汎用 evaluator でアンカー未設定の合格を拒否する**):

1. ユーザーが `anchors: <パス>` を指定していればそのファイルを使う (前回のアンカーの再利用)
2. なければ、各軸に 90+/75-89/60-74/<60 の帯を**観測可能な行動の記述**で書いたアンカーを起草し、`<SESSION_DIR>/criteria-anchors.md` に Write する (SESSION_DIR = STATE_FILE のあるディレクトリ。プリセット採点係の SKILL.md にあるアンカーが書き方の手本。形容詞は禁止)
3. `jq --arg a "<アンカーのパス>" '.anchors_file=$a' "<STATE_FILE>" > tmp && mv tmp "<STATE_FILE>"`

**起草は必ず最初の生成の前。** 一度でも生成が走った後にアンカーを書くと「今の成果物が高く出る目盛り」を引く誘惑が生まれる (記録時刻と最初の生成物の mtime は pass gate が機械照合する)。プリセット採点係 (script/shorts/title/planning/channel) はアンカー内蔵なので不要。

**ブリーフとアンカーを書き終えてから**、最後に指紋を記録する:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/fingerprint.sh" "<STATE_FILE>" --record
```

指紋は threshold・criteria・プロファイル・機械ルール・**ブリーフ・アンカー・採点係の定義 (SKILL.md/schema)** のハッシュで、**ループ中にものさしが変更されると Stop hook が合格を拒否する** (ブリーフの「絶対言わない話」を消す・アンカーやプリセットの目盛りを緩める、という抜け道も塞がれる)。record は一度しかできないので、必ずこの順序で実行すること。

最後に、ループを回し始める前にユーザーへ見通しを伝える (その後すぐ Step 3 のツール呼び出しへ進む — テキストだけで応答を終えない):

> ループ開始: 最大 <max> 周 / 合格点 <threshold> / 時間上限 <max_wall> 分。**作る係: <generator 名>{既定なら " (既定)"} / 採点係: <evaluator 名> (軸: <criteria>)** — 軸を変えるには `criteria:` 指定、チャンネル固有にするには /yt-profile。
> {ブリーフを作った場合: ブリーフ: <パス> — 約束する変化「<1行要約>」/ 絶対言わない話「<1行要約>」}
> {アンカーを起草した場合: 採点アンカー: <パス> (90点の目盛りはこのファイルで確認できます)}
> 1 周の目安は 10〜25 分 (プロファイル付き台本は長め)、多くは 2〜4 周で収束します。途中で止める: /yt-loop-cancel。ベスト版は必ず納品します。

固定軸 evaluator (script/shorts/title) を使う場合、criteria にはその evaluator の軸名をそのまま書く (eval-schema.json の breakdown_keys と一致させる)。

## Step 3: イテレーションプロトコル

**各イテレーションはオーケストレーターの計画作成から始まる。**

### 3a. 状態読み込み + 計画作成

```bash
STATE_FILE="<STATE_FILE>"
TURNS_DIR="$(jq -r '.turns_dir' "$STATE_FILE")"
ITER=$(jq -r '.iteration' "$STATE_FILE")
TASK=$(jq -r '.task' "$STATE_FILE")
CRITERIA=$(jq -r '.criteria' "$STATE_FILE")
PREV_EVAL=""
if [ "$ITER" -gt 0 ]; then
  PREV_ITER=$((ITER - 1))
  PREV_EVAL_FILE="$TURNS_DIR/turn-$(printf '%03d' $PREV_ITER)-eval.json"
  [ -f "$PREV_EVAL_FILE" ] && PREV_EVAL=$(cat "$PREV_EVAL_FILE")
fi
echo "ITER: $ITER"; echo "TASK: $TASK"; echo "CRITERIA: $CRITERIA"; echo "TURNS_DIR: $TURNS_DIR"
[ -n "$PREV_EVAL" ] && echo "PREV_EVAL: $PREV_EVAL"
```

**即座に Write ツールで計画ファイルを作成する:** `{TURNS_DIR}/turn-{NNN}-plan.md` (NNN = iteration の 3 桁ゼロパディング)

```markdown
## Goal
{このイテレーションで達成すること。1-2 文}

## Analysis
{iteration 0 なら task の要約。iteration > 0 なら eval feedback の要点と改善方針}

## Changes
- {変更 1}: {なぜ変えるのか}
- {変更 2}: {なぜ変えるのか}

## Self-check (generator の提出前チェック用 — evaluator の採点軸ではない)
- [ ] {チェック 1}
- [ ] {チェック 2}
```

計画のポイント:
- **iteration 0**: task と criteria から初期計画。
- **iteration > 0**: feedback を分析し、改善方針を書く。**task の本来の目的からの逸脱 (目標ドリフト) に注意** — 点稼ぎに寄った変更 (文字数の水増し、どうでもいい箇所の言い換え) を Changes に入れない。
- Self-check は generator の自己検査用。evaluator は task と criteria を主軸に絶対評価する。

### 3b. Generator 起動

**1 回の bash で phase 更新と generator コンテキストを作成:**

task 原文を必ず同梱する (目標再注入 — plan は task の派生物にすぎず、ドリフトを継承するため)。

```bash
STATE_FILE="<STATE_FILE>"
TURNS_DIR="$(jq -r '.turns_dir' "$STATE_FILE")"
ITER=$(jq -r '.iteration' "$STATE_FILE")
NNN=$(printf '%03d' $ITER)
SESSION_DIR="$(dirname "$STATE_FILE")"
PLAN_CONTENT=$(cat "$TURNS_DIR/turn-$NNN-plan.md")
ARTIFACT_FILE="$TURNS_DIR/turn-$NNN-output.md"
PREV_ARTIFACT=""
if [ "$ITER" -gt 0 ]; then
  PREV_ARTIFACT="$TURNS_DIR/turn-$(printf '%03d' $((ITER - 1)))-output.md"
fi
PROFILE_FILE=""
[ -f "$(jq -r '.project_dir' "$STATE_FILE")/.yt-loop/channel-profile.md" ] && PROFILE_FILE="$(jq -r '.project_dir' "$STATE_FILE")/.yt-loop/channel-profile.md"
BRIEF_FILE=$(jq -r '.brief_file // ""' "$STATE_FILE")

jq '.phase="plan"' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

jq -n \
  --arg project_dir "$(jq -r '.project_dir' "$STATE_FILE")" \
  --arg task "$(jq -r '.task' "$STATE_FILE")" \
  --arg plan "$PLAN_CONTENT" \
  --arg criteria "$(jq -r '.criteria' "$STATE_FILE")" \
  --argjson iteration "$ITER" \
  --arg turns_dir "$TURNS_DIR" \
  --arg artifact_file "$ARTIFACT_FILE" \
  --arg prev_artifact_file "$PREV_ARTIFACT" \
  --arg profile_file "$PROFILE_FILE" \
  --arg brief_file "$BRIEF_FILE" \
  '{project_dir:$project_dir, task:$task, plan:$plan, criteria:$criteria, iteration:$iteration, turns_dir:$turns_dir, artifact_file:$artifact_file, prev_artifact_file:(if $prev_artifact_file == "" then null else $prev_artifact_file end), profile_file:(if $profile_file == "" then null else $profile_file end), brief_file:(if $brief_file == "" or $brief_file == "null" then null else $brief_file end)}' \
  > "$SESSION_DIR/generator-context.json"
jq '.phase="generator"' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
GEN_SKILL=$(jq -r '.generator_skill // "assign-yt-generator"' "$STATE_FILE")
echo "GEN_SKILL:$GEN_SKILL"
echo "CONTEXT:$SESSION_DIR/generator-context.json"
```

**即座に Skill ツールで generator を起動:**

- **`GEN_SKILL` が `assign-yt-generator` の場合**: skill = GEN_SKILL、args = CONTEXT 行のパス。
- **それ以外 (ユーザーの既存スキル) の場合**: skill = GEN_SKILL、args は自然文で組み立てる (既存スキルは context JSON の契約を知らないため):

  ```
  <task 原文>
  {iteration > 0 なら: 前回版 <prev_artifact_file> を読み、それを土台に次の修正だけを反映すること:
  <plan の Changes の箇条書き>}
  {profile_file があれば: チャンネルプロファイル <profile_file> に従うこと。}
  完成版の全文を <artifact_file> に書き込むこと。それ以外のファイルは作成・変更しないこと。
  途中で質問せず最後まで自走すること。
  ```

- **カスタム generator の検収**: 完了後に `[ -s "<artifact_file>" ]` を確認する。空/不在なら、そのスキルが出力した成果物ファイルを特定して `cp` で artifact_file に集約する。特定もできなければ、このイテレーションに限り assign-yt-generator (context JSON) で作り直して続行し、最終報告に「カスタム generator が出力契約を守らなかった」と明記する。

### 3c-0. 機械チェック (`.yt-loop/mechanical-checks.json` がある場合のみ)

Generator 完了後、採点係に渡す前に、○×で判定できる基準 (文字数・禁止ワード・文末連続) をスクリプトで検査する。○×で落ちるものを LLM に採点させるのはコストの無駄で、機械の×は AI がどう言い張っても覆らない:

```bash
STATE_FILE="<STATE_FILE>"
TURNS_DIR="$(jq -r '.turns_dir' "$STATE_FILE")"
ITER=$(jq -r '.iteration' "$STATE_FILE")
NNN=$(printf '%03d' $ITER)
ARTIFACT_FILE="$TURNS_DIR/turn-$NNN-output.md"
RULES="$(jq -r '.project_dir' "$STATE_FILE")/.yt-loop/mechanical-checks.json"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-mechanical.sh" "$ARTIFACT_FILE" "$RULES" && echo "MECH:OK" || echo "MECH:NG"
```

- **MECH:OK** (または SKIP) → 3c へ進む。
- **MECH:NG** → **evaluator を起動しない。** NG 行を記録し、`mech_ng` フラグを立てて応答を終了する (validate-eval は不要 — 機械判定は決定論。score は書かず、Stop hook はフラグで判定する):

```bash
STATE_FILE="<STATE_FILE>"
TURNS_DIR="$(jq -r '.turns_dir' "$STATE_FILE")"
ITER=$(jq -r '.iteration' "$STATE_FILE")
NNN=$(printf '%03d' $ITER)
jq -n --arg fb "<check-mechanical の NG 行を改行区切りでまとめたもの>" \
  '{score:null, mechanical:true, quality:{overall:null, breakdown:{}}, feedback:("機械チェックNG (修正必須):\n"+$fb), evaluator_skill:"mechanical-check"}' \
  > "$TURNS_DIR/turn-$NNN-eval.json"
jq --argjson i "$ITER" '.mech_ng=true | .latest_score=null | .phase="eval" | .evaluated_iteration=$i' \
  "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
```

1-2 行要約して応答を終了すれば、Stop hook が NG 内容を feedback として次イテレーションを開始する (NG が 3 回連続すると自動終了)。機械 NG は score 系列に混ぜない — best・進捗ゼロ判定を汚染しないため。

### 3c. Evaluator 起動

Generator 完了後、**1 回の bash で evaluator コンテキストを作成:**

```bash
STATE_FILE="<STATE_FILE>"
TURNS_DIR="$(jq -r '.turns_dir' "$STATE_FILE")"
ITER=$(jq -r '.iteration' "$STATE_FILE")
NNN=$(printf '%03d' $ITER)
SESSION_DIR="$(dirname "$STATE_FILE")"
EVAL_SKILL=$(jq -r '.evaluator_skill // "assign-yt-evaluator"' "$STATE_FILE")
CRITERIA_VAL=$(jq -r '.criteria' "$STATE_FILE")
ARTIFACT_FILE="$TURNS_DIR/turn-$NNN-output.md"
EVAL_FILE="$TURNS_DIR/turn-$NNN-eval.json"
SCHEMA_FILE="${CLAUDE_PLUGIN_ROOT}/skills/${EVAL_SKILL}/eval-schema.json"

if [ -f "$SCHEMA_FILE" ]; then
  BREAKDOWN_KEYS_JSON=$(jq -c '[.breakdown_keys[]?.key]' "$SCHEMA_FILE")
  KEY_INSTRUCTION="quality.breakdown のキーは eval-schema.json の固定キー ${BREAKDOWN_KEYS_JSON} を過不足なく使う。iteration 間で不変"
else
  SCHEMA_FILE="-"
  BREAKDOWN_KEYS_JSON="[]"
  KEY_INSTRUCTION="quality.breakdown のキーは criteria ('${CRITERIA_VAL}') の各項目で固定し iteration 間で不変"
fi

PROFILE_FILE=""
[ -f "$(jq -r '.project_dir' "$STATE_FILE")/.yt-loop/channel-profile.md" ] && PROFILE_FILE="$(jq -r '.project_dir' "$STATE_FILE")/.yt-loop/channel-profile.md"
BRIEF_FILE=$(jq -r '.brief_file // ""' "$STATE_FILE")
ANCHORS_FILE=$(jq -r '.anchors_file // ""' "$STATE_FILE")

jq -n \
  --arg task "$(jq -r '.task' "$STATE_FILE")" \
  --arg criteria "$CRITERIA_VAL" \
  --arg artifact_file "$ARTIFACT_FILE" \
  --arg eval_file "$EVAL_FILE" \
  --arg evaluator_skill "$EVAL_SKILL" \
  --arg key_instruction "$KEY_INSTRUCTION" \
  --arg profile_file "$PROFILE_FILE" \
  --arg brief_file "$BRIEF_FILE" \
  --arg anchors_file "$ANCHORS_FILE" \
  '{task:$task, criteria:$criteria, artifact_file:$artifact_file, eval_file:$eval_file, evaluator_skill:$evaluator_skill, key_instruction:$key_instruction, profile_file:(if $profile_file == "" then null else $profile_file end), brief_file:(if $brief_file == "" or $brief_file == "null" then null else $brief_file end), anchors_file:(if $anchors_file == "" or $anchors_file == "null" then null else $anchors_file end)}' \
  > "$SESSION_DIR/evaluator-context.json"
echo "SKILL:$EVAL_SKILL"
echo "SCHEMA:$SCHEMA_FILE"
echo "CONTEXT:$SESSION_DIR/evaluator-context.json"
```

**即座に Skill ツールで evaluator を起動:** skill = SKILL 行の値、args = CONTEXT 行のパス。

evaluator に渡さないもの (意図的):
- **計画** — 計画への適合で採点すると、間違った方向の計画に忠実な実装ほど高得点になる
- **threshold と iteration 番号** — 「あと 2 点」「最終周」という圧が採点を合格ラインに吸着させる。合否の計算は evaluator の仕事ではない (機械が行う)

### 3d. 検証 + スコア更新

evaluator 完了後、**採点 JSON を機械検証してから** score を書き戻す:

```bash
STATE_FILE="<STATE_FILE>"
TURNS_DIR="$(jq -r '.turns_dir' "$STATE_FILE")"
ITER=$(jq -r '.iteration' "$STATE_FILE")
NNN=$(printf '%03d' $ITER)
EVAL_FILE="$TURNS_DIR/turn-$NNN-eval.json"
THRESHOLD=$(jq -r '.threshold' "$STATE_FILE")
CRITERIA_VAL=$(jq -r '.criteria' "$STATE_FILE")
SCHEMA_FILE="<3c の SCHEMA 行の値>"

if bash "${CLAUDE_PLUGIN_ROOT}/scripts/validate-eval.sh" "$EVAL_FILE" "$SCHEMA_FILE" "$THRESHOLD" "$CRITERIA_VAL"; then
  SCORE=$(jq -r '.score' "$EVAL_FILE")
  echo "Score: $SCORE / Threshold: $THRESHOLD"
else
  echo "EVAL INVALID — re-run evaluator once"
fi
```

- **INVALID の場合**: evaluator を同じコンテキストでもう 1 回だけ起動し、再検証する。2 回目も INVALID なら `jq '.phase="eval" | .latest_score=null' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"` で state を更新して応答を終了 (Stop hook の修復パスに任せる)。
- **スコアを自分で決めない・書き換えない。** validate を通った eval JSON の値だけを使う。

### 3d-2. 確認採点 (SCORE >= THRESHOLD の時のみ)

LLM 採点は同一成果物でも±数点ブレる。6 周引けば 1 回はまぐれの 90+ が出る (ガチャ合格)。**合格が出た時は必ず**、まっさらな evaluator でもう 1 回採点し、**低い方を採用する**。これは省略できない — **Stop hook の pass gate が「確認採点の実在・本採点とのバイト相違・min(2採点) >= threshold」を機械検証し、無い/コピーの合格主張は拒否する**:

1. 3c と同じコンテキスト JSON の `eval_file` だけを `$TURNS_DIR/turn-$NNN-eval-confirm.json` に変えて、evaluator をもう一度 Skill ツールで起動する (本採点のコピーで代用しない — バイト一致は機械的に弾かれる)
2. confirm 側も validate-eval.sh で検証する (INVALID なら evaluator を再実行して confirm を取り直す)
3. **confirm の score が低ければ** `cp "$TURNS_DIR/turn-$NNN-eval-confirm.json" "$EVAL_FILE"` の前に本採点を `$TURNS_DIR/turn-$NNN-eval-first.json` として退避してから正本を差し替える… は不要 — 差し替えず、state の latest_score に低い方を書けばよい (pass gate が両ファイルを読んで min を採る)。confirm が threshold 未満なら合格主張せず、低い方を latest_score にして通常どおり応答を終了する (ループ続行)

### 3e. スコア書き戻し + 応答終了

採用スコアを state に書き戻し (best も更新)、**1-2 行で要約して応答を終了する**:

```bash
SCORE=$(jq -r '.score' "$EVAL_FILE")
ART_SHA=$( { shasum -a 256 "$TURNS_DIR/turn-$NNN-output.md" 2>/dev/null || sha256sum "$TURNS_DIR/turn-$NNN-output.md" 2>/dev/null; } | cut -d' ' -f1 )
jq --argjson s "$SCORE" --argjson i "$ITER" --arg nnn "$NNN" --arg sha "$ART_SHA" \
  '.latest_score = $s | .phase="eval" | .evaluated_iteration = $i
   | .artifact_hashes = ((.artifact_hashes // {}) + {($nnn): $sha})
   | (if (.best_score == null or $s > .best_score) then .best_score = $s | .best_iteration = $i else . end)' \
  "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
echo "Best: iter $(jq -r '.best_iteration' "$STATE_FILE") ($(jq -r '.best_score' "$STATE_FILE"))"
```

artifact のハッシュも同時に記録する (採点後に成果物を書き換える「すり替え」を hook が検知するための材料)。

- **score < threshold でも >= threshold でも、ここで応答を終了する。** 続行/終了/合格の判定はすべて Stop hook が行う:
  - 未達 → hook が次イテレーションを自動開始
  - 合格主張 → hook が **検証** (eval JSON 直読・契約・機械チェック再実行・指紋照合) してから終了させる
  - max / 時間切れ / 進捗ゼロ → hook が終了させる
- どの終わり方でも、hook が `[YT-loop iteration ENDED: <理由>]` という最終指示を送ってくる。それを受けたら Step 4 を実行する。

## Step 4: 完了処理 (hook の ENDED 指示を受けたら)

`[YT-loop iteration ENDED: ...]` を受けたら、その指示に従って 1 応答で完了させる。まず `final-report.sh` を実行し、その出力を最終報告の正本にする:

```bash
STATE_FILE="<ENDED 指示内の STATE_FILE>"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/final-report.sh" "$STATE_FILE"
```

`final-report.sh` が使えない場合のみ、以下の手順で手動納品する:

```bash
STATE_FILE="<ENDED 指示内の STATE_FILE>"
BEST_ITER=$(jq -r '.best_iteration' "$STATE_FILE")
TURNS_DIR="$(jq -r '.turns_dir' "$STATE_FILE")"
if [ "$BEST_ITER" != "null" ]; then
  BEST_NNN=$(printf '%03d' $BEST_ITER)
  BEST_FILE="$TURNS_DIR/turn-$BEST_NNN-output.md"
  STORED=$(jq -r --arg n "$BEST_NNN" '(.artifact_hashes // {})[$n] // ""' "$STATE_FILE")
  CUR=$( { shasum -a 256 "$BEST_FILE" 2>/dev/null || sha256sum "$BEST_FILE" 2>/dev/null; } | cut -d' ' -f1 )
  [ -n "$STORED" ] && [ "$STORED" != "$CUR" ] && echo "WARNING: best artifact was modified after evaluation (採点時と中身が違う)"
  OUT_FILE="./yt-loop-output-$(date +%Y%m%d-%H%M%S).md"
  cp "$BEST_FILE" "$OUT_FILE"
  echo "DELIVERED: $OUT_FILE"
else
  echo "NO DELIVERABLE (合格評価が一度も無かった)"
fi
```

WARNING が出た場合は最終報告に含める (採点時と納品物が一致しないことをユーザーに隠さない)。

最終報告に必ず含める:
- 成果物のパス (`yt-loop-output-*.md`) — **ベストスコアのイテレーションの成果物** を納品する。best が null なら納品せず、turns ディレクトリの場所と「task をどう具体化すべきか」を案内する
- 最終/ベストスコアと quality.breakdown (どの軸が何点か)
- イテレーション数と推移 (例: 82 → 88 → 91) + 「スコアは同一成果物でも±数点ブレます (90点=伸びる保証ではありません)」の 1 行
- 終了理由と、最後の eval の feedback に残った改善余地
- 次回の改善メモ (profile に反映すべきこと、既存 generator が守れなかった出力契約があればその警告)
- 自由 criteria で回した場合: アンカーのパスと「次回同じ軸で回すなら `anchors: <パス>` で再利用できます」の 1 行
- 「納品物を手直ししたら `/yt-profile 更新` で直しを次回に反映できます」の 1 行

ループを勝手に再開しない。

## 重要なルール

1. **Generator / Evaluator は Skill ツールで起動する** (Agent ツールではない)。
2. **計画はオーケストレーター自身が Write で書く。** Planner スキルは使わない。
3. **Evaluator は成果物の絶対品質を評価する。** 改善度ではない。
4. **score の続行・合格判定をしない。** 未達でも合格主張でも応答を終了し、Stop hook (整数比較 + 検証) に任せる。
5. **採点軸・threshold・evaluator・プロファイル・機械ルールをループの途中で変えない。** 点が伸びない時に直すのは成果物か計画であって、ものさしではない (グッドハートの法則)。変えると指紋照合で合格が拒否される。ものさし自体が壊れていると判断した場合はループを止めてユーザーに相談する。
6. **eval JSON を自分で書かない・編集しない。** 書けるのは evaluator (と機械チェックの NG 記録) だけ。「修復」も evaluator の再実行で行う。
7. **フェーズ間で応答を終了しない。** テキスト確認を挟まず即座に次のツール呼び出しに進む。
8. **STATE_FILE パスは Step 2 で取得したものを使い続ける。** 途中で cd しない。
