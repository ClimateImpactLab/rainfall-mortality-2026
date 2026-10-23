#!/usr/bin/env python3
"""
compare_global_to_regional.py

Check the new global download against the existing regional archive, for one
region-month or for every global month currently on disk.

Why this exists
---------------
The global product has to be interchangeable with the regional files the
hydrology work already uses. The global grid is a strict superset of every
regional box on the same 0.1-degree lattice, so the overlap can be compared
cell for cell with no regridding.

Inputs
------
* Global:   <global-root>/global/<variable>/era5land_global_<variable>_<year>_<MM>.nc4
* Regional: <regional-root>/<region>/<variable>/era5land_<region>_<variable>_<year>.nc4

The regional archive is only ever opened for reading. Nothing is written.

Output
------
A CSV, and nothing else. There is no per-comparison console output: the sweep is
thousands of comparisons and the table form was unreadable at that length. The
console gets one summary line at the end. Rows are flushed as each region-month
finishes, so a wall-time kill still leaves a usable file.

One row per region-month-variable:

    region year month variable      which comparison this is
    regional_source                 cds, destine, cds+destine, or unknown
    status                          PASS, FAIL or SKIP
    rel_max_diff mantissa_bits      the relative difference, and its precision
    max_diff median_diff p99_9      the absolute difference distribution
    pct_exact                       cells agreeing bit for bit
    mask_mismatch cells             NaN disagreements, and cells compared
    global_units regional_units     units as recorded in each file
    detail                          why a row is not PASS

To read the differences: filter on status, then read mantissa_bits. A value
near 11 across every variable and month is the precision story above. A row
that drops well below that, or a nonzero mask_mismatch, is a real finding.
median_diff against max_diff shows the shape: a median near half the max means
the differences fill the interval, which is rounding, not a tail.

The regional_source marker
--------------------------
Per download/README.md and the CDS script's own docstring, the regional archive
was built by two different routes: the Copernicus CDS API first (india, usa and
early patch regions) and the DestinE Earth Data Hub later (most other
downloads). The global download reads DestinE only. Whether a CDS-sourced
region differs from the global product differently than a DestinE-sourced one
is therefore worth being able to group on, so each row carries the route.

It is read from the regional file's own global attributes, not from a lookup
table:

  * europe and australia carry `source`, set by
    transform/convert_monthly_to_annual_by_variable.py.
  * asia_combined carries `india_data_source` and `asia_east_data_source`
    instead, from merge_asia_components.py. Its two components can come from
    different routes, so such a row can read `cds+destine`. That is not an
    error: per the CDS script's docstring, india was one of the CDS-route
    regions, and the merged file really does mix them.
  * mexico and brazil carry neither. Their merge scripts assign a fresh attrs
    dict and drop `source`, keeping only `<component>_source_file` paths, so
    the marker follows those paths one level to the component annual files,
    which do carry `source`.
    
Usage
-----
One region-month:

    python compare_global_to_regional.py --year 2020 --month 1 \
        --region mexico --csv one_month.csv

Every global month on disk, against every final region. The download runs a
year-block at a time, so the global tree is normally a patchwork of finished
months; whatever is present is what gets compared.

    python compare_global_to_regional.py --regions all --csv compare.csv

Months with no global file are not visited. Months outside a region's own
archive coverage are recorded as SKIP rows rather than dropped, so the CSV shows
what was not checked as well as what was.

This is a long serial sweep. Submit it with sbatch, not sinteractive.

Dependencies
------------
numpy, xarray, netCDF4
"""

# =============================================================================
# 1. Imports
# =============================================================================

import argparse
import calendar
import csv
from pathlib import Path

try:
    import numpy as np # type: ignore
    import xarray as xr # type: ignore
except ImportError as e:
    raise SystemExit(f"Missing package. Need: numpy, xarray, netCDF4.\n{e}")


# =============================================================================
# 2. Paths and Constants
# =============================================================================

DEFAULT_GLOBAL_ROOT = Path("/project/cil/gcp/climate/ERA5-LAND-GLOBAL/raw/daily")

# Read-only. This is the inherited archive.
DEFAULT_REGIONAL_ROOT = Path("/project/cil/gcp/climate/ERA5-LAND/raw/daily")

