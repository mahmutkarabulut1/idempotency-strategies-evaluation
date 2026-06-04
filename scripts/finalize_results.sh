#!/usr/bin/env bash
# Post-grid finalization: regenerate figures/tables + LaTeX results table from the
# measured results/aggregate.csv, and print a concise summary.
set -uo pipefail
cd "$(dirname "$0")/.."
[ -f results/aggregate.csv ] || { echo "results/aggregate.csv missing — run the grid first"; exit 1; }

echo "=== measured aggregate.csv ==="
column -t -s, results/aggregate.csv

echo "=== regenerate figures/tables (measured) ==="
python3 analysis/analyze.py 2>&1 | tail -12

echo "=== LaTeX measured results table ==="
python3 analysis/make_results_table.py 2>&1 | tail -20

echo "=== artifacts ==="
ls -1 results/figures/ results/tables/ paper/results_table.tex 2>/dev/null
