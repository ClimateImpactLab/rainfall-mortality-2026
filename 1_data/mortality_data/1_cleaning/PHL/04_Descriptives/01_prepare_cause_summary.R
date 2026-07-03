# ============================================================
# 01_prepare_cause_summary.R
#
# Count deaths by three-digit ICD-10 cause across 2006–2024.
#
# Input:
#   Mortality/1_Clean/Death_Records/PHL_death_records.csv
#
# Output:
#   Mortality/1_Clean/Descriptive_Tables/phl_cause_summary.csv
# ============================================================

library(dplyr)

user_name <- Sys.getenv("USER", unset = Sys.info()[["user"]])
repo_dir <- Sys.getenv("RAINFALL_MORTALITY_REPO")
if (repo_dir == "") repo_dir <- file.path("/project/cil/home_dirs", user_name, "repos/rainfall-mortality-2026")
source(file.path(repo_dir, "1_data/mortality_data/1_cleaning/PHL/paths.R"))

mortality_file <- file.path(
  death_records_dir,
  "PHL_death_records.csv"
)

if (!file.exists(mortality_file)) {
  stop("Missing mortality file:\n", mortality_file)
}

dir.create(descriptive_tables_dir, recursive = TRUE, showWarnings = FALSE)
data.table::setDTthreads(4)

mortality <- data.table::fread(
  mortality_file,
  select = c("cause_code_3d", "cause_name"),
  colClasses = "character",
  showProgress = TRUE
) %>%
  tibble::as_tibble() %>%
  mutate(
    cause_code_3d = na_if(toupper(trimws(cause_code_3d)), ""),
    cause_name = na_if(trimws(cause_name), "")
  )

# If a code has more than one description, use the description appearing most
# often in the cleaned records.
cause_names <- mortality %>%
  filter(!is.na(cause_code_3d), !is.na(cause_name)) %>%
  count(cause_code_3d, cause_name, name = "records") %>%
  arrange(cause_code_3d, desc(records), cause_name) %>%
  group_by(cause_code_3d) %>%
  slice_head(n = 1) %>%
  ungroup() %>%
  select(cause_code_3d, cause_name)

cause_summary <- mortality %>%
  filter(!is.na(cause_code_3d)) %>%
  count(cause_code_3d, name = "deaths") %>%
  left_join(cause_names, by = "cause_code_3d") %>%
  arrange(desc(deaths), cause_code_3d) %>%
  select(cause_code_3d, cause_name, deaths)

data.table::fwrite(
  cause_summary,
  file.path(descriptive_tables_dir, "phl_cause_summary.csv")
)

cat("\nCause summary written to:\n", descriptive_tables_dir, "\n")
