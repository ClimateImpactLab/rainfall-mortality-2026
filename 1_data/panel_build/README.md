# Rainfall-mortality panel build

This folder builds the annual mortality panel used in the regressions.
It starts from the original Carleton panel, adds the new countries, then adds climate and heterogeneity
vars to every country.

## Panel versions

Paths are relative to `/project/cil/gcp/estimation/rainfall-mortality/mortality_data/`.

| version | files | what they are |
|---|---|---|
| original Carleton panel | `global_mortality_panel_era5.dta` (Battuta path below) | the original panel with ERA5-Land vars, read by every rebuild |
| first rebuild | `annual/combined_panel/new_mortality_panel*` | the first cross-country rebuild, still read by some older analysis scripts |
| current build | `annual/panel_update/combined_panel/` | the three datasets below, on current boundaries |

The original panel:

```text
/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/data/0_data_cleaning/3_final/global_mortality_panel_era5.dta
```

The current build saves three datasets, each starting from the one before:

| dataset | contents | scripts |
|---|---|---|
| `01_panel_mortality.csv` | mortality, population and admin IDs | 1a-1c |
| `02_panel_climate.csv` | 01 plus climate, drought and their t-1 and t+1 | 2a-2g |
| `03_panel_full.csv` | 02 plus income and the other het vars | 3a-3f |

Each stage reads the previous dataset and writes only its own, so rerunning from 2a or 3a starts
again from a finished file.
Stage 4 checks the full panel and saves RDS and Stata copies of the three CSVs.

The other folders under `annual/panel_update/` (paths in [paths.R](paths.R)):

```text
old_panel/        trimmed old panel (1a)
new_countries/    new-country mortality and ADM1 income inputs
climate_inputs/   full 1950-2025 climate series, before keeping the mortality years
checks/           check workbook
```

Job logs go in `logs/` in this code folder (ignored by git).

## Admin IDs

`admin_id` is the unit used in the regressions and in every merge.
`adm1_id`, `adm2_id` and `adm3_id` are kept where available.
The old panel uses ADM2, with `admin_id` = `<adm1_id>_<adm2_id>`.
New-country IDs come from their cleaned mortality files, listed in
[country_files.csv](country_files.csv).

The climate files have their own region IDs, which need matching to the panel's `admin_id`:

* old-panel countries: through the ERA5-Land panel crosswalk
* new countries: the climate ID is the country code plus the `admin_id`, so the code is dropped
  (for ex `CPV_31_32` becomes `31_32`)
* Brazil: the climate folder is `BRA_STABLE`, matched to `BRA` in the panel

The matching is done in [climate_inputs.R](climate_inputs.R).

## 1. Mortality

| script | what it does |
|---|---|
| [1a_trim_old_panel.R](scripts/1a_trim_old_panel.R) | keeps mortality, ADM0 and ADM1 income and ERA5-Land climate from the old panel, without the countries that have a newer file, and renames the admin cols |
| [1b_prepare_new_countries.R](scripts/1b_prepare_new_countries.R) | stacks the new-country mortality files listed in `country_files.csv` |
| [1c_combine_panels.R](scripts/1c_combine_panels.R) | stacks the old and new rows, mortality, population and geography only |

The new countries (`country_files.csv`) are Argentina, Australia, Brazil, Botswana, Canada,
Colombia, Cabo Verde, Costa Rica, Ecuador, South Korea, Peru, the Philippines and Thailand.
Their files replace any older rows for the same country.
Brazil uses the stable municipalities from 2000, Ecuador its 162 final units, the Philippines
merged units without BARMM, and Thailand 2014-2024 with all 125 units.

`source_panel` says where each row comes from (`old` or `new`).

## 2. Climate

ERA5-Land is the main climate source, CHIRPS a second precip measure.

| script | what it adds |
|---|---|
| [2a_add_new_country_climate.R](scripts/2a_add_new_country_climate.R) | ERA5-Land temp and precip polynomials for every country |
| [2b_add_chirps.R](scripts/2b_add_chirps.R) | CHIRPS precip polynomials, 1981-2025 |
| [2c_add_adm1_climate.R](scripts/2c_add_adm1_climate.R) | ADM1 temp and precip for the new countries and their long-run averages (admin units averaged to ADM1 with LandScan 2011 pop weights) |
| [2d_add_precip_extremes.R](scripts/2d_add_precip_extremes.R) | average annual days above 50, 100, 150 and 200 mm, and the annual max and p99 of daily precip, fixed over time (not run by the jobs) |
| [2e_add_wind.R](scripts/2e_add_wind.R) | annual max daily wind and days above 17.5 m/s, pop- and area-weighted (all weather, not cyclone tracks) |
| [2f_add_rain_wind_overlap.R](scripts/2f_add_rain_wind_overlap.R) | days with 100, 200 or 300 mm of rain and strong wind within a day, and the wettest and windiest wet days |
| [2g_add_drought_terms.R](scripts/2g_add_drought_terms.R) | ERA5-Land and CHIRPS drought terms, precip polynomials at t-1 and t+1, rainfall baselines, drought x normal temp terms |

The climate files for 2d-2g are built in
[era5land_admin](../climate_data/climate_aggregation_global/era5land_admin/):

