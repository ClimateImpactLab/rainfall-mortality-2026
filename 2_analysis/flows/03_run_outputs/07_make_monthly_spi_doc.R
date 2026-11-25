# ============================================================
# 07_make_monthly_spi_doc.R
#
# Overleaf-ready LaTeX document on the monthly SPI terms summed to the year and
# the annual SPI-12, the SPI counterpart of 03_make_monthly_bins_doc.R. Same
# article layout. z-scores are left out for now (monthly rain and flow are skewed).
#
# Sections:
#   1.   The idea and the measures (why months; a table of the measures and what each shows)
#   2.   How the measures are built (baseline, SPI-1, SPI-12, the annual terms)
#   3.   Regression
#   4.   The measures in the regression years (raw-level bin counts as in
#        03_make_monthly_bins_doc.R, SPI bin counts, SPI-12 sides, weighted sums)
#   5.   Which measure explains mortality better? The raw-level bin counts of
#        03_make_monthly_bins_doc.R and the SPI terms in one run (same rows).
#        Both FE specs are shown, the discussion is on the saturated FE
#   6.   Judgment calls
#   Appendix: coefficients
# Every figure and table is placed [H], so it stays in its own section.
#
# Every number in the document is computed here or read from the outputs below,
# on the regression county-years: the USA regression panel's county-years with
# annual flow, 1968-2010 (as in 02_regressions/07_usa_monthly_spi_regs.R). The
# settings (cap, baseline length, bin cutoffs) are set below and have to match
# 01_measures/06_build_monthly_spi_measures.R.
#
# Inputs:
# /project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/
#   flows/usa_annual/usa_annual_flow_regression_panel.rds
#   flows/annual_from_monthly_spi/era5land_admin_monthly_spi_usa.rds
#   flows/annual_from_monthly_precip_flow_bins/era5land_admin_precip_flow_bins_usa.rds
# /project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND-GLOBAL/
#   USA/hydro/monthly/era5land_usa_adm2_flow_monthly_<year>.csv (counts for a caption)
# output/data/flows/usa-annual/precip_flow_bins/explore/ (01_measures/04_explore_precip_flow_bins.R):
#   explore_summary.csv, explore_schemes.csv and figures/fig_explore_{hists,events_selected}.pdf
# output/data/flows/usa-annual/monthly_spi/ (the regs, saturated FE and the _main FE run):
#   usa_monthly_spi_{coefficients,models}_<REG_RUN_ID>[_main].csv
# Output (output/data/flows/usa-annual/overleaf_monthly_spi/), the folder to
# upload to Overleaf:
#   usa_monthly_spi.tex
#   figures/fig_raw_bins_regs.pdf, fig_pct_bins_regs.pdf, fig_spi_counts_regs.pdf, fig_spi12_regs.pdf, fig_wsum_regs.pdf
#   (made here; fig_raw_bins_regs.pdf is the same regressions as the
#   bins document's fig_precip_flow_bins_regs.pdf)
#   figures/fig_explore_hists.pdf, fig_explore_events_selected.pdf (copied from the explore folder)
# Run order: 01_measures/04_explore_precip_flow_bins.R, sbatch/run_07_usa_monthly_spi_regs.sbatch
# (builds the terms and runs the regs), then this script.
# Dependencies: dplyr, readr, tidyr, ggplot2; ../../../0_utils/paths.R, so run
# this script from its own folder.
# ============================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(readr)
library(tidyr)
library(ggplot2)
library(purrr) # read_monthly()


# -----------------------------
# Paths and settings
# -----------------------------

USER <- Sys.getenv("USER")
source("../../../0_utils/paths.R") # DATA_DIR, DIR_REPO_RAINFALL_MORTALITY

CLIMATE_DIR <- file.path(DATA_DIR, "climate_data")
PANEL_FILE <- file.path(CLIMATE_DIR, "ERA5-LAND", "flows", "usa_annual", "usa_annual_flow_regression_panel.rds")
SPI_FILE <- file.path(CLIMATE_DIR, "ERA5-LAND", "flows", "annual_from_monthly_spi", "era5land_admin_monthly_spi_usa.rds")

BINS_FILE <- file.path(CLIMATE_DIR, "ERA5-LAND", "flows", "annual_from_monthly_precip_flow_bins", "era5land_admin_precip_flow_bins_usa.rds")

# county-percentile bins (05_ with --scheme=percentile --probs=0.1,0.25,0.75,0.9): the file
PCT_BINS_TAG  <- "_pct_roll20_p10_25_75_90"
PCT_BINS_FILE <- sub("\\.rds$", paste0(PCT_BINS_TAG, ".rds"), BINS_FILE)

FLOW_MONTHLY_DIR <- file.path(CLIMATE_DIR, "ERA5-LAND-GLOBAL", "USA", "hydro", "monthly")

# Precip vs flow bin exploration (01_measures/04_explore_precip_flow_bins.R), figures of the bins document
EXPLORE_DIR <- file.path(DIR_REPO_RAINFALL_MORTALITY, "output", "data", "flows", "usa-annual", "precip_flow_bins", "explore")
EXPLORE_FIGURES <- c("fig_explore_hists.pdf", "fig_explore_events_selected.pdf")
HIST_X_MIN <- 1 # the histogram's flow axis starts here (as in 03_make_monthly_bins_doc.R); the county-months below it are counted in the caption

# Reg runs (levels, weighted, both wind controls), saturated FE, death year only
REG_RUN_ID <- "levels_weighted_both"
REG_DIR <- file.path(DIR_REPO_RAINFALL_MORTALITY, "output", "data", "flows", "usa-annual", "monthly_spi")

# New folder: no existing script reads from it
OVERLEAF_DIR <- file.path(DIR_REPO_RAINFALL_MORTALITY, "output", "data", "flows", "usa-annual", "overleaf_monthly_spi")
figure_dir <- file.path(OVERLEAF_DIR, "figures")
dir.create(figure_dir, recursive = TRUE, showWarnings = FALSE)
TEX_FILE <- file.path(OVERLEAF_DIR, "usa_monthly_spi.tex")

# Colors from 00_describe_flow_measures.R
fill_colour <- "#1c5cab"

FIRST_YEAR <- 1968 # regression years, as in 02_regressions/02_usa_flow_regs.R
LAST_YEAR <- 2010

# Settings of 01_measures/06_build_monthly_spi_measures.R. Keep them in step with it
BASELINE_YEARS <- 20 # rolling prior years, same calendar month
EARLY_BASELINE <- c(1950, 1969) # fixed baseline for the years without 20 prior years of data
SPI_P_MIN <- 1e-4 # SPI probability cap
SPI_EDGES <- c(-2, -1.5, -1, 1, 1.5, 2) # SPI bin cutoffs, reference bin [-1, 1)

# Raw-level bins of 01_measures/05_build_monthly_precip_flow_bins.R (mm), in the regs of 07_
RAW_BINS <- list(
  prcp = list(edges = c(50, 100, 150, 200), names = c("lt50", "50_100", "100_150", "150_200", "ge200"), ref = "50_100"),
  flow = list(edges = c(100, 1000, 10000, 100000), names = c("lt100", "100_1k", "1k_10k", "10k_100k", "ge100k"), ref = "100_1k")
)

