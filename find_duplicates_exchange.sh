#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SEARCH_DIR=${1:-/mnt/data/Exchange}
REPORT_FILE=${2:-"/tmp/duplicates_report_$(date +%Y%m%d_%H%M%S).txt"}
MAX_DEPTH=${3:-10}

printf 'NOTICE: find_duplicates_exchange.sh is a compatibility wrapper.\n' >&2
printf 'Use duplicate-file-finder.sh for new deployments.\n' >&2

exec "${SCRIPT_DIR}/duplicate-file-finder.sh" \
    --path "$SEARCH_DIR" \
    --report "$REPORT_FILE" \
    --max-depth "$MAX_DEPTH"
