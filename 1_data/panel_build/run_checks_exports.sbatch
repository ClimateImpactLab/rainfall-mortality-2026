#!/bin/bash
#SBATCH --job-name=panel_exports
#SBATCH --partition=cil
#SBATCH --account=cil
#SBATCH --time=02:00:00
#SBATCH --mem=32G
#SBATCH --cpus-per-task=1
#SBATCH --output=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/1_data/panel_build/logs/panel_exports_%j.out
#SBATCH --error=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/1_data/panel_build/logs/panel_exports_%j.err

set -euo pipefail

# Refresh the final panel check workbook and the RDS/Stata exports.
# Use this when the CSV panels are already current.

cd /project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/1_data/panel_build

R=/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin/Rscript

$R scripts/11_check_panel.R
$R scripts/12_export_panel.R