# Kept as documentation of how each variable is built, not as a pass criterion.
# A min or max is order-independent; a mean is not, so tmean and the other
# means carry float32 summation noise on top of any storage-precision
# difference. That is why tmean's observed cap (0.0840) sits below tmin's
# (0.125): averaging 24 quantized values cancels part of the error.
MINMAX_VARIABLES = ("tmin", "tmax", "tp_total", "wind_max")
MEAN_VARIABLES = ("tmean", "rh_mean", "q_mean", "swe_mean")

ALL_VARIABLES = MINMAX_VARIABLES + MEAN_VARIABLES

# The five final analysis domains from README.md. The component folders (india,
# usa, latam, ...) are deliberately excluded: they are build inputs, not
# domains, and comparing them would double-count the same cells.
FINAL_REGIONS = ("asia_combined", "mexico", "brazil", "europe", "australia")

# The pass criterion. Relative, because the observed difference is a relative
# one: the stores agree to about 11 mantissa bits, or 2^-11 = 4.9e-4. A true
# float32 round trip would agree to 24 bits (6e-8), so 1e-3 is loose by a
# factor of ~8000 against float32 but only a factor of 2 against what is
# actually on disk. That is the point: it accepts the known precision gap and
# still catches anything materially worse.
#
# Raising this would start accepting real data changes. Lowering it below
# 4.9e-4 fails every row, which is where this started.
RELATIVE_TOLERANCE = 1e-3

# Temperature is stored in degC but was quantized in Kelvin, so the relative
# difference has to be taken against the Kelvin magnitude. This is the only
# place the native unit differs from the stored unit by an OFFSET; tp_total and
# swe_mean differ only by a factor of 1000, and a ratio is scale invariant, so
# they need no conversion.
KELVIN_OFFSET = 273.15
KELVIN_VARIABLES = ("tmin", "tmean", "tmax")

# The grid is 0.1 degrees, so anything closer than this is the same cell.
COORDINATE_TOLERANCE_DEGREES = 1e-3


# =============================================================================
# 3. Arguments
# =============================================================================

def parse_args():
    parser = argparse.ArgumentParser()

    # Omit both to compare every year-month the global tree already holds.
    parser.add_argument("--year", type=int)
    parser.add_argument("--month", type=int)
    parser.add_argument(
        "--region",
        type=str,
        default="mexico",
        help="Regional folder to compare against, e.g. mexico or europe. "
             "Use 'all' for every final region.",
    )
    parser.add_argument(
        "--regions",
        type=str,
        help="Comma-separated regions, or 'all'. Overrides --region.",
    )
    parser.add_argument(
        "--variables",
        type=str,
        default=",".join(ALL_VARIABLES),
        help="Comma-separated daily variables to compare.",
    )
    # Required: the CSV is the only output. Nothing is printed per comparison.
    parser.add_argument(
        "--csv",
        type=Path,
        required=True,
        help="Output file. One row per region-month-variable.",
    )

    parser.add_argument("--global-root", type=Path, default=DEFAULT_GLOBAL_ROOT)
    parser.add_argument("--regional-root", type=Path,
                        default=DEFAULT_REGIONAL_ROOT)

    return parser.parse_args()


# =============================================================================
# 4. Comparison
# =============================================================================

def snap(ds: xr.Dataset) -> xr.Dataset:
    """Put both grids on exact tenths so coordinates can be matched.

    The archive carries float noise on some regions (europe and brazil have
    values like 26.900000000001), which would otherwise defeat coordinate
    alignment.
    """
    return ds.assign_coords(
        latitude=np.round(ds.latitude.values, 1),
        longitude=np.round(ds.longitude.values, 1),
    )


def global_path_for(global_root: Path, variable: str, year: int,
                    month: int) -> Path:
    return (global_root / "global" / variable
            / f"era5land_global_{variable}_{year}_{month:02d}.nc4")


def regional_path_for(regional_root: Path, region: str, variable: str,
                      year: int) -> Path:
    return (regional_root / region / variable
            / f"era5land_{region}_{variable}_{year}.nc4")


