#!/bin/bash
# Download annual CHIRPS v2.0 daily precipitation files for 2017-2024.
#
# Submit as an array job, for example:
#
#   sbatch --array=2017-2024 run_download_chirps_2017_2024.sbatch
#
# Inputs:
# - year from SLURM_ARRAY_TASK_ID
# - `download_chirps_year.sh`
#
# Outputs:
# - CHIRPS annual NetCDF files in the raw CHIRPS folder
# - one stdout and stderr log per year
#
# Each array task downloads and checks one year. The download script skips a
# year if the final NetCDF already exists and passes the basic checks.

#SBATCH --job-name=chirps_dl
#SBATCH --account=cil
#SBATCH --partition=caslake
#SBATCH --time=04:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=8G

set -euo pipefail

ROOT=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/1_data/climate_data/chirps_download
YEAR=${SLURM_ARRAY_TASK_ID:?Submit with --array=2017-2024}
LOG_DIR=/project/cil/gcp/climate/CHIRPS/download/logs

mkdir -p "$LOG_DIR"
exec >"$LOG_DIR/chirps_${SLURM_ARRAY_JOB_ID}_${YEAR}.out" \
     2>"$LOG_DIR/chirps_${SLURM_ARRAY_JOB_ID}_${YEAR}.err"

echo "year=${YEAR} host=$(hostname) start=$(date --iso-8601=seconds)"
bash "$ROOT/download_chirps_year.sh" "$YEAR"
echo "end=$(date --iso-8601=seconds)"
