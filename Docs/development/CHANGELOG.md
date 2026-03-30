# Changelog

All notable changes to the ETHOS Mapping Widget, grouped by version. Trivial fixes (typos, formatting) are omitted.

---

## 2.0-beta1 (2026-03-29)

### Breaking
- Repository restructured: `RADIO/` → `src/`, build script produces release ZIP
- Settings key reset from 1.x — re-configuration required after upgrade

### Added
- **User documentation**: Installation Guide, Overview, Map Tiles Guide, Troubleshooting, Migration Guide
- Build script (`Build-Release.ps1`) with automatic version + commit hash in ZIP filename

### Changed
- README significantly trimmed — detailed content moved to dedicated manuals
- Screenshots renamed to descriptive names (overview, providers, maptypes, splitscreen, nomap)

### Fixed
- WP drawing performance: reduced from 5 to 2 rendering passes
- Unlock-mode markers now visible in detached panning mode
- CRSF GPS nil safety: guard against nil latitude/longitude from CRSF transport
- Correct waypoint numbering for off-screen waypoints

### Refactored
- Complete MSP stack rewrite with native V1/V2 protocol support

---

## 1.1.0-beta1 (2026-03-26)

### Added
- **INAV waypoint mission overlay**: automatic MSP download, path rendering, waypoint markers
- **CRSF/ELRS transport** for MSP waypoint download (dual transport: SmartPort + CRSF)
- **Transport fallback**: try CRSF after SmartPort timeout (5s each)
- **MSP_NAV_STATUS polling**: active waypoint tracking with green ring indicator
- **Nav-aware UAV coloring**: green for NAV/HOLD, orange for RTH
- **Waypoint download ON/OFF setting** in widget configuration
- RTH path arrows, SET_HEAD chevrons, JUMP indicators on waypoint overlay
- Arming detection and automatic home position setting via MSP
- Documentation for waypoint missions and panning/marker features

### Fixed
- CRSF pushFrame/popFrame API compatibility + crsf as userdata support
- CRSF probe no longer gated on RSSI source name
- MSP-over-CRSF aligned with TBS CRSF specification
- ArmingOnly retry bug fixed
- Reduced memory allocations in panning and dense-waypoint scenarios

### Changed
- Settings reordered: debug tools moved below telemetry section
- Trail threshold blocked when trail feature is disabled
- Waypoint rings changed from black outlines to alpha-filled circles
- SET_HEAD and JUMP chevron arrows scaled 2.5× larger

---

## 1.0.0 (2026-03-22)

### Added
- **Flight trail system**: configurable resolution (Off/20m/50m/100m/500m/1km) + bend threshold (3–15°)
- **Touch panning**: drag-to-pan with state machine (IDLE/PENDING/DRAGGING/GRACE)
- **Follow-lock toggle**: button to switch between GPS-tracking and detached viewport
- **Observation marker**: pin a marker at viewport center, green heading line to marker
- **Vehicle symbol styles**: Arrow, Airplane, Multirotor (configurable)
- **Edge arrows**: pointer when UAV is off-screen in detached mode
- **Default position setting**: pre-configure map center for GPS-less startup
- **BMP tile support** (24-bit): zero-decode alternative for older radios
- **Tile format priority**: JPG → BMP → PNG (auto-detection per tile)
- **Debug telemetry input mode**: external sensor sources for GPS, heading, speed
- **Settings version guard** with `system.getVersion()` compatibility check
- Crosshair at viewport center when unlocked
- Marker coordinates persisted via `storage.read/write`
- `pixel_to_coord` inverse Mercator projection

### Performance
- Complete code cleanup: removed 222 lines of dead Yaapu legacy code (Step 1)
- Consolidated `flagEnabled` (5→1) and `getTime` (4→1) helpers (Step 2)
- Replaced verbose debug/perf guards with cached booleans (Step 3)
- Optimized `drawTiles` bitmap cache, fixed provider-switch bug (Step 4)
- Simplified `clearTable`, removed `lfs/pathExists`, fixed queue nil-path bug (Step 5)
- Hot-path caching in drawlib, maplib, tileloader (Step 6)
- Bitmap GC-timing fix: `pendingGCBeforeLoad` prevents OOM at ~831KB
- Tier 1/2/3 embedded Lua optimizations (field caching, pcall cache, getTime cache)
- Cached 6 `lcd.RGB` colors — removed 14 per-frame calls
- Fixed `string.sub` regression in drawlib
- Tile loader cache optimizations with Cohen-Sutherland viewport clipping
- Ring-buffer (51 slots) with O(1) rotation for trail waypoints
- 15px minimum segment length to merge short trail segments

### Fixed
- Scale bar not shown for ESRI and OSM map providers
- Redundant `coord_to_tiles()` call removed (saved sin/log per frame)
- `homeLon` nil-check alongside `homeLat` guard
- 14 dead variables removed
- `resetLib`: `status.layout = {}` instead of `{ nil }`
- Sensor fallback: heading/speed correctly fall back to calculated values when external source cleared
- GPS 0,0 guard prevents false trail line at startup
- Memory leak fixes: GPS source caching, `topBarValueCache` bounded
- Provider-switch tile cache bug

### Changed
- Async tile loading architecture with full-speed map redraw
- Tile cache strategy tuned for viewport rendering stability
- Top/bottom bar text alignment and sizing stabilized
- New loading bitmap and reworked loading screen design
- Telemetry source (ETHOS/Sensors) decoupled from debug log toggle

---

## Pre-1.0 (2026-03-14 – 2026-03-21)

### Added
- Multi-provider support: Google, ESRI, OSM with independent map types
- Native EthosMaps tile folder structure (`bitmaps/ethosmaps/maps/`)
- Yaapu tile fallback (Google + GMapCatcher auto-detection)
- Dynamic layout scaling for any widget size (fullscreen to tiny)
- Smart element hiding when widget area is limited
- Minimum widget size warning (200×100 px)
- Zoom buttons (touch + hardware key support)
- Home position marker and home direction arrow
- Scale bar with distance indication
- Top bar with customizable telemetry sensors
- Bottom bar with speed, heading, distance, travel
- Debug logger with stream rollover
- Performance monitor
- Telemetry replay tools for ETHOS simulator

### Changed
- Widget key changed to coexist with Yaapu (`ethosmaps` instead of `yaapumaps`)
- Extensive code cleanup: removed old unused Yaapu code in multiple passes
- Comments reworked and translated to English
- Obsolete `hudlib.lua` and GPS source setting removed

### Fixed
- Map type switching stability and tile lookup diagnostics
- Variable reuse conflict
- Button visibility tweaks
- Various performance optimizations for CPU load reduction

---

## Initial Release (2026-03-14)

- Fork of Yaapu Mapping Widget for FrSky ETHOS
- Basic moving map with Google satellite tiles
- UAV position tracking with heading
- Home marker
- Dynamic scaling groundwork