SPI_CAP <- qnorm(1 - SPI_P_MIN) # the bound the probability cap puts on the SPI
stopifnot(EARLY_BASELINE[2] - EARLY_BASELINE[1] + 1 == BASELINE_YEARS)

years_label <- paste0(FIRST_YEAR, "--", LAST_YEAR)


# -----------------------------
# Small functions
# -----------------------------

fmt_int <- function(x) format(x, big.mark = ",", scientific = FALSE, trim = TRUE)
fmt_num <- function(x, digits) formatC(x, format = "f", digits = digits, big.mark = ",")
fmt_pct <- function(x) paste0(formatC(100 * x, format = "f", digits = 1), "\\%")
# significance stars of a p-value: * p < 0.10, ** p < 0.05, *** p < 0.01
stars <- function(p) ifelse(p < 0.01, "***", ifelse(p < 0.05, "**", ifelse(p < 0.10, "*", "")))
star_note <- "Stars: * $p < 0.10$, ** $p < 0.05$, *** $p < 0.01$."
# an estimate to 3 significant digits, never in scientific notation (LaTeX math)
fmt_est <- function(x) vapply(x, function(v) format(signif(v, 3), scientific = FALSE, trim = TRUE), character(1)) # one at a time: format() on a vector pads to common decimals

takeaway <- function(text) c("", paste0("\\medskip\\noindent\\textbf{Takeaway.} ", text), "")

join_and <- function(x) if (length(x) <= 1) x else paste0(paste(head(x, -1), collapse = ", "), " and ", tail(x, 1))


# -----------------------------
# Regression county-years and the annual terms
# -----------------------------

# -------- 1. Terms in the regression county-years --------

SPI_NAMES <- c("lt_m2", "m2_m1p5", "m1p5_m1", "m1_p1", "p1_p1p5", "p1p5_p2", "ge_p2") # as in 06_
REF_BIN <- "m1_p1"
stopifnot(length(SPI_NAMES) == length(SPI_EDGES) + 1)
VARS <- c(prcp = "Precipitation", flow = "Flow")

reg_cy <- readRDS(PANEL_FILE) %>%
  filter(year >= FIRST_YEAR, year <= LAST_YEAR, !is.na(flowmean_pop_annual)) %>%
  distinct(admin_id, year)

terms_df <- inner_join(reg_cy, readRDS(SPI_FILE), by = c("admin_id", "year"))
stopifnot(nrow(terms_df) == nrow(reg_cy), !anyDuplicated(terms_df[c("admin_id", "year")]))
n_cy <- nrow(terms_df)
n_counties <- n_distinct(terms_df$admin_id)

# the SPI bins: edges, plain label (figure axis) and LaTeX label
spi_bin_tbl <- tibble(bin = SPI_NAMES, lower = c(-Inf, SPI_EDGES), upper = c(SPI_EDGES, Inf)) %>%
  mutate(
    plain = case_when(is.infinite(lower) ~ paste0("<", upper), is.infinite(upper) ~ paste0(">=", lower),
                      TRUE ~ paste(lower, "to", upper)),
    tex   = case_when(is.infinite(lower) ~ paste0("$<", upper, "$"), is.infinite(upper) ~ paste0("$\\ge ", lower, "$"),
                      TRUE ~ paste0("$[", lower, ", ", upper, ")$")),
    reference = bin == REF_BIN
  )

# the raw-level bins: edges, plain label (figure axis) and LaTeX label, per variable
raw_bin_tbl <- bind_rows(lapply(names(RAW_BINS), function(v) {
  b <- RAW_BINS[[v]]
  stopifnot(length(b$names) == length(b$edges) + 1, b$ref %in% b$names)
  num <- function(x) format(x, big.mark = ",", scientific = FALSE, trim = TRUE)
  num_tex <- function(x) format(x, big.mark = "{,}", scientific = FALSE, trim = TRUE) # a comma in math mode gets a space after it
  tibble(variable = v, bin = b$names, lower = c(-Inf, b$edges), upper = c(b$edges, Inf)) %>%
    mutate(plain = case_when(is.infinite(lower) ~ paste0("<", num(upper)), is.infinite(upper) ~ paste0(">=", num(lower)),
                             TRUE ~ paste(num(lower), "to", num(upper))),
           tex   = case_when(is.infinite(lower) ~ paste0("$<", num_tex(upper), "$"), is.infinite(upper) ~ paste0("$\\ge ", num_tex(lower), "$"),
                             TRUE ~ paste0("$[", num_tex(lower), ", ", num_tex(upper), ")$")),
           reference = bin == b$ref)
}))

# -------- 2. Summaries --------

# bin counts: mean months per county-year and the share of county-years with none
bin_stats <- bind_rows(lapply(names(VARS), function(v) {
  terms_df %>%
    select(all_of(setNames(paste0(v, "spi_bin_", SPI_NAMES, "_pop"), SPI_NAMES))) %>%
    pivot_longer(everything(), names_to = "bin", values_to = "months") %>%
    group_by(bin) %>%
    summarise(mean_months = mean(months), share_zero = mean(months == 0), .groups = "drop") %>%
    mutate(variable = v)
}))
stopifnot(nrow(bin_stats) == length(VARS) * length(SPI_NAMES))
bin_stat <- function(v, b, what) bin_stats[[what]][bin_stats$variable == v & bin_stats$bin == b]

# raw-level bin counts (05_build_monthly_precip_flow_bins.R), as in the chosen-bins table of
# 03_make_monthly_bins_doc.R: share of months, months per year, county-years with any month,
# counties with any month, counties whose count varies over the years
bins_m <- readRDS(BINS_FILE)
stopifnot(!anyDuplicated(bins_m[c("admin_id", "year")]))
raw_df <- inner_join(reg_cy, bins_m, by = c("admin_id", "year"))
stopifnot(nrow(raw_df) == n_cy)

raw_stats <- bind_rows(lapply(names(RAW_BINS), function(v) {
  b <- RAW_BINS[[v]]
  cols <- setNames(paste0(v, "mon_bin_", b$names, "_pop"), b$names)
  stopifnot(all(cols %in% names(raw_df)), !anyNA(raw_df[cols]))
  long <- raw_df %>%
    select(admin_id, year, all_of(cols)) %>%
    pivot_longer(all_of(names(cols)), names_to = "bin", values_to = "months")
  stopifnot(all(tapply(long$months, paste(long$admin_id, long$year), sum) == 12)) # the counts sum to 12
  long %>%
    group_by(bin) %>%
    summarise(mean_months = mean(months), share_of_months = mean(months) / 12, share_cy_any = mean(months > 0), .groups = "drop") %>%
    left_join(long %>%
                group_by(bin, admin_id) %>%
                summarise(any_month = any(months > 0), varies = n_distinct(months) > 1, .groups = "drop") %>%
                group_by(bin) %>%
                summarise(counties_any = sum(any_month), counties_varying = sum(varies), .groups = "drop"),
              by = "bin") %>%
    mutate(variable = v)
}))
raw_stat <- function(v, b, what) raw_stats[[what]][raw_stats$variable == v & raw_stats$bin == b]

