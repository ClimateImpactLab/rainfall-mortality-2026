"""
settings.py

Country settings for the global ERA5-Land admin files.

This file tells the ERA5-Land scripts where to find each country shapefile,
which columns identify the admin units, and which years to run. The raw
ERA5-Land files come from the monthly global folder defined below.

The global code covers weights, daily/monthly/annual precipitation and
temperature, and annual wind. Panel-ready scripts are separate from the main
aggregation run.

LandScan 2011 is used for population weights. The GPW 2010 land-area point
table is used for area weights.

Be careful when changing ID columns, ID widths, year ranges, or shapefile
paths. Those choices affect every file written for that country.
"""

from dataclasses import dataclass
from dataclasses import field
from pathlib import Path


# -----------------------------
# Shared Paths
# -----------------------------

ROOT = Path(__file__).resolve().parents[1]
OUTPUT_ROOT = Path("/project/cil/gcp/estimation/rainfall-mortality/climate_data")
CLIMATE_ROOT = Path("/project/cil/gcp/climate/ERA5-LAND-GLOBAL/raw/daily/global")
PRODUCT = "ERA5-LAND-GLOBAL"
LANDSCAN = Path(
    "/project/cil/battuta_shares/gcp/social/sources/Landscan2011/"
    "RasterGISbinary/lspop2011.flt"
)
GPW_LAND_AREA = Path("/project/cil/gcp/temp_data/gpw_2010_land_area_points")


# -----------------------------
# Country settings
# -----------------------------


@dataclass(frozen=True)
class Country:
    code: str
    level: str
    first_year: int
    last_year: int
    climate_region: str
    shapefile: Path
    id_columns: tuple[str, ...]
    name_columns: tuple[str, ...]
    id_widths: dict[str, int]
    grid_year: int
    column_aliases: dict[str, str] = field(default_factory=dict)
    shapefile_encoding: str | None = None
    # Reviewed units with no source points, entirely inside one climate cell.
    single_cell_ids: tuple[str, ...] = ()
    # Keep reruns for changed boundaries separate from the previous files.
    output_subfolder: str = ""


