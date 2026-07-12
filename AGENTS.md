# yt-quality-loop 開発ルール (AI エージェント向け)

このリポジトリを変更する前に必ず読むこと。人間の開発者にも適用される。

## 変更時の必須手順

1. **スキルの正本は `codex/skills/yt-loop/`** (Codex/Cursor/Antigravity 共通)。ここを変えたら必ず `bash sync-packages.sh` で codex-plugin / cursor-plugin / antigravity-plugin に同期する。パッケージ側を直接編集しない (次の sync で消える)
2. **Claude Code プラグインの正本は `plugins/yt-quality-loop/`**。scripts は sync-packages が codex-plugin/scripts にも同期する
3. **`loop-control.sh` / `validate-eval.sh` / `fingerprint.sh` / `loop-judge.sh` / `check-mechanical.sh` / `yt-loop.js` を触ったら、必ず `bash scripts/guard-tests.sh` と `node scripts/e2e-smoke-node.js` を通す** (グッドハート対策ガード G/V/J と Windows ネイティブ制御プレーンのレグレッション)。落ちる変更はマージしない
4. リリース前の一括検証: `bash scripts/validate-packages.sh && bash scripts/e2e-smoke.sh`
5. バージョン更新は `bash bump-version.sh <x.y.z>` (7 ファイルに散在する version を一括更新) → sync-packages → zip 再生成

## 設計原則 (壊してはいけないもの)

- **続行/終了の判定は機械 (整数比較) が行う。** LLM に判定させる変更は不可
- **合格は「主張」であり、Stop hook / loop-judge が検証してから通す** (eval JSON 直読・契約検証・機械チェック再実行・指紋照合)。この検証を弱める変更は不可
- **evaluator に threshold・周回数・過去スコア・過去 feedback を渡さない** (合格ラインへの吸着防止)
- **eval JSON を書けるのは evaluator (と機械チェックの NG 記録) だけ。** orchestrator による自書き・修正を許す文言を SKILL.md に入れない
- **ものさし (threshold / criteria / プロファイル / 機械ルール / ブリーフ / アンカー) はループ中に変更不可** — 変更は指紋照合で合格拒否される。新しい「ものさし」ファイルを足す時は fingerprint.sh の対象に加え、guard-tests に改ざんテストを追加する
- **hook は何があっても exit 0** (HOOK SAFETY)。hook スクリプトに set -e を入れない
- **`set -o pipefail` 下で `printf | grep -q` を書かない** (SIGPIPE で確率的に偽になる — 実測済み)。行リスト照合は in_lines() / case 文を使う
- **文字数計測は count-chars.sh** (wc -m 直呼びはロケールでバイト数になる)
- **ユーザー向けコマンドは増やさない** (/yt-loop, /yt-profile, /yt-doctor, /yt-loop-cancel, /yt-import-skill で打ち止め)。新機能はモードとして既存コマンドに入れる

## 多ベンダー確認採点 (judges) ポリシー

- judges は**合格ゲート専用**。周回中の採点係 (evaluator / evaluator_runtime) には触れない。周回中パネル・毎周平均は導入しない (フィードバック分裂・停滞判定破壊・コスト増のため設計却下済み)
- ジャッジの実体は **Node ランナーからのCLI直呼び** (`claude` / `codex` / `grok`)。MCPは使わない。MCP (fable-mcp / codex-mcp / grok系) は対話・レビュー層と evaluator_runtime の担当で、層が違う
- `claude` ジャッジは既定で `--model fable` を指定する。Codexはconfig、Grokは`models`出力から設定済みモデルを開始時に解決する。上書きは `YT_JUDGE_CODEX_MODEL` / `YT_JUDGE_GROK_MODEL`。解決不能時は `configured-unpinned` と開示し、固定済みと表現しない。使用モデルはstate・指紋・最終報告に含める
- auto の規則は「検出された候補から**ホストと同じベンダーを除く**」。Claude系ホストは claude を除外、Codexは codex を除外
- 集計は 外部 1 体 = min / 2 体以上 = 下側中央値 (2/3 合意)。採用スコアは本採点より上がらない (下げる方向にのみ動く)
- 外部ジャッジの失敗は .failed で開示し、**fail-open しない** (全滅時は host 確認に降格 + 最終報告で開示)。明示指定した不在CLIを構成から黙って除外しない。judges と judge_models は指紋対象 — 途中変更は合格拒否 (G21/G23)
- 外部ジャッジに渡してよいもの: task / 採点軸 / プロファイル / ブリーフ / アンカー / 成果物本文 / eval JSON 契約。渡さないもの: threshold / 周回数 / 過去スコア / 過去 feedback / 本採点の結果
- 決定論的な合格ゲートがあるのは hook 経路 (loop-control.sh / yt-loop.js)。skill環境版 (`$yt-loop`) は開示ベース。この差は明示する。なお同じローカル権限でstate・marker・scriptを書けるため、指紋やmarkerをベンダー署名・セキュリティ境界と表現しない

