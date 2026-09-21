# ERA5-Land Nearby Cell Rules

Sometimes an admin unit has ERA5-Land grid cells, but all of those cells are
missing climate data. This usually comes from the ERA5-Land land mask, and it
mostly affects small islands or coastal units.

When that happens, we only move the weights for reviewed admin units listed in
the fallback ID CSVs.

## Main Climate Variables

For precipitation and temperature, use a nearby cell only when all of these are
true:

- the admin unit is needed in the mortality panel
- the normal grid cells are all missing climate data
- the replacement cell has valid precipitation and temperature data
- the replacement cell is no more than `0.5` degrees away
- the admin unit is listed in the reviewed fallback ID CSVs



Listed units:

| Country | Units |
|---|---:|
| CHL | 2 |
| IND | 1 |
| PHL | 23 |
| USA | 1 |

Units that are farther than `0.5` degrees stay missing.

## Wind

Wind uses a separate rule: use a nearby cell only when all of these are true:

- the normal wind cells are all missing
- the replacement cell has valid `wind_max`
- the replacement cell is no more than `1.6` degrees away

Wind audit files are written here:

```text
/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/<COUNTRY>/wind/fallback_audit/
```

Units farther than `1.6` degrees stay missing.

## Rule Of Thumb

If the nearby-cell choice was not reviewed and checked, leave the unit missing.
