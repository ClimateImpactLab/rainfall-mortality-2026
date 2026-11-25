#!/bin/bash
#SBATCH --job-name=panel_exports
#SBATCH --partition=cil
#SBATCH --account=cil
#SBATCH --time=02:00:00
#SBATCH --mem=32G
#SBATCH --cpus-per-task=1
#SBATCH --output=/dev/null
#SBATCH --error=/dev/null

set -euo pipefail

# Stage 4 only: redo the checks and the RDS/Stata copies, when the CSV
# panels are already up to date.

cd /project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/1_data/panel_build

# Create the code-side log folder before opening this job's logs.
LOG_DIR="$PWD/logs"
mkdir -p "$LOG_DIR"
exec >"$LOG_DIR/panel_exports_${SLURM_JOB_ID}.out" 2>"$LOG_DIR/panel_exports_${SLURM_JOB_ID}.err"

R=/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin/Rscript

$R scripts/4a_check_panel.R
$R scripts/4b_export_panel.R