COUNTRIES = {
    # Cabo Verde combines Ribeira Brava and Tarrafal de Sao Nicolau as 31_32.
    # Keep IDs as text so this combined unit is not padded or split.
    "CPV": Country(
        code="CPV",
        level="adm1",
        first_year=1950,
        last_year=2025,
        climate_region="global",
        shapefile=Path(
            "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/"
            "data/0_data_cleaning/1_raw/Countries/New_Countries/CPV/"
            "Shapefile/1_Clean/CPV_adm1_21_units.gpkg"
        ),
        id_columns=("admin_id",),
        name_columns=("admin_name",),
        id_widths={},
        grid_year=2000,
    ),
    # Thailand uses 74 provinces, one Nong Khai/Bueng Kan group, and 50 khet.
    # The GeoPackage has one layer: THA_public_panel_mixed_adm1_adm2.
    "THA": Country(
        code="THA",
        level="mixed",
        first_year=1950,
        last_year=2025,
        climate_region="global",
        shapefile=Path(
            "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/"
            "data/0_data_cleaning/1_raw/Countries/New_Countries/THA/"
            "Shapefiles/1_Clean/THA_public_panel_mixed_adm1_adm2.gpkg"
        ),
        id_columns=("admin_id",),
        name_columns=("admin_name",),
        id_widths={},
        grid_year=2000,
        output_subfolder="current_boundaries",
    ),
    # Rwanda's supplied deaths are grouped by facility-location district.
    # Keep the same 30 district P-codes used in its cleaned mortality file.
    "RWA": Country(
        code="RWA",
        level="adm2",
        first_year=1950,
        last_year=2025,
        climate_region="global",
        shapefile=Path(
            "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/"
            "data/0_data_cleaning/1_raw/Countries/New_Countries/RWA/"
            "Shapefiles/0_Raw/rwa_adm_2006_nisr_wgs1984_20181002_shp/"
            "rwa_adm2_2006_NISR_WGS1984_20181002.shp"
        ),
        id_columns=("adm2_id",),
        name_columns=("adm2_name",),
        id_widths={},
        grid_year=2000,
        column_aliases={"adm2_id": "ADM2_PCODE", "adm2_name": "ADM2_EN"},
    ),
    # Canada mortality uses the 293 census divisions from the 2021 shapefile.
    "CAN": Country(
        code="CAN",
        level="adm2",
        first_year=1950,
        last_year=2025,
        climate_region="global",
        shapefile=Path(
            "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/"
            "data/0_data_cleaning/1_raw/Countries/New_Countries/CAN/"
            "Shapefiles/lcd_000b21a_e.zip"
        ),
        id_columns=("adm2_id",),
        name_columns=("adm2_name",),
        id_widths={"adm2_id": 4},
        grid_year=2000,
        column_aliases={"adm2_id": "CDUID", "adm2_name": "CDNAME"},
    ),
    # Argentina mortality uses provinces, including Buenos Aires city.
    "ARG": Country(
        code="ARG",
        level="adm1",
        first_year=1950,
        last_year=2025,
        climate_region="global",
        shapefile=Path(
            "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/"
            "data/0_data_cleaning/1_raw/Countries/New_Countries/ARG/"
            "Shapefiles/provincia/provinciaPolygon.shp"
        ),
        id_columns=("province_code",),
        name_columns=("province_name",),
        id_widths={"province_code": 2},
        grid_year=2000,
        column_aliases={"province_code": "in1", "province_name": "nam"},
    ),
    # Costa Rica mortality uses fixed zones based on the 2024 district geography.
    # The GeoPackage contains one layer: fixed_zones_2024.
    "CRI": Country(
        code="CRI",
        level="fixed",
        first_year=1950,
        last_year=2025,
        climate_region="global",
        shapefile=Path(
            "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/"
            "data/0_data_cleaning/1_raw/Countries/New_Countries/CRI/"
            "Shapefiles/1_Clean/CRI_fixed_zones_2024.gpkg"
        ),
        id_columns=("fixed_code",),
        name_columns=("fixed_name",),
        id_widths={"fixed_code": 5},
        grid_year=2000,
        # These small zones contain no LandScan or GPW points.
        single_cell_ids=("CRI_40301", "CRI_10802"),
    ),
    # Botswana mortality uses the 2011 ADM3 units, identified by ADM3_PCODE.
    "BWA": Country(
        code="BWA",
        level="adm3",
        first_year=1950,
        last_year=2025,
        climate_region="global",
        shapefile=Path(
            "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/"
            "data/0_data_cleaning/1_raw/Countries/New_Countries/BWA/"
            "Shapefiles/0_Raw/HDX_COD_AB_BWA/bwa_admbnda_adm3_2011.shp"
        ),
        id_columns=("ADM3_PCODE",),
        name_columns=("ADM3_EN",),
        id_widths={},
        grid_year=2000,
    ),
    # Stable municipality units used by the rebuilt 1997-2024 Brazil panel.
    # Keep this separate from BRA, which is the older Carleton/GADM geography.
    "BRA_STABLE": Country(
        code="BRA_STABLE",
        level="adm2",
        first_year=1950,
        last_year=2025,
        climate_region="brazil",
        shapefile=Path(
            "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/"
            "data/0_data_cleaning/1_raw/Countries/BRA/Shapefile/"
            "IBGE_2010_Stable_1997_2024/"
            "BRA_IBGE_2010_stable_municipalities.gpkg"
        ),
        id_columns=("stable_admin_id",),
        name_columns=("stable_admin_name",),
        id_widths={"stable_admin_id": 6},
        grid_year=2000,
    ),
    "BRA": Country(
        code="BRA",
        level="adm2",
        first_year=1950,
        last_year=2025,
        climate_region="brazil",
        shapefile=Path(
            "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/"
            "Countries/BRA/Shapefile/BRA_adm2.shp"
        ),
        id_columns=("ID_0", "ID_1", "ID_2"),
        name_columns=("NAME_1", "NAME_2"),
        id_widths={"ID_0": 3, "ID_1": 2, "ID_2": 4},
        grid_year=2000,
    ),
    "CHL": Country(
        code="CHL",
        level="adm2",
        first_year=1950,
        last_year=2025,
        climate_region="latam",
        shapefile=Path(
            "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/"
            "Countries/CHL/Shapefile/cl_comunas_geo_mortality_adm2.shp"
        ),
        id_columns=("adm1_id", "adm2_id"),
        name_columns=(),
        id_widths={"adm1_id": 2, "adm2_id": 3},
        grid_year=2000,
    ),
    "CHN": Country(
        code="CHN",
        level="adm2",
        first_year=1950,
        last_year=2025,
        climate_region="asia_combined",
        shapefile=Path(
            "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/"
            "Countries/CHN/Shapefile/china00.shp"
        ),
        id_columns=("PROVGB", "CITYGB", "CNTYGB"),
        name_columns=("EPROV", "ECITY", "ECNTY"),
        id_widths={"PROVGB": 2, "CITYGB": 4, "CNTYGB": 6},
        grid_year=2000,
    ),
    # Colombia's merged municipality units match the parent-zone mortality file.
    "COL": Country(
        code="COL",
        level="adm2",
        first_year=1950,
        last_year=2025,
        climate_region="latam",
        shapefile=Path(
            "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/"
            "data/0_data_cleaning/1_raw/Countries/New_Countries/COL/"
            "Admin_Geocodes/3_Boundary_Changes/parent_zone_units.gpkg"
        ),
        id_columns=("parent_zone_id",),
        name_columns=("parent_zone_name",),
        id_widths={"parent_zone_id": 5},
        grid_year=2000,
        output_subfolder="current_boundaries",
    ),
    # Australia mortality is reported at 2011 SA3 geography. The mortality
    # panel stores the SA3 code as admin_id, and the cleaned shapefile keeps the
    # same code in adm2_id.
    "AUS": Country(
        code="AUS",
        level="adm2",
        first_year=1950,
        last_year=2025,
        climate_region="australia",
        shapefile=Path(
            "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/"
            "data/0_data_cleaning/1_raw/Countries/AUS/Shapefiles/1_Clean/"
            "AUS_sa3_2011.gpkg"
        ),
        id_columns=("adm2_id",),
        name_columns=("adm2",),
        id_widths={"adm2_id": 5},
        grid_year=2010,
    ),
    # Ecuador's final 162 groups match the rebuilt mortality panel.
    "ECU": Country(
        code="ECU",
        level="adm2",
        first_year=1950,
        last_year=2025,
        climate_region="latam",
        shapefile=Path(
            "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/"
            "data/0_data_cleaning/1_raw/Countries/New_Countries/ECU/"
            "Admin_Geocodes/3_Boundary_Changes/reviewed_groups_20261111/"
            "ECU_adm2_grouped_2010/ECU_adm2_grouped_2010.shp"
        ),
        id_columns=("adm2_id",),
        name_columns=("adm2_name",),
        id_widths={"adm2_id": 4},
        grid_year=2000,
        column_aliases={
            "adm2_id": "admin_id",
            "adm2_name": "admin_name",
        },
        output_subfolder="current_boundaries",
    ),
    "EU": Country(
        code="EU",
        level="nuts2",
        first_year=1950,
        last_year=2025,
        climate_region="europe",
        shapefile=Path(
            "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/"
            "Countries/EU/Shapefile/NUTS2_RG_60M_2013_mortality.shp"
        ),
        id_columns=("NUTS_ID",),
        name_columns=(),
        id_widths={},
        grid_year=2000,
    ),
    "FRA": Country(
        code="FRA",
        level="adm2",
        first_year=1950,
        last_year=2025,
        climate_region="europe",
        shapefile=Path(
            "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/"
            "Countries/FRA/Shapefile/FRA_adm2.shp"
        ),
        id_columns=("ID_0", "ID_1", "ID_2"),
        name_columns=("NAME_1", "NAME_2"),
        id_widths={"ID_0": 3, "ID_1": 2, "ID_2": 2},
        grid_year=2000,
    ),
    # India uses the 1961 district shapefile used by the mortality panel.
    "IND": Country(
        code="IND",
        level="adm2",
        first_year=1950,
        last_year=2025,
        climate_region="india",
        shapefile=Path(
            "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/"
            "Countries/IND/Shapefile/1961_districts/1961_districts_final.shp"
        ),
        id_columns=("UNID",),
        name_columns=("STATE_UT", "NAME"),
        id_widths={"UNID": 3},
        grid_year=2000,
    ),
    "JPN": Country(
        code="JPN",
        level="adm1",
        first_year=1950,
        last_year=2025,
        climate_region="asia_combined",
        shapefile=Path(
            "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/"
            "Countries/JPN/Shapefile/JPN_adm1.shp"
        ),
        id_columns=("ID_0", "ID_1"),
        name_columns=("NAME_1",),
        id_widths={"ID_0": 3, "ID_1": 2},
        grid_year=2000,
    ),
    "KOR": Country(
        code="KOR",
        level="adm2",
        first_year=1950,
        last_year=2025,
        climate_region="asia_combined",
        shapefile=Path(
            "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/"
            "Countries/KOR/Mortality/dta/shapefile/korea_adm2.shp"
        ),
        id_columns=("adm2_n_",),
        name_columns=("adm_nam",),
        id_widths={"adm2_n_": 5},
        grid_year=2000,
        shapefile_encoding="CP949",
    ),
    "MEX": Country(
        code="MEX",
        level="adm2",
        first_year=1950,
        last_year=2025,
        climate_region="mexico",
        shapefile=Path(
            "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/"
            "Countries/MEX/Shapefile/harmonized/"
            "boundaries_4795_IPUMS_MX_HSLAD_1990_2015.shp"
        ),
        id_columns=("GEOID",),
        name_columns=("LABEL",),
        id_widths={"GEOID": 9},
        grid_year=2000,
    ),
    "USA": Country(
        code="USA",
        level="adm2",
        first_year=1950,
        last_year=2025,
        climate_region="usa",
        shapefile=Path(
            "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/"
            "Countries/USA/Shapefile/tl_2016_us_county_mortality.shp"
        ),
        id_columns=("ID_0", "ID_1", "ID_2"),
        name_columns=("NAME", "NAMELSAD"),
        id_widths={"ID_0": 3, "ID_1": 2, "ID_2": 3},
        grid_year=2000,
    ),
    # Philippines municipalities that changed boundaries are combined in this map.
    # read_admins() excludes parent zones marked drop_no_barmm, leaving 1,509 units.
    "PHL": Country(
        code="PHL",
        level="adm3",
        first_year=1950,
        last_year=2025,
        climate_region="asia_combined",
        shapefile=Path(
            "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/"
            "data/0_data_cleaning/1_raw/Countries/New_Countries/PHL/"
            "Admin_Geocodes/3_Boundary_Changes/parent_zone_units.gpkg"
        ),
        id_columns=("parent_zone_id",),
        name_columns=("parent_zone_name",),
        id_widths={"parent_zone_id": 10},
        grid_year=2010,
        output_subfolder="current_boundaries",
    ),
    # Peru's 196 panel ADM2 units combine the original MINAM district polygons.
    "PER": Country(
        code="PER",
        level="adm2",
        first_year=1950,
        last_year=2025,
        climate_region="latam",
        shapefile=Path(
            "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/"
            "data/0_data_cleaning/1_raw/Countries/New_Countries/PER/"
            "Shapefiles/1_Clean/PER_adm2_panel.geojson"
        ),
        id_columns=("shp_adm2_code",),
        name_columns=("shp_adm2_name",),
        id_widths={"shp_adm2_code": 4},
        grid_year=2020,
        output_subfolder="current_boundaries",
    ),
}


