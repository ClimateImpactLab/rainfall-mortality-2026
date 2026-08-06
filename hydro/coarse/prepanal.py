import numpy as np
import pandas as pd
import xarray as xr
import os
from tqdm import tqdm

# Station metadata
meta = pd.read_csv("grdd-meta.csv")
meta["station_id"] = meta["station_id"].astype(int)

# Monthly discharge data
discharge = pd.read_csv("grdd-data.csv")
discharge["station_id"] = discharge["station_id"].astype(int)
discharge["year"] = discharge["year"].astype(int)
discharge["month"] = discharge["month"].astype(int)
discharge["discharge"] = pd.to_numeric(discharge["discharge"], errors="coerce")

# Combine
obs = discharge.merge(
    meta[["station_id", "country", "lat", "lon"]],
    on="station_id",
    how="left",
)

regions = ['asia_east', 'australia', 'brazil', 'europe',
           'india', 'latam', 'mexico_south', 'usa']

root = "/project/cil/gcp/climate/ERA5-LAND/processed/monthly"

# We'll keep per-region datasets separate, in dicts keyed by region
ttp_dsets = {}
runoff_dsets = {}
flow_dsets = {}

# Also store region bounding boxes (lat/lon min/max) as we open datasets
region_bounds = {}

for region in regions:
    f_ttp = os.path.join(root, f"{region}_monthly_ttp.nc4")
    f_runoff = os.path.join(root, f"{region}_monthly.nc4")
    f_flow = os.path.join(root, f"{region}_monthly_flow.nc4")

    ds_ttp = xr.open_dataset(f_ttp, chunks={"valid_time": 100}) if os.path.exists(f_ttp) else None
    ds_runoff = xr.open_dataset(f_runoff, chunks={"valid_time": 100}) if os.path.exists(f_runoff) else None
    ds_flow = xr.open_dataset(f_flow, chunks={"time": 100}) if os.path.exists(f_flow) else None

    # Store only if present
    if ds_ttp is not None:
        ttp_dsets[region] = ds_ttp[["tp", "tmean"]]
    if ds_runoff is not None:
        runoff_dsets[region] = ds_runoff[["rainfall", "era5melt", "tempmelt"]]
    if ds_flow is not None:
        flow_dsets[region] = ds_flow[["rainfall_flow",
                                      "era5melt_flow",
                                      "tempmelt_flow"]]

    # Determine region bounds from any dataset we have
    ds_for_bounds = ds_ttp or ds_runoff or ds_flow
    if ds_for_bounds is not None:
        lats = ds_for_bounds["latitude"]
        lons = ds_for_bounds["longitude"]
        # Use compute-free min/max; .min() / .max() on dask arrays stay lazy
        lat_min = float(lats.min())
        lat_max = float(lats.max())
        lon_min = float(lons.min())
        lon_max = float(lons.max())
        region_bounds[region] = {
            "lat_min": lat_min,
            "lat_max": lat_max,
            "lon_min": lon_min,
            "lon_max": lon_max,
        }

# Small helper: find which region a given (lat, lon) belongs to,
# using bounding boxes + 0.05° buffer
def find_region_for_latlon(lat, lon, region_bounds, buffer_deg=0.05):
    for region, b in region_bounds.items():
        if (
            (b["lat_min"] - buffer_deg) <= lat <= (b["lat_max"] + buffer_deg)
            and (b["lon_min"] - buffer_deg) <= lon <= (b["lon_max"] + buffer_deg)
        ):
            return region
    return None


