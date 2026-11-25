# ==============================================================================
# climate_inputs.R
#
# Read the current country climate files and match them to panel IDs.
# Used by 2a, 2b, 2e and 2g so climate sources use the same panel IDs.
# Sourced after paths.R and with build_dir set.
# ==============================================================================

# --------------------------------
# Country lists and ID crosswalk
# --------------------------------

# New countries, from country_files.csv without the excluded ones
country_files <- readr::read_csv(
  file.path(build_dir, "country_files.csv"), show_col_types = FALSE,
  col_types = readr::cols(.default = readr::col_character())
) %>% filter(!iso %in% excluded_countries)

# Current ERA5-Land admin maps, one row per country with its climate folder
climate_maps <- readr::read_csv(climate_maps_file, show_col_types = FALSE) %>%
  filter(!country %in% excluded_countries)

# CHIRPS has its own grid and weights, but uses the same admin maps and IDs
chirps_maps <- readr::read_csv(chirps_maps_file, show_col_types = FALSE,
                              col_types = readr::cols(.default = readr::col_character())) %>%
  filter(!country %in% excluded_countries) %>%
  mutate(climate_folder = file.path(chirps_dir, country, coalesce(output_subfolder, "")))

# Old-panel countries: ERA5-Land region_id to panel iso and admin_id
# New countries are left out, they are matched by region_id in panel_climate_ids
crosswalk <- readr::read_csv(
  file.path(era5land_global_dir, "combined/era5land_to_global_panel_crosswalk.csv"),
  show_col_types = FALSE, col_types = readr::cols(.default = readr::col_character())
) %>%
  filter(match_status == "matched", !panel_iso %in% c(country_files$iso, excluded_countries)) %>%
  transmute(climate_country, region_id, iso = panel_iso,
            admin_id = paste(coalesce(panel_adm1_id, ""), coalesce(panel_adm2_id, ""), sep = "_")) %>%
  distinct()

# ------------------------
# Read and match climate
# ------------------------

# Read all yearly or monthly files of one country and product
# The current-map list supplies the folder
# This includes current_boundaries where used
read_climate_source <- function(code, period, variables, product = "ERA5LAND") {
  # ERA5-Land starts in 1950 and CHIRPS starts in 1981, both end in 2025
  maps <- if (product == "CHIRPS") chirps_maps else climate_maps
  expected_years <- if (product == "CHIRPS") 1981:2025 else 1950:2025
  folder <- maps$climate_folder[maps$country == code]
  if (length(folder) != 1) stop(code, ": no unique ", product, " folder.", call. = FALSE)
  file_period <- if (period == "wind") "wind_annual" else period
  files <- sort(list.files(file.path(folder, period),
                          pattern = paste0("_", file_period, "_[0-9]{4}\\.csv$"), full.names = TRUE))
  years <- as.integer(sub(".*_([0-9]{4})\\.csv$", "\\1", files))
  if (!identical(years, expected_years)) stop(code, ": incomplete ", product, " ", period, " file years.", call. = FALSE)

  time_column <- if (period == "monthly") "month" else "year"
  climate <- data.table::rbindlist(lapply(files, function(path) {
    # Climate values are numeric even when a CSV has only whole numbers
    data.table::fread(path, select = c("region_id", time_column, variables),
                     colClasses = list(character = "region_id", numeric = variables))
  })) %>% as_tibble() %>% mutate(climate_country = code)
  if (anyDuplicated(climate[c("region_id", time_column)])) {
    stop(code, ": repeated climate admin-date rows.", call. = FALSE)
  }
  climate
}

# Add last year and next year climate to each admin-year
# Join by the actual year, not the preceding/following row in the file.
# If 2019 is missing, 2018 must not become the lag of 2020.
add_climate_years <- function(climate, variables) {
  keys <- c("iso", "admin_id", "year")
  if (anyDuplicated(climate[keys])) stop("Repeated climate admin-years.", call. = FALSE)
  previous <- climate %>% select(all_of(c(keys, variables))) %>% mutate(year = year + 1L) %>%
    rename_with(~ paste0(.x, "_lag1"), all_of(variables))
  following <- climate %>% select(all_of(c(keys, variables))) %>% mutate(year = year - 1L) %>%
    rename_with(~ paste0(.x, "_lead1"), all_of(variables))
  climate %>% left_join(previous, by = keys) %>% left_join(following, by = keys)
}

# Match climate region_id to panel iso and admin_id, for old and new countries
# Strip only the country prefix. For example, CPV_31_32 becomes 31_32, not 32.
# BRA_STABLE is a climate folder name, its panel ISO is BRA.
panel_climate_ids <- function(climate, variables, ignore_missing = FALSE) {
  time_column <- intersect(c("year", "month"), names(climate))
  old <- climate %>% inner_join(crosswalk, by = c("climate_country", "region_id")) %>%
    select(iso, admin_id, all_of(time_column), all_of(variables))
  new <- climate %>% inner_join(
    country_files %>% select(iso, climate_country), by = "climate_country"
  ) %>% mutate(admin_id = substring(region_id, nchar(climate_country) + 2L)) %>%
    select(iso, admin_id, all_of(time_column), all_of(variables))

  # Average when two old climate regions match one panel unit
  # Missing precipitation or temperature stays missing
  # Wind uses the available values
  bind_rows(old, new) %>% group_by(across(all_of(c("iso", "admin_id", time_column)))) %>%
    summarize(across(all_of(variables), ~ mean(.x, na.rm = ignore_missing)), .groups = "drop") %>%
    mutate(across(all_of(variables), ~ replace(.x, is.nan(.x), NA_real_)))
}
