# ============================================================
# Monthly precip and flow bin counts for the precip vs flow comparison regs
#
# Number of each county's months in each bin per year (0-12), pop-weighted,
# bins [c_(j-1), c_j) with open end bins. The bin definition is an argument:
#
#   Rscript 05_build_monthly_precip_flow_bins.R [--scheme=levels|percentile]
#           [--prcp_edges=50,100,150,200] [--flow_edges=100,1000,10000,100000]
#           [--prcp_ref=50_100] [--flow_ref=100_1k]
#           [--probs=0.1,0.25,0.75,0.9] [--write]
#
#   --scheme=levels (default): fixed edges in mm, the same for every county.
#     Defaults are the edges picked from 04_explore_precip_flow_bins.log:
#       precip, prcp_pop_p1 (mm):  <50 | 50-100 (ref) | 100-150 | 150-200 | >=200
#         = prcp_w50 in the log.
#       flow, flow_pop (mm summed over upstream cells):
#         <100 | 100-1k (ref) | 1k-10k | 10k-100k | >=100k
#         = flow_decade, the current flow bins.
#     Ref bin = the one with the pooled median month (74.5 mm precip, 656 mm flow).
#     With the default edges the output is the file and the column names every
#     reg script already reads. With other edges, give the ref bin too.
#   --scheme=percentile: county-relative bins. Each month's percentile is measured
#     against the same county's monthly values over the baseline years (all
#     calendar months pooled, so seasonality stays in): the previous 20 years for
#     t >= 1970, the fixed years 1950-1969 for t <= 1969 (which include the year
#     itself, as in the SPI). The percentile is the mid-rank, (months below +
#     half the months tied) / number of baseline months, so ties, such as the
#     months with zero flow, bin correctly. The bins are cut at --probs, ref =
#     the bin with the median.
#     Why: fixed edges for flow mostly pick up how big a county's river is (flow
#     is summed over upstream cells), so with county FE a flow bin is identified
#     only by the counties that sit near its edge. County percentiles give every
#     county the same bins. The number of bins is the length of --probs + 1.
#
# Every scheme writes its own file, so no scheme overwrites another. The default scheme keeps the old name.
#
# 1968-2010 only for the counts: the regs use the death year only. Lags would need
# the earlier years. The percentile scheme reads 1950 on, for its baselines.
#
# Inputs:  monthly flow and precip csvs; the annual regression panel (checks only)
# Outputs: with --write, annual_from_monthly_precip_flow_bins/<file>.rds
# Dependencies: dplyr, tidyr, readr, purrr, glue; 00_read_monthly.R
# ============================================================

library(dplyr)
library(tidyr)
library(readr)
library(purrr)
library(glue)

# set paths
USER <- Sys.getenv("USER")
source("../../../0_utils/paths.R") # DATA_DIR

flow_dir      <- file.path(DATA_DIR, "climate_data/ERA5-LAND-GLOBAL/USA/hydro/monthly")
prcp_dir      <- file.path(DATA_DIR, "climate_data/ERA5-LAND-GLOBAL/USA/monthly")
panel_file    <- file.path(DATA_DIR, "climate_data/ERA5-LAND/flows/usa_annual/usa_annual_flow_regression_panel.rds")

out_dir  <- file.path(DATA_DIR, "climate_data/ERA5-LAND/flows/annual_from_monthly_precip_flow_bins")


# Arguments and settings ---------------------------

args    <- commandArgs(trailingOnly = TRUE)
get_arg <- function(name, default) {
  hit <- grep(paste0("^--", name, "="), args, value = TRUE)
  if (length(hit) == 0) default else sub(paste0("^--", name, "="), "", hit[[1]])
}
num_arg <- function(name, default) as.numeric(strsplit(get_arg(name, default), ",")[[1]])

write_output <- "--write" %in% args
scheme       <- get_arg("scheme", "levels")
stopifnot(scheme %in% c("levels", "percentile"))

first_year <- 1968 # reg years, as in 02_usa_flow_regs.R
last_year  <- 2010
data_start <- 1950 # first year of the monthly files, needed for the percentile baselines

ROLLING_BASELINE_YEARS <- 20 # the SPI baseline (06_build_monthly_spi_measures.R)
EARLY_BASELINE_START   <- 1950
EARLY_BASELINE_END     <- 1969
stopifnot(EARLY_BASELINE_END - EARLY_BASELINE_START + 1 == ROLLING_BASELINE_YEARS)

# an edge as it appears in a bin name: 1000 -> 1k, 100000 -> 100k
edge_name <- function(e) if (e >= 1000 && e %% 1000 == 0) paste0(e / 1000, "k") else as.character(e)

