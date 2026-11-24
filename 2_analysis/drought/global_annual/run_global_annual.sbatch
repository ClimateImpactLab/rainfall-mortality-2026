#!/bin/bash
#SBATCH --job-name=drought_global
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --output=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/global_annual/logs/%x_%A_%a.out
#SBATCH --error=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/global_annual/logs/%x_%A_%a.err
#SBATCH --time=08:00:00
#SBATCH --mem=24G
#SBATCH --cpus-per-task=1
#SBATCH --array=0-37

# Stop at the first error
set -euo pipefail

# ---------------------------------------------------------------------------------
# Global drought regs (02_heterogeneity_regs.R), one array task per run, 38 runs
# Needs the panel from 01_build_heterogeneity_panel.R (see the README)
# ---------------------------------------------------------------------------------

# R from the project env (has fixest and the other packages)
RSCRIPT="/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin/Rscript"
# Run from the script folder, since the R scripts read paths.R from there
cd "/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/2_analysis/drought/global_annual"

# cut: cross = groups and ranks over all admin units (main), within = inside each country

# The 38 runs, one option string each
# Array task i runs 02_heterogeneity_regs.R with JOBS[i]
JOBS=(
  # 0-6: SPI-12 (main term), every part, both cuts
  "--part=pooled --measure=spi12_dry --cut=cross"
  "--part=terciles --measure=spi12_dry --cut=cross"
  "--part=two_by_two --measure=spi12_dry --cut=cross"
  "--part=ranks --measure=spi12_dry --cut=cross"
  "--part=terciles --measure=spi12_dry --cut=within"
  "--part=two_by_two --measure=spi12_dry --cut=within"
  "--part=ranks --measure=spi12_dry --cut=within"

  # 7-11: weighted dry sum, pooled, terciles and 2 x 2s, both cuts
  "--part=pooled --measure=dry_wsum --cut=cross"
  "--part=terciles --measure=dry_wsum --cut=cross"
  "--part=two_by_two --measure=dry_wsum --cut=cross"
  "--part=terciles --measure=dry_wsum --cut=within"
  "--part=two_by_two --measure=dry_wsum --cut=within"

  # 12-13: unweighted dry sum and McKee, pooled only
  "--part=pooled --measure=dry_sum --cut=cross"
  "--part=pooled --measure=mckee --cut=cross"

  # 14: SPI-12 quintiles, to see the shape of the tercile results
  "--part=quintiles --measure=spi12_dry --cut=cross"

  # 15-18: with a linear trend for each admin unit x age, for the results whose placebo is significant
  "--part=terciles --measure=spi12_dry --cut=cross --trend=unit"
  "--part=two_by_two --measure=spi12_dry --cut=cross --trend=unit"
  "--part=ranks --measure=spi12_dry --cut=cross --trend=unit"
  "--part=terciles --measure=spi12_dry --cut=within --trend=unit"

  # 19-23: sample checks, without Brazil 2011-2024, without Brazil, without the countries added in the new panel
  "--part=terciles --measure=spi12_dry --cut=cross --sample=no_brazil_post2010"
  "--part=terciles --measure=spi12_dry --cut=cross --sample=no_brazil"
  "--part=terciles --measure=spi12_dry --cut=cross --sample=no_new_countries"
  "--part=two_by_two --measure=spi12_dry --cut=cross --sample=no_brazil_post2010"
  "--part=two_by_two --measure=spi12_dry --cut=cross --sample=no_brazil"

  # 24-31: CHIRPS vs ERA5-Land on the same rows (the CHIRPS sample), pooled and terciles, saturated and main FE
  "--part=pooled --measure=spi12_dry --cut=cross --product=chirps"
  "--part=pooled --measure=spi12_dry --cut=cross --product=era5land_chirpsample"
  "--part=pooled --measure=spi12_dry --cut=cross --product=chirps --fe=main"
  "--part=pooled --measure=spi12_dry --cut=cross --product=era5land_chirpsample --fe=main"
  "--part=terciles --measure=spi12_dry --cut=cross --product=chirps"
  "--part=terciles --measure=spi12_dry --cut=cross --product=era5land_chirpsample"
  "--part=terciles --measure=spi12_dry --cut=cross --product=chirps --fe=main"
  "--part=terciles --measure=spi12_dry --cut=cross --product=era5land_chirpsample --fe=main"

  # 32-35: income terciles with the other Kummu windows (main = 2000-2010)
  "--part=terciles --measure=spi12_dry --cut=cross --income=1990_2024"
  "--part=terciles --measure=spi12_dry --cut=cross --income=1990_1999"
  "--part=terciles --measure=spi12_dry --cut=cross --income=2000_2009"
  "--part=terciles --measure=spi12_dry --cut=cross --income=2010_2024"

  # 36-37: SPI-12 against the 30 years before instead of 1981-2010
  "--part=pooled --measure=spi12_dry --cut=cross --baseline=rolling30"
  "--part=terciles --measure=spi12_dry --cut=cross --baseline=rolling30"
)

# This task's run: the script with its option string
"${RSCRIPT}" 02_heterogeneity_regs.R ${JOBS[$SLURM_ARRAY_TASK_ID]}
