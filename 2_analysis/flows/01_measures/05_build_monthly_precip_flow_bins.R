# ============================================================
# Monthly precip and flow bin counts for the precip vs flow comparison regs
#
# Number of each county's months in each bin per year (0-12), pop-weighted,
# bins [c_(j-1), c_j) with open end bins.
#
# Edges picked from 04_explore_precip_flow_bins.log:
#   precip, prcp_pop_p1 (mm):  <50 | 50-100 (ref) | 100-150 | 150-200 | >=200
#     = prcp_w50 in the log.
#   flow, flow_pop (mm summed over upstream cells):
#     <100 | 100-1k (ref) | 1k-10k | 10k-100k | >=100k
#     = flow_decade, the current flow bins.
# Ref bin = the one with the pooled median month (74.5 mm precip, 656 mm flow).
#
# 1968-2010 only: the regs use the death year only. Lags would need the
# earlier years.
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
out_file <- file.path(out_dir, "era5land_admin_precip_flow_bins_usa.rds")

write_output <- "--write" %in% commandArgs(trailingOnly = TRUE)


# Settings ---------------------------

first_year <- 1968 # reg years, as in 02_usa_flow_regs.R
last_year  <- 2010

bins <- list(
  prcp = list(edges = c(50, 100, 150, 200),
              names = c("lt50", "50_100", "100_150", "150_200", "ge200"),
              ref   = "50_100",
              col   = "prcpmon_bin_"),
  flow = list(edges = c(100, 1000, 10000, 100000),
              names = c("lt100", "100_1k", "1k_10k", "10k_100k", "ge100k"),
              ref   = "100_1k",
              col   = "flowmon_bin_")
)
walk(bins, ~ stopifnot(length(.x$names) == length(.x$edges) + 1, .x$ref %in% .x$names))

bin_vars <- unlist(map(bins, ~ paste0(.x$col, .x$names, "_pop")), use.names = FALSE)


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
    pivot_wider(names_from = bin, values_from = n, names_prefix = b$col) %>%
    rename_with(~ paste0(.x, "_pop"), starts_with(b$col)) %>%
    right_join(complete_cy, by = c("admin_id", "year")) %>%
    mutate(across(starts_with(b$col), ~ if_else(complete, .x, NA_integer_))) %>%
    select(-complete)
}


# 1. Load monthly precip and flow ---------------------------

print("==== reading monthly flow and precip ====")
flow_m <- read_monthly(flow_dir, "^era5land_usa_adm2_flow_monthly_[0-9]{4}\\.csv$", "flow_pop", first_year, last_year)
prcp_m <- read_monthly(prcp_dir, "^era5land_usa_adm2_monthly_[0-9]{4}\\.csv$", "prcp_pop_p1", first_year, last_year)

monthly <- full_join(flow_m, prcp_m, by = c("admin_id", "year", "month")) %>%
  rename(flow = flow_pop, prcp = prcp_pop_p1)
rm(flow_m, prcp_m)

# reg county-years (for the checks below)
reg_cy <- readRDS(panel_file) %>%
  filter(year >= first_year, year <= last_year, !is.na(flowmean_pop_annual)) %>%
  distinct(admin_id, year)

# every county-year should have 12 rows (values can still be NA)
stopifnot(all(count(monthly, admin_id, year)$n == 12))


# 2. Count months per bin ---------------------------

counts <- count_bins(monthly, "prcp", bins$prcp) %>%
  full_join(count_bins(monthly, "flow", bins$flow), by = c("admin_id", "year")) %>%
  select(admin_id, year, all_of(bin_vars)) %>%
  arrange(admin_id, year)

stopifnot(!anyDuplicated(counts[c("admin_id", "year")]))

# each variable's counts are all there or all NA, and sum to 12
for (b in bins) {
  m  <- as.matrix(counts[paste0(b$col, b$names, "_pop")])
  ok <- complete.cases(m)
  stopifnot(all(is.na(m[!ok, , drop = FALSE])), all(rowSums(m[ok, , drop = FALSE]) == 12))
}


# 3. Checks ---------------------------

# reg county-years: all have every set of counts (reg_cy is built in section 1)
reg_counts <- semi_join(counts, reg_cy, by = c("admin_id", "year"))
stopifnot(nrow(reg_counts) == nrow(reg_cy), !anyNA(reg_counts[bin_vars]))

message(glue("reg county-years: {nrow(reg_counts)} | {n_distinct(reg_counts$admin_id)} counties | {first_year}-{last_year}"))

# share of months, counties with any month and counties whose count varies,
# per bin. should match the prcp_w50 and flow_decade rows of
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


# 4. Save ---------------------------

if (write_output) {
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  saveRDS(counts, out_file)
  message("wrote: ", out_file)
}
