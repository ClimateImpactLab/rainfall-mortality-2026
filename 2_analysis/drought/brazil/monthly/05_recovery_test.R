# ============================================================================
# 05_recovery_test.R
#
# Can annual regs recover what the monthly regs find? Builds an annual panel
# by summing the monthly one (same municipalities, deaths and exposures), runs
# annual Poisson regs, and compares them to the monthly results. Also compares
# the three candidate annual drought terms.
#
# Annual exposures, each at t-2, t-1, t and t+1 (taken on the 1995-2011
# climate series, so 1997 and 2010 keep their lags and lead):
#   dry_sum, wet_sum   sum over the year of the monthly SPI dry side / wet
#                      side (drought term 1 = dry_sum)
#   dry_wsum           same, each month weighted by its 1981-2010 share of
#                      annual rain, x 12 so it's in the same units as dry_sum
#                      (drought term 2)
#   spi12_dry          dry side of the January-December 12-month SPI (drought
#                      term 3)
#   rain_d1/d2/d3      daily rain, rain^2, rain^3 summed over the year, in cm
#                      (the precip poly)
#   tavg_1, tavg_2     daily temp and temp^2 summed over the year
#
# Regs (Poisson, log pop offset, unweighted, ADM2 x age + state x year x age
# FE, clustered by state):
#   recovery_spi       dry_sum + wet_sum at t-1, t, t+1
#   recovery_spi_lag2  same + t-2
#   recovery_spi_templag  same as recovery_spi + last year's temp
#   recovery_poly      rain_d1/d2/d3 at t-1, t, t+1
#   main_<term>        poly + one drought term, both at t-1, t, t+1
#   + recovery_spi on the Northeast and the rest of Brazil, and on the
#     official stable annual panel (side check)
#
# Monthly benchmarks come from the saved precip_poly regs (saturated FE,
# current temp), which have the covariance needed for window sums.
#
# All effects are 100 x Poisson coef (about % change in annual deaths).
# Monthly sums are divided by 12: % of a month's deaths -> % of a year's.
#
# Output: output/data/drought/brazil-monthly/1997_2010/recovery_test/
# ============================================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(readr)
library(data.table)
library(fixest)

setFixest_nthreads(as.integer(Sys.getenv("SLURM_CPUS_PER_TASK", "1")))


# -----------------------------
# Paths
# -----------------------------

PILOT_DIR <- "/project/cil/gcp/estimation/rainfall-mortality/mortality_data/monthly/brazil_pilot/legacy_1997_2010"
MONTHLY_DEATHS_FILE <- file.path(PILOT_DIR, "BRA_mortality_climate_monthly_1997_2010.csv")
ANNUAL_DEATHS_FILE <- "/project/cil/gcp/estimation/rainfall-mortality/mortality_data/annual/brazil_pilot/legacy_1997_2010/BRA_mortality_climate_annual_1997_2010.csv"
CLIMATE_DIR <- "/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND-GLOBAL/BRA_STABLE/monthly"
SPI_FILE <- "/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/brazil_monthly/brazil_monthly_drought_measures_stable.rds"
REPO <- "/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026"
MONTHLY_RESULTS <- file.path(REPO, "output/data/precip-monthly/1997_2010")
REGION_RESULTS <- file.path(REPO, "output/data/drought/brazil-monthly/1997_2010")
OUTPUT_DIR <- file.path(REPO, "output/data/drought/brazil-monthly/1997_2010/recovery_test")
dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

P99_DAY_MM <- 34.25 # p99 of municipality-days, 1997-2010 (precip_poly/03_figures.R)
EXPOSURES <- c("dry_sum", "wet_sum", "dry_wsum", "spi12_dry", "rain_d1", "rain_d2", "rain_d3")
DROUGHT_TERMS <- c("dry_sum", "dry_wsum", "spi12_dry")
POLY <- c("rain_d1", "rain_d2", "rain_d3")


# -----------------------------
# Annual exposures, 1995-2011
# -----------------------------

# Monthly rain and temp terms, population-weighted (cm for rain, as in the
# monthly precip poly)
climate <- rbindlist(lapply(1995:2011, function(y) {
  fread(file.path(CLIMATE_DIR, paste0("era5land_bra_stable_adm2_monthly_", y, ".csv")),
        select = c("month", "stable_admin_id", "prcp_pop_p1", "prcp_pop_p2", "prcp_pop_p3",
                   "tmean_pop_p1", "tmean_pop_p2"))
}))
climate[, `:=`(admin_id = as.character(stable_admin_id), year = as.integer(substr(month, 1, 4)),
               month = as.integer(substr(month, 6, 7)))]

