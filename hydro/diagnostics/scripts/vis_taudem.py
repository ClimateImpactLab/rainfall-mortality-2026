# Accumulated rainfall flow over the TauDEM D8 network, USA.
#
# Purpose: check that rainfall_flow looks like a river network -- that accumulation
#   grows downstream and tracks TauDEM's own upstream cell count (aread8) at known
#   gauge locations.
#
# Inputs:  {test vintage}/usa_monthly_flow.nc4      var rainfall_flow
#          composite_01deg_ad8.tif                 TauDEM D8 contributing area,
#                                                   produced by run_aread8.sh
#          lsm.area-subset.90.180.-90.-180.nc       ERA5-Land land-sea mask
#
# Outputs: output/taudem_flow/usa_rainfall_flow_map.png
#          output/taudem_flow/flow_panel_{basin}.png  one per window in PANELS
#
# Dependencies: numpy, xarray, matplotlib, cartopy, rasterio
#
# Run: sbatch hydro/diagnostics/scripts/vis_taudem.sh

import os
import pathlib
import xarray as xr
import numpy as np
import matplotlib
matplotlib.use("Agg")  # runs headless under SLURM
import matplotlib.pyplot as plt
import cartopy.crs as ccrs
import cartopy.feature as cfeature
import rasterio

home_dir   = pathlib.Path("/Volumes/cil") if pathlib.Path("/Volumes/cil").exists() else pathlib.Path("/project/cil")
script_dir = pathlib.Path(__file__).parents[1]

INPUT_FILE = str(home_dir / "gcp/climate/ERA5-LAND/processed/monthly/test/usa_monthly_flow.nc4")
OUTPUT_DIR = str(script_dir / "output/taudem_flow")
os.makedirs(OUTPUT_DIR, exist_ok=True)

# TauDEM D8 contributing area
AD8 = str(home_dir / "gcp/climate/taudem_conus/geo_working/composite_01deg_ad8.tif")

# ERA5-Land land-sea mask
LSM = str(home_dir / "gcp/climate/taudem_conus/geo_working/lsm.area-subset.90.180.-90.-180.nc")
LAND_MIN = 0.2

# Gauge locations and basin windows. Originally from the check_network.py network
# validation, which has since been removed; these are the surviving record of them.
CITIES = [
    ("Mississippi at Vicksburg MS",   32.3150,  -90.9062),
    ("Mississippi at Memphis TN",     35.1237,  -90.0684),
    ("Mississippi at Thebes IL",      37.2217,  -89.4634),
    ("Mississippi at St Louis MO",    38.6290,  -90.1799),
    ("Missouri at Hermann MO",        38.7098,  -91.4388),
    ("Columbia at The Dalles OR",     45.6073, -121.1725),
    ("Ohio at Metropolis IL",         37.1520,  -88.7400),
    ("Arkansas at Little Rock AR",    34.7500,  -92.2830),
    ("Colorado at Lees Ferry AZ",     36.8650, -111.5880),
    ("Rio Grande at El Paso TX",      31.7990, -106.5450),
    ("Susquehanna at Harrisburg PA",  40.2550,  -76.8860),
    ("Sacramento at Freeport CA",     38.4560, -121.5000),
    ("Tennessee at Chattanooga TN",   35.0553,  -85.3100),
]

PANELS = [
    ("ohio_mississippi_confluence", (33.0, 41.0), (-93.0, -83.0)),
    ("missouri",                    (38.0, 48.0), (-105.0, -90.0)),
    ("columbia",                    (42.0, 50.0), (-124.0, -113.0)),
    ("colorado",                    (33.0, 42.0), (-114.0, -105.0)),
]

print(f"Reading {INPUT_FILE}")
ds = xr.open_dataset(INPUT_FILE)
lats = ds.latitude.values
lons = ds.longitude.values

