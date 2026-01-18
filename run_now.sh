#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$HOME/jobsaf"
DATA_DIR="$BASE_DIR/data"
LOCK_FILE="$DATA_DIR/run.lock"
SCRAPER="$BASE_DIR/scraper/jobsaf_ui_scrape_v1.py"

mkdir -p "$DATA_DIR"

if [ -f "$LOCK_FILE" ]; then
  read -r old_pid old_ts < "$LOCK_FILE" || true
  if [ -n "${old_pid:-}" ] && kill -0 "$old_pid" 2>/dev/null; then
    echo "RUNNING"
    exit 2
  fi
  rm -f "$LOCK_FILE"
fi

echo "$$ $(date -u +%s)" > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

if [ ! -f "$SCRAPER" ]; then
  echo "Missing scraper: $SCRAPER" >&2
  exit 1
fi

python "$SCRAPER"

if [ ! -s "$DATA_DIR/jobs_full_open.json" ]; then
  echo "Missing output: $DATA_DIR/jobs_full_open.json" >&2
  exit 1
fi

python "$BASE_DIR/notify.py"
