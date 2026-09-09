# Philippines rainfall-mortality study

Carleton-style polynomial response functions estimated on the new PHL
municipality-level (adm3) mortality panel, 2006-2024, plus the heterogeneity
margins and the robustness checks behind
[`output/slides/phl_rainfall_mortality.tex`](../../output/slides/phl_rainfall_mortality.tex).

## Scripts

**Run them in number order.** Numbering follows the dependencies: `00` builds a
covariate the others read, `01` estimates and writes the residuals `02` maps.
`03` depends on nothing but the panel, and the prototype depends only on `00`.

| Script | What it does | Feeds |
|---|---|---|
| `00_phl_coastal.R` | Coastal exposure per municipality, by subtracting shared borders from each perimeter. A prep step, not a result: it reads the 211 MB shapefile and does ~8k pairwise boundary intersections, so run it once and let the output be cached | `phl_coastal.csv`, read by `01`, `02` and the prototype |
| `01_phl_response_functions.R` | The main script. Baseline precip and temperature responses, ~12 robustness checks (polynomial order, FE ladder, climate product, estimator, COVID handling, dynamics, leave-one-region-out, weighting, winsorisation, clustering, adm2 aggregation), the heterogeneity margins, marginal effects, an annual-total functional form, and a drought/extreme prototype | most of the main deck; writes `resid_adm3.csv` for `02` |
| `02_phl_maps.R` | Maps of climate, covariates, mortality, coastal exposure and the residuals from `01`, on the adm3 shapefile | 5 map figures |
| `03_phl_poly_selection.R` | Which precipitation polynomial order fits best: AIC/BIC and 5-fold cross-validated Poisson deviance for orders 1-5. Refits the model 30 times, so it is deliberately not part of `01` | `poly_selection.png` |
| `prototype/lasso_heterogeneity.R` | Residualise-then-LASSO over a wide heterogeneity space. **A prototype**, hence the subfolder: it is machinery being stress-tested on a panel we understand before the multi-country panel arrives, and its post-selection inference is not valid — it reports bootstrap selection frequencies rather than p-values. Unnumbered because it is not part of the sequence | `output/slides/heterogeneity_methodology.tex` |

```bash
Rscript adhoc/phl/00_phl_coastal.R
Rscript adhoc/phl/01_phl_response_functions.R
Rscript adhoc/phl/02_phl_maps.R
Rscript adhoc/phl/03_phl_poly_selection.R
Rscript adhoc/phl/prototype/lasso_heterogeneity.R
```

## Shared setup

`_phl_common.R` holds everything the scripts must agree on: the input panel,
`prep_phl_panel()` (sample definition, winsorisation, admin codes,
`covid_period`, polynomial rescaling, weights), `AGE_LABS`, `fmt()`, and the
`PRCP_SCALE`/`TAVG_SCALE` constants.

It exists because that prep block used to be copy-pasted into `01`, `03` and
the prototype, and had already drifted: the prototype had lost the
`covid_period` factor levels
and had reimplemented `get_weights()` without the `agegroup` factor conversion.

### Why the polynomials are rescaled

fixest repairs a non-PSD clustered VCOV by clipping its eigenvalues at an
absolute `1e-12`. In raw units the higher-order polynomial coefficients have
true variances far below that floor — the cubic precipitation term is ~`1.6e-18`
— so the clip, not the data, ends up setting the standard errors, and
`vcov_fix = FALSE` does not disable it (checked in fixest 0.13.2).

Measuring rainfall in units of 100 mm/day divides the order-*k* regressor by
`100^k` and multiplies its coefficient by the same, leaving the response
function exactly unchanged while lifting the coefficient variances clear of the
floor. Section 10 of `01` asserts the standard errors are scale-invariant at
these values, which is what "the floor no longer binds" looks like.
`fix_mat()` in `0_utils/functions.R` is a further safety net, not a substitute.

## Inputs

Neither input is in the repo. Both live on the cluster, and on the cluster both
resolve automatically — no manual step and no env vars. Off-server, both are
looked for under `local_data/`, which is gitignored.

### The mortality panel

This study is **the Philippines rows of the multi-country panel** built by
[`1_data/panel_build/`](../../1_data/panel_build/README.md). There is no
separate PHL build: `read_phl_panel()` reads the canonical file and does the
`iso == "PHL"` subsetting itself.

```text
/project/cil/gcp/estimation/rainfall-mortality/mortality_data/panel_build/
  combined_panel/new_mortality_panel_urban.csv
```

The `_urban` variant is the one to use — it is the base panel plus the GHSL
variables (`settlement_type`, `urban_share`, `ghsl_population`, `year_5s`) that
the heterogeneity margins in `01` are built on.

Upstream of the panel build, PHL mortality is
`PHL_mortality_population_panel_adm3_year_agegroup_no_barmm.csv` under
`release_2020/.../3_final/PHL/` — adm3 × year × agegroup, 2006-2024, and
**BARMM is excluded** (`1_data/panel_build/country_files.csv`). PHL is one of
the few countries carried at ADM3 rather than ADM2, which is why this study can
run at municipality level at all.

After the sample restrictions in `prep_phl_panel()` the estimation sample is
roughly 84k rows: ~1,475 municipalities × 3 age groups × 19 years.

**Working off-server**, put a copy under `local_data/phl/` — gitignored, and
the second place each input is looked for. The full panel is large, so a
PHL-only extract is the practical alternative; it is a plain row subset, so the
two are interchangeable:

```r
readr::read_csv("<panel_build>/combined_panel/new_mortality_panel_urban.csv") |>
  dplyr::filter(iso == "PHL") |>
  readr::write_csv("local_data/phl/phl_new_mortality_panel_urban.csv")
```

Set `PHL_PANEL_CSV` to point somewhere else explicitly.

A local copy carries no version marker, and the panel build rewrites the
combined panel in place at several steps, so one taken months ago can be behind
the cluster's. `read_phl_panel()` prints the row count it kept — worth a glance
if numbers move unexpectedly.

### The adm3 shapefile

Needed by `00` and `02` only. PSA PSGC post-2023 municipality/city boundaries,
at the path the panel build itself uses for PHL:

```text
/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/data/
  0_data_cleaning/1_raw/Countries/New_Countries/PHL/Shapefiles/Post2023/
  PH_Adm3_MuniCities.shp/
```

That is a *directory* named `...shp`, containing `PH_Adm3_MuniCities.shp.shp` —
hence the doubled name in the `st_read()` layer argument. Original source:
[philippines-psgc-shapefiles](https://github.com/altcoder/philippines-psgc-shapefiles),
documented in
[`1_data/mortality_data/1_cleaning/Death_Rates/PHL/README.md`](../../1_data/mortality_data/1_cleaning/Death_Rates/PHL/README.md).
Off-server, copy the directory's contents to `local_data/phl/shp/`. Override
with `PHL_SHP_DIR`.

`02` joins the shapefile to the panel on a zero-padded 10-character
`adm3_psgc`, skipping the cluster's crosswalk (which exists for harmonisation
exceptions such as the BARMM SGA splits). The match rate is asserted, so a
silent mismatch cannot slip through.

## Outputs

`output/figures/phl/`, `output/tables/phl/`, `output/data/phl/`.

Everything here is gitignored and rebuilt by re-running the scripts; the
compiled deck PDF is the committed rendering. Run `00`-`03` before recompiling
`phl_rainfall_mortality.tex` from source.

Three of these outputs are read back by later scripts rather than only being
results:

| File | Written by | Read by |
|---|---|---|
| `phl_coastal.csv` | `00` | `01`, `02`, the prototype |
| `resid_adm3.csv` | `01` | `02` |
| `phl_adm3_simplified.rds` | `02` (its own geometry cache) | `02` |

All three reads are `file.exists()`-gated, so running out of order degrades the
affected figures **silently** rather than erroring — `02` on its own produces
maps with the coastal and residual panels simply missing. Running in number
order avoids this; `00` is the slow one (~90s) and is the only one worth
keeping around between runs.
