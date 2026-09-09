#========================================================================================#
#' Aggregate PHL death records to municipality x DATE x age (x cause group)
#'
#' RUN ON MIDWAY3. Produces the daily mortality panel needed to estimate a
#' distributed-lag response to daily rainfall, which is where the signal
#' should be: annual sums of daily polynomial terms average a shock that lasts
#' days over 365 days of exposure.
#'
#' Output is written as PARQUET and stored SPARSE (only municipality-date-age
#' cells with at least one death). Zero cells are recovered by joining onto the
#' climate panel, which is dense by construction -- storing ~30M mostly-zero
#' rows would be wasteful and slow to move.
#'
#' Two files are written:
#'   phl_deaths_daily.parquet        adm3 x date x age            (all causes)
#'   phl_deaths_daily_cause.parquet  adm3 x date x age x cause    (grouped)
#'
#' Run:
#'   sinteractive --account=cil --cpus-per-task=8 --mem=64G --time=02:00:00
#'   module load R
#'   Rscript 2_analysis/phl/cluster/02_aggregate_daily_deaths.R
#========================================================================================#

suppressPackageStartupMessages({
  library(data.table); library(arrow)
})
setDTthreads(as.integer(Sys.getenv("SLURM_CPUS_PER_TASK", unset = "4")))

phl_root <- Sys.getenv(
  "PHL_MORTALITY_DATA_ROOT",
  unset = "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/data/0_data_cleaning/1_raw/Countries/New_Countries/PHL"
)
rec_dir <- file.path(phl_root, "Mortality", "1_Clean", "Death_Records")

# Prefer the boundary-aligned file if present: the analysis panel is built on
# harmonised adm3 boundaries, so its codes are the ones that will merge.
cand <- c(file.path(rec_dir, "PHL_death_records_adm3_aligned.csv"),
          file.path(rec_dir, "PHL_death_records.csv"))
in_file <- cand[file.exists(cand)][1]
stopifnot(!is.na(in_file))
message("input: ", in_file)

out_dir <- Sys.getenv("PHL_DAILY_OUT", unset = dirname(
  sub("--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])))

# Inspect the header first: the aligned file may carry different column names
hdr <- names(fread(in_file, nrows = 0))
message("columns: ", paste(hdr, collapse = ", "))

pick <- function(...) { c <- c(...); c[c %in% hdr][1] }
col_date  <- pick("death_date", "date_of_death")
col_year  <- pick("date_of_death_year", "year")
col_month <- pick("date_of_death_month")
col_day   <- pick("date_of_death_day")
col_age   <- pick("age")
col_cause <- pick("cause_code_3d")
col_adm3  <- pick("res_psgc_adm3_code_aligned", "res_psgc_adm3_code",
                  "adm3_id", "res_shp_adm3_code")
stopifnot(!is.na(col_age), !is.na(col_adm3))
message("using adm3 column: ", col_adm3, " | date column: ",
        ifelse(is.na(col_date), "(rebuilt from y/m/d)", col_date))

keep <- unique(na.omit(c(col_date, col_year, col_month, col_day,
                         col_age, col_cause, col_adm3)))
d <- fread(in_file, select = keep, showProgress = TRUE)
message("rows read: ", format(nrow(d), big.mark = ","))

setnames(d, col_adm3, "adm3_id"); setnames(d, col_age, "age")
d[, adm3_id := formatC(as.numeric(adm3_id), width = 10, flag = "0", format = "d")]

# date: use the provided column, else rebuild from year/month/day
if (!is.na(col_date)) {
  d[, date := as.IDate(get(col_date))]
} else {
  d[, date := as.IDate(sprintf("%04d-%02d-%02d", get(col_year),
                               get(col_month), get(col_day)))]
}
bad <- d[is.na(date), .N]
message("unparseable dates dropped: ", format(bad, big.mark = ","),
        sprintf(" (%.3f%%)", 100 * bad / nrow(d)))
d <- d[!is.na(date)]

d[, agegroup := fcase(is.na(age), NA_integer_, age <= 4, 1L, age <= 64, 2L,
                      default = 3L)]
d <- d[!is.na(agegroup) & !is.na(adm3_id)]

# --- all-cause daily -------------------------------------------------------
daily <- d[, .(deaths = .N), by = .(adm3_id, date, agegroup)]
setorder(daily, adm3_id, date, agegroup)
write_parquet(daily, file.path(out_dir, "phl_deaths_daily.parquet"))
message("all-cause: ", format(nrow(daily), big.mark = ","), " non-zero cells, ",
        format(sum(daily$deaths), big.mark = ","), " deaths")

# --- daily by cause group --------------------------------------------------
if (!is.na(col_cause)) {
  setnames(d, col_cause, "cause_code_3d")
  d[, cause_code_3d := toupper(trimws(cause_code_3d))]
  L <- substr(d$cause_code_3d, 1, 1)
  N <- suppressWarnings(as.integer(substr(d$cause_code_3d, 2, 3)))
  d[, cause_group := fcase(
    is.na(cause_code_3d) | cause_code_3d == "", "Unknown",
    L == "A" & N <= 9,                     "Diarrhoeal (A00-A09)",
    L %chin% c("A", "B"),                  "Other infectious",
    L == "I",                              "Cardiovascular",
    L == "J",                              "Respiratory",
    L == "W" & N %between% c(65, 74),      "Drowning (W65-W74)",
    L == "X" & N %between% c(30, 39),      "Forces of nature (X30-X39)",
    L %chin% c("V", "W", "X", "Y"),        "Other external",
    default = "All other")]
  dc <- d[, .(deaths = .N), by = .(adm3_id, date, agegroup, cause_group)]
  setorder(dc, adm3_id, date, agegroup, cause_group)
  write_parquet(dc, file.path(out_dir, "phl_deaths_daily_cause.parquet"))
  message("by cause: ", format(nrow(dc), big.mark = ","), " non-zero cells")
  print(dc[, .(deaths = sum(deaths)), by = cause_group][order(-deaths)])
}

message("\nwrote to ", out_dir)
message("NOTE: cells are SPARSE (non-zero only). Join onto the dense daily ",
        "climate panel and set missing deaths to 0 before estimating.")
