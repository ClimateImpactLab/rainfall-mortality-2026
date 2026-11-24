# ============================================================
# USA mortality regs: monthly precip bins vs monthly flow bins, death year only
#
# Which explains mortality better: months in precip bins or months in flow
# bins? Three regs, same rows:
#   baseline    temp + wind, no rain term (the reference for the R2 gains)
#   prcp_bins   + months in each precip bin: <50 | 50-100 (ref) | 100-150 | 150-200 | >=200 mm
#   flow_bins   + months in each flow bin:   <100 | 100-1k (ref) | 1k-10k | 10k-100k | >=100k mm
# Edges: 01_measures/05_build_monthly_precip_flow_bins.R.
#
# A bin coefficient = change in the death rate from moving one month of the
# death year out of the ref bin into that bin.
#
# Set up like 04_usa_monthly_bins_regs_OLD.R: fit_response(), temp poly order 2
# x age, wind controls x age, bins x age, saturated FE (county x age, year x
# age, state x year x age), levels, pop weights, SEs clustered by state. Death
# year only, no lags or lead. No precip poly in any of the three, so the two
# bin sets are compared on similar levels. 
#
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

panel_file  <- file.path(DATA_DIR, "climate_data/ERA5-LAND/flows/usa_annual/usa_annual_flow_regression_panel.rds")
counts_file <- file.path(DATA_DIR, "climate_data/ERA5-LAND/flows/annual_from_monthly_precip_flow_bins/era5land_admin_precip_flow_bins_usa.rds")

flow_out    <- file.path(DIR_REPO_RAINFALL_MORTALITY, "output/data/flows/usa-annual")
main_models <- file.path(flow_out, paste0("usa_flow_models_", main_run_id, ".csv"))
out_dir     <- file.path(flow_out, "precip_flow_bins")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)


# Settings ---------------------------

first_year <- 1968 # as in 02_usa_flow_regs.R
last_year  <- 2010
prcp_order <- 3   

wind_vars <- switch(wind_control,
                    none     = character(),
                    windmax  = "windmax_pop_annual",
                    winddays = "winddays_17p5_pop_annual",
                    both     = c("windmax_pop_annual", "winddays_17p5_pop_annual"))
wind_terms <- if (length(wind_vars)) paste0("i(agegroup, ", wind_vars, ")") else character()

# the 4 non-ref bins of each set, with edges in mm (same as 05)
bin_terms <- tribble(
  ~set_id,     ~variable, ~bin,       ~bin_label,  ~lower, ~upper,
  "prcp_bins", "prcp",    "lt50",     "<50",       -Inf,   50,
  "prcp_bins", "prcp",    "100_150",  "100-150",   100,    150,
  "prcp_bins", "prcp",    "150_200",  "150-200",   150,    200,
  "prcp_bins", "prcp",    "ge200",    ">=200",     200,    Inf,
  "flow_bins", "flow",    "lt100",    "<100",      -Inf,   100,
  "flow_bins", "flow",    "1k_10k",   "1k-10k",    1000,   10000,
  "flow_bins", "flow",    "10k_100k", "10k-100k",  10000,  100000,
  "flow_bins", "flow",    "ge100k",   ">=100k",    100000, Inf
) %>%
  mutate(coef_var = paste0(variable, "mon_bin_", bin, "_pop"))

sets <- tribble(
  ~set_id,     ~set_label,
  "baseline",  "Temp + wind, no rain term",
  "prcp_bins", "Monthly precip bins",
  "flow_bins", "Monthly flow bins"
)

spec <- filter(new_panel_specs, spec_id == !!spec_id)
stopifnot(nrow(spec) == 1)


# 1. Load panel and bin counts ---------------------------

panel <- readRDS(panel_file)

# wind columns are stored as text in the panel; stop if any value isn't a number
for (v in wind_vars) {
  x <- suppressWarnings(as.numeric(panel[[v]]))
  if (any(is.na(x) & !is.na(panel[[v]]))) stop(v, " has values that are not numbers")
  panel[[v]] <- x
}