# Build peak across all months in yearly chunks to stay within memory
print("Computing peak across all months (yearly chunks)...")
rf = ds["rainfall_flow"]
peak = rf.isel(valid_time=slice(0, 12)).max(dim="valid_time").values.astype(float)
for yr_start in range(12, len(rf.valid_time), 12):
    chunk = rf.isel(valid_time=slice(yr_start, yr_start + 12)).max(dim="valid_time").values.astype(float)
    peak = np.maximum(peak, chunk)
print(f"  Peak range: {peak[peak > 0].min():.1f} – {np.nanmax(peak):.1f} mm")

# Time-mean flow, same yearly chunking as the peak loop above 
print("Computing time mean across all months (yearly chunks)...")
n_months = len(rf.valid_time)
total = np.zeros_like(peak)
for yr_start in range(0, n_months, 12):
    total += rf.isel(valid_time=slice(yr_start, yr_start + 12)).sum(
        dim="valid_time").values.astype(float)
mean_flow = total / n_months
print(f"  {n_months} months; mean range over flowing cells: "
      f"{mean_flow[peak > 0].min():.1f} – {mean_flow[peak > 0].max():.1f} mm")


# Land-sea mask on the flow grid. Read the same way diagnostics.py does: the file
# repeats lon/lat values at its edges, so deduplicate before use (np.unique also
# sorts, which is harmless here since the match below is by nearest index).
lsm_ds = xr.open_dataset(LSM)
lsm_da = lsm_ds["lsm"]
if "time" in lsm_da.dims:
    lsm_da = lsm_da.isel(time=0)
lsm_da = lsm_da.load()
_, lon_idx = np.unique(lsm_da.longitude.values, return_index=True)
_, lat_idx = np.unique(lsm_da.latitude.values, return_index=True)
lsm_da = lsm_da.isel(longitude=lon_idx, latitude=lat_idx)

# The LSM uses 0-360 longitude; the flow grid uses -180-180.
lsm_lats = lsm_da.latitude.values
lsm_lons = ((lsm_da.longitude.values + 180) % 360) - 180
si = np.abs(lsm_lats[None, :] - lats[:, None]).argmin(axis=1)
sj = np.abs(lsm_lons[None, :] - lons[:, None]).argmin(axis=1)
is_land = lsm_da.values[np.ix_(si, sj)] >= LAND_MIN
lsm_ds.close()
print(f"  land mask: {is_land.sum():,} of {is_land.size:,} cells have lsm >= {LAND_MIN}")

# Mask non-positive cells (no-flow) and sea cells
data = peak.copy()
data[data <= 0] = np.nan
data[~is_land] = np.nan

# Mask the mean with the PEAK mask, not its own. A cell whose peak is positive but
# whose mean is not (possible: prepflow's rainfall can go negative, see
# diagnostics.py) must still be excluded from both panels rather than from one, so
# the two flow panels below cover identical cells.
mean_data = mean_flow.copy()
mean_data[peak <= 0] = np.nan
# A cell that is NaN in every month is NaN in peak (.max keeps all-NaN as NaN) but
# EXACTLY 0.0 in mean (.sum with skipna=True returns 0 for an all-NaN slice). NaN <= 0
# is False, so the line above does not catch those cells, and log10(0) = -inf then
# makes Normalize degenerate and paints every cell the darkest colour. Drop them on
# peak's finiteness, not on its sign.
mean_data[~np.isfinite(peak)] = np.nan
mean_data[~is_land] = np.nan
# Guard the log transform itself: rainfall can go negative (see diagnostics.py), so a
# negative mean is possible and log10 would return NaN silently.
mean_data[mean_data <= 0] = np.nan

# Shared colormap: NaN → white, low → light blue, high → dark blue
cmap = plt.cm.Blues.copy()
cmap.set_bad("white")

