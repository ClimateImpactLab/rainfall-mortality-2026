#!/bin/bash
#SBATCH --job-name=panel_prepare
#SBATCH --partition=cil
#SBATCH --account=cil
#SBATCH --time=04:00:00
#SBATCH --mem=32G
#SBATCH --cpus-per-task=1
#SBATCH --output=/dev/null
#SBATCH --error=/dev/null

# Prepare the working mortality panel with current climate, drought,
# Kummu income, urban shares, density and agricultural shares.
# Elevation and the remaining climate checks are added separately.
# This job does not export or replace the published regression panel.

set -euo pipefail

# -----------------------------
# Paths and logs
# -----------------------------

cd "$SLURM_SUBMIT_DIR"
R=/project/cil/home_dirs/$USER/envs/mortality-rainfall-env/bin/Rscript
# Keep job logs beside the code, not with the saved datasets.
LOG_DIR="$PWD/logs"
mkdir -p "$LOG_DIR"
exec >"$LOG_DIR/prepare_${SLURM_JOB_ID}.out" 2>"$LOG_DIR/prepare_${SLURM_JOB_ID}.err"

# -----------------------------
# Working panel
# -----------------------------

# Print start/end times in the log so the runtime is easy to check.
echo "start=$(date --iso-8601=seconds)"

# Stage 1 saves 01_panel_mortality.csv without climate or income.
"$R" scripts/1a_trim_old_panel.R
"$R" scripts/1b_prepare_new_countries.R
"$R" scripts/1c_combine_panels.R

# Stage 2 saves 02_panel_climate.csv, leaving the mortality-only file unchanged.
# Use the full climate history for t-1 and t+1 before keeping mortality years.
"$R" scripts/2a_add_new_country_climate.R
"$R" scripts/2b_add_chirps.R
"$R" scripts/2c_add_adm1_climate.R
"$R" scripts/2e_add_wind.R
"$R" scripts/2g_add_drought_terms.R

# Stage 3 starts 03_panel_full.csv from 02, then adds the checked sources.
"$R" scripts/3a_add_adm1_income.R
"$R" scripts/3b_add_kummu_income.R
"$R" scripts/3c_add_urban.R
"$R" scripts/3e_add_pop_density.R
"$R" scripts/3f_add_ag_land.R

echo "end=$(date --iso-8601=seconds)"
