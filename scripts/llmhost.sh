#!/usr/bin/env bash
# Usage: scripts/llmhost.sh <up|down|status|reap|catalog>
# Configuration comes from environment variables (the GitHub workflows set them; see README).
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT_DIR/lib/common.sh"

need curl; need jq; need awk

cmd="${1:-}"
case "$cmd" in
  up|down|status|reap|catalog) ;;
  *) echo "usage: $0 <up|down|status|reap|catalog>" >&2; exit 2 ;;
esac

load_config
"cmd_$cmd"