# Extent for imshow: [lon_min, lon_max, lat_min, lat_max]
# Latitude is ascending (south→north), so origin="lower" is correct. It used to be
# descending, which is why this was origin="upper" before: transform.py now applies
# sortby(["latitude", "longitude"]) to normalize the mixed orientations in the raw
# archive, so every file downstream of it is south-to-north. Getting this wrong does
# not error, it silently mirrors the map and puts the city markers on the wrong
# cells, so assert the direction rather than trusting the comment to stay true.
assert lats[0] < lats[-1], \
    "latitude is not ascending -- check origin= on the imshow calls below before plotting"
extent = [lons.min(), lons.max(), lats.min(), lats.max()]

log_data = np.log10(mean_data)
# Full data range, NOT percentiles. Assert finite: a single -inf here does not error,
# it silently collapses the colour scale and renders the whole map at one colour.
vmin = np.nanmin(log_data)
vmax = np.nanmax(log_data)
assert np.isfinite([vmin, vmax]).all(), \
    f"non-finite colour limits (log10 {vmin} - {vmax}) -- mean_data still contains 0 or negative values"
print(f"  colour range: log10 {vmin:.2f} – {vmax:.2f}")


# ── Plot 1: all positive-flow cells ──────────────────────────────────────────
fig, ax = plt.subplots(
    subplot_kw={"projection": ccrs.PlateCarree()},
    figsize=(16, 10),
)
im = ax.imshow(
    log_data,
    cmap=cmap,
    norm=plt.Normalize(vmin=vmin, vmax=vmax),
    interpolation="nearest",
    extent=extent,
    transform=ccrs.PlateCarree(),
    origin="lower",
)
plt.colorbar(im, ax=ax, label="log₁₀(mean monthly accumulated rainfall, mm)", shrink=0.7)
ax.add_feature(cfeature.COASTLINE, linewidth=0.6)
ax.add_feature(cfeature.BORDERS, linewidth=0.4, linestyle=":")
ax.set_title("Accumulated Rainfall Flow — USA (mean across all months, 0.1° grid)")
ax.axis("off")
plt.tight_layout()
plt.savefig(os.path.join(OUTPUT_DIR, "usa_rainfall_flow_map.png"), dpi=150, bbox_inches="tight")
plt.close()
print("Wrote usa_rainfall_flow_map.png")


# ══ Basin windows: accumulated rainfall vs the network it was accumulated on ══
# rainfall_flow is the upstream sum of monthly rainfall over the same D8 network
# whose upstream CELL COUNT aread8 reports. So
#
#     rainfall_flow(cell) = ad8(cell) x (mean monthly rainfall over the upstream area)
#
if not os.path.exists(AD8):
    raise SystemExit(f"missing {AD8} -- run run_aread8.sh first")

with rasterio.open(AD8) as src:
    acc = np.ma.filled(src.read(1, masked=True).astype(np.float64), np.nan)
    t = src.transform
    ad8_lons = t.c + (np.arange(acc.shape[1]) + 0.5) * t.a
    ad8_lats = t.f + (np.arange(acc.shape[0]) + 0.5) * t.e

# TauDEM sometimes writes -1 for nodata without declaring it in the header.
acc[acc < 0] = np.nan
print(f"\naread8: shape={acc.shape}  res={abs(t.e)}x{abs(t.a)}  "
      f"max={np.nanmax(acc):,.0f} cells")

# Resample aread8 onto the flow file's own grid ONCE, by nearest index
ai = np.abs(ad8_lats[None, :] - lats[:, None]).argmin(axis=1)
aj = np.abs(ad8_lons[None, :] - lons[:, None]).argmin(axis=1)
ad8 = acc[np.ix_(ai, aj)]
ad8[ad8 <= 0] = np.nan
# Same sea mask as the flow arrays, so all three panels cover identical cells and
# the outlet picked per window below cannot land on a sea cell.
ad8[~is_land] = np.nan
del acc


