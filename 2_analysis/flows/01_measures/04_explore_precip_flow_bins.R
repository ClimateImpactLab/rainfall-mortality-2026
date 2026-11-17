# ============================================================
# Explore monthly precip and flow bins, USA counties 1968-2010
#
# Before building bins for the regs:
#   1. Precip needs its own edges. Flow is mm summed over the cell and every
#      cell upstream of it (01_aggregate_monthly_flow.py), so its level grows
#      with the catchment. Precip is the local monthly depth in mm
#   2. Check that counties move between bins when it rains more or floods.
#      With county FE a bin is only identified by counties whose count of
#      months in it changes across years
#
# Bin measure: number of the county's
# months in each bin in a year (0-12), bins [c_(j-1), c_j), open end bins,
# raw values.
#
# Flood events are hand-coded below. Each was checked 2026-11-16 against the
# source in its row.
#
# Sample: regression county-months, 1968-2010, pop-weighted, unweighted counts
# ============================================================

library(dplyr)
library(tidyr)
library(readr)
library(purrr)
library(glue)
library(ggplot2)
library(patchwork)
theme_set(theme_classic())

# set paths
USER <- Sys.getenv("USER")
source("../../../0_utils/paths.R") # DATA_DIR, DIR_REPO_RAINFALL_MORTALITY

flow_dir   <- file.path(DATA_DIR, "climate_data/ERA5-LAND-GLOBAL/USA/hydro/monthly")
prcp_dir   <- file.path(DATA_DIR, "climate_data/ERA5-LAND-GLOBAL/USA/monthly")
panel_file <- file.path(DATA_DIR, "climate_data/ERA5-LAND/flows/usa_annual/usa_annual_flow_regression_panel.rds")

out_dir <- file.path(DIR_REPO_RAINFALL_MORTALITY, "output/data/flows/usa-annual/precip_flow_bins/explore")
fig_dir <- file.path(out_dir, "figures")
dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)


# Settings ---------------------------

first_year <- 1968 # reg years, as in 02_usa_flow_regs.R
last_year  <- 2010
yrs_around <- 2    # event figures show +/- 2 yrs, so read 2 extra years each end
min_share  <- 0.01 # 1% rule


# colors from 00_describe_flow_measures.R
blue  <- "#1c5cab"
ink   <- "#0b0b0b"
muted <- "#898781"

options(pillar.sigfig = 6)

# starting edges, before the 1% rule. precip grids go from one width up to the
# biggest multiple below the max, so they're built once the data is in
flow_start <- list(
  flow_decade     = c(100, 1000, 10000, 100000),
  flow_halfdecade = c(100, 300, 1000, 3000, 10000, 30000, 100000, 300000)
)
prcp_widths <- c(prcp_w25 = 25, prcp_w50 = 50, prcp_w100 = 100)

scheme_var <- c(flow_decade = "flow", flow_halfdecade = "flow",
                prcp_w25 = "prcp", prcp_w50 = "prcp", prcp_w100 = "prcp")
# precip scheme whose edges the precip figures mark: the one picked for the
# regs (05_build_monthly_precip_flow_bins.R). Its width goes in the summary so
# the doc can check it
prcp_fig_scheme <- "prcp_w50"

scheme_lab <- c(flow_decade     = "Flow, decade edges",
                flow_halfdecade = "Flow, half-decade edges",
                prcp_w25        = "Precip, 25 mm bins",
                prcp_w50        = "Precip, 50 mm bins",
                prcp_w100       = "Precip, 100 mm bins")


# Flood events ---------------------------

# one row per county named by the source. months = the source's dates rounded
# out to whole months. admin_id = state FIPS _ county FIPS (01_build_usa_panel.R).
# Katrina is in on purpose: New Orleans flooded from storm surge and levee
# failures, which precip and flow aren't built to pick up
usgs_hist <- "https://www.usgs.gov/mission-areas/water-resources/science/historical-flooding"

