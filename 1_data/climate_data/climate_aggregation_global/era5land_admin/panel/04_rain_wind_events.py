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
from settings import COUNTRIES, OUTPUT_ROOT, PRODUCT, climate_file, country, monthly_climate_file  # noqa: E402
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
OUTPUT_DIR = OUTPUT_ROOT / PRODUCT / "combined/current_boundaries/daily_rain_event_wind_overlap"
CURRENT_COUNTRIES = pd.read_csv(CLIMATE_ADMIN / "shapefiles_current.csv")["country"].tolist()


# -----------------------------
# Arguments
# -----------------------------

def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    # Country and year arguments make it easy to run smaller Slurm jobs.
    parser.add_argument("--countries", nargs="+", default=CURRENT_COUNTRIES)
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
    # Include adjacent-year dates for rain on January 1 or December 31.
    if events.empty:
        return []

    wanted = set()
    for date in events["date"].drop_duplicates():
        for offset in WINDOW_DAYS:
            shifted = date + pd.Timedelta(days=offset)
            wanted.add(shifted)
    return sorted(wanted)


def aggregate_daily_wind(wind, day_numbers, all_dates, flat_indices, matrices, admins, flip_latitude=False):
    # For each needed day, read raw wind at weighted grid cells and aggregate it
    # to admin units with the existing population and area weights.
    # Read the country rectangle, not the full globe for every event day.
    n_rows, n_columns = wind.shape[1:]
    rows, columns = np.divmod(flat_indices, n_columns)
    row_min, row_max = int(rows.min()), int(rows.max())
    col_min, col_max = int(columns.min()), int(columns.max())
    local_flat = (rows - row_min) * (col_max - col_min + 1) + columns - col_min
    first_row, last_row = (n_rows - 1 - row_max, n_rows - row_min) if flip_latitude else (row_min, row_max + 1)
    day_frames = []
    for day_number in day_numbers:
        raw = np.ma.asarray(wind[day_number:day_number + 1, first_row:last_row, col_min:col_max + 1])
        raw = np.ma.filled(raw, np.nan).astype("float64", copy=False)
        if flip_latitude:
            raw = raw[:, ::-1, :]
        raw = raw.reshape(1, -1)[:, local_flat]
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
    window_days_observed = []
    for row in events[["date", "region_id"]].itertuples(index=False):
        keys = [(row.date + pd.Timedelta(days=offset), row.region_id) for offset in WINDOW_DAYS]
        window_wind = wind_lookup.reindex(keys)
        window_days_observed.append(int(window_wind["windmax_pop_day"].notna().sum()))
        for column in WIND_COLUMNS:
            window_values[column].append(window_wind[column].max(skipna=True))

    for source, target in {
        "windmax_pop_day": "windmax_pop_pm1day",
        "windmax_area_day": "windmax_area_pm1day",
        "windshare_17p5_pop_day": "windshare_17p5_pop_pm1day",
        "windshare_17p5_area_day": "windshare_17p5_area_pm1day",
    }.items():
        merged[target] = window_values[source]
    merged["wind_window_days_observed"] = window_days_observed
    return merged


