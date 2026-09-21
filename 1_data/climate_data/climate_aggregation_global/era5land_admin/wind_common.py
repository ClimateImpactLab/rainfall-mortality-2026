"""
wind_common.py

Wind code used by the ERA5-Land admin wind scripts.

The annual wind, daily wind, and rain-event wind checks all need to open the
same `wind_max` files and handle the same small-island wind fallback. Keeping
those pieces here avoids importing a numbered script from another numbered
script.
"""

import calendar
import warnings

from netCDF4 import Dataset
import numpy as np
import pandas as pd
from pandas.errors import DtypeWarning
from scipy import sparse
from scipy.spatial import cKDTree

from common import atomic_csv, month_dates, require
from settings import monthly_climate_file, result_dir


WIND_VARIABLE = "wind_max"
WIND_UNITS = "m/s"
HIGH_WIND_THRESHOLD = 17.5
MAX_FALLBACK_DISTANCE_DEGREES = 1.6

# The weight files contain fallback metadata created by the main climate code.
# The wind scripts do not use those columns.
warnings.filterwarnings("ignore", category=DtypeWarning)


class WindYear:
    # Treat the 12 monthly global files like one daily year.
    # The aggregation scripts can then read day blocks in the usual way.
    def __init__(self, datasets, variables):
        self.datasets = datasets
        self.variables = variables
        self.month_days = [variable.shape[0] for variable in variables]
        self.month_starts = np.cumsum([0, *self.month_days[:-1]])
        self.shape = (sum(self.month_days), *variables[0].shape[1:])
        self.units = getattr(variables[0], "units", None)

    def __getitem__(self, key):
        # Support both variable[0] and variable[start:stop, rows, cols].
        if isinstance(key, tuple):
            time_key = key[0]
            grid_key = key[1:]
        else:
            time_key = key
            grid_key = ()

        if isinstance(time_key, int):
            if time_key < 0:
                time_key = self.shape[0] + time_key
            for start, days, variable in zip(self.month_starts, self.month_days, self.variables, strict=True):
                if start <= time_key < start + days:
                    return variable[(time_key - start, *grid_key)]
            raise IndexError("wind day is outside the year")

        start = 0 if time_key.start is None else time_key.start
        stop = self.shape[0] if time_key.stop is None else time_key.stop
        step = time_key.step
        require(step in (None, 1), "Wind reads expect a simple day slice")

        pieces = []
        for month_start, days, variable in zip(self.month_starts, self.month_days, self.variables, strict=True):
            month_stop = month_start + days
            if stop <= month_start or start >= month_stop:
                continue
            local_start = max(start, month_start) - month_start
            local_stop = min(stop, month_stop) - month_start
            pieces.append(variable[(slice(local_start, local_stop), *grid_key)])

        require(pieces, "Wind read slice is outside the year")
        if len(pieces) == 1:
            return pieces[0]
        return np.ma.concatenate(pieces, axis=0)

    def close(self):
        for data in self.datasets:
            data.close()


def fallback_audit_path(spec, year):
    stem = f"era5land_{spec.code.lower()}_{spec.level}_wind_fallback_{year}.csv"
    return result_dir(spec) / "wind" / "fallback_audit" / stem


def open_wind_file(spec, year, grid):
    # Open the 12 monthly global wind files and check that they match the grid
    # used for the admin weights.
    datasets = []
    variables = []
    dates = []
    flip_latitude = None

    for month in range(1, 13):
        path = monthly_climate_file(WIND_VARIABLE, year, month)
        require(path.is_file(), f"Missing wind input: {path}")

        data = Dataset(path)
        datasets.append(data)

        if WIND_VARIABLE not in data.variables:
            data.close()
            require(False, f"{path} has no {WIND_VARIABLE}")

        variable = data.variables[WIND_VARIABLE]
        days = calendar.monthrange(year, month)[1]

        require(
            variable.shape == (days, len(grid.latitude), len(grid.longitude)),
            f"Unexpected shape for {path}: {variable.shape}",
        )
        require(
            getattr(variable, "units", None) == WIND_UNITS,
            f"Unexpected wind units for {path}",
        )

        latitude = np.asarray(data.variables["latitude"][:], dtype="float64")
        longitude = np.asarray(data.variables["longitude"][:], dtype="float64")
        require(np.allclose(longitude, grid.longitude), f"Longitudes differ from the pilot grid: {path}")

        if np.allclose(latitude, grid.latitude):
            month_flip = False
        elif np.allclose(latitude[::-1], grid.latitude):
            month_flip = True
        else:
            require(False, f"Latitudes differ from the pilot grid: {path}")

        if flip_latitude is None:
            flip_latitude = month_flip
        require(month_flip == flip_latitude, f"Latitude order changes across monthly wind files: {path}")
        variables.append(variable)
        dates.append(month_dates(data, year, month))

    variable = WindYear(datasets, variables)
    all_dates = pd.DatetimeIndex(np.concatenate([month_dates.to_numpy() for month_dates in dates]))
    expected = pd.date_range(f"{year}-01-01", f"{year}-12-31", freq="D")
    require(all_dates.equals(expected), f"Wind dates are incomplete for {year}")

    return variable, variable, all_dates, bool(flip_latitude)