def available_months(global_root: Path, variables: list) -> list:
    """Every (year, month) with at least one global variable file on disk.

    The download writes each variable separately, so a month can be partially
    present. Any file is enough to visit the month; variables still missing
    show up as SKIP rows.
    """
    found = set()

    for variable in variables:
        directory = global_root / "global" / variable
        if not directory.is_dir():
            continue
        for path in directory.glob(f"era5land_global_{variable}_*_*.nc4"):
            year, month = path.stem.split("_")[-2:]
            try:
                found.add((int(year), int(month)))
            except ValueError:
                # Not a name this script wrote; leave it alone.
                continue

    return sorted(found)


def classify_source(text: str) -> str:
    """One provenance label from a source attribute string.

    The placeholder default written by convert_monthly_to_annual_by_variable.py
    names both routes ("... from CDS/DestinE ..."), so a string mentioning both
    is unknown provenance, not a mixed file.
    """
    lowered = text.lower()
    mentions_cds = "cds" in lowered
    mentions_destine = "destine" in lowered

    if mentions_cds and mentions_destine:
        return "unknown"
    if mentions_destine:
        return "destine"
    if mentions_cds:
        return "cds"
    return "unknown"


def source_labels(ds: xr.Dataset) -> set:
    """Route labels carried by a dataset's own global attributes.

    `source` is what the direct regions have. `<component>_data_source` is what
    merge_asia_components.py records for each of its two inputs.
    """
    return {
        classify_source(str(value))
        for key, value in ds.attrs.items()
        if key == "source" or key.endswith("_data_source")
    }


def regional_source(ds: xr.Dataset) -> str:
    """Which download route built this regional file.

    Three shapes have to be handled, because the archive was not built by one
    script:

      * europe, australia carry `source` directly.
      * asia_combined carries `india_data_source` and `asia_east_data_source`,
        and those two components can come from different routes, so more than
        one label is a real answer and is reported as e.g. "cds+destine".
      * mexico and brazil carry neither. merge_mexico_components.py and
        merge_brazil_components.py assign `combined.attrs` as a fresh dict and
        drop `source`, keeping only `<component>_source_file` paths. Those
        paths point at the component annual files, which do carry `source`, so
        follow them one level rather than reporting nothing for two of the
        five final regions.
    """
    labels = source_labels(ds)

    if not labels:
        for key, value in ds.attrs.items():
            if not key.endswith("_source_file"):
                continue
            try:
                with xr.open_dataset(str(value)) as component:
                    labels |= source_labels(component)
            except Exception:
                # The component file may have moved since the merge ran. That
                # is a traceability gap, not a reason to stop the sweep.
                labels.add("unknown")

    if not labels:
        return "absent"
    return "+".join(sorted(labels))


def regional_source_of(path: Path) -> str:
    """The route marker for a regional file, reading attributes only.

    Used for rows the comparison skips because the global file is missing:
    rh_mean and q_mean have no global files at all so far, and a blank
    provenance column for a quarter of the variables would be a gap in the
    one thing this column exists to answer.
    """
    try:
        with xr.open_dataset(path) as ds:
            return regional_source(ds)
    except Exception:
        # Never let the provenance marker take down a sweep.
        return "unreadable"


def difference_stats(a: np.ndarray, b: np.ndarray, variable: str) -> dict:
    """Absolute and relative difference statistics over the overlapping cells.

    `a` is global, `b` is regional, both in the file's stored units.
    """
    mask_a, mask_b = np.isnan(a), np.isnan(b)
    mask_mismatch = int(np.count_nonzero(mask_a != mask_b))

    both = ~mask_a & ~mask_b
    n = int(np.count_nonzero(both))

    if n == 0:
        return {"n": 0, "mask_mismatch": mask_mismatch, "n_exact": 0,
                "max_diff": float("nan"), "median_diff": float("nan"),
                "p99_9": float("nan"), "rel_max_diff": float("nan")}

    a, b = a[both], b[both]
    diff = np.abs(a - b)

    # Relative difference against the magnitude in the unit the data was
    # quantized in. Only cells that actually differ can carry information
    # about the step size, and dividing by a zero-valued cell is meaningless.
    scale = np.abs(b + KELVIN_OFFSET) if variable in KELVIN_VARIABLES \
        else np.abs(b)
    informative = (diff > 0.0) & (scale > 0.0)

    rel_max = (float(np.max(diff[informative] / scale[informative]))
               if np.any(informative) else 0.0)

    return {
        "n": n,
        "mask_mismatch": mask_mismatch,
        "n_exact": int(np.count_nonzero(diff == 0.0)),
        "max_diff": float(diff.max()),
        "median_diff": float(np.median(diff)),
        "p99_9": float(np.percentile(diff, 99.9)),
        "rel_max_diff": rel_max,
    }


