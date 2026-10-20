# ERA5-Land Downloads

This folder contains the scripts that pull hourly ERA5-Land data and turn it into daily files.

There are two download routes:

```text
download_era5land_cds_month_region.py
download_era5land_destine_month_region.py
```

The CDS script uses the Copernicus CDS API. This was the first route I used. It worked, but large requests were slow and often queued.

The DestinE script uses the DestinE Earth Data Hub. This became the better route for most later downloads because the same region-month jobs usually ran much faster.

Both scripts follow the same basic steps:

1. download hourly ERA5-Land data for one region-month
2. aggregate hourly values to daily variables
3. save the daily NetCDF output
4. remove hourly intermediate files

Hourly files are not kept because they are too large.

## DestinE Setup

The DestinE script needs an Earth Data Hub API key. The official setup page is:

```text
https://earthdatahub.destine.eu/getting-started
```

The DestinE platform login page is:

```text
https://platform.destine.eu/
```

After the account exists, API keys are here:

```text
https://earthdatahub.destine.eu/quota-api-keys
```

That page shows the default API key and also lets you create more keys. Keys can
start with `edh_key_...` or `edh_pat_...`; both should work for this script.

Basic steps:

1. Create or sign in to a DestinE account.
2. Open `https://earthdatahub.destine.eu/quota-api-keys`.
3. Copy the default API key, or create a new key and copy it.
4. On RCC, save the key in this file:

```text
~/.env_destine
```

Use:

```bash
nano ~/.env_destine
```

Put this in the file, replacing `PASTE_KEY_HERE` with the actual key:

```bash
export EDH_TOKEN="PASTE_KEY_HERE"
```

For example, the file should look like this:

```bash
export EDH_TOKEN="edh_pat_..."
```

In `nano`, save with `Ctrl-O` (the letter O), press `Enter`, then exit with `Ctrl-X`.

Then lock down the file:

```bash
chmod 600 ~/.env_destine
```

Before running a DestinE sbatch, test that the key loads:

```bash
source ~/.env_destine
echo "${EDH_TOKEN:+EDH_TOKEN is set}"
```

The sbatch files below already run `source ~/.env_destine`.

The `~/.env_destine` file is just a small shell file. Running
`source ~/.env_destine` loads the `EDH_TOKEN` value into the current terminal or
Slurm job.

## Variables

The scripts create these daily variables:

```text
tmin
tmean
tmax
rh_mean
q_mean
swe_mean
tp_total
wind_max
```

Temperature is saved in degrees Celsius. Precipitation and snow water equivalent are saved in millimeters.

## Precipitation

Precipitation needs special handling. ERA5-Land total precipitation is accumulated, not an hourly rain rate.
Therefore, we should not sum the raw hourly `total_precipitation` values directly.
Instead, the scripts shift timestamps back by one hour, take the daily maximum accumulated value, and convert meters to millimeters.

## Sbatch Files

Use these sbatch files as templates for new downloads.

For a normal DestinE region, start from:

```text
run_destine_monthly_europe_example.sbatch
```

For a small patch/component region, start from:

```text
run_destine_monthly_patch_example.sbatch
```

For the old CDS route, start from:

```text
run_cds_monthly_template.sbatch
```

Before submitting, check these lines:

```bash
#SBATCH --array=0-251%8
REGION=europe
START_YEAR=1990
END_YEAR=2010
```

The array count should match the number of months. For example, 1990-2010 is 21 years, so it is 252 months:

```text
0-251
```

The `%8` part means Slurm can run 8 months at once. If DestinE starts failing with quota or connection errors, lower this to `%4`, `%2`, or `%1` and rerun the missing months.

## If We Want Global Data

Global hourly downloads may be too heavy for our current set up here. 
Tried downloading one day of hourly data as a test (about 4 GB for one day of hourly data). 
I think I was close to my limit of monthly tokens and the global download consumed a lot of tokens and I got an error: `HTTP 429: Too Many Requests`.

If we want global data and the hourly dataset is too much to handle for global downloads, other options to check out: 

- DestinE daily ERA5-Land Zarr: https://earthdatahub.destine.eu/collections/era5/datasets/era5-land-daily
- Copernicus ERA5-Land ARCO Zarr: https://cds.climate.copernicus.eu/datasets/reanalysis-era5-land?tab=analysis_ready_data
- Google Earth Engine ERA5-Land Daily Aggregated: https://developers.google.com/earth-engine/datasets/catalog/ECMWF_ERA5_LAND_DAILY_AGGR

These daily ERA5-Land may be best solution but may not match our variables exactly.
This matters most for `tmin`, `tmax`, `rh_mean`, `q_mean`, `swe_mean`, and `wind_max`.
For ex, `tmin` and `tmax` are the daily minimum and maximum of hourly temperature, not daily mean temperature. `rh_mean` and `q_mean` are computed from hourly temperature, dew
point, and pressure, then averaged to the day.
  
`swe_mean` is the daily mean of hourly snow water equivalent. `wind_max` is built from hourly `u10` and `v10`, then maxed over the day.

so variables may change if we use the daily dataset (and this maybe is totally fine). 



