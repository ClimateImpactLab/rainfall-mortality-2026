#!/bin/bash
#SBATCH --job-name=era5land_global
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=24:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=40G
#SBATCH --output=/project/cil/home_dirs/%u/repos/rainfall-mortality-2026/1_data/climate_data/era5land_download/logs/global/download_%j.log
#SBATCH --error=/project/cil/home_dirs/%u/repos/rainfall-mortality-2026/1_data/climate_data/era5land_download/logs/global/download_%j.err

set -eo pipefail

# Global DestinE download: daily files, one per variable per month.
#
# Reads in the store's own 60-day blocks rather than a month at a time, which is
# where the quota saving comes from. Because blocks do not line up with months,
# monthly files are assembled in memory and written as they complete, so a
# 60-day block finishes two or three months at a time.
#
# START HERE: price one year first.
#   START_YEAR=2020 END_YEAR=2020
# The summary block ends with a projection to the whole store, in hours and in
# TB, computed from that year's measured per-block cost. Read it before running
# the full range.
#
# Then for everything the store holds, leave both years empty:
#   START_YEAR= END_YEAR=
# Months already on disk are skipped and cost no quota, so this resumes safely
# after a timeout or a quota stop (exit code 4).
#
# Before submitting:
#   1. Set the years below.
#   2. Make sure ~/.env_destine exists and contains EDH_TOKEN.
#   3. mkdir -p the logs/global directory (Slurm will not create it).
#
# To make ~/.env_destine:
#   nano ~/.env_destine
#   export EDH_TOKEN='PASTE_KEY_HERE'
#   chmod 600 ~/.env_destine

REPO_ROOT=/project/cil/home_dirs/${USER}/repos/rainfall-mortality-2026
SCRIPT_DIR=$REPO_ROOT/1_data/climate_data/era5land_download/global

# Call the environment's interpreter directly, as hydro/diagnostics/scripts/
# vis_taudem.sh does. Avoids depending on conda being initialised in .bashrc.
PYTHON=/home/${USER}/.conda/envs/era5land-global/bin/python

# A new root, deliberately not the inherited ERA5-LAND tree. The script refuses
# to run if this points inside the existing archive.
OUTPUT_ROOT=/project/cil/gcp/climate/ERA5-LAND-GLOBAL/raw/daily

# Edit these two lines. Leave both empty for every year the store holds.
START_YEAR=1989
END_YEAR=1989

# Load the DestinE key.
source ~/.env_destine

YEAR_ARGS=""
[ -n "$START_YEAR" ] && YEAR_ARGS="$YEAR_ARGS --start-year $START_YEAR"
[ -n "$END_YEAR" ] && YEAR_ARGS="$YEAR_ARGS --end-year $END_YEAR"

echo "Years:       ${START_YEAR:-store start} .. ${END_YEAR:-store end}"
echo "Output root: $OUTPUT_ROOT"
echo "Python:      $PYTHON"
echo "Cores:       ${SLURM_CPUS_PER_TASK}"
echo "EDH_TOKEN loaded? ${EDH_TOKEN:+yes}"

"$PYTHON" -u "$SCRIPT_DIR/download_era5land_destine_global.py" \
  $YEAR_ARGS \
  --output-root "$OUTPUT_ROOT"
