# ============================================================================
# 04_brazil_sample_dominance.R
#
# Check whether the Brazil annual drought regressions are dominated by a small
# number of large admin units.
#
# The levels regressions use population weights. In this panel, `weight` is the
# population share within each year x age group, so this script aggregates that
# same regression weight by ADM2 and ADM1.
#
# Outputs:
#   - top ADM2 and ADM1 shares of total regression weight
#   - cumulative weight-share figures
#   - simple concentration summaries
# ============================================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(ggplot2)
library(readr)
library(scales)


# -----------------------------
# Paths
# -----------------------------

PANEL_FILE <- paste0(
  "/project/cil/gcp/estimation/rainfall-mortality/climate_data/",
  "ERA5-LAND/drought/brazil_annual/brazil_annual_drought_regression_panel_urban.rds"
)

OUTPUT_DIR <- paste0(
  "/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/",
  "output/data/drought/brazil-annual/sample-dominance"
)

figure_dir <- file.path(OUTPUT_DIR, "figures")


# -----------------------------
# Read Brazil panel
# -----------------------------

df <- readRDS(PANEL_FILE) %>%
  filter(!is.na(weight), !is.na(population))

message(
  "Brazil sample: ", nrow(df), " rows | ",
  n_distinct(df$admin_code), " ADM2s | ",
  n_distinct(df$adm1_code), " ADM1s | ",
  min(df$year), "-", max(df$year)
)


# -----------------------------
# Aggregate sample shares
# -----------------------------

# Regression weight is the relevant object for the weighted levels specs.
total_weight <- sum(df$weight, na.rm = TRUE)
total_population <- sum(df$population, na.rm = TRUE)

