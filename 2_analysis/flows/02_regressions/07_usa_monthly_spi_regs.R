# ============================================================
# USA mortality regs: the monthly-built terms in one run, death year only: the
# raw-level bin counts, the SPI-1 bin counts, the annual SPI-12, the weighted sums and the squared z-score sums
#
# Terms built from the months (sum_m g(X_m)), not from the annual value. Same
# rows in every reg, so the sets can be compared:
#   baseline          temp + wind, no rain term (reference for the R2 gains)
# Monthly-built, for precip (prcp) and for flow (flow):
#   *_raw_bins        months per raw-level bin, from
#                     01_measures/05_build_monthly_precip_flow_bins.R (the
#                     bins of 06_usa_precip_flow_bins_regs.R, which is left as
#                     it is): precip <50 | 50-100 (ref) | 100-150 | 150-200 | >=200 mm,
#                     flow <100 | 100-1k (ref) | 1k-10k | 10k-100k | >=100k mm
#   *_pct_bins        months per county-percentile bin, from 05_ with --scheme=percentile: each
#                     month's percentile among the same county's months over the rolling prior
#                     20 years (calendar months pooled), cut at the 10th, 25th, 75th and 90th
#                     percentile (bins and ref hard-coded below, as 05_ builds them)
# From 01_measures/06_build_monthly_spi_measures.R (rolling prior-20-year baseline):
#   *_spi12           SPI-12 of the calendar-year total, two-sided: a drought term
#                     max(0, -SPI-12) and a wet-year term max(0, SPI-12)
#   *_wsum            weighted dry and wet sums: 12 x sum over months of s_m max(0, -SPI-1)
#                     (dry) and s_m max(0, SPI-1) (wet), s_m = the month's usual share of
#                     the year's rain (flow)
#   *_spi_counts      months per SPI bin: <-2 | [-2,-1.5) | [-1.5,-1) | [-1,1) (ref)
#                     | [1,1.5) | [1.5,2) | >=2
#   *_z2, *_z2cap     squared monthly z-score, dry and wet sums: sum over months of
#                     min(z,0)^2 and of max(z,0)^2, z against the same rolling baseline.
#                     _z2 uncapped, _z2cap with z capped at the SPI bound (about 3.7),
#                     because z is very large in dry-season months (skewed rain and flow)
#
# Set up like 06_usa_precip_flow_bins_regs.R: fit_response(), temp poly order
# 2 x age, wind controls x age, terms x age, saturated FE (county x age, year x
# age, state x year x age), levels, pop weights, SEs clustered by state. Death
# year only, no lags or lead. No precip poly in any reg.
#
# Inputs:  annual regression panel; annual_from_monthly_spi/ (06_ measures);
#          annual_from_monthly_precip_flow_bins/ (05_ measures)
# Outputs: output/data/flows/usa-annual/monthly_spi/usa_monthly_spi_{coefficients,models}_<run_id>.csv
# Dependencies: dplyr, tidyr, readr, purrr, glue, fixest; 0_utils/functions.R
# ============================================================

library(dplyr)
library(tidyr)
library(readr)
library(purrr)
library(glue)
library(fixest)

# options, as in 02_usa_flow_regs.R
args    <- commandArgs(FALSE)
get_arg <- function(name, default) {
  hit <- grep(paste0("^--", name, "="), args, value = TRUE)
  if (length(hit) == 0) default else sub(paste0("^--", name, "="), "", hit[[1]])
}

outcome_model <- get_arg("outcome_model", "levels")
weighted      <- tolower(get_arg("weighted", "true")) %in% c("true", "t", "1", "yes")
wind_control  <- get_arg("wind_control", "both")
spec_id       <- get_arg("spec", "saturated")
log_mort      <- outcome_model == "poisson"

run_id <- paste(outcome_model, if (weighted) "weighted" else "unweighted", sep = "_")
if (wind_control != "none") run_id <- paste(run_id, wind_control, sep = "_")

# the main regs' models csv (sample check) is named without the spec
main_run_id <- run_id
if (spec_id != "saturated") run_id <- paste(run_id, spec_id, sep = "_")

# set paths
USER <- Sys.getenv("USER")
source("../../../0_utils/paths.R")                   # DATA_DIR, DIR_REPO_RAINFALL_MORTALITY
source("../../../0_utils/functions.R")               # fit_response()
source("../../regressions/00_prep_analysis_panel.R") # filter_regression_sample(), new_panel_specs