def compare_variable(global_path: Path, regional_path: Path, variable: str,
                     year: int, month: int) -> dict:
    n_days = calendar.monthrange(year, month)[1]
    first = np.datetime64(f"{year}-{month:02d}-01")
    last = first + np.timedelta64(n_days - 1, "D")

    with xr.open_dataset(global_path) as g_raw, \
            xr.open_dataset(regional_path) as r_raw:
        g = snap(g_raw)
        r = snap(r_raw).sel(valid_time=slice(first, last))

        if r.sizes["valid_time"] != n_days:
            return {"error": f"regional file has {r.sizes['valid_time']} days "
                             f"for this month, expected {n_days}"}

        # The global grid is a superset, so pull exactly the regional cells.
        try:
            g = g.sel(
                latitude=r.latitude,
                longitude=r.longitude,
                method="nearest",
                tolerance=COORDINATE_TOLERANCE_DEGREES,
            )
        except KeyError as exc:
            return {"error": f"regional cells missing from the global grid: {exc}"}

        a = g[variable].values.astype(np.float64)
        b = r[variable].values.astype(np.float64)

        if a.shape != b.shape:
            return {"error": f"shape {a.shape} vs {b.shape}"}

        result = difference_stats(a, b, variable)
        result.update(
            global_units=g[variable].attrs.get("units"),
            regional_units=r[variable].attrs.get("units"),
            # Read from the regional file itself, so the marker travels with
            # the data rather than depending on a lookup kept up to date by
            # hand.
            regional_source=regional_source(r_raw),
        )
        return result


# =============================================================================
# 5. Reporting
# =============================================================================

# Ordered for reading left to right: what was compared, where the regional side
# came from, the verdict, then the relative difference and the precision it
# implies, then the absolute difference distribution, then the structural
# checks. detail is last because it is the only long free-text field and would
# otherwise push the numbers off screen.
#
# The tolerance is not a column: it is one constant for every row
# (RELATIVE_TOLERANCE), so repeating it 7,640 times would be noise.
CSV_COLUMNS = ("region", "year", "month", "variable", "reduction",
               "regional_source", "status",
               "rel_max_diff", "mantissa_bits",
               "max_diff", "median_diff", "p99_9", "pct_exact",
               "mask_mismatch", "cells", "global_units", "regional_units",
               "detail")


def number(value, digits: int = 6) -> str:
    """Six significant figures, so 0.125 reads as 0.125 and not 0.125000000001.

    Float64 repr would otherwise put summation noise in the file and make the
    difference columns hard to scan.
    """
    if value is None or (isinstance(value, float) and np.isnan(value)):
        return ""
    return f"{value:.{digits}g}"


def mantissa_bits(rel_max_diff: float) -> str:
    """How many mantissa bits the two stores agree to, from a relative diff.

    A relative difference of 2^-n means agreement to n bits. Reported rather
    than the raw ratio because the bit count is the number that interprets
    itself: 11 means a store is carrying about 11 bits, 24 means float32
    agreement, and a low value means a real difference in the data.
    """
    if rel_max_diff is None or np.isnan(rel_max_diff):
        return ""
    if rel_max_diff <= 0.0:
        # Bit-identical. No finite bit count describes it.
        return "exact"
    return f"{-np.log2(rel_max_diff):.2f}"


def new_row(region, year, month, variable, status, detail) -> dict:
    """A row with the identifying fields filled in. Numeric fields stay blank
    unless a comparison actually produced them."""
    row = dict.fromkeys(CSV_COLUMNS, "")
    row.update(
        region=region,
        year=year,
        month=f"{month:02d}",
        variable=variable,
        # Context for reading the numbers, not a pass criterion: a mean also
        # carries float32 summation noise, a min or max does not.
        reduction="minmax" if variable in MINMAX_VARIABLES else "mean",
        status=status,
        detail=detail,
    )
    return row