# Monthly SPI, and each calendar month's share of normal (1981-2010) rain
spi <- as.data.table(readRDS(SPI_FILE))
normals <- spi[year %in% 1981:2010, .(normal_mm = mean(rain_mm)), by = .(admin_id, month)]
normals[, rain_share := normal_mm / sum(normal_mm), by = admin_id]
spi <- merge(spi[year %in% 1995:2011], normals[, .(admin_id, month, rain_share)], by = c("admin_id", "month"))
climate <- merge(climate, spi[, .(admin_id, year, month, spi01, spi12, rain_share)],
                 by = c("admin_id", "year", "month"))

# Sum the months of each year
annual_x <- climate[, .(
  dry_sum = sum(pmax(0, -spi01)),
  wet_sum = sum(pmax(0, spi01)),
  dry_wsum = 12 * sum(rain_share * pmax(0, -spi01)),
  spi12_dry = pmax(0, -spi12[month == 12]),
  rain_d1 = sum(prcp_pop_p1) / 10,
  rain_d2 = sum(prcp_pop_p2) / 10^2,
  rain_d3 = sum(prcp_pop_p3) / 10^3,
  tavg_1 = sum(tmean_pop_p1),
  tavg_2 = sum(tmean_pop_p2),
  n_months = .N
), by = .(admin_id, year)]
stopifnot(all(annual_x$n_months == 12))
setorder(annual_x, admin_id, year)

# Last years (lag1, lag2) and next year (lead1)
for (k in 1:2) annual_x[, paste0(c(EXPOSURES, "tavg_1", "tavg_2"), "_lag", k) := shift(.SD, k),
                        by = admin_id, .SDcols = c(EXPOSURES, "tavg_1", "tavg_2")]
annual_x[, paste0(EXPOSURES, "_lead1") := shift(.SD, 1, type = "lead"), by = admin_id, .SDcols = EXPOSURES]


# -----------------------------
# Annual mortality: the monthly panel summed over months
# -----------------------------

# Population is annual, repeated across months, so it's not summed
monthly <- fread(MONTHLY_DEATHS_FILE, select = c("admin_id", "year", "month", "adm1_id", "agegroup", "deaths", "population"))
annual <- monthly[agegroup != 0, .(deaths = sum(deaths), population = population[1], n_months = .N),
                  by = .(admin_id = as.character(admin_id), adm1_id, year, agegroup)]
stopifnot(all(annual$n_months == 12))

# Same columns from the official annual panel, for the side check
official <- fread(ANNUAL_DEATHS_FILE, select = c("admin_id", "adm1_id", "year", "agegroup", "deaths", "population"))
official <- official[agegroup != 0][, admin_id := as.character(admin_id)]

prep <- function(d) {
  merge(d, annual_x, by = c("admin_id", "year")) %>%
    as_tibble() %>%
    filter(population > 0) %>%
    mutate(agegroup = factor(agegroup), admin_code = paste("BRA", admin_id, sep = "_"),
           adm1_code = paste("BRA", adm1_id, sep = "_"), northeast = adm1_id %in% 21:29)
}
annual <- prep(annual)
official <- prep(official)
message("annual panel: ", nrow(annual), " rows, ", n_distinct(annual$admin_id), " ADM2s, ",
        paste(range(annual$year), collapse = "-"))


# -----------------------------
# Annual regs
# -----------------------------

# Exposure names at t-2 ... t+1
at <- function(v, lags) unlist(lapply(lags, function(l) {
  if (l == 0) v else if (l > 0) paste0(v, "_lag", l) else paste0(v, "_lead", -l)
}))

fit_annual <- function(df, terms, temp = c("tavg_1", "tavg_2")) {
  rhs <- paste0("i(agegroup, ", c(temp, terms), ")")
  f <- as.formula(paste("deaths ~", paste(rhs, collapse = " + "),
                        "| admin_code^agegroup + adm1_code^year^agegroup"))
  fepois(f, data = df, offset = ~log(population), cluster = ~adm1_code)
}

# Estimate and SE of a weighted sum of coefs for one age group.
# weights: named (variable -> weight), applied at each of `lags`
lincomb <- function(coef, vcov, age, weights, lags) {
  a <- setNames(rep(0, length(coef)), names(coef))
  for (l in lags) for (v in names(weights)) {
    name <- paste0("agegroup::", age, ":", at(v, l))
    if (name %in% names(a)) a[name] <- weights[[v]]
  }
  est <- sum(a * coef)
  se <- sqrt(as.numeric(t(a) %*% vcov %*% a))
  tibble(est = 100 * est, se = 100 * se, p = 2 * pnorm(-abs(est / se)))
}