panel_file <- file.path(DATA_DIR, "climate_data/ERA5-LAND/flows/usa_annual/usa_annual_flow_regression_panel.rds")
spi_file   <- file.path(DATA_DIR, "climate_data/ERA5-LAND/flows/annual_from_monthly_spi/era5land_admin_monthly_spi_usa.rds")
bins_file  <- file.path(DATA_DIR, "climate_data/ERA5-LAND/flows/annual_from_monthly_precip_flow_bins/era5land_admin_precip_flow_bins_usa.rds")
# the county-percentile bins: the tag 05_ puts in the file name for --scheme=percentile --probs=0.1,0.25,0.75,0.9
pct_bins_tag  <- "_pct_roll20_p10_25_75_90"
pct_bins_file <- sub("\\.rds$", paste0(pct_bins_tag, ".rds"), bins_file)

flow_out    <- file.path(DIR_REPO_RAINFALL_MORTALITY, "output/data/flows/usa-annual")
main_models <- file.path(flow_out, paste0("usa_flow_models_", main_run_id, ".csv"))
out_dir     <- file.path(flow_out, "monthly_spi")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)


# Settings ---------------------------

first_year <- 1968 # as in 02_usa_flow_regs.R
last_year  <- 2010
prcp_order <- 3 # only for the sample filter, as in 02_ and 06_ (no precip poly in the regs)

wind_vars <- switch(wind_control,
                    none     = character(),
                    windmax  = "windmax_pop_annual",
                    winddays = "winddays_17p5_pop_annual",
                    both     = c("windmax_pop_annual", "winddays_17p5_pop_annual"))
wind_terms <- if (length(wind_vars)) paste0("i(agegroup, ", wind_vars, ")") else character()

# SPI bins, same as 06_build_monthly_spi_measures.R (ref bin left out)
spi_bins <- tribble(
  ~bin,       ~bin_label,   ~lower, ~upper,
  "lt_m2",    "<-2",        -Inf,   -2,
  "m2_m1p5",  "-2 to -1.5", -2,     -1.5,
  "m1p5_m1",  "-1.5 to -1", -1.5,   -1,
  "p1_p1p5",  "1 to 1.5",   1,      1.5,
  "p1p5_p2",  "1.5 to 2",   1.5,    2,
  "ge_p2",    ">=2",        2,      Inf
)

# One row per term: the set it is in, the column, and a label. The monthly sets
# are built for precip and flow
monthly_terms <- map_dfr(c(prcp = "Precip", flow = "Flow"), .id = "variable", function(lab) {
  bind_rows(
    mutate(spi_bins, kind = "counts", suffix = paste0("spi_bin_", bin, "_pop"), term_label = bin_label)
  ) %>% mutate(source_label = lab)
}) %>%
  mutate(set_id   = paste0(variable, "_spi_counts"),
         coef_var = paste0(variable, suffix))

# raw-level bins, the non-ref bins of 05_build_monthly_precip_flow_bins.R (same
# edges as 06_usa_precip_flow_bins_regs.R)
raw_terms <- tribble(
  ~variable, ~bin,       ~bin_label,   ~lower, ~upper,
  "prcp",    "lt50",     "<50",        -Inf,   50,
  "prcp",    "100_150",  "100-150",    100,    150,
  "prcp",    "150_200",  "150-200",    150,    200,
  "prcp",    "ge200",    ">=200",      200,    Inf,
  "flow",    "lt100",    "<100",       -Inf,   100,
  "flow",    "1k_10k",   "1k-10k",     1000,   10000,
  "flow",    "10k_100k", "10k-100k",   10000,  100000,
  "flow",    "ge100k",   ">=100k",     100000, Inf
) %>%
  mutate(set_id = paste0(variable, "_raw_bins"), kind = "raw_bins",
         source_label = if_else(variable == "prcp", "Precip", "Flow"),
         coef_var = paste0(variable, "mon_bin_", bin, "_pop"),
         term_label = bin_label)

# the county-percentile bins, hard-coded: must match 05_ with --scheme=percentile --probs=0.1,0.25,0.75,0.9
# (bin p25_75 is the reference; column names as 05_ builds them)
pct_def <- crossing(variable = c("prcp", "flow"),
                      tibble(bin = c("p00_10", "p10_25", "p25_75", "p75_90", "p90_100"),
                             lower = c(-Inf, 0.1, 0.25, 0.75, 0.9), upper = c(0.1, 0.25, 0.75, 0.9, Inf))) %>%
  arrange(desc(variable), lower) %>%
  mutate(scheme = "percentile", reference = bin == "p25_75", column = paste0(variable, "pct_bin_", bin, "_pop")) %>%
  select(variable, scheme, bin, lower, upper, reference, column)

# county-percentile bins: the non-reference bins
pct_terms <- pct_def %>%
  filter(!reference) %>%
  mutate(set_id = paste0(variable, "_pct_bins"), kind = "pct_bins",
         source_label = if_else(variable == "prcp", "Precip", "Flow"),
         coef_var = column, bin_label = bin, term_label = bin) %>%
  select(set_id, kind, variable, source_label, coef_var, bin, bin_label, term_label, lower, upper)