# county-percentile bins (05_, scheme percentile): the same descriptives
# the county-percentile bins, hard-coded: must match 05_ with --scheme=percentile --probs=0.1,0.25,0.75,0.9
# (bin p25_75 is the reference; column names as 05_ builds them)
pct_def <- crossing(variable = c("prcp", "flow"),
                      tibble(bin = c("p00_10", "p10_25", "p25_75", "p75_90", "p90_100"),
                             lower = c(-Inf, 0.1, 0.25, 0.75, 0.9), upper = c(0.1, 0.25, 0.75, 0.9, Inf))) %>%
  arrange(desc(variable), lower) %>%
  mutate(scheme = "percentile", reference = bin == "p25_75", column = paste0(variable, "pct_bin_", bin, "_pop")) %>%
  select(variable, scheme, bin, lower, upper, reference, column)
pct_bins_m <- readRDS(PCT_BINS_FILE)
stopifnot(!anyDuplicated(pct_bins_m[c("admin_id", "year")]))
pct_df <- inner_join(reg_cy, pct_bins_m, by = c("admin_id", "year"))
stopifnot(nrow(pct_df) == n_cy)

# bin labels in percent: the plain label (figure axis) and the LaTeX one
pct_bin_tbl <- pct_def %>%
  mutate(plain = case_when(is.infinite(lower) ~ paste0("<", round(100 * upper)), is.infinite(upper) ~ paste0(">=", round(100 * lower)),
                           TRUE ~ paste(round(100 * lower), "to", round(100 * upper))),
         tex   = case_when(is.infinite(lower) ~ paste0("$<", round(100 * upper), "$"), is.infinite(upper) ~ paste0("$\\ge ", round(100 * lower), "$"),
                           TRUE ~ paste0("$[", round(100 * lower), ", ", round(100 * upper), ")$")))

pct_stats <- bind_rows(lapply(names(VARS), function(v) {
  d <- pct_def %>% filter(variable == v)
  cols <- setNames(d$column, d$bin)
  stopifnot(all(cols %in% names(pct_df)), !anyNA(pct_df[cols]))
  long <- pct_df %>%
    select(admin_id, year, all_of(cols)) %>%
    pivot_longer(all_of(names(cols)), names_to = "bin", values_to = "months")
  stopifnot(all(tapply(long$months, paste(long$admin_id, long$year), sum) == 12)) # the counts sum to 12
  long %>%
    group_by(bin) %>%
    summarise(mean_months = mean(months), share_of_months = mean(months) / 12, share_cy_any = mean(months > 0), .groups = "drop") %>%
    left_join(long %>%
                group_by(bin, admin_id) %>%
                summarise(any_month = any(months > 0), varies = n_distinct(months) > 1, .groups = "drop") %>%
                group_by(bin) %>%
                summarise(counties_any = sum(any_month), counties_varying = sum(varies), .groups = "drop"),
              by = "bin") %>%
    mutate(variable = v)
}))
pct_stat <- function(v, b, what) pct_stats[[what]][pct_stats$variable == v & pct_stats$bin == b]

# the exploration figures of the bins document: copied here, with the numbers of their captions
source("../01_measures/00_read_monthly.R") # read_monthly()

flow_m <- read_monthly(FLOW_MONTHLY_DIR, "^era5land_usa_adm2_flow_monthly_[0-9]{4}\\.csv$", "flow_pop", FIRST_YEAR, LAST_YEAR) %>%
  semi_join(reg_cy, by = c("admin_id", "year"))
stopifnot("flow_pop" %in% names(flow_m), nrow(flow_m) == 12 * n_cy, !anyNA(flow_m$flow_pop)) # every regression county-year has its 12 months
n_at_or_below_0 <- sum(flow_m$flow_pop <= 0)
n_below_hist_min <- sum(flow_m$flow_pop < HIST_X_MIN)

explore_path <- function(name) {
  path <- file.path(EXPLORE_DIR, name)
  if (!file.exists(path)) stop("run 01_measures/04_explore_precip_flow_bins.R first, missing: ", path, call. = FALSE)
  path
}
explore_summary <- read_csv(explore_path("explore_summary.csv"), show_col_types = FALSE)
explore_schemes <- read_csv(explore_path("explore_schemes.csv"), show_col_types = FALSE) %>%
  mutate(lower = as.numeric(lower), upper = as.numeric(upper)) # open end bins are -Inf / Inf
ex_value <- function(name) {
  value <- explore_summary$value[explore_summary$name == name]
  stopifnot(length(value) == 1)
  value
}

# the exploration has to be on these county-months and its chosen schemes have to be the raw-level bins above
scheme_edges <- function(id) explore_schemes %>% filter(scheme == id, is.finite(upper)) %>% arrange(bin) %>% pull(upper)
if (ex_value("first_year") != FIRST_YEAR || ex_value("last_year") != LAST_YEAR || ex_value("counties") != n_counties ||
    ex_value("county_years") != n_cy || ex_value("county_months") != 12 * n_cy ||
    !isTRUE(all.equal(scheme_edges("prcp_w50"), RAW_BINS$prcp$edges)) ||
    !isTRUE(all.equal(scheme_edges("flow_decade"), RAW_BINS$flow$edges))) {
  stop("the exploration run doesn't match this document's sample or raw-level bins: ", EXPLORE_DIR, call. = FALSE)
}

copied <- file.copy(file.path(EXPLORE_DIR, "figures", EXPLORE_FIGURES), file.path(figure_dir, EXPLORE_FIGURES), overwrite = TRUE)
if (!all(copied)) stop("could not copy: ", paste(EXPLORE_FIGURES[!copied], collapse = ", "), call. = FALSE)

# the annual SPI-12 sides and the weighted dry and wet sums: mean, sd and share of county-years at 0
ANNUAL_TERMS <- tribble(
  ~suffix,           ~tex,
  "spi12_dry_pop",   "SPI-12, drought side $A^{\\mathrm{dry}}$",
  "spi12_wet_pop",   "SPI-12, wet side $A^{\\mathrm{wet}}$",
  "wdry_pop",        "Weighted dry sum $W^{\\mathrm{dry}}$",
  "wwet_pop",        "Weighted wet sum $W^{\\mathrm{wet}}$",
  "z2_dry_sum_pop",  "Squared z-score, dry sum $Z^{2,\\mathrm{dry}}$",
  "z2_wet_sum_pop",  "Squared z-score, wet sum $Z^{2,\\mathrm{wet}}$",
  "z2cap_dry_sum_pop", "Capped squared z-score, dry sum $\\tilde Z^{2,\\mathrm{dry}}$",
  "z2cap_wet_sum_pop", "Capped squared z-score, wet sum $\\tilde Z^{2,\\mathrm{wet}}$"
)
term_stats <- bind_rows(lapply(names(VARS), function(v) {
  terms_df %>%
    select(all_of(setNames(paste0(v, ANNUAL_TERMS$suffix), ANNUAL_TERMS$suffix))) %>%
    pivot_longer(everything(), names_to = "suffix", values_to = "x") %>%
    group_by(suffix) %>%
    summarise(mean = mean(x), sd = sd(x), share_zero = mean(x == 0), .groups = "drop") %>%
    mutate(variable = v)
}))
term_stat <- function(v, s, what) term_stats[[what]][term_stats$variable == v & term_stats$suffix == s]

# county-years with any missing term (the terms are NA unless all 12 months have a value)
term_cols <- unlist(lapply(names(VARS), function(v) c(paste0(v, "spi_bin_", SPI_NAMES, "_pop"), paste0(v, ANNUAL_TERMS$suffix))))
stopifnot(all(term_cols %in% names(terms_df)))
n_missing_cy <- sum(!complete.cases(terms_df[c("admin_id", "year", term_cols)]))


