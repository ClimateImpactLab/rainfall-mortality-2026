#!/bin/bash
#SBATCH --job-name=hydro2-coarse
#SBATCH --output=/home/jrising/flooding/rainfall-mortality-2026/hydro2/coarse/hydro-coarse-%j.out
#SBATCH --error=/home/jrising/flooding/rainfall-mortality-2026/hydro2/coarse/hydro-coarse-%j.err
#SBATCH --account=cil
#SBATCH --partition=caslake
#SBATCH --time=24:00:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1

cd /home/jrising/flooding/rainfall-mortality-2026/hydro2/coarse

source activate hydroenv
module load libgeotiff

./main
