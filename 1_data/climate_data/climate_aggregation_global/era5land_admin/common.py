"""
common.py

Common code for ERA5-Land admin aggregation.

These are the small pieces used in several scripts: basic checks, CSV writing,
admin ID cleanup, shapefile reading, and ERA5-Land grid reading.

Admin IDs are handled carefully because many country IDs have leading zeros.
They are treated as strings before they are used in file names, region IDs, or
merges.
"""

from dataclasses import dataclass
import calendar
import os
from pathlib import Path

import geopandas as gpd
import numpy as np
import pandas as pd
from netCDF4 import Dataset, num2date
from scipy import sparse
from shapely.geometry import box

from settings import Country, admin_file, result_dir, weights_file


class CheckError(RuntimeError):
    pass


POWERS = range(1, 6)

# Output names and the corresponding ERA5-Land variable names and units.
CLIMATE_VARIABLES = {
    "prcp": ("tp_total", "mm"),
    "tmean": ("tmean", "degC"),
    "tmax": ("tmax", "degC"),
}

WIND_OUTPUT_COLUMNS = [
    "windmax_pop_annual",
    "windmax_area_annual",
    "winddays_17p5_pop_annual",
    "winddays_17p5_area_annual",
]


def require(test: bool, message: str) -> None:
    if not test:
        raise CheckError(message)


def admin_climate_paths(spec: Country, year: int) -> dict[str, Path]:
    # Daily, monthly, and annual outputs use the same country/admin-level stem.
    root = result_dir(spec)
    stem = f"era5land_{spec.code.lower()}_{spec.level}"
    return {
        "daily": root / "daily" / f"{stem}_daily_{year}.csv",
        "monthly": root / "monthly" / f"{stem}_monthly_{year}.csv",
        "annual": root / "annual" / f"{stem}_annual_{year}.csv",
    }


def admin_climate_columns() -> list[str]:
    # Powers are calculated at the grid-cell level before spatial averaging.
    return [
        f"{variable}_{weighting}_p{power}"
        for variable in CLIMATE_VARIABLES
        for weighting in ("pop", "area")
        for power in POWERS
    ]


def admin_wind_path(spec: Country, year: int) -> Path:
    stem = f"era5land_{spec.code.lower()}_{spec.level}_wind_annual_{year}.csv"
    return result_dir(spec) / "wind" / stem


def admin_wind_columns(spec: Country) -> list[str]:
    return ["year", "region_id", *spec.id_columns, *WIND_OUTPUT_COLUMNS]


def atomic_csv(frame: pd.DataFrame, path: Path) -> None:
    # Write through a temporary file so a failed job does not leave a half-written CSV.
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp.csv")
    if temporary.exists():
        temporary.unlink()
    frame.to_csv(temporary, index=False, float_format="%.15g")
    os.replace(temporary, path)


def normalize_ids(frame: pd.DataFrame, spec: Country) -> pd.DataFrame:
    # Admin IDs must stay as strings. Many country IDs have leading zeros that
    # would be lost if pandas kept them numeric.
    frame = frame.copy()
    for column in spec.id_columns:
        require(column in frame, f"Missing ID column: {column}")
        width = spec.id_widths.get(column)
        values = frame[column]
        if pd.api.types.is_numeric_dtype(values):
            numeric = pd.to_numeric(values, errors="raise")
            require(np.isclose(numeric, np.round(numeric)).all(), f"{column} is not integer-valued")
            values = numeric.round().astype("int64").astype(str)
        else:
            values = values.astype("string").str.strip()
            numeric = pd.to_numeric(values, errors="coerce")
            whole_number = numeric.notna() & np.isclose(numeric, np.round(numeric))
            values = values.astype(object)
            values.loc[whole_number] = numeric.loc[whole_number].round().astype("int64").astype(str)
            values = values.astype("string")
        if width:
            values = values.str.zfill(width)
        require(values.notna().all() and (values != "").all(), f"{column} contains an empty ID")
        frame[column] = values
    return frame


def add_region_id(frame: pd.DataFrame, spec: Country) -> pd.DataFrame:
    # region_id is the climate-side admin key used by all ERA5-Land outputs
    frame = normalize_ids(frame, spec)
    joined = frame.loc[:, spec.id_columns].astype(str).agg("_".join, axis=1)
    frame.insert(0, "region_id", spec.code + "_" + joined)
    return frame


def ensure_region_id(frame: pd.DataFrame, spec: Country) -> pd.DataFrame:
    # Older files may not already contain region_id. If it exists, check that
    # it still agrees with the source admin IDs.
    if "region_id" not in frame:
        return add_region_id(frame, spec)

    frame = normalize_ids(frame, spec)
    expected = spec.code + "_" + frame.loc[:, spec.id_columns].astype(str).agg("_".join, axis=1)
    require(frame.region_id.astype(str).equals(expected), "region_id does not match the source IDs")
    return frame


