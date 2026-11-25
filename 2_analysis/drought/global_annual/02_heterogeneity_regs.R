# ============================================================================
# 02_heterogeneity_regs.R
#
# Global annual drought regs, on the panel from 01_build_heterogeneity_panel.R.
# Poisson on annual deaths, log(pop) offset, unweighted, SEs clustered by
# ADM1, with FE admin unit x age, country x year x age and ADM1 x year x age.
#
# Every reg has temp + precip poly + one drought term, all x age group with the
# precip terms at t-1, t and t+1 (placebo).
#
# Parts:
#   - pooled: one drought effect per age group
#   - terciles: by tercile of each het var
#   - quintiles: same with 5 groups, to see the shape of the effect along each het var 
#   - two_by_two: each pair of het vars cut at the median, one effect per cell,
#     plus the gaps between cells (for ex poorest minus richest among rural)
#   - ranks: income, irrigated and urban share in one reg, each as the
#     place's rank, to see which one matters once the other two are held fixed
#
# Groups and ranks are cut over all admin units (--cut=cross so they mostly compare 
# countries) or inside each country (--cut=within) - main version is across
#
# For every effect: t, t-1, total (t + t-1) and placebo (t+1), in two units:
#  - est: 100 x coef, about the % change in annual deaths per 1 unit of the term
#    For spi12_dry, 1 unit = a year 1 SD drier than usual
#    For dry_wsum, dry_sum and mckee (sums of monthly SPI), 1 unit = one month
#    1 SD drier, so their est can't be compared with spi12_dry's
#  - est_per_sd: est x the term's swing (its SD within a place), the % change
#    per typical drought year, comparable across the 4 measures
#
# Options for the reg runs:
# part, measure, product, cut, income, trend, sample, panel, fe, baseline
#
# Output: output/data/drought/global-annual/het/het_<part>_<measure>.csv
# ============================================================================


# --------------
# Packages
# --------------

library(dplyr)
library(readr)
library(fixest)


# -------------
#  Options
# -------------

# Each option is passed as --name=value by the sbatch, for ex --part=terciles
# Run in R, nothing is passed, so you get the defaults (the main spec)
args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(name, default) {
  value <- sub(".*=", "", grep(paste0("^--", name, "="), args, value = TRUE))
  if (length(value) == 0) default else value
}

# The options, default first:
#  - part = pooled | terciles | quintiles | two_by_two | ranks
#      which regs
#  - measure = spi12_dry | dry_wsum | dry_sum | mckee
#      the drought term
#  - product = era5land | chirps | era5land_chirpsample
#      the rainfall data for the drought term, the precip poly and the baseline
#      rainfall terciles. chirps and era5land_chirpsample keep only admin
#      unit-years with CHIRPS at t, t-1 and t+1 (50S to 50N, from 1981), so both
#      run on the same rows
#  - cut = cross | within
#      groups and ranks over all admin units, or inside each country 
#  - income = 2000_2010 | 1990_2024 | 1990_1999 | 2000_2009 | 2010_2024
#      years of the Kummu income average
#  - trend = no | unit
#      unit adds a linear trend for each admin unit x age (only for results
#      whose placebo is significant)
#  - sample = all | no_brazil_post2010 | no_brazil | no_new_countries
#      drops Brazil 2011-2024, all of Brazil, or the countries added in the new
#      panel (ARG, BWA, CAN, CPV, CRI, THA)
#  - panel = new | old
#      the old (August) panel, to compare the two
#  - fe = saturated | main
#      main drops ADM1 x year x age
#  - baseline = fixed | rolling30
#      SPI-12 against 1981-2010, or against the 30 years before (only with
#      measure spi12_dry and ERA5-Land)

MEASURE <- get_arg("measure", "spi12_dry")
PART <- get_arg("part", "pooled")
CUT <- get_arg("cut", "cross")
INCOME <- get_arg("income", "2000_2010")
TREND <- get_arg("trend", "no")
SAMPLE <- get_arg("sample", "all")
PANEL <- get_arg("panel", "new")
PRODUCT <- get_arg("product", "era5land")
FE_SET <- get_arg("fe", "saturated")
BASELINE <- get_arg("baseline", "fixed")
stopifnot(PRODUCT %in% c("era5land", "chirps", "era5land_chirpsample"), FE_SET %in% c("saturated", "main"),
          BASELINE %in% c("fixed", "rolling30"),
          BASELINE == "fixed" | (MEASURE == "spi12_dry" & PRODUCT == "era5land"))

