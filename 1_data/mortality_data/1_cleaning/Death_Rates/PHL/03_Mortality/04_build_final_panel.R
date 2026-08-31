# ============================================================
# 04_build_final_panel.R
#
# Build the standardized Philippines ADM3 mortality panel for the
# global rainfall-mortality append step.
# ============================================================

library(dplyr)
library(readr)
library(sf)
library(writexl)

user_name <- Sys.getenv("USER", unset = Sys.info()[["user"]])
repo_dir <- Sys.getenv("RAINFALL_MORTALITY_REPO")
if (repo_dir == "") {
  repo_dir <- file.path(
    "/project/cil/home_dirs", user_name, "repos/rainfall-mortality-2026"
  )
}

source(file.path(
  repo_dir, "1_data/mortality_data/1_cleaning/Death_Rates/PHL/paths.R"
))

final_dir <- file.path(
  "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020",
  "data/0_data_cleaning/3_final/PHL"
)
dir.create(final_dir, recursive = TRUE, showWarnings = FALSE)

total_rates_file <- file.path(death_rates_dir, "adm3_year_total_no_barmm.csv")
age_rates_file <- file.path(death_rates_dir, "adm3_year_age_broad_no_barmm.csv")
population_file <- file.path(
  population_interpolated_dir, "PHL_population_annual_adm3.csv"
)
aligned_deaths_file <- file.path(
  death_records_dir, "PHL_death_records_adm3_aligned.csv"
)
shapefile_path <- file.path(
  post2023_shapefiles_dir,
  "PH_Adm3_MuniCities.shp/PH_Adm3_MuniCities.shp.shp"
)
climate_admin_summary_file <- file.path(
  repo_dir,
  "1_data/climate_data/climate_aggregation/outputs/weights/landscan2011",
  "ERA5-LAND/PHL/era5land_phl_adm3_admin_summary.csv"
)

total_rates <- read_csv(
  total_rates_file,
  col_types = cols(
    shp_adm1_code = col_character(),
    shp_adm2_code = col_character(),
    shp_adm3_code = col_character(),
    psgc_adm3_code = col_character(),
    .default = col_guess()
  ),
  show_col_types = FALSE
)

age_rates <- read_csv(
  age_rates_file,
  col_types = cols(
    shp_adm1_code = col_character(),
    shp_adm2_code = col_character(),
    shp_adm3_code = col_character(),
    psgc_adm3_code = col_character(),
    .default = col_guess()
  ),
  show_col_types = FALSE
)

shapefile_ids <- st_read(shapefile_path, quiet = TRUE) |>
  st_drop_geometry() |>
  transmute(
    shapefile_admin_id = sprintf("%010.0f", as.numeric(adm3_psgc)),
    shapefile_admin_name = as.character(adm3_en)
  ) |>
  distinct()

make_panel <- function(data) {
  data |>
    transmute(
      iso = "PHL",
      adm0 = "Philippines",
      admin_level = "ADM3",
      admin_id = shp_adm3_code,
      admin_name = shp_adm3_name,
      adm1_id = shp_adm1_code,
      adm1_name = shp_adm1_name,
      adm2_id = shp_adm2_code,
      adm2_name = shp_adm2_name,
      adm3_id = shp_adm3_code,
      adm3_name = shp_adm3_name,
      year = as.integer(year),
      agegroup = as.integer(agegroup),
      deaths = as.numeric(deaths),
      population = as.numeric(population),
      deathrate = as.numeric(death_rate_per_100000)
    )
}

panel_all <- total_rates |>
  mutate(agegroup = 0L) |>
  make_panel()
panel_age <- age_rates |>
  mutate(
    agegroup = case_when(
      age_group_broad == "0-4" ~ 1L,
      age_group_broad == "5-64" ~ 2L,
      age_group_broad == "65+" ~ 3L,
      TRUE ~ NA_integer_
    )
  ) |>
  make_panel()

final_panel <- bind_rows(panel_all, panel_age) |>
  arrange(iso, admin_id, year, agegroup)

duplicate_keys <- final_panel |>
  count(iso, admin_id, year, agegroup, name = "rows") |>
  filter(rows > 1L)

admin_identity_check <- final_panel |>
  distinct(iso, admin_id, admin_name, adm1_id, adm1_name, adm2_id, adm2_name) |>
  count(iso, admin_id, name = "distinct_admin_records") |>
  filter(distinct_admin_records > 1L)

missing_counts <- final_panel |>
  summarise(
    missing_deaths = sum(is.na(deaths)),
    missing_population = sum(is.na(population)),
    missing_deathrate = sum(is.na(deathrate))
  )

missing_deathrate_allowed <- final_panel |>
  filter(is.na(deathrate)) |>
  summarise(
    all_zero_deaths_and_population = all(deaths == 0 & population == 0)
  ) |>
  pull(all_zero_deaths_and_population)

rows_by_agegroup <- final_panel |>
  count(agegroup, name = "rows") |>
  arrange(agegroup)

rate_summary <- final_panel |>
  summarise(
    rows = n(),
    min_deathrate = min(deathrate, na.rm = TRUE),
    median_deathrate = median(deathrate, na.rm = TRUE),
    p95_deathrate = quantile(deathrate, 0.95, na.rm = TRUE),
    p99_deathrate = quantile(deathrate, 0.99, na.rm = TRUE),
    max_deathrate = max(deathrate, na.rm = TRUE),
    .by = agegroup
  ) |>
  arrange(agegroup)

highest_rates <- final_panel |>
  arrange(desc(deathrate)) |>
  slice_head(n = 20)

