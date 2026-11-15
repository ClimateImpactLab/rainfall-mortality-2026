# ============================================================================
# 04_tables_figures.R
#
# Tables and figures for the station check write-up, from the gauge
# comparison (02_station_vs_grids.py) and the admin unit comparison
# (03_units_era5land_vs_chirps.R):
#   - by_country.tex: gauges vs cells by country, median ratios
#   - colombia_airports.tex: the Colombian city gauges vs their own cells
#   - nits.tex: ERA5-Land vs CHIRPS per admin unit, by country
#   - scatter_annual.pdf: yearly total, gauge vs cell, Andes highlighted
#   - ratio_by_country.pdf: median cell / gauge by country
#
# Output: /project/cil/gcp/estimation/rainfall-mortality/climate_data/
#   station_check/summary/
# ============================================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(readr)
library(tidyr)
library(ggplot2)


# -----------------------------
# Paths and labels
# -----------------------------

# Comparisons from 01 and 02
CHECK_DIR <- "/project/cil/gcp/estimation/rainfall-mortality/climate_data/station_check"

# Where the tables and figures are saved
SUMMARY_DIR <- file.path(CHECK_DIR, "summary")
dir.create(SUMMARY_DIR, recursive = TRUE, showWarnings = FALSE)

# Country names for the tables and figures
NAMES <- c(
  ARG = "Argentina", AUS = "Australia", AUT = "Austria", BEL = "Belgium", BGR = "Bulgaria", BRA = "Brazil",
  BWA = "Botswana", CAN = "Canada", CHE = "Switzerland", CHL = "Chile", CHN = "China", COL = "Colombia",
  CPV = "Cape Verde", CRI = "Costa Rica", CYP = "Cyprus", CZE = "Czechia", DEU = "Germany", DNK = "Denmark",
  ECU = "Ecuador", ESP = "Spain", EST = "Estonia", FIN = "Finland", FRA = "France", GBR = "United Kingdom",
  GRC = "Greece", HRV = "Croatia", HUN = "Hungary", IRL = "Ireland", ISL = "Iceland", ITA = "Italy",
  IND = "India", JPN = "Japan", KOR = "South Korea", LIE = "Liechtenstein", LTU = "Lithuania", LUX = "Luxembourg",
  LVA = "Latvia", MEX = "Mexico", MKD = "North Macedonia", MLT = "Malta", MNE = "Montenegro",
  NLD = "Netherlands", NOR = "Norway", PER = "Peru", PHL = "Philippines", POL = "Poland", PRT = "Portugal",
  ROU = "Romania", RWA = "Rwanda", SVK = "Slovakia", SVN = "Slovenia", SWE = "Sweden", THA = "Thailand",
  TUR = "Turkey", USA = "United States"
)

# Countries outside the EU NUTS2 file get their own row in the units table,
# the NUTS2 countries one row together
OWN_ROW <- c("ARG", "AUS", "BRA", "BWA", "CHL", "CHN", "COL", "CPV", "CRI", "ECU", "FRA", "IND", "JPN", "KOR",
             "MEX", "PER", "PHL", "RWA", "THA", "USA")

ANDES <- c("COL", "ECU", "PER")
BLUE <- "#2a78d6"
ORANGE <- "#eb6834"
GRAY <- "#b5b4ad"
INK <- "#52514e"

# Numbers for the tables: thousands commas, missing as --
fmt <- function(x, digits = 2) {
  ifelse(is.na(x), "--", formatC(x, format = "f", digits = digits, big.mark = ","))
}

# One LaTeX row per data frame row
write_rows <- function(rows, name) {
  writeLines(paste(rows, "\\\\"), file.path(SUMMARY_DIR, name))
}


# -----------------------------
# Gauge comparison
# -----------------------------

# Product / gauge ratios for each gauge
gauges <- read_csv(file.path(CHECK_DIR, "station_vs_grids_1981_2010.csv"), show_col_types = FALSE,
                   col_types = cols(state = "c")) %>%
  mutate(
    era5l_ann = era5l_annual_mm / station_annual_mm, chirps_ann = chirps_annual_mm / station_annual_mm,
    era5l_wet = era5l_wettest_mm / station_wettest_mm, chirps_wet = chirps_wettest_mm / station_wettest_mm
  )

