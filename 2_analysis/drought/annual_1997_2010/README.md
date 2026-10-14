# Brazil Drought and Mortality, annual 1997-2010

We're trying to capture the mortality effects of drought aswell as we can. 
Before taking this to the global panel, we decided to start  with one country to see if we
can pick up a signal at all: we test different drought measures, and different
dimensions of heterogeneity (places where the same drought might hurt more).

We started with Brazil because it's a good place to look for a drought signal:
it gets both droughts (the semi-arid Northeast) and extreme rainfall, has a lot of
climate variation within one country, and has good mortality data (death
records for ~5,500 municipalities, by month).

Here we look at annual mortality, 1997-2010.
We build various drought measures from ERA5-Land rainfall (monthly totals,
i.e. daily rainfall summed over the month), compare them in annual mortality
regs, and check heterogeneity by urban share, income and baseline rainfall.
Results are in `main_drought.tex` (first tests) and
`annual_drought_update.tex` in the
[Overleaf project](https://www.overleaf.com/9831588511krkymqfgvqbk#41a22e).

Timing is tested separately with monthly data, in
[monthly_1997_2010](../monthly_1997_2010/README.md): when deaths show up after
a dry or a wet month, and whether there are signals at the monthly level that
we can't see in the annual regs.

Every reg is run with two FE specs side by side: main, and saturated
(+ state x year), which compares municipalities within the same state and
year. With main FE alone something seemed off, like the drought coefs were
picking up something else (maybe regional trends), so we check everything
with saturated FE too. Results are in the Overleaf docs above.

## Folders

```text
annual_1997_2010/
  01_measures/             drought measures (monthly, yearly, SPI) + pilot drought measure rmarkdown file
  02_regressions/          reg panel, pooled regs and heterogeneity regs
  03_run_outputs/          tables and figures for one reg run
  04_checks_diagnostics/   checks on the het bins, the drought measures, and their
                           overlap with the precip poly (collinear)
  05_summary_figures/      figures comparing runs (main vs saturated FE, placebo)
```

Each R script sources `../../../../0_utils/paths.R`, so run it from its own
folder. The sbatch files do this too. 

## 01_measures

* `01_build_monthly_drought_measures.R`: rainfall over the last 1, 3, 6 and 12
  months, and how unusual it is vs the same municipality and ending month in
  the 20 previous years (percentile, z-score, below p10/p5, deficits). Plus
  Rocha-Soares.
* `02_build_annual_drought_summaries.R`: the yearly measures (calendar-year
  rainfall vs 1981-2010, number of dry windows in the year, worst window, dry
  episodes, Rocha-Soares).
* `03_build_spi_measures.R`: calendar-year SPI and worst 6-month SPI.
* `04_drought_pilot.Rmd` / `.html`: the pilot notebook used to choose the
  windows, baselines and thresholds.

## 02_regressions

* `01_build_brazil_panel.R`: mortality + drought panel. Weights are
  population shares within Brazil x year x age. Adds the annual rainfall
  deviation (wet years negative) with last and next year (placebo), a very
  wet year dummy, rainfall percentile bins, SPI, a Northeast flag and the 5
  macro-regions.
* `02_brazil_regs.R`: pooled regs, one drought measure at a time x age group,
  SEs clustered by state.
  * outcome: levels (winsorized death rate, pop weights) or Poisson (deaths)
  * FE: main, saturated, and two in-between checks (state trends,
    macro-region x year)
  * checks: + precip poly, + Tmax, Northeast only
* `03_brazil_het_regs.R`: the same regs with drought x age group x het bin:
  urban share, Kummu income, baseline rainfall level and variability (1981-2010),
  and their 2 x 2 cells.

## 03_run_outputs

* `01_brazil_reg_outputs.R`: +1 SD coef tables, TeX tables and the coef plot
  for one pooled run.
* `02_brazil_het_outputs.R`: coef plots and 2 x 2 heatmaps for one het run.

## 04_checks_diagnostics

* `01_describe_brazil_het_bins.R`: distributions and cutoffs of the het bins.
* `02_brazil_prcp_drought_collinear.R`: how much of each drought measure the
  precip poly already explains after FE (`--fe_spec=main | saturated`).
* `03_brazil_var_diagnostics.R`: drought measure distributions, and each
  measure vs annual rainfall.

## 05_summary_figures

Figures for `annual_drought_update.tex`. `00_figure_setup.R` is sourced by the
two others (paths, plot settings, readers).

* `01_fe_comparison_figures.R`: lead placebo by FE spec, Northeast vs rest of
  Brazil by year, drought variation left under each FE spec.
* `02_main_vs_saturated_figures.R`: pooled results, rainfall bins, Northeast,
  robustness checks and heterogeneity, main vs saturated FE side by side.

## Run order

From the repository root:

```bash
# Measures (only needed if the rainfall inputs change)
sbatch 2_analysis/drought/annual_1997_2010/01_measures/sbatch/run_01_monthly_drought_bra.sbatch
sbatch 2_analysis/drought/annual_1997_2010/01_measures/sbatch/run_02_annual_drought_bra.sbatch
sbatch 2_analysis/drought/annual_1997_2010/01_measures/sbatch/run_03_spi_bra.sbatch

# Panel and regs (each reg run also writes its tables and figures)
sbatch 2_analysis/drought/annual_1997_2010/02_regressions/sbatch/run_01_build_panel_bra.sbatch
sbatch 2_analysis/drought/annual_1997_2010/02_regressions/sbatch/run_02_regs_bra.sbatch
sbatch 2_analysis/drought/annual_1997_2010/02_regressions/sbatch/run_03_het_regs_bra.sbatch main
sbatch 2_analysis/drought/annual_1997_2010/02_regressions/sbatch/run_03_het_regs_bra.sbatch saturated
```

Then, each from its own folder (small, can run on a login node):

```bash
cd 2_analysis/drought/annual_1997_2010/04_checks_diagnostics
Rscript 01_describe_brazil_het_bins.R
Rscript 02_brazil_prcp_drought_collinear.R --fe_spec=main
Rscript 02_brazil_prcp_drought_collinear.R --fe_spec=saturated
Rscript 03_brazil_var_diagnostics.R

cd ../05_summary_figures
Rscript 01_fe_comparison_figures.R
Rscript 02_main_vs_saturated_figures.R
```

## Outputs

```text
Drought measures (monthly and yearly):
/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/monthly/
/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/annual/

Reg panel, SPI file, logs:
/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/brazil_annual/

Reg results, tables and figures (per run, het, checks and summary figures):
output/data/drought/brazil-annual/
```
