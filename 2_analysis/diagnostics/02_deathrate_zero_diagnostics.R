# ==============================================================================
# 02_deathrate_zero_diagnostics.R
#
# Summarize zero death rates in the mortality panel.
#
# This script uses the full panel, including the all-age group. The regression
# sample drops all-age rows later, but they are useful here for checking whether
# zero death rates are concentrated in particular ages or small admin units.
#
# Outputs:
#   output/data/diagnostics/deathrate_zeros/zero_deathrate_by_agegroup.csv
#   output/data/diagnostics/deathrate_zeros/zero_deathrate_by_country_agegroup.csv
#   output/data/diagnostics/deathrate_zeros/zero_deathrate_admin_unit_detail.csv
#   output/tables/diagnostics/deathrate_zeros/zero_deathrate_by_agegroup.tex
#   output/tables/diagnostics/deathrate_zeros/zero_deathrate_country_age_nontrivial.tex
# ==============================================================================

# -----------------------------
# Packages
# -----------------------------

suppressPackageStartupMessages({
  library(data.table)
  library(dplyr)
  library(knitr)
  library(kableExtra)
  library(readr)
  library(scales)
})

# -----------------------------
# Paths
# -----------------------------

args <- commandArgs(FALSE)
file_arg <- args[grepl("^--file=", args)]

# Start from this folder so the relative source paths below work
# This matters when the script is run from sbatch
script_dir <- if (length(file_arg) > 0) {
  dirname(normalizePath(sub("^--file=", "", file_arg[[1]])))
} else {
  getwd()
}
setwd(script_dir)

USER <- Sys.getenv("USER")

# Load repo paths used for the output folders below
source("../../0_utils/paths.R") # DIR_REPO_RAINFALL_MORTALITY

# Read the full panel directly so all-age rows are kept
# `load_new_panel()` drops them when preparing the regression sample
panel_path <- file.path(
  "/project/cil/gcp/estimation/rainfall-mortality",
  "mortality_data", "panel_build", "combined_panel",
  "new_mortality_panel.csv"
)

out_dir <- file.path(
  DIR_REPO_RAINFALL_MORTALITY,
  "output", "data", "diagnostics", "deathrate_zeros"
)

table_dir <- file.path(
  DIR_REPO_RAINFALL_MORTALITY,
  "output", "tables", "diagnostics", "deathrate_zeros"
)

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(table_dir, recursive = TRUE, showWarnings = FALSE)

# Age labels used in the CSV summaries and LaTeX tables
age_labels <- c(
  "0" = "All ages",
  "1" = "0-4",
  "2" = "5-64",
  "3" = "65+"
)

# Formatting used in the LaTeX tables
format_count <- function(x) {
  comma(x, accuracy = 1)
}

format_percent <- function(x) {
  percent(x, accuracy = 0.1)
}

# -----------------------------
# Read panel
# -----------------------------

# Read only the variables needed for the zero-death-rate checks
panel <- fread(
  panel_path,
  select = c(
    "adm0", "iso",
    "adm1_id", "adm1_name",
    "adm2_id", "adm2_name",
    "adm3_id", "adm3_name",
    "admin_id", "admin_name", "admin_level",
    "year", "agegroup",
    "deaths", "population", "deathrate"
  )
)

# Missing death rates are excluded from the denominator when calculating
# the share of rows with zero death rates
panel <- panel %>%
  mutate(
    zero_deathrate = !is.na(deathrate) & deathrate == 0,
    nonmissing_deathrate = !is.na(deathrate)
  )

# -----------------------------
# Zero rates by age group
# -----------------------------

# Summarize how often zero death rates appear in each age group
agegroup_summary <- panel %>%
  group_by(agegroup) %>%
  summarize(
    rows = n(),
    rows_nonmissing_deathrate = sum(nonmissing_deathrate),
    zero_deathrate_rows = sum(zero_deathrate),
    share_zero_deathrate = zero_deathrate_rows / rows_nonmissing_deathrate,
    countries_with_zero_deathrate = n_distinct(iso[zero_deathrate]),
    admin_units_with_zero_deathrate = n_distinct(admin_id[zero_deathrate]),
    .groups = "drop"
  ) %>%
  arrange(agegroup)

write_csv(
  agegroup_summary,
  file.path(out_dir, "zero_deathrate_by_agegroup.csv")
)

