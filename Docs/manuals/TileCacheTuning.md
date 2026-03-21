# Tile Cache Tuning (Field Manual)

This file describes the currently relevant cache parameters for map rendering, so we can run fast and reproducible per-user field tests.

## Purpose

- Control RAM usage and IO behavior
- Minimize white/gray edge tiles
- Quickly switch profiles for different devices/layouts

## Relevant Code Locations

- `RADIO/scripts/ethosmaps/lib/layout_default.lua`
  - `MAP_TILE_BUFFER_X`
  - `MAP_TILE_BUFFER_Y`
  - Raster calculation `mapTilesX/mapTilesY`
- `RADIO/scripts/ethosmaps/lib/tileloader.lua`
  - `TILE_CACHE_REFERENCE_MARGIN_TILES`
  - `TILE_CACHE_RING_TILES`
  - `TILE_CACHE_DIRECTIONAL_GUARD_TILES`
- `RADIO/scripts/ethosmaps/lib/maplib.lua`
  - `HEAVY_UPDATE_INTERVAL`
  - `RASTER_REBUILD_OFFSET_THRESHOLD`
  - Render-offset clamp (prevents small gray edge gaps)

## Current Default Values

### Raster (Viewport -> Tile Grid)

In `layout_default.lua`:

- `MAP_TILE_BUFFER_X = 1`
- `MAP_TILE_BUFFER_Y = 1`
- Formula:
  - `mapTilesX = max(MIN, ceil(viewportWidth/100) + MAP_TILE_BUFFER_X)`
  - `mapTilesY = max(MIN, ceil(viewportHeight/100) + MAP_TILE_BUFFER_Y)`

Note: The effective height depends on which `viewportHeight` is passed into `drawMap(...)`.

### Cache Keep-Window

In `tileloader.lua`:

- `TILE_CACHE_REFERENCE_MARGIN_TILES = 0`
- `TILE_CACHE_RING_TILES = 0`
- `TILE_CACHE_DIRECTIONAL_GUARD_TILES = 1`

Meaning:

1. Base is the currently visible raster (`tilesX/tilesY`)
2. No additional global ring
3. In the movement axis only, ±1 tile is kept as look-ahead/look-behind

## Parameter Behavior

### `TILE_CACHE_REFERENCE_MARGIN_TILES`

- Expands the keep area globally in X and Y
- Effect: less reloading, more RAM

### `TILE_CACHE_RING_TILES`

- Adds a global ring around the keep window
- Effect: more stable during turns/telemetry jumps, but expensive in RAM

### `TILE_CACHE_DIRECTIONAL_GUARD_TILES`

- Adds extra buffer in the current movement axis
- Effect: targeted and cheaper than a global ring

## Recommended Test Profiles

### Profile A: Minimal RAM (current)

- `REFERENCE_MARGIN = 0`
- `RING = 0`
- `DIRECTIONAL_GUARD = 1`

Use case: lowest RAM footprint with solid forward buffering.

### Profile B: More Forward Buffer

- `REFERENCE_MARGIN = 0`
- `RING = 0`
- `DIRECTIONAL_GUARD = 2`

Use case: if white edges still appear during fast movement/turns.

### Profile C: Conservative

- `REFERENCE_MARGIN = 0..1`
- `RING = 1`
- `DIRECTIONAL_GUARD = 1`

Use case: maximum robustness when RAM is less critical.

## Troubleshooting (Quick)

### Gray edge at trailing border (10–20 px)

- Check whether render-offset clamp is active (`maplib.lua`)
- If still visible, increase `DIRECTIONAL_GUARD` for testing

### White tiles in flight direction

- Test `DIRECTIONAL_GUARD = 2`
- If still visible, try `RING = 1` only as a last resort

### High RAM peak

- Set `RING = 0`
- Set `REFERENCE_MARGIN = 0`
- Keep `DIRECTIONAL_GUARD = 1`

## Change Rule

For field tests, always change only **one** parameter at a time, then:

1. 2–3 minutes replay on mostly straight movement
2. 2–3 minutes with frequent turns
3. Record peak RAM + visible artifacts

This keeps effects clearly attributable.
