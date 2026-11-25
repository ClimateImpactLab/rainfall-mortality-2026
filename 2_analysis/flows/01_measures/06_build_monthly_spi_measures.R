# ============================================================
# Monthly SPI-1 aggregated to the county-year, and the annual SPI-12
#
# Purpose: build the annual terms from the monthly values, sum_m g(X_m), not
# g(annual X). If mortality responds nonlinearly to each month,
# f(sum_m X_m) != sum_m f(X_m), so the annual SPI loses it. The annual SPI-12 is
# built too, as the annual counterpart.
#
# The monthly z-score is built too, squared and summed to the year. Monthly rain
# and flow are skewed and bounded at zero, so z gives very large values in
# dry-season months (a few mm of baseline rain, then an ordinary wet month). Both
# an uncapped and a capped version (z capped at the SPI bound) are built.
#
# For flow (flow_pop) and precip (prcp_pop_p1), pop-weighted:
#   1. SPI-1 of each county-month against that county's same calendar
#      month in the baseline years (rolling prior 20 years, as in
#      01_build_flow_measures.R; 1968-1969 use the fixed 1950-1969 baseline,
#      which includes the year itself, so those two years are in-sample).
#      SPI = mixed gamma (method of moments on the positive baseline values,
#      zero share as a point mass), capped at p = 1e-4 / 1 - 1e-4, as in the
#      annual script and the Brazil SPI script.
#   2. Annual terms per county-year from the SPI-1 (NA unless all 12 months have an SPI):
#      - months per SPI bin (0-12, sum to 12), wet positive
#      - weighted dry sum: 12 x sum over the 12 months of s_m max(0, -SPI-1), with s_m
#        the month's usual share of the year's rain (flow), so a month counts by how
#        much it usually brings (Marine's weighted dry sum). The weighted wet sum is the
#        same with max(0, SPI-1): the wet side is our extension, Marine's is dry only.
#        The shares are the baseline mean of the month over the sum of the 12 baseline
#        means (floored at 0), from the same baseline as the SPI, so they add to 1
#   3. SPI-12 of the calendar-year total, two-sided: dry side max(0, -SPI-12) and wet
#      side max(0, SPI-12). Same method and baseline as the SPI-1, with the annual totals
#      of the baseline years (20 values per fit)
#   4. Squared z-score sums of the SPI-1 months, dry and wet (NA unless all 12 months have a z):
#      z of a county-month = (value - baseline mean) / baseline sd, with the same baseline as
#      the SPI. Z2dry = sum over months of min(z, 0)^2, Z2wet = sum of max(z, 0)^2. The
#      capped version does the same with z capped at +/- the SPI bound (about 3.72)
#
# Inputs:  monthly flow and precip csvs, 1950-2010 (baseline needs 1950 on);
#          the annual regression panel (only for the reg county-year checks)
# Outputs: with --write, annual_from_monthly_spi/era5land_admin_monthly_spi_usa.rds
#          (separate folder: no final panel is touched)
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

flow_dir   <- file.path(DATA_DIR, "climate_data/ERA5-LAND-GLOBAL/USA/hydro/monthly")
prcp_dir   <- file.path(DATA_DIR, "climate_data/ERA5-LAND-GLOBAL/USA/monthly")
panel_file <- file.path(DATA_DIR, "climate_data/ERA5-LAND/flows/usa_annual/usa_annual_flow_regression_panel.rds")

out_dir  <- file.path(DATA_DIR, "climate_data/ERA5-LAND/flows/annual_from_monthly_spi")
out_file <- file.path(out_dir, "era5land_admin_monthly_spi_usa.rds")

write_output <- "--write" %in% commandArgs(trailingOnly = TRUE)


# Settings ---------------------------

first_year <- 1968 # reg years, as in 02_usa_flow_regs.R
last_year  <- 2010
data_start <- 1950 # first year of the monthly files, needed for the baselines

ROLLING_BASELINE_YEARS <- 20 # same as 01_build_flow_measures.R
EARLY_BASELINE_START   <- 1950
EARLY_BASELINE_END     <- 1969
stopifnot(EARLY_BASELINE_END - EARLY_BASELINE_START + 1 == ROLLING_BASELINE_YEARS)

SPI_P_MIN <- 1e-4 # caps SPI at about +/-3.7, as in the annual script
Z_CAP <- qnorm(1 - SPI_P_MIN) # the capped z-score uses the same bound as the SPI