# fixest on 1 thread, jobs on more threads got stuck on Midway
setFixest_nthreads(1)


# -------------
# Paths
# -------------

# het_panel_file (from 01) and results_dir
source("paths.R")

OUTPUT_FILE <- file.path(results_dir, 
                         paste0("het_", PART, "_",
                                MEASURE,
                                if (CUT == "within") "_within",
                                if (INCOME != "2000_2010") paste0("_income_", INCOME),
                                if (TREND == "unit") "_unittrend",
                                if (SAMPLE != "all") paste0("_", SAMPLE),
                                if (PANEL == "old") "_oldpanel",
                                if (FE_SET == "main") "_mainfe",
                                if (PRODUCT == "chirps") "_chirps" else if (PRODUCT == "era5land_chirpsample") "_chirpsample",
                                if (BASELINE == "rolling30") "_roll30", ".csv"))


# -----------------------
# Heterogeneity variables
# -----------------------

# Heterogeneity vars, one tercile split each
HET_VARS <- c("baseline_prcp_mm", "baseline_prcp_cv", "log_gdppc", "cropland_share",
              "irrigated_share", "rainfed_share_land", "irrigated_share_spam", "urban_share")

# Pairs for the 2 x 2:
#   cropland x irrigated: is it rainfed farming?
#   income x irrigated: is it income or irrigation
#   income x urban, irrigated x urban: is it just rural places?
PAIRS_2X2 <- list(
  c("cropland_share", "irrigated_share"),
  c("log_gdppc", "irrigated_share"),
  c("log_gdppc", "urban_share"),
  c("irrigated_share", "urban_share")
)

# Vars in the ranks regression
RANK_VARS <- c(income = "log_gdppc", irrigated = "irrigated_share", urban = "urban_share")


# ----------------
# Regression terms
# ----------------

# Periods of the drought and precip terms: this year (t), last year (t-1)
# and next year (t+1, placebo)
WHEN <- c(t = "", `t-1` = "_lag1", `t+1` = "_lead1")

# Windows we report: t, t-1, the total (t + t-1) and the placebo (t+1)
WINDOWS <- list(t = "t", `t-1` = "t-1", `t + t-1` = c("t", "t-1"), `t+1` = "t+1")

# Drought term and precip poly at t, t-1 and t+1, for ex spi12_dry_lag1
DROUGHT <- paste0(MEASURE, WHEN)
POLY <- paste0(rep(paste0("prcp_poly_", 1:3), each = 3), WHEN)

# FE: admin unit x age, country x year x age, ADM1 x year x age.
# With --trend=unit each admin unit x age also gets its own linear trend in years,
# so a place whose death rate drifts at its own pace doesn't look like a drought effect
# --fe=main drops ADM1 x year x age
FE <- paste("admin_code^agegroup + iso^year^agegroup",
            if (FE_SET == "saturated") "+ fe_adm1^year^agegroup",
            if (TREND == "unit") "+ admin_code^agegroup[year]")


# -----------------
# Read the panel
# -----------------

# The old panel still has the all-ages rows (agegroup 0), which 01 drops in the new one
panel <- if (PANEL == "old") filter(readRDS(old_panel_file), agegroup != "0") %>% mutate(agegroup = droplevels(agegroup)) else readRDS(het_panel_file)

# Sample checks: 
#  - without Brazil 2011-2024 (drier years with a drought effect of about 0 in Brazil's poorest places),
#  - without Brazil (all years)
#  - or without the countries added in the new panel

NEW_COUNTRIES <- c("ARG", "BWA", "CAN", "CPV", "CRI", "THA")
panel <- switch(SAMPLE,
                all = panel,
                no_brazil_post2010 = filter(panel, !(iso == "BRA" & year > 2010)),
                no_brazil = filter(panel, iso != "BRA"),
                no_new_countries = filter(panel, !iso %in% NEW_COUNTRIES))

