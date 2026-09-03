#!/bin/bash
# ClickyLogs — installs/updates the dashboard into Application Support (so the
# background auto-refresh job can reach it), refreshes the data, and opens it.
#   ./scripts/clickylogs.sh
set -euo pipefail
cd "$(dirname "$0")/.."

SITE="$HOME/Library/Application Support/MyClicky/ClickyLogsSite"
mkdir -p "$SITE"
cp ClickyLogs/index.html ClickyLogs/generate.py "$SITE/"

python3 "$SITE/generate.py" --backfill

if [[ "${1:-}" != "--no-open" ]]; then
  open "$SITE/index.html"
fi