# -----------------------------
# Regressions
# -----------------------------

# -------- 3. Regression outputs --------

SETS <- c("baseline", paste0(names(VARS), "_raw_bins"), paste0(names(VARS), "_pct_bins"),
          unlist(lapply(names(VARS), function(v) paste0(v, c("_spi_counts", "_spi12", "_wsum", "_z2", "_z2cap")))))
SET_SHORT <- c(
  prcp_raw_bins = "precipitation raw bins", flow_raw_bins = "flow raw bins",
  prcp_pct_bins = "precipitation county-percentile bins", flow_pct_bins = "flow county-percentile bins",
  prcp_spi_counts = "precipitation SPI bin counts", prcp_spi12 = "precipitation SPI-12",
  prcp_wsum = "precipitation weighted sums",
  prcp_z2 = "precipitation squared z-score", prcp_z2cap = "precipitation capped squared z-score",
  flow_spi_counts = "flow SPI bin counts", flow_spi12 = "flow SPI-12",
  flow_wsum = "flow weighted sums",
  flow_z2 = "flow squared z-score", flow_z2cap = "flow capped squared z-score"
)
SET_TEX <- c(
  prcp_raw_bins = "Precipitation, raw-level bin counts", flow_raw_bins = "Flow, raw-level bin counts",
  prcp_pct_bins = "Precipitation, county-percentile bin counts", flow_pct_bins = "Flow, county-percentile bin counts",
  prcp_spi_counts = "Precipitation, SPI bin counts", prcp_spi12 = "Precipitation, SPI-12",
  prcp_wsum = "Precipitation, weighted sums",
  prcp_z2 = "Precipitation, squared z-score", prcp_z2cap = "Precipitation, capped squared z-score",
  flow_spi_counts = "Flow, SPI bin counts", flow_spi12 = "Flow, SPI-12",
  flow_wsum = "Flow, weighted sums",
  flow_z2 = "Flow, squared z-score", flow_z2cap = "Flow, capped squared z-score"
)
stopifnot(setequal(names(SET_SHORT), setdiff(SETS, "baseline")), setequal(names(SET_TEX), setdiff(SETS, "baseline")))

reg_file <- function(what, suffix) {
  path <- file.path(REG_DIR, paste0("usa_monthly_spi_", what, "_", REG_RUN_ID, suffix, ".csv"))
  if (!file.exists(path)) stop("run sbatch/run_07_usa_monthly_spi_regs.sbatch first, missing: ", path, call. = FALSE)
  path
}

age_levels <- c("0-4", "5-64", "65+")

# one run of 07_usa_monthly_spi_regs.R: suffix "" = saturated FE, "_main" = main FE (no state x year x age)
load_run <- function(suffix, spec) {
  run <- list(
    spec   = spec,
    coefs  = read_csv(reg_file("coefficients", suffix), show_col_types = FALSE,
                      col_types = cols(agegroup = "c", lower = "d", upper = "d", .default = col_guess())),
    models = read_csv(reg_file("models", suffix), show_col_types = FALSE)
  )
  # every set estimated, the FE spec this document says, one N
  if (!setequal(run$models$set_id, SETS) || any(run$models$spec_id != spec) ||
      anyNA(run$coefs$estimate) || n_distinct(run$models$nobs) != 1) {
    stop("the monthly SPI run (", spec, ") isn't the one this document describes: ", REG_DIR, call. = FALSE)
  }
  run
}
sat     <- load_run("", "saturated")
main_fe <- load_run("_main", "main")
stopifnot(unique(sat$models$sample_rows) == unique(main_fe$models$sample_rows))
reg_nobs <- unique(sat$models$nobs)
main_nobs <- unique(main_fe$models$nobs)

# the bins and the cap in the regs have to be the ones described here
reg_edges <- sat$coefs %>% filter(grepl("spi_counts", set_id)) %>% with(sort(unique(c(lower, upper))))
stopifnot(isTRUE(all.equal(reg_edges[is.finite(reg_edges)], SPI_EDGES)))
for (v in names(RAW_BINS)) {
  raw_reg_edges <- sat$coefs %>% filter(set_id == paste0(v, "_raw_bins")) %>% with(sort(unique(c(lower, upper))))
  stopifnot(isTRUE(all.equal(raw_reg_edges[is.finite(raw_reg_edges)], RAW_BINS[[v]]$edges)))
}

# -------- 4. Coefficient figures --------

variable_labels <- c(prcp = "Precipitation", flow = "Flow")

# Figure 1: raw-level bin counts. x axis: every bin in order, the ref (0) in place
raw_axis_tbl <- raw_bin_tbl %>% mutate(axis = if_else(reference, paste0(plain, "\n(ref)"), plain))
stopifnot(!anyDuplicated(raw_axis_tbl$axis))

raw_data <- sat$coefs %>%
  filter(grepl("raw_bins", set_id)) %>%
  left_join(select(raw_axis_tbl, variable, lower, axis), by = c("variable", "lower")) %>%
  mutate(axis = factor(axis, levels = raw_axis_tbl$axis),
         variable = factor(variable_labels[variable], levels = variable_labels),
         age_label = factor(age_label, levels = age_levels))
stopifnot(!anyNA(raw_data$axis))

raw_ref <- raw_axis_tbl %>%
  filter(reference) %>%
  crossing(age_label = factor(age_levels, levels = age_levels)) %>%
  mutate(axis = factor(axis, levels = raw_axis_tbl$axis), estimate = 0,
         variable = factor(variable_labels[variable], levels = variable_labels))

fig_raw <- ggplot(raw_data, aes(axis, estimate)) +
  geom_blank(data = bind_rows(select(raw_data, axis, estimate, variable, age_label),
                              select(raw_ref, axis, estimate, variable, age_label))) +
  geom_hline(yintercept = 0, colour = "grey75", linewidth = 0.5) +
  geom_pointrange(aes(ymin = lo, ymax = hi), colour = fill_colour, linewidth = 0.55) +
  geom_point(data = raw_ref, shape = 1, size = 2.5, colour = "grey40") +
  facet_grid(age_label ~ variable, scales = "free") +
  scale_x_discrete(guide = guide_axis(n.dodge = 2)) +
  labs(x = "Raw-level bin (mm; flow summed over upstream cells)", y = "Deaths per 100,000") +
  theme_classic(base_size = 10) +
  theme(strip.background = element_blank(), strip.text = element_text(face = "bold"),
        strip.text.y.right = element_text(angle = 0))
ggsave(file.path(figure_dir, "fig_raw_bins_regs.pdf"), fig_raw, width = 8, height = 6)

# Figure 2: SPI bin counts. x axis: every bin in order, the ref (0) in place
axis_tbl <- spi_bin_tbl %>% mutate(axis = if_else(reference, paste0(plain, "\n(ref)"), plain))

counts_data <- sat$coefs %>%
  filter(grepl("spi_counts", set_id)) %>%
  left_join(select(axis_tbl, lower, axis), by = "lower") %>%
  mutate(axis = factor(axis, levels = axis_tbl$axis),
         variable = factor(variable_labels[variable], levels = variable_labels),
         age_label = factor(age_label, levels = age_levels))
stopifnot(!anyNA(counts_data$axis))

