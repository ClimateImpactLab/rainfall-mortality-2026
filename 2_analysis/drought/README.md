# Brazil Drought and Mortality

We're trying to capture the mortality effects of drought as well as we can,
starting with Brazil before taking this to the global panel. Drought
measures are built from ERA5-Land rainfall and tested in Brazil mortality
regs at the municipality level.

```text
drought/
  annual_1997_2010/    annual drought measures and annual regs, with
                       heterogeneity and checks
  monthly_1997_2010/   monthly regs (SPI and precip poly), to look at timing
    precip_poly/       same monthly regs with the daily precip cubic instead of SPI
```

Each folder has its own README with the context, scripts, run order, inputs
and outputs: [annual](annual_1997_2010/README.md),
[monthly](monthly_1997_2010/README.md).