events <- tibble::tribble(
  ~event_id, ~event_name, ~admin_id, ~county_name, ~event_start, ~event_end, ~source,
  "camille_1969", "Hurricane Camille", "51_125", "Nelson County, VA", "1969-08", "1969-08",
    "USGS OFR 99-518, debris flows and floods from the August 19/20, 1969, storm in Nelson County, VA (https://pubs.usgs.gov/of/1999/ofr-99-0518/ofr-99-0518.html)",
  "rapid_city_1972", "Black Hills-Rapid City flood", "46_103", "Pennington County, SD", "1972-06", "1972-06",
    paste0("USGS, Flood of June 9-10, 1972, at Rapid City, South Dakota (", usgs_hist, ")"),
  "agnes_1972", "Tropical Storm Agnes", "42_079", "Luzerne County, PA", "1972-06", "1972-06",
    "USGS HA 523, Flood of June 1972 in Wilkes-Barre area, Pennsylvania (https://pubs.usgs.gov/publication/ha523)",
  "big_thompson_1976", "Big Thompson flood", "08_069", "Larimer County, CO", "1976-07", "1976-08",
    paste0("USGS, Storm and flood of July 31-August 1, 1976, in the Big Thompson River and Cache la Poudre River Basins, Larimer and Weld Counties, Colorado (", usgs_hist, ")"),
  "big_thompson_1976", "Big Thompson flood", "08_123", "Weld County, CO", "1976-07", "1976-08",
    paste0("USGS, Storm and flood of July 31-August 1, 1976, in the Big Thompson River and Cache la Poudre River Basins, Larimer and Weld Counties, Colorado (", usgs_hist, ")"),
  "johnstown_1977", "Johnstown flood", "42_021", "Cambria County, PA", "1977-07", "1977-07",
    "NWS State College, The 1977 Johnstown Flood, July 19-20, 1977, heaviest rain over southern Cambria County (https://www.weather.gov/ctp/77JohnstownFlood)",
  "midwest_1993", "Great Midwest flood", "19_153", "Polk County, IA (Des Moines)", "1993-06", "1993-08",
    paste0("USGS HA 735-D, Flood of June 18 through August 4, 1993, in Des Moines and vicinity, Iowa (", usgs_hist, ")"),
  "midwest_1993", "Great Midwest flood", "19_163", "Scott County, IA (Davenport)", "1993-06", "1993-07",
    paste0("USGS HA 735-C, Flood of June 19-July 31, 1993, in Davenport, Iowa and vicinity (", usgs_hist, ")"),
  "midwest_1993", "Great Midwest flood", "19_103", "Johnson County, IA (Iowa City)", "1993-06", "1993-09",
    paste0("USGS HA 735-B, Flood of June 29-September 18, 1993, in Iowa City and vicinity, Iowa (", usgs_hist, ")"),
  "midwest_1993", "Great Midwest flood", "29_095", "Jackson County, MO (Kansas City)", "1993-07", "1993-07",
    paste0("USGS HA 735-E, Flood of July 10 and 27, 1993, in Kansas City, Missouri, and Kansas City, Kansas, and vicinity (", usgs_hist, ")"),
  "midwest_1993", "Great Midwest flood", "20_209", "Wyandotte County, KS (Kansas City)", "1993-07", "1993-07",
    paste0("USGS HA 735-E, Flood of July 10 and 27, 1993, in Kansas City, Missouri, and Kansas City, Kansas, and vicinity (", usgs_hist, ")"),
  "midwest_1993", "Great Midwest flood", "29_510", "St. Louis city, MO", "1993-08", "1993-08",
    paste0("USGS HA 735-F, Flood of August 1-3, 1993, in St. Louis and vicinity, Missouri (", usgs_hist, ")"),
  "red_river_1997", "Red River flood", "38_035", "Grand Forks County, ND", "1997-04", "1997-04",
    "NWS service assessment, Red River of the North flood, April 1997; record crest at Grand Forks (https://www.weather.gov/owp/oh_Dis_Svy_RedR_Apr97_Overview)",
  "red_river_1997", "Red River flood", "27_119", "Polk County, MN (East Grand Forks)", "1997-04", "1997-04",
    "NWS service assessment, Red River of the North flood, April 1997; record crest at Grand Forks (https://www.weather.gov/owp/oh_Dis_Svy_RedR_Apr97_Overview)",
  "floyd_1999", "Hurricane Floyd", "37_147", "Pitt County, NC (Greenville)", "1999-09", "1999-10",
    "USGS WRI 00-4093, Two months of flooding in eastern North Carolina, September-October 1999 (https://pubs.usgs.gov/wri/wri004093/flooding.html); NWS Wilmington, Tar River at Greenville (https://www.weather.gov/ilm/floyd)",
  "floyd_1999", "Hurricane Floyd", "37_065", "Edgecombe County, NC (Princeville)", "1999-09", "1999-10",
    "USGS WRI 00-4093, Two months of flooding in eastern North Carolina, September-October 1999 (https://pubs.usgs.gov/wri/wri004093/flooding.html); NWS Wilmington, Princeville and Tarboro (https://www.weather.gov/ilm/floyd)",
  "allison_2001", "Tropical Storm Allison", "48_201", "Harris County, TX (Houston)", "2001-06", "2001-06",
    "NWS Houston/Galveston Storm Data, June 2001, Harris County flash flooding June 8-9 (https://www.weather.gov/media/hgx/stormdata/jun01hgx.pdf)",
  "katrina_2005", "Hurricane Katrina (storm surge)", "22_071", "Orleans Parish, LA", "2005-08", "2005-08",
    "NHC Tropical Cyclone Report, Hurricane Katrina, 23-30 August 2005 (https://www.nhc.noaa.gov/data/tcr/AL122005_Katrina.pdf)",
  "iowa_2008", "Iowa and Cedar River floods", "19_113", "Linn County, IA (Cedar Rapids)", "2008-05", "2008-06",
    "USGS OFR 2010-1190, Floods of May 30 to June 15, 2008, in the Iowa River and Cedar River Basins; record peak at Cedar Rapids June 13 (https://pubs.usgs.gov/of/2010/1190/)",
  "iowa_2008", "Iowa and Cedar River floods", "19_103", "Johnson County, IA (Iowa City)", "2008-05", "2008-06",
    "USGS OFR 2010-1190, Floods of May 30 to June 15, 2008, in the Iowa River and Cedar River Basins; Iowa River flood in Iowa City (https://pubs.usgs.gov/of/2010/1190/)",
  "nashville_2010", "Nashville flood", "47_037", "Davidson County, TN (Nashville)", "2010-05", "2010-05",
    paste0("USGS, Record floods of greater Nashville, May 1-4, 2010 (", usgs_hist, ")")
) %>%
  mutate(event_year = as.integer(substr(event_start, 1, 4)))

