---
name: yt-loop-cancel
description: 実行中の品質ループを止めたい場面で発動。「ループ停止」「ループ止めて」で発動。
user-invocable: true
allowed-tools: Bash, Read
---

# YT Loop Cancel

実行中の YT quality loop を停止します。

## Step 1: アクティブセッション検出

```bash
for f in .yt-loop/sessions/*/state.json; do
  [ -f "$f" ] || continue
  active=$(jq -r '.active' "$f" 2>/dev/null)
  if [ "$active" = "true" ]; then
    task=$(jq -r '.task // "unknown"' "$f" 2>/dev/null)
    iter=$(jq -r '.iteration' "$f" 2>/dev/null)
    max=$(jq -r '.max_iterations' "$f" 2>/dev/null)
    score=$(jq -r '.latest_score // "none"' "$f" 2>/dev/null)
    echo "ACTIVE: $f (task=$task, iter=$iter/$max, score=$score)"
  fi
done
```

## Step 2: キャンセル実行

- **アクティブが 1 つだけ**: そのセッションを自動キャンセル
- **アクティブが複数**: リスト表示してどれをキャンセルするか確認。「全部」も選択肢に含める
- **アクティブなし**: 「アクティブなループはありません」と報告

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/loop-cancel.sh "<STATE_FILE>"
```

キャンセル後、これまでのベスト成果物があれば案内する:

```bash
BEST_ITER=$(jq -r '.best_iteration // empty' "<STATE_FILE>")
if [ -n "$BEST_ITER" ]; then
  TURNS_DIR=$(jq -r '.turns_dir' "<STATE_FILE>")
  echo "ここまでのベスト: $TURNS_DIR/turn-$(printf '%03d' $BEST_ITER)-output.md (score $(jq -r '.best_score' "<STATE_FILE>"))"
fi
```

途中停止でも、ベストイテレーションの成果物パスとスコアを必ずユーザーに伝えること (回した分は無駄にしない)。
