#!/usr/bin/env python3
"""
04_rain_wind_events.py

Build country-level daily rain-event wind files.

This script starts from existing daily admin precipitation files, finds
admin-days with rainfall >= 100 mm, and adds ERA5-Land windspeed for the
rain date and the day before/after. It reads raw wind only for heavy-rain 
event dates, not for every admin-day.

Inputs:
- daily admin ERA5-Land files with `prcp_pop_p1`
- raw daily ERA5-Land `wind_max` NetCDF files
- admin-grid weights from `01_make_weights.py`

Outputs:
- event-level country rain/wind CSV
- country-year rain/wind coverage and summary CSV

Combined review tables are written by `05_combine_rain_wind_events.py`.
"""

# ------------------
# Packages
# ------------------


import argparse
from pathlib import Path
import sys

sys.dont_write_bytecode = True

import numpy as np
import pandas as pd


# -----------------------------
# Paths
# -----------------------------

# Use the shared ERA5-Land admin settings and aggregation readers.
CLIMATE_ADMIN = Path(__file__).resolve().parents[1]
CLIMATE_AGGREGATION = CLIMATE_ADMIN / "aggregation_scripts"

sys.path.insert(0, str(CLIMATE_ADMIN))
sys.path.insert(0, str(CLIMATE_AGGREGATION))

from common import (  # noqa: E402
    admin_climate_paths,
    atomic_csv,
    load_weights,
    read_cells,
    read_grid,
)
from settings import COUNTRIES, OUTPUT_ROOT, PRODUCT, climate_file, country  # noqa: E402
from wind_common import apply_wind_fallback, open_wind_file  # noqa: E402


# -----------------------------
# Choices
# -----------------------------

# Rain events start at 100 mm. 200 and 300 mm are kept for review flags.
RAIN_THRESHOLDS_MM = (100, 200, 300)
MIN_RAIN_THRESHOLD_MM = min(RAIN_THRESHOLDS_MM)

# Same high-wind cutoff used in the annual wind exposure files.
HIGH_WIND_THRESHOLD_MS = 17.5

# Pull wind on the rain date and the adjacent days.
WINDOW_DAYS = (-1, 0, 1)

# Same-day wind and +/-1 day wind are both kept in the event file.
WIND_COLUMNS = [
    "windmax_pop_day",
    "windmax_area_day",
    "windshare_17p5_pop_day",
    "windshare_17p5_area_day",
]

# Country jobs write here before 05 stacks the files.
OUTPUT_DIR = OUTPUT_ROOT / PRODUCT / "combined/daily_rain_event_wind_overlap"


# -----------------------------
# Arguments
# -----------------------------

def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    # Country and year arguments make it easy to run smaller Slurm jobs.
    parser.add_argument("--countries", nargs="+", default=sorted(COUNTRIES))
    parser.add_argument("--start-year", type=int)
    parser.add_argument("--end-year", type=int)
    parser.add_argument("--output-dir", type=Path, default=OUTPUT_DIR)
    return parser.parse_args()


# -----------------------------
# Daily rain events
# -----------------------------

