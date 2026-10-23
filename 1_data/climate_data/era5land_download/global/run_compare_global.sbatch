#!/bin/bash
#SBATCH --job-name=era5land_compare
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=02:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=8G
#SBATCH --array=0-2
#SBATCH --output=/project/cil/home_dirs/%u/repos/rainfall-mortality-2026/1_data/climate_data/era5land_download/logs/global/compare_%A_%a.log
#SBATCH --error=/project/cil/home_dirs/%u/repos/rainfall-mortality-2026/1_data/climate_data/era5land_download/logs/global/compare_%A_%a.err

set -eo pipefail

# Compare the global download against the inherited regional archive and write
# the differences to CSV. One array task per year, all five final regions.
#
# Why a batch job
# ---------------
# Measured throughput on 2026-09-16 was 0.62-0.70 rows/s, so a full sweep of
# every global month on disk against all five regions (7,640 rows) is about
# 3.0-3.4 hours. A 90-second sinteractive allocation gets through four
# comparisons before Slurm reclaims the node and closes the ssh session.
#
# Why a stratified sample and not the full sweep
# ----------------------------------------------
# The full sweep is mostly redundant. Across 106 asia_combined region-months
# spanning 1980-2017, tmin and tmax max_diff took only two distinct values, so
# the precision finding is already saturated in the time dimension: month 107
# adds nothing. What is NOT yet tested is REGION -- every row so far is one
# region, and the other four are different bounding boxes, three of them built
# by merging component downloads where a seam or a coordinate offset could
# show up as a nonzero mask_mismatch.
#
# So this samples years and takes all regions, rather than sampling at random.
# Random draws from 955 region-months would likely miss a region entirely and
# over-sample 2008-2013, where the global tree is dense. One year covers all
# 12 months, so the seasonal cycle -- monsoon precipitation and the snow
# season, which is what tp_total and swe_mean are sensitive to -- comes free.
#
# Each task is ~60 region-months, roughly 12-16 minutes. The 2 hour limit is
# ~8x headroom for the larger boxes (europe, brazil), which are untimed.
#
# Choosing the years
# ------------------
# Pick the earliest year on disk, one middle year, and the latest year on
# disk. From the 2026-09-16 partial run the global tree holds 6 months of
# 1980, 8 of 1990, 11 of 1999, all of 2008-2013 and at least 9 of 2017, out of
# 191 months total, so the tail past 2017 was never reached. Check the real
# upper end before submitting:
#
#   ls /project/cil/gcp/climate/ERA5-LAND-GLOBAL/raw/daily/global/tmin/ | tail -3
#
# A year is cheap, so add a fourth if you know when the regional archive was
# patched -- a patched year is where a merge seam would be most likely.
#
# Inputs
#   Global:   /project/cil/gcp/climate/ERA5-LAND-GLOBAL/raw/daily/global/<var>/
#   Regional: /project/cil/gcp/climate/ERA5-LAND/raw/daily/<region>/<var>/  (read only)
#
# Output
#   One CSV per array task, job and year stamped so nothing is overwritten.
#   Rows are flushed per region-month, so a TIME_LIMIT kill still leaves a
#   usable partial file. To pool the tasks afterwards, keeping one header:
#
#     cd <logs>/global
#     head -1 compare_1980_*.csv > compare_sample.csv
#     tail -q -n +2 compare_????_*.csv >> compare_sample.csv
#
# Dependencies
#   The era5land-global conda env (numpy, xarray, netCDF4). No DestinE token:
#   this reads local files only and makes no network requests.
#
# Before submitting
#   1. Set YEARS below, and make --array above match its length (0 to n-1).
#   2. mkdir -p the logs/global directory. Slurm will not create it, and the
#      job fails immediately if the --output path does not exist.
#
# Resource notes
#   1 core, because the script is serial: one file pair at a time, and the
#   netCDF4 reads are single threaded. More cores buy nothing.
#   8G, headroom over the 4G that carried asia_combined at 8.5M cells per
#   month-variable. europe and brazil are untested at this writing.

REPO_ROOT=/project/cil/home_dirs/${USER}/repos/rainfall-mortality-2026
SCRIPT_DIR=$REPO_ROOT/1_data/climate_data/era5land_download/global
LOG_DIR=$REPO_ROOT/1_data/climate_data/era5land_download/logs/global

PYTHON=/home/${USER}/.conda/envs/era5land-global/bin/python

GLOBAL_ROOT=/project/cil/gcp/climate/ERA5-LAND-GLOBAL/raw/daily
REGIONAL_ROOT=/project/cil/gcp/climate/ERA5-LAND/raw/daily

# Edit these. One array task per entry; keep --array=0-(n-1) in step.
# Earliest on disk, a middle year, the latest on disk.
YEARS=(1980 1999 2017)

# REGIONS=all is the five final domains from README.md. The component folders
# (india, usa, latam, mexico_south, brazil_east, asia_east) are build inputs,
# not analysis domains, so they are not compared.
REGIONS=all

TASK_ID=${SLURM_ARRAY_TASK_ID:-0}

# A mismatch between --array and the YEARS length would otherwise run a task
# with an empty year, which the script would read as "every month on disk" --
# a 3 hour sweep instead of a 15 minute one. Fail loudly instead.
if [ "$TASK_ID" -ge "${#YEARS[@]}" ]; then
  echo "Task $TASK_ID has no year: YEARS has ${#YEARS[@]} entries." >&2
  echo "Fix --array=0-$(( ${#YEARS[@]} - 1 )) to match." >&2
  exit 1
fi

YEAR=${YEARS[$TASK_ID]}
CSV_OUT=$LOG_DIR/compare_${YEAR}_${SLURM_ARRAY_JOB_ID:-local}.csv

echo "Year:          $YEAR  (array task $TASK_ID of ${#YEARS[@]})"
echo "Regions:       $REGIONS"
echo "Global root:   $GLOBAL_ROOT"
echo "Regional root: $REGIONAL_ROOT (read only)"
echo "CSV out:       $CSV_OUT"
echo "Python:        $PYTHON"

# The script prints only a one-line tally; the CSV is the output.
#
# Exit code 1 means at least one row is FAIL. Do not read that as a broken
# job: with the relative tolerance in place a FAIL is a substantive finding
# (nonzero mask_mismatch, mismatched units, or a relative difference past
# 1e-3) and the CSV is where it is described. So the exit code is swallowed
# here on purpose, to keep Slurm from mailing a FAILED job for a result that
# is simply a difference worth reading.
"$PYTHON" -u "$SCRIPT_DIR/compare_global_to_regional.py" \
  --regions "$REGIONS" \
  --year "$YEAR" \
  --global-root "$GLOBAL_ROOT" \
  --regional-root "$REGIONAL_ROOT" \
  --csv "$CSV_OUT" \
  || echo "exit $? -- differences found, read $CSV_OUT"