counts_ref <- axis_tbl %>%
  filter(reference) %>%
  crossing(age_label = factor(age_levels, levels = age_levels), variable = factor(variable_labels, levels = variable_labels)) %>%
  mutate(axis = factor(axis, levels = axis_tbl$axis), estimate = 0)

fig_counts <- ggplot(counts_data, aes(axis, estimate)) +
  geom_blank(data = bind_rows(select(counts_data, axis, estimate, variable, age_label),
                              select(counts_ref, axis, estimate, variable, age_label))) +
  geom_hline(yintercept = 0, colour = "grey75", linewidth = 0.5) +
  geom_pointrange(aes(ymin = lo, ymax = hi), colour = fill_colour, linewidth = 0.55) +
  geom_point(data = counts_ref, shape = 1, size = 2.5, colour = "grey40") +
  facet_grid(age_label ~ variable, scales = "free") +
  scale_x_discrete(guide = guide_axis(n.dodge = 2)) + # the labels overlap in one row
  labs(x = "SPI-1 bin", y = "Deaths per 100,000") +
  theme_classic(base_size = 10) +
  theme(strip.background = element_blank(), strip.text = element_text(face = "bold"),
        strip.text.y.right = element_text(angle = 0))
ggsave(file.path(figure_dir, "fig_spi_counts_regs.pdf"), fig_counts, width = 8, height = 6)

# County-percentile bin counts. x axis: every bin in order, the ref (0) in place
pct_axis_tbl <- pct_bin_tbl %>% filter(variable == "prcp") %>% select(-variable) %>% # same bins for both variables
  mutate(axis = if_else(reference, paste0(plain, "\n(ref)"), plain))

pctb_data <- sat$coefs %>%
  filter(grepl("pct_bins", set_id)) %>%
  left_join(select(pct_axis_tbl, lower, axis), by = "lower") %>%
  mutate(axis = factor(axis, levels = pct_axis_tbl$axis),
         variable = factor(variable_labels[variable], levels = variable_labels),
         age_label = factor(age_label, levels = age_levels))
stopifnot(!anyNA(pctb_data$axis))

pctb_ref <- pct_axis_tbl %>%
  filter(reference) %>%
  crossing(age_label = factor(age_levels, levels = age_levels), variable = factor(variable_labels, levels = variable_labels)) %>%
  mutate(axis = factor(axis, levels = pct_axis_tbl$axis), estimate = 0)

fig_pctb <- ggplot(pctb_data, aes(axis, estimate)) +
  geom_blank(data = bind_rows(select(pctb_data, axis, estimate, variable, age_label),
                              select(pctb_ref, axis, estimate, variable, age_label))) +
  geom_hline(yintercept = 0, colour = "grey75", linewidth = 0.5) +
  geom_pointrange(aes(ymin = lo, ymax = hi), colour = fill_colour, linewidth = 0.55) +
  geom_point(data = pctb_ref, shape = 1, size = 2.5, colour = "grey40") +
  facet_grid(age_label ~ variable, scales = "free") +
  scale_x_discrete(guide = guide_axis(n.dodge = 2)) + # the labels overlap in one row
  labs(x = "County-percentile bin (percentile of the month in the county's last 20 years)", y = "Deaths per 100,000") +
  theme_classic(base_size = 10) +
  theme(strip.background = element_blank(), strip.text = element_text(face = "bold"),
        strip.text.y.right = element_text(angle = 0))
ggsave(file.path(figure_dir, "fig_pct_bins_regs.pdf"), fig_pctb, width = 8, height = 6)

# Figures 3 to 6: the two terms of a set side by side, in the layout of Figures 1 and 2 (age in rows,
# precipitation and flow in columns): the SPI-12 sides, the weighted dry and wet sums, and the dry and wet
# sums of the squared z-score, uncapped and capped
side_figure <- function(set_pattern, side_labels, x_label, y_label, file) {
  d <- sat$coefs %>%
    filter(grepl(set_pattern, set_id)) %>%
    mutate(side = factor(if_else(grepl("dry", coef_var), side_labels[1], side_labels[2]), levels = side_labels),
           variable = factor(variable_labels[variable], levels = variable_labels),
           age_label = factor(age_label, levels = age_levels))
  stopifnot(nrow(d) == length(VARS) * length(age_levels) * 2)
  fig <- ggplot(d, aes(side, estimate)) +
    geom_hline(yintercept = 0, colour = "grey75", linewidth = 0.5) +
    geom_pointrange(aes(ymin = lo, ymax = hi), colour = fill_colour, linewidth = 0.55) +
    facet_grid(age_label ~ variable, scales = "free_y") +
    labs(x = x_label, y = y_label) +
    theme_classic(base_size = 10) +
    theme(strip.background = element_blank(), strip.text = element_text(face = "bold"),
          strip.text.y.right = element_text(angle = 0))
  ggsave(file.path(figure_dir, file), fig, width = 8, height = 6)
}
side_figure("spi12", c("Drought side", "Wet side"), "Side of the SPI-12", "Deaths per 100,000 per unit of the SPI-12 side", "fig_spi12_regs.pdf")
side_figure("wsum", c("Weighted dry sum", "Weighted wet sum"), "Weighted sum", "Deaths per 100,000 per unit of the weighted sum", "fig_wsum_regs.pdf")
side_figure("_z2$", c("Dry sum", "Wet sum"), "Squared z-score", "Deaths per 100,000 per unit of the sum", "fig_z2_regs.pdf")
side_figure("z2cap", c("Dry sum", "Wet sum"), "Capped squared z-score", "Deaths per 100,000 per unit of the sum", "fig_z2cap_regs.pdf")

# -------- 5. Tables and takeaway numbers --------

# Section 5, raw-level bins: one block per variable, as in the chosen-bins table of the bins document
raw_variable_labels <- c(prcp = "Precipitation (mm)", flow = "Flow (mm summed over upstream cells)")
raw_rows <- unlist(lapply(names(RAW_BINS), function(v) {
  rows <- raw_bin_tbl %>% filter(variable == v)
  c(
    paste0("    \\multicolumn{6}{l}{\\textit{", raw_variable_labels[[v]], "}} \\\\"),
    vapply(seq_len(nrow(rows)), function(i) {
      b <- rows$bin[i]
      paste0("    ", rows$tex[i], if (rows$reference[i]) " (ref)" else "", " & ",
             fmt_pct(raw_stat(v, b, "share_of_months")), " & ", fmt_num(raw_stat(v, b, "mean_months"), 2), " & ",
             fmt_pct(raw_stat(v, b, "share_cy_any")), " & ", fmt_int(raw_stat(v, b, "counties_any")), " & ",
             fmt_int(raw_stat(v, b, "counties_varying")), " \\\\")
    }, character(1)),
    if (v != tail(names(RAW_BINS), 1)) "    \\addlinespace"
  )
}))

# the county-percentile bins: one block per variable, as the raw-level bins table
pct_rows <- unlist(lapply(names(VARS), function(v) {
  rows <- pct_bin_tbl %>% filter(variable == v)
  c(
    paste0("    \\multicolumn{6}{l}{\\textit{", c(prcp = "Precipitation", flow = "Flow")[[v]], "}} \\\\"),
    vapply(seq_len(nrow(rows)), function(i) {
      b <- rows$bin[i]
      paste0("    ", rows$tex[i], if (rows$reference[i]) " (ref)" else "", " & ",
             fmt_pct(pct_stat(v, b, "share_of_months")), " & ", fmt_num(pct_stat(v, b, "mean_months"), 2), " & ",
             fmt_pct(pct_stat(v, b, "share_cy_any")), " & ", fmt_int(pct_stat(v, b, "counties_any")), " & ",
             fmt_int(pct_stat(v, b, "counties_varying")), " \\\\")
    }, character(1)),
    if (v != tail(names(VARS), 1)) "    \\addlinespace"
  )
}))