#' One variable's bins: names, edges, ref and the column prefix. `cuts` are mm edges (levels)
#' or probabilities (percentile)
make_bins <- function(cuts, ref = NULL) {
  stopifnot(!is.unsorted(cuts, strictly = TRUE))
  k <- length(cuts)
  if (scheme == "levels") {
    nm <- c(paste0("lt", edge_name(cuts[1])),
            if (k > 1) paste0(sapply(seq_len(k - 1), function(i) edge_name(cuts[i])), "_", sapply(2:k, function(i) edge_name(cuts[i]))),
            paste0("ge", edge_name(cuts[k])))
    col <- "mon_bin_"
  } else {
    stopifnot(all(cuts > 0 & cuts < 1), all(abs(100 * cuts - round(100 * cuts)) < 1e-9)) # whole percents, for the names
    pc  <- round(100 * c(0, cuts, 1))
    nm  <- paste0("p", sprintf("%02d", pc[-length(pc)]), "_", pc[-1])
    col <- "pct_bin_"
    ref <- nm[findInterval(0.5, cuts) + 1] # the bin with the median
  }
  stopifnot(length(nm) == k + 1, ref %in% nm)
  list(edges = cuts, names = nm, ref = ref, col = col)
}

if (scheme == "levels") {
  prcp_edges <- num_arg("prcp_edges", "50,100,150,200")
  flow_edges <- num_arg("flow_edges", "100,1000,10000,100000")
  default_levels <- identical(prcp_edges, c(50, 100, 150, 200)) && identical(flow_edges, c(100, 1000, 10000, 100000))
  bins <- list(prcp = c(make_bins(prcp_edges, get_arg("prcp_ref", "50_100")), list(var = "prcp_pop_p1")),
               flow = c(make_bins(flow_edges, get_arg("flow_ref", "100_1k")),  list(var = "flow_pop")))
  tag  <- if (default_levels) "" else paste0("_levels_", paste(prcp_edges, collapse = "-"), "_", paste(flow_edges, collapse = "-"))
} else {
  probs <- num_arg("probs", "0.1,0.25,0.75,0.9")
  bins  <- list(prcp = c(make_bins(probs), list(var = "prcp_pop_p1")),
                flow = c(make_bins(probs), list(var = "flow_pop")))
  tag   <- paste0("_pct_roll", ROLLING_BASELINE_YEARS, "_p", paste(round(100 * probs), collapse = "_"))
}
out_file     <- file.path(out_dir, paste0("era5land_admin_precip_flow_bins_usa", tag, ".rds"))

# the bins (in memory only; the reg and doc scripts hard-code the percentile bins)
bin_definition <- bind_rows(imap(bins, function(b, v) {
  tibble(variable = v, scheme = scheme, bin = b$names, lower = c(-Inf, b$edges), upper = c(b$edges, Inf),
         reference = b$names == b$ref, column = paste0(v, b$col, b$names, "_pop"))
}))

bin_vars <- bin_definition$column


# Functions ---------------------------

source("00_read_monthly.R") # read_monthly()

#' Months per bin per county-year for one variable, wide (one column per bin).
#' NA for county-years without all 12 months, same rule as 03
count_bins <- function(df, var, b) {
  complete_cy <- df %>%
    group_by(admin_id, year) %>%
    summarise(complete = sum(!is.na(.data[[var]])) == 12, .groups = "drop")

  df %>%
    filter(!is.na(.data[[var]])) %>%
    # findInterval() puts a value on an edge in the bin above, so [c_(j-1), c_j)
    mutate(bin = b$names[findInterval(.data[[var]], b$edges) + 1]) %>%
    count(admin_id, year, bin) %>%
    complete(nesting(admin_id, year), bin = b$names, fill = list(n = 0L)) %>%
    pivot_wider(names_from = bin, values_from = n, names_prefix = paste0(var, b$col)) %>%
    rename_with(~ paste0(.x, "_pop"), starts_with(paste0(var, b$col))) %>%
    right_join(complete_cy, by = c("admin_id", "year")) %>%
    mutate(across(starts_with(paste0(var, b$col)), ~ if_else(complete, .x, NA_integer_))) %>%
    select(-complete)
}

#' Mid-rank percentile of every county-month among the same county's monthly values over the
#' baseline years (all calendar months pooled), one target year at a time. NA unless the
#' whole baseline and the month are present. long: admin_id, year, month ("YYYY-MM"), value.
#' Returns admin_id, year, month, pct for first_year-last_year
county_percentile <- function(long) {
  wide <- long %>%
    mutate(cal_month = substr(month, 6, 7)) %>%
    select(admin_id, cal_month, year, value) %>%
    pivot_wider(names_from = year, values_from = value) %>%
    arrange(admin_id, cal_month)
  stopifnot(!anyNA(wide$admin_id), ncol(wide) == 2 + (last_year - data_start + 1), all(table(wide$admin_id) == 12))
  mat <- as.matrix(wide[, as.character(data_start:last_year)])

  years_out <- first_year:last_year
  pct <- matrix(NA_real_, nrow(mat), length(years_out), dimnames = list(NULL, years_out))
  for (rows in split(seq_len(nrow(mat)), wide$admin_id)) { # the county's 12 calendar months
    M <- mat[rows, , drop = FALSE]
    for (t in years_out) {
      base_years <- if (t <= EARLY_BASELINE_END) EARLY_BASELINE_START:EARLY_BASELINE_END else (t - ROLLING_BASELINE_YEARS):(t - 1)
      base <- as.vector(M[, as.character(base_years)]) # 12 x 20 baseline months
      if (anyNA(base)) next
      s <- sort(base)
      x <- M[, as.character(t)]
      # (months below + months at or below) / 2n = (below + half the tied) / n
      pct[rows, as.character(t)] <- (findInterval(x, s, left.open = TRUE) + findInterval(x, s)) / (2 * length(s))
    }
  }
  as_tibble(pct) %>%
    bind_cols(select(wide, admin_id, cal_month)) %>%
    pivot_longer(-c(admin_id, cal_month), names_to = "year", values_to = "pct") %>%
    mutate(year = as.integer(year), month = paste0(year, "-", cal_month)) %>%
    select(admin_id, year, month, pct)
}