def load_weights(spec: Country, grid: "Grid"):
    # Load the admin-grid weights and matching admin summary from 01_make_weights.py.
    require(weights_file(spec).is_file(), f"Missing weights: {weights_file(spec)}")
    require(admin_file(spec).is_file(), f"Missing admin summary: {admin_file(spec)}")

    # Read admin IDs as strings so leading zeros are preserved.
    # The fallback columns are text notes; keep them as text to avoid pandas warnings.
    dtype = {column: "string" for column in spec.id_columns}
    dtype.update({"popwt_fallback": "string", "areawt_fallback": "string"})
    weights = ensure_region_id(pd.read_csv(weights_file(spec), dtype=dtype), spec)
    admins = ensure_region_id(pd.read_csv(admin_file(spec), dtype=dtype), spec)

    # Fix the admin order here so all output arrays use the same order.
    admins = admins.sort_values("region_id").reset_index(drop=True)

    # The weight file stores ERA5-Land row and column indices from the pilot
    # file. Check that they still point to this grid.
    require(not admins.region_id.duplicated().any(), "Admin summary has duplicate IDs")
    require(
        not weights.duplicated(["region_id", "grid_row", "grid_column"]).any(),
        "Weights have duplicate admin-grid rows",
    )

    rows = weights.grid_row.to_numpy(dtype="int64")
    columns = weights.grid_column.to_numpy(dtype="int64")

    require(((rows >= 0) & (rows < len(grid.latitude))).all(), "Weight row is outside the climate grid")
    require(
        ((columns >= 0) & (columns < len(grid.longitude))).all(),
        "Weight column is outside the climate grid",
    )

    # Check coordinates as well as row/column indices. This catches a shifted
    # grid even if the array dimensions still match.
    require(np.allclose(weights.latitude, grid.latitude[rows]), "Weight latitudes differ from ERA5-Land")
    require(
        np.allclose(weights.longitude, grid.longitude[columns]),
        "Weight longitudes differ from ERA5-Land",
    )

    # Convert each ERA5-Land row/column pair to one flattened cell index.
    # Several admin units can use the same cell, so the climate data only need
    # to be read once for each unique cell.
    flat = rows * len(grid.longitude) + columns
    unique_flat, cell_number = np.unique(flat, return_inverse=True)

    # Assign each admin unit an integer row number in the weight matrices.
    admin_number = pd.Series(
        np.arange(len(admins)), index=admins.region_id
    ).loc[weights.region_id].to_numpy()

    matrices = {}
    for column, label in (("popwt", "pop"), ("areawt", "area")):
        # Sparse matrices let each daily block be aggregated without looping
        # over admin units.
        values = pd.to_numeric(weights[column], errors="raise").to_numpy()
        require(np.isfinite(values).all() and (values >= 0).all(), f"Invalid {column}")
        matrix = sparse.coo_matrix(
            (values, (admin_number, cell_number)),
            shape=(len(admins), len(unique_flat)),
        ).tocsr()
        matrix.sum_duplicates()
        matrices[label] = matrix

        # Admin units with coverage should have weights summing to one.
        sums = np.asarray(matrix.sum(axis=1)).ravel()
        covered = sums > 0
        require(np.allclose(sums[covered], 1), f"{column} does not sum to one")

    return admins, unique_flat, matrices


def dates(dataset, year: int) -> pd.DatetimeIndex:
    # The daily sequence must contain every calendar day exactly once and in
    # order. Monthly and annual aggregation depend on this being complete.
    require("valid_time" in dataset.variables, "Climate file has no valid_time")
    time = dataset.variables["valid_time"]
    decoded = num2date(
        time[:], time.units,
        calendar=getattr(time, "calendar", "proleptic_gregorian"),
        only_use_cftime_datetimes=False,
        only_use_python_datetimes=True,
    )
    found = pd.DatetimeIndex([value.isoformat()[:10] for value in decoded])
    expected = pd.date_range(f"{year}-01-01", f"{year}-12-31", freq="D")
    require(found.equals(expected), f"Daily dates are incomplete for {year}")
    return found


def month_dates(dataset, year: int, month: int) -> pd.DatetimeIndex:
    # The global raw files are monthly.
    # Each file should contain every day for that calendar month.
    require("valid_time" in dataset.variables, "Climate file has no valid_time")
    time = dataset.variables["valid_time"]
    decoded = num2date(
        time[:], time.units,
        calendar=getattr(time, "calendar", "proleptic_gregorian"),
        only_use_cftime_datetimes=False,
        only_use_python_datetimes=True,
    )
    found = pd.DatetimeIndex([value.isoformat()[:10] for value in decoded])
    start = f"{year}-{month:02d}-01"
    days = calendar.monthrange(year, month)[1]
    expected = pd.date_range(start, periods=days, freq="D")
    require(found.equals(expected), f"Daily dates are incomplete for {year}-{month:02d}")
    require(found.month.nunique() == 1 and found.month[0] == month, f"Wrong month in {year}-{month:02d}")
    return found


