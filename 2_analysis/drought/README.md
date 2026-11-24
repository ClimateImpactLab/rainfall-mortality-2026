# Drought and Mortality

We're trying to capture the mortality effects of drought as well as we can, starting with Brazil
before taking this to the global panel.
Drought measures are built from ERA5-Land rainfall (and CHIRPS for the global panel).

```text
drought/
  brazil/
    annual/         annual drought measures and annual regs, with heterogeneity and checks
    monthly/        monthly regs (SPI and precip poly), to look at timing
      precip_poly/  same monthly regs with the daily precip cubic instead of SPI
  global_annual/    the global annual panel: where drought raises mortality, and drought x
                    normal temp for 65+
```

Each folder has its own README with the context, scripts, run order, inputs and outputs:
[Brazil annual](brazil/annual/README.md), [Brazil monthly](brazil/monthly/README.md),
[global annual](global_annual/README.md).