# Rainfall product
# In the panel, spi12_dry, prcp_poly_1 etc refer to ERA5-Lan
# the same cols with _CHIRPS are CHIRPS (for ex spi12_dry_CHIRPS)
# for product options chirps and era5land_chirpsample: keep only the admin unit-years 
# that have the CHIRPS drought term and precip poly at t, t-1 and t+1
if (PRODUCT != "era5land") {
  chirps_cols <- c(paste0(MEASURE, "_CHIRPS", WHEN), as.vector(outer(paste0("prcp_poly_", 1:3, "_CHIRPS"), WHEN, paste0)))
  stopifnot(all(chirps_cols %in% names(panel)))
  panel <- filter(panel, if_all(all_of(chirps_cols), ~ !is.na(.x)))
}
# chirps: copy the CHIRPS columns onto the ERA5-Land names, so the regs below
# run on CHIRPS without changing anything else
if (PRODUCT == "chirps") {
  short <- function(x) sub("_CHIRPS", "", x)
  swap <- grep("_CHIRPS", names(panel), value = TRUE)
  panel[short(swap)] <- panel[swap]
}

# SPI-12 baseline: for --baseline=rolling30, the rolling version takes the
# short names (spi12_dry, spi12_dry_lag1, spi12_dry_lead1)
if (BASELINE == "rolling30") {
  roll <- paste0("spi12_dry_roll30", WHEN)
  stopifnot(all(roll %in% names(panel)))
  panel[paste0("spi12_dry", WHEN)] <- panel[roll]
}

# Income: the Kummu average over the --income years
panel <- mutate(panel, log_gdppc = .data[[paste0("log_gdppc_", INCOME)]])

# rows with every rainfall and temp term (drops the few admin units with no climate)
panel <- filter(panel, if_all(all_of(c(DROUGHT, POLY, "tavg_1", "tavg_2")), ~ !is.na(.x)))
message(MEASURE, ", ", PART, ": ", nrow(panel), " rows, ", n_distinct(panel$admin_code), " admin units")

# One row per admin unit with its het vars, to cut the groups on (so each tercile has a third of the admin units)
places <- distinct(panel, admin_code, country_group, across(all_of(HET_VARS)))

# swing: the SD of the drought term, to compare the 4 measures - they're in different units,
# so their estimates per 1 unit can't be compared. 
# The estimate x swing (est_per_sd) is the % change in deaths per 1 SD of the term, and that
# one can be compared across measures.

# How the swing is computed: each year's value minus its place's average over years
# (the admin FE take that average out), then one SD of those differences over all places and years
swing <- distinct(panel, admin_code, year, x = .data[[MEASURE]]) %>%
  group_by(admin_code) %>%
  mutate(dev = x - mean(x)) %>%
  ungroup() %>%
  pull(dev) %>%
  sd()


# -----------
#  Groups
# -----------

# Group names, bottom to top:
# 1_low, 2_mid, 3_high for terciles (n = 3)
# q1 to q5 for quintiles (n = 5)
group_names_n <- function(n) if (n == 3) c("1_low", "2_mid", "3_high") else paste0("q", 1:n)

# splits a het var into n groups with the same number of places in each:
# n = 3 for terciles, n = 5 for quintiles

# Terciles are cut at the 33rd and 67th percentiles - quintiles at the 20th, 40th, 60th and 80th
# If a third of units or more share the lowest value, the low and mid groups merge into one
# A var with fewer different values than groups isn't cut (all NA)
cut_n <- function(x, n) {
  if (n_distinct(x[!is.na(x)]) < n) return(rep(NA_character_, length(x)))
  bin <- cut(x, unique(quantile(x, 0:n / n, na.rm = TRUE)), include.lowest = TRUE, labels = FALSE)
  group_names_n(n)[bin]
}

# Urban share needs its own cut: 38% of admin units are at 0, so cut_n would merge the bottom groups
# The bottom group is every unit at or below the 33rd percentile (20th for quintiles), all at 0, 
# then the rest is split in equal groups
cut_urban <- function(x, n) {
  low <- x <= quantile(x, 1 / n, na.rm = TRUE)
  rest_cuts <- quantile(x[!low], seq_len(n - 2) / (n - 1), na.rm = TRUE)
  bin <- if_else(low, 1L, 1L + cut(x, c(-Inf, rest_cuts, Inf), labels = FALSE))
  group_names_n(n)[bin]
}

# Below ("lo") or above ("hi") the median
half <- function(x) if_else(x <= median(x, na.rm = TRUE), "lo", "hi")

# Groups the places by country for --cut=within, so the cuts and ranks below are inside 
# each country, otherwise over all admin units
by_cut <- function(df) if (CUT == "within") group_by(df, country_group) else df