spi_terms <- at(c("dry_sum", "wet_sum"), c(-1, 0, 1))
fits <- list(
  recovery_spi = fit_annual(annual, spi_terms),
  recovery_spi_lag2 = fit_annual(annual, c(spi_terms, at(c("dry_sum", "wet_sum"), 2))),
  recovery_spi_templag = fit_annual(annual, spi_terms, c("tavg_1", "tavg_2", "tavg_1_lag1", "tavg_2_lag1")),
  recovery_poly = fit_annual(annual, at(POLY, c(-1, 0, 1))),
  recovery_spi_northeast = fit_annual(filter(annual, northeast), spi_terms),
  recovery_spi_rest = fit_annual(filter(annual, !northeast), spi_terms),
  recovery_spi_official = fit_annual(official, spi_terms)
)
for (d in DROUGHT_TERMS) {
  fits[[paste0("main_", d)]] <- fit_annual(annual, at(c(POLY, d), c(-1, 0, 1)))
}
saveRDS(lapply(fits, function(f) list(coef = coef(f), vcov = vcov(f), nobs = nobs(f))),
        file.path(OUTPUT_DIR, "recovery_fits.rds"))


# -----------------------------
# Comparison table: monthly vs annual
# -----------------------------

# Monthly regs (saturated FE, current temp): SPI dry/wet and precip poly
m_spi <- readRDS(file.path(MONTHLY_RESULTS, "precip_monthly_spi_saturated_temp-current.rds"))
m_poly <- readRDS(file.path(MONTHLY_RESULTS, "precip_monthly_daily_saturated_temp-current.rds"))
d <- P99_DAY_MM / 10
p99 <- c(rain_d1 = d, rain_d2 = d^2, rain_d3 = d^3)

# Monthly term names use spi_dryside/spi_wetside, annual dry_sum/wet_sum
monthly_window <- function(res, age, weights, lags) {
  lincomb(res$coef, res$vcov, age, weights, lags) %>% mutate(est = est / 12, se = se / 12)
}
annual_window <- function(fit, age, weights, lags) lincomb(coef(fit), vcov(fit), age, weights, lags)

rows <- list()
add_row <- function(age, exposure, window, monthly, annual_fit, annual_lags, weights_a, model = "recovery") {
  a <- annual_window(annual_fit, age, weights_a, annual_lags)
  rows[[length(rows) + 1]] <<- tibble(
    agegroup = age, exposure, window, model,
    monthly_est = monthly$est, monthly_se = monthly$se, monthly_p = monthly$p,
    annual_est = a$est, annual_se = a$se, annual_p = a$p
  )
}
none <- tibble(est = NA_real_, se = NA_real_, p = NA_real_)

for (age in 1:3) {
  for (side in c("dry", "wet")) {
    wm <- setNames(1, paste0("spi_", side, "side"))
    wa <- setNames(1, paste0(side, "_sum"))
    f <- fits$recovery_spi
    add_row(age, side, "total: months 0-11 vs t + t-1", monthly_window(m_spi, age, wm, 0:11), f, 0:1, wa)
    add_row(age, side, "short run: months 0-2 vs t", monthly_window(m_spi, age, wm, 0:2), f, 0, wa)
    add_row(age, side, "slow: months 3-11 vs t-1", monthly_window(m_spi, age, wm, 3:11), f, 1, wa)
    add_row(age, side, "placebo: leads 1-6 vs t+1", monthly_window(m_spi, age, wm, -(1:6)), f, -1, wa)
    add_row(age, side, "t-2 check: total with t-2", none, fits$recovery_spi_lag2, 0:2, wa)
    add_row(age, side, "temp lag check: t + t-1", none, fits$recovery_spi_templag, 0:1, wa)
    add_row(age, side, "official annual panel: t + t-1", none, fits$recovery_spi_official, 0:1, wa)
  }
  f <- fits$recovery_poly
  add_row(age, "p99 day", "total: months 0-11 vs t + t-1", monthly_window(m_poly, age, p99, 0:11), f, 0:1, p99)
  add_row(age, "p99 day", "short run: months 0-2 vs t", monthly_window(m_poly, age, p99, 0:2), f, 0, p99)
  add_row(age, "p99 day", "slow: months 3-11 vs t-1", monthly_window(m_poly, age, p99, 3:11), f, 1, p99)
  add_row(age, "p99 day", "placebo: leads 1-6 vs t+1", monthly_window(m_poly, age, p99, -(1:6)), f, -1, p99)
}

