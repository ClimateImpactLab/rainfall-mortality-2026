#!/bin/bash
#SBATCH --job-name=merge_era5_panel
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=02:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH --output=/dev/null
#SBATCH --error=/dev/null

# ======================================================================
# Add ERA5-Land variables to the old mortality panel.
#
# This writes a new through-2010 panel copy. The original mortality panel is
# not changed. The Stata file checks the merge before saving the copy.
# ======================================================================

set -euo pipefail

# ----------------------
# Paths
# ----------------------

ROOT=$(cd "$SLURM_SUBMIT_DIR" && pwd)
PANEL_DIR=/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/data/0_data_cleaning/3_final
FINAL="$PANEL_DIR/global_mortality_panel_updated_era5.dta"
STATA_LOG="$ROOT/logs/era5land_admin/add_era5land_to_old_panel.log"
LOG_DIR="$ROOT/logs/era5land_admin/panel"

# -----------------------------
# Logs and environment
# -----------------------------

mkdir -p "$LOG_DIR"
exec >"$LOG_DIR/merge_panel_${SLURM_JOB_ID}.out" \
     2>"$LOG_DIR/merge_panel_${SLURM_JOB_ID}.err"

export HOME=/home/mdefranciosi

# -----------------------------
# Run
# -----------------------------

# Print start/end times in the log so the runtime is easy to check.
echo "start=$(date --iso-8601=seconds)"

/software/stata-16-el8-x86_64/stata-mp -b do \
  "$ROOT/era5land_admin/panel/02_add_era5land_to_old_panel.do"

# Stata writes r(#) in the log when a do-file fails.
if grep -Eq '^r\([0-9]+\);$' "$STATA_LOG"; then
  echo "Stata reported an error; see $STATA_LOG" >&2
  exit 1
fi

# Stata writes the output only after the merge checks pass.
if [[ ! -s "$FINAL" ]]; then
  echo "Stata did not create the updated panel" >&2
  exit 1
fi

grep -q 'CHECKS_PASSED=1' "$STATA_LOG"
echo "created=$FINAL"
echo "end=$(date --iso-8601=seconds)"
