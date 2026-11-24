# Drought x normal temp, Brazil monthly

Does a drought hurt more when it hits a month that's normally hot? For ex, does
a dry month raise 65+ deaths only when it falls in a hot month? Runs on
2000-2024 by default (`--period=2000_2024`, the doc's appendices F and G), or
1997-2010 (`--period=1997_2010`).

The **normal temp** of a month is the average temp of that calendar month in
that municipality, in C, so it's on the same scale everywhere (not relative to
the place):

* **rolling** (main): over the 30 years before, for ex July 1967-1996 for July 1997
* **fixed**: over 1981-2010, the same years as the SPI baseline

The reg is the precip poly monthly reg (`../precip_poly/02_regs.R`): FE Poisson
on monthly deaths, log(pop) offset, SEs clustered by state, saturated FE, temp
this month + 11 lags, everything by age group. The dry side of monthly SPI at
this month + 11 lags + 6 leads (placebo) goes in, split by the normal temp of
each dry month, two ways (`--spec`):

* `linear`, the first set-up: each drought term also x the centered normal temp of
  its month,

  ```text
  drought effect of month t-k = b_k + phi_k x (normal temp of month t-k - T*)
  ```

  T* is the average normal temp over the sample, so b is the effect in a month
  at the average normal temp and phi the change in it per 1 C hotter normal.
  Reported summed over this month + 11 lags, and over the leads (placebo).
* cold, middle and hot months (appendix G), one drought term per group, no T*:
  * `season` (main): within place, each year the municipality's 3 coldest, 6
    middle and 3 hottest months by their normal (`--season_n=1`: single
    coldest and hottest)
  * `abs`: across places, the month's normal below the 25th percentile of all
    municipality-months, 25th-75th, above the 75th

Climate control: linear has this month's normal (the h term), the groups have
this month being cold or hot instead (middle left out).

## Runs

| run | spec | normal | precip poly | |
|---|---|---|---|---|
| main | linear | rolling | yes | |
| no precip | linear | rolling | no | dry months compared with normal and wet months |
| fixed | linear | fixed | yes | |
| within place | linear | rolling | yes | + drought x the municipality's average temp, so phi only comes from the season a drought falls in, not from hot vs cool places |
| within place, 3 / 6 / 3 | season | rolling | yes | main of appendix G |
| within place, 1 / 10 / 1 | season, `--season_n=1` | rolling | yes | |
| across places | abs | rolling | yes | |

## Scripts

| script | what it does |
|---|---|
| `01_build_normal_temp.R` | normal temp of every municipality x month, rolling and fixed, 1980-2024 |
| `02_regs.R` | the reg, `--period`, `--spec`, `--season_n`, `--normal`, `--precip`, `--place_avg` |
| `03_outputs.R` | the appendix F (linear) and G (cold, middle and hot months) tables and lag figures, plus the numbers in the text |

## Run order

```bash
cd 2_analysis/drought/brazil/monthly/temp_interaction

# 1. Normal temps (only if the climate files change)
srun --account=cil --partition=cil --mem=16G Rscript 01_build_normal_temp.R

# 2. The 2000-2024 monthly panel
cd ../precip_poly
srun --account=cil --partition=cil --mem=160G --time=04:00:00 Rscript 01_build_panel.R --period=2000_2024
cd ../temp_interaction

# 3. The 7 runs (about 15 min each)
sbatch run_temp_interaction.sbatch

# 4. Tables and figures
Rscript 03_outputs.R
```

## Inputs and outputs

```text
Monthly temp (ERA5-Land, pop-weighted):
/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND-GLOBAL/BRA_STABLE/monthly/

Monthly panel (../precip_poly/01_build_panel.R):
/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/precip_monthly/brazil_precip_monthly_panel_<period>.rds

Normal temps (01):
/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/brazil_monthly/brazil_monthly_normal_temp.rds

Coefs, tables and figures (02, 03):
output/data/drought/brazil-monthly/<period>/temp_interaction/
```