# SPI bins, [c_(j-1), c_j) with open end bins (findInterval convention of
# 05_build_monthly_precip_flow_bins.R). Mutually exclusive, so the counts sum
# to 12 and the ref bin is left out of the regressions. Cutoffs: 1 / 1.5 / 2
# are the usual moderate / severe / extreme SPI classes.
spi_edges <- c(-2, -1.5, -1, 1, 1.5, 2)
spi_names <- c("lt_m2", "m2_m1p5", "m1p5_m1", "m1_p1", "p1_p1p5", "p1p5_p2", "ge_p2")
spi_ref   <- "m1_p1"
stopifnot(length(spi_names) == length(spi_edges) + 1, spi_ref %in% spi_names)

vars <- list(prcp = list(dir = prcp_dir, pattern = "^era5land_usa_adm2_monthly_[0-9]{4}\\.csv$",
                         col = "prcp_pop_p1"),
             flow = list(dir = flow_dir, pattern = "^era5land_usa_adm2_flow_monthly_[0-9]{4}\\.csv$",
                         col = "flow_pop"))


# Functions ---------------------------

source("00_read_monthly.R") # read_monthly()

#' SPI-1 for every county-month of one variable, one target year at a time.
#' mat: rows = county-months (one calendar month of one county), columns = years
#' data_start..last_year. Vectorised over rows: for target year t, the baseline
#' is the same row's values in the baseline columns (see header).
#' A row-year is NA unless all 20 baseline values are present (same rule as
#' rolling_prior_spi() in 01_build_flow_measures.R), and also if the SPI gamma
#' cannot be fit (fewer than 2 positive baseline values, or zero variance of them).
spi_matrix <- function(mat, years_out) {
  spi <- matrix(NA_real_, nrow(mat), length(years_out), dimnames = list(NULL, years_out))

  for (t in years_out) {
    base_years <- if (t <= EARLY_BASELINE_END) EARLY_BASELINE_START:EARLY_BASELINE_END
                  else (t - ROLLING_BASELINE_YEARS):(t - 1)
    stopifnot(length(base_years) == ROLLING_BASELINE_YEARS, min(base_years) >= data_start)
    B <- mat[, as.character(base_years), drop = FALSE]
    x <- mat[, as.character(t)]
    ok <- !is.na(x) & rowSums(is.na(B)) == 0

    # gamma on the positive baseline values, zeros as a point mass
    Bp       <- B; Bp[Bp <= 0] <- NA
    pos_n    <- rowSums(!is.na(Bp))
    pos_mean <- rowMeans(Bp, na.rm = TRUE)
    pos_var  <- rowSums((Bp - pos_mean)^2, na.rm = TRUE) / (pos_n - 1)
    spi_ok   <- ok & pos_n >= 2 & pos_var > 0
    shape <- pos_mean[spi_ok]^2 / pos_var[spi_ok]
    rate  <- pos_mean[spi_ok] / pos_var[spi_ok]
    zero_share <- rowMeans(B[spi_ok, , drop = FALSE] <= 0)
    xs <- x[spi_ok]
    p <- ifelse(xs <= 0, zero_share, zero_share + (1 - zero_share) * pgamma(xs, shape = shape, rate = rate))
    spi[spi_ok, as.character(t)] <- qnorm(pmin(pmax(p, SPI_P_MIN), 1 - SPI_P_MIN))
  }
  spi
}

#' z-score of every county-month against its baseline, one target year at a time:
#' (value - baseline mean) / baseline sd, with the same baseline as spi_matrix(). NA unless
#' all 20 baseline values and the month are present, and if the baseline sd is 0
z_matrix <- function(mat, years_out) {
  z <- matrix(NA_real_, nrow(mat), length(years_out), dimnames = list(NULL, years_out))
  for (t in years_out) {
    base_years <- if (t <= EARLY_BASELINE_END) EARLY_BASELINE_START:EARLY_BASELINE_END
                  else (t - ROLLING_BASELINE_YEARS):(t - 1)
    stopifnot(length(base_years) == ROLLING_BASELINE_YEARS, min(base_years) >= data_start)
    B <- mat[, as.character(base_years), drop = FALSE]
    x <- mat[, as.character(t)]
    b_mean <- rowMeans(B)
    b_sd   <- sqrt(rowSums((B - b_mean)^2) / (ROLLING_BASELINE_YEARS - 1))
    ok     <- !is.na(x) & rowSums(is.na(B)) == 0 & b_sd > 0
    z[ok, as.character(t)] <- (x[ok] - b_mean[ok]) / b_sd[ok]
  }
  z
}

