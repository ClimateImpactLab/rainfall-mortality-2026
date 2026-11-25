# ============================================================================
# 02_regs.R
#
# Brazil monthly drought x normal temp regs: does a drought hurt more when it
# hits a month that's normally hot?
#
# Same reg as ../precip_poly/02_regs.R (FE Poisson on monthly deaths, log(pop)
# offset, SEs clustered by state, everything x age group, temp this month + 11
# lags), with the SPI dry side at this month + 11 lags + 6 leads (placebo),
# split by the normal temp of each dry month (01_build_normal_temp.R).
#
# Builds, for each run:
#   linear: drought x the month's normal temp (notes/temp_drought_interaction.tex
#     in the Overleaf project), one effect at the average normal temp and one
#     change per 1 C, at each lag and lead
#   season, abs: one drought effect per group of months (cold, middle, hot
#     within each municipality, or by C cuts over all municipalities)
#
# Options (--period, --spec, --season_n, --normal, --precip, --place_avg): see
# "Options and paths" below.
#
# Output: output/data/drought/brazil-monthly/<period>/temp_interaction/, one
# file per run with the drought coefs and their vcov. Tables and figures in
# 03_outputs.R
# ============================================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(data.table)
library(fixest)


# -----------------------------
# Options and paths
# -----------------------------

# Read one option from the command line, for ex --spec=season gives "season".
# If the option isn't given, use the default
args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(name, default) {
  value <- sub(".*=", "", grep(paste0("^--", name, "="), args, value = TRUE))
  if (length(value) == 0) default else value
}

# Years: 2000_2024 (default, the doc) or 1997_2010, the panel from
# ../precip_poly/01_build_panel.R with the same --period
PERIOD <- get_arg("period", "2000_2024")

# How the drought term is split by the month's normal temp:
#   linear (default): each drought term also x the centered normal temp of its
#     month, so the drought effect of month t-k = b_k + phi_k x (normal of
#     month t-k - T*). T* is the average normal over the sample, so b is the
#     effect in a month at the average normal and phi the change per 1 C
#   season: within place, each year the municipality's 12 months ranked by
#     their normal, its 3 coldest, 6 middle and 3 hottest
#   abs: across places, the month's normal below the 25th percentile of all
#     municipality-months in the sample, 25th-75th, above the 75th
SPEC <- get_arg("spec", "linear")

# With --spec=season, months in the cold and hot groups: 3 (default) or 1
SEASON_N <- as.integer(get_arg("season_n", "3"))

# Normal temp: over the 30 years before (rolling, default) or 1981-2010 (fixed)
NORMAL <- get_arg("normal", "rolling")

# With (yes, default) or without (no) the precip poly (this month + 11 lags +
# 6 leads). Without it, dry months are compared with normal and wet months
PRECIP <- get_arg("precip", "yes") == "yes"

# Linear only: yes also adds drought x the municipality's average temp over the
# year, so phi only comes from the season a drought falls in within a place,
# not from hot vs cool places
PLACE_AVG <- get_arg("place_avg", "no") == "yes"

# Run name, for ex season_rolling, and the first and last year
RUN <- paste0(SPEC, if (SPEC == "season" && SEASON_N != 3) paste0("_n", SEASON_N), "_", NORMAL,
              if (!PRECIP) "_noprecip", if (PLACE_AVG) "_placeavg")
YEARS <- as.integer(strsplit(PERIOD, "_")[[1]])

# Use the CPUs given by Slurm (fixest otherwise counts the whole node)
setFixest_nthreads(as.integer(Sys.getenv("SLURM_CPUS_PER_TASK", "1")))

# Panel from ../precip_poly/01_build_panel.R, normals from 01_build_normal_temp.R
PANEL_FILE <- paste0(
  "/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/",
  "precip_monthly/brazil_precip_monthly_panel_", PERIOD, ".rds"
)
NORMAL_FILE <- paste0(
  "/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/",
  "brazil_monthly/brazil_monthly_normal_temp.rds"
)
OUTPUT_DIR <- file.path("/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/output/data/drought/brazil-monthly",
                        PERIOD, "temp_interaction")
dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)


# -----------------------------
# Regression terms
# -----------------------------

# Saturated FE: municipality x age x calendar month, year-month x age, state x year x age
FE <- c("admin_code^agegroup^month", "year_month^agegroup", "adm1_code^year^agegroup")

# Periods: this month (""), 11 lags and 6 leads (placebo)
PERIODS <- c("", paste0("_lag", 1:11), paste0("_lead", 1:6))
lags_of <- function(v) c(v, paste0(v, "_lag", 1:11))

# Drought terms: spi_dryside, and for linear its interactions with normal temp,
# for ex dxt_lag3 = spi_dryside_lag3 x centered normal of that month
DROUGHT <- paste0("spi_dryside", PERIODS)
DXT <- paste0("dxt", PERIODS)
DXP <- paste0("dxp", PERIODS)

# By group of months, for ex dhot_lag3 (season) or dahot_lag3 (abs)
GROUPS <- c("cold", "mid", "hot")
PREFIX <- if (SPEC == "abs") "da" else "d"
DGROUP <- paste0(PREFIX, rep(GROUPS, each = length(PERIODS)), PERIODS)

TEMP <- c(lags_of("tavg_1"), lags_of("tavg_2"))
PRECIP_POLY <- unlist(lapply(c("rain_d1", "rain_d2", "rain_d3"), function(v) paste0(v, PERIODS)))


