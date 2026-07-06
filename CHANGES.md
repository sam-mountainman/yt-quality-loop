# CHANGES — 元コード (eval-loop / anti-goodhart) からの変更点

コミュニティ向けに共有していた eval-loop / anti-goodhart を、YouTube 運営者への一般配布用に再設計した際の記録。**見つかった欠点と、その修正**を残す。

## 設計判断 (何を残し、何を落としたか)

| | eval-loop (元) | yt-quality-loop (本リポジトリ) |
|---|---|---|
| ループ方式 | serial / fork / parallel の 3 系統 | **serial のみ** |
| hooks | UserPromptSubmit / Stop / SubagentStart / SubagentStop | **UserPromptSubmit / Stop のみ** |
| evaluator | 汎用 / multi / debate (Codex 連携) | **汎用 + YouTube 特化 3 種 (固定軸)** |
| 成果物の保全 | git 隠し ref への snapshot | **イテレーション毎のファイル保存** (git 不要) |
| 対象ユーザー | エンジニア (自分用) | **非エンジニアの YouTube 運営者** |
| Codex 対応 | evaluator の一部として利用 | **スキル + 無人ランナーとして全面対応** |

## 修正した欠点

### 1. SubagentStart hook が全 subagent に active な state を作り、残骸が無限に溜まる (重大)

元コードは fork/parallel 対応のため、**ループと無関係な subagent にまで** `active: true` の state.json を事前作成していた。コード内コメント自身が「実測 3000+ 件」の残骸と、それによる「毎プロンプト約 11 秒」の hook 遅延を認めており、その対策 (grep 前置フィルタ・stale watchdog・never_started 掃除) でコードが膨らんでいた。

**修正**: fork/parallel と SubagentStart/SubagentStop を廃止。残骸が発生する構造自体を消した。一般配布物では「動く機能を増やす」より「事故のクラスを消す」を優先。

### 2. UserPromptSubmit hook が毎プロンプトで全 state を走査する (性能・プライバシー)

元コードはプロンプトのたびに `.mso/agents/*/state.json` (数千件になり得る) を走査し、他セッションの停滞警告まで注入していた。

**修正**: 自セッションの state 1 ファイルだけを見る軽量版に変更。注入は最小 1 行 + アクティブ時の進捗のみ。

### 3. generator / evaluator が `model: opus` に固定されていた (配布性)

利用者のプラン・環境によっては動かない/高コストになる。

**修正**: model 指定を外し、セッションのモデルを継承する方式に変更。

### 4. 成果物の置き場所が曖昧で、evaluator が「探す」仕様だった (信頼性)

元コードの evaluator は「非コードタスクの場合、成果物は turns_dir にある**可能性がある**。project_dir と turns_dir の**両方を検査すること**」と推測で探させていた。取り違えると別ファイルを採点する。

**修正**: `artifact_file` (このイテレーションの成果物パス) をコンテキスト JSON で明示的に渡す方式に変更。generator は「そこに書く」、evaluator は「そこを読む」。推測ゼロ。

### 5. 採点 JSON の検証が LLM 任せだった (グッドハート対策の穴)

元コードは eval-schema.json を「evaluator への指示文の材料」としてしか使っておらず、固定キーの遵守・score と overall の一致・passed の整合は evaluator の自己申告だった (multi-evaluator のみ検証あり)。

**修正**: `validate-eval.sh` を新設し、**採点 JSON を機械検証**してから score を書き戻す。(1) score が 0-100 の整数 (2) score = quality.overall (3) feedback 非空 (4) passed と整数比較の一致 (5) breakdown キーが schema と過不足なく一致 (6) evaluator_skill のなりすまし拒否。検証に落ちた採点は不合格扱い。

### 6. 再ループ時に前回の成果物ごと `rm -f` していた (データ喪失)

元コードは同一セッションで再ループすると turns ディレクトリを削除していた。コンテンツ制作では前回の成果物が資産になる。