# 1. Load monthly precip and flow ---------------------------

print("==== reading monthly flow and precip ====")
read_from <- if (scheme == "percentile") data_start else first_year
flow_m <- read_monthly(flow_dir, "^era5land_usa_adm2_flow_monthly_[0-9]{4}\\.csv$", "flow_pop", read_from, last_year)
prcp_m <- read_monthly(prcp_dir, "^era5land_usa_adm2_monthly_[0-9]{4}\\.csv$", "prcp_pop_p1", read_from, last_year)

# reg county-years (for the checks below)
reg_cy <- readRDS(panel_file) %>%
  filter(year >= first_year, year <= last_year, !is.na(flowmean_pop_annual)) %>%
  distinct(admin_id, year)

# the value each bin is cut on: the monthly value (levels) or its county percentile (percentile)
if (scheme == "levels") {
  monthly <- full_join(flow_m, prcp_m, by = c("admin_id", "year", "month")) %>%
    rename(flow = flow_pop, prcp = prcp_pop_p1)
} else {
  print("==== county percentiles against the rolling baseline ====")
  monthly <- full_join(
    county_percentile(rename(flow_m, value = flow_pop)) %>% rename(flow = pct),
    county_percentile(rename(prcp_m, value = prcp_pop_p1)) %>% rename(prcp = pct),
    by = c("admin_id", "year", "month"))
}
rm(flow_m, prcp_m)

# every county-year should have 12 rows (values can still be NA)
stopifnot(all(count(monthly, admin_id, year)$n == 12), min(monthly$year) == first_year)


# 2. Count months per bin ---------------------------

# columns are <variable><col><bin>_pop, e.g. prcpmon_bin_lt50_pop
counts <- count_bins(monthly, "prcp", bins$prcp) %>%
  full_join(count_bins(monthly, "flow", bins$flow), by = c("admin_id", "year")) %>%
  select(admin_id, year, all_of(bin_vars)) %>%
  arrange(admin_id, year)

stopifnot(!anyDuplicated(counts[c("admin_id", "year")]))

# each variable's counts are all there or all NA, and sum to 12
for (v in names(bins)) {
  m  <- as.matrix(counts[bin_definition$column[bin_definition$variable == v]])
  ok <- complete.cases(m)
  stopifnot(all(is.na(m[!ok, , drop = FALSE])), all(rowSums(m[ok, , drop = FALSE]) == 12))
}


# 3. Checks ---------------------------

# reg county-years: all have every set of counts (reg_cy is built in section 1)
reg_counts <- semi_join(counts, reg_cy, by = c("admin_id", "year"))
stopifnot(nrow(reg_counts) == nrow(reg_cy), !anyNA(reg_counts[bin_vars]))

message(glue("scheme: {scheme} | reg county-years: {nrow(reg_counts)} | {n_distinct(reg_counts$admin_id)} counties | {first_year}-{last_year}"))

# share of months, counties with any month and counties whose count varies,
# per bin. for the default levels, should match the prcp_w50 and flow_decade rows of
# 04_explore_precip_flow_bins.log
reg_counts %>%
  pivot_longer(all_of(bin_vars), names_to = "bin", values_to = "months") %>%
  group_by(bin, admin_id) %>%
  summarise(varies = n_distinct(months) > 1, total = sum(months), years = n(), .groups = "drop") %>%
  group_by(bin) %>%
  summarise(share_of_months  = sum(total) / (12 * sum(years)),
            counties_any     = sum(total > 0),
            counties_varying = sum(varies)) %>%
  arrange(match(bin, bin_vars)) %>%
  print(n = Inf, width = Inf)

if (scheme == "percentile") {
  # by construction each bin holds about the width of its percentile range
  message("nominal share of months per bin: ", paste(bins$prcp$names, round(diff(c(0, bins$prcp$edges, 1)), 3), collapse = " | "))
}


# 4. Save ---------------------------

if (write_output) {
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  saveRDS(counts, out_file)
  message("wrote: ", out_file)
}
