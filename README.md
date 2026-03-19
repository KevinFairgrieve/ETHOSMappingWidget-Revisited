# EthosMappingWidget

**Scalable Mapping Widget for Ethos OS**

A modern, fully scalable version of the popular Yaapu Mapping Widget for FrSky Ethos.  
It displays your real-time GPS position on a supported map type of your choice and works perfectly on **any** widget size — from Fullscreen down to very small custom layouts.

## Download
- Releases and Pre-Tested Beta-Versions can be downloaded from https://github.com/b14ckyy/ETHOSMappingWidget-Revisited/releases
- If you want to try out the latest running development version, download from the `main` branch directly (usually working fine but just roughly tested).
- other branches are in active development and should not be used and no feedback to these will be accepted.

## Features

- Real-time moving map with satellite imagery
- Dynamic zoom levels (manual via touch or buttons)
- UAV position marker with heading
- Home position marker and Home Arrow
- Scale bar with distance indication
- Trail history
- Visual Zoom Buttons (+ / -) on the right edge
- Works in Fullscreen, Split-Screen and all custom widget sizes
- Optimized tile loading and performance

![As Full Screen Widget](images/screenshots/screenshot-2026-03-15-39603.jpg)

![Multi Instance Possible](images/screenshots/screenshot-2026-03-15-39795.jpg)

![Tiny Widget with others](images/screenshots/screenshot-2026-03-15-40068.jpg)

## Installation

### Quick Start (Works with Existing Yaapu Tiles!)

1. Download the repository to your PC
2. Copy the `scripts` and `bitmaps` folders (from `RADIO`) to your SD card or Radio storage
3. Restart your radio completely
4. Add the widget to any screen

**That's it!** If you already have Yaapu map tiles, the widget automatically finds and uses them.

### Folder Structure Expected

```
RADIO/ or SD/
├── scripts/
│   └── ethosmaps/          ← all .lua files (copy as-is)
│       ├── lib/            ← helper libraries
│       ├── audio/          ← notification sounds (optional)
│       └── main.lua        ← main widget code
└── bitmaps/
    ├── ethosmaps/
    │   ├── maps/           ← new native EthosMaps tiles
    │   └── bitmaps/        ← widget graphics
    └── yaapu/              ← existing Yaapu tiles (auto-detected & used)
        └── maps/           ← your GMapCatcher / Google tiles
```

**Important Notes:**
- Script and Map Tiles must be on the same drive (Radio or SD) as your other scripts
- Existing Yaapu tiles in `/bitmaps/yaapu/maps/` are automatically discovered and used
- No need to reorganize or duplicate tiles if you already use Yaapu
- New EthosMaps tiles can be added anytime — seamless mixing with Yaapu tiles 

## Usage

- Touch buttons on the left side to zoom in/out
- The map centers automatically on the current UAV position
- The Home Arrow shows the direction and distance to home
- The Scale Bar shows the current map scale
- Basic Telemetry widgets at the Bottom show GroundSpeed, Heading, DistanceToHome and TravelDistance
- Customizable widgets (up to 4) at the top including one specifically for LQ or RSSI and Transmitter Voltage

## Seamless Multi-Source Tile Support: EthosMaps + Yaapu

This widget supports a **fully transparent fallback system** that allows you to use existing Yaapu tile layouts alongside new native EthosMaps providers. Whether you're sharing map tiles with Yaapu Telemetry or gradually migrating to EthosMaps, the system handles it seamlessly.

### How It Works

**Tile Loading Priority (Automatic):**

1. **Primary (EthosMaps)**: Try native EthosMaps folder structure first
   - Supports multiple providers: `GOOGLE`, `ESRI`, `OSM`, etc.
   - Each provider offers independent map types
   - Latest provider technology

2. **Fallback (Yaapu Paths)**: If EthosMaps tiles not found (only Google), automatically load from Yaapu structure, if available
   - GMapCatcher: Works with existing Yaapu `/bitmaps/yaapu/maps/` layout but is not natively supported in `etosmaps` path
   - Google: Falls back to legacy Yaapu Google map folders
   - Seamless integration — **users don't notice the switch**

3. **Result**: Mix EthosMaps and Yaapu tiles on the **same map**, or use pure Yaapu layouts

### Practical Scenarios

