#!/bin/bash
#SBATCH --job-name=rain_station_check
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --output=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/logs/station_check_%j.out
#SBATCH --error=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/logs/station_check_%j.err
#SBATCH --time=02:00:00
#SBATCH --mem=96G
#SBATCH --cpus-per-task=8

# Station check step 2, after run_cells_by_year.sbatch: gauges vs cells,
# admin units, tables and figures

set -euo pipefail

PYTHON="/project/cil/home_dirs/mdefranciosi/envs/era5land/bin/python"
RSCRIPT="/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin/Rscript"
cd "/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/1_data/climate_data/station_check"

#   02: gauges vs ERA5-Land and CHIRPS cells (reads the yearly cell files)
#   03: ERA5-Land vs CHIRPS per admin unit
#   04: tables and figures
"${PYTHON}" 02_station_vs_grids.py
"${RSCRIPT}" 03_units_era5land_vs_chirps.R
"${RSCRIPT}" 04_tables_figures.R
