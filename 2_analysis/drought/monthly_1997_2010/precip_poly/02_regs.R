# ============================================================================
# 02_regs.R
#
# Brazil monthly mortality regs with precip only, 1997-2010.
# FE Poisson on monthly deaths, log(pop) offset, SEs clustered by state.
# Rainfall and temp terms all x age group.
#
# Three ways of measuring a month's rainfall, each run on its own, with this
# month + 11 lags + 6 leads (placebo):
#   daily     daily rainfall, ^2, ^3 summed over the month (main spec:
#             what matters is heavy days)
#   monthly   monthly total, ^2, ^3 (what matters is how wet or dry the month
#             is as a whole). A check (results not shown)
#   spi       SPI dry side and wet side, as in the drought regs
#
# Options (--fe_spec, --temp): see "Options and paths" below.
#
# Output: output/data/precip-monthly/1997_2010/
#   precip_monthly_<model>_<fe_spec>_temp-<temp>.rds   coefs and vcov of the rainfall terms
#   precip_monthly_fit_<fe_spec>_temp-<temp>.csv       fit and the joint tests (on lag sums)
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

# --fe_spec = main (default) | saturated | statemonth | seasontrend, same as
#   ../03_monthly_regs.R
# --temp = lags (default) | current: temp this month + 11 lags, or this
#   month only (does past heat drive any of the rainfall effects?)
args <- commandArgs(trailingOnly = TRUE)
fe_spec <- sub("^--fe_spec=", "", c(grep("^--fe_spec=", args, value = TRUE), "--fe_spec=main")[1])
temp <- sub("^--temp=", "", c(grep("^--temp=", args, value = TRUE), "--temp=lags")[1])
run_label <- paste0(fe_spec, "_temp-", temp)

# Use the CPUs given by Slurm (fixest otherwise counts the whole node)
setFixest_nthreads(as.integer(Sys.getenv("SLURM_CPUS_PER_TASK", "1")))

# Panel from 01_build_panel.R, and where the results go
PANEL_FILE <- paste0(
  "/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/",
  "precip_monthly/brazil_precip_monthly_panel_1997_2010.rds"
)
OUTPUT_DIR <- "/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/output/data/precip-monthly/1997_2010"
dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)


# -----------------------------
# Regression setup
# -----------------------------

# FE for each --fe_spec (same as ../03_monthly_regs.R)
fe <- c("admin_code^agegroup^month", "year_month^agegroup")
if (fe_spec == "saturated") fe <- c(fe, "adm1_code^year^agegroup")
if (fe_spec == "statemonth") fe <- c("admin_code^agegroup^month", "adm1_code^year_month^agegroup")

# Season trend: year_c centres the trend (doesn't change results)
df_season_fe <- function(df) mutate(df, year_c = year - 2003)
if (fe_spec == "seasontrend") fe <- c("admin_code^agegroup^month[year_c]", "year_month^agegroup", "adm1_code^year^agegroup")

# this month + 11 lags (12 months), and 6 leads, for one base variable
lags_of <- function(v) c(v, paste0(v, "_lag", 1:11))
leads_of <- function(v) paste0(v, "_lead", 1:6)

# The three models and the base rainfall terms in each
models <- list(
  daily = c("rain_d1", "rain_d2", "rain_d3"),
  monthly = c("rain_d1", "rain_m2", "rain_m3"),
  spi = c("spi_dryside", "spi_wetside")
)

# Temp controls by age group: this month only, or this month + 11 lags
temp_vars <- if (temp == "lags") c(lags_of("tavg_1"), lags_of("tavg_2")) else c("tavg_1", "tavg_2")
temperature_terms <- paste0("i(agegroup, ", temp_vars, ")")

# Joint Wald test that the sums of several blocks of coefs are all zero,
# chi2 = (Rb)' (R V R')^-1 (Rb), one row of R per block 
# Tests are on sums (like the 12 coefs of rain_m2, this month + 11 lags, added up) 
# because with 27 state clusters the vcov of dozens of single coefs is singular
wald_sums <- function(fit, blocks) {
  b <- coef(fit)
  R <- t(sapply(blocks, function(names_b) as.numeric(names(b) %in% names_b)))
  Rb <- R %*% b
  stat <- as.numeric(t(Rb) %*% solve(R %*% vcov(fit) %*% t(R)) %*% Rb)
  tibble(n_terms = length(blocks), chi2 = stat, p_value = pchisq(stat, length(blocks), lower.tail = FALSE))
}


# -----------------------------
# Read panel
# -----------------------------

# Drop rows with no deaths data or zero population (log(pop) offset)
df <- readRDS(PANEL_FILE) %>%
  filter(!is.na(deaths), population > 0) %>%
  df_season_fe()

# Sample size and spec, to the log
message(
  "Brazil monthly sample: ", nrow(df), " rows | ", n_distinct(df$admin_code), " ADM2s | ",
  min(df$year), "-", max(df$year), " | FE: ", paste(fe, collapse = " + "), " | temp: ", temp
)


# -----------------------------
# Estimate
# -----------------------------

fit_results <- list()

for (model in names(models)) {
  message("Running: ", model)
  rain_terms <- unlist(lapply(models[[model]], function(v) c(lags_of(v), leads_of(v))))

  # deaths ~ temp x age + rainfall terms x age, log(pop) offset, FE
  rhs <- c(temperature_terms, paste0("i(agegroup, ", rain_terms, ")"))
  f <- as.formula(paste(
    "deaths ~", paste(rhs, collapse = " + "), "+ offset(log(population)) |",
    paste(fe, collapse = " + ")
  ))
  fit <- fepois(f, data = df, cluster = ~adm1_code)

  # Keep only the rainfall coefs and their vcov, for the response curves
  rain_names <- grep(":(rain|spi)_", names(coef(fit)), value = TRUE)
  saveRDS(
    list(model = model, fe_spec = fe_spec, temp = temp, coef = coef(fit)[rain_names],
         vcov = vcov(fit)[rain_names, rain_names], nobs = nobs(fit)),
    file.path(OUTPUT_DIR, paste0("precip_monthly_", model, "_", run_label, ".rds"))
  )

  # Joint tests by age, on the sums over this month + 11 lags of each rainfall
  # term, and on the sums over the 6 leads (placebo)
  tests <- list(lags = models[[model]], leads = models[[model]])

  for (age in levels(df$agegroup)) {
    for (test in names(tests)) {
      blocks <- lapply(tests[[test]], function(v) {
        terms <- if (test == "leads") leads_of(v) else lags_of(v)
        paste0("agegroup::", age, ":", terms)
      })
      fit_results[[length(fit_results) + 1]] <- wald_sums(fit, blocks) %>%
        mutate(model, fe_spec, temp, agegroup = age, test, .before = 1)
    }
  }

  # Fit, for comparing the models on the same sample
  fit_results[[length(fit_results) + 1]] <- tibble(
    model, fe_spec, temp, agegroup = "all", test = "fit",
    n_terms = length(rain_names), loglik = as.numeric(logLik(fit)),
    bic = BIC(fit), pseudo_r2 = as.numeric(fitstat(fit, "pr2")), nobs = nobs(fit)
  )
}


# -----------------------------
# Write results
# -----------------------------

# Fit and joint tests of all three models, one CSV per run
write_csv(bind_rows(fit_results), file.path(OUTPUT_DIR, paste0("precip_monthly_fit_", run_label, ".csv")))
message("wrote: ", OUTPUT_DIR)
