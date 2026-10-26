#!/bin/bash
#SBATCH --job-name=taudem
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=06:00:00
#SBATCH --ntasks=4
#SBATCH --mem=55G
#SBATCH --output=/project/cil/home_dirs/sarahmad/repos/rainfall-mortality-2026/hydro/diagnostics/logs/run_taudem_%j.log
#SBATCH --error=/project/cil/home_dirs/sarahmad/repos/rainfall-mortality-2026/hydro/diagnostics/logs/run_taudem_%j.err

cd /project/cil/home_dirs/sarahmad/repos/TauDEM
source /software/python-anaconda-2022.05-el8-x86_64/etc/profile.d/conda.sh && conda activate taudem

cd /project/cil/gcp/climate/taudem_conus/geo_working

# Pit removal (0.1° DEM)
mpiexec -n 4 pitremove -z composite_01deg.tif -fel composite_01deg_fel.tif

# D8 flow direction (0.1° DEM)
mpiexec -n 4 d8flowdir -fel composite_01deg_fel.tif -p compositep_01deg.tif -sd8 composite_01deg_sd8.tif