# Global Drought and Mortality, annual

In Brazil, [monthly regs](../brazil/monthly/README.md) suggest that drought raises deaths in the
0-4 age group slowly, mostly 3 to 11 months after a dry month, and mostly in the Northeast, which
is poorer, drier and more dependent on rainfed farming than the rest of Brazil.
Here we test whether these characteristics change the drought effect across all the countries in
the global annual panel.
A second question, for 65+: does a drought raise deaths more when it falls in months that are
usually hot?
Results go in the [Overleaf project](https://www.overleaf.com/9831588511krkymqfgvqbk#41a22e)
(`06_drought_heterogeneity`).

## The regressions: 

Poisson regs with fixed effects (FE) on annual deaths, with a log(pop) offset, unweighted, by age
group (0-4, 5-64, 65+), SEs clustered by ADM1.

FE: admin unit x age, country x year x age, ADM1 x year x age.

Each reg has tempearature controls, the precip poly and a drought term, with the drought term and
precip poly at t-1, t and t+1 (the placebo).

The main drought term is the dry side of SPI-12.

SPI (standardized precipitation index) says how unusual a period's rain is for the place, in SD, compared with 1981-2010. 

SPI-12 is the SPI of the January-December total, and its dry side is 0 in a normal or wet year.
Three other terms built from monthly SPI (weighted dry sum, unweighted dry sum, McKee drought magnitude) give similar results.

Two rainfall products: ERA5-Land (main) and CHIRPS (`--product`).

The heterogeneity variables, for every country and fixed in time:

* baseline rainfall: 1981-2010 mean and coefficient of variation (CV) of annual precip
* income: GDP per capita from Kummu et al. (2025), in constant 2021 PPP dollars, 2000-2010 average
* cropland share of land (EarthStat) and irrigated share of cropland (HID, the Historical Irrigation
  Dataset), 2000
* rainfed area over land and irrigated share of harvested area (SPAM, Spatial Production
  Allocation Model, 2005)
* urban share (GHSL, Global Human Settlement Layer, closest to 2000)

Terciles, 2 x 2 medians and ranks are cut over all admin units (so they mostly compare countries),
or inside each country with `--cut=within`.

## Options of 02

Default first, full descriptions in the Options section of [02](02_heterogeneity_regs.R):

| option | values | what it does |
|---|---|---|
| `--part` | `pooled`, `terciles`, `quintiles`, `two_by_two`, `ranks` | which regs |
| `--measure` | `spi12_dry`, `dry_wsum`, `dry_sum`, `mckee` | the drought term |
| `--product` | `era5land`, `chirps`, `era5land_chirpsample` | the rainfall data (CHIRPS, or ERA5-Land on the CHIRPS rows) |
| `--cut` | `cross`, `within` | groups over all admin units or inside each country |
| `--income` | `2000_2010`, `1990_2024`, `1990_1999`, `2000_2009`, `2010_2024` | years of the Kummu income average |
| `--trend` | `no`, `unit` | a linear trend for each admin unit x age |
| `--sample` | `all`, `no_brazil_post2010`, `no_brazil`, `no_new_countries` | drop Brazil 2011-2024, Brazil, or the countries added in the new panel |
| `--panel` | `new`, `old` | the old (August) panel, to compare the two |
| `--fe` | `saturated`, `main` | main drops ADM1 x year x age |
| `--baseline` | `fixed`, `rolling30` | SPI-12 against 1981-2010 or the 30 years before |

## Drought x normal temp (04 and 05)

Same reg as [02](02_heterogeneity_regs.R), with the year's drought split by the normal temp of each dry month (the average temp
of that calendar month in the place, over the 30 years before). Four ways to split (`--spec`),
details in the header of [04](04_temp_interaction_regs.R):

* `linear`: one effect at the average normal temp, plus its change per 1 C
* `season`: the place's own 3 coldest, 6 middle and 3 hottest months (hot relative to the place)
* `abs`: cold, middle and hot months in C, across all places (the main version)
* `bins`: same as `abs` with 10 groups

ERA5-Land only. The Brazil monthly version is in
[temp_interaction](../brazil/monthly/temp_interaction/README.md).

## Scripts

| script | what it does |
|---|---|
| [01_build_heterogeneity_panel.R](01_build_heterogeneity_panel.R) | reg-ready panel: het vars, ERA5-Land and CHIRPS rainfall, FE groups (special cases for one-unit ADM1, Japan and Europe in its header) |
| [02_heterogeneity_regs.R](02_heterogeneity_regs.R) | pooled, terciles, quintiles, 2 x 2s and the ranks reg |
| [03_heterogeneity_figures.R](03_heterogeneity_figures.R) | tercile, 2 x 2 and quintile figures |
| [04_temp_interaction_regs.R](04_temp_interaction_regs.R) | drought x normal temp regs |
| [05_temp_interaction_figures.R](05_temp_interaction_figures.R) | drought x normal temp tables and the 10-bin figure |
| [paths.R](paths.R) | input and output paths, read by 01-05 |
| [run_global_annual.sbatch](run_global_annual.sbatch) | every 02 run, one array task each |
| [run_temp_interaction.sbatch](run_temp_interaction.sbatch) | every 04 run, one array task each |

The input panel comes from [1_data/panel_build](../../../1_data/panel_build/README.md):

* drought terms: [2g_add_drought_terms.R](../../../1_data/panel_build/scripts/2g_add_drought_terms.R),
  with the functions of
  [06_admin_drought_terms.R](../../../1_data/climate_data/climate_aggregation_global/era5land_admin/panel/06_admin_drought_terms.R)
* income: [3b_add_kummu_income.R](../../../1_data/panel_build/scripts/3b_add_kummu_income.R)
* urban share: [3c_add_urban.R](../../../1_data/panel_build/scripts/3c_add_urban.R)
* cropland, irrigation and SPAM: [3f_add_ag_land.R](../../../1_data/panel_build/scripts/3f_add_ag_land.R)

## Run order

After the panel build:

```bash
cd 2_analysis/drought/global_annual

RSCRIPT=/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin/Rscript

# 1. Reg-ready panel
srun --account=cil --partition=cil --mem=96G --time=01:00:00 $RSCRIPT 01_build_heterogeneity_panel.R

# 2. Regs, 38 tasks (about 1-30 min each, the unit-trend ones up to 4 h)
sbatch run_global_annual.sbatch

# 3. Figures (needs 2)
$RSCRIPT 03_heterogeneity_figures.R

# 4. Drought x normal temp: regs (12 tasks, about 3-40 min each), then tables and figure
sbatch run_temp_interaction.sbatch
$RSCRIPT 05_temp_interaction_figures.R
```

## Inputs and outputs

`DATA` = `/project/cil/gcp/estimation/rainfall-mortality`, and `OUT` =
`output/data/drought/global-annual/het` in the repo.

* input panel: `DATA/mortality_data/annual/panel_update/combined_panel/03_panel_full.csv`
* reg-ready panel (from 01): `DATA/climate_data/ERA5-LAND/drought/global_annual/global_het_panel.rds`
* old (August) panel, for `--panel=old`: `DATA/climate_data/ERA5-LAND/drought/global_annual/global_drought_panel.rds`
* logs: `DATA/climate_data/ERA5-LAND/drought/global_annual/logs/`
* results (`het_<part>_<measure>.csv`): `OUT/`
* figures: `OUT/figures/`
* drought x normal temp coefs (`temp_<run>.rds`) and tables: `OUT/temp_interaction/`