#' Usual share of the year's rain (flow) that each calendar month brings, one target year
#' at a time: the month's baseline mean over the sum of the county's 12 baseline means
#' (floored at 0, as flow can be negative), so the 12 shares add to 1. Same baseline as
#' spi_matrix(). NA unless the whole baseline is present, and if the annual baseline mean is not positive.
#' mat rows are sorted by county then calendar month, county_of_row gives each row's county
share_matrix <- function(mat, years_out, county_of_row) {
  share <- matrix(NA_real_, nrow(mat), length(years_out), dimnames = list(NULL, years_out))
  for (t in years_out) {
    base_years <- if (t <= EARLY_BASELINE_END) EARLY_BASELINE_START:EARLY_BASELINE_END
                  else (t - ROLLING_BASELINE_YEARS):(t - 1)
    bm  <- pmax(rowMeans(mat[, as.character(base_years), drop = FALSE]), 0) # NA unless all baseline values are present
    tot <- ave(bm, county_of_row, FUN = sum)
    share[, as.character(t)] <- ifelse(tot > 0, bm / tot, NA_real_)
  }
  share
}

#' Matrix -> long (admin_id, year, month, value)
mat_to_long <- function(mat, keys, name) {
  as_tibble(mat) %>%
    bind_cols(keys) %>%
    pivot_longer(-c(admin_id, month), names_to = "year", values_to = name) %>%
    mutate(year = as.integer(year))
}

#' Annual terms of one variable from its monthly SPI and shares (long, 12 rows per
#' county-year) and its annual SPI-12 (long, one row per county-year). prefix is "prcp" or "flow".
annual_terms <- function(long, spi12, prefix) {
  bin_cols <- paste0(prefix, "spi_bin_", spi_names, "_pop")

  complete_cy <- long %>%
    group_by(admin_id, year) %>%
    summarise(spi_complete = sum(!is.na(spi)) == 12, .groups = "drop")

  bins <- long %>%
    filter(!is.na(spi)) %>%
    mutate(bin = spi_names[findInterval(spi, spi_edges) + 1]) %>%
    count(admin_id, year, bin) %>%
    complete(nesting(admin_id, year), bin = spi_names, fill = list(n = 0L)) %>%
    pivot_wider(names_from = bin, values_from = n) %>%
    rename_with(~ paste0(prefix, "spi_bin_", .x, "_pop"), all_of(spi_names))

  # weighted dry and wet sums: 12 x sum of share x depth of the dry (wet) months. NA unless all 12 months have an SPI and a share
  wdry <- long %>%
    group_by(admin_id, year) %>%
    summarise(complete = sum(!is.na(spi) & !is.na(share)) == 12,
              share_sum = sum(share),
              wdry = 12 * sum(share * pmax(0, -spi)),
              wwet = 12 * sum(share * pmax(0, spi)), .groups = "drop") %>%
    mutate(across(c(wdry, wwet, share_sum), ~ if_else(complete, .x, NA_real_))) %>%
    select(admin_id, year, wdry, wwet, share_sum)

  # squared z sums, dry and wet, uncapped and capped. NA unless all 12 months have a z
  z2 <- long %>%
    mutate(zc = pmin(pmax(z, -Z_CAP), Z_CAP)) %>% # z capped at +/- the SPI bound
    group_by(admin_id, year) %>%
    summarise(complete = sum(!is.na(z)) == 12,
              z2_dry_sum    = sum(pmin(z, 0)^2),  z2_wet_sum    = sum(pmax(z, 0)^2),
              z2cap_dry_sum = sum(pmin(zc, 0)^2), z2cap_wet_sum = sum(pmax(zc, 0)^2), .groups = "drop") %>%
    mutate(across(c(z2_dry_sum, z2_wet_sum, z2cap_dry_sum, z2cap_wet_sum), ~ if_else(complete, .x, NA_real_))) %>%
    select(-complete)

  complete_cy %>%
    left_join(bins, by = c("admin_id", "year")) %>%
    left_join(wdry, by = c("admin_id", "year")) %>%
    left_join(z2, by = c("admin_id", "year")) %>%
    left_join(transmute(spi12, admin_id, year, spi12_dry = pmax(0, -spi12), spi12_wet = pmax(0, spi12)),
              by = c("admin_id", "year")) %>%
    # NA unless all 12 months have an SPI
    mutate(across(all_of(bin_cols), ~ if_else(spi_complete, .x, NA_integer_))) %>%
    select(-spi_complete) %>%
    rename_with(~ paste0(prefix, .x, "_pop"), c(wdry, wwet, spi12_dry, spi12_wet, z2_dry_sum, z2_wet_sum, z2cap_dry_sum, z2cap_wet_sum))
}