def build_country_year_events(spec, year):
    events, coverage = read_daily_rain_events(spec, year)
    if events.empty:
        return events, coverage

    grid = read_grid(climate_file(spec, "tp_total", spec.grid_year))
    admins, flat_indices, matrices = load_weights(spec, grid)
    wanted_dates = event_window_dates(events, year)
    wind_frames = []

    # Usually this reads one year. Events at New Year can also need one day
    # from the preceding or following year.
    for wind_year in sorted({date.year for date in wanted_dates}):
        paths = [monthly_climate_file("wind_max", wind_year, month) for month in range(1, 13)]
        missing = [path for path in paths if not path.is_file()]
        if missing:
            if wind_year == year:
                raise FileNotFoundError(f"Missing event-year wind: {missing[0]}")
            # At the edge of the raw history, keep the missing day visible.
            continue
        data = None
        try:
            data, wind, all_dates, flip_latitude = open_wind_file(spec, wind_year, grid)
            local_flat, local_matrices = apply_wind_fallback(
                spec, wind_year, grid, wind, admins, flat_indices, matrices, flip_latitude
            )
            day_numbers = [int(all_dates.get_loc(date)) for date in wanted_dates if date.year == wind_year]
            wind_frames.append(aggregate_daily_wind(
                wind, day_numbers, all_dates, local_flat, local_matrices, admins, flip_latitude
            ))
        finally:
            if data is not None:
                data.close()

    daily_wind = pd.concat(wind_frames, ignore_index=True)
    events = add_window_wind(events, daily_wind)
    observed_dates = set(pd.to_datetime(daily_wind["date"]))
    coverage["missing_window_dates"] = sum(date not in observed_dates for date in wanted_dates)
    coverage["event_dates_with_wind"] = len(observed_dates)
    coverage["events_with_same_day_wind"] = int(events["windmax_pop_day"].notna().sum())
    coverage["events_with_pm1day_wind"] = int(events["windmax_pop_pm1day"].notna().sum())
    return events, coverage


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


# -----------------------------
# Event flags and country run
# -----------------------------

def add_threshold_flags(events):
    events = events.copy()
    for threshold in RAIN_THRESHOLDS_MM:
        events[f"rain_ge_{threshold}mm"] = events["prcp_pop_p1"] >= threshold
    for source, target, cutoff in (
        ("windmax_pop_day", "windmean_ge_17p5_pop_day", HIGH_WIND_THRESHOLD_MS),
        ("windmax_pop_pm1day", "windmean_ge_17p5_pop_pm1day", HIGH_WIND_THRESHOLD_MS),
        ("windshare_17p5_pop_day", "any_pop_above_17p5_day", 0),
        ("windshare_17p5_pop_pm1day", "any_pop_above_17p5_pm1day", 0),
    ):
        high = events[source] > cutoff if "windshare" in source else events[source] >= cutoff
        observed = events[source].notna()
        if "pm1day" in source:
            # A known high-wind day proves overlap. An incomplete low-wind
            # window cannot prove there was no overlap on the missing day.
            observed &= (events["wind_window_days_observed"] == 3) | high
        events[target] = high.astype("boolean").where(observed)
    return events


def main():
    args = parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    all_events = []
    coverage_rows = []
    for code in args.countries:
        spec = country(code)
        first_year = spec.first_year if args.start_year is None else max(spec.first_year, args.start_year)
        last_year = spec.last_year if args.end_year is None else min(spec.last_year, args.end_year)
        for year in range(first_year, last_year + 1):
            print(f"{spec.code} {year}", flush=True)
            events, coverage = build_country_year_events(spec, year)
            if coverage["status"] == "missing_daily_file":
                raise FileNotFoundError(f"Missing daily precipitation: {spec.code} {year}")
            coverage_rows.append(coverage)
            if not events.empty:
                all_events.append(events)

    # Write a header even when a country has no >=100 mm events in any year.
    columns = ["climate_country", "region_id", "year", "date", "prcp_pop_p1", *WIND_COLUMNS,
               "windmax_pop_pm1day", "windmax_area_pm1day", "windshare_17p5_pop_pm1day",
               "windshare_17p5_area_pm1day", "wind_window_days_observed"]
    events = pd.concat(all_events, ignore_index=True) if all_events else pd.DataFrame(columns=columns)
    events = add_threshold_flags(events)
    country_year = summarize_country_year(events, coverage_rows)
    atomic_csv(events, args.output_dir / "daily_extreme_rain_wind_events_ge100mm.csv")
    atomic_csv(country_year, args.output_dir / "daily_precip_wind_country_year_summary.csv")
    print(f"wrote={args.output_dir} events={len(events)}", flush=True)


if __name__ == "__main__":
    main()
