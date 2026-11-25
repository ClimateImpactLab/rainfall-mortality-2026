# ==============================================================================
# 1b_prepare_new_countries.R
#
# Combine the mortality files for the new countries
#
# Each country is cleaned in its own folder. country_files.csv lists the final
# country files used here
#
# admin_id and admin_name identify the unit used in the panel
# ADM1-ADM3 cols are kept where available
# Climate and other vars are added later
#
# Input:  country_files.csv, and the country files it lists
# Output: new_countries/new_countries_mortality.csv
# ==============================================================================


# ----------------
# Packages
# ----------------

library(dplyr)
library(readr)


# --------------
# Paths
# --------------

# Run from the panel_build folder
build_dir <- getwd()
source(file.path(build_dir, "paths.R"))

country_file <- file.path(build_dir, "country_files.csv")
out_file <- file.path(new_country_dir, "new_countries_mortality.csv")


# -------------------
# Country files
# -------------------

# The final file of each new country, without the excluded ones (paths.R)
country_files <- read_csv(country_file, col_types = cols(.default = col_character()))
country_files <- country_files %>% filter(!iso %in% excluded_countries)

# Mortality cols kept, anything else is dropped here
required_cols <- c(
  "iso", "adm0", "admin_level", "admin_id", "admin_name",
  "adm1_id", "adm1_name", "adm2_id", "adm2_name", "adm3_id", "adm3_name",
  "year", "agegroup", "deaths", "population", "deathrate"
)


# ----------------------
# Read country panels
# ----------------------

# Read one country's file, with the IDs as text so leading zeroes are kept
read_country_panel <- function(file) {
  panel <- read_csv(
    file,
    show_col_types = FALSE, col_types = cols(.default = col_character())
  )

  # Keep the panel cols, IDs as text and counts as numbers
  panel %>%
    select(all_of(required_cols)) %>%
    mutate(
      across(
        c(iso, adm0, admin_level, admin_id, admin_name,
          adm1_id, adm1_name, adm2_id, adm2_name, adm3_id, adm3_name),
        as.character
        ),
      across(c(year, agegroup, deaths, population, deathrate), as.numeric)
    )
}

# Read 1 country at a time so any error is easy to trace
country_panels <- list()

for (row in seq_len(nrow(country_files))) {
  file <- country_files$panel_file[[row]]
  iso <- country_files$iso[[row]]

  message("Reading ", iso, ": ", file)
  country_panels[[row]] <- read_country_panel(file)
}

# All countries in one table
panel <- bind_rows(country_panels) %>%
  arrange(iso, admin_id, year, agegroup)

# Stop if a row is repeated, it would also duplicate the climate added later
if (anyDuplicated(panel[c("iso", "admin_id", "year", "agegroup")])) {
  stop("Repeated country-admin-year-agegroup rows.", call. = FALSE)
}

# ---------------
# Write
# ---------------

write_csv(panel, out_file, na = "")

message("Wrote new country mortality panel: ", out_file)
