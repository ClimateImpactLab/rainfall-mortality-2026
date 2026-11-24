# ============================================================================
# 04_temp_interaction_regs.R
#
# Does a drought raise deaths more when it falls in a month that's normally
# hot? Same reg as 02 (on the panel from 01), but the year's drought term is
# split by how hot each dry month normally is
# 
# A month's normal temp = the average temp of that calendar month in the place,
# in C, over the 30 years before (for ex July in Phoenix)
#
# Four ways to split (--spec):
#  - linear: one drought effect at the average normal temp, plus its change per
#    1 C hotter normal
#  - season: within each place, its 3 coldest, 6 middle and 3 hottest months
#    each year, so hot is relative to the place
#  - abs (absolute, the main version): across all places, hot = a normal temp
#    in the top quarter of all admin unit-months, cold = the bottom quarter,
#    so hot is in C, whatever the place
#  - bins: same as abs with 10 groups of equal size
#
# Options: see the Options section below
#
# Output: output/data/drought/global-annual/het/temp_interaction/, one file per
# run with the drought coefs and their vcov (tables and figures in 05)
# ============================================================================


# --------------
# Packages
# --------------

library(dplyr)
library(data.table)
library(fixest)


# --------------
# Options
# --------------

# Each option is passed as --name=value by the sbatch, for ex --spec=abs
# Run in R, nothing is passed, so you get the defaults
args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(name, default) {
  value <- sub(".*=", "", grep(paste0("^--", name, "="), args, value = TRUE))
  if (length(value) == 0) default else value
}

# The options, default first:
#  - spec = linear | season | abs | bins
#      how the drought term is split by the month's normal temp (see header)
#      linear: dry_sum (monthly SPI dry side summed over the year) and dxt (the
#      same with each month x its normal minus T*, the sample's average normal),
#      so the dry_sum coef is the effect at T* and the dxt coef the change per 1 C
#  - season_n = 3 | 1
#      with spec season, the number of months in the cold and hot groups: 3 gives
#      3 cold, 6 mid and 3 hot months, 1 gives 1 cold, 10 mid and 1 hot
#  - normal = rolling | fixed
#      normal temp over the 30 years before, or over 1981-2010
#  - precip = yes | no
#      with or without the precip poly
#  - check = none | place | income | place_income
#      extra drought terms: dry_sum x the place's average temp (so the linear
#      slope only comes from seasons within a place), dry_sum x income (so hot
#      isn't just poor), or both
#  - trend = no | unit
#      unit adds a linear trend for each admin unit x age (for the results whose
#      placebo is significant)

SPEC <- get_arg("spec", "linear")
SEASON_N <- as.integer(get_arg("season_n", "3"))
NORMAL <- get_arg("normal", "rolling")
PRECIP <- get_arg("precip", "yes") == "yes"
CHECK <- get_arg("check", "none")
TREND <- get_arg("trend", "no")

# Run name, for the output file, for ex abs_rolling or linear_rolling_income
RUN <- paste0(SPEC, if (SPEC == "season" && SEASON_N != 3) paste0("_n", SEASON_N), "_", NORMAL,
              if (!PRECIP) "_noprecip", if (CHECK != "none") paste0("_", CHECK),
              if (TREND == "unit") "_unittrend")

# fixest on 1 thread, jobs on more threads got stuck on Midway
setFixest_nthreads(1)


# ------------
# Paths
# ------------

# het_panel_file (from 01) and results_dir
source("paths.R")
OUTPUT_DIR <- file.path(results_dir, "temp_interaction")
dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

# The groups of months need each month's drought and normal temp, which the panel
# doesn't keep, so they're rebuilt from the monthly climate files
# Same matching to the panel's admin units (climate_inputs.R) and same functions used
# (from 06_admin_drought_terms.R) as the 2_panel_build scripts

repo_dir <- normalizePath("../../..")
build_dir <- file.path(repo_dir, "1_data/panel_build")
if (SPEC != "linear") {
  source(file.path(build_dir, "paths.R"))
  source(file.path(build_dir, "climate_inputs.R"))
  source(file.path(repo_dir, "1_data/climate_data/climate_aggregation_global/era5land_admin/panel/06_admin_drought_terms.R"))
}


