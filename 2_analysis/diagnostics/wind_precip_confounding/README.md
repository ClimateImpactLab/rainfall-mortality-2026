# Wind and Extreme Rain Checks

This folder contains the wind checks for the rainfall-mortality analysis.

The main question is whether very heavy rainfall events are also high-wind
events. If they are, wind could be part of what the rainfall response is
picking up.

There are three checks here:

* **Daily overlap:** how often extreme-rain days also have high wind on or around the rain event
* **Annual overlap:** whether unusually wet admin-years also tend to be unusually windy
* **Known storms:** whether ERA5-Land wind shows large values around a small set of major tropical cyclones in the mortality sample

`pm1day` refers to the rain-event day, the day before, and the day after. High
wind is defined as wind at or above 17.5 m/s.

Most scripts are in R. The known-storm check is in Python because the
ERA5-Land climate aggregation code is in Python. This script reuses those
functions to reopen the raw daily wind files and apply the same grid and admin
weights.

## Script Order

### 01_daily_overlap_tables.R

Starts from the daily rain-event file and asks a simple question: when we see a
very wet admin-day, is there also strong wind around that day?

The input already keeps only admin-days with at least 100 mm of
population-weighted rain. This script breaks those events into 100, 200, and
300 mm rain cutoffs and checks how often they have wind above 17.5 m/s nearby.

The output is one Excel workbook with global counts, country counts, admin-year
summaries, and a few large-event tables.

### 02_make_daily_overlap_panel.R

Turns the daily rain-event file into the annual variables used in the
regression checks.

The regressions need one row per mortality admin-year. This script counts, for
each admin-year, how many extreme-rain days occurred and how many of those days
also had high wind within one day.

The main output is:

```text
admin_year_daily_overlap_panel_ready.csv
```

There is some country-specific ID work in the middle because the daily climate
file and the mortality panel do not always name admin units the same way. That
is just to get the daily events onto the mortality `admin_id` before counting
admin-year events.

The regression checks mostly use:

```text
rain_days_100_wind_pm1day
rain_days_200_wind_pm1day
```

The script also saves a small workbook to check that the matching worked.

The regression scripts that read this file are:

* `01_main_response.R`
* `03_subsample_profiles.R`
* `05_wind_control_coefficients.R`

### 03_annual_overlap_check.R

Checks whether unusually wet admin-years also tend to be unusually windy.

Unlike the daily check in `01_daily_overlap_tables.R`, this uses the annual
ERA5-Land rain and wind measures directly. It looks at whether the upper tails
of the two distributions overlap: for example, how often an admin-year in the
top 1%, 5%, or 10% for extreme rainfall is also in the corresponding top tail
for wind.

The script also reports rain-wind correlations and lists the most extreme
annual rain and wind cases, including years that are high in both and very wet
years that are not especially windy.

This is a descriptive annual check of how closely the two climate measures move
together. It is separate from the daily overlap variables created in
`02_make_daily_overlap_panel.R` for the regression checks.

The script writes the joined annual climate file and an Excel workbook with the
overlap tables, correlations, country summaries, and extreme annual cases.


### 04_tc_event_spot_check.py

Checks whether ERA5-Land wind captures large wind values around 12 known
tropical cyclone events.

For each storm, the script reads raw gridded ERA5-Land daily wind over the event 
window and applies the same admin weights as the main ERA5-Land climate aggregation.
It keeps both the population-weighted admin mean and the maximum grid-cell wind.
The grid-cell maximum matters because the strongest storm winds may affect only
part of an admin unit.

I used AI to identify an initial list of prominent storms that should fall
within the countries and years covered by the mortality sample. I then checked
each of the 12 events manually before using them here.

This is only a spot check, it doesn't idenitfy all TC-exposed admin units.
It's a quick way to check the wind data around known major storms without using 
storm tracks.

The script saves three CSVs:

```text
tc_event_admin_day.csv
tc_event_top_admins.csv
tc_event_summary.csv
```

### 05_tc_event_spot_check_report.Rmd

Summarizes the known-storm check in an HTML report.

The report reads the three CSVs from `04_tc_event_spot_check.py`. It shows the
highest-wind admin units for each storm, rankings by admin-mean wind and max
grid-cell wind, the share of population exposed to wind above 17.5 m/s, rainfall
during the event window, and daily values for the top five admin units.

When knitted from RStudio, the HTML is written next to the R Markdown file:

```text
05_tc_event_spot_check_report.html
```

## Main Files

### Daily overlap inputs

```text
/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/combined/daily_rain_event_wind_overlap/daily_extreme_rain_wind_events_ge100mm.csv
/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/combined/daily_rain_event_wind_overlap/daily_precip_wind_country_year_summary.csv
```

### Mortality panel
```text
/project/cil/gcp/estimation/rainfall-mortality/mortality_data/panel_build/combined_panel/new_mortality_panel_urban.csv
```

### Annual rain and wind inputs

```text
/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/combined/era5land_admin_wind_annual.csv
/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/combined/era5land_admin_precip_exposure_annual.csv
```

### Tropical cyclone event list

```text
/project/cil/gcp/estimation/rainfall-mortality/external_data/wind_precip_confounding/tc_event_spot_check_events.csv
```

### Main outputs

All outputs from these checks are under:

```text
output/data/wind_precip_confounding/
```

### Daily overlap file used in the regressions:

```text
output/data/wind_precip_confounding/daily_precip_wind_overlap_panel_ready/admin_year_daily_overlap_panel_ready.csv
```

### Daily overlap tables:

```text
output/data/wind_precip_confounding/daily_precip_wind_overlap_report/tables/daily_rain_wind_overlap_tables.xlsx
```

### Annual overlap outputs:

```text
output/data/wind_precip_confounding/annual_precip_wind_overlap/annual_precip_wind_joined.csv
output/data/wind_precip_confounding/annual_precip_wind_overlap/annual_precip_wind_checks.xlsx
```

### Known-storm spot-check outputs:

```text
output/data/wind_precip_confounding/tc_event_spot_check/tc_event_admin_day.csv
output/data/wind_precip_confounding/tc_event_spot_check/tc_event_top_admins.csv
output/data/wind_precip_confounding/tc_event_spot_check/tc_event_summary.csv
```

## Related Wind Check

Tom separately replicated [Young–Hsiang (2024)](https://doi.org/10.1038/s41586-024-07945-5) 
using their U.S. state-month mortality sample, but replaced their TC-specific LICRICE 
wind measure with ERA5-Land wind.

ERA5-Land does not capture the most extreme TC wind speeds as well as LICRICE,
but the two measures are still correlated within TC months (`r = 0.49`). 
ERA5-Land also captures high-wind events that are not tropical cyclones.

Importantly, ERA5-Land still picks up a clear mortality response to wind.
The result remains strong across the main diagnostic and robustness checks.

Overall, ERA5-Land is not a perfect TC wind measure, but it does capture
meaningful damaging-wind exposure. This makes it more reassuring that the small
change in the rainfall response after adding wind controls in our analysis is not 
simply because the wind variable is failing to capture relevant storm-related wind.

See also [`wind_tc_validation`](../../wind_tc_validation/README.md).


