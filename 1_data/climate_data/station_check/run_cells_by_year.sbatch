#!/bin/bash
#SBATCH --job-name=station_cells
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --output=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/logs/station_cells_%A_%a.out
#SBATCH --error=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/logs/station_cells_%A_%a.err
#SBATCH --array=1981-2010
#SBATCH --time=01:00:00
#SBATCH --mem=16G
#SBATCH --cpus-per-task=1

# Station check step 1: ERA5-Land and CHIRPS daily precip at the gauge cells,
# one task per year 1981-2010

set -euo pipefail

PYTHON="/project/cil/home_dirs/mdefranciosi/envs/era5land/bin/python"
cd "/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/1_data/climate_data/station_check"

"${PYTHON}" 01_cells_by_year.py --year=${SLURM_ARRAY_TASK_ID}