# for the pooled reg (no het split): every admin unit in one group, "all"
one_group <- function() {
  places %>% mutate(group = "all") %>% select(admin_code, group)
}

# group of each admin unit for one het var, in n groups (urban share with cut_urban): 
# n = 3 for the terciles, 5 for the quintiles
het_groups <- function(var, n) {
  split_n <- if (var == "urban_share") cut_urban else cut_n
  by_cut(places) %>%
    mutate(group = split_n(.data[[var]], n)) %>%
    ungroup() %>%
    filter(!is.na(group)) %>%
    select(admin_code, group)
}

# 2 x 2 cell of a pair, each cut at the median, for ex "hi_lo" = first var above the median, second below
cell_groups <- function(pair) {
  by_cut(places) %>%
    mutate(group = paste(half(.data[[pair[1]]]), half(.data[[pair[2]]]), sep = "_")) %>%
    ungroup() %>%
    filter(!is.na(.data[[pair[1]]]), !is.na(.data[[pair[2]]])) %>%
    select(admin_code, group)
}


# ----------------------
# Regression
# ----------------------

# fit() is used to run every reg in this script: FE Poisson of deaths on temp
# and precip poly (by age group) and the drought terms (by cell)
# Each cell (age group x het group, for ex "1_3_high" = age group 1 (0-4) in
# the top tercile, "3_high") gets its own drought effect
fit <- function(df, drought_terms, fe = FE) {
  controls <- paste0("i(agegroup, ", c("tavg_1", "tavg_2", POLY), ")")
  drought <- paste0("i(cell, ", drought_terms, ")")
  f <- as.formula(paste("deaths ~", paste(c(controls, drought), collapse = " + "), "|", fe))
  fepois(f, data = df, offset = ~log(population), cluster = ~adm1_code)
}


# ----------------------
# Combining coefficients
# ----------------------

# the reg gives one drought coef per cell for each period: t, t-1 and t+1 (placebo).
# We also report the "total" effect, the sum of the t and t-1  coefs: droughts are 
# persistent and their effects on deaths can show up the year after, so the total 
# is the full effect over the drought year and the year after. 

# low - high: the low tercile coef minus the high tercile coef, in each window.

# the coefs are correlated, so the SE of a total or a low - high uses their covariance (vcov),
# not just the SEs added up


# a cell ell combines the age group and het group created above
#   age codes: 1 = 0-4, 2 = 5-64, 3 = 65+
#   tercile groups: 1_low, 2_mid, 3_high
#   for ex 1_1_low = 0-4 in the low tercile, 2_3_high = 5-64 in the high one

# The function below gives the names of one cell's drought coefs for some periods, 
# to pull them from the reg (fixest names each coef after the cell and the drought term)

coef_names <- function(cell, years, term = MEASURE) {
  paste0("cell::", cell, ":", term, WHEN[years])
}

# tells coef_sum to add these coefs (-ones() tells it to subtract them)
ones <- function(names) setNames(rep(1, length(names)), names)


# coef_sum() adds or subtracts the coefs picked with ones(), for ex adds the t and t-1
# coefs for the total: it gives the estimate (x 100, so in %), its SE and p
# The SE uses vcov, since the coefs are correlated
# NA if one of the coefs was dropped from the reg: fixest drops a coef when
# the FE leave it no variation, for ex a group with very few admin units

# model: the reg (from fit())
# coefs_to_combine: the coefs to add or subtract (from ones())
coef_sum <- function(model, coefs_to_combine) {
  b <- coef(model)
  if (!all(names(coefs_to_combine) %in% names(b))) return(tibble(est = NA_real_, se = NA_real_, p = NA_real_))
  a <- 0 * b
  a[names(coefs_to_combine)] <- coefs_to_combine
  est <- sum(a * b)
  se <- sqrt(as.numeric(t(a) %*% vcov(model) %*% a))
  tibble(est = 100 * est, se = 100 * se, p = 2 * pnorm(-abs(est / se)))
}

# runs coef_sum for each window we report: t, t-1, total (t + t-1) and placebo  (t+1)
# pick_coefs: a function that, for a window's periods, gives the coefs to combine
# (for ex for the total, the t and t-1 coefs). Each caller passes its own: 
# one group's coefs, low - high, a rank slope, the effect at the median
by_window <- function(model, pick_coefs) {
  bind_rows(lapply(WINDOWS, function(years) coef_sum(model, pick_coefs(years))), .id = "window")
}