def aggregate_with_finite_cells(values, matrix):
    # Missing wind cells are not zero wind.
    # Average over finite weighted cells only and renormalize the weights.
    valid = np.isfinite(values)
    denominator = np.asarray(matrix @ valid.T).T.ravel()
    numerator = np.asarray(matrix @ np.where(valid, values, 0).T).T.ravel()
    answer = np.full(numerator.shape, np.nan)
    np.divide(numerator, denominator, out=answer, where=denominator > 0)
    return answer


def first_day_wind_valid_mask(variable, flip_latitude=False):
    # The missing-cell pattern is treated as a property of the wind grid, not
    # something that changes day by day.
    values = np.ma.asarray(variable[0])
    values = np.ma.filled(values, np.nan).astype("float64", copy=False)
    if flip_latitude:
        values = values[::-1, :]
    return np.isfinite(values)


def nearest_valid_cells(grid, valid_mask):
    # Build a nearest-neighbor search over ERA5-Land cells with finite wind.
    valid_rows, valid_columns = np.where(valid_mask)
    require(len(valid_rows) > 0, "No finite wind cells found")

    coordinates = np.column_stack([
        grid.latitude[valid_rows],
        grid.longitude[valid_columns],
    ])

    return cKDTree(coordinates), valid_rows, valid_columns


def fallback_cell_moves(admins, flat_indices, matrix, grid, valid_mask, weighting):
    # Only move weights when every positive-weight cell for an admin unit has
    # missing wind. If one original cell has finite wind, keep the normal
    # weights.
    tree, valid_rows, valid_columns = nearest_valid_cells(grid, valid_mask)
    n_longitude = len(grid.longitude)
    valid_by_flat = valid_mask.reshape(-1)[flat_indices]

    moves = []
    target_flats = []

    for admin_number in range(matrix.shape[0]):
        row = matrix.getrow(admin_number)
        positive = row.data > 0
        if not positive.any():
            continue

        source_columns = row.indices[positive]
        source_weights = row.data[positive]
        if valid_by_flat[source_columns].any():
            continue

        region_id = admins.at[admin_number, "region_id"]
        source_flats = flat_indices[source_columns]
        source_rows = source_flats // n_longitude
        source_grid_columns = source_flats % n_longitude
        query = np.column_stack([
            grid.latitude[source_rows],
            grid.longitude[source_grid_columns],
        ])

        # Do not partly replace an admin unit's weights. If any source cell is
        # too far from finite wind, keep the original missing result.
        distances, nearest = tree.query(query, k=1)
        over_limit = distances > MAX_FALLBACK_DISTANCE_DEGREES + 1e-12
        if over_limit.any():
            for source_flat, distance in zip(source_flats, distances, strict=True):
                moves.append({
                    "region_id": region_id,
                    "weighting": weighting,
                    "status": "distance_exceeds_limit",
                    "source_flat": int(source_flat),
                    "target_flat": np.nan,
                    "source_weight": np.nan,
                    "distance_degrees": float(distance),
                })
            continue

        # Move each source cell's existing weight to its nearest finite wind cell.
        # The weight itself does not change.
        for source_flat, source_weight, distance, target_number in zip(
            source_flats, source_weights, distances, nearest, strict=True
        ):
            target_flat = (
                int(valid_rows[int(target_number)]) * n_longitude
                + int(valid_columns[int(target_number)])
            )

            target_flats.append(target_flat)
            moves.append({
                "region_id": region_id,
                "weighting": weighting,
                "status": "moved_to_nearest_finite_wind_cell",
                "source_flat": int(source_flat),
                "target_flat": int(target_flat),
                "source_weight": float(source_weight),
                "distance_degrees": float(distance),
            })

    return moves, target_flats