# Section 5 table 1: bin counts
bin_rows <- vapply(seq_len(nrow(spi_bin_tbl)), function(i) {
  b <- spi_bin_tbl$bin[i]
  paste0("    ", spi_bin_tbl$tex[i], if (spi_bin_tbl$reference[i]) " (ref)" else "", " & ",
         fmt_num(bin_stat("prcp", b, "mean_months"), 2), " & ", fmt_pct(bin_stat("prcp", b, "share_zero")), " & ",
         fmt_num(bin_stat("flow", b, "mean_months"), 2), " & ", fmt_pct(bin_stat("flow", b, "share_zero")), " \\\\")
}, character(1))

# Section 6: fit and significance, one row per set
gain_of <- function(run, set) run$models$within_adj_r2_gain[run$models$set_id == set]
gain_text <- function(run, set) paste0("$", fmt_num(1e4 * gain_of(run, set), 2), " \\times 10^{-4}$")
sig_of <- function(set) {
  p <- sat$coefs$p_value[sat$coefs$set_id == set]
  paste0(sum(p < 0.05), " of ", length(p))
}
fit_rows <- vapply(setdiff(SETS, "baseline"), function(s) {
  paste0("    ", SET_TEX[[s]], " & ", sat$models$n_terms[sat$models$set_id == s], " & ",
         fmt_num(1e4 * gain_of(sat, s), 2), " & ", fmt_num(1e4 * gain_of(main_fe, s), 2), " & ", sig_of(s), " \\\\")
}, character(1))


# the set with the largest gain under a spec, with its gain
best_set_text <- function(run) {
  sets <- setdiff(SETS, "baseline")
  top <- sets[which.max(vapply(sets, function(s) gain_of(run, s), numeric(1)))]
  paste0(SET_SHORT[[top]], " ", gain_text(run, top))
}

# coefficients, appendix: one block per set, ages across
coef_rows_of <- function(run) unlist(lapply(setdiff(SETS, "baseline"), function(s) {
  cs <- run$coefs %>% filter(set_id == s)
  keys <- unique(cs$coef_var) # in the order of the regs
  c(
    paste0("    \\multicolumn{4}{l}{\\textit{", SET_TEX[[s]], "}} \\\\"),
    unlist(lapply(keys, function(k) {
      ck <- cs %>% filter(coef_var == k) %>% arrange(match(age_label, age_levels))
      stopifnot(nrow(ck) == 3)
      label <- if (grepl("spi12|wsum|z2", s)) ANNUAL_TERMS$tex[match(sub("^(prcp|flow)", "", k), ANNUAL_TERMS$suffix)] else
        if (grepl("pct_bins", s)) pct_bin_tbl$tex[pct_bin_tbl$variable == ck$variable[1] & pct_bin_tbl$lower == ck$lower[1]] else
        if (grepl("spi_counts", s)) spi_bin_tbl$tex[match(ck$lower[1], spi_bin_tbl$lower)] else
        raw_bin_tbl$tex[raw_bin_tbl$variable == ck$variable[1] & raw_bin_tbl$lower == ck$lower[1]]
      stopifnot(!is.na(label))
      c(paste0("    ", label, " & ", paste0("$", fmt_est(ck$estimate), ifelse(nzchar(stars(ck$p_value)), paste0("^{", stars(ck$p_value), "}"), ""), "$", collapse = " & "), " \\\\*"),
        paste0("    & ", paste0("($", fmt_est(ck$se), "$)", collapse = " & "), " \\\\"))
    })),
    "    \\addlinespace"
  )
}))
# a coefficient table that can break across pages, with its header repeated on each page
coef_longtable <- function(rows, caption) c(
  "{\\small",
  "\\begin{longtable}{lrrr}",
  paste0("\\caption{", caption, "}\\\\"),
  "    \\toprule", "    Term & 0--4 & 5--64 & 65+ \\\\", "    \\midrule", "\\endfirsthead",
  "    \\toprule", "    Term & 0--4 & 5--64 & 65+ \\\\", "    \\midrule", "\\endhead",
  "    \\bottomrule", "\\endfoot",
  rows,
  "\\end{longtable}",
  "}"
)
coef_rows_sat <- coef_rows_of(sat)
coef_rows_main <- coef_rows_of(main_fe)

# significant coefficients of the sets matching a pattern, per FE spec
n_sig <- function(run, pattern) sum(run$coefs$p_value[grepl(pattern, run$coefs$set_id)] < 0.05)
n_coefs <- function(pattern) sum(grepl(pattern, sat$coefs$set_id))

# Section 5: the SPI-12 sides and the weighted sums
annual_rows <- vapply(seq_len(nrow(ANNUAL_TERMS)), function(i) {
  s <- ANNUAL_TERMS$suffix[i]
  paste0("    ", ANNUAL_TERMS$tex[i], " & ",
         paste(vapply(names(VARS), function(v) paste(fmt_num(term_stat(v, s, "mean"), 2), fmt_num(term_stat(v, s, "sd"), 2),
                                                     fmt_pct(term_stat(v, s, "share_zero")), sep = " & "), character(1)), collapse = " & "),
         " \\\\")
}, character(1))



# -----------------------------
# LaTeX document
# -----------------------------

