#!/bin/bash
#SBATCH --job-name=flooding-prepflow
#SBATCH --output=/project/cil/home_dirs/sarahmad/repos/rainfall-mortality-2026/hydro/diagnostics/logs/prepflow_%j.log
#SBATCH --error=/project/cil/home_dirs/sarahmad/repos/rainfall-mortality-2026/hydro/diagnostics/logs/prepflow_%j.err
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=36:00:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --mem=40G

cd /project/cil/home_dirs/sarahmad/repos/rainfall-mortality-2026
source .venv/bin/activate

python -u hydro/coarse/prepflow.py