# -----------------------------
# Normal temp of each period's month
# -----------------------------

# Normal temp of every month, then shifted so each row also has the normal of
# the month k months before (_lagk) or after (_leadk). Months are consecutive
# within a municipality (1980-2024), so a shift by k rows is k months
normal <- as.data.table(readRDS(NORMAL_FILE))[, .(admin_id, year, month, normal = get(paste0("normal_", NORMAL)))]
setorder(normal, admin_id, year, month)

# Season of each month: each year, the municipality's 12 months ranked by their
# normal (1 cold, 2 middle, 3 hot)
normal[, rank := frank(normal, ties.method = "first", na.last = "keep"), by = .(admin_id, year)]
normal[, season := fifelse(rank <= SEASON_N, 1L, fifelse(rank > 12 - SEASON_N, 3L, 2L))]
normal[, rank := NULL]
setorder(normal, admin_id, year, month)
for (k in 1:11) normal[, paste0(c("normal", "season"), "_lag", k) := shift(.SD, k), by = admin_id, .SDcols = c("normal", "season")]
for (k in 1:6) normal[, paste0(c("normal", "season"), "_lead", k) := shift(.SD, k, type = "lead"), by = admin_id, .SDcols = c("normal", "season")]

# Each municipality's average temp over the year (fixed normals), for --place_avg
place_avg <- as.data.table(readRDS(NORMAL_FILE))[, .(place_avg = mean(normal_fixed)), by = admin_id]


# -----------------------------
# Read panel
# -----------------------------

# Drop rows with no deaths data or zero population (log(pop) offset), and rows
# missing any term (so all runs and periods use the same months)
df <- as.data.table(readRDS(PANEL_FILE))[!is.na(deaths) & population > 0]
df <- merge(df, normal[year %in% YEARS[1]:YEARS[2]], by = c("admin_id", "year", "month"))
df <- merge(df, place_avg, by = "admin_id")
NORMALS <- paste0("normal", PERIODS)
df <- df[complete.cases(df[, c(DROUGHT, TEMP, PRECIP_POLY, NORMALS), with = FALSE])]

# T*: the average normal temp over the sample's municipality-months, and the
# 25th and 75th percentile cuts for abs
month_normals <- unique(df[, .(admin_id, year, month, normal)])$normal
T_STAR <- mean(month_normals)
PLACE_STAR <- mean(unique(df[, .(admin_id, place_avg)])$place_avg)
CUTS <- quantile(month_normals, c(0.25, 0.75))

# Drought terms of every period: x centered normal (linear), x centered place
# average (--place_avg), or split by group of months (season, abs)
for (p in PERIODS) {
  df[, (paste0("dxt", p)) := get(paste0("spi_dryside", p)) * (get(paste0("normal", p)) - T_STAR)]
  df[, (paste0("dxp", p)) := get(paste0("spi_dryside", p)) * (place_avg - PLACE_STAR)]
  group <- if (SPEC == "abs") findInterval(df[[paste0("normal", p)]], CUTS) + 1L else df[[paste0("season", p)]]
  for (i in 1:3) df[, (paste0(PREFIX, GROUPS[i], p)) := get(paste0("spi_dryside", p)) * (group == i)]
}

# This month's group, for the climate control of season and abs
this_group <- if (SPEC == "abs") findInterval(df$normal, CUTS) + 1L else df$season
df[, `:=`(g_cold = as.numeric(this_group == 1), g_hot = as.numeric(this_group == 3))]

message(
  "run: ", RUN, " | ", nrow(df), " rows | ", uniqueN(df$admin_code), " municipalities | ",
  min(df$year), "-", max(df$year), " | T* = ", round(T_STAR, 2), " C"
)


# -----------------------------
# Estimate
# -----------------------------

# deaths ~ temp + precip poly + drought terms + climate control, all x age.
# Climate control: linear has this month's normal with the rolling normal (the
# fixed one is taken out by the municipality x calendar month FE). season and
# abs have this month being cold or hot instead (middle left out)
drought <- if (SPEC == "linear") c(DROUGHT, DXT, if (PLACE_AVG) DXP) else DGROUP
control <- if (SPEC == "linear") { if (NORMAL == "rolling") "normal" } else c("g_cold", "g_hot")
terms <- c(TEMP, if (PRECIP) PRECIP_POLY, drought, control)
f <- as.formula(paste(
  "deaths ~", paste0("i(agegroup, ", terms, ")", collapse = " + "), "+ offset(log(population)) |",
  paste(FE, collapse = " + ")
))
fit <- fepois(f, data = df, cluster = ~adm1_code)

# Drought coefs and their vcov, plus what 03_outputs.R needs: T*, the cuts and
# the normal temps of the sample (for the range of the figures)
keep <- grep(":(spi_dryside|dxt|dxp|dcold|dmid|dhot|dacold|damid|dahot)", names(coef(fit)), value = TRUE)
saveRDS(
  list(run = RUN, period = PERIOD, spec = SPEC, coef = coef(fit)[keep], vcov = vcov(fit)[keep, keep],
       nobs = nobs(fit), t_star = T_STAR, cuts = CUTS,
       normal_pct = quantile(month_normals, c(0.05, 0.1, 0.5, 0.9, 0.95))),
  file.path(OUTPUT_DIR, paste0("temp_interaction_", RUN, ".rds"))
)
message("wrote: ", file.path(OUTPUT_DIR, paste0("temp_interaction_", RUN, ".rds")))
