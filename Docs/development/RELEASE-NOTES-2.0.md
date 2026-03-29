# ETHOS Mapping Widget 2.0

A major update with INAV waypoint mission support, CRSF/ELRS compatibility, and comprehensive documentation.

## What's New

### INAV Waypoint Mission Overlay
The widget can now automatically download and display waypoint missions from your INAV flight controller. The mission path, numbered waypoint markers, and active navigation state are rendered directly on the map in real-time.

- **Automatic download** — mission is fetched via MSP as soon as the FC is connected
- **Live tracking** — the active waypoint is highlighted with a green ring; RTH waypoints show in orange
- **Dual transport** — works over SmartPort and CRSF/ELRS (automatic detection and fallback)
- **Full mission visualization** — RTH return paths, heading arrows, jump indicators

Enable in widget settings: **Waypoint download (INAV)** → ON

### Improved Map Controls
- New high-resolution button icons for zoom, follow-lock, and observation marker
- Waypoint rendering optimized for smooth performance even with complex missions

### Comprehensive Documentation
This release includes a full set of user manuals — available both in the repository and linked from the README:

| Guide | What it covers |
|-------|---------------|
| **[Installation](Docs/manuals/Installation.md)** | Step-by-step setup, folder structure, adding tiles |
| **[Overview](Docs/manuals/Overview.md)** | Complete UI guide, all settings explained, context menu |
| **[Map Tiles](Docs/manuals/MapTilesGuide.md)** | Providers, formats, folder structure, Yaapu compatibility |
| **[Panning & Marker](Docs/manuals/PanningAndMarker.md)** | Touch panning, observation marker, detached mode |
| **[Waypoint Missions](Docs/manuals/WaypointMission.md)** | INAV waypoint overlay setup and usage |
| **[Custom Layouts](Docs/manuals/CustomLayouts.md)** | Split-screen and smaller widget sizes |
| **[Troubleshooting](Docs/manuals/Troubleshooting.md)** | Common problems and solutions |
| **[Migration Guide](Docs/manuals/MigrationGuide.md)** | Upgrading from 1.x |

## Upgrading from 1.x

- **Map tiles**: If you use the [High Resolution Map Generator](https://martinovem.github.io/High-Resolution-Map-Generator/) or have Yaapu tiles, **no changes needed** — everything works as before.
- **Settings**: Widget settings are reset when upgrading from 1.x to 2.0. You'll need to re-configure your preferences (map provider, zoom, telemetry sensors, etc.).
- **Minimum ETHOS version**: 1.6

See the [Migration Guide](Docs/manuals/MigrationGuide.md) for full details.

## Installation

1. Download the ZIP below
2. Extract to the root of your SD card
3. Reboot the radio
4. Add the **ETHOS Maps** widget to any screen

Full instructions: [Installation Guide](Docs/manuals/Installation.md)

## Bug Fixes
- Fixed waypoint numbering for off-screen waypoints
- Fixed CRSF GPS nil safety (no more crashes from nil lat/lon)
- Fixed unlock-mode markers not showing in detached panning mode
- Fixed CRSF pushFrame/popFrame API compatibility
- Improved MSP reliability with auto-retry and timeout handling

## Compatibility
- **Radios**: All FrSky radios running ETHOS 1.6+ (TANDEM, TWIN, Horus series)
- **Flight Controllers**: INAV (for waypoint features), any FC with GPS telemetry (for basic map)
- **Transports**: SmartPort, CRSF/ELRS
- **Tile formats**: JPG (recommended), PNG, BMP (24-bit)
