"""
settings.py

Country settings for the CHIRPS admin aggregation.

Country settings are read from shapefiles_chirps.csv, one row per country.
Every country runs 1981-2025.

Population weights use LandScan 2011 and area weights use the GPW 2010
land-area point table.
"""

from dataclasses import dataclass, field
from pathlib import Path

import pandas as pd


# -----------------------------
# Shared paths
# -----------------------------

OUTPUT_ROOT = Path("/project/cil/gcp/estimation/rainfall-mortality/climate_data")
CHIRPS_ROOT = Path(
    "/project/cil/gcp/climate/CHIRPS/Raw_NetCDF_p05deg_by_p05deg/PRCP"
)
LANDSCAN = Path(
    "/project/cil/battuta_shares/gcp/social/sources/Landscan2011/"
    "RasterGISbinary/lspop2011.flt"
)
GPW_LAND_AREA = Path("/project/cil/gcp/temp_data/gpw_2010_land_area_points")


# -----------------------------
# Country settings
# -----------------------------

# Shapefile, admin IDs and CHIRPS small-cell rules for each country.
SHAPEFILES = Path(__file__).resolve().parent / "shapefiles_chirps.csv"


@dataclass(frozen=True)
class Country:
    code: str
    level: str
    shapefile: Path
    id_columns: tuple[str, ...]
    name_columns: tuple[str, ...]
    id_widths: dict[str, int]
    column_aliases: dict[str, str] = field(default_factory=dict)
    shapefile_encoding: str | None = None
    output_subfolder: str = ""
    # 1981-2010 is the baseline for the heterogeneity variables. Climate runs
    # through 2025 so 2024 panel rows can use the following year's rainfall.
    first_year: int = 1981
    last_year: int = 2025
    # One year used only to read the CHIRPS grid, which is the same every year.
    pilot_year: int = 2000
    # Rule for weighted CHIRPS cells that are masked in the raw precipitation file.
    masked_cell_rule: str = "keep_missing"
    # Search radius measured in CHIRPS grid cells.
    masked_cell_max_radius: int = 0
    # Rule for small polygons with no CHIRPS grid-cell center.
    uncovered_cell_rule: str = "keep_uncovered"


def read_countries() -> dict[str, Country]:
    # Lists in the CSV are separated by ";", for ex "ID_0;ID_1;ID_2".
    # ID widths are written as column:width, for ex "ID_1:2".
    split = lambda text: tuple(text.split(";")) if text else ()
    table = pd.read_csv(SHAPEFILES, dtype=str, keep_default_na=False)
    countries = {}
    for row in table.itertuples(index=False):
        ids, names = split(row.id_columns), split(row.name_columns)
        sources = split(row.source_id_columns) + split(row.source_name_columns)

        # Columns renamed from the shapefile, for ex RWA ADM2_PCODE becomes adm2_id.
        aliases = {
            target: source for target, source in zip(ids + names, sources)
            if target != source
        }
        widths = dict(item.split(":") for item in split(row.id_widths))
        countries[row.country] = Country(
            code=row.country,
            level=row.admin_level,
            shapefile=Path(row.shapefile),
            id_columns=ids,
            name_columns=names,
            id_widths={column: int(width) for column, width in widths.items()},
            column_aliases=aliases,
            shapefile_encoding=row.shapefile_encoding or None,
            output_subfolder=row.output_subfolder,
            masked_cell_rule=row.masked_cell_rule,
            masked_cell_max_radius=int(row.masked_cell_max_radius),
            uncovered_cell_rule=row.uncovered_cell_rule,
        )
    return countries


COUNTRIES = read_countries()


# -----------------------------
# Derived paths
# -----------------------------


def country(code: str) -> Country:
    # Use one spelling of the country code everywhere downstream.
    code = code.upper()
    if code not in COUNTRIES:
        raise ValueError(f"Unknown CHIRPS country: {code}")
    return COUNTRIES[code]


def climate_file(year: int) -> Path:
    # Raw CHIRPS files are one NetCDF per year.
    return CHIRPS_ROOT / f"chirps-v2.0.{year}.days_p05.nc"


def weights_dir(spec: Country) -> Path:
    # Countries with changed boundaries use a subfolder, for ex COL/current_boundaries.
    return OUTPUT_ROOT / "weights/landscan2011/CHIRPS" / spec.code / spec.output_subfolder


def weights_file(spec: Country) -> Path:
    # One row per admin unit x CHIRPS grid cell.
    slug = spec.code.lower()
    return weights_dir(spec) / f"chirps_{slug}_{spec.level}_segment_weights_landscan2011.csv"


def admin_file(spec: Country) -> Path:
    # One row per admin unit, with coverage and weight-sum checks.
    slug = spec.code.lower()
    return weights_dir(spec) / f"chirps_{slug}_{spec.level}_admin_summary.csv"


def result_dir(spec: Country) -> Path:
    # Daily, monthly, and annual precipitation files are written below here.
    return OUTPUT_ROOT / "CHIRPS" / spec.code / spec.output_subfolder