def extract_values_for_obs_row(
    row,
    ds_ttp=None,
    ds_runoff=None,
    ds_flow=None,
):
    lat = float(row["lat"])
    lon = float(row["lon"])
    year = int(row["year"])
    month = int(row["month"])

    result = {
        "tp": np.nan,
        "tmean": np.nan,
        "rainfall": np.nan,
        "era5melt": np.nan,
        "tempmelt": np.nan,
        "rainfall_flow": np.nan,
        "era5melt_flow": np.nan,
        "tempmelt_flow": np.nan,
    }

    target_time_year = year
    target_time_month = month

    def _time_filter_valid(da):
        t = da["valid_time"]
        mask = (t.dt.year == target_time_year) & (t.dt.month == target_time_month)
        da_tm = da.where(mask, drop=True)
        if da_tm.sizes.get("valid_time", 0) == 0:
            raise KeyError("No matching time")
        return da_tm.isel(valid_time=0)

    def _time_filter_time(da):
        t = da["time"]
        mask = (t.dt.year == target_time_year) & (t.dt.month == target_time_month)
        da_tm = da.where(mask, drop=True)
        if da_tm.sizes.get("time", 0) == 0:
            raise KeyError("No matching time")
        return da_tm.isel(time=0)

    # tp, tmean
    if ds_ttp is not None:
        try:
            da = ds_ttp.sel(latitude=lat, longitude=lon, method="nearest")
            da_t = _time_filter_valid(da)
            # These should be scalars or tiny; .item() avoids loading big arrays
            result["tp"] = float(da_t["tp"].values)
            result["tmean"] = float(da_t["tmean"].values)
        except Exception:
            pass

    # runoff rainfall, era5melt, tempmelt
    if ds_runoff is not None:
        try:
            da = ds_runoff.sel(latitude=lat, longitude=lon, method="nearest")
            da_t = _time_filter_valid(da)
            result["rainfall"] = float(da_t["rainfall"].values)
            result["era5melt"] = float(da_t["era5melt"].values)
            result["tempmelt"] = float(da_t["tempmelt"].values)
        except Exception:
            pass

    # flow rainfall_flow, era5melt_flow, tempmelt_flow
    if ds_flow is not None:
        try:
            da = ds_flow.sel(latitude=lat, longitude=lon, method="nearest")
            da_t = _time_filter_time(da)
            result["rainfall_flow"] = float(da_t["rainfall_flow"].values)
            result["era5melt_flow"] = float(da_t["era5melt_flow"].values)
            result["tempmelt_flow"] = float(da_t["tempmelt_flow"].values)
        except Exception:
            pass

    return result


def attach_model_values_by_station(
    obs_df,
    ttp_dsets,
    runoff_dsets,
    flow_dsets,
    region_bounds,
):
    # Prepare result container aligned with obs_df.index
    out = pd.DataFrame(
        {
            "tp": np.nan,
            "tmean": np.nan,
            "rainfall": np.nan,
            "era5melt": np.nan,
            "tempmelt": np.nan,
            "rainfall_flow": np.nan,
            "era5melt_flow": np.nan,
            "tempmelt_flow": np.nan,
        },
        index=obs_df.index,
    )

    # Group by station so we only do region lookup and dataset selection once per station
    grouped = obs_df.groupby("station_id", sort=False)

    for station_id, g in tqdm(grouped, total=len(grouped)):
        # Same lat/lon for each station
        lat = float(g["lat"].iloc[0])
        lon = float(g["lon"].iloc[0])

        region = find_region_for_latlon(lat, lon, region_bounds)
        if region is None:
            # No matching region; leave NaNs
            continue

        ds_ttp = ttp_dsets.get(region, None)
        ds_runoff = runoff_dsets.get(region, None)
        ds_flow = flow_dsets.get(region, None)

        # Apply extraction row-wise for this station subset
        for idx, row in g.iterrows():
            vals = extract_values_for_obs_row(
                row,
                ds_ttp=ds_ttp,
                ds_runoff=ds_runoff,
                ds_flow=ds_flow,
            )
            for k, v in vals.items():
                out.at[idx, k] = v

    # Concatenate with original obs_df
    out = out.reset_index(drop=True)
    obs_reset = obs_df.reset_index(drop=True)
    combined = pd.concat([obs_reset, out], axis=1)
    return combined


combined = attach_model_values_by_station(
    obs,
    ttp_dsets=ttp_dsets,
    runoff_dsets=runoff_dsets,
    flow_dsets=flow_dsets,
    region_bounds=region_bounds,
)

combined.to_csv("streamflow_model_monthly_combined.csv", index=False)