# ----------
# Joint test
# ----------

# joint test: p-value that several differences or slopes are all 0 at once, on totals (t + t-1)
# groups regs: are the groups' totals all the same? Tests each group's total - the reference group's 
# (for terciles: mid - low and high - low)
# small p = at least one group differs, not that every pair differs

# ranks reg: does any of the three dims change the drought effect? Tests that the three slopes' totals are all 0
# NA if one of the coefs was dropped from the reg, same as coef_sum
# model: the reg (from fit())
# sums: the differences or slopes to test, each made with ones() like in coef_sum
test_p <- function(model, sums) {
  b <- coef(model)
  if (!all(unlist(lapply(sums, names)) %in% names(b))) return(NA_real_)
  R <- t(sapply(sums, function(coefs) { r <- 0 * b; r[names(coefs)] <- coefs; r }))
  d <- R %*% b
  pchisq(as.numeric(t(d) %*% solve(R %*% vcov(model) %*% t(R)) %*% d), df = nrow(R), lower.tail = FALSE)
}


# -------------------------------------
# Regressions by heterogeneity group
# -------------------------------------

# one reg with drought x age x group
# For each age group: 
#    - the effect in each group
#    - low - high (terciles)
#    - and the test that every group has the same total

## The pooled reg uses it too, with every admin unit in one group ("all"), so there's no het split, just drought x age 
run_groups <- function(groups, label) {
  # 1. Each row's cell
  df <- panel %>%
    inner_join(groups, by = "admin_code") %>%
    mutate(cell = paste(agegroup, group, sep = "_"))
  group_names <- sort(unique(groups$group))

  # 2. The reg
  model <- fit(df, DROUGHT)

  rows <- list()
  for (age in levels(df$agegroup)) {
    cell <- function(group) paste(age, group, sep = "_")

    # 3. Effect in each group
    for (g in group_names) {
      rows[[length(rows) + 1]] <- by_window(model, function(years) ones(coef_names(cell(g), years))) %>%
        mutate(bin = g, agegroup = age)
    }

    # 4. Low - high: the bottom group minus the top one, for terciles (1_low -3_high) and quintiles (q1 - q5)
    # Not for the pooled reg or the 2 x 2
    bottom_top <- if ("1_low" %in% group_names) c("1_low", "3_high") else c("q1", "q5")
    if (all(bottom_top %in% group_names)) {
      low_minus_high <- function(years) c(ones(coef_names(cell(bottom_top[1]), years)), -ones(coef_names(cell(bottom_top[2]), years)))
      rows[[length(rows) + 1]] <- by_window(model, low_minus_high) %>%
        mutate(bin = "low - high", agegroup = age)
    }

    # 2 x 2 only: the two cells low on the second var, the first var's low cell minus its high one (lo_lo - hi_lo)
    # For income or irrigation x urban share: among rural places, poorest minus richest, or least minus most irrigated
    if (all(c("lo_lo", "hi_lo") %in% group_names)) {
      low_first_minus_high <- function(years) c(ones(coef_names(cell("lo_lo"), years)), -ones(coef_names(cell("hi_lo"), years)))
      rows[[length(rows) + 1]] <- by_window(model, low_first_minus_high) %>%
        mutate(bin = "lo_lo - hi_lo", agegroup = age)
    }

    # 5. Test that every group has the same total (t + t-1): each group's total minus the reference group's is 0
    if (length(group_names) > 1) {
      total <- function(g) ones(coef_names(cell(g), c("t", "t-1")))
      differences <- lapply(group_names[-1], function(g) c(total(g), -total(group_names[1])))
      rows[[length(rows) + 1]] <- tibble(window = "test", bin = "groups differ", p = test_p(model, differences), agegroup = age)
    }
  }

  message(label, " done")
  bind_rows(rows) %>% mutate(n_obs = nobs(model), model = label)
}


# -----------------
# Ranks regressions
# -----------------

# Drought x rank term of one var, for ex "spi12_dry_x_income"
rank_term <- function(var) paste0(MEASURE, "_x_", var)

# One reg with drought x age plus drought x age x each var's rank
# Ranks go from 0 (bottom) to 1 (top), so each var's slope is the difference in
# the drought effect between the top and bottom place (of the panel, or of a
# country with --cut=within), holding the other two vars fixed

