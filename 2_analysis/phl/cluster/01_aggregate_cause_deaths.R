#========================================================================================#
#' Aggregate PHL individual death records to adm3 x year x age x cause-group
#'
#' RUN ON MIDWAY3 (the input is 2.8GB of individual-level records that should
#' not leave the cluster). Produces a small (~few MB) aggregate that contains
#' no individual records and merges onto the analysis panel by
#' (adm3_id, year, agegroup).
#'
#' Input : Mortality/1_Clean/Death_Records/PHL_death_records.csv
#'         (schema from 1_data/mortality_data/1_cleaning/PHL/03_Mortality/
#'          01_clean_mortality_records.R: one row per death, with
#'          date_of_death_year, age, cause_code_3d, res_psgc_adm3_code)
#' Output: phl_deaths_by_cause_adm3.csv in this script's directory (or
#'         $PHL_CAUSE_OUT if set)
#'
#' Usage (interactive):
#'   sinteractive --account=cil --cpus-per-task=4 --mem=32G --time=01:00:00
#'   module load R
#'   Rscript 01_aggregate_cause_deaths.R
#========================================================================================#

suppressPackageStartupMessages({
  library(data.table)
  library(dplyr)
  library(stringr)
})
setDTthreads(as.integer(Sys.getenv("SLURM_CPUS_PER_TASK", unset = "2")))

phl_root <- Sys.getenv(
  "PHL_MORTALITY_DATA_ROOT",
  unset = "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/data/0_data_cleaning/1_raw/Countries/New_Countries/PHL"
)
in_file  <- file.path(phl_root, "Mortality", "1_Clean", "Death_Records",
                      "PHL_death_records.csv")
out_file <- Sys.getenv("PHL_CAUSE_OUT",
                       unset = file.path(dirname(sub("--file=", "",
                         grep("^--file=", commandArgs(FALSE), value = TRUE)[1])),
                         "phl_deaths_by_cause_adm3.csv"))
stopifnot(file.exists(in_file))

# read only what the aggregation needs (4 of ~27 columns)
d <- fread(in_file,
           select = c("date_of_death_year", "age", "cause_code_3d",
                      "res_psgc_adm3_code"),
           colClasses = list(character = c("cause_code_3d", "res_psgc_adm3_code")),
           showProgress = TRUE)
message("rows read: ", nrow(d))

d[, cause_code_3d := toupper(trimws(cause_code_3d))]

# ICD-10 groups chosen for rainfall mechanisms. X38 (flood) and W65-W74
# (drowning) are the sharpest signals; diarrhoeal disease is the waterborne
# channel; cardiovascular is the "should not respond much" comparison group.
icd_letter <- substr(d$cause_code_3d, 1, 1)
icd_num    <- suppressWarnings(as.integer(substr(d$cause_code_3d, 2, 3)))

d[, cause_group := fcase(
  is.na(cause_code_3d) | cause_code_3d == "", "Unknown/missing",
  icd_letter == "A" & icd_num <= 9,           "Diarrhoeal (A00-A09)",
  icd_letter %chin% c("A", "B"),              "Other infectious (A10-B99)",
  icd_letter == "I",                          "Cardiovascular (I)",
  icd_letter == "J",                          "Respiratory (J)",
  icd_letter == "W" & icd_num %between% c(65, 74), "Drowning (W65-W74)",
  icd_letter == "X" & icd_num %between% c(30, 39), "Forces of nature (X30-X39)",
  icd_letter %chin% c("V", "W", "X", "Y"),    "Other external (V-Y)",
  default = "All other causes"
)]

# age groups matching the analysis panel: 1 = 0-4, 2 = 5-64, 3 = 65+
d[, agegroup := fcase(
  is.na(age),  NA_integer_,
  age <= 4,    1L,
  age <= 64,   2L,
  default =    3L
)]

agg <- d[, .(deaths = .N),
         by = .(adm3_id = res_psgc_adm3_code,
                year    = date_of_death_year,
                agegroup, cause_group)]
setorder(agg, adm3_id, year, agegroup, cause_group)

fwrite(agg, out_file)
message("wrote ", nrow(agg), " rows (", sum(agg$deaths), " deaths) -> ", out_file)
message("\ncause-group totals:")
print(agg[, .(deaths = sum(deaths)), by = cause_group][order(-deaths)])