stopifnot(!anyDuplicated(events[c("event_id", "admin_id")]),
          substr(events$event_start, 1, 4) == substr(events$event_end, 1, 4), # windows stay in one year
          events$event_end >= events$event_start)


# Functions ---------------------------

bin_of    <- function(x, edges) findInterval(x, edges) + 1L
bin_share <- function(x, edges) tabulate(bin_of(x, edges), nbins = length(edges) + 1) / length(x)

#' The 1% rule. While some bin has < min_share of the months, take the thin bin
#' furthest from the median bin and merge it towards its tail by dropping one
#' edge (end bins can only merge inward). Thin tails end up in the open end
#' bins and the middle keeps its widths. The median bin holds the median month
#' so it never needs merging.
merge_tails <- function(x, edges, min_share = 0.01) {
  med <- median(x) # once, not every pass
  repeat {
    sh <- bin_share(x, edges)
    if (all(sh >= min_share)) break

    med_b <- bin_of(med, edges)
    thin  <- which(sh < min_share)
    j     <- thin[which.max(abs(thin - med_b))]
    k     <- length(sh)
    if (j == med_b) stop("the median bin has < ", min_share, " of the months")

    # bin j runs from edges[j - 1] to edges[j]
    drop <- if (j > med_b) {
      if (j == k) j - 1 else j  # top bin: drop its lower edge, otherwise its upper one
    } else {
      if (j == 1) 1 else j - 1  # bottom bin: drop its upper edge, otherwise its lower one
    }
    edges <- edges[-drop]
  }
  edges
}

# edge labels: 1k, 30k etc for flow, plain mm for precip. ASCII only, the
# default pdf device can choke on >= and en dashes
fmt_edge <- function(x) {
  map_chr(x, function(v) {
    if (v >= 1000) paste0(format(v / 1000, scientific = FALSE, drop0trailing = TRUE), "k")
    else format(v, scientific = FALSE, drop0trailing = TRUE)
  })
}

bin_labels <- function(edges) {
  c(paste0("<", fmt_edge(edges[1])),
    if (length(edges) > 1) paste0(fmt_edge(head(edges, -1)), "-", fmt_edge(tail(edges, -1))),
    paste0(">=", fmt_edge(tail(edges, 1))))
}

