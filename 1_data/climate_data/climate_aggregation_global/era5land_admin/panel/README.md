# Panel Climate Files

These scripts prepare already-aggregated ERA5-Land admin climate files for the
old mortality panel merge, the final mortality panel build, and rain/wind
overlap checks.

This folder does not aggregate raw rasters or NetCDFs. The daily and annual
admin climate files already exist before these scripts run.

This folder has three separate parts:

1. `00`-`02` add annual ERA5-Land precipitation and temperature to a copy of
   the old Carleton-style global mortality panel through 2010.
2. `03` builds long-run admin extreme-rain variables that are read later by
   `1_data/panel_build`.
3. `04`-`05` build daily rain/wind overlap event files that are read later by
   `1_data/panel_build`.

Wind controls in the final panel come from `1_data/panel_build/scripts/07c_add_wind_exposure.R`.
That script reads the annual wind file from the wind aggregation code, not the
rain/wind event files made here.

## Old-Panel ERA5-Land Merge

These scripts write a copy of the old global mortality panel with annual
ERA5-Land precipitation and temperature variables added.

`00_export_panel_ids.do`

Reads the old global mortality panel and exports the admin-year IDs that need
ERA5-Land climate values:

```text
iso x adm1_id x adm2_id x year
```

The export is limited to years through 2010 to match the old Carleton-style
panel period. This script only writes the admin-year ID data. It does not merge
climate data.

`01_link_panel_climate.py`

Links already-aggregated annual ERA5-Land climate data to the old-panel admin
IDs from `00_export_panel_ids.do`.

It writes the annual climate file used by the old-panel Stata merge:

```text
era5land_global_panel_annual.csv
era5land_global_panel_annual.dta
```

It also writes audit files:

```text
era5land_to_global_panel_crosswalk.csv
era5land_old_panel_link_review.xlsx
```

The crosswalk links ERA5-Land admin regions to the IDs used in the old panel.
Numeric IDs are allowed to differ only by leading zeros, while text IDs must
match exactly. India is matched through the 1961 district crosswalk. Alaska
uses the old panel's historical county merges. Regions outside the old panel
are listed as unmatched.

The review workbook has four sheets:

```text
xwalk
counts
cover
missing
```

`xwalk` repeats the crosswalk for inspection. `counts` gives matched and
not-in-panel counts by climate country. `cover` summarizes old-panel
admin-year climate coverage by ISO. `missing` lists old-panel admin-years with
no ERA5-Land values.

Only population-weighted annual precipitation and temperature variables are
written for the old-panel merge.

`02_add_era5land_to_old_panel.do`

Opens the old global mortality panel through 2010 and merges in:

```text
era5land_global_panel_annual.dta
```

It writes a new copy of the old panel with ERA5-Land precipitation and
temperature variables added. It does not overwrite the original old mortality
panel.

Run order:

1. `00_export_panel_ids.do`
2. `01_link_panel_climate.py`
3. `02_add_era5land_to_old_panel.do`

## Final-Panel Extreme-Rain Variables

`03_admin_precip_exposure.py`

Builds long-run admin extreme-rain variables from existing daily admin
precipitation files. This is the “days above rainfall thresholds” file.

For each admin region and year, it calculates:

```text
days above 50 mm
days above 100 mm
days above 150 mm
days above 200 mm
annual maximum daily precipitation
annual 99th percentile daily precipitation
```

Then it averages those annual values across available years. The combined
long-run output is:

```text
era5land_admin_precip_exposure_static.csv
```

That long-run file is read by:

```text
1_data/panel_build/scripts/07b_add_admin_precip_exposure.R
```

and merged into the final panel.

The script also writes annual and coverage files.

## Rain/Wind Overlap Checks

These files check whether very rainy admin-days also have high all-weather
ERA5-Land wind. They write event-level data. The admin-year variables used in
the mortality panel are added later by:

```text
1_data/panel_build/scripts/07d_add_daily_rain_wind_overlap.R
```

`04_rain_wind_events.py`

Finds admin-days where population-weighted daily precipitation is at least
100 mm.

For those rainy admin-days only, it reads all-weather ERA5-Land wind and adds:

```text
same-day wind
maximum wind over t-1, t, and t+1
```

The plus/minus 1 day window allows rain and wind from the same storm to fall on
nearby recorded dates.
This is all-weather ERA5-Land wind, not tropical cyclone track exposure.

`05_combine_rain_wind_events.py`

Stacks the country-level rain/wind event files from `04_rain_wind_events.py`
and writes event examples and threshold summaries:

```text
top rain events
top rain plus high wind events
high rain without high wind events
summary by 100 / 200 / 300 mm rain thresholds
```

These files answer one question: do very rainy admin-days often overlap with
high all-weather ERA5-Land wind?