# annual terms from the same file as the SPI bin counts: the SPI-12 sides, the weighted dry and wet sums
# and the squared z-score sums. Within a set: the dry term, then the wet term
annual_terms <- bind_rows(
  crossing(variable = c("prcp", "flow"),
           tibble(kind = "spi12", suffix = c("spi12_dry_pop", "spi12_wet_pop"),
                  term_label = c("Drought: max(0, -SPI-12)", "Wet year: max(0, SPI-12)"))),
  crossing(variable = c("prcp", "flow"),
           tibble(kind = "wsum", suffix = c("wdry_pop", "wwet_pop"),
                  term_label = c("Weighted dry sum", "Weighted wet sum"))),
  crossing(variable = c("prcp", "flow"),
           tibble(kind = "z2", suffix = c("z2_dry_sum_pop", "z2_wet_sum_pop"),
                  term_label = c("Squared z-score, dry sum", "Squared z-score, wet sum"))),
  crossing(variable = c("prcp", "flow"),
           tibble(kind = "z2cap", suffix = c("z2cap_dry_sum_pop", "z2cap_wet_sum_pop"),
                  term_label = c("Capped squared z-score, dry sum", "Capped squared z-score, wet sum")))
) %>%
  mutate(set_id = paste0(variable, "_", kind),
         source_label = if_else(variable == "prcp", "Precip", "Flow"),
         coef_var = paste0(variable, suffix)) %>%
  arrange(set_id, suffix)

terms <- bind_rows(raw_terms, pct_terms, monthly_terms, annual_terms) %>%
  select(set_id, variable, source_label, coef_var, term_label, any_of(c("bin", "bin_label", "lower", "upper")))

set_ids <- c("baseline", unique(terms$set_id))
sets <- tibble(set_id = set_ids) %>%
  mutate(set_label = case_when(
    set_id == "baseline" ~ "Temp + wind, no rain term",
    TRUE ~ paste(
      case_when(startsWith(set_id, "prcp_") ~ "Monthly precip",
                startsWith(set_id, "flow_") ~ "Monthly flow"),
      case_when(grepl("raw_bins", set_id)     ~ "raw-level bin counts",
                grepl("pct_bins", set_id)     ~ "county-percentile bin counts",
                grepl("spi12", set_id)        ~ "SPI-12, drought and wet-year terms",
                grepl("wsum", set_id)         ~ "weighted dry and wet sums",
                grepl("z2cap", set_id)        ~ "capped squared z-score, dry and wet sums",
                grepl("z2", set_id)           ~ "squared z-score, dry and wet sums",
                grepl("spi_counts", set_id)   ~ "SPI-1 bin counts"))))

spec <- filter(new_panel_specs, spec_id == !!spec_id)
stopifnot(nrow(spec) == 1)


# 1. Load panel and monthly-built terms ---------------------------

# raw-level and county-percentile bin counts (05_) and SPI terms (06_), joined onto the panel below

panel <- readRDS(panel_file)

# wind columns are stored as text in the panel; stop if any value isn't a number
for (v in wind_vars) {
  x <- suppressWarnings(as.numeric(panel[[v]]))
  if (any(is.na(x) & !is.na(panel[[v]]))) stop(v, " has values that are not numbers")
  panel[[v]] <- x
}

spi_m  <- readRDS(spi_file)
bins_m <- readRDS(bins_file)
pct_bins_m <- readRDS(pct_bins_file)
monthly_vars <- c(monthly_terms$coef_var, annual_terms$coef_var, raw_terms$coef_var, pct_terms$coef_var)
stopifnot(!anyDuplicated(spi_m[c("admin_id", "year")]),
          !anyDuplicated(bins_m[c("admin_id", "year")]),
          !anyDuplicated(pct_bins_m[c("admin_id", "year")]),
          all(pct_terms$coef_var %in% names(pct_bins_m)),
          all(c(monthly_terms$coef_var, annual_terms$coef_var) %in% names(spi_m)),
          all(raw_terms$coef_var %in% names(bins_m)),
          !any(monthly_vars %in% names(panel))) # the join can't overwrite a panel column

df_all <- panel %>%
  left_join(select(spi_m, admin_id, year, all_of(c(monthly_terms$coef_var, annual_terms$coef_var))), by = c("admin_id", "year")) %>%
  left_join(select(bins_m, admin_id, year, all_of(raw_terms$coef_var)), by = c("admin_id", "year")) %>%
  left_join(select(pct_bins_m, admin_id, year, all_of(pct_terms$coef_var)), by = c("admin_id", "year"))
