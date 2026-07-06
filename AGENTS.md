# yt-quality-loop 開発ルール (AI エージェント向け)

このリポジトリを変更する前に必ず読むこと。人間の開発者にも適用される。

## 変更時の必須手順

1. **スキルの正本は `codex/skills/yt-loop/`** (Codex/Cursor/Antigravity 共通)。ここを変えたら必ず `bash sync-packages.sh` で codex-plugin / cursor-plugin / antigravity-plugin に同期する。パッケージ側を直接編集しない (次の sync で消える)
2. **Claude Code プラグインの正本は `plugins/yt-quality-loop/`**。scripts は sync-packages が codex-plugin/scripts にも同期する
3. **`loop-control.sh` / `validate-eval.sh` / `fingerprint.sh` / `loop-judge.sh` / `check-mechanical.sh` を触ったら、必ず `bash scripts/guard-tests.sh` を通す** (グッドハート対策ガード G1-G10 + V + J のレグレッション)。落ちる変更はマージしない
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

## 参照禁止

- `/Users/higataiyu/まさお/` 配下のセミナー資料・note 記事・文字起こしは**このリポジトリの実装・文言の参照元にしない** (ユーザー指示)。プリセットの採点知識は一般知識の範囲で書く

## 実測済みの環境注意

- Codex CLI 0.132.0: exec / 対話とも plugin hook は発火しない (実測)。`$yt-loop-hook` は plugin root 不在を検知して `$yt-loop` にフォールバックする — この縮退を壊さない
- Node 20+ が必要な CLI (claude 等) を呼ぶスクリプトは、古い node が PATH 先頭の環境を考慮する (validate-packages.sh の Node ガード参照)

## 他エージェント仕様の扱い

- Codex / Cursor / Antigravity / Claude Code の plugin・skill・hook・subagent 仕様は、AI エージェントの記憶で断言しない。変更時は `docs/agent-compat-matrix.md` に公式 docs URL、確認日、実機検証の有無を残す
- 実機差分は `bash scripts/probe-agent-platforms.sh` で確認する。GUI で読ませていないものは「GUI 検証済み」と書かない
- vendor 仕様が変わった場合は、先に互換性表とプローブ結果を更新し、その後に manifest / skill / agent / hook を直す

## 二重正本の方針 (Claude 版 と スキル環境版)

ループのオーケストレーション手順は 2 系統ある:

- `plugins/yt-quality-loop/skills/yt-loop/SKILL.md` (Claude Code。Stop hook 前提)
- `codex/skills/yt-loop{,-hook}/SKILL.md` (Codex/Cursor/Antigravity。yt-loop-hook は Codex hook 前提)

**機能を片方に足したら、もう片方へ移植するか「意図的な差分」として AGENTS.md に記録するか、必ずどちらかを行う** (v1.5 で hook 版に brief/anchors の配線漏れが起き、指紋防御が片系統だけ欠落した — この事故の再発防止)。現在の意図的な差分: なし (機能は両系統で同等)。

## テストの使い分け

- `bash scripts/guard-tests.sh` — グッドハート対策ガードの挙動 (G/V/J)。**ループ制御スクリプトを触ったら必須**
- `bash scripts/e2e-smoke.sh` — 引数なしで **plugins/ (正本) と codex-plugin/ (同期コピー) の両方** に対して状態遷移+final-report を検証し、最後に guard-tests も回す。**リリース前はこれ 1 本でよい**
- `bash scripts/validate-packages.sh` — 静的検証 (構文 / JSON / manifest / claude plugin validate)
- guard-tests は /tmp 配下で完結する (リポジトリに残骸を残さない)