counts <- readRDS(counts_file)
stopifnot(!anyDuplicated(counts[c("admin_id", "year")]),
          !any(bin_terms$coef_var %in% names(panel))) # the join can't overwrite a panel column

df_all <- left_join(panel, counts, by = c("admin_id", "year"))
stopifnot(nrow(df_all) == nrow(panel))
rm(panel)

# in the reg years: flow counts come from the same 12 months as the annual
# flow, so they're missing exactly where flowmean_pop_annual is. precip counts
# can't add missing rows on top of that
in_years <- df_all$year >= first_year & df_all$year <= last_year
no_flow  <- is.na(df_all$flowmean_pop_annual[in_years])
for (v in bin_terms$coef_var) {
  miss <- is.na(df_all[[v]][in_years])
  if (startsWith(v, "flow") && !identical(miss, no_flow)) stop(v, " and flowmean_pop_annual are missing in different rows")
  if (startsWith(v, "prcp") && any(miss & !no_flow)) stop(v, " is missing in rows that have annual flow")
}


# 2. Sample ---------------------------

df <- df_all %>%
  filter(year >= first_year, year <= last_year) %>%
  filter_regression_sample(tavg_order = 2, prcp_order = prcp_order,
                           extra_vars = c(wind_vars, bin_terms$coef_var))
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
  vars <- bin_terms$coef_var[bin_terms$set_id == s]
  # baseline has no bins. the if matters: paste0() on an empty vector still
  # returns "i(agegroup, )", which fixest can't parse
  bin_regs <- if (length(vars)) paste0("i(agegroup, ", vars, ")") else character()
  fit_response(df,
               tavg_order = 2,
               prcp_order = 0,
               fe         = unlist(spec$fe, use.names = FALSE),
               controls   = c(bin_regs, wind_terms),
               weights    = if (weighted) ~weight else NULL,
               cluster    = ~adm1_code,
               log_mort   = log_mort)
})

# clustered vcov without fixest's eigenvalue floor, as in the main regs
vcovs <- map(fits, ~ vcov(.x, cluster = ~adm1_code, vcov_fix = FALSE))


# 4. Coefficients ---------------------------

age_labels <- c("1" = "0-4", "2" = "5-64", "3" = "65+")

coefs <- map_dfr(c("prcp_bins", "flow_bins"), function(s) {
  b <- coef(fits[[s]]); v <- vcovs[[s]]
  bin_terms %>%
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

if (anyNA(coefs$estimate)) warning("some bin terms were dropped by fixest, see the NA rows")


# 5. Fit ---------------------------

models <- imap_dfr(fits, function(fit, s) {
  r2s <- r2(fit, type = c("wr2", "war2"))
  tibble(set_id     = s,
         spec_id    = spec$spec_id,
         sample_rows = nrow(df),
         nobs       = nobs(fit),
         counties   = n_distinct(df$admin_code),
         state_clusters = n_states,
         bin_terms  = sum(grepl("mon_bin_", names(coef(fit)))),
         within_r2  = unname(r2s["wr2"]),
         within_adj_r2 = unname(r2s["war2"]),
         formula    = paste(deparse(formula(fit), width.cutoff = 500L), collapse = " "))
}) %>%
  mutate(within_r2_gain     = within_r2 - within_r2[set_id == "baseline"],
         within_adj_r2_gain = within_adj_r2 - within_adj_r2[set_id == "baseline"],
         outcome_model = outcome_model, weighted = weighted, wind_control = wind_control) %>%
  left_join(sets, by = "set_id")

# 6. Save ---------------------------

print(select(models, set_id, nobs, bin_terms, within_r2, within_adj_r2, within_r2_gain, within_adj_r2_gain), width = Inf)
print(select(coefs, set_id, age_label, bin_label, estimate, se, p_value), n = Inf, width = Inf)

write_csv(coefs,  file.path(out_dir, paste0("usa_precip_flow_bins_coefficients_", run_id, ".csv")))
write_csv(models, file.path(out_dir, paste0("usa_precip_flow_bins_models_", run_id, ".csv")))

message("wrote: ", out_dir)
