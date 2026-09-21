#!/bin/bash
# Download one year of CHIRPS v2.0 daily 0.05-degree precipitation.
#
# The script reads one annual NetCDF from the UCSB CHIRPS server. It writes to a
# temporary file, checks the NetCDF shape, and only then moves the file into the
# final CHIRPS folder.
#
# Inputs:
# - one year argument, for example 2024
# - CHIRPS annual NetCDF files from the UCSB CHIRPS v2.0 archive
#
# Outputs:
# - chirps-v2.0.YEAR.days_p05.nc in the CHIRPS raw NetCDF folder
#
# This is safe to rerun. If the final file already exists and passes the basic
# checks, the script leaves it alone.

set -euo pipefail

# Default paths match the climate aggregation code. Environment variables are
# kept here so a test run can point to another destination without editing code.
YEAR=${1:?Usage: download_chirps_year.sh YEAR}
DEST_DIR=${CHIRPS_DEST_DIR:-/project/cil/gcp/climate/CHIRPS/Raw_NetCDF_p05deg_by_p05deg/PRCP}
BASE_URL=${CHIRPS_BASE_URL:-https://data.chc.ucsb.edu/products/CHIRPS-2.0/global_daily/netcdf/p05}
PYTHON=${PYTHON:-/project/cil/home_dirs/mdefranciosi/envs/era5land/bin/python}

# Build the file names once so the existing-file and new-download paths use the
# same target.
file="chirps-v2.0.${YEAR}.days_p05.nc"
url="${BASE_URL}/${file}"
final="${DEST_DIR}/${file}"
tmp="${final}.tmp.${SLURM_JOB_ID:-manual}.${SLURM_ARRAY_TASK_ID:-${YEAR}}"

if (( YEAR < 1981 || YEAR > 2100 )); then
    echo "Bad CHIRPS year: ${YEAR}" >&2
    exit 2
fi

mkdir -p "$DEST_DIR"

# Existing files are checked before skipping, so a bad partial file is not
# silently treated as done.
if [[ -s "$final" ]]; then
    "$PYTHON" - "$final" "$YEAR" <<'PY'
import calendar
import sys
from netCDF4 import Dataset

path = sys.argv[1]
year = int(sys.argv[2])
expected_days = 366 if calendar.isleap(year) else 365

with Dataset(path) as data:
    assert "precip" in data.variables, "missing precip variable"
    assert len(data.dimensions["time"]) == expected_days, "unexpected time dimension"
    assert len(data.dimensions["latitude"]) == 2000, "unexpected latitude dimension"
    assert len(data.dimensions["longitude"]) == 7200, "unexpected longitude dimension"
PY
    echo "existing verified: ${final}"
    exit 0
fi

# Download to the temp path first. The final file only appears after the NetCDF
# check below passes.
rm -f "$tmp"
echo "downloading ${url}"
curl --fail --location --retry 5 --retry-delay 20 --connect-timeout 60 \
    --output "$tmp" "$url"

# CHIRPS p05 daily files should have one time slice per day and the full global
# 0.05-degree grid. Also check that precipitation is in millimeters.
"$PYTHON" - "$tmp" "$YEAR" <<'PY'
import calendar
import sys
from netCDF4 import Dataset

path = sys.argv[1]
year = int(sys.argv[2])
expected_days = 366 if calendar.isleap(year) else 365

with Dataset(path) as data:
    assert "precip" in data.variables, "missing precip variable"
    assert len(data.dimensions["time"]) == expected_days, "unexpected time dimension"
    assert len(data.dimensions["latitude"]) == 2000, "unexpected latitude dimension"
    assert len(data.dimensions["longitude"]) == 7200, "unexpected longitude dimension"
    units = getattr(data.variables["precip"], "units", "")
    assert "mm" in units.lower(), f"unexpected precip units: {units}"
PY

# The temp file has passed the checks, so it can replace the final file.
mv "$tmp" "$final"
chmod g+w "$final"
echo "wrote ${final}"