# --------------------
# Regression terms
# --------------------

# Periods: this year (t), last year (t-1) and next year (t+1, placebo)
WHEN <- c(t = "", `t-1` = "_lag1", `t+1` = "_lead1")
POLY <- paste0(rep(paste0("prcp_poly_", 1:3), each = 3), WHEN)

# FE: admin unit x age, country x year x age, ADM1 x year x age
# With --trend=unit each admin unit x age also gets its own linear trend, so a
# place whose death rate drifts at its own pace doesn't look like a drought effect
FE <- paste("admin_code^agegroup + iso^year^agegroup + fe_adm1^year^agegroup",
            if (TREND == "unit") "+ admin_code^agegroup[year]")

# Groups of months, cold to hot (none for linear)
GROUPS <- switch(SPEC, linear = NULL, bins = paste0("b", 1:10), c("cold", "mid", "hot"))

# Groups counted in the climate control (see Regression): all but mid for abs, all but bin 5 for bins, none for season
CONTROL_GROUPS <- switch(SPEC, abs = c("cold", "hot"), bins = paste0("b", setdiff(1:10, 5)), NULL)


# --------------
# Read the panel
# --------------

# The panel from 01, with income as the 2000-2010 Kummu average
panel <- readRDS(het_panel_file) %>%
  mutate(log_gdppc = log_gdppc_2000_2010)

# Rows with every rainfall and temp term and the normals, the same rows for every spec
# (the rolling normal starts in 1965, so all mortality years have it)
panel <- filter(panel, if_all(all_of(c(paste0("dry_sum", WHEN), paste0("dry_x_normal_", NORMAL, WHEN), POLY,
                                       "tavg_1", "tavg_2", paste0("normal_", NORMAL), "normal_fixed")), ~ !is.na(.x)))
if (grepl("income", CHECK)) panel <- filter(panel, !is.na(log_gdppc))


# ----------------
# Groups of months
# ----------------

# Every month of a country's panel units, all years: its drought d 
# (the monthly SPI dry side, max(0, -SPI)) and its normal temp
country_months <- function(code) {
  m <- read_climate_source(code, "monthly", c("prcp_pop_p1", "tmean_pop_p1")) %>%
    panel_climate_ids(c("prcp_pop_p1", "tmean_pop_p1")) %>%
    mutate(region_id = paste(iso, admin_id, sep = ":"))
  monthly_drought(m)[, .(iso, admin_id, year, month, d = pmax(0, -spi01), normal = get(paste0("normal_", NORMAL)))]
}

# For each admin unit x year: d summed over the months in each group (dry_<group>)
# and the number of months in each group (n_<group>), with t-1 and t+1
# A month with no normal gets no group, so its year gets NAs

group_terms <- function(months) {
  sample_years <- distinct(panel, iso, admin_id, year)
  # Each month's group: season ranks the place's 12 months that year, abs and
  # bins compare its normal with cuts over all admin unit-months of the sample
  if (SPEC == "season") {
    months[, rank := frank(normal, ties.method = "first", na.last = "keep"), by = .(iso, admin_id, year)]
    months[, group := fifelse(rank <= SEASON_N, "cold", fifelse(rank > 12 - SEASON_N, "hot", "mid"))]
    cuts <- NULL
  } else {
    # Cuts over the months of the sample's admin unit-years
    in_sample <- merge(months, sample_years, by = c("iso", "admin_id", "year"))$normal
    cuts <- quantile(in_sample, if (SPEC == "abs") c(0.25, 0.75) else seq(0.1, 0.9, 0.1), na.rm = TRUE)
    months[, group := GROUPS[findInterval(normal, cuts) + 1L]]
  }
  # Sums over each admin unit's year, full years only, then last and next year
  terms <- months[, c(setNames(lapply(GROUPS, function(g) sum(d * (group == g))), paste0("dry_", GROUPS)),
                      setNames(lapply(GROUPS, function(g) sum(group == g)), paste0("n_", GROUPS)),
                      list(n_months = .N)), by = .(iso, admin_id, year)][n_months == 12][, n_months := NULL]
  terms <- add_climate_years(as_tibble(terms), paste0("dry_", GROUPS))
  list(terms = semi_join(terms, sample_years, by = c("iso", "admin_id", "year")), cuts = cuts)
}

