#!/bin/bash
#SBATCH --job-name=flooding-transform
#SBATCH --output=/project/cil/home_dirs/sarahmad/repos/rainfall-mortality-2026/hydro/diagnostics/logs/transform2_%j.log
#SBATCH --error=/project/cil/home_dirs/sarahmad/repos/rainfall-mortality-2026/hydro/diagnostics/logs/transform2_%j.err
#SBATCH --account=cil
#SBATCH --partition=caslake
#SBATCH --time=08:00:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --mem=50G

cd /project/cil/home_dirs/sarahmad/repos/rainfall-mortality-2026/hydro/coarse
python transform2.py