- `panel/03_admin_precip_exposure.py` (2d)
- `aggregation_scripts/06_combine_annual_wind.py` (2e)
- `panel/04_rain_wind_events.py` and `panel/05_combine_rain_wind_events.py` (2f)
- [panel/06_admin_drought_terms.R](../climate_data/climate_aggregation_global/era5land_admin/panel/06_admin_drought_terms.R) (2g)

### Climate in each year, the year before and the year after

The full 1950-2025 climate series is kept, so the first and last mortality years still get t-1
and t+1.
The precip polynomials and drought terms have `_lag1` (year before) and `_lead1` (year after)
versions, joined on the actual year, so a missing year stays missing.

Drought columns end with the rainfall product, for ex `spi12_dry_ERA5LAND`,
`spi12_dry_ERA5LAND_lag1`, `spi12_dry_CHIRPS_lead1`.
The terms are `spi12_dry`, `dry_wsum`, `dry_sum`, `mckee`, `dry_x_normal_rolling` and
`dry_x_normal_fixed`, for both products, plus `spi12_dry_roll30_ERA5LAND` (SPI-12 against the 30
years before instead of 1981-2010, ERA5-Land only).
The SPI is fit on 1981-2010, on monthly rain already matched to the panel units.

CHIRPS terms stay missing where there is no CHIRPS (before 1981, Canada, outside 50S to 50N).
`baseline_prcp_mm`, `baseline_prcp_cv` and `baseline_prcp_n` are the 1981-2010 rainfall
baseline (ERA5-Land, with `_CHIRPS` versions).

Three old Chile units have no current climate: Antartica (`12_601`), Juan Fernandez (`5_317`)
and Isla de Pascua (`5_330`).

## 3. Heterogeneity vars

| script | what it adds |
|---|---|
| [3a_add_adm1_income.R](scripts/3a_add_adm1_income.R) | starts `03` from `02`, puts back the old-panel income and adds the corrected Carleton ADM1 income for the new countries |
| [3b_add_kummu_income.R](scripts/3b_add_kummu_income.R) | Kummu GDP per capita, each year and averaged over fixed windows |
| [3c_add_urban.R](scripts/3c_add_urban.R) | GHSL urban, city and town shares, population and settlement type (closest 5-year GHSL year), and pop- and area-weighted building cover in 2000 |
| [3d_add_elevation.R](scripts/3d_add_elevation.R) | FABDEM elevation: median by area and by population, share of land below 10 m and of people below 5, 10 and 20 m |
| [3e_add_pop_density.R](scripts/3e_add_pop_density.R) | panel, LandScan 2011 and GHSL 2010 pop density |
| [3f_add_ag_land.R](scripts/3f_add_ag_land.R) | cropland share and irrigated share of cropland (EarthStat and HID, 2000), irrigated share of harvested area and rainfed harvested area over land (SPAM 2005) |

**Carleton income (3a)**, from `income_data/carleton/output/current_2026_11_15_v2/`: Carleton
through 2014, then PWT 11 national growth, in constant 2005 PPP dollars.
It joins on `iso`, `adm1_id` and `year` (on `admin_id` for ECU `1503` and THA `TH38_43`, which span
ADM1 boundaries).
See the [Carleton income README](../heterogeniety_data/1_data_cleaning/Income/carleton/README.md).

**Kummu income (3b)**, from `income_data/kummu/output/constant_2021_2026_11_21/`: in constant 2021
PPP dollars, each year and averaged over 1990-2024, 1990-1999, 2000-2009, 2010-2024 and 2000-2010
(`kummu_gdppc_avg_<years>`, `kummu_loggdppc_avg_<years>`).
Mortality years before 1990 use 1990 income, after 2024 use 2024.
See the [Kummu price correction](../heterogeniety_data/1_data_cleaning/Income/kummu/price_correction.md).
To refresh only Kummu, run 3b, 4a and `Rscript scripts/4b_export_panel.R --full-only`.

## 4. Check and export

| script | what it does |
|---|---|
| [4a_check_panel.R](scripts/4a_check_panel.R) | panel size, country coverage, repeated rows and missing values |
| [4b_export_panel.R](scripts/4b_export_panel.R) | RDS and Stata copies of the three CSVs (the CSVs aren't changed) |

All checks go to one workbook, `checks/panel_checks.xlsx`, one sheet per check, written by the
script that computes it ([checks.R](checks.R)):

| script | sheets |
|---|---|
| 2a | unmatched climate rows |
| 2c | missing ADM1 links |
| 2g | rainfall and SPI baseline coverage, units and months without a usable baseline, coverage of the climate terms |
| 3a | unmatched ADM1 income |
| 3c | unmatched urban IDs, missing building cover |
| 3d | unmatched elevation IDs |
| 3e | unmatched density IDs |
| 4a | panel size, country coverage, repeated rows, missing values |
| 4b | paths, rows and cols of the exported datasets |

Each script replaces only its own sheets.
An empty unmatched-ID sheet means every unit matched.
Run the steps in order, not as parallel jobs, since they write to the same panel and workbook.

## Running

```bash
cd 1_data/panel_build

# Full build: every step except 2d, then the checks and exports
sbatch run_panel_build.sbatch

# Only the preparation steps (no 2d, 2f, 3d, checks or exports)
sbatch run_panel_prepare.sbatch

# Only the checks and exports, when the CSVs are up to date
sbatch run_checks_exports.sbatch
```

Pick the job for the steps you need, they aren't meant to be submitted together.
