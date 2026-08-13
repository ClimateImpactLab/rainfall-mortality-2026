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
    ds_flow = xr.open_dataset(f_flow, chunks={"valid_time": 100}) if os.path.exists(f_flow) else None

    if ds_ttp is not None:
        ttp_dsets[region] = ds_ttp[["tp", "tmean"]]
    if ds_runoff is not None:
        runoff_dsets[region] = ds_runoff[["rainfall", "era5melt", "tempmelt"]]
    if ds_flow is not None:
        flow_dsets[region] = ds_flow[["rainfall_flow", "era5melt_flow", "tempmelt_flow"]]

    ds_for_bounds = ds_ttp or ds_runoff or ds_flow
    if ds_for_bounds is not None:
        lats = ds_for_bounds["latitude"]
        lons = ds_for_bounds["longitude"]
        region_bounds[region] = {
            "lat_min": float(lats.min()),
            "lat_max": float(lats.max()),
            "lon_min": float(lons.min()),
            "lon_max": float(lons.max()),
        }

# Helper: region lookup

def find_region_for_latlon(lat, lon, region_bounds, buffer_deg=0.05):
    for region, b in region_bounds.items():
        if (
            (b["lat_min"] - buffer_deg) <= lat <= (b["lat_max"] + buffer_deg)
            and (b["lon_min"] - buffer_deg) <= lon <= (b["lon_max"] + buffer_deg)
        ):
            return region
    return None


# Faster station-wise extraction

def get_grid_indices(ds, lat, lon):
    """Return nearest (lat_idx, lon_idx) for a dataset."""
    # We only compute index selection once, then reuse as integers
    lat_idx = int(abs(ds["latitude"] - lat).argmin())
    lon_idx = int(abs(ds["longitude"] - lon).argmin())
    return lat_idx, lon_idx


def build_time_lookup(ds, time_dim="valid_time"):
    """
    Build a dict mapping (year, month) -> integer index along time_dim.
    Assumes one entry per month; if multiple exist, takes the first.
    """
    if ds is None or time_dim not in ds.coords:
        return {}

    t = ds[time_dim]
    years = t.dt.year.values
    months = t.dt.month.values

    lookup = {}
    for i, (y, m) in enumerate(zip(years, months)):
        key = (int(y), int(m))
        if key not in lookup:
            lookup[key] = i
    return lookup


def extract_for_station(station_df, ds_ttp, ds_runoff, ds_flow):
    """
    station_df: subset of obs for a single station_id.
    ds_*: regional datasets for that station's region (can be None).
    Returns a DataFrame with model columns for this station.
    """

    lat = float(station_df["lat"].iloc[0])
    lon = float(station_df["lon"].iloc[0])

    # Precompute grid indices per dataset (if present)
    if ds_ttp is not None:
        ttp_lat_idx, ttp_lon_idx = get_grid_indices(ds_ttp, lat, lon)
        ttp_time_lookup = build_time_lookup(ds_ttp, time_dim="valid_time")
    else:
        ttp_lat_idx = ttp_lon_idx = None
        ttp_time_lookup = {}

    if ds_runoff is not None:
        ro_lat_idx, ro_lon_idx = get_grid_indices(ds_runoff, lat, lon)
        ro_time_lookup = build_time_lookup(ds_runoff, time_dim="valid_time")
    else:
        ro_lat_idx = ro_lon_idx = None
        ro_time_lookup = {}

    if ds_flow is not None:
        fl_lat_idx, fl_lon_idx = get_grid_indices(ds_flow, lat, lon)
        fl_time_lookup = build_time_lookup(ds_flow, time_dim="valid_time")
    else:
        fl_lat_idx = fl_lon_idx = None
        fl_time_lookup = {}

    # Prepare result table for this station
    res = pd.DataFrame(
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
        index=station_df.index,
    )

    # Loop rows for this station, but using cheap integer indexing + prebuilt time lookups
    for idx, row in station_df.iterrows():
        y = int(row["year"])
        m = int(row["month"])

        # ttp
        if ds_ttp is not None:
            ti = ttp_time_lookup.get((y, m), None)
            if ti is not None:
                # integer-based selection: tiny task
                sub = ds_ttp.isel(valid_time=ti,
                                  latitude=ttp_lat_idx,
                                  longitude=ttp_lon_idx)
                # sub["tp"] and sub["tmean"] should be scalar
                res.at[idx, "tp"] = float(sub["tp"].values)
                res.at[idx, "tmean"] = float(sub["tmean"].values)

        # runoff
        if ds_runoff is not None:
            ti = ro_time_lookup.get((y, m), None)
            if ti is not None:
                sub = ds_runoff.isel(valid_time=ti,
                                     latitude=ro_lat_idx,
                                     longitude=ro_lon_idx)
                res.at[idx, "rainfall"] = float(sub["rainfall"].values)
                res.at[idx, "era5melt"] = float(sub["era5melt"].values)
                res.at[idx, "tempmelt"] = float(sub["tempmelt"].values)

        # flow
        if ds_flow is not None:
            ti = fl_time_lookup.get((y, m), None)
            if ti is not None:
                sub = ds_flow.isel(valid_time=ti,
                                   latitude=fl_lat_idx,
                                   longitude=fl_lon_idx)
                res.at[idx, "rainfall_flow"] = float(sub["rainfall_flow"].values)
                res.at[idx, "era5melt_flow"] = float(sub["era5melt_flow"].values)
                res.at[idx, "tempmelt_flow"] = float(sub["tempmelt_flow"].values)

    return res


# Streaming to CSV station-by-station

output_file = "streamflow_model_monthly_combined.csv"
if os.path.exists(output_file):
    prevs = pd.read_csv(output_file)
    skipids = prevs['station_id'].unique()
else:
    skipids = []
first = len(skipids) == 0  # to control header writing

grouped = obs.groupby("station_id", sort=False)

for station_id, g in tqdm(grouped, total=len(grouped)):
    if station_id in skipids:
        continue
    
    lat = float(g["lat"].iloc[0])
    lon = float(g["lon"].iloc[0])

    region = find_region_for_latlon(lat, lon, region_bounds)
    if region is None:
        # No matching region: write station rows with NaNs in model columns
        model_vals = pd.DataFrame(
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
            index=g.index,
        )
    else:
        ds_ttp = ttp_dsets.get(region, None)
        ds_runoff = runoff_dsets.get(region, None)
        ds_flow = flow_dsets.get(region, None)

        model_vals = extract_for_station(g, ds_ttp, ds_runoff, ds_flow)

    # combine for this station
    station_combined = pd.concat(
        [g.reset_index(drop=True), model_vals.reset_index(drop=True)],
        axis=1,
    )

    # append to CSV
    mode = "w" if first else "a"
    header = first
    station_combined.to_csv(output_file, mode=mode, header=header, index=False)
    first = False