# mm axis labels without scientific notation (as 02_monthly_flow_histogram_OLD.R)
raw_labels <- function(b) {
  map_chr(b, ~ format(.x, big.mark = ",", scientific = FALSE, drop0trailing = TRUE, trim = TRUE))
}

source("00_read_monthly.R") # read_monthly()


# 1. Load monthly precip and flow ---------------------------

print("==== reading monthly flow and precip ====")
flow_m <- read_monthly(flow_dir, "^era5land_usa_adm2_flow_monthly_[0-9]{4}\\.csv$", "flow_pop",
                       first_year - yrs_around, last_year + yrs_around)
prcp_m <- read_monthly(prcp_dir, "^era5land_usa_adm2_monthly_[0-9]{4}\\.csv$", "prcp_pop_p1",
                       first_year - yrs_around, last_year + yrs_around)

monthly <- full_join(flow_m, prcp_m, by = c("admin_id", "year", "month")) %>%
  rename(flow = flow_pop, prcp = prcp_pop_p1)
rm(flow_m, prcp_m)

# regression county-years (the panel repeats rows by age group), same as
# 02_monthly_flow_histogram_OLD.R
reg_cy <- readRDS(panel_file) %>%
  filter(year >= first_year, year <= last_year, !is.na(flowmean_pop_annual)) %>%
  distinct(admin_id, year)

df <- semi_join(monthly, reg_cy, by = c("admin_id", "year"))

# every reg county-year should have 12 months of both. flow is only set when
# all 12 months exist (02_make_drought_flood.py), and precip months are only
# kept when every day is there (02_aggregate_prcp_temp.py), so a gap is new
n_months <- df %>% filter(!is.na(flow), !is.na(prcp)) %>% count(admin_id, year)
if (nrow(n_months) != nrow(reg_cy) || any(n_months$n != 12)) {
  stop("some regression county-years don't have 12 months of both flow and precip")
}

message(glue("regression county-months: {nrow(df)} | {n_distinct(df$admin_id)} counties | ",
             "{nrow(reg_cy)} county-years | {first_year}-{last_year}"))

# tp_total shouldn't be negative. printed, not stopped: the bottom bin is
# open so a negative month still gets binned
message(glue("precip months below 0: {sum(df$prcp < 0)} | min {min(df$prcp)} mm"))


# 2. Precip distribution ---------------------------

print("==== precip vs flow distribution ====")
# why precip needs its own edges: where precip months land on the flow decade edges
prcp_on_flow <- tibble(bin = bin_labels(flow_start$flow_decade),
                       share_of_prcp_months = bin_share(df$prcp, flow_start$flow_decade),
                       share_of_flow_months = bin_share(df$flow, flow_start$flow_decade))
print(prcp_on_flow, width = Inf)


# 3. Candidate bins ---------------------------

# precip grids: one width up to the biggest multiple of it below the max
start_edges <- c(flow_start, map(prcp_widths, ~ seq(.x, floor(max(df$prcp) / .x) * .x, by = .x)))
stopifnot(setequal(names(start_edges), names(scheme_var)),
          setequal(names(scheme_lab), names(scheme_var)))

edges <- imap(start_edges, ~ merge_tails(df[[scheme_var[[.y]]]], .x, min_share))

schemes <- imap_dfr(edges, function(e, s) {
  x <- df[[scheme_var[[s]]]]
  tibble(scheme        = s,
         scheme_label  = scheme_lab[[s]],
         variable      = scheme_var[[s]],
         bin           = seq_len(length(e) + 1),
         label         = bin_labels(e),
         lower         = c(-Inf, e),
         upper         = c(e, Inf),
         reference     = bin == bin_of(median(x), e),
         n_start_edges = length(start_edges[[s]]),
         n_final_edges = length(e))
})

schemes %>%
  group_by(scheme) %>%
  summarise(bins = n(), edges = paste(head(upper, -1), collapse = ", ")) %>%
  print(width = Inf)


# 4. Bin table ---------------------------

# months per bin per county-year, 0 for bins a county-year never hits
counts <- imap_dfr(edges, function(e, s) {
  df %>%
    transmute(admin_id, year, bin = bin_of(.data[[scheme_var[[s]]]], e)) %>%
    count(admin_id, year, bin, name = "months") %>%
    complete(nesting(admin_id, year), bin = seq_len(length(e) + 1), fill = list(months = 0L)) %>%
    mutate(scheme = s)
})