tex <- c(
  "\\documentclass[11pt]{article}",
  "\\usepackage[margin=1in]{geometry}",
  "\\usepackage{amsmath}",
  "\\usepackage{amssymb}",
  "\\usepackage{booktabs}",
  "\\usepackage{graphicx}",
  "\\usepackage{longtable} % the coefficient tables are longer than a page",
  "\\usepackage{adjustbox} % shrinks a table wider than the text, never enlarges",
  "\\usepackage{float} % [H]: every figure and table stays in its own section",
  "\\usepackage[hidelinks]{hyperref}",
  "",
  paste0("\\title{Rainfall and mortality: monthly measures for  droughts and floods \\\\\\large U.S. counties, ", years_label, "}"),
  "\\date{\\today}",
  "",
  "\\begin{document}",
  "\\maketitle",
  "",
  "\\section{Measures}",
  "\\label{sec:idea}",
  "",
  "\\begin{itemize}",
  "\\item My older annual drought and flood terms collapse the twelve months first and transform second. But mortality responds nonlinearly to each day's rain and annual totals hide extremes.",
  "\\item Here, each month is transformed first, and the year's term is the sum over its months, with $X_{itm}$ county $i$'s flow or precipitation in month $m$ of year $t$.",
  "\\item Testing different dimensions (too many dimensions, maybe?): absolute vs relative, linear vs binned, annual vs monthly, precip vs flow, z-score vs SPI (capped vs uncapped), fixed vs county-percentile bin edges.",
  "\\end{itemize}",
  "",
  "\\begin{table}[H]",
  "\\centering",
  "\\small",
  "\\begin{adjustbox}{max width=\\textwidth}",
  "\\begin{tabular}{p{3.6cm}p{3.7cm}p{7.2cm}}",
  "    \\toprule",
  "    Measure & Annual term & Description \\\\",
  "    \\midrule",
  "    Raw-level bins & months per level bin & absolute amounts of rain or flow \\\\",
  "    County-percentile bins & months per county-percentile bin & relative to the county's own recent months, seasonality kept \\\\",
  "    SPI-1 bin counts & months per SPI bin & relative to the place's normal \\\\",
  "    Weighted dry and wet sums & $W^{\\mathrm{dry}}$, $W^{\\mathrm{wet}}$ & same monthly SPI in a linear form, each month weighted by how much rain it usually brings \\\\",
  "    SPI-12, two-sided & $A^{\\mathrm{dry}}$, $A^{\\mathrm{wet}}$ & linear SPI of the year's total \\\\",
  "    Squared z-score & $Z^{2,\\mathrm{dry}}$, $Z^{2,\\mathrm{wet}}$ & squared z-score of each month, summed over dry and wet months \\\\",
  "    Squared z-score, capped & $\\tilde Z^{2,\\mathrm{dry}}$, $\\tilde Z^{2,\\mathrm{wet}}$ & same with z capped at the SPI bound \\\\",
  "    \\bottomrule",
  "\\end{tabular}",
  "\\end{adjustbox}",
  "\\caption{Measures}",
  "\\label{tab:measures}",
  "\\end{table}",
  "",
  "\\section{How the measures are built}",
  "\\label{sec:build}",
  "",
  "\\begin{itemize}",
  "\\item \\textbf{Baseline.} A month is compared with the same calendar month of the same county in the baseline years $B_t$: the previous 20 years for $t \\ge 1970$, and the fixed years 1950--1969 for $t \\le 1969$, which include the year itself.",
  "\\item \\textbf{SPI-1.} The SPI of a month is the normal quantile of its probability under a gamma fitted to the baseline values. Used from Marine's regressions. Capped at about $\\pm 3.7$.",
  "\\item \\textbf{SPI-12.} The same calculation for the calendar-year total.",
  "\\item \\textbf{z-score.} The z-score of a month is its value minus the baseline mean, over the baseline standard deviation, with the same baseline as the SPI. Rain and flow are right-skewed, so in a dry-season month with a few mm of baseline rain an ordinary wet month is many standard deviations above the mean, and squaring such values lets a few county-months dominate the annual sum. So there is an uncapped version and a capped one, with z capped at the SPI bound (about $\\pm 3.7$). The cap limits the outliers, but doesn't help with the skewness problem. In an earlier run, the precipitation squared-z terms for wet months were significant uncapped and not capped, so the uncapped result came from a few extreme months.",
  "\\end{itemize}",
  "",
  "The annual terms:",
  "\\begin{itemize}",
  "\\item \\textbf{Raw-level bins.} Months in each bin of $X_{itm}$ itself, with the bins of the monthly bins document: precipitation cutoffs at 50, 100, 150 and 200 mm, reference $[50, 100)$; flow cutoffs at 100, 1,000, 10,000 and 100,000, reference $[100, 1{,}000)$.",
  "\\item \\textbf{County-percentile bins.} Fixed edges for flow mostly pick up how big a county's river is, so here the bins are relative to each county. The percentile of a month is its rank among the same county's months (all calendar months) in the baseline years $B_t$, ties counted half. Months per bin, with cutoffs at the 10th, 25th, 75th and 90th percentile (five bins, reference $[25, 75)$).",
  "\\item \\textbf{SPI-1 bin counts.} Months per SPI bin, with cutoffs $c_1, \\dots, c_6 = -2, -1.5, -1, 1, 1.5, 2$ (seven bins, reference $[-1, 1)$, three bins of drought months below it and three of flood months above).",
  "\\item \\textbf{Weighted dry and wet sums.} Each month is weighted by $s_{im}$, the share of the year's rain (flow) its calendar month usually brings:",
  "\\[ W^{\\mathrm{dry}}_{it} = 12 \\sum_{m=1}^{12} s_{im} \\max(0, -\\mathrm{SPI}_{itm}), \\qquad W^{\\mathrm{wet}}_{it} = 12 \\sum_{m=1}^{12} s_{im} \\max(0, \\mathrm{SPI}_{itm}). \\]",
  "The dry sum is Marine's weighted dry sum; the wet sum is the same on the wet side.",
  "\\item \\textbf{SPI-12, two-sided.} A drought term and a wet-year term:",
  "\\[ A^{\\mathrm{dry}}_{it} = \\max(0, -\\mathrm{SPI12}_{it}), \\qquad A^{\\mathrm{wet}}_{it} = \\max(0, \\mathrm{SPI12}_{it}). \\]",
  "Note that it only has the year's total, so a really dry month followed by a very wet one looks like a normal year.",
  "\\item \\textbf{Squared z-score, dry and wet sums.} With $z_{itm}$ the z-score of month $m$, and $\\tilde z_{itm}$ the same capped at $\\pm 3.7$:",
  "\\[ Z^{2,\\mathrm{dry}}_{it} = \\sum_{m=1}^{12} \\min(0, z_{itm})^2, \\qquad Z^{2,\\mathrm{wet}}_{it} = \\sum_{m=1}^{12} \\max(0, z_{itm})^2. \\]",
  "The capped sums $\\tilde Z^{2,\\mathrm{dry}}_{it}$ and $\\tilde Z^{2,\\mathrm{wet}}_{it}$ are the same with $\\tilde z_{itm}$ in place of $z_{itm}$.",
  "\\end{itemize}",
  "\\section{Regression}",
  "\\label{sec:reg}",
  "",
  "\\begin{itemize}",
  "\\item With $a$ the age group, county-year $(i,t)$ and $T^{k}_{it}$ the terms of one set,",
  "\\[ Y_{ait} = \\sum_{k} \\beta_{ak}\\, T^{k}_{it} + \\text{temp}_{a} + \\text{wind}_{a} + \\text{FE} + U_{ait}. \\]",
  "\\item A coefficient is, for a bin count, the change in the death rate of age group $a$ from moving one month out of the reference bin into that bin; for an SPI-12 term, the change per unit of the term (one standard deviation of the year's total beyond normal); for a weighted sum, the change per unit of the sum (one month one standard deviation beyond normal, in a month with a typical share); for a squared z-score sum, the change per unit of the sum (one month one standard deviation from its baseline mean, on that side).",
  "\\item Temperature polynomial (order 2) $\\times$ age, annual extreme wind and high-wind days $\\times$ age. Levels (OLS), population weights, SEs clustered by state. Death year only, with no leads or lags.",
  "\\item FE: saturated (county $\\times$ age, year $\\times$ age, state $\\times$ year $\\times$ age), which absorbs everything common to the counties of a state in a year, is the specification discussed. The run without the state $\\times$ year $\\times$ age FE is shown next to it in the fit table and in Appendix~\\ref{app:coefs}.",
  "\\end{itemize}",
  "\\section{Bin descriptives}",
  "\\label{sec:years}",
  "",
  "\\begin{table}[H]",
  "\\centering",
  "\\small",
  "\\begin{adjustbox}{max width=\\textwidth}",
  "\\begin{tabular}{lrrrrr}",
  "    \\toprule",
  "    & & Months per & County-years & \\multicolumn{2}{c}{Counties} \\\\",
  "    \\cmidrule(lr){5-6}",
  "    Bin (mm) & Share of months & year (mean) & with any month & any month & count varies \\\\",
  "    \\midrule",
  raw_rows,
  "    \\bottomrule",
  "\\end{tabular}",
  "\\end{adjustbox}",
  "\\caption{The raw-level bins. Count varies: the county's number of months in the bin changes across years; with county FE, only these counties identify the bin's coefficient.}",
  "\\label{tab:rawbins}",
  "\\end{table}",
  "",
  "\\begin{figure}[H]",
  "\\centering",
  "\\includegraphics[width=\\textwidth]{figures/fig_explore_hists.pdf}",
  paste0(
    "\\caption{Monthly flow (log axis) and precipitation in the regression county-months, with the raw-level bin edges (dashed). ",
    fmt_int(n_below_hist_min), " county-months below ", HIST_X_MIN, " mm of flow (", fmt_int(n_at_or_below_0), " at or below 0) and ",
    fmt_int(ex_value("prcp_above_400")), " above 400 mm of precipitation are not shown.}"
  ),
  "\\label{fig:hists}",
  "\\end{figure}",
  "",
  "\\begin{figure}[H]",
  "\\centering",
  "\\includegraphics[width=\\textwidth]{figures/fig_explore_events_selected.pdf}",
  "\\caption{Four of the flood counties, event year $\\pm$ 2 years: flow (top, log axis) and precipitation (bottom), with the raw-level bin edges (dashed). Shaded: event months.}",
  "\\label{fig:events}",
  "\\end{figure}",
  "",
  "\\begin{table}[H]",
  "\\centering",
  "\\small",
  "\\begin{tabular}{lrrrrr}",
  "    \\toprule",
  "    & & Months per & County-years & \\multicolumn{2}{c}{Counties} \\\\",
  "    \\cmidrule(lr){5-6}",
  "    Bin (percentile) & Share of months & year (mean) & with any month & any month & count varies \\\\",
  "    \\midrule",
  pct_rows,
  "    \\bottomrule",
  "\\end{tabular}",
  "\\caption{The county-percentile bins. Count varies: the county's number of months in the bin changes across years; with county FE, only these counties identify the bin's coefficient.}",
  "\\label{tab:pctbins}",
  "\\end{table}",
  "",
  "\\begin{table}[H]",
  "\\centering",
  "\\small",
  "\\begin{adjustbox}{max width=\\textwidth}",
  "\\begin{tabular}{lrrrr}",
  "    \\toprule",
  "    & \\multicolumn{2}{c}{Precipitation} & \\multicolumn{2}{c}{Flow} \\\\",
  "    \\cmidrule(lr){2-3} \\cmidrule(lr){4-5}",
  "    SPI-1 bin & Mean months & No month & Mean months & No month \\\\",
  "    \\midrule",
  bin_rows,
  "    \\bottomrule",
  "\\end{tabular}",
  "\\end{adjustbox}",
  "\\caption{Months per county-year in each SPI-1 bin (the seven counts sum to 12). No month: share of county-years with none.}",
  "\\label{tab:bins}",
  "\\end{table}",
  "",
  "\\section{Regression results}",
  "\\label{sec:results}",
  "",
  "\\begin{figure}[H]",
  "\\centering",
  "\\includegraphics[width=\\textwidth]{figures/fig_raw_bins_regs.pdf}",
  "\\caption{Death-year raw-level bin-count coefficients (saturated FE), deaths per 100,000 per month moved out of the reference bin (open circle). 95\\% CIs, clustered by state.}",
  "\\end{figure}",
  "",
  "\\begin{figure}[H]",
  "\\centering",
  "\\includegraphics[width=\\textwidth]{figures/fig_pct_bins_regs.pdf}",
  "\\caption{Death-year county-percentile bin-count coefficients (saturated FE), deaths per 100,000 per month moved out of the reference bin (open circle). 95\\% CIs, clustered by state.}",
  "\\end{figure}",
  "",
  "\\begin{figure}[H]",
  "\\centering",
  "\\includegraphics[width=\\textwidth]{figures/fig_spi_counts_regs.pdf}",
  "\\caption{Death-year SPI bin-count coefficients (saturated FE), deaths per 100,000 per month moved out of the reference bin (open circle). 95\\% CIs, clustered by state.}",
  "\\end{figure}",
  "",
  "\\begin{figure}[H]",
  "\\centering",
  "\\includegraphics[width=\\textwidth]{figures/fig_spi12_regs.pdf}",
  "\\caption{Death-year coefficients of the two sides of the SPI-12 (saturated FE), deaths per 100,000 per unit of the side. Each age group has its own scale. 95\\% CIs, clustered by state.}",
  "\\end{figure}",
  "",
  "\\begin{figure}[H]",
  "\\centering",
  "\\includegraphics[width=\\textwidth]{figures/fig_wsum_regs.pdf}",
  "\\caption{Death-year coefficients of the weighted dry and wet sums (saturated FE), deaths per 100,000 per unit of the sum. Each age group has its own scale. 95\\% CIs, clustered by state.}",
  "\\end{figure}",
  "",
  "\\begin{figure}[H]",
  "\\centering",
  "\\includegraphics[width=\\textwidth]{figures/fig_z2_regs.pdf}",
  "\\caption{Death-year coefficients of the dry and wet sums of the squared z-score (saturated FE), deaths per 100,000 per unit of the sum. Each age group has its own scale. 95\\% CIs, clustered by state. The narrow wet-sum CIs rest on a few California county-years: the 20 largest values carry 88.9\\% of the within-county variation, and 47 of the 50 largest are California (the six largest are California counties in 1974). The capped term, where the top 20 carry 0.6\\%, has wide CIs. Not re-estimated without California.}",
  "\\end{figure}",
  "",
  "\\begin{figure}[H]",
  "\\centering",
  "\\includegraphics[width=\\textwidth]{figures/fig_z2cap_regs.pdf}",
  "\\caption{Death-year coefficients of the dry and wet sums of the capped squared z-score (saturated FE), deaths per 100,000 per unit of the sum. Each age group has its own scale. 95\\% CIs, clustered by state.}",
  "\\end{figure}",

  # ---- appendix
  "\\appendix",
  "",
  "\\section{Coefficients}",
  "\\label{app:coefs}",
  "",
  coef_longtable(coef_rows_sat, paste0("Death-year coefficients of Section~\\ref{sec:results} (saturated FE), deaths per 100,000 per unit of the term (per month for the bin counts); SEs clustered by state in parentheses. N = ", fmt_int(reg_nobs), ". ", star_note)),
  "",
  "",
  coef_longtable(coef_rows_main, paste0("The same coefficients without the state $\\times$ year $\\times$ age FE; SEs clustered by state in parentheses. N = ", fmt_int(main_nobs), ". ", star_note)),

  "\\end{document}"
)

# every table inside adjustbox, so none is cut off at the margin in Overleaf
tex <- ifelse(startsWith(tex, "\\begin{tabular}"), paste0("\\begin{adjustbox}{max width=\\textwidth}\n", tex), tex)
tex <- ifelse(tex == "\\end{tabular}", "\\end{tabular}\n\\end{adjustbox}", tex)

writeLines(tex, TEX_FILE)

message("wrote: ", TEX_FILE)