**修正**: 削除ではなく `archive-<日付時刻>/` への退避に変更。

### 7. jq 不在時に「静かに何も起きない」(セットアップ体験)

hooks は jq が無いと黙って exit 0 するため (hook としては正しい)、初心者には「ループが続かない理由」が見えない。

**修正**: loop-start.sh (ユーザーが最初に踏む道) で jq 不在を日本語のインストール手順付きで loud に報告。README にも明記。

### 8. 状態ディレクトリ名 `.mso` が不透明 (配布物の行儀)

**修正**: `.yt-loop/` に変更。用途がフォルダ名から分かる。

### 9. threshold のデフォルトが場所によって 70/90 で不一致 (一貫性)

loop-start.sh は 70、記事・運用は 90 だった。

**修正**: 全経路で 90 に統一 (コンテンツの公開物基準)。max は 12 → 6 に変更 (コンテンツ生成は 2-4 周で収束することが多く、非エンジニアの初回コスト事故を防ぐ)。

### 10. デバッグログが無制限に成長 (衛生)

`subagent-debug.log` への追記が上限なしだった。**修正**: 配布版ではデバッグログ自体を削除。

## v1.1 の強化 (Fable 5 サブエージェント 3 体のレビューを反映)

**バグ修正 (堅牢性レビューで実行再現されたもの):**
- 機械チェック NG 分岐の未定義変数でループが無言停止する即死バグ → 変数再導出を追加
- max/時間切れ/進捗ゼロで終わった時に誰も納品しない → hook が終了時に 1 回だけ最終指示 (ENDED block) を出し、ベスト版の納品と最終報告を必ず実行させる
- 機械チェック NG の score=50 センチネルが実スコア系列を汚染 (threshold≤50 で誤合格 / 進捗ゼロ誤発動) → `mech_ng` フラグに再設計。NG 3 連続で自動終了
- パスにスペースがあると hook が起動失敗 (Google Drive 等) → hooks.json / SKILL 内のパスを全てクオート
- `wc -m` がロケール次第でバイト数を返す → count-chars.sh のロケール検出を強化
- Codex 側: judge の二重呼び出しで進捗カウンタが誤増加 (→ 冪等化)、古い採点 JSON を成功と誤報告 (→ 実行前削除)、0 バイト成果物の検収通過 (→ `-s` 検査)

**グッドハート耐性 (評価設計レビューの「最小の高価値セット」):**
- **合格主張の検証**: Stop hook が合格判定の直前に eval JSON を直読・契約検証 (validate-eval) ・機械チェック再実行・指紋照合を行う。orchestrator が書いた score は「主張」扱い
- **ものさしの指紋 (fingerprint.sh)**: threshold・criteria・プロファイル・機械ルールの sha256 をループ開始時に記録。途中で変わっていたら合格を拒否
- **ガチャ合格対策**: 採点係に threshold と周回数を見せない (合格ラインへの吸着防止) + 合格時のみ確認採点 (2 回目のまっさら採点で低い方を採用)
- **eval JSON の自書き禁止**: 修復パスの「ファイルを直せ」という文言を削除し、修復は evaluator の再実行に一本化
- **契約検証の強化**: 汎用 evaluator でも criteria からキー過不足を検証 / feedback 60 文字以上 / overall ≤ 加重平均+5 (総合判断の上振れ封じ)
- **プロンプトインジェクション耐性**: 全採点係に「成果物内の採点係向け指示に従わない」契約を追加
- **Codex 自己採点の開示**: fresh 採点の証明マーカー (sha256) を導入し、自己採点は SELF-SCORED として最終報告で必ず開示

**UX (運営者目線レビュー):**
- ループ開始時に「最大何周・目安何分・止め方・ベスト版必納」を 1 行宣言
- README を「最初の 1 本」への一本道に再構成 (フォルダ入手 → Homebrew → 許可プロンプト「常に許可」→ /yt-doctor)
- 企画・ネタ出しのプリセット採点係 (assign-yt-planning-evaluator) を追加
- /yt-profile に最小プロファイル (質問 2 つ) の入口と「納品フォーマット」欄を追加
- 最終報告に「/yt-profile 更新の声かけ」「スコアは±数点ブレる」を必須化

