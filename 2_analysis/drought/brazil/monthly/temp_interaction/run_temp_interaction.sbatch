#!/bin/bash
#SBATCH --job-name=drought_temp_monthly
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=08:00:00
#SBATCH --mem=240G
#SBATCH --cpus-per-task=8
#SBATCH --array=0-6
#SBATCH --output=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/brazil_monthly/logs/%x_%A_%a.out
#SBATCH --error=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/brazil_monthly/logs/%x_%A_%a.err

set -euo pipefail

RSCRIPT="/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin/Rscript"
cd "/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/2_analysis/drought/brazil/monthly/temp_interaction"

# Brazil monthly, drought x normal temp, 2000-2024. Needs the panel from
# ../precip_poly/01_build_panel.R --period=2000_2024 and the normals from
# 01_build_normal_temp.R. Then 03_outputs.R for the tables and figures
#   0-3 linear (the first set-up): main (rolling normal, precip poly), no precip
#     poly, fixed 1981-2010 normal, within place
#   4-6 cold / middle / hot months: within place (main), single coldest and
#     hottest month, across places
RUNS=(
  "--spec=linear"
  "--spec=linear --precip=no"
  "--spec=linear --normal=fixed"
  "--spec=linear --place_avg=yes"
  "--spec=season"
  "--spec=season --season_n=1"
  "--spec=abs"
)
"${RSCRIPT}" 02_regs.R --period=2000_2024 ${RUNS[$SLURM_ARRAY_TASK_ID]}