# Make a compact LaTeX version of the age-group summary
agegroup_table <- agegroup_summary %>%
  mutate(
    `Age group` = recode(as.character(agegroup), !!!age_labels),
    `Rows` = format_count(rows),
    `Nonmissing rows` = format_count(rows_nonmissing_deathrate),
    `Zero rows` = format_count(zero_deathrate_rows),
    `\\% zero deathrate` = format_percent(share_zero_deathrate),
    `Countries with zeros` = format_count(countries_with_zero_deathrate),
    `Admin units with zeros` = format_count(admin_units_with_zero_deathrate)
  ) %>%
  select(
    `Age group`, `Rows`, `Nonmissing rows`, `Zero rows`,
    `\\% zero deathrate`, `Countries with zeros`, `Admin units with zeros`
  ) %>%
  kbl(
    format = "latex",
    booktabs = TRUE,
    escape = FALSE,
    align = c("l", rep("r", 6)),
    caption = "Zero deathrate shares by age group",
    label = "zero_deathrate_by_agegroup",
    linesep = ""
  ) %>%
  kable_styling(
    latex_options = c("hold_position"),
    font_size = 8,
    position = "center"
  ) %>%
  row_spec(0, bold = TRUE)

writeLines(
  agegroup_table,
  file.path(table_dir, "zero_deathrate_by_agegroup.tex")
)

# -----------------------------
# Zero rates by country and age
# -----------------------------

# Keep country-age groups with at least one zero death-rate row
country_age_summary <- panel %>%
  group_by(iso, adm0, agegroup) %>%
  summarize(
    rows = n(),
    rows_nonmissing_deathrate = sum(nonmissing_deathrate),
    zero_deathrate_rows = sum(zero_deathrate),
    share_zero_deathrate = zero_deathrate_rows / rows_nonmissing_deathrate,
    years_with_zero_deathrate = n_distinct(year[zero_deathrate]),
    admin_units_with_zero_deathrate = n_distinct(admin_id[zero_deathrate]),
    .groups = "drop"
  ) %>%
  filter(zero_deathrate_rows > 0) %>%
  arrange(agegroup, desc(share_zero_deathrate), iso)

write_csv(
  country_age_summary,
  file.path(out_dir, "zero_deathrate_by_country_agegroup.csv")
)

# Limit the LaTeX table to country-age groups where at least 1% of rows have
# zero death rates
country_age_table <- country_age_summary %>%
  filter(share_zero_deathrate >= 0.01) %>%
  mutate(
    `Country` = adm0,
    `ISO` = iso,
    `Age group` = recode(as.character(agegroup), !!!age_labels),
    `Rows` = format_count(rows),
    `Nonmissing rows` = format_count(rows_nonmissing_deathrate),
    `Zero rows` = format_count(zero_deathrate_rows),
    `\\% zero deathrate` = format_percent(share_zero_deathrate),
    `Years with zeros` = format_count(years_with_zero_deathrate),
    `Admin units with zeros` = format_count(admin_units_with_zero_deathrate)
  ) %>%
  arrange(agegroup, desc(share_zero_deathrate), iso) %>%
  select(
    `Country`, `ISO`, `Age group`, `Rows`, `Nonmissing rows`,
    `Zero rows`, `\\% zero deathrate`, `Years with zeros`,
    `Admin units with zeros`
  ) %>%
  kbl(
    format = "latex",
    booktabs = TRUE,
    escape = FALSE,
    align = c("l", "l", "l", rep("r", 6)),
    caption = "Country-age cells with at least 1 percent zero deathrate rows",
    label = "zero_deathrate_country_age_nontrivial",
    linesep = ""
  ) %>%
  kable_styling(
    latex_options = c("hold_position", "scale_down"),
    font_size = 7,
    position = "center"
  ) %>%
  row_spec(0, bold = TRUE)

writeLines(
  country_age_table,
  file.path(table_dir, "zero_deathrate_country_age_nontrivial.tex")
)

# -----------------------------
# Admin-unit detail
# -----------------------------

# List every admin unit and age group with at least one zero death-rate row,
# including when the zeros occur and the average population of those rows
zero_admin_detail <- panel %>%
  filter(zero_deathrate) %>%
  group_by(
    iso, adm0,
    adm1_id, adm1_name,
    adm2_id, adm2_name,
    adm3_id, adm3_name,
    admin_id, admin_name, admin_level,
    agegroup
  ) %>%
  summarize(
    zero_deathrate_rows = n(),
    first_zero_year = min(year, na.rm = TRUE),
    last_zero_year = max(year, na.rm = TRUE),
    zero_years = paste(sort(unique(year)), collapse = "; "),
    mean_population_zero_rows = mean(population, na.rm = TRUE),
    total_deaths_zero_rows = sum(deaths, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  arrange(iso, agegroup, admin_level, admin_name)

write_csv(
  zero_admin_detail,
  file.path(out_dir, "zero_deathrate_admin_unit_detail.csv")
)

# -----------------------------
# Console summary
# -----------------------------

message("Wrote zero deathrate diagnostics to: ", out_dir)
message("Wrote zero deathrate LaTeX tables to: ", table_dir)
message("Age groups with zero death rates: ", nrow(filter(agegroup_summary, zero_deathrate_rows > 0)))
message("Country-age cells with zero death rates: ", nrow(country_age_summary))