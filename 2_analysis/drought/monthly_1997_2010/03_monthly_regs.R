# ============================================================================
# 03_monthly_regs.R
#
# Brazil monthly mortality regs with drought, 1997-2010. FE Poisson on
# monthly deaths, log(pop) offset, unweighted, SEs clustered by state.
#
# Each drought measure x age group is run on its own, with temp x age:
#   spi01_lags         monthly SPI, this month + 11 lags + 6 leads (placebo)
#   spi01_dry_wet      same, split into a dry side and a wet side
#   spi01_dry_wet_24   same with 23 lags, to see if the dry placebo comes
#                      from older droughts
#   spi03/06/12        SPI over the last 3/6/12 months + the next 3/6/12
#                      (placebo)
#   dry10_6m/dry05_6m  6-month rainfall below p10 / p5 + the next 6 months
#                      (placebo)
#
# The 12 monthly coefs are also summed (effect over a full year), and so are
# the 6 leads (placebo).
#
# Options (--period, --years, --region, --fe_spec): see "Options and paths"
# below.
#
# Output: output/data/drought/brazil-monthly/<period>/
#   brazil_monthly_drought_coefficients_<fe_spec>.csv
#   brazil_monthly_drought_lag_sums_<fe_spec>.csv
#   brazil_monthly_drought_models_<fe_spec>.csv
# ============================================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(readr)
library(fixest)


# -----------------------------
# Options and paths
# -----------------------------

args <- commandArgs(trailingOnly = TRUE)
# Read one option from the command line, for ex --fe_spec=saturated gives
# "saturated". If the option isn't given, use the default
get_arg <- function(name, default) {
  hit <- sub(paste0("^--", name, "="), "", args[grepl(paste0("^--", name, "="), args)])
  if (length(hit) == 0) default else hit[[1]]
}

# --period = 1997_2010 (default) | 2000_2024
# --years = all (default) | start_end, for ex 2000_2010: keep only those years
#   of the panel (lags still come from the months before)
# --region = all (default) | northeast | rest: keep only the Northeast
#   (states 21-29) or only the rest of Brazil
# --fe_spec = main (default) | saturated | statemonth | seasontrend
#   main: municipality x age x calendar month (each place's seasonality)
#     + year-month x age (shocks common to all of Brazil)
#   saturated: main + state x year x age (compare within state-year)
#   statemonth: municipality x age x calendar month + state x year-month x
#     age (compare within state and month)
#   seasontrend: saturated, but each place's seasonal pattern can drift
#     slowly over the years (health programs, vaccines, sanitation reaching
#     places at different times). Checks whether the dry placebo and the
#     9-11 month dip come from that drift
period <- get_arg("period", "1997_2010")
years <- get_arg("years", "all")
region <- get_arg("region", "all")
fe_spec <- get_arg("fe_spec", "main")

# Use the CPUs given by Slurm (fixest otherwise counts the whole node)
setFixest_nthreads(as.integer(Sys.getenv("SLURM_CPUS_PER_TASK", "1")))

# Panel from 02_build_panel.R
PANEL_FILE <- paste0(
  "/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/",
  "brazil_monthly/brazil_monthly_drought_regression_panel_", period, ".rds"
)

OUTPUT_DIR <- sub("/$", "", file.path(
  "/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/output/data/drought/brazil-monthly",
  period,
  # Subfolders for a year or region subset, for ex 1997_2010/region_northeast
  paste(c(if (years != "all") paste0("years_", years), if (region != "all") paste0("region_", region)), collapse = "/")
))
dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)


# -----------------------------
# Regression setup
# -----------------------------

# FE for each --fe_spec (see header)
fe <- c("admin_code^agegroup^month", "year_month^agegroup")
if (fe_spec == "saturated") fe <- c(fe, "adm1_code^year^agegroup")
if (fe_spec == "statemonth") fe <- c("admin_code^agegroup^month", "adm1_code^year_month^agegroup")
# Season trend: year_c centres the trend (doesn't change results)
df_season_fe <- function(df) mutate(df, year_c = year - 2003)
if (fe_spec == "seasontrend") fe <- c("admin_code^agegroup^month[year_c]", "year_month^agegroup", "adm1_code^year^agegroup")

# Temp controls by age group: this month's temp and temp^2
temperature_terms <- c("i(agegroup, tavg_poly_1)", "i(agegroup, tavg_poly_2)")

# Names of the SPI terms: this month + 11 lags, and the 6 leads. Same names
# for the dry side and the wet side
lag_terms <- c("spi01_dry", paste0("spi01_dry_lag", 1:11))
lead_terms <- paste0("spi01_dry_lead", 1:6)
dry_lag_terms <- sub("spi01_dry", "spi01_dryside", lag_terms)
dry_lead_terms <- sub("spi01_dry", "spi01_dryside", lead_terms)
wet_lag_terms <- sub("spi01_dry", "spi01_wetside", lag_terms)
wet_lead_terms <- sub("spi01_dry", "spi01_wetside", lead_terms)

# 24-month version: this month + 23 lags, split in months 0-11 and 12-23
dry_lag_terms_24 <- c("spi01_dryside", paste0("spi01_dryside_lag", 1:23))
wet_lag_terms_24 <- c("spi01_wetside", paste0("spi01_wetside_lag", 1:23))