def compare_region_month(args, region: str, year: int, month: int,
                         variables: list) -> list:
    """One region-month. Returns a CSV row per variable. Prints nothing."""
    rows = []

    for variable in variables:
        global_path = global_path_for(args.global_root, variable, year, month)
        regional_path = regional_path_for(args.regional_root, region,
                                          variable, year)

        if not global_path.exists():
            row = new_row(region, year, month, variable, "SKIP",
                          "global file absent")
            if regional_path.exists():
                row["regional_source"] = regional_source_of(regional_path)
            rows.append(row)
            continue
        if not regional_path.exists():
            rows.append(new_row(region, year, month, variable, "SKIP",
                                "regional file absent"))
            continue

        result = compare_variable(global_path, regional_path, variable,
                                  year, month)

        if "error" in result:
            rows.append(new_row(region, year, month, variable, "FAIL",
                                result["error"]))
            continue

        if result["n"] == 0:
            rows.append(new_row(region, year, month, variable, "FAIL",
                                "no overlapping non-NaN cells"))
            continue

        # Structural checks first: a wrong grid or wrong units makes the
        # difference statistics meaningless, so they outrank the tolerance.
        detail = ""
        status = "PASS"

        if result["mask_mismatch"]:
            status = "FAIL"
            detail = f"{result['mask_mismatch']} cells disagree on NaN"
        elif result["global_units"] != result["regional_units"]:
            status = "FAIL"
            detail = (f"units {result['global_units']!r} vs "
                      f"{result['regional_units']!r}")
        elif result["rel_max_diff"] > RELATIVE_TOLERANCE:
            status = "FAIL"
            detail = (f"relative difference exceeds "
                      f"{RELATIVE_TOLERANCE:.0e}")
        elif result["max_diff"] == 0.0:
            detail = "bit identical"

        pct_exact = 100.0 * result["n_exact"] / result["n"]

        row = new_row(region, year, month, variable, status, detail)
        row.update(
            regional_source=result["regional_source"],
            rel_max_diff=number(result["rel_max_diff"]),
            mantissa_bits=mantissa_bits(result["rel_max_diff"]),
            max_diff=number(result["max_diff"]),
            median_diff=number(result["median_diff"]),
            p99_9=number(result["p99_9"]),
            pct_exact=f"{pct_exact:.2f}",
            mask_mismatch=result["mask_mismatch"],
            cells=result["n"],
            global_units=result["global_units"] or "",
            regional_units=result["regional_units"] or "",
        )
        rows.append(row)

    return rows


# =============================================================================
# 6. Main
# =============================================================================

def main():
    args = parse_args()
    variables = [v.strip() for v in args.variables.split(",") if v.strip()]

    if args.regions:
        regions = (list(FINAL_REGIONS) if args.regions.strip() == "all"
                   else [r.strip() for r in args.regions.split(",") if r.strip()])
    elif args.region.strip() == "all":
        regions = list(FINAL_REGIONS)
    else:
        regions = [args.region]

    if args.year and args.month:
        months = [(args.year, args.month)]
    else:
        months = available_months(args.global_root, variables)
        if args.year:
            months = [(y, m) for y, m in months if y == args.year]

    if not months:
        raise SystemExit("No global month files found. Nothing to compare.")

    args.csv.parent.mkdir(parents=True, exist_ok=True)

    # Rows are written and flushed as each region-month finishes rather than
    # at the end. The sweep is long enough to hit a wall-time limit, and a
    # partial file of finished comparisons is worth keeping.
    counts = {"PASS": 0, "FAIL": 0, "SKIP": 0}

    with open(args.csv, "w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=CSV_COLUMNS)
        writer.writeheader()

        for region in regions:
            for year, month in months:
                rows = compare_region_month(args, region, year, month,
                                            variables)
                writer.writerows(rows)
                handle.flush()

                for row in rows:
                    counts[row["status"]] += 1

    # The CSV is the output. Console gets the tally only, so it stays readable
    # in a Slurm log.
    print(f"{args.csv}: PASS {counts['PASS']}  FAIL {counts['FAIL']}  "
          f"SKIP {counts['SKIP']}", flush=True)

    if counts["FAIL"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