# every county-year has its 12 months in every scheme
stopifnot(all(count(counts, scheme, admin_id, year, wt = months)$n == 12),
          nrow(counts) == sum(lengths(edges) + 1) * nrow(reg_cy))

# counties_varying = the county's count in the bin changes across years. with
# county FE only these counties identify the bin's coefficient
varying <- counts %>%
  group_by(scheme, bin, admin_id) %>%
  summarise(varies = n_distinct(months) > 1, .groups = "drop") %>%
  group_by(scheme, bin) %>%
  summarise(counties_varying = sum(varies), share_counties_varying = mean(varies), .groups = "drop")

bin_table <- counts %>%
  group_by(scheme, bin) %>%
  summarise(share_of_months        = sum(months) / (12 * n()),
            mean_months_per_year   = mean(months),
            share_county_years_any = mean(months > 0),
            counties_any           = n_distinct(admin_id[months > 0]),
            .groups = "drop") %>%
  left_join(varying, by = c("scheme", "bin")) %>%
  left_join(select(schemes, scheme, bin, label, reference), by = c("scheme", "bin")) %>%
  relocate(label, reference, .after = bin)

print(bin_table, n = Inf, width = Inf)


# 6. Flood events ---------------------------

print("==== flood events ====")

# event counties missing from the monthly files get reported (FIPS or boundary
# mismatch) and dropped. counties outside the reg sample in the event year are
# kept but flagged
events <- events %>%
  mutate(in_monthly_files         = admin_id %in% monthly$admin_id,
         in_regression_event_year = paste(admin_id, event_year) %in% paste(reg_cy$admin_id, reg_cy$year))
events %>%
  select(event_id, county_name, admin_id, in_monthly_files, in_regression_event_year) %>%
  print(n = Inf, width = Inf)

ev <- filter(events, in_monthly_files)
if (nrow(ev) < nrow(events)) warning(nrow(events) - nrow(ev), " event counties aren't in the monthly files")

# only the event counties' months, so the joins below stay small
ev_monthly <- semi_join(monthly, ev, by = "admin_id")

# 6.1 highest bin in the event months vs the same months a year earlier. max
# over the window, so a multi-month event counts its worst month
ev_months <- ev %>%
  select(event_id, admin_id, county_name, event_start, event_end, event_year) %>%
  left_join(ev_monthly, by = "admin_id", relationship = "many-to-many") %>%
  mutate(m = as.integer(substr(month, 6, 7))) %>%
  filter(m >= as.integer(substr(event_start, 6, 7)), m <= as.integer(substr(event_end, 6, 7)),
         year == event_year | year == event_year - 1) %>% # row by row: %in% c(...) would pool every event's years
  mutate(period = if_else(year == event_year, "event", "year_before"))

stopifnot(!anyNA(ev_months$flow), !anyNA(ev_months$prcp))

ev_moves <- imap_dfr(edges, function(e, s) {
  ev_months %>%
    mutate(value = .data[[scheme_var[[s]]]], bin = bin_of(value, e)) %>%
    group_by(event_id, admin_id, county_name, event_start, event_end, period) %>%
    summarise(max_bin = max(bin), max_value = max(value), .groups = "drop") %>%
    pivot_wider(names_from = period, values_from = c(max_bin, max_value)) %>%
    mutate(scheme = s, variable = scheme_var[[s]], bins_up = max_bin_event - max_bin_year_before)
}) %>%
  left_join(transmute(schemes, scheme, max_bin_event = bin, label_event = label),
            by = c("scheme", "max_bin_event")) %>%
  left_join(transmute(schemes, scheme, max_bin_year_before = bin, label_year_before = label),
            by = c("scheme", "max_bin_year_before")) %>%
  arrange(event_start, admin_id, scheme)

ev_moves %>%
  select(event_id, county_name, scheme, label_year_before, label_event, bins_up) %>%
  print(n = Inf, width = Inf)

# how many event counties moved up at least one bin, by scheme
ev_moves %>%
  group_by(scheme) %>%
  summarise(event_counties = n(), moved_up = sum(bins_up > 0),
            same = sum(bins_up == 0), moved_down = sum(bins_up < 0)) %>%
  print(width = Inf)