# Coefs summed for the lag sets: the lags (this month + the months before),
# and the 6 leads
sum_blocks <- list(
  spi01_lags = list(lags = lag_terms, leads = lead_terms),
  spi01_dry_wet = list(dry_lags = dry_lag_terms, dry_leads = dry_lead_terms,
                       wet_lags = wet_lag_terms, wet_leads = wet_lead_terms),
  spi01_dry_wet_24 = list(dry_lags_0_11 = dry_lag_terms_24[1:12], dry_lags_12_23 = dry_lag_terms_24[13:24],
                          dry_leads = dry_lead_terms,
                          wet_lags_0_11 = wet_lag_terms_24[1:12], wet_lags_12_23 = wet_lag_terms_24[13:24],
                          wet_leads = wet_lead_terms)
)

# One reg per row: its name and the drought terms in it
drought_sets <- tibble::tribble(
  ~set_id, ~terms,
  "spi01_lags", c(lag_terms, lead_terms),
  "spi01_dry_wet", c(dry_lag_terms, dry_lead_terms, wet_lag_terms, wet_lead_terms),
  "spi01_dry_wet_24", c(dry_lag_terms_24, dry_lead_terms, wet_lag_terms_24, wet_lead_terms),
  "spi03", c("spi03_dry", "spi03_dry_lead"),
  "spi06", c("spi06_dry", "spi06_dry_lead"),
  "spi12", c("spi12_dry", "spi12_dry_lead"),
  "dry10_6m", c("dry10_6m", "dry10_6m_lead"),
  "dry05_6m", c("dry05_6m", "dry05_6m_lead")
)


# -----------------------------
# Read panel
# -----------------------------

df <- readRDS(PANEL_FILE) %>%
  filter(!is.na(deaths), population > 0) %>%
  df_season_fe()
# Year subset: the period's panel cut to the years asked
if (years != "all") {
  year_range <- as.integer(strsplit(years, "_")[[1]])
  df <- filter(df, year >= year_range[1], year <= year_range[2])
}
# Region subset: Northeast or the rest of Brazil
if (region != "all") df <- filter(df, northeast == (region == "northeast"))

message(
  "Brazil monthly sample, ", period, ": ", nrow(df), " rows | ",
  n_distinct(df$admin_code), " ADM2s | ", min(df$year), "-", max(df$year),
  " | FE: ", paste(fe, collapse = " + ")
)


# -----------------------------
# Estimate
# -----------------------------

coef_results <- list()
sum_results <- list()
model_results <- list()

for (i in seq_len(nrow(drought_sets))) {
  set <- drought_sets[i, ]
  terms <- set$terms[[1]]
  message("Running: ", set$set_id)

  # deaths ~ temp x age + drought terms x age, log(pop) offset, FE
  rhs <- c(temperature_terms, paste0("i(agegroup, ", terms, ")"))
  f <- as.formula(paste(
    "deaths ~", paste(rhs, collapse = " + "), "+ offset(log(population)) |",
    paste(fe, collapse = " + ")
  ))
  fit <- fepois(f, data = df, cluster = ~adm1_code)

  # One row per drought term x age group
  ct <- as.data.frame(coeftable(fit))
  ct$term <- rownames(ct)
  coef_results[[i]] <- ct %>%
    mutate(variable = sub("^agegroup::[^:]+:", "", term)) %>%
    filter(variable %in% terms) %>%
    transmute(
      set_id = set$set_id, fe_spec, period, variable,
      agegroup = sub("^agegroup::([^:]+):.*$", "\\1", term),
      estimate = Estimate, std_error = `Std. Error`, p_value = `Pr(>|z|)`
    )

  # Lag sets: sum of this month + 11 lags, and sum of the 6 leads, by age.
  # SE of a sum = sqrt(a' V a), with a = 1 on the summed coefs.
  if (set$set_id %in% names(sum_blocks)) {
    V <- vcov(fit)
    for (age in levels(df$agegroup)) {
      for (block in names(sum_blocks[[set$set_id]])) {
        block_terms <- sum_blocks[[set$set_id]][[block]]
        names_b <- paste0("agegroup::", age, ":", block_terms)
        est <- sum(coef(fit)[names_b])
        se <- sqrt(sum(V[names_b, names_b]))
        sum_results[[length(sum_results) + 1]] <- tibble(
          set_id = set$set_id, fe_spec, period, agegroup = age, block, n_terms = length(block_terms),
          estimate = est, std_error = se, p_value = 2 * pnorm(-abs(est / se))
        )
      }
    }
  }

  # Sample size and fit of this reg
  model_results[[i]] <- tibble(
    set_id = set$set_id, fe_spec, period,
    nobs = nobs(fit),
    admin_units = n_distinct(df$admin_code),
    years = paste(range(df$year), collapse = "-"),
    adm1_clusters = n_distinct(df$adm1_code),
    # Poisson pseudo R2 (the within version needs a refit that fails with
    # these interacted FE)
    pseudo_r2 = as.numeric(fitstat(fit, "pr2"))
  )
}


# -----------------------------
# Write results
# -----------------------------

# One CSV each for the coefs, the lag sums and the model fit, per FE spec
write_csv(bind_rows(coef_results), file.path(OUTPUT_DIR, paste0("brazil_monthly_drought_coefficients_", fe_spec, ".csv")))
write_csv(bind_rows(sum_results), file.path(OUTPUT_DIR, paste0("brazil_monthly_drought_lag_sums_", fe_spec, ".csv")))
write_csv(bind_rows(model_results), file.path(OUTPUT_DIR, paste0("brazil_monthly_drought_models_", fe_spec, ".csv")))
message("wrote: ", OUTPUT_DIR)
