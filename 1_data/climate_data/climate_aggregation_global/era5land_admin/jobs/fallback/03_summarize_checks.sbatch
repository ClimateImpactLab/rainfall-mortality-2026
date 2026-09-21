#!/bin/bash
#SBATCH --job-name=era5_fb_summary
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=01:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=8G
#SBATCH --output=/dev/null
#SBATCH --error=/dev/null

# ======================================================================
# Summarize cell-fallback check files.
#
# The first input is the summary CSV to write.
# The remaining inputs are the detailed check CSV files to summarize.
# ======================================================================

set -euo pipefail

# ----------------------
# Paths and sbatch inputs
# ----------------------

ROOT=$(cd "$SLURM_SUBMIT_DIR" && pwd)
PYTHON=/project/cil/home_dirs/mdefranciosi/envs/era5land/bin/python

OUTPUT=$1
shift

LOG_DIR="$ROOT/logs/era5land_admin/cell_fallback"

# -----------------------------
# Logs and environment
# -----------------------------

mkdir -p "$LOG_DIR"

exec >"$LOG_DIR/summary_${SLURM_JOB_ID}.out" \
     2>"$LOG_DIR/summary_${SLURM_JOB_ID}.err"

cd "$ROOT/era5land_admin"
export PYTHONPATH="$PWD:$PWD/aggregation_scripts:$PWD/diagnostics:$PWD/cell_fallback:$PWD/panel:${PYTHONPATH:-}"

# -----------------------------
# Run
# -----------------------------

# Print start/end times in the log so the runtime is easy to check.
echo "output=$OUTPUT inputs=$# start=$(date --iso-8601=seconds)"

# Pass each detailed check CSV to the summary script.
CMD=("$PYTHON" cell_fallback/step_03_summarize_checks.py --output "$OUTPUT")
for CHECK_CSV in "$@"; do
    CMD+=(--check-file "$CHECK_CSV")
done
"${CMD[@]}"

echo "end=$(date --iso-8601=seconds)"