# 6.1b baseline: how often does a county move up a bin from one year to the
# next with no flood? Same rule as above (highest bin over the window's months
# vs the same months a year earlier), for every county-year pair in the reg
# sample, one window per event (the event's months), pairs with a listed event
# in the later year left out. "Moved up" is only informative against this: any
# bin set moves up in some non-flood years, and narrower bins move more often.
# Pairs need both years in the reg sample and all the window's months in both.
df_m <- mutate(df, m = as.integer(substr(month, 6, 7)))
windows <- ev %>%
  mutate(m1 = as.integer(substr(event_start, 6, 7)), m2 = as.integer(substr(event_end, 6, 7))) %>%
  count(m1, m2, name = "n_events")
event_pairs <- transmute(ev, admin_id, year = event_year)

baseline <- pmap_dfr(windows, function(m1, m2, n_events) {
  w <- df_m %>%
    filter(m >= m1, m <= m2) %>%
    group_by(admin_id, year) %>%
    summarise(flow = max(flow), prcp = max(prcp), n = n(), .groups = "drop") %>%
    filter(n == m2 - m1 + 1) %>%
    anti_join(event_pairs, by = c("admin_id", "year"))
  prev <- transmute(w, admin_id, year = year + 1, flow_prev = flow, prcp_prev = prcp)
  pairs <- inner_join(w, prev, by = c("admin_id", "year"))
  imap_dfr(edges, function(e, s) {
    v <- scheme_var[[s]]
    up <- bin_of(pairs[[v]], e) - bin_of(pairs[[paste0(v, "_prev")]], e)
    tibble(scheme = s, n_events = n_events, pairs = length(up), share_up = mean(up > 0))
  })
}) %>%
  group_by(scheme) %>%
  summarise(baseline_share_up = weighted.mean(share_up, n_events), pairs = sum(pairs), .groups = "drop")

event_share <- ev_moves %>%
  group_by(scheme) %>%
  summarise(event_share_up = mean(bins_up > 0), .groups = "drop")
baseline <- left_join(baseline, event_share, by = "scheme") %>%
  arrange(match(scheme, names(edges)))
print(baseline, width = Inf)

# 6.2 monthly series around each event, event year +/- 2. dashed lines = the
# edges picked for the regs (decade flow, 50 mm precip). shaded = event months
ev_series <- ev %>%
  select(event_id, event_name, admin_id, county_name, event_start, event_end, event_year) %>%
  left_join(ev_monthly, by = "admin_id", relationship = "many-to-many") %>%
  filter(year >= event_year - yrs_around, year <= event_year + yrs_around) %>%
  mutate(date  = as.Date(paste0(month, "-15")),
         panel = paste0(county_name, "\n", event_name, ", ", event_year))

# panels in date order
panels    <- ev_series %>% distinct(panel, event_start, admin_id) %>% arrange(event_start, admin_id) %>% pull(panel)
ev_series <- mutate(ev_series, panel = factor(panel, levels = panels))

ev_windows <- ev %>%
  mutate(xmin  = as.Date(paste0(event_start, "-01")),
         xmax  = as.Date(paste0(event_end, "-01")) + 31,
         panel = factor(paste0(county_name, "\n", event_name, ", ", event_year), levels = panels))

# 7. Histograms ---------------------------

# precip: raw axis, 5 mm bars, edges of the chosen 50 mm bins dashed
p_hist <- ggplot(df) +
  geom_histogram(aes(x = prcp), binwidth = 5, boundary = 0, fill = blue, color = NA) +
  geom_vline(xintercept = edges[[prcp_fig_scheme]], linetype = "dashed", linewidth = 0.4, colour = ink) +
  scale_x_continuous(labels = raw_labels) +
  scale_y_continuous(labels = raw_labels, expand = expansion(mult = c(0, 0.05))) +
  labs(x = "Monthly precipitation (mm)", y = "County-months") +
  theme_classic(base_size = 11)


# 7b. Both histograms in one figure (for the doc; the flow one is
# 02_monthly_flow_histogram_OLD.R's and the old doc's: 0.05 log10 bars, months <= 0
# not drawn). Edges of the chosen bins dashed
flow_pos <- df$flow[df$flow > 0]

p_hist_flow <- ggplot(tibble(flow = flow_pos), aes(flow)) +
  geom_histogram(binwidth = 0.05, fill = blue, color = NA) +
  geom_vline(xintercept = edges$flow_decade, linetype = "dashed", linewidth = 0.4, color = ink) +
  scale_x_log10(labels = raw_labels) +
  scale_y_continuous(labels = raw_labels, expand = expansion(mult = c(0, 0.05))) +
  coord_cartesian(xlim = c(1, max(flow_pos))) +
  labs(x = "Monthly flow (mm summed over upstream cells), log axis", y = "County-months") +
  theme_classic(base_size = 10)