# For each age group:
#   - the slope of each rank
#   - the effect at the median (rank 0.5 on all three)
#   - the test that the three slopes' totals (t + t-1) are all 0
# trend = TRUE adds country x year x age x income half FE (are richer places just on a different trend?)

run_ranks <- function(trend) {
  # 1. Each place's rank, and its income half (for the trend version)
  ranks <- by_cut(places) %>%
    mutate(across(all_of(unname(RANK_VARS)), percent_rank, .names = "rank_{.col}"),
           income_half = half(log_gdppc)) %>%
    ungroup() %>%
    filter(if_all(starts_with("rank_"), ~ !is.na(.x))) %>%
    select(admin_code, income_half, starts_with("rank_"))

  # One group ("all") per age group, so the plain drought terms are drought x age, like the pooled reg
  df <- panel %>%
    inner_join(ranks, by = "admin_code") %>%
    mutate(cell = paste(agegroup, "all", sep = "_"))

  # 2. Drought x rank at t, t-1 and t+1, for ex spi12_dry_x_income_lag1
  for (var in names(RANK_VARS)) for (period in WHEN) {
    df[[paste0(rank_term(var), period)]] <- df[[paste0(MEASURE, period)]] * df[[paste0("rank_", RANK_VARS[[var]])]]
  }
  slope_terms <- as.vector(outer(rank_term(names(RANK_VARS)), WHEN, paste0))

  # 3. The reg, plus country x year x age x income half in the trend version
  fe <- if (trend) paste(FE, "+ iso^year^agegroup^income_half") else FE
  model <- fit(df, c(DROUGHT, slope_terms), fe)
  label <- if (trend) "ranks + trends by income half" else "ranks"

  rows <- list()
  for (age in levels(df$agegroup)) {
    cell <- paste(age, "all", sep = "_")
    slope <- function(var, years) ones(coef_names(cell, years, rank_term(var)))

    # 4. Slope of each rank
    for (var in names(RANK_VARS)) {
      rows[[length(rows) + 1]] <- by_window(model, function(years) slope(var, years)) %>%
        mutate(bin = var, agegroup = age)
    }

    # 5. Effect at the median: rank 0.5 on all three
    at_median <- function(years) c(ones(coef_names(cell, years)), 0.5 * unlist(lapply(names(RANK_VARS), slope, years)))
    rows[[length(rows) + 1]] <- by_window(model, at_median) %>%
      mutate(bin = "at median", agegroup = age)

    # 6. Test that the three slopes' totals (t + t-1) are all 0
    totals <- lapply(names(RANK_VARS), slope, c("t", "t-1"))
    rows[[length(rows) + 1]] <- tibble(window = "test", bin = "slopes all 0", p = test_p(model, totals), agegroup = age)
  }

  message(label, " done")
  bind_rows(rows) %>% mutate(n_obs = nobs(model), model = label)
}


# ------------
# Run Regs
# -----------

# Runs the part picked with PART (only that line runs), and stacks its regs into one table:
#   pooled: one reg, every admin unit in one group
#   terciles: one reg per het var
#   two_by_two: one reg per pair, for ex "log_gdppc x irrigated_share"
#   ranks: two regs, without and with the trends by income half

results <- switch(PART,
  pooled = run_groups(one_group(), "pooled"),
  terciles = bind_rows(lapply(HET_VARS, function(het_var) run_groups(het_groups(het_var, 3), het_var))),
  quintiles = bind_rows(lapply(HET_VARS, function(het_var) run_groups(het_groups(het_var, 5), het_var))),
  two_by_two = bind_rows(lapply(PAIRS_2X2, function(pair) run_groups(cell_groups(pair), paste(pair, collapse = " x ")))),
  ranks = bind_rows(run_ranks(trend = FALSE), run_ranks(trend = TRUE))
)


# ---------
# Write
# ---------

# est: the estimate, % change in annual deaths per 1 unit of the drought term 
# (for SPI-12, a year 1 SD of rainfall drier)

# est_per_sd: the estimate x swing, % change per 1 within-place SD of the term
# (to compare the 4 measures)
results <- results %>%
  mutate(measure = MEASURE,
         cut = CUT,
         swing = swing,
         est_per_sd = est * swing, 
         se_per_sd = se * swing) %>%
  select(measure, cut, model,
         bin, agegroup, 
         window, est, se,
         p, est_per_sd,
         se_per_sd, swing,
         n_obs)

write_csv(results, OUTPUT_FILE)
message("wrote: ", OUTPUT_FILE)



