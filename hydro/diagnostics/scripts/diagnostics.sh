#!/bin/bash
#SBATCH --job-name=hydro-diagnostics
#SBATCH --output=/project/cil/home_dirs/sarahmad/repos/rainfall-mortality-2026/hydro/diagnostics/logs/diagnostics_%j.log
#SBATCH --error=/project/cil/home_dirs/sarahmad/repos/rainfall-mortality-2026/hydro/diagnostics/logs/diagnostics_%j.err
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=08:00:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --mem=32G

cd /project/cil/home_dirs/sarahmad/repos/rainfall-mortality-2026
source .venv/bin/activate

python -u hydro/diagnostics/scripts/diagnostics.py