**Scenario 1: Existing Yaapu User**
- Your Yaapu Telemetry has GMapCatcher tiles in `/bitmaps/yaapu/maps/`
- Just add the EthosMappingWidget to your radio
- It automatically finds and uses your existing tiles
- **No tile duplication or file movement needed**

**Scenario 2: Gradual Yaapu → EthosMaps Migration**
- Start downloading EthosMaps GOOGLE tiles to `/bitmaps/ethosmaps/maps/GOOGLE/`
- Widget loads EthosMaps tiles where available
- Falls back to Yaapu tiles for gaps
- No downtime during transition

**Scenario 3: New EthosMaps-Only Setup**
- Use `/bitmaps/ethosmaps/maps/` exclusively
- Access new providers (ESRI, OSM) not available in Yaapu
- Better organization and performance

### Folder Structure & Naming

**EthosMaps (New Native Format):**
```
/bitmaps/ethosmaps/maps/
├── GOOGLE/
│   ├── Map/{level}/{tileY}/s_{tileX}.png
│   ├── Satellite/{level}/{tileY}/s_{tileX}.png
│   ├── Hybrid/{level}/{tileY}/s_{tileX}.png
│   └── Terrain/{level}/{tileY}/s_{tileX}.png
├── ESRI/
│   ├── Map/{level}/{tileY}/s_{tileX}.png
│   └── Satellite/{level}/{tileY}/s_{tileX}.png
└── OSM/
    └── Map/{level}/{tileY}/s_{tileX}.png
```

**Yaapu (Legacy Format - Automatically Supported):**
```
/bitmaps/yaapu/maps/
├── sat_tiles/{level}/{x/1024}/{x%1024}/{y/1024}/s_{y%1024}.png
├── map_tiles/{level}/{x/1024}/{x%1024}/{y/1024}/s_{y%1024}.png
├── GoogleMap/{level}/{x/1024}/{x%1024}/{y/1024}/s_{y%1024}.png
├── GoogleSatelliteMap/{level}/{x/1024}/{x%1024}/{y/1024}/s_{y%1024}.png
├── GoogleHybridMap/{level}/{x/1024}/{x%1024}/{y/1024}/s_{y%1024}.png
└── GoogleTerrainMap/{level}/{x/1024}/{x%1024}/{y/1024}/s_{y%1024}.png
```

### Naming Conventions (Strict for Predictability)

- **EthosMaps provider folders**: FULL CAPS (`GOOGLE`, `ESRI`, `OSM`)
- **Map type folders**: Exact Title-Case (`Map`, `Satellite`, `Hybrid`, `Terrain`)
- **Yaapu folders**: Original Yaapu naming (automatically mapped for compatibility)
- **UI Display**: Provider names shown in readable format (`Google`, `ESRI`), but internal paths remain strict
- **Invalid selections**: If no tiles found, settings show `NONE` and dependent options are disabled

### Key Advantages

| Feature | EthosMaps | Yaapu (Fallback) |
|---------|-----------|------------------|
| Providers | GOOGLE, ESRI, OSM, others | GMapCatcher, Google only |
| Map organization | Per-provider folders | Single shared folder |
| New features | ✅ Supported | ❌ Limited |
| Existing Yaapu tiles | ✅ Automatic fallback | ✅ Native support |
| Mixed tile sources | ✅ Seamless | N/A |

## Unified Zoom Settings

Zoom configuration is unified across all map providers to keep the settings menu simple and consistent.

- `Map zoom`: default zoom level used when the map is initialized
- `Map zoom min`: lower zoom limit
- `Map zoom max`: upper zoom limit

Notes:

- Provider-specific zoom settings are no longer used.
- Existing installations are migrated automatically from legacy provider-specific zoom keys.
- If no valid provider or map type is available, the UI shows `NONE` and map-related selection fields are disabled.

## Custom Enhancements & Modifications

This version includes extensive custom improvements:
- Full dynamic scaling for any widget size (including Tiny and Ultra-Tiny modes)
- Smart element hiding (Top/Bottom bars, telemetry values, overlays) when space is limited
- Improved Scale Bar visibility and background
- Refined "Home Not Set" warning with dynamic box sizing
- Better performance and reduced tile loading in small widgets

## Credits

- Original concept and base code: Yaapu (Alessandro Apostoli)
- Heavy modifications and scalability enhancements: b14ckyy
