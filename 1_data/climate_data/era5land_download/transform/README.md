# ERA5-Land Transforms and Merges

This folder contains scripts that run after the monthly regional downloads.

There are two kinds of transforms here:

1. convert downloaded month-region files into the annual-by-variable layout;
2. merge component region files into final region folders.

## File Layout Conversion

The conversion script is:

```text
convert_monthly_to_annual_by_variable.py
```

The download scripts originally save daily data by region and year, with one monthly file containing all variables. The final daily data location uses a different layout:

```text
/project/cil/gcp/climate/ERA5-LAND/raw/daily/<region>/<variable>/era5land_<region>_<variable>_<year>.nc4
```

This script does that reshaping.

## Region Merges

The merge scripts are:

```text
merge_asia_components.py
merge_mexico_components.py
merge_brazil_components.py
```

They build the final merged folders:

| Final folder now | Better name | Built from |
|---|---|---|
| `asia_combined` | `asia` | `india` + `asia_east` |
| `mexico` | `north_america` | `usa` + `mexico_south` |
| `brazil` | `latin_america` | `latam` + `brazil_east` |

The merged folders already contain final daily files. The issue is mostly naming and documentation.

The component folders should eventually be moved out of the main data directory so they are not used by mistake.

## Sbatch Files

The sbatch files are examples for compute-node runs and should be edited for the year range (and region) before submission.

The merge scripts read and write large NetCDF files. Run them through Slurm, not on the login node.
