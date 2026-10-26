#!/bin/bash
#SBATCH --job-name=flooding-prepflow-preview
#SBATCH --output=/project/cil/home_dirs/sarahmad/repos/rainfall-mortality-2026/hydro/diagnostics/logs/prepflow_preview_%j.log
#SBATCH --error=/project/cil/home_dirs/sarahmad/repos/rainfall-mortality-2026/hydro/diagnostics/logs/prepflow_preview_%j.err
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=06:00:00
# Was 02:00:00 for the 2000-only preview. One year took about 2 minutes
# (job 59779236), so 1950-2025 should take roughly 2-3 hours; years already
# written are skipped if the job has to be resubmitted.
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --mem=40G

# TEMPORARY PREVIEW: routes latitude strips 0-4 for PREVIEW_YEARS only and
# writes to test/preview_bands0-4/. Use prepflow.sh for the full global run.

cd /project/cil/home_dirs/sarahmad/repos/rainfall-mortality-2026
source .venv/bin/activate

python -u hydro/coarse/prepflow_preview.py