# Every country's months, kept for the panel's admin units, summed by group and
# added to the panel (rows without a full year of groups dropped)
cuts <- NULL
if (SPEC != "linear") {
  months <- rbindlist(lapply(climate_maps$country, function(code) {
    message("monthly drought: ", code)
    country_months(code)
  }))
  months <- months[paste(iso, admin_id) %in% paste(panel$iso, panel$admin_id)]
  groups <- group_terms(months)
  cuts <- groups$cuts
  rm(months)
  panel <- inner_join(panel, groups$terms, by = c("iso", "admin_id", "year")) %>%
    filter(if_all(all_of(paste0("dry_", rep(GROUPS, each = 3), WHEN)), ~ !is.na(.x)))
}


# ---------------
# Drought terms
# ---------------

# Linear only: T* = the average normal temp over the sample's admin unit-years
# dxt = dry_x_normal - T* x dry_sum, so each month's drought x (normal - T*),summed over the year
T_STAR <- NA
if (SPEC == "linear") {
  T_STAR <- mean(distinct(panel, admin_code, year, normal = .data[[paste0("normal_", NORMAL)]])$normal)
  for (w in WHEN) panel[[paste0("dxt", w)]] <- panel[[paste0("dry_x_normal_", NORMAL, w)]] - T_STAR * panel[[paste0("dry_sum", w)]]
}

# The checks, any spec: dxp = dry_sum x the place's average temp, dxi = dry_sum x income, both centered on their average
centered <- function(v) panel[[v]] - mean(distinct(panel, admin_code, x = .data[[v]])$x)
for (w in WHEN) {
  if (grepl("place", CHECK)) panel[[paste0("dxp", w)]] <- panel[[paste0("dry_sum", w)]] * centered("normal_fixed")
  if (grepl("income", CHECK)) panel[[paste0("dxi", w)]] <- panel[[paste0("dry_sum", w)]] * centered("log_gdppc")
}
message(RUN, ": ", nrow(panel), " rows, ", n_distinct(panel$admin_code), " admin units",
        if (SPEC == "linear") paste0(", T* = ", round(T_STAR, 2), " C"))


# ----------------
# Regression
# ----------------

# Drought terms: dry_sum and dxt (linear), or D summed by group of months
drought <- if (SPEC == "linear") c(paste0("dry_sum", WHEN), paste0("dxt", WHEN)) else paste0("dry_", rep(GROUPS, each = 3), WHEN)

# Climate control: linear with the rolling normal also has the year's average normal, since it moves over time
# abs and bins have the number of the year's months in each group instead (mid or bin 5 left out)
# season has none since every year has 3, 6 and 3
control <- if (SPEC == "linear") { if (NORMAL == "rolling") "normal_rolling" } else if (length(CONTROL_GROUPS)) paste0("n_", CONTROL_GROUPS)

# Temp, precip poly (or not), the drought terms, the checks and the climate control, all by age group
terms <- c("tavg_1", "tavg_2", if (PRECIP) POLY, drought,
           if (grepl("place", CHECK)) paste0("dxp", WHEN), if (grepl("income", CHECK)) paste0("dxi", WHEN), control)
f <- as.formula(paste("deaths ~", paste0("i(agegroup, ", terms, ")", collapse = " + "), "|", FE))
model <- fepois(f, data = panel, offset = ~log(population), cluster = ~adm1_code)

# Drought coefs and their vcov, for 05
keep <- grep(":(dry_|dxt|dxp|dxi)", names(coef(model)), value = TRUE)
saveRDS(list(run = RUN, spec = SPEC, coef = coef(model)[keep], vcov = vcov(model)[keep, keep],
             nobs = nobs(model), t_star = T_STAR, cuts = cuts),
        file.path(OUTPUT_DIR, paste0("temp_", RUN, ".rds")))
message("wrote: ", file.path(OUTPUT_DIR, paste0("temp_", RUN, ".rds")))