# Northeast vs rest: monthly benchmarks from the --region runs (sums only)
for (r in c("northeast", "rest")) {
  m <- read_csv(file.path(REGION_RESULTS, paste0("region_", r), "brazil_monthly_drought_lag_sums_saturated.csv"),
                show_col_types = FALSE) %>% filter(set_id == "spi01_dry_wet")
  for (age in 1:3) for (side in c("dry", "wet")) for (b in c("lags", "leads")) {
    mm <- filter(m, agegroup == age, block == paste0(side, "_", b))
    monthly <- tibble(est = 100 * mm$estimate / 12, se = 100 * mm$std_error / 12, p = mm$p_value)
    add_row(age, side, paste0(r, ": ", if (b == "lags") "months 0-11 vs t + t-1" else "leads 1-6 vs t+1"),
            monthly, fits[[paste0("recovery_spi_", r)]], if (b == "lags") 0:1 else -1, setNames(1, paste0(side, "_sum")),
            model = r)
  }
}

# Main annual spec: each drought term (and the p99 day) next to the poly
for (dt in DROUGHT_TERMS) for (age in 1:3) {
  f <- fits[[paste0("main_", dt)]]
  for (w in list(list("total: t + t-1", 0:1), list("t", 0), list("t-1", 1), list("placebo: t+1", -1))) {
    add_row(age, dt, w[[1]], none, f, w[[2]], setNames(1, dt), model = paste0("main_", dt))
    add_row(age, "p99 day", w[[1]], none, f, w[[2]], p99, model = paste0("main_", dt))
  }
}

comparison <- bind_rows(rows)
write_csv(comparison, file.path(OUTPUT_DIR, "recovery_comparison.csv"))


# -----------------------------
# Drought terms: overlap with the poly, and out-of-sample fit
# -----------------------------

# Overlap: share of each drought term's variation (after FE and temp) that
# the poly explains, and its correlation with the poly's linear term. One
# row per municipality-year (65+ rows only, exposures are the same by age)
one_age <- filter(annual, agegroup == 3)
fe <- "| admin_code + adm1_code^year"
resid_of <- function(v, rhs) resid(feols(as.formula(paste(v, "~", rhs, fe)), one_age))
overlap <- bind_rows(lapply(DROUGHT_TERMS, function(dt) {
  base <- resid_of(dt, "tavg_1 + tavg_2")
  full <- resid_of(dt, "tavg_1 + tavg_2 + rain_d1 + rain_d2 + rain_d3")
  tibble(drought_term = dt, sd_after_fe = sd(base),
         share_explained_by_poly = 1 - var(full) / var(base),
         corr_with_rain_d1 = cor(base, resid_of("rain_d1", "tavg_1 + tavg_2")))
}))
write_csv(overlap, file.path(OUTPUT_DIR, "drought_term_overlap.csv"))

# Out-of-sample fit: hold out a random fifth of municipality-years (all ages
# together), fit on the rest, Poisson deviance on the held-out rows. The FE
# of held-out rows are still estimated from the other years and places.
# Lower = better, compared to the poly alone.
set.seed(20261012)
cells <- distinct(annual, admin_id, year) %>% mutate(fold = sample(rep(1:5, length.out = n())))
annual_f <- left_join(annual, cells, by = c("admin_id", "year"))
oos_models <- c(list(poly_only = at(POLY, c(0, 1))),
                setNames(lapply(DROUGHT_TERMS, function(dt) at(c(POLY, dt), c(0, 1))), DROUGHT_TERMS))
deviance_rows <- list()
for (k in 1:5) {
  train <- filter(annual_f, fold != k)
  test <- filter(annual_f, fold == k)
  preds <- sapply(oos_models, function(terms) predict(fit_annual(train, terms), newdata = test))
  ok <- complete.cases(preds)
  y <- test$deaths[ok]
  dev <- apply(preds[ok, , drop = FALSE], 2, function(mu) 2 * sum(ifelse(y > 0, y * log(y / mu), 0) - (y - mu)))
  deviance_rows[[k]] <- tibble(fold = k, model = names(dev), deviance = dev, rows = sum(ok))
}
oos <- bind_rows(deviance_rows) %>%
  group_by(model) %>%
  summarise(deviance = sum(deviance), .groups = "drop") %>%
  mutate(vs_poly_only = deviance - deviance[model == "poly_only"])
write_csv(oos, file.path(OUTPUT_DIR, "drought_term_oos_fit.csv"))


# -----------------------------
# Print
# -----------------------------

options(width = 200)
print(comparison %>% mutate(across(c(monthly_est, monthly_se, annual_est, annual_se), ~ round(.x, 2)),
                            across(c(monthly_p, annual_p), ~ round(.x, 3))), n = Inf)
print(overlap)
print(oos)
message("wrote: ", OUTPUT_DIR)
