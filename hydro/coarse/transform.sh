#!/bin/bash
#SBATCH --job-name=flooding-transform
#SBATCH --output=/project/cil/home_dirs/sarahmad/repos/rainfall-mortality-2026/hydro/diagnostics/logs/transform_%A_%a.log
#SBATCH --error=/project/cil/home_dirs/sarahmad/repos/rainfall-mortality-2026/hydro/diagnostics/logs/transform_%A_%a.err
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=36:00:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --array=0-7
#SBATCH --cpus-per-task=4
#SBATCH --mem=120G

cd /project/cil/home_dirs/sarahmad/repos/rainfall-mortality-2026
source .venv/bin/activate

python -u hydro/coarse/transform.py