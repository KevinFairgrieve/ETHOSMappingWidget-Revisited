# Migration Guide: 1.x → 2.0

This guide covers what changed between version 1.x and 2.0 and what you need to do when upgrading.

## Quick Summary

| Area | Change | Action Required |
|------|--------|-----------------|
| Folder structure | `RADIO/` renamed to `src/` in the repository | **None** — the release ZIP still extracts to the correct SD card paths |
| Tile folders | Native EthosMaps path is now the primary format | **Only if** you had custom (non-Yaapu) tile folders in a non-standard layout |
| Settings | Settings key may be reset between major versions | Re-configure widget settings after update |
| MSP stack | Complete rewrite with native V1/V2 support | **None** — transparent improvement |
| Minimum ETHOS | 1.6 required | Update your radio firmware if below 1.6 |

## Tile Folder Changes

### What Changed

Version 2.0 expects native EthosMaps tiles under:

```
bitmaps/ethosmaps/maps/<PROVIDER>/<MapType>/<z>/...
```

with strict naming:
- Provider: `GOOGLE`, `ESRI`, `OSM` (uppercase)
- Map type: `Satellite`, `Hybrid`, `Street`, `Map`, `Terrain` (title case)

### What Is NOT Affected

- **Yaapu tiles** in `bitmaps/yaapu/maps/` continue to work as before (auto-detected fallback for Google)
- **Tiles downloaded with the High Resolution Map Generator** using output target `b14ckyy ETHOS Mapping Widget` are already in the correct format

### Who Needs to Migrate

Only users who had tiles in a **custom non-standard layout** that was neither Yaapu nor the native EthosMaps format (1.0-beta). If you downloaded tiles with the recommended downloader tool, no changes are needed.

### Migration Steps (if needed)

1. Create provider folders under `bitmaps/ethosmaps/maps/`:
   ```
   GOOGLE/
   ESRI/
   OSM/
   ```
2. Move each map type into the correct provider/type subfolder (exact case)
3. Ensure the coordinate layout matches the provider:
   - Google / OSM: `{z}/{x}/{y}.ext`
   - ESRI: `{z}/{y}/{x}.ext`
4. Restart the radio and verify in widget settings that the provider and map type are detected

## Settings Reset

Widget settings are stored under a versioned key. When upgrading from 1.x to 2.0, **settings will be reset to defaults**. You'll need to re-configure:

- Map provider and type
- Zoom levels (min / default / max)
- Top bar telemetry sensors
- Units (metric / imperial)
- Feature toggles (trail, waypoints, etc.)

Settings are preserved between minor releases (e.g. 2.0 → 2.1).

## MSP Stack

The MSP waypoint download system was newly implemented in 2.0:

- **Native MSP V1/V2 protocol** support
- **Dual transport**: SmartPort and CRSF/ELRS with automatic fallback
- **Auto-retry** on connection loss (5-second intervals)
- **INAV FC detection** with version validation

## New Features in 2.0

Features added since 1.0 that are available after upgrading:

- CRSF/ELRS transport for MSP waypoint download
- Active waypoint tracking with nav-mode coloring
- BMP tile support
- Touch panning with observation marker (fullscreen)
- Multiple vehicle symbol styles (Arrow, Airplane, Multirotor)
- Edge arrows when UAV or home is off-screen
- Default position setting for map initialization

For details on all features, see the [Overview](Overview.md).

## Updating

1. Download the latest release ZIP from [GitHub Releases](https://github.com/b14ckyy/ETHOSMappingWidget-Revisited/releases)
2. Extract to the SD card root — existing files are overwritten
3. Reboot the radio
4. Re-configure widget settings

See [Installation Guide](Installation.md) for full instructions.