smallest_population <- final_panel |>
  arrange(agegroup, population) |>
  group_by(agegroup) |>
  slice_head(n = 20) |>
  ungroup()

rate_admin_ids <- final_panel |> distinct(admin_id)
shape_admin_ids <- shapefile_ids |> distinct(shapefile_admin_id)

unmatched_mortality_ids <- anti_join(
  final_panel |> distinct(admin_id, admin_name, adm1_id, adm1_name, adm2_id, adm2_name),
  shape_admin_ids,
  by = c("admin_id" = "shapefile_admin_id")
)

unmatched_shapefile_ids <- anti_join(
  shapefile_ids,
  rate_admin_ids,
  by = c("shapefile_admin_id" = "admin_id")
)

shape_match_summary <- tibble::tibble(
  check = c(
    "shapefile_path",
    "shapefile_id_field",
    "mortality_admin_id_source_field",
    "mortality_unique_admin_id_values",
    "shapefile_unique_id_values",
    "matched_unique_ids",
    "unmatched_mortality_admin_id_values",
    "unmatched_shapefile_id_values"
  ),
  value = as.character(c(
    shapefile_path,
    "adm3_psgc",
    "shp_adm3_code",
    nrow(rate_admin_ids),
    nrow(shape_admin_ids),
    nrow(inner_join(rate_admin_ids, shape_admin_ids,
                   by = c("admin_id" = "shapefile_admin_id"))),
    nrow(unmatched_mortality_ids),
    nrow(unmatched_shapefile_ids)
  ))
)

audit_summary <- tibble::tibble(
  check = c(
    "terminal_admin_units",
    "first_year",
    "last_year",
    "total_rows",
    "duplicate_iso_admin_year_agegroup_rows",
    "admin_ids_with_multiple_parent_or_name_records",
    "missing_deaths",
    "missing_population",
    "missing_deathrate"
  ),
  value = c(
    n_distinct(final_panel$admin_id),
    min(final_panel$year),
    max(final_panel$year),
    nrow(final_panel),
    nrow(duplicate_keys),
    nrow(admin_identity_check),
    missing_counts$missing_deaths,
    missing_counts$missing_population,
    missing_counts$missing_deathrate
  )
)

source_notes <- tibble::tribble(
  ~item, ~value,
  "iso", "PHL",
  "adm0", "Philippines",
  "terminal geography", "ADM3 city/municipality",
  "final geography vintage", "Post-2023 PSGC-compatible ADM3 shapefile",
  "all-age rate input", total_rates_file,
  "broad-age rate input", age_rates_file,
  "aligned death record input used upstream", aligned_deaths_file,
  "population input used upstream", population_file,
  "shapefile path", shapefile_path,
  "shapefile ID field", "adm3_psgc",
  "climate admin summary using the same shapefile", climate_admin_summary_file,
  "admin_id", "shp_adm3_code, the 10-character ADM3 code matching shapefile field adm3_psgc",
  "agegroup 0", "All ages from adm3_year_total_no_barmm.csv",
  "agegroup 1", "Ages 0-4 from adm3_year_age_broad_no_barmm.csv",
  "agegroup 2", "Ages 5-64 from adm3_year_age_broad_no_barmm.csv",
  "agegroup 3", "Ages 65+ from adm3_year_age_broad_no_barmm.csv",
  "boundary harmonization",
  "Deaths and population were harmonized to the current ADM3 geography before rate construction. Historical parent deaths were split using the same allocation shares used in the population boundary alignment, producing fractional deaths where boundaries split.",
  "PSGC note",
  "Most shapefile IDs match the current official PSGC code. Negros Island Region units keep the shapefile-compatible codes because climate and GHSL extraction use the existing ADM3 shapefile geometry IDs.",
  "BARMM decision",
  "BARMM is excluded from the final file because it has unusual population changes, nearly all high-population zero-death ADM3-years, most very low ADM3 rate outliers, and implausibly low province-year resident death totals."
)

csv_out <- file.path(
  final_dir,
  "PHL_mortality_population_panel_adm3_year_agegroup_no_barmm.csv"
)
audit_out <- file.path(
  final_dir,
  "PHL_mortality_population_panel_adm3_year_agegroup_no_barmm_audit.xlsx"
)

write_csv(final_panel, csv_out)
write_xlsx(
  list(
    Summary = audit_summary,
    `Rows by Agegroup` = rows_by_agegroup,
    `Duplicate Keys` = duplicate_keys,
    `Admin Identity Check` = admin_identity_check,
    `Missing Counts` = missing_counts,
    `Rate Summary` = rate_summary,
    `Highest Rates` = highest_rates,
    `Smallest Population` = smallest_population,
    `Shapefile Match` = shape_match_summary,
    `Unmatched Mortality IDs` = unmatched_mortality_ids,
    `Unmatched Shapefile IDs` = unmatched_shapefile_ids,
    `Source Notes` = source_notes
  ),
  audit_out
)

stopifnot(
  all(nchar(final_panel$admin_id) == 10L),
  all(nchar(final_panel$adm1_id) == 10L),
  all(nchar(final_panel$adm2_id) == 10L),
  all(final_panel$agegroup %in% 0:3),
  nrow(duplicate_keys) == 0L,
  nrow(admin_identity_check) == 0L,
  missing_counts$missing_deaths == 0L,
  missing_counts$missing_population == 0L,
  missing_deathrate_allowed,
  nrow(unmatched_mortality_ids) == 0L
)

print(audit_summary, n = Inf)
print(rows_by_agegroup, n = Inf)
print(shape_match_summary, n = Inf)
message("Final Philippines mortality panel complete: ", csv_out)