# 1. Load monthly flow and precip, 1950-2010 ---------------------------

print("==== reading monthly flow and precip ====")
monthly <- imap(vars, function(v, nm) {
  read_monthly(v$dir, v$pattern, v$col, data_start, last_year) %>%
    rename(value = all_of(v$col))
})

# reg county-years (for the checks below)
reg_panel <- readRDS(panel_file) %>%
  filter(year >= first_year, year <= last_year, !is.na(flowmean_pop_annual))
reg_cy <- distinct(reg_panel, admin_id, year)

# county x calendar month rows, years as columns: every row needs all years
# (values can be NA, but the row must exist)
years_out <- first_year:last_year
results <- imap(monthly, function(df, nm) {
  df <- df %>% mutate(cal_month = substr(month, 6, 7))
  stopifnot(all(count(df, admin_id, year)$n == 12))
  wide <- df %>%
    select(admin_id, cal_month, year, value) %>%
    pivot_wider(names_from = year, values_from = value) %>%
    arrange(admin_id, cal_month)
  stopifnot(!anyNA(wide$admin_id), ncol(wide) == 2 + (last_year - data_start + 1))
  mat  <- as.matrix(wide[, as.character(data_start:last_year)])
  keys <- wide %>% select(admin_id, month = cal_month)

  long <- mat_to_long(spi_matrix(mat, years_out), keys, "spi") %>%
    left_join(mat_to_long(share_matrix(mat, years_out, wide$admin_id), keys, "share"), by = c("admin_id", "month", "year")) %>%
    left_join(mat_to_long(z_matrix(mat, years_out), keys, "z"), by = c("admin_id", "month", "year"))

  # SPI-12: the calendar-year total (NA unless all 12 months), standardized like the SPI-1
  annual_mat <- rowsum(mat, group = wide$admin_id, reorder = FALSE)
  spi12 <- spi_matrix(annual_mat, years_out)
  spi12_long <- as_tibble(spi12) %>%
    mutate(admin_id = rownames(annual_mat)) %>%
    pivot_longer(-admin_id, names_to = "year", values_to = "spi12") %>%
    mutate(year = as.integer(year))

  list(long = long, annual = annual_terms(long, spi12_long, nm))
})


# 2. Combine ---------------------------

annual <- results$prcp$annual %>%
  full_join(results$flow$annual, by = c("admin_id", "year")) %>%
  arrange(admin_id, year)

stopifnot(!anyDuplicated(annual[c("admin_id", "year")]))

# bins sum to 12 where present, and all-NA otherwise
for (nm in names(vars)) {
  m  <- as.matrix(annual[paste0(nm, "spi_bin_", spi_names, "_pop")])
  ok <- complete.cases(m)
  stopifnot(all(is.na(m[!ok, , drop = FALSE])), all(rowSums(m[ok, , drop = FALSE]) == 12))
}


# the 12 shares of a county-year add to 1, the weighted sums and the SPI-12 sides are not negative, and a year is not on both SPI-12 sides
for (nm in names(vars)) {
  w <- annual[[paste0(nm, "wdry_pop")]]; ww <- annual[[paste0(nm, "wwet_pop")]]; ss <- annual[[paste0(nm, "share_sum_pop")]]
  d <- annual[[paste0(nm, "spi12_dry_pop")]]; wt <- annual[[paste0(nm, "spi12_wet_pop")]]
  stopifnot(all(abs(ss - 1) < 1e-9, na.rm = TRUE), all(w >= 0 & ww >= 0, na.rm = TRUE),
            all(d >= 0 & wt >= 0, na.rm = TRUE), all(d == 0 | wt == 0, na.rm = TRUE))
}
annual <- select(annual, -ends_with("share_sum_pop"))