stopifnot(nrow(df_all) == nrow(panel))
rm(panel)

# in the reg years the monthly terms must not drop any row that has annual flow
in_years <- df_all$year >= first_year & df_all$year <= last_year
has_flow <- !is.na(df_all$flowmean_pop_annual[in_years])
for (v in monthly_vars) {
  if (any(is.na(df_all[[v]][in_years]) & has_flow)) stop(v, " is missing in rows that have annual flow")
}


# 2. Sample ---------------------------

df <- df_all %>%
  filter(year >= first_year, year <= last_year) %>%
  filter_regression_sample(tavg_order = 2, prcp_order = prcp_order,
                           extra_vars = c(wind_vars, terms$coef_var))
rm(df_all)

main_rows <- unique(read_csv(main_models, show_col_types = FALSE)$sample_rows)
if (length(main_rows) != 1 || nrow(df) != main_rows) {
  stop("sample has ", nrow(df), " rows but 02_usa_flow_regs.R used ", paste(main_rows, collapse = ", "))
}

n_states <- n_distinct(df$adm1_code)
message(glue("sample: {nrow(df)} rows | {n_distinct(df$admin_code)} counties | {n_states} states | ",
             "{min(df$year)}-{max(df$year)} | run {run_id}"))


# 3. Regressions ---------------------------

ages <- levels(df$agegroup)

fits <- map(set_names(sets$set_id), function(s) {
  print(paste0("==== running ", s, " ===="))
  vars <- terms$coef_var[terms$set_id == s]
  # baseline has no terms. the if matters: paste0() on an empty vector still
  # returns "i(agegroup, )", which fixest can't parse
  term_regs <- if (length(vars)) paste0("i(agegroup, ", vars, ")") else character()
  fit_response(df,
               tavg_order = 2,
               prcp_order = 0,
               fe         = unlist(spec$fe, use.names = FALSE),
               controls   = c(term_regs, wind_terms),
               weights    = if (weighted) ~weight else NULL,
               cluster    = ~adm1_code,
               log_mort   = log_mort)
})

# clustered vcov without fixest's eigenvalue floor, as in the main regs
vcovs <- map(fits, ~ vcov(.x, cluster = ~adm1_code, vcov_fix = FALSE))


# 4. Coefficients ---------------------------

age_labels <- c("1" = "0-4", "2" = "5-64", "3" = "65+")

coefs <- map_dfr(setdiff(sets$set_id, "baseline"), function(s) {
  b <- coef(fits[[s]]); v <- vcovs[[s]]
  terms %>%
    filter(set_id == s) %>%
    crossing(agegroup = ages) %>%
    mutate(term     = paste0("agegroup::", agegroup, ":", coef_var),
           estimate = unname(b[term]),           # NA if fixest dropped the term
           se       = sqrt(unname(diag(v)[term])))
}) %>%
  mutate(age_label = unname(age_labels[agegroup]),
         p_value   = 2 * pnorm(-abs(estimate / se)),
         lo        = estimate - 1.96 * se,
         hi        = estimate + 1.96 * se) %>%
  left_join(sets, by = "set_id")

if (anyNA(coefs$estimate)) warning("some terms were dropped by fixest, see the NA rows")


# 5. Fit ---------------------------

models <- imap_dfr(fits, function(fit, s) {
  r2s <- r2(fit, type = c("wr2", "war2"))
  tibble(set_id     = s,
         spec_id    = spec$spec_id,
         sample_rows = nrow(df),
         nobs       = nobs(fit),
         counties   = n_distinct(df$admin_code),
         state_clusters = n_states,
         n_terms    = sum(terms$set_id == s) * length(ages),
         within_r2  = unname(r2s["wr2"]),
         within_adj_r2 = unname(r2s["war2"]),
         formula    = paste(deparse(formula(fit), width.cutoff = 500L), collapse = " "))
}) %>%
  mutate(within_r2_gain     = within_r2 - within_r2[set_id == "baseline"],
         within_adj_r2_gain = within_adj_r2 - within_adj_r2[set_id == "baseline"],
         outcome_model = outcome_model, weighted = weighted, wind_control = wind_control) %>%
  left_join(sets, by = "set_id")


# 6. Save ---------------------------

print(select(models, set_id, nobs, n_terms, within_r2, within_adj_r2, within_r2_gain, within_adj_r2_gain), n = Inf, width = Inf)
print(select(coefs, set_id, age_label, term_label, estimate, se, p_value), n = Inf, width = Inf)

write_csv(coefs,  file.path(out_dir, paste0("usa_monthly_spi_coefficients_", run_id, ".csv")))
write_csv(models, file.path(out_dir, paste0("usa_monthly_spi_models_", run_id, ".csv")))

message("wrote: ", out_dir)
