#!/bin/bash
#SBATCH --job-name=taudem
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=01:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --nodes=1
#SBATCH --output=/project/cil/home_dirs/sarahmad/repos/rainfall-mortality-2026/hydro/diagnostics/logs/vis_taudem_%j.log
#SBATCH --error=/project/cil/home_dirs/sarahmad/repos/rainfall-mortality-2026/hydro/diagnostics/logs/vis_taudem_%j.err

cd /project/cil/home_dirs/sarahmad/repos/rainfall-mortality-2026/hydro/diagnostics/scripts

/home/sarahmad/.conda/envs/rainfall/bin/python -u vis_taudem.py