# squared z sums: not negative, the capped sums never above the uncapped ones, and at most 12 months x the cap squared per side
for (nm in names(vars)) {
  u <- annual[paste0(nm, c("z2_dry_sum_pop", "z2_wet_sum_pop"))]; cp <- annual[paste0(nm, c("z2cap_dry_sum_pop", "z2cap_wet_sum_pop"))]
  stopifnot(all(u >= 0, na.rm = TRUE), all(cp >= 0, na.rm = TRUE), all(cp <= u + 1e-8, na.rm = TRUE),
            all(cp <= 12 * Z_CAP^2 + 1e-8, na.rm = TRUE), identical(is.na(u[[1]]), is.na(cp[[1]])))
}

# 3. Checks (read these in the log) ---------------------------

reg_annual <- semi_join(annual, reg_cy, by = c("admin_id", "year"))
message(glue("reg county-years in the panel: {nrow(reg_cy)} | with a row here: {nrow(reg_annual)}"))
stopifnot(nrow(reg_annual) == nrow(reg_cy))

# county-years with a missing annual term (missing months from a baseline with
# fewer than 2 positive values, a zero-variance baseline or missing data),
# so the regressions will drop them
message("reg county-years with a missing term:")
reg_annual %>%
  summarise(across(-c(admin_id, year), ~ sum(is.na(.x)))) %>%
  pivot_longer(everything(), names_to = "term", values_to = "n_missing") %>%
  print(n = Inf)

# the flow SPI-12 built here against spi12_flow_pop of the annual flow panel (01_build_flow_measures.R): same
# method and baseline, so they should agree. wet side - dry side = the signed SPI-12
chk <- reg_annual %>%
  transmute(admin_id, year, mine = flowspi12_wet_pop - flowspi12_dry_pop) %>%
  inner_join(select(reg_panel, admin_id, year, spi12_flow_pop), by = c("admin_id", "year"))
message(glue("flow SPI-12 vs spi12_flow_pop: {nrow(chk)} county-years | both present: {sum(!is.na(chk$mine) & !is.na(chk$spi12_flow_pop))} | ",
             "max abs difference: {signif(max(abs(chk$mine - chk$spi12_flow_pop), na.rm = TRUE), 3)}"))
stopifnot(max(abs(chk$mine - chk$spi12_flow_pop), na.rm = TRUE) < 1e-6,
          identical(is.na(chk$mine), is.na(chk$spi12_flow_pop)))

# the new continuous terms, reg county-years
message("SPI-12 sides, weighted dry and wet sums and squared z sums, reg county-years:")
reg_annual %>%
  select(matches("spi12_(dry|wet)_pop|w(dry|wet)_pop|z2(cap)?_(dry|wet)_sum_pop")) %>%
  pivot_longer(everything(), names_to = "term", values_to = "x") %>%
  group_by(term) %>%
  summarise(mean = mean(x), sd = sd(x), share_zero = mean(x == 0), max = max(x), .groups = "drop") %>%
  print(n = Inf)

# monthly SPI by calendar month, 1970-2010 only (the baseline excludes the year
# itself). SPI should be near mean 0 / sd 1 if the gamma fits; the log shows how
# far it is, especially for flow
message("monthly SPI-1 by calendar month, 1970-", last_year, ":")
walk(names(results), function(nm) {
  message(nm)
  results[[nm]]$long %>%
    filter(year >= 1970, !is.na(spi)) %>%
    group_by(month) %>%
    summarise(n = n(), spi_mean = mean(spi), spi_sd = sd(spi)) %>%
    print(n = Inf)
})

# share of county-months in each SPI bin, reg county-years
walk(names(vars), function(nm) {
  message(nm, ": share of months per SPI bin, reg county-years")
  cols <- paste0(nm, "spi_bin_", spi_names, "_pop")
  reg_annual %>%
    filter(complete.cases(across(all_of(cols)))) %>%
    summarise(across(all_of(cols), ~ sum(.x) / (12 * n()))) %>%
    pivot_longer(everything(), names_to = "bin", values_to = "share_of_months") %>%
    print(n = Inf)
})


# 4. Save ---------------------------

if (write_output) {
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  saveRDS(annual, out_file)
  message("wrote: ", out_file)
}