def cell_window(flat_indices, grid: "Grid"):
    # Global files are much larger than the old regional files.
    # Read only the rectangle that contains this country's weighted cells.
    rows = flat_indices // len(grid.longitude)
    columns = flat_indices % len(grid.longitude)
    row_min = int(rows.min())
    row_max = int(rows.max())
    col_min = int(columns.min())
    col_max = int(columns.max())

    # Convert global row/column addresses to row/column addresses inside
    # the smaller rectangle that will be read from the global file.
    width = col_max - col_min + 1
    local_flat = (rows - row_min) * width + (columns - col_min)
    return row_min, row_max, col_min, col_max, local_flat


def read_cells(variable, start: int, stop: int, flat_indices, flip_latitude: bool = False):
    # Read one block of days and keep only ERA5-Land cells used by the weights.
    values = np.ma.asarray(variable[start:stop])
    values = np.ma.filled(values, np.nan).astype("float64", copy=False)
    if flip_latitude:
        # A few older raw files store latitude south-to-north. The weights use
        # the pilot-year grid order, so flip those arrays before selecting cells.
        values = values[:, ::-1, :]
    return values.reshape(stop - start, -1)[:, flat_indices]


def read_cells_window(variable, start: int, stop: int, row_min: int, row_max: int,
                      col_min: int, col_max: int, local_flat):
    # Read a country-sized rectangle from a global monthly file.
    # `local_flat` then selects the exact ERA5-Land cells used by the weights.
    values = np.ma.asarray(variable[start:stop, row_min:row_max + 1, col_min:col_max + 1])
    values = np.ma.filled(values, np.nan).astype("float64", copy=False)
    return values.reshape(stop - start, -1)[:, local_flat]


def read_admins(spec: Country) -> gpd.GeoDataFrame:
    # Read only the ID/name fields needed for matching, plus geometry.
    # Country-specific column aliases are defined in settings.py.
    requested = [*spec.id_columns, *spec.name_columns]
    columns = [spec.column_aliases.get(column, column) for column in requested]
    read_options = {"columns": columns, "engine": "pyogrio"}
    if spec.shapefile_encoding:
        read_options["encoding"] = spec.shapefile_encoding
    admins = gpd.read_file(spec.shapefile, **read_options)
    for target, source in spec.column_aliases.items():
        require(source in admins, f"Missing source column for {target}: {source}")
        admins[target] = admins[source]
    require(admins.crs is not None, "Shapefile has no CRS")
    if admins.crs.to_epsg() != 4326:
        # ERA5-Land coordinates are lon/lat
        admins = admins.to_crs(4326)
    admins["geometry"] = admins.geometry.make_valid()
    require(admins.geometry.notna().all(), "Shapefile contains missing geometry")
    require((~admins.geometry.is_empty).all(), "Shapefile contains empty geometry")
    admins = add_region_id(admins, spec)
    require(not admins["region_id"].duplicated().any(), "Shapefile IDs are not unique")
    # Sorting west-to-east makes split jobs stable when a country is divided into parts
    admins["_longitude"] = admins.geometry.representative_point().x
    return admins.sort_values(["_longitude", "region_id"]).reset_index(drop=True)


@dataclass(frozen=True)
class Grid:
    latitude: np.ndarray
    longitude: np.ndarray
    step: float
    left: float
    right: float
    bottom: float
    top: float

    @property
    def extent(self):
        return box(self.left, self.bottom, self.right, self.top)

    def point_indices(self, latitude, longitude):
        rows = np.floor((self.top - latitude) / self.step).astype("int64")
        columns = np.floor((longitude - self.left) / self.step).astype("int64")
        inside = (
            (rows >= 0) & (rows < len(self.latitude))
            & (columns >= 0) & (columns < len(self.longitude))
        )
        return rows, columns, inside


def read_grid(path: Path) -> Grid:
    # Use one ERA5-Land NetCDF file to define the grid used by all weights
    require(path.is_file(), f"Missing climate file: {path}")
    with Dataset(path) as data:
        latitude = np.asarray(data.variables["latitude"][:], dtype="float64")
        longitude = np.asarray(data.variables["longitude"][:], dtype="float64")
    require(latitude.ndim == longitude.ndim == 1, "Climate coordinates are not one-dimensional")
    require(np.all(np.diff(latitude) < 0), "Latitude must run north to south")
    require(np.all(np.diff(longitude) > 0), "Longitude must run west to east")
    lat_step = float(np.median(-np.diff(latitude)))
    lon_step = float(np.median(np.diff(longitude)))
    require(np.isclose(lat_step, lon_step, atol=1e-8), "Latitude and longitude steps differ")
    require(np.allclose(np.diff(latitude), -lat_step, atol=1e-8), "Latitude grid is irregular")
    require(np.allclose(np.diff(longitude), lon_step, atol=1e-8), "Longitude grid is irregular")
    # Store grid-cell edges so point coordinates can be converted to row/column indices
    half = lat_step / 2
    return Grid(
        latitude, longitude, lat_step,
        float(longitude[0] - half), float(longitude[-1] + half),
        float(latitude[-1] - half), float(latitude[0] + half),
    )