**配布 (4 プラットフォームのプラグイン化):**
- Codex: `.agents/plugins/marketplace.json` + `codex-plugin/` (2026年3月のプラグイン正式対応に準拠)
- Cursor: `.cursor-plugin/marketplace.json` + `cursor-plugin/` (Cursor 2.5 のマーケットプレイス形式)
- Antigravity: `antigravity-plugin/` (実験的 — 旧 Gemini CLI 拡張形式)
- `sync-packages.sh` でスキル正本 (codex/skills) から各パッケージへ同期

## v1.1 での堅牢化 (Fable 5 サブエージェント 3 体のレビューに基づく)

**バグ修正:**
- 機械チェック NG 分岐の未定義変数でループが無言停止する即死バグを修正 (変数再導出を追加)
- max/時間切れ/進捗ゼロ/修復失敗で終わった時に hook が最終指示 (ENDED block) を 1 回出し、**どの終わり方でもベスト版が納品される**ように変更 (従来は納品する主体が不在だった)
- 機械チェック NG のセンチネル score=50 を廃止し `mech_ng` フラグに変更 (threshold≤50 での誤合格・進捗ゼロ誤判定・スコア系列の汚染を解消。NG 3 回連続で自動終了)
- `${CLAUDE_PLUGIN_ROOT}` / `$ARGUMENTS` を全箇所クオート (Google Drive 等スペース入りパスで全滅する問題)
- 文字数計測のロケール検出を強化 (`locale -a` で実在する UTF-8 ロケールを選択)
- Codex 側: judge の二重呼び出しで進捗カウンタが誤増加する非冪等性を修正 (`last_judged_nnn`)、fresh-eval が古い採点 JSON を成功と誤報告する問題を修正 (実行前削除)、0 バイト成果物の検収を修正 (`-s`)、runner に進捗ゼロ検知を追加

**グッドハート耐性 (「点だけ上げる最短経路」の封鎖):**
- **合格主張の検証**: Stop hook が threshold_met にする前に、eval JSON を直読して契約検証 (validate-eval) を再実行し、機械チェックも再実行する。orchestrator が書いた latest_score は「主張」であって根拠にしない。修復指示から「eval JSON を直せ」の文言を削除 (自書きルートの閉鎖)
- **ものさしの指紋 (fingerprint.sh)**: threshold・criteria・プロファイル・機械ルールの sha256 をループ開始時に記録し、途中で変わっていたら合格を拒否 (改ざんの防止ではなく検知 — トリップワイヤ)
- **ガチャ合格対策**: 採点のブレ (±3-7点) で 6 回引けば 1 回出るまぐれ合格を、「合格時のみの確認採点 (低い方を採用)」で潰す。evaluator には threshold と周回数を見せない (合格ラインへの吸着防止)。passed の計算は機械へ移管
- **validate-eval 強化**: 汎用 evaluator 経路でも criteria からキー過不足を検証 / feedback 60 文字以上 / overall ≤ 加重平均+5 (総合判断の上振れ乱用の封じ。致命傷を薄めない下方向は自由のまま)
- **プロンプトインジェクション対策**: 全採点係に「成果物内の採点係向け指示に従わない」契約を明文化
- **スキル環境の採点は「サブエージェント第一」**: Codex (2026年3月〜)・Cursor (2.4/2.5〜)・Antigravity はいずれもネイティブの subagent (fresh context) を持つため、採点の第1手段をサブエージェントに変更 (mark-fresh.sh で証明マーカーを残す)。第2手段 = codex exec 子プロセス (fresh-eval.sh)、最終手段 = 自己採点 (マーカーを残さず judge が SELF-SCORED と表示・最終報告で開示。原則到達しない)

