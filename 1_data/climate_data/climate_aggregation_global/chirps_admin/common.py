"""
common.py

Shared code for CHIRPS admin aggregation.

Used for checks, CSV writing, admin IDs, shapefile reading, CHIRPS grid reading,
and CHIRPS output names.

Admin IDs are handled as text because some country IDs have leading zeros. They
are treated as strings before they are used in file names, region IDs, or
merges.
"""

# -----------------------------
# Packages
# -----------------------------

from dataclasses import dataclass
import os
from pathlib import Path

import geopandas as gpd
from netCDF4 import Dataset
import numpy as np
import pandas as pd
from shapely.geometry import box

from settings import Country, result_dir


class CheckError(RuntimeError):
    pass


POWERS = range(1, 6)


def require(test: bool, message: str) -> None:
    if not test:
        raise CheckError(message)


def atomic_csv(frame: pd.DataFrame, path: Path) -> None:
    # Write through a temporary file so a failed job does not leave a partial CSV.
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp.csv")
    if temporary.exists():
        temporary.unlink()
    frame.to_csv(temporary, index=False, float_format="%.15g")
    os.replace(temporary, path)


def chirps_paths(spec: Country, year: int) -> dict[str, Path]:
    # Daily, monthly, and annual outputs use the same country/admin-level stem.
    root = result_dir(spec)
    stem = f"chirps_{spec.code.lower()}_{spec.level}"
    return {
        "daily": root / "daily" / f"{stem}_daily_{year}.csv",
        "monthly": root / "monthly" / f"{stem}_monthly_{year}.csv",
        "annual": root / "annual" / f"{stem}_annual_{year}.csv",
    }


def chirps_columns() -> list[str]:
    # Powers are calculated at the grid-cell level before admin averaging.
    # Both population- and area-weighted versions are kept for checks.
    return [
        f"prcp_{weighting}_p{power}"
        for weighting in ("pop", "area")
        for power in POWERS
    ]


def normalize_ids(frame: pd.DataFrame, spec: Country) -> pd.DataFrame:
    # Admin IDs must stay as strings. Some country IDs have leading zeros that
    # would be lost if pandas kept them numeric.
    frame = frame.copy()
    for column in spec.id_columns:
        require(column in frame, f"Missing ID column: {column}")

        width = spec.id_widths.get(column)
        values = frame[column]

        # Numeric ID columns should contain whole numbers before conversion to strings
        if pd.api.types.is_numeric_dtype(values):
            numeric = pd.to_numeric(values, errors="raise")
            require(np.isclose(numeric, np.round(numeric)).all(), f"{column} is not integer-valued")
            values = numeric.round().astype("int64").astype(str)

        else:
            # String columns can still contain values such as "1.0"
            # Convert numeric-looking whole numbers cleanly before padding IDs
            values = values.astype("string").str.strip()
            numeric = pd.to_numeric(values, errors="coerce")
            whole = numeric.notna() & np.isclose(numeric, np.round(numeric))
            values = values.astype(object)
            values.loc[whole] = numeric.loc[whole].round().astype("int64").astype(str)
            values = values.astype("string")

        if width:
            values = values.str.zfill(width)

        require(values.notna().all() and (values != "").all(), f"{column} contains an empty ID")
        frame[column] = values

    return frame


def add_region_id(frame: pd.DataFrame, spec: Country) -> pd.DataFrame:
    # region_id is the climate-side admin key used by all CHIRPS outputs.
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


def read_admins(spec: Country) -> gpd.GeoDataFrame:
    # Read only the admin IDs, names, and geometry needed for the weights.
    # Country-specific shapefile column names are listed in settings.py.
    requested = [*spec.id_columns, *spec.name_columns]
    columns = [spec.column_aliases.get(column, column) for column in requested]

    options = {"columns": columns, "engine": "pyogrio"}
    if spec.shapefile_encoding:
        options["encoding"] = spec.shapefile_encoding

    admins = gpd.read_file(spec.shapefile, **options)

    # Copy aliased shapefile columns to the common names used by the scripts.
    for target, source in spec.column_aliases.items():
        require(source in admins, f"Missing source column for {target}: {source}")
        admins[target] = admins[source]

    require(admins.crs is not None, "Shapefile has no CRS")

    # CHIRPS is stored on a longitude/latitude grid.
    if admins.crs.to_epsg() != 4326:
        admins = admins.to_crs(4326)

    # Repair invalid polygons before spatial matching.
    admins["geometry"] = admins.geometry.make_valid()

    require(admins.geometry.notna().all(), "Shapefile contains missing geometry")
    require((~admins.geometry.is_empty).all(), "Shapefile contains empty geometry")

    admins = add_region_id(admins, spec)
    require(not admins["region_id"].duplicated().any(), "Shapefile IDs are not unique")

    # Sort west to east so rebuilt weight chunks contain the same admin units.
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
    latitude_descending: bool

    @property
    def extent(self):
        return box(self.left, self.bottom, self.right, self.top)

    def point_indices(self, latitude, longitude):
        # Map longitude/latitude points to CHIRPS cell row and column addresses.
        # Latitude can run north-to-south or south-to-north depending on the file.
        if self.latitude_descending:
            rows = np.floor((self.top - latitude) / self.step).astype("int64")
        else:
            rows = np.floor((latitude - self.bottom) / self.step).astype("int64")

        columns = np.floor((longitude - self.left) / self.step).astype("int64")

        # Points outside the CHIRPS grid are not covered.
        inside = (
            (rows >= 0) & (rows < len(self.latitude))
            & (columns >= 0) & (columns < len(self.longitude))
        )

        return rows, columns, inside


def read_grid(path: Path) -> Grid:
    # Read the CHIRPS latitude and longitude arrays from one NetCDF file.
    # The same 0.05-degree grid is used for all years.
    require(path.is_file(), f"Missing CHIRPS file: {path}")

    with Dataset(path) as data:
        latitude = np.asarray(data.variables["latitude"][:], dtype="float64")
        longitude = np.asarray(data.variables["longitude"][:], dtype="float64")

    require(latitude.ndim == longitude.ndim == 1, "CHIRPS coordinates are not one-dimensional")

    lat_diff = np.diff(latitude)
    lon_diff = np.diff(longitude)

    # Latitude can run in either direction, but longitude should run west to east.
    lat_desc = bool(np.all(lat_diff < 0))
    require(lat_desc or np.all(lat_diff > 0), "CHIRPS latitude is not monotonic")
    require(np.all(lon_diff > 0), "CHIRPS longitude must run west to east")

    lat_step = float(np.median(np.abs(lat_diff)))
    lon_step = float(np.median(lon_diff))
    step = round((lat_step + lon_step) / 2, 2)

    # CHIRPS uses a regular 0.05-degree grid.
    # The stored coordinates have small floating-point differences, so allow a
    # small tolerance when checking the spacing.
    require(np.isclose(step, 0.05, atol=1e-6), f"Unexpected CHIRPS grid step: {step}")
    require(np.allclose(np.abs(lat_diff), step, atol=1e-4), "Latitude grid is irregular")
    require(np.allclose(lon_diff, step, atol=1e-4), "Longitude grid is irregular")

    # Store outer cell edges so points can be mapped to CHIRPS row/column cells.
    half = lat_step / 2

    return Grid(
        latitude=latitude,
        longitude=longitude,
        step=step,
        left=float(longitude[0] - half),
        right=float(longitude[-1] + half),
        bottom=float(latitude.min() - half),
        top=float(latitude.max() + half),
        latitude_descending=lat_desc,
    )