def read_daily_rain_events(spec, year):
    path = admin_climate_paths(spec, year)["daily"]
    if not path.is_file():
        # Missing daily rain files are recorded in coverage.
        return pd.DataFrame(), {
            "climate_country": spec.code,
            "year": year,
            "status": "missing_daily_file",
            "daily_rows": 0,
            "admin_units": 0,
            "events_ge_100mm": 0,
            "events_ge_200mm": 0,
            "events_ge_300mm": 0,
        }

    # Daily rain is already aggregated to admin units. This script does not
    # reopen raw precipitation grids.
    daily = pd.read_csv(
        path,
        usecols=["date", "region_id", *spec.id_columns, "prcp_pop_p1"],
        dtype={"region_id": "string", **{column: "string" for column in spec.id_columns}},
    )
    daily["date"] = pd.to_datetime(daily["date"], errors="coerce")
    daily["prcp_pop_p1"] = pd.to_numeric(daily["prcp_pop_p1"], errors="coerce")

    # Keep the event file at >=100 mm.
    # Coverage also counts the >=200 and >=300 mm subsets for quick review.
    events = daily.loc[daily["prcp_pop_p1"] >= MIN_RAIN_THRESHOLD_MM].copy()
    events.insert(0, "year", year)
    events.insert(0, "climate_country", spec.code)

    coverage = {
        "climate_country": spec.code,
        "year": year,
        "status": "ok",
        "daily_rows": len(daily),
        "admin_units": daily["region_id"].nunique(),
        "events_ge_100mm": len(events),
        "events_ge_200mm": int((daily["prcp_pop_p1"] >= 200).sum()),
        "events_ge_300mm": int((daily["prcp_pop_p1"] >= 300).sum()),
        "max_prcp_pop_p1": float(daily["prcp_pop_p1"].max(skipna=True)),
    }
    return events, coverage


# -----------------------------
# Wind for event dates
# -----------------------------

def event_window_dates(events, year):
    # Read wind only for rain dates and t-1/t/t+1, within the same year.
    if events.empty:
        return []

    wanted = set()
    first = pd.Timestamp(f"{year}-01-01")
    last = pd.Timestamp(f"{year}-12-31")
    for date in events["date"].drop_duplicates():
        for offset in WINDOW_DAYS:
            shifted = date + pd.Timedelta(days=offset)
            if first <= shifted <= last:
                wanted.add(shifted)
    return sorted(wanted)


def aggregate_daily_wind(wind, day_numbers, all_dates, flat_indices, matrices, admins, flip_latitude=False):
    # For each needed day, read raw wind at weighted grid cells and aggregate it
    # to admin units with the existing population and area weights.
    day_frames = []
    for day_number in day_numbers:
        raw = read_cells(wind, day_number, day_number + 1, flat_indices, flip_latitude)
        valid = np.isfinite(raw)
        high_wind = np.where(valid, raw > HIGH_WIND_THRESHOLD_MS, np.nan)
        day_values = {"date": all_dates[day_number].strftime("%Y-%m-%d")}

        for weighting, matrix in matrices.items():
            # Mean wind and high-wind share use the same finite-cell denominator.
            denominator = np.asarray(matrix @ valid.T).T
            numerator = np.asarray(matrix @ np.where(valid, raw, 0).T).T
            wind_mean = np.full(numerator.shape, np.nan)
            np.divide(numerator, denominator, out=wind_mean, where=denominator > 0)

            high_wind_numerator = np.asarray(matrix @ np.where(valid, high_wind, 0).T).T
            high_wind_share = np.full(high_wind_numerator.shape, np.nan)
            np.divide(
                high_wind_numerator,
                denominator,
                out=high_wind_share,
                where=denominator > 0,
            )

            day_values[f"windmax_{weighting}_day"] = wind_mean.ravel()
            day_values[f"windshare_17p5_{weighting}_day"] = high_wind_share.ravel()

        day_frame = pd.DataFrame({"date": day_values["date"], "region_id": admins["region_id"]})
        for column in WIND_COLUMNS:
            day_frame[column] = day_values[column]
        day_frames.append(day_frame)

    if not day_frames:
        return pd.DataFrame(columns=["date", "region_id", *WIND_COLUMNS])
    return pd.concat(day_frames, ignore_index=True)