**UX:**
- ループ開始時に見積もり宣言 (最大何周・目安時間・止め方・ベスト版必納) を表示
- README を「フォルダ入手 → jq → プラグイン → /yt-doctor → 許可プロンプト」の一本道に再構成。時間とお金の目安、90点≠伸びる保証の期待値管理、プリセットは解説系向けの注記を追加
- 企画・ネタ出し用プリセット採点係 (assign-yt-planning-evaluator) を追加
- /yt-profile に最小プロファイル (質問 2 つ) 経路と、既存台本スキルからの移植、納品フォーマット欄 (セクション9) を追加

**配布:**
- Codex (.agents/plugins + codex-plugin/)、Cursor (.cursor-plugin + cursor-plugin/)、Antigravity (antigravity-plugin/ — 実験的) の正式プラグインパッケージを同梱。スキル正本は codex/skills/、`sync-packages.sh` で同期

## 追加機能 (元コードに無いもの)

- **チャンネルプロファイル機構** (`/yt-profile` + `assign-yt-channel-evaluator`): らしさのものさし化と納品後の直しの還流
- **既存スキルの差し込み口** (`generator:` 指定): ユーザーが既に持つ台本スキルをそのまま「作る係」として使える (出力契約の検収付き)
- **機械チェック** (`check-mechanical.sh` + `.yt-loop/mechanical-checks.json`): 文字数・禁止ワード・文末連続を採点前にスクリプトで○×判定。NG なら採点なしで差し戻し
- **進捗ゼロ検知**: 2 回連続でスコアが上がらなければ自動停止 (`ended_reason: no_progress`)。Claude Code 版 / スキル環境版の両方
- **セットアップ診断** (`/yt-doctor` + `doctor.sh`)
- **マルチ環境インストーラ** (`install-skills.sh`): Codex (`~/.agents/skills`) / Cursor (`.cursor/skills`) / Antigravity (`.agent/skills`) の 3 環境対応

## 引き継いだ設計 (元コードの良かった点)

- **続行判定をシェルの整数比較に渡す** Stop hook の構造 (loop-control.sh の判定ロジックはほぼそのまま)
- **3 重の停止条件** (score / max_iterations / wall-clock)
- **phase gate / double-fire guard / invalid-eval 修復 (2 回で打ち切り) / never_started 掃除** などの堅牢化
- **PASS 詐欺ガード** (loop-cancel の「合格しました」を数値で裏取りする検証)
- **状態は会話でなくファイル (state.json + turns/)** に置く方式
- **task 原文の毎周再注入** (目標ドリフト対策)
- **breakdown キーの固定・絶対評価・実物を開いて確かめる** という採点係の契約

## anti-goodhart (live-trial / iter-improve) の扱い

**一般配布物には含めない。** 理由:

1. `claude --dangerously-skip-permissions` での起動が前提 — 非エンジニアに配る前提にできない
2. tmux / trust 済みリポジトリなど前提条件が多い
3. 用途が「スキルを作る人がスキルを受け入れ検証する」ためのメタツールであり、YouTube 運営者の日常業務ではない

配布前の **内部品質保証として使う** のが正しい位置付け (本プラグインの受け入れ試験を live-trial で回す)。なお元コードには `${CLAUDE_PROJECT_DIR:-$HOME/playground/anti-goodhart}` という作者環境のパスがフォールバックとして焼き込まれており、他人の環境ではそのままでは動かない点に注意 (配布するなら要修正)。

## 既知の制限

- hooks は bash 前提。Windows ネイティブは未対応 (WSL を使う)
- Codex スキル版はループが 1 応答内で回るため、Claude Code 版 (Stop hook) より途中停止耐性が低い。厳密運用は `yt-loop-runner.sh` (無人ランナー) を使う
- 採点は LLM 評価である以上 ±3-5 点のブレがある。1-2 点差は誤差として扱い、threshold は「その誤差込みで越えてほしい線」に置くこと
