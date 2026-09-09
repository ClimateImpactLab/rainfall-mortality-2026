# Ad-hoc studies

Self-contained side studies that sit outside the main multi-country pipeline in
`2_analysis/`.

`2_analysis/` is organised by **stage** — `regressions/` produces coefficients,
`figures/` turns them into plots, `diagnostics/` checks the panel. The studies
here are organised by **question**: each script runs its own regressions, draws
its own figures and writes its own tables end to end, and each backs one slide
deck in `output/slides/`. They are validation and exploration rather than steps
in the main pipeline, so they live here instead.

## Studies

```text
phl/                  Philippines municipality-level rainfall & temperature
                      response functions, and the heterogeneity margins
                      -> output/slides/phl_rainfall_mortality.tex
                      -> output/slides/heterogeneity_methodology.tex

wind_tc_validation/   Young-Hsiang tropical-cyclone mortality regressions with
                      ERA5-Land wind: replication, head-to-head, diagnostics
                      -> output/slides/wind_tc_validation.tex
```

## Shared setup

Every script starts with the same four-line bootstrap, which walks up the
directory tree until it finds `adhoc/_common.R`. Nothing depends on how deep a
script sits, so `phl/prototype/lasso_heterogeneity.R` and
`phl/01_phl_response_functions.R` resolve the repo root identically:

```r
.adhoc <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a) == 1) dirname(normalizePath(sub("^--file=", "", a))) else normalizePath(getwd())
  while (!file.exists(file.path(d, "_common.R")) && dirname(d) != d) d <- dirname(d)
  d
})
source(file.path(.adhoc, "_common.R"))
source(file.path(.adhoc, "<study>", "_<study>_common.R"))
```

```text
_common.R                        REPO_ROOT, out_dirs(), save_fig(),
                                 write_facts(), PAL3 and the wind colours,
                                 N_CORES

phl/_phl_common.R                PHL_PANEL, PHL_SHP, AGE_LABS, fmt(),
                                 PRCP_SCALE/TAVG_SCALE, read_phl_panel(),
                                 prep_phl_panel()

wind_tc_validation/_wind_common.R
                                 PANEL_CSV, the panel `d`, lag windows, FE,
                                 MEASURES, fmt(), cached(), fit_dl(), SDS
```

There is deliberately no shared `fmt()`. Both studies format numbers the same
way, but want different default digit counts — one decimal for PHL death rates,
three for the wind coefficients — and ~90 call sites rely on that default. What
was genuinely duplicated, and is now shared, is `write_facts()`.

Both studies are written in the tidyverse. The wind study was originally
data.table; it was translated so the two studies read the same way, and the
translation was verified to reproduce every published number.

## Requirements

R >= 4.1 (the scripts use the native `|>` pipe); developed against 4.5.0,
dplyr 1.1.4, fixest 0.13.2.

On the cluster, use the shared environment the panel build uses — see
`1_data/panel_build/run_panel_build.sbatch`:

```bash
/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin/Rscript \
  adhoc/phl/01_phl_response_functions.R
```

Packages, beyond base R:

```text
both studies    dplyr tidyr readr purrr stringr ggplot2 patchwork fixest
phl also        MetBrewer glue sf            (sf for 00 and 02 only)
phl prototype   glmnet
wind also       MetBrewer rlang writexl      (writexl for 01 only)
```

Only **patchwork** and **glmnet** are new relative to what `2_analysis/` and
`1_data/` already require; everything else is either already used there or a
guaranteed dependency of one of these (`rlang` via dplyr, `scales`/`grid` via
ggplot2, `parallel` in base R). If a study fails immediately with a missing
package on the cluster, those two are the ones to check first.

`03_era5_diagnostics.R` and `04_lag_window_sweep.R` fork with `mclapply()`, so
they want a few cores; `N_CORES` takes `SLURM_CPUS_PER_TASK` when set and
otherwise leaves two cores free. Nothing here needs a GPU or more than a few GB
of memory — the largest object is the ~100 MB PHL panel.

## Inputs

No input data is in the repo. Each input is looked up in the same order — env
var, then the cluster path, then `local_data/`, a gitignored folder at the repo
root for local copies. So a checkout on the cluster needs no configuration, and
a local checkout needs only the files placed there:

```text
local_data/phl/phl_new_mortality_panel_urban.csv   (or new_mortality_panel_urban.csv)
local_data/phl/shp/                                PH_Adm3_MuniCities.shp.{shp,dbf,shx,prj,cpg}
local_data/wind_tc_validation/young_hsiang_state_month_era5land_wind_1950_2015.csv
```

Each study README gives the cluster path to copy its files from. A missing
input is reported by name, with the env var to set.

| Study | Input | Override |
|---|---|---|
| phl | Philippines rows of `combined_panel/new_mortality_panel_urban.csv`, the panel built by [`1_data/panel_build/`](../1_data/panel_build/README.md). Subset to `iso == "PHL"` on read, so no pre-made PHL file is required | `PHL_PANEL_CSV` |
| phl | adm3 PSGC shapefile `PH_Adm3_MuniCities.shp/`, at the path `1_data/panel_build/country_files.csv` records. Needed by `00` and `02` only | `PHL_SHP_DIR` |
| wind | `young_hsiang_state_month_era5land_wind_1950_2015.csv` — the Young-Hsiang state-month panel with ERA5-Land wind added; provenance in [`wind_tc_validation/README.md`](wind_tc_validation/README.md) | `YH_TC_PANEL_CSV` |

Each study README documents what its data is and where it comes from.

## Outputs

Everything is written under the repo-level `output/`, in a subfolder named for
the study: `output/{data,figures,tables}/<study>/`. The decks in
`output/slides/` reach the figures via `\graphicspath` and the tables via
`\input`, so the deck and the code that feeds it stay decoupled.

**None of it is committed.** Every `output/{data,figures,tables}/<study>/`
folder is gitignored, because re-running the study rebuilds all of it: the
figures, the `.tex` tables and fact files, the response-curve CSVs, the
cross-script intermediates, and the wind result caches.

What is committed is the source and the finished article: the deck `.tex` in
`output/slides/` (hand-written, not generated) and their compiled PDFs.
`output/data/rf/` stays tracked too, but that comes from the main pipeline, not
from here — `phl/01` reads it for the global overlay.

Two consequences of a fresh checkout being empty of outputs:

- **Recompiling a deck from source needs a full run of its study first.** The
  committed PDFs are the reference rendering until then.
- **Run each study's scripts in order.** Some read files earlier ones write, and
  those reads are `file.exists()`-gated so a missing input degrades the output
  quietly rather than erroring — running `phl/02` alone in a fresh checkout
  gives maps with the coastal and residual panels silently absent.

## Running

```bash
# Philippines -- number order is dependency order
Rscript adhoc/phl/00_phl_coastal.R
Rscript adhoc/phl/01_phl_response_functions.R
Rscript adhoc/phl/02_phl_maps.R
Rscript adhoc/phl/03_phl_poly_selection.R
Rscript adhoc/phl/prototype/lasso_heterogeneity.R

# Wind validation -- 02, 03, 04 are independent of each other
Rscript adhoc/wind_tc_validation/02_young_hsiang_regressions_era5.R
Rscript adhoc/wind_tc_validation/03_era5_diagnostics.R
Rscript adhoc/wind_tc_validation/04_lag_window_sweep.R
```

The wind jackknives and lag sweep are memoized. Set `REFRESH=1` to force a
recompute.
