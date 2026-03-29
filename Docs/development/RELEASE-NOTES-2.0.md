# ETHOS Mapping Widget 2.0

A major update with touch panning, observation marker, vehicle symbols, INAV waypoint missions, CRSF/ELRS support, flight trail, BMP tiles, extensive performance work, and comprehensive documentation.

## What's New

### Touch Panning & Detached Mode
The map now supports **touch-based panning** in fullscreen mode. Drag to scroll the map freely while your UAV continues to fly.

- **Follow-lock toggle** — switch between GPS tracking and free exploration with the lock button
- **Detached viewport** — pan offset is preserved across frames and zoom changes
- **Crosshair** at viewport center when unlocked
- **UAV edge arrow** — pointer at the screen edge when the vehicle is off-screen

### Observation Marker
Place a **custom marker** anywhere on the map using the pin button. A green heading line is drawn from the UAV to the marker, and the marker coordinates are persisted across sessions.

### Vehicle Symbols
Three configurable UAV symbol styles replace the old fixed arrow:
- **Arrow** (default) — classic heading indicator
- **Airplane** — flying wing silhouette
- **Multirotor** — X-frame quadcopter

Select in widget settings under **UAV symbol**.

### Home Edge Marker
The old home direction arrow has been replaced with a **home edge marker** — when the home position is off-screen, an arrow at the screen border points toward it. Both UAV and home edge markers are rendered on top of all overlays for visibility.

### Flight Trail
A configurable trail shows your flight path history on the map:
- **Resolution settings** — Off / 20m / 50m / 100m / 500m / 1km
- **Bend threshold** — 3–15° to control path detail
- Ring-buffer with viewport clipping for smooth performance

### INAV Waypoint Mission Overlay
The widget can now automatically download and display waypoint missions from your INAV flight controller. The mission path, numbered waypoint markers, and active navigation state are rendered directly on the map in real-time.

- **Automatic download** — mission is fetched via MSP as soon as the FC is connected
- **Live tracking** — the active waypoint is highlighted with a green ring; RTH waypoints show in orange
- **Dual transport** — works over SmartPort and CRSF/ELRS (automatic detection and fallback)
- **Full mission visualization** — RTH return paths, heading arrows, jump indicators
- **Nav-aware UAV coloring** — green for NAV/HOLD, orange for RTH

Enable in widget settings: **Waypoint download (INAV)** → ON

### BMP Tile Support
In addition to JPG and PNG, the widget now supports **BMP (24-bit)** tiles. BMP has zero CPU decode cost and may outperform JPG on older Horus radios (STM32F4). Tile format priority: JPG → BMP → PNG (auto-detected per tile).

### Zoom Control via RC Channel
Zoom can now be controlled via an **RC channel** instead of (or alongside) touch buttons:
- **3-Position** — edge-triggered zoom steps at >60% threshold
- **Proportional** — continuous channel-to-zoom mapping with apply delay
- Supports channels 1–64

### Default Position
Set a **default map position** via the context menu (long press → Set Default Position). The map centers on this position when no GPS fix is available — useful for pre-flight briefing.

### Performance Improvements
Extensive optimization work since 1.0:
- Embedded Lua performance optimizations (3-tier approach)
- Cached `lcd.RGB` colors — removed 14 per-frame calls
- Hot-path caching in draw/map/tile libraries
- Bitmap GC-timing fix preventing ETHOS OOM at ~831KB
- Async tile loading architecture with full-speed map redraw
- WP drawing optimized from 5 to 2 rendering passes

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
- Fixed scale bar not shown for ESRI and OSM map providers
- Fixed sensor fallback: heading/speed correctly fall back to calculated values
- Fixed GPS 0,0 guard preventing false trail line at startup
- Fixed memory leaks: GPS source caching, topBarValueCache bounded
- Fixed waypoint numbering for off-screen waypoints
- Fixed CRSF GPS nil safety (no more crashes from nil lat/lon)
- Fixed unlock-mode markers not showing in detached panning mode
- Fixed CRSF pushFrame/popFrame API compatibility
- Fixed provider-switch tile cache bug
- Improved MSP reliability with auto-retry and timeout handling

## Compatibility
- **Radios**: All FrSky radios running ETHOS 1.6+ (TANDEM, TWIN, Horus series)
- **Flight Controllers**: INAV (for waypoint features), any FC with GPS telemetry (for basic map)
- **Transports**: SmartPort, CRSF/ELRS
- **Tile formats**: JPG (recommended), PNG, BMP (24-bit)