adm2_share <- df %>%
  group_by(admin_code, admin_name, adm1_code, adm1_name) %>%
  summarise(
    rows = n(),
    years = n_distinct(year),
    age_groups = n_distinct(agegroup),
    reg_weight = sum(weight, na.rm = TRUE),
    population_person_years = sum(population, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(
    reg_weight_share = reg_weight / total_weight,
    population_share = population_person_years / total_population
  ) %>%
  arrange(desc(reg_weight_share)) %>%
  mutate(
    rank = row_number(),
    cumulative_reg_weight_share = cumsum(reg_weight_share),
    cumulative_population_share = cumsum(population_share)
  )

adm1_share <- df %>%
  group_by(adm1_code, adm1_name) %>%
  summarise(
    adm2s = n_distinct(admin_code),
    rows = n(),
    reg_weight = sum(weight, na.rm = TRUE),
    population_person_years = sum(population, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(
    reg_weight_share = reg_weight / total_weight,
    population_share = population_person_years / total_population
  ) %>%
  arrange(desc(reg_weight_share)) %>%
  mutate(
    rank = row_number(),
    cumulative_reg_weight_share = cumsum(reg_weight_share),
    cumulative_population_share = cumsum(population_share)
  )


# -----------------------------
# Concentration summaries
# -----------------------------

# Top-k shares answer the question: how much of the weighted sample is
# carried by the largest units?
top_k <- c(1, 5, 10, 25, 50, 100)

adm2_concentration <- tibble(k = top_k) %>%
  mutate(
    level = "ADM2",
    units = nrow(adm2_share),
    reg_weight_share = sapply(k, function(x) {
      sum(head(adm2_share$reg_weight_share, x), na.rm = TRUE)
    }),
    population_share = sapply(k, function(x) {
      sum(head(adm2_share$population_share, x), na.rm = TRUE)
    })
  )

adm1_concentration <- tibble(k = seq_len(nrow(adm1_share))) %>%
  filter(k %in% c(1, 3, 5, 10, 15, nrow(adm1_share))) %>%
  mutate(
    level = "ADM1",
    units = nrow(adm1_share),
    reg_weight_share = sapply(k, function(x) {
      sum(head(adm1_share$reg_weight_share, x), na.rm = TRUE)
    }),
    population_share = sapply(k, function(x) {
      sum(head(adm1_share$population_share, x), na.rm = TRUE)
    })
  )

concentration_summary <- bind_rows(adm2_concentration, adm1_concentration) %>%
  select(level, units, k, reg_weight_share, population_share)


# -----------------------------
# Figures
# -----------------------------

theme_set(
  theme_bw(base_size = 11) +
    theme(
      panel.grid = element_blank(),
      plot.title = element_text(face = "bold", size = 12),
      plot.subtitle = element_text(size = 9),
      axis.text.y = element_text(size = 8)
    )
)

top_adm2 <- adm2_share %>%
  slice_head(n = 20) %>%
  mutate(admin_label = reorder(paste0(admin_name, " (", adm1_name, ")"), reg_weight_share))

top_adm1 <- adm1_share %>%
  slice_head(n = 15) %>%
  mutate(adm1_label = reorder(adm1_name, reg_weight_share))

top_adm2_plot <- ggplot(top_adm2, aes(x = reg_weight_share, y = admin_label)) +
  geom_col(fill = "#2F6B8F", width = 0.72) +
  scale_x_continuous(labels = percent_format(accuracy = 0.1)) +
  labs(
    x = "Share of total regression weight",
    y = NULL,
    title = "Top ADM2s by regression weight",
    subtitle = "Weights are population shares within year x age group"
  )

top_adm1_plot <- ggplot(top_adm1, aes(x = reg_weight_share, y = adm1_label)) +
  geom_col(fill = "#2F6B8F", width = 0.72) +
  scale_x_continuous(labels = percent_format(accuracy = 0.1)) +
  labs(
    x = "Share of total regression weight",
    y = NULL,
    title = "Top ADM1s by regression weight",
    subtitle = "Weights are population shares within year x age group"
  )

cumulative_adm2_plot <- ggplot(adm2_share, aes(x = rank, y = cumulative_reg_weight_share)) +
  geom_line(color = "#9F352D", linewidth = 0.8) +
  scale_x_continuous(labels = comma) +
  scale_y_continuous(labels = percent_format(accuracy = 1), limits = c(0, 1)) +
  labs(
    x = "ADM2 rank by regression weight",
    y = "Cumulative share of regression weight",
    title = "Cumulative ADM2 regression-weight share"
  )

adm2_weight_hist <- ggplot(adm2_share, aes(x = reg_weight_share)) +
  geom_histogram(bins = 45, fill = "#2F6B8F", color = "white", linewidth = 0.2) +
  scale_x_continuous(labels = percent_format(accuracy = 0.01)) +
  labs(
    x = "Share of total regression weight",
    y = "ADM2 count",
    title = "Distribution of ADM2 regression-weight shares"
  )


# -----------------------------
# Write outputs
# -----------------------------

dir.create(figure_dir, recursive = TRUE, showWarnings = FALSE)

write_csv(adm2_share, file.path(OUTPUT_DIR, "adm2_weight_shares.csv"))
write_csv(adm1_share, file.path(OUTPUT_DIR, "adm1_weight_shares.csv"))
write_csv(concentration_summary, file.path(OUTPUT_DIR, "weight_concentration_summary.csv"))

ggsave(file.path(figure_dir, "fig_top_adm2_weight_shares.pdf"), top_adm2_plot,
       width = 8, height = 6.5, bg = "white")

ggsave(file.path(figure_dir, "fig_top_adm1_weight_shares.pdf"), top_adm1_plot,
       width = 8, height = 5.8, bg = "white")

ggsave(file.path(figure_dir, "fig_cumulative_adm2_weight_share.pdf"), cumulative_adm2_plot,
       width = 7.2, height = 4.8, bg = "white")

ggsave(file.path(figure_dir, "fig_adm2_weight_share_hist.pdf"), adm2_weight_hist,
       width = 7.2, height = 4.8, bg = "white")

message("wrote: ", OUTPUT_DIR)
