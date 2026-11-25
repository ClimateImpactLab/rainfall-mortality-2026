# ==============================================================================
# checks.R
#
# Save named check tables as sheets in panel_checks.xlsx.
# Each build step replaces its own sheets and keeps the other steps' checks.
# Sourced by the scripts that save checks, after paths.R (needs check_dir).
# ==============================================================================

# --------------------
# Write check sheets
# --------------------

write_checks <- function(tables) {
  path <- file.path(check_dir, "panel_checks.xlsx")

  # Keep sheets already written by the other build steps
  previous <- list()
  if (file.exists(path)) {
    sheets <- readxl::excel_sheets(path)
    previous <- setNames(lapply(sheets, function(sheet) {
      readxl::read_excel(path, sheet = sheet, guess_max = 1048576,
                         .name_repair = "minimal")
    }), sheets)
  }

  # Replace these tables, rather than appending rows from another run
  previous[names(tables)] <- tables

  # Finish the new workbook before replacing the previous one
# so a failed write never leaves a broken checks file
  temporary <- paste0(path, ".tmp.xlsx")
  writexl::write_xlsx(previous, temporary)
  if (!file.rename(temporary, path)) stop("Could not save checks: ", path, call. = FALSE)
}