# axis cut at 400 mm so the 50 mm edges aren't squeezed; months above are counted in the summary
p_hist_prcp <- p_hist + coord_cartesian(xlim = c(0, 400)) + labs(x = "Monthly precipitation (mm)", y = NULL) + theme_classic(base_size = 10)
ggsave(file.path(fig_dir, "fig_explore_hists.pdf"), p_hist_flow + p_hist_prcp, width = 9, height = 3.4)


# 7d. Selected flood events, flow (log axis, decade edges) above precip (50 mm
# edges): the full 21-county figures are too many to read, these 4 are the
# well-known ones across regions and seasons (4, so the text stays readable at page width)
sel <- tribble(~event_id, ~admin_id,
               "agnes_1972", "42_079", "red_river_1997", "38_035", "floyd_1999", "37_147", "iowa_2008", "19_113")
stopifnot(nrow(semi_join(sel, ev, by = c("event_id", "admin_id"))) == nrow(sel))
sel_panels <- ev %>% semi_join(sel, by = c("event_id", "admin_id")) %>%
  arrange(event_start, admin_id) %>%
  transmute(panel = paste0(county_name, "\n", event_name, ", ", event_year)) %>% pull(panel)
sel_series  <- filter(ev_series, as.character(panel) %in% sel_panels) %>% mutate(panel = factor(as.character(panel), levels = sel_panels))
sel_windows <- filter(ev_windows, as.character(panel) %in% sel_panels) %>% mutate(panel = factor(as.character(panel), levels = sel_panels))

sel_plot <- function(var, e, ylab, log_axis) {
  p <- ggplot(sel_series) +
    geom_rect(data = sel_windows, aes(xmin = xmin, xmax = xmax, ymin = if (log_axis) 0 else -Inf, ymax = Inf),
              fill = muted, alpha = 0.25) +
    geom_hline(yintercept = e, color = ink, linewidth = 0.3, linetype = "dashed") +
    geom_line(aes(x = date, y = .data[[var]]), color = blue, linewidth = 0.5) +
    facet_wrap(~panel, nrow = 1, scales = "free_x") +
    scale_x_date(date_labels = "%Y") +
    labs(x = NULL, y = ylab) +
    theme_classic(base_size = 10) +
    theme(strip.background = element_blank(), strip.text = element_text(face = "bold", size = 8))
  if (log_axis) p + scale_y_log10(labels = raw_labels) else p + scale_y_continuous(labels = raw_labels)
}
stopifnot(all(sel_series$flow > 0))
p_sel <- sel_plot("flow", edges$flow_decade, "Flow (mm), log axis", TRUE) /
  sel_plot("prcp", edges[[prcp_fig_scheme]], "Precipitation (mm)", FALSE) +
  theme(strip.text = element_blank())
ggsave(file.path(fig_dir, "fig_explore_events_selected.pdf"), p_sel, width = 8.5, height = 4.6)


# 8. Save ---------------------------

# named numbers for the doc text
summary_out <- tribble(
  ~name,                    ~value,
  "first_year",             first_year,
  "last_year",              last_year,
  "counties",               n_distinct(df$admin_id),
  "county_years",           nrow(reg_cy),
  "county_months",          nrow(df),
  "prcp_median",            median(df$prcp),
  "flow_median",            median(df$flow),
  "prcp_p99",               quantile(df$prcp, 0.99, names = FALSE),
  "flow_p99",               quantile(df$flow, 0.99, names = FALSE),
  "prcp_above_400",         sum(df$prcp > 400),
  "prcp_fig_width",         prcp_widths[[prcp_fig_scheme]]
)

write_csv(summary_out,  file.path(out_dir, "explore_summary.csv"))
write_csv(schemes,      file.path(out_dir, "explore_schemes.csv"))
write_csv(bin_table,    file.path(out_dir, "explore_bin_table.csv"))
write_csv(prcp_on_flow, file.path(out_dir, "explore_prcp_in_flow_bins.csv"))
write_csv(events,       file.path(out_dir, "explore_events.csv"))
write_csv(ev_moves,     file.path(out_dir, "explore_event_moves.csv"))
write_csv(baseline,     file.path(out_dir, "explore_event_baseline.csv"))

message("wrote: ", out_dir)