## Fable 連携ポリシー

- Fable は任意の外部 reviewer / evaluator であり、yt-quality-loop の必須依存ではない。Fable の認証失敗や未インストールで通常ループを止めない。
- Codex Plan mode では、Fable MCP が利用可能なら criteria / brief / anchors / 実装計画のレビューにデフォルトで使ってよい。Plan mode 以外では、ユーザーが `Fable`, `Fable5`, `フェイブル`, `evaluator: fable` のように明示した時だけ使う。
- 採点に Fable を使う場合も、Fable は fresh evaluator runtime として扱う。`evaluator_skill` は固定済みの採点基準 (例: `assign-yt-script-evaluator`) のままにし、`evaluator_runtime: "fable"` で別管理する。渡してよいものは task、criteria、artifact、profile、brief、anchors、eval JSON 契約だけ。threshold、iteration、過去 score、過去 feedback、合格/不合格の期待は渡さない。
- Fable が返した eval JSON は orchestrator が編集しない。INVALID は Fable の再実行か、通常の fresh evaluator へのフォールバックで処理する。検証・合否判定は既存の validate / Stop hook / loop-judge が行う。

## 参照禁止

- `/Users/higataiyu/まさお/` 配下のセミナー資料・note 記事・文字起こしは**このリポジトリの実装・文言の参照元にしない** (ユーザー指示)。プリセットの採点知識は一般知識の範囲で書く

## 実測済みの環境注意

- Codex CLI 0.144.1 (2026-07-13): `codex exec --dangerously-bypass-hook-trust` で Stop hook 発火を実測。0.132.0で未発火だった記録は歴史的結果としてのみ扱う。通常は `/hooks` でplugin hookを信頼して `$yt-loop-hook` を使い、hook無効/未信頼時だけ `$yt-loop` へ縮退する
- Node 20+ が必要な CLI (claude 等) を呼ぶスクリプトは、古い node が PATH 先頭の環境を考慮する (validate-packages.sh の Node ガード参照)
- Windows ネイティブでは Bash/jq ではなく `plugins/yt-quality-loop/scripts/yt-loop.js` が hook / state / eval / final-report の制御プレーンになる。Bash scripts は macOS/Linux/WSL 互換経路として残すが、hook command は Node 経由を正とする

## 他エージェント仕様の扱い

- Codex / Cursor / Antigravity / Claude Code の plugin・skill・hook・subagent 仕様は、AI エージェントの記憶で断言しない。変更時は `docs/agent-compat-matrix.md` に公式 docs URL、確認日、実機検証の有無を残す
- 実機差分は `bash scripts/probe-agent-platforms.sh` で確認する。GUI で読ませていないものは「GUI 検証済み」と書かない
- vendor 仕様が変わった場合は、先に互換性表とプローブ結果を更新し、その後に manifest / skill / agent / hook を直す

## 二重正本の方針 (Claude 版 と スキル環境版)

ループのオーケストレーション手順は 2 系統ある:

- `plugins/yt-quality-loop/skills/yt-loop/SKILL.md` (Claude Code。Stop hook 前提)
- `codex/skills/yt-loop{,-hook}/SKILL.md` (Codex/Cursor/Antigravity。yt-loop-hook は Codex hook 前提)

**機能を片方に足したら、もう片方へ移植するか「意図的な差分」として AGENTS.md に記録するか、必ずどちらかを行う** (v1.5 で hook 版に brief/anchors の配線漏れが起き、指紋防御が片系統だけ欠落した — この事故の再発防止)。現在の意図的な差分: `yt-loop.js` は Claude/Codex hook 制御プレーンの正本。`confirm-judges.js` と互換wrapperは `sync-packages.sh` がhookなしスキルにも同期する。hookなし `$yt-loop` / `codex/yt-loop-runner.sh` はループ本体についてはBash互換経路。

## テストの使い分け

- `bash scripts/guard-tests.sh` — グッドハート対策ガードの挙動 (G/V/J)。**ループ制御スクリプトを触ったら必須**
- `bash scripts/e2e-smoke.sh` — 引数なしで **plugins/ (正本) と codex-plugin/ (同期コピー) の両方** に対して状態遷移+final-report を検証し、Node E2E と guard-tests も回す。**リリース前はこれ 1 本でよい**
- `node scripts/e2e-smoke-node.js` — Bash/jq 無しの Windows ネイティブ制御プレーンだけを高速検証する
- `bash scripts/validate-packages.sh` — 静的検証 (構文 / JSON / manifest / claude plugin validate)
- guard-tests は /tmp 配下で完結する (リポジトリに残骸を残さない)
