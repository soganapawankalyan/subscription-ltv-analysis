#!/usr/bin/env bash
# run_all.sh | Runs every SQL file against data/subscriptions.db and saves
# readable output to ./results/.   Usage (from this folder):  bash run_all.sh
set -euo pipefail

DB="data/subscriptions.db"

if [ ! -f "$DB" ]; then
  echo "Missing $DB. Generate it first:  python generate_subscription_data.py" >&2
  exit 1
fi

mkdir -p results

for f in 0[0-5]_*.sql; do
  out="results/${f%.sql}.txt"
  echo "Running $f -> $out"
  sqlite3 -header -column "$DB" < "$f" > "$out"
done

echo "Done. Open the files in ./results/ and paste key numbers into your README."
