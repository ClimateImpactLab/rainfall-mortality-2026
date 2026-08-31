# ============================================================
# 01_prepare_cause_summary.R
#
# Count weighted deaths by three-digit ICD-10 cause across 2006–2024.
# Write one full-country summary and one summary without BARMM.
#
# Input:
#   Mortality/1_Clean/Death_Records/PHL_death_records_adm3_aligned.csv
#
# Output:
#   Mortality/1_Clean/Descriptive_Tables/phl_cause_summary.csv
#   Mortality/1_Clean/Descriptive_Tables/phl_cause_summary_no_barmm.csv
# ============================================================

library(dplyr)


# -----------------------------
# Paths
# -----------------------------

user_name <- Sys.getenv("USER", unset = Sys.info()[["user"]])
repo_dir <- Sys.getenv("RAINFALL_MORTALITY_REPO")
if (repo_dir == "") repo_dir <- file.path("/project/cil/home_dirs", user_name, "repos/rainfall-mortality-2026")
source(file.path(repo_dir, "1_data/mortality_data/1_cleaning/Death_Rates/PHL/paths.R"))

mortality_file <- file.path(
  death_records_dir,
  "PHL_death_records_adm3_aligned.csv"
)

# Check that the aligned death records exist
if (!file.exists(mortality_file)) {
  stop("Missing mortality file:\n", mortality_file)
}

# Create output folder
dir.create(descriptive_tables_dir, recursive = TRUE, showWarnings = FALSE)
data.table::setDTthreads(4)


# -----------------------------
# Read deaths
# -----------------------------

# Keep only cause, weight, and resident region
mortality <- data.table::fread(
  mortality_file,
  select = c("cause_code_3d", "cause_name", "death_weight", "res_shp_adm1_name"),
  colClasses = "character",
  showProgress = TRUE
) %>%
  tibble::as_tibble() %>%
  mutate(
    cause_code_3d = na_if(toupper(trimws(cause_code_3d)), ""),
    cause_name = na_if(trimws(cause_name), ""),
    res_shp_adm1_name = na_if(trimws(res_shp_adm1_name), ""),
    death_weight = suppressWarnings(as.numeric(death_weight)),
    death_weight = if_else(is.na(death_weight), 1, death_weight)
  )


# -----------------------------
# Cause summaries
# -----------------------------

make_cause_summary <- function(x) {
  # If a code has more than one description, use the description appearing most
  # often in the selected records
  cause_names <- x %>%
    filter(!is.na(cause_code_3d), !is.na(cause_name)) %>%
    count(cause_code_3d, cause_name, name = "records") %>%
    arrange(cause_code_3d, desc(records), cause_name) %>%
    group_by(cause_code_3d) %>%
    slice_head(n = 1) %>%
    ungroup() %>%
    select(cause_code_3d, cause_name)

  x %>%
    filter(!is.na(cause_code_3d)) %>%
    group_by(cause_code_3d) %>%
    summarise(deaths = sum(death_weight, na.rm = TRUE), .groups = "drop") %>%
    left_join(cause_names, by = "cause_code_3d") %>%
    arrange(desc(deaths), cause_code_3d) %>%
    select(cause_code_3d, cause_name, deaths)
}

barmm_name <- "Bangsamoro Autonomous Region In Muslim Mindanao (BARMM)"

# Full-country summary
cause_summary <- make_cause_summary(mortality)

# Summary after dropping BARMM
cause_summary_no_barmm <- mortality %>%
  filter(is.na(res_shp_adm1_name) | res_shp_adm1_name != barmm_name) %>%
  make_cause_summary()


# -----------------------------
# Write outputs
# -----------------------------

data.table::fwrite(
  cause_summary,
  file.path(descriptive_tables_dir, "phl_cause_summary.csv")
)

data.table::fwrite(
  cause_summary_no_barmm,
  file.path(descriptive_tables_dir, "phl_cause_summary_no_barmm.csv")
)

cat("\nCause summaries written to:\n", descriptive_tables_dir, "\n")
