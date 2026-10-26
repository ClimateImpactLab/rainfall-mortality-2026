#!/bin/bash
#SBATCH --job-name=aread8
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=02:00:00
#SBATCH --ntasks=4
#SBATCH --mem=55G
#SBATCH --output=/project/cil/home_dirs/sarahmad/repos/rainfall-mortality-2026/hydro/diagnostics/logs/aread8_%j.log
#SBATCH --error=/project/cil/home_dirs/sarahmad/repos/rainfall-mortality-2026/hydro/diagnostics/logs/aread8_%j.err

# Computes D8 contributing area (upstream cell count) from the EXISTING
# compositep_01deg.tif. Deliberately does NOT re-run pitremove / d8flowdir: this
# is a read-only diagnostic and must not rewrite the flow-direction grid that
# all existing pipeline outputs were built from.
#
# aread8 is the first *global* operator in the chain. pitremove and d8flowdir are
# local (each output cell depends only on its neighbourhood), so neither can
# reveal a network that fails to connect over long distances. aread8's value at a
# cell depends on every cell upstream of it, which is exactly the property under
# test.

set -euo pipefail

set -eo pipefail
source /software/python-anaconda-2022.05-el8-x86_64/etc/profile.d/conda.sh
set +u
conda activate taudem
set -u

cd /project/cil/gcp/climate/taudem_conus/geo_working

# -nc disables edge-contamination checking. Without it TauDEM sets any cell whose
# upstream area *might* touch the domain edge or a nodata cell to nodata, which
# on a land-only DEM can blank out large regions and would masquerade as the very
# fragmentation we are testing for (false positive).
mpiexec -n 4 aread8 -p compositep_01deg.tif -ad8 composite_01deg_ad8.tif -nc

echo "=== Done ==="
ls -la composite_01deg_ad8.tif