def rebuild_matrix_with_fallback(matrix, flat_indices, new_flat_indices, moves, admins):
    # Replace affected admin rows with their wind fallback cells.
    move_frame = pd.DataFrame(moves)
    moved = move_frame.loc[
        move_frame["status"].eq("moved_to_nearest_finite_wind_cell")
    ]

    if moved.empty:
        return matrix

    region_to_admin = pd.Series(np.arange(len(admins)), index=admins.region_id).to_dict()
    affected_admins = {region_to_admin[region_id] for region_id in moved.region_id.unique()}
    new_column = {int(flat): number for number, flat in enumerate(new_flat_indices)}

    # Keep all rows that do not need wind fallback.
    coo = matrix.tocoo()
    keep = np.array([row not in affected_admins for row in coo.row])
    rows = coo.row[keep].tolist()
    columns = [new_column[int(flat_indices[column])] for column in coo.col[keep]]
    values = coo.data[keep].tolist()

    # Rebuild affected rows with the replacement cells.
    # Multiple source cells can map to the same target cell.
    for row in moved.itertuples(index=False):
        admin_number = region_to_admin[row.region_id]
        rows.append(admin_number)
        columns.append(new_column[int(row.target_flat)])
        values.append(float(row.source_weight))

    rebuilt = sparse.coo_matrix(
        (values, (rows, columns)),
        shape=(matrix.shape[0], len(new_flat_indices)),
    ).tocsr()
    rebuilt.sum_duplicates()

    # Fallback changes cell locations but should preserve each admin's total weight.
    sums = np.asarray(rebuilt.sum(axis=1)).ravel()
    covered = sums > 0
    require(np.allclose(sums[covered], 1), "Wind fallback weights do not sum to one")

    return rebuilt


def write_fallback_audit(spec, year, grid, moves):
    # Write a small CSV showing which cells moved and which were too far away.
    if not moves:
        return

    audit = pd.DataFrame(moves)
    n_longitude = len(grid.longitude)

    source_flat = audit["source_flat"].to_numpy(dtype="int64")
    audit["source_grid_row"] = source_flat // n_longitude
    audit["source_grid_column"] = source_flat % n_longitude
    audit["source_latitude"] = grid.latitude[audit["source_grid_row"].to_numpy(dtype="int64")]
    audit["source_longitude"] = grid.longitude[audit["source_grid_column"].to_numpy(dtype="int64")]

    # Rejected moves have no target cell.
    has_target = audit["target_flat"].notna()
    audit["target_grid_row"] = np.nan
    audit["target_grid_column"] = np.nan
    audit["target_latitude"] = np.nan
    audit["target_longitude"] = np.nan

    if has_target.any():
        target_flat = audit.loc[has_target, "target_flat"].to_numpy(dtype="int64")
        target_rows = target_flat // n_longitude
        target_columns = target_flat % n_longitude
        audit.loc[has_target, "target_grid_row"] = target_rows
        audit.loc[has_target, "target_grid_column"] = target_columns
        audit.loc[has_target, "target_latitude"] = grid.latitude[target_rows]
        audit.loc[has_target, "target_longitude"] = grid.longitude[target_columns]

    columns = [
        "region_id", "weighting", "status", "source_weight",
        "source_grid_row", "source_grid_column", "source_latitude", "source_longitude",
        "target_grid_row", "target_grid_column", "target_latitude", "target_longitude",
        "distance_degrees",
    ]

    atomic_csv(audit.loc[:, columns], fallback_audit_path(spec, year))


def apply_wind_fallback(spec, year, grid, variable, admins, flat_indices, matrices, flip_latitude=False):
    # Check population and area weights separately because their weighted cells
    # can differ.
    valid_mask = first_day_wind_valid_mask(variable, flip_latitude)
    all_moves = []
    target_flats = []

    for weighting, matrix in matrices.items():
        moves, targets = fallback_cell_moves(
            admins, flat_indices, matrix, grid, valid_mask, weighting
        )
        all_moves.extend(moves)
        target_flats.extend(targets)

    write_fallback_audit(spec, year, grid, all_moves)

    # Rejected moves are recorded in the audit but do not change the weights.
    moved = [
        move for move in all_moves
        if move["status"] == "moved_to_nearest_finite_wind_cell"
    ]

    if not moved:
        return flat_indices, matrices

    # Add fallback target cells to the set of ERA5-Land cells read from wind_max.
    new_flat_indices = np.array(
        sorted(set(flat_indices).union(target_flats)),
        dtype="int64",
    )

    moved_by_weighting = {
        weighting: [move for move in moved if move["weighting"] == weighting]
        for weighting in matrices
    }

    new_matrices = {
        weighting: rebuild_matrix_with_fallback(
            matrix, flat_indices, new_flat_indices, moved_by_weighting[weighting], admins
        )
        for weighting, matrix in matrices.items()
    }

    print(
        f"wind fallback moved {len(moved)} source cells for "
        f"{len(set(move['region_id'] for move in moved))} admin units",
        flush=True,
    )

    return new_flat_indices, new_matrices
