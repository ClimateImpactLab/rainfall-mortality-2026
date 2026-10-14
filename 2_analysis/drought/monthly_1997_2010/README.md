# Brazil Drought and Mortality, monthly 1997-2010

The annual regs (in [annual_1997_2010](../annual_1997_2010/README.md)) can only
tell us whether drought in a given year raises mortality. But drought and
heavy rainfall probably don't hit mortality on the same timescale: a wet month
could raise deaths within weeks (floods, infections), while a dry spell might
take months to show up (water, food, income). Some deaths might also just be
moved a few months earlier, which nets out over a year. A calendar year
mixes all of that together, so the annual coefs can hide effects or pick up
the wrong ones.

Brazil has deaths by month, so here we look at timing directly: when deaths
show up after a dry or a wet month, and whether there are signals at the
monthly level that we can't see in the annual regs. This also helps us
understand what an annual reg can and can't pick up before we use annual data
in the global panel.

Each reg has this month's rainfall + 11 lags (a full year back) and the next
6 months as a placebo (future rainfall can't cause deaths now). Two ways of
measuring rainfall, run separately:

* **SPI** (main folder): each month's rainfall vs what's normal for that place
  and calendar month (1981-2010), in SD. Also split into a dry side and a wet
  side, so dry and wet months each get their own coefs.
* **Precip poly** (`precip_poly/`): usual daily precip, precip^2 and precip^3
  summed over the month, in mm (like our annual regs).

All regs: FE Poisson on monthly deaths with a log(pop) offset, unweighted, by
age group (0-4, 5-64, 65+), SEs clustered by state. Results are in
`monthly_drought.tex` in the
[Overleaf project](https://www.overleaf.com/9831588511krkymqfgvqbk#41a22e).

## FE options (`--fe_spec`)

* `main`: municipality x age x calendar month (each place's seasonality) +
  year-month x age (shocks common to all of Brazil)
* `saturated`: main + state x year x age (compare within state-year)
* `statemonth`: municipality x age x calendar month + state x year-month x age
  (compare within state and month)
* `seasontrend`: saturated, but each place's seasonal pattern can drift over
  the years (health programs, vaccines, sanitation reaching places at
  different times)

## Scripts

| script | what it does |
|---|---|
| `01_build_monthly_measures.R` | monthly SPI (1, 3, 6, 12 months) and 6-month p10/p5 dry flags, 1950-2024 |
| `02_build_panel.R` | mortality + SPI panel, with lags and leads |
| `03_monthly_regs.R` | SPI regs (one term, dry/wet split, 24 lags check, 3/6/12-month SPI, dry flags) |
| `04_monthly_figures.R` | lag profiles, windows figure, lag-sum tables, season trend and Northeast vs rest tables |
| `precip_poly/01_build_panel.R` | mortality + precip panel (daily cubic, monthly totals cubic, SPI dry/wet), 12 lags and 6 leads |
| `precip_poly/02_regs.R` | precip poly regs, `--fe_spec` and `--temp=current \| lags` (temp this month only, or + 11 lags) |
| `precip_poly/03_figures.R` | response curves by window, lag profiles, temp lags comparison, windows table |

`03_monthly_regs.R` and `04_monthly_figures.R` also take `--years=start_end`
and `--region=northeast|rest` to run on a subset of years or municipalities
(results go to `1997_2010/years_<start_end>/` and `1997_2010/region_<region>/`).
`precip_poly/02_regs.R` also runs a `monthly` model (cubic in monthly totals),
as a check (results not shown).

## Run order

From the repository root:

```bash
cd 2_analysis/drought/monthly_1997_2010

# 1. Drought measures (only if the rainfall inputs change)
Rscript 01_build_monthly_measures.R --write

# 2. SPI panel and regs: main, saturated and statemonth FE
sbatch run_monthly_1997_2010.sbatch

# 3. Extra SPI regs: season trend, Northeast vs rest (big regs, so on a
#    compute node)
SRUN="srun --account=cil --partition=cil --mem=48G --cpus-per-task=4"
$SRUN Rscript 03_monthly_regs.R --fe_spec=seasontrend
$SRUN Rscript 03_monthly_regs.R --fe_spec=saturated --region=northeast
$SRUN Rscript 03_monthly_regs.R --fe_spec=saturated --region=rest

# 4. SPI figures and tables (needs 2 and 3)
Rscript 04_monthly_figures.R

# 5. Precip poly: panel, regs (main + saturated FE, both temp specs), figures
sbatch precip_poly/run_precip_monthly.sbatch

# 6. Precip poly with statemonth FE
cd precip_poly
srun --account=cil --partition=cil --mem=96G --cpus-per-task=8 Rscript 02_regs.R --fe_spec=statemonth --temp=current
```

## Inputs

```text
Rainfall and temp (ERA5-Land, population-weighted):
/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND-GLOBAL/BRA_STABLE/monthly/

Mortality + climate panel, 1997-2010 (built in 1_data/panel_build/brazil_pilot/):
/project/cil/gcp/estimation/rainfall-mortality/mortality_data/panel_build/brazil_pilot/legacy_1997_2010/BRA_mortality_climate_monthly_1997_2010.csv
```

## Outputs

```text
Drought measures, reg panels, logs:
/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/brazil_monthly/
/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/precip_monthly/

SPI results, figures and tables:
output/data/drought/brazil-monthly/1997_2010/
output/data/drought/brazil-monthly/1997_2010/summary/

Precip poly results, figures and tables:
output/data/precip-monthly/1997_2010/
output/data/precip-monthly/1997_2010/summary/
```