# Median ratio per country, yearly total and typical wettest day, and the
# share of gauges where ERA5-Land is over 2 times the gauge
by_country <- gauges %>%
  group_by(iso) %>%
  summarize(
    n = n(), gauge_ann = median(station_annual_mm),
    e_ann = median(era5l_ann, na.rm = TRUE), c_ann = median(chirps_ann, na.rm = TRUE),
    e_over2 = 100 * mean(era5l_ann > 2, na.rm = TRUE),
    gauge_wet = median(station_wettest_mm),
    e_wet = median(era5l_wet, na.rm = TRUE), c_wet = median(chirps_wet, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  arrange(desc(e_ann))

with(by_country, write_rows(
  paste(NAMES[iso], fmt(n, 0), fmt(gauge_ann, 0), fmt(e_ann), fmt(c_ann), fmt(e_over2, 0),
        fmt(gauge_wet, 0), fmt(e_wet), fmt(c_wet), sep = " & "),
  "by_country.tex"
))

# The gauges behind the Colombian cities, at their own cell, on the gauge's
# days
airports <- tibble(
  id = c("COM00080094", "COM00080210", "CO000080222", "COM00080110", "COM00080112", "COM00080144"),
  label = c("Bucaramanga (Palonegro)", "Pereira (Matecaña)", "Bogotá (El Dorado)", "Medellín (Olaya Herrera)",
            "Rionegro (Medellín airport)", "Quibdó (El Caraño)")
) %>%
  left_join(gauges, by = "id")

with(airports, write_rows(
  paste(label, fmt(n_days, 0), fmt(station_annual_mm, 0),
        paste0(fmt(era5l_annual_mm, 0), " (", fmt(era5l_ann, 1), "$\\times$)"),
        fmt(chirps_annual_mm, 0), fmt(station_wettest_mm, 0), fmt(era5l_wettest_mm, 0), fmt(chirps_wettest_mm, 0),
        sep = " & "),
  "colombia_airports.tex"
))


# -----------------------------
# Admin unit comparison
# -----------------------------

# Per country: median ERA5-Land / CHIRPS ratio, share of units over 2 and 3
# times and their share of deaths, top ratio
units <- read_csv(file.path(CHECK_DIR, "units_era5land_vs_chirps_1981_2010.csv"), show_col_types = FALSE) %>%
  mutate(country = if_else(iso %in% OWN_ROW, NAMES[iso], "Europe (NUTS2)"))

by_unit_country <- units %>%
  group_by(country) %>%
  summarize(
    units = n(), med = median(ratio),
    u2 = 100 * mean(ratio > 2), d2 = 100 * sum(deaths[ratio > 2], na.rm = TRUE) / sum(deaths, na.rm = TRUE),
    u3 = 100 * mean(ratio > 3), top = max(ratio),
    .groups = "drop"
  ) %>%
  arrange(desc(med))

with(by_unit_country, write_rows(
  paste(country, fmt(units, 0), fmt(med), fmt(u2, 0), fmt(d2, 0), fmt(u3, 0), fmt(top, 1), sep = " & "),
  "units.tex"
))


# -----------------------------
# Figures
# -----------------------------

theme_check <- theme_classic(base_size = 9) +
  theme(axis.line = element_line(color = INK), axis.ticks = element_line(color = INK),
        axis.text = element_text(color = INK), axis.title = element_text(color = INK),
        strip.background = element_blank(), strip.text = element_text(size = 10, color = INK),
        legend.position = "top", legend.title = element_blank())

# Gauge vs cell, yearly total, log scales, Andes on top in orange. Solid
# line 1:1, dotted line cell 2 times the gauge
scatter <- gauges %>%
  select(iso, station_annual_mm, `ERA5-Land` = era5l_annual_mm, CHIRPS = chirps_annual_mm) %>%
  pivot_longer(c(`ERA5-Land`, CHIRPS), names_to = "product", values_to = "cell_mm") %>%
  filter(!is.na(cell_mm)) %>%
  mutate(product = factor(product, levels = c("ERA5-Land", "CHIRPS")),
         group = if_else(iso %in% ANDES, "Colombia, Ecuador, Peru", "other gauges"))

log_axis <- function(name) {
  list(breaks = 10^(2:4), labels = scales::label_math(10^.x, format = log10), name = name)
}
p <- ggplot(scatter, aes(station_annual_mm, cell_mm)) +
  geom_point(data = filter(scatter, group == "other gauges"), aes(color = group), size = 0.4, alpha = 0.5, stroke = 0) +
  geom_point(data = filter(scatter, group != "other gauges"), aes(fill = group), shape = 21, size = 1.8,
             color = "white", stroke = 0.4) +
  geom_abline(slope = 1, intercept = 0, color = INK, linewidth = 0.4) +
  geom_abline(slope = 1, intercept = log10(2), color = INK, linewidth = 0.3, linetype = "dotted") +
  geom_text(data = tibble(product = factor("ERA5-Land", levels = levels(scatter$product)), x = 60, y = c(85, 170),
                          label = c("1:1", "2×")),
            aes(x, y, label = label), color = INK, size = 2.6, hjust = 0) +
  facet_wrap(~product) +
  do.call(scale_x_log10, log_axis("gauge, mm per year (log scale)")) +
  do.call(scale_y_log10, log_axis("grid cell, mm per year (log scale)")) +
  coord_cartesian(xlim = c(50, 20000), ylim = c(50, 20000), expand = FALSE) +
  scale_color_manual(values = c("other gauges" = GRAY)) +
  scale_fill_manual(values = c("Colombia, Ecuador, Peru" = ORANGE)) +
  guides(color = guide_legend(override.aes = list(size = 2, alpha = 1))) +
  theme_check
ggsave(file.path(SUMMARY_DIR, "scatter_annual.pdf"), p, width = 7.5, height = 3.9, device = cairo_pdf)

# Median cell / gauge by country, yearly total and typical wettest day,
# countries sorted by the ERA5-Land yearly ratio
ratios <- by_country %>%
  mutate(label = factor(paste0(NAMES[iso], " (", n, ")"), levels = paste0(NAMES[iso], " (", n, ")")[order(e_ann)])) %>%
  select(label, e_ann, c_ann, e_wet, c_wet) %>%
  pivot_longer(-label, names_to = c("product", "kind"), names_sep = "_", values_to = "ratio") %>%
  mutate(product = factor(if_else(product == "e", "ERA5-Land", "CHIRPS"), levels = c("ERA5-Land", "CHIRPS")),
         kind = factor(if_else(kind == "ann", "Yearly total", "Typical wettest day"),
                       levels = c("Yearly total", "Typical wettest day")))

p <- ggplot(ratios, aes(ratio, label, fill = product)) +
  geom_vline(xintercept = 1, color = INK, linewidth = 0.4) +
  geom_point(shape = 21, size = 2.2, color = "white", stroke = 0.4, na.rm = TRUE) +
  facet_wrap(~kind) +
  scale_x_log10(breaks = c(0.3, 0.5, 1, 2, 3), labels = c("0.3", "0.5", "1", "2", "3"),
                name = "grid cell / gauge (median, log scale)") +
  coord_cartesian(xlim = c(0.28, 3.5)) +
  scale_fill_manual(values = c("ERA5-Land" = BLUE, "CHIRPS" = ORANGE)) +
  labs(y = NULL) +
  theme_check +
  theme(panel.grid.major.y = element_line(color = "#e8e7e2", linewidth = 0.3), axis.text.y = element_text(size = 7))
ggsave(file.path(SUMMARY_DIR, "ratio_by_country.pdf"), p, width = 7.5, height = 9.5, device = cairo_pdf)

message("wrote tables and figures to ", SUMMARY_DIR)