# ── Proportionality per basin window ─────────────────────────────────────────
print(f"\n{'basin window':<30}{'cells':>10}{'rainfall_mm':>14}{'ratio_mm':>10}")
for wname, lat_rng, lon_rng in PANELS:
    iw = np.flatnonzero((lats >= lat_rng[0]) & (lats <= lat_rng[1]))
    jw = np.flatnonzero((lons >= lon_rng[0]) & (lons <= lon_rng[1]))
    fw = mean_data[np.ix_(iw, jw)].ravel()
    aw = ad8[np.ix_(iw, jw)].ravel()
    ok = np.isfinite(fw) & np.isfinite(aw) & (fw > 0)
    if not ok.any():
        print(f"{wname:<30}   no flowing cells in window")
        continue
    k = int(np.nanargmax(np.where(ok, aw, np.nan)))
    n, s = float(aw[k]), float(fw[k])
    print(f"{wname:<30}{n:>10,.0f}{s:>14,.0f}{s / n:>10.1f}")


# ── Basin panels ──────────────────────────────────────────────────────────────
print("\nPanels:")
for pname, lat_rng, lon_rng in PANELS:
    iw = np.flatnonzero((lats >= lat_rng[0]) & (lats <= lat_rng[1]))
    jw = np.flatnonzero((lons >= lon_rng[0]) & (lons <= lon_rng[1]))
    sub_mean = mean_data[np.ix_(iw, jw)]
    sub_peak = data[np.ix_(iw, jw)]
    sub_ad8 = ad8[np.ix_(iw, jw)]
    panel_extent = [lons[jw].min(), lons[jw].max(), lats[iw].min(), lats[iw].max()]

    flow_vals = np.concatenate([sub_mean[np.isfinite(sub_mean)],
                                sub_peak[np.isfinite(sub_peak)]])
    flow_vals = flow_vals[flow_vals > 0]  # same -inf guard as the full-map limits above
    if flow_vals.size == 0:
        print(f"  {pname}: no flowing cells in window, skipped")
        continue
    fvmin, fvmax = np.log10(flow_vals.min()), np.log10(flow_vals.max())

    fig, axes = plt.subplots(1, 3, figsize=(21, 7))
    specs = [
        ("mean rainfall_flow", sub_mean, fvmin, fvmax, "log10(mean monthly accumulated rainfall, mm)"),
        ("peak rainfall_flow", sub_peak, fvmin, fvmax, "log10(peak monthly accumulated rainfall, mm)"),
        ("TauDEM aread8", sub_ad8, 0, 5, "log10(upstream 0.1° cell count)"),
    ]
    for ax, (title, arr, vlo, vhi, cbar_label) in zip(axes, specs):
        cmap = plt.cm.Blues.copy()
        cmap.set_bad("white")
        img = ax.imshow(np.log10(arr), cmap=cmap, vmin=vlo, vmax=vhi,
                        extent=panel_extent, origin="lower", interpolation="nearest")
        for cname, clat, clon in CITIES:
            if lat_rng[0] <= clat <= lat_rng[1] and lon_rng[0] <= clon <= lon_rng[1]:
                ax.plot(clon, clat, "r+", ms=13, mew=2)
                ax.annotate(cname.split(" at ")[-1], (clon, clat), fontsize=7,
                            color="red", xytext=(4, 4), textcoords="offset points")
        ax.set_title(f"{title}\nwindow max = {np.nanmax(arr):,.0f}")
        ax.set_xlabel("lon")
        ax.set_ylabel("lat")
        plt.colorbar(img, ax=ax, shrink=0.75, label=cbar_label)
    fig.suptitle(f"{pname} — accumulated rainfall flow vs taudem, 0.1° grid")
    fig.tight_layout()
    out = os.path.join(OUTPUT_DIR, f"flow_panel_{pname}.png")
    fig.savefig(out, dpi=160, bbox_inches="tight")
    plt.close(fig)
    print(f"  {out}")

print("\nDone.")