# -----------------------------
# Derived Paths
# -----------------------------


def country(code: str) -> Country:
    code = code.upper()
    if code not in COUNTRIES:
        raise ValueError(f"Unknown country: {code}")
    return COUNTRIES[code]


def climate_file(spec: Country, variable: str, year: int) -> Path:
    # Use January when a script only needs the grid, not a full year of data.
    return monthly_climate_file(variable, year, 1)


def monthly_climate_file(variable: str, year: int, month: int) -> Path:
    # Global ERA5-Land files are one variable-month per file.
    # Example:
    #   global/tp_total/era5land_global_tp_total_2020_01.nc4
    return (
        CLIMATE_ROOT
        / variable
        / f"era5land_global_{variable}_{year}_{month:02d}.nc4"
    )


def weights_dir(spec: Country) -> Path:
    return OUTPUT_ROOT / "weights/landscan2011" / PRODUCT / spec.code / spec.output_subfolder


def weights_file(spec: Country) -> Path:
    slug = spec.code.lower()
    return (
        weights_dir(spec)
        / f"era5land_{slug}_{spec.level}_segment_weights_landscan2011.csv"
    )


def admin_file(spec: Country) -> Path:
    slug = spec.code.lower()
    return weights_dir(spec) / f"era5land_{slug}_{spec.level}_admin_summary.csv"


def result_dir(spec: Country) -> Path:
    return OUTPUT_ROOT / PRODUCT / spec.code / spec.output_subfolder