def add_window_wind(events, daily_wind):
    if events.empty:
        return events

    events = events.copy()
    events["date"] = pd.to_datetime(events["date"])
    daily_wind = daily_wind.copy()
    daily_wind["date"] = pd.to_datetime(daily_wind["date"])

    # Same-day measures use t.
    merged = events.merge(daily_wind, on=["date", "region_id"], how="left")
    wind_lookup = daily_wind.set_index(["date", "region_id"])

    # +/-1 day allows for storm timing and UTC/local-day mismatch.
    # pm1day measures use the max over t-1, t, t+1.
    window_values = {column: [] for column in WIND_COLUMNS}
    for row in events[["date", "region_id"]].itertuples(index=False):
        keys = [(row.date + pd.Timedelta(days=offset), row.region_id) for offset in WINDOW_DAYS]
        window_wind = wind_lookup.reindex(keys)
        for column in WIND_COLUMNS:
            window_values[column].append(window_wind[column].max(skipna=True))

    for source, target in {
        "windmax_pop_day": "windmax_pop_pm1day",
        "windmax_area_day": "windmax_area_pm1day",
        "windshare_17p5_pop_day": "windshare_17p5_pop_pm1day",
        "windshare_17p5_area_day": "windshare_17p5_area_pm1day",
    }.items():
        merged[target] = window_values[source]
    return merged


def build_country_year_events(spec, year):
    events, coverage = read_daily_rain_events(spec, year)
    if events.empty:
        # No >=100 mm rain events in this country-year, keep the coverage row.
        return events, coverage

    wind_path = climate_file(spec, "wind_max", year)
    if not wind_path.is_file():
        # Rain events still exist, but this country-year has no raw wind file.
        # Keep the event rows and leave wind measures missing.
        coverage["status"] = "missing_wind_file"
        for column in [
            *WIND_COLUMNS,
            "windmax_pop_pm1day",
            "windmax_area_pm1day",
            "windshare_17p5_pop_pm1day",
            "windshare_17p5_area_pm1day",
        ]:
            events[column] = np.nan
        return events, coverage

    # Load the grid and admin weights used by the admin climate aggregation.
    # The precipitation file gives the grid definition, wind is read on that grid below.
    grid = read_grid(climate_file(spec, "tp_total", spec.grid_year))
    admins, flat_indices, matrices = load_weights(spec, grid)

    data = None
    try:
        data, wind, all_dates, flip_latitude = open_wind_file(spec, year, grid)

        # A few islands need the wind-only fallback because the usual weighted
        # cells have no finite wind values.
        flat_indices, matrices = apply_wind_fallback(
            spec, year, grid, wind, admins, flat_indices, matrices, flip_latitude
        )

        # Only read wind on rain-event dates and the adjacent days.
        wanted_dates = event_window_dates(events, year)
        day_numbers = [int(all_dates.get_loc(date)) for date in wanted_dates]
        daily_wind = aggregate_daily_wind(
            wind, day_numbers, all_dates, flat_indices, matrices, admins, flip_latitude
        )

        # Attach same-day wind and max wind over t-1/t/t+1 to each rain event.
        events = add_window_wind(events, daily_wind)

        # Coverage records how much of the rain-event file received wind values.
        coverage["event_dates_with_wind"] = len(day_numbers)
        coverage["events_with_same_day_wind"] = int(events["windmax_pop_day"].notna().sum())
        coverage["events_with_pm1day_wind"] = int(events["windmax_pop_pm1day"].notna().sum())
        return events, coverage
    finally:
        if data is not None:
            data.close()


# -----------------------------
# Country outputs
# -----------------------------

def summarize_country_year(events, coverage_rows):
    # Country-year summary keeps missing-file and no-event years visible.
    coverage = pd.DataFrame(coverage_rows)
    if events.empty:
        return coverage

    summary = (
        events.groupby(["climate_country", "year"], dropna=False)
        .agg(
            max_prcp_event=("prcp_pop_p1", "max"),
            max_wind_pop_pm1day=("windmax_pop_pm1day", "max"),
            events_any_pop_above_17p5_pm1day=("any_pop_above_17p5_pm1day", "sum"),
            events_windmean_ge_17p5_pm1day=("windmean_ge_17p5_pop_pm1day", "sum"),
        )
        .reset_index()
    )
    return coverage.merge(summary, on=["climate_country", "year"], how="left")


m
