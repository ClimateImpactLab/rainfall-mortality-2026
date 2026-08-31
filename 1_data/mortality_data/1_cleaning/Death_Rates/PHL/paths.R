# Shared paths for the Philippines mortality and population cleaning scripts

user_name <- Sys.getenv("USER")
if (user_name == "") user_name <- Sys.info()[["user"]]

default_repo_dir <- file.path("/project/cil/home_dirs", user_name, "repos/rainfall-mortality-2026")
repo_dir <- Sys.getenv("RAINFALL_MORTALITY_REPO", unset = default_repo_dir)

default_phl_data_dir <- "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/data/0_data_cleaning/1_raw/Countries/New_Countries/PHL"
phl_data_dir <- Sys.getenv("PHL_MORTALITY_DATA_ROOT", unset = default_phl_data_dir)

phl_code_dir <- file.path(repo_dir,"1_data", "mortality_data", "1_cleaning", "PHL")

mortality_raw_dir <- file.path(phl_data_dir, "Mortality", "0_Raw")
mortality_clean_dir <- file.path(phl_data_dir, "Mortality", "1_Clean")
death_records_dir <- file.path(mortality_clean_dir, "Death_Records")
death_rates_dir <- file.path(mortality_clean_dir, "Death_Rates")
descriptive_tables_dir <- file.path(
  mortality_clean_dir, "Descriptive_Tables"
)

admin_geocodes_dir <- file.path(phl_data_dir, "Admin_Geocodes")
admin_geocodes_raw_dir <- file.path(admin_geocodes_dir, "0_Raw")
admin_geocodes_clean_dir <- file.path(admin_geocodes_dir, "1_Clean")
admin_crosswalks_dir <- file.path(admin_geocodes_dir, "2_Crosswalks")

shapefiles_dir <- file.path(phl_data_dir, "Shapefiles")
post2023_shapefiles_dir <- file.path(shapefiles_dir, "Post2023")

population_dir <- file.path(phl_data_dir, "Population")
population_raw_dir <- file.path(population_dir, "0_Raw")
population_clean_dir <- file.path(population_dir, "1_Clean")
population_interpolated_dir <- file.path(population_dir, "2_Interpolated")
