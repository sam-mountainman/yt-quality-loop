# yt-quality-loop

開発ルール・設計原則・必須検証手順は @AGENTS.md を読むこと。要点:

- スキル正本: `codex/skills/yt-loop/` → 変更後 `bash sync-packages.sh` 必須
- ループ制御スクリプトを触ったら `bash scripts/guard-tests.sh` 必須 (G1-G10)
- 合格検証・指紋照合・evaluator への threshold 非開示などのグッドハート対策を弱める変更は不可
- `/Users/higataiyu/まさお/` のセミナー資料は参照禁止
