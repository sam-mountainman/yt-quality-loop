#!/bin/bash
set -euo pipefail
# Backward-compatible wrapper. The Node runner is the cross-platform source of truth.
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
exec node "$SELF_DIR/confirm-judges.js" "$@"
