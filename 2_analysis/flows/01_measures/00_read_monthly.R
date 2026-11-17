# ============================================================
# 00_read_monthly.R
#
# read_monthly(): one variable's monthly county files, stacked. Sourced by
# 04_explore_precip_flow_bins.R and 05_build_monthly_precip_flow_bins.R, so
# both read the monthly files the same way.
#
# Arguments: dir (folder of the yearly csvs), pattern (file name regex ending
# in the 4-digit year), value_col (the column to keep), first and last year.
# Returns: admin_id, year, month, <value_col>. 
# Dependencies: dplyr, readr, purrr (loaded by the caller)
# ============================================================

# one variable's monthly csvs for first-last: admin_id, year, month, value
read_monthly <- function(dir, pattern, value_col, first, last) {
  files <- list.files(dir, pattern = pattern, full.names = TRUE)
  yrs   <- as.integer(sub("^.*_([0-9]{4})\\.csv$", "\\1", basename(files)))
  files <- files[yrs >= first & yrs <= last]
  if (length(files) != last - first + 1) stop("expected one file per year ", first, "-", last, " in ", dir)

  out <- map_dfr(files, function(f) {
    # admin IDs as text so leading zeros stay (ID_1 = "01")
    read_csv(f, progress = FALSE,
             col_types = cols(month = "c", region_id = "c", ID_0 = "c", ID_1 = "c", ID_2 = "c", .default = "d")) %>%
      select(month, ID_1, ID_2, all_of(value_col))
  }) %>%
    mutate(admin_id = paste(ID_1, ID_2, sep = "_"), # USA mortality IDs, as in 01_build_usa_panel.R
           year     = as.integer(substr(month, 1, 4))) %>%
    select(admin_id, year, month, all_of(value_col))

  if (anyDuplicated(out[c("admin_id", "month")]) > 0) stop("duplicate county-months in ", dir)
  out
}
