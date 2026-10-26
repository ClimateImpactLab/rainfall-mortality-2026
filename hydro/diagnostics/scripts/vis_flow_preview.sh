#!/bin/bash
#SBATCH --job-name=vis_flow_preview
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=01:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=8G
#SBATCH --nodes=1
#SBATCH --output=/project/cil/home_dirs/sarahmad/repos/rainfall-mortality-2026/hydro/diagnostics/logs/vis_flow_preview_%j.log
#SBATCH --error=/project/cil/home_dirs/sarahmad/repos/rainfall-mortality-2026/hydro/diagnostics/logs/vis_flow_preview_%j.err

# Preview figures comparing drought/flood representations for the USA
# preview run (latitude strips 0-4, 1950-2025). Uses the repo .venv.

cd /project/cil/home_dirs/sarahmad/repos/rainfall-mortality-2026
source .venv/bin/activate

python -u hydro/diagnostics/scripts/vis_flow_preview.py
