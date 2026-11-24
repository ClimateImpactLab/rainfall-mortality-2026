#!/bin/bash
#SBATCH --job-name=drought_global_temp
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --output=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/global_annual/logs/%x_%A_%a.out
#SBATCH --error=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/global_annual/logs/%x_%A_%a.err
#SBATCH --time=06:00:00
#SBATCH --mem=32G
#SBATCH --cpus-per-task=1
#SBATCH --array=0-11

# Stop at the first error
set -euo pipefail

# ---------------------------------------------------------------------------------
# Drought x normal temp regs (04_temp_interaction_regs.R), one array task per run, 12 runs
# Needs the panel from 01_build_heterogeneity_panel.R, then 05 makes the tables and figure
# ---------------------------------------------------------------------------------

# R from the project env (has fixest and the other packages)
RSCRIPT="/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin/Rscript"
# Run from the script folder, since the R scripts read paths.R from there
cd "/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/2_analysis/drought/global_annual"

# The 12 runs, one option string each
# Array task i runs 04_temp_interaction_regs.R with JOBS[i]
JOBS=(
  # 0-5: linear, main (rolling normal, precip poly), fixed normal, no precip poly, within place, + drought x income, within place + drought x income
  "--spec=linear"
  "--spec=linear --normal=fixed"
  "--spec=linear --precip=no"
  "--spec=linear --check=place"
  "--spec=linear --check=income"
  "--spec=linear --check=place_income"

  # 6-10: cold, middle and hot months: abs (main), season, season with the single coldest and hottest month, 10 bins, abs + drought x income
  "--spec=abs"
  "--spec=season"
  "--spec=season --season_n=1"
  "--spec=bins"
  "--spec=abs --check=income"

  # 11: abs with a linear trend for each admin unit x age (its placebo is significant)
  "--spec=abs --trend=unit"
)

# This task's run: the script with its option string
"${RSCRIPT}" 04_temp_interaction_regs.R ${JOBS[$SLURM_ARRAY_TASK_ID]}
