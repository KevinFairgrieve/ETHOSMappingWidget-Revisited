# INAV Waypoint Mission Overlay

The widget supports automatic download and display of INAV waypoint missions from the flight controller using the MSP (MultiWii Serial Protocol) protocol. Missions are rendered as a path overlay on the map with interactive markers and real-time active waypoint tracking.

## Requirements

- INAV flight controller with waypoint mission loaded
- SmartPort (FrSky ACCESS / ACCST / TD) **or** CRSF (Crossfire / ELRS) telemetry link
- "Waypoint download (INAV)" enabled in widget settings (default: on)

## Transport Layer

The widget auto-detects the available telemetry transport on startup:

| Transport  | Detection                          | Max Payload | Notes              |
|------------|-------------------------------------|-------------|--------------------|
| SmartPort  | `RSSI` source + `sport.getSensor()` | 6 bytes     | Fully tested       |
| CRSF/ELRS  | `1RSS` source + `crsf.getSensor()`  | 58 bytes    | Experimental       |

SmartPort is tried first. If no SmartPort sensor is found, CRSF is attempted as fallback. If neither transport is available, the MSP module enters an error state and retries after 5 seconds.

## Download State Machine

The MSP module operates as a state machine with the following states:

| State          | Description                                                    |
|----------------|----------------------------------------------------------------|
| OFF            | MSP not started                                                |
| CONNECTING     | Identifying flight controller via `MSP_FC_VARIANT` (ID 2)     |
| GET_WP_INFO    | Requesting waypoint count via `MSP_WP_GETINFO` (ID 20)        |
| DOWNLOADING    | Fetching individual waypoints via `MSP_WP` (ID 118)           |
| DONE           | Download complete, polling for arming state and nav status     |
| ERROR          | Error occurred, automatic retry after 5 seconds                |

### Download Flow

1. **Connect**: Send `MSP_FC_VARIANT` → receive 4-char FC identifier (e.g. `INAV`)
2. **Get WP Info**: Send `MSP_WP_GETINFO` → receive waypoint count and validity flag
3. **Download WPs**: For each WP index (1 to count), send `MSP_WP` with requested index → receive 21 bytes per waypoint:
   - `idx` (1 byte) — waypoint index
   - `action` (1 byte) — action type
   - `lat` (4 bytes) — latitude × 10⁷
   - `lon` (4 bytes) — longitude × 10⁷
   - `alt` (4 bytes) — altitude in cm
   - `p1` (2 bytes) — parameter 1
   - `p2` (2 bytes) — parameter 2
   - `p3` (2 bytes) — parameter 3
   - `flags` (1 byte) — `0xA5` marks mission end
4. **Done**: Parsed mission stored; begin polling `MSP_STATUS` (arming) and `MSP_NAV_STATUS` (navigation)

### Polling Intervals

| Poll Target      | Interval | Condition        |
|------------------|----------|------------------|
| MSP_STATUS       | 5 s      | Always (in DONE) |
| MSP_NAV_STATUS   | 2 s      | Only when armed  |

## Waypoint Action Types

| Action         | ID | Description                      | Has Position | Navigable |
|----------------|----|----------------------------------|--------------|-----------|
| WAYPOINT       | 1  | Fly to coordinate                | Yes          | Yes       |
| POSHOLD_TIME   | 3  | Loiter at position for N seconds | Yes          | Yes       |
| RTH            | 4  | Return to home                   | No           | No        |
| SET_POI        | 5  | Point of interest (camera)       | Yes          | No        |
| JUMP           | 6  | Jump to WP index, repeat N times | No           | No        |
| SET_HEAD       | 7  | Set heading direction            | No           | No        |
| LAND           | 8  | Landing position                 | Yes          | Yes       |

**Navigable** waypoints are connected with path lines on the map. Non-navigable actions (RTH, JUMP, SET_HEAD) modify navigation behavior but do not represent physical positions in the flight path.

## Map Rendering (5-Pass System)

The waypoint overlay is rendered in five passes to ensure correct layering:

### Pass 1 — SET_POI Markers
Red bullseye markers for Point of Interest waypoints. Drawn as concentric red rings with a center dot.

### Pass 2 — WP Markers & Path Lines
- **Path lines**: Green lines connecting consecutive navigable waypoints
- **WP circles**: Semi-transparent black shadow fill (alpha 0.4) with contrast rings on top
- **Active WP**: Highlighted with a bright green ring (`RGB(0, 255, 43)`)
- **Labels**: Waypoint number centered in circle; POSHOLD_TIME shows duration above ("Ns"), LAND shows "L"
- **Dense mode**: When waypoints are closely spaced at the current zoom level, only small dots are drawn (no text or rings)

### Pass 3 — SET_HEAD Chevrons
Direction indicators rendered on the preceding navigable waypoint, pointing in the configured heading direction (p1 = degrees, 0 = North).

### Pass 4 — RTH Dashed Line
A green dashed line from the last navigable waypoint before RTH back to the home position. The line is clipped to the viewport for performance.

### Pass 5 — JUMP Destination Arrows
Arrow indicators pointing from JUMP waypoints to their target waypoint index. Skipped during map panning for performance.

## Active Waypoint Tracking

When the UAV is armed and navigating, the widget polls `MSP_NAV_STATUS` every 2 seconds. The response contains:

| Field           | Size   | Description                                     |
|-----------------|--------|-------------------------------------------------|
| navMode         | 1 byte | 0=NONE, 1=HOLD, 2=RTH, 3=NAV, 15=EMERGENCY      |
| navState        | 1 byte | Internal nav state machine value                |
| activeWpAction  | 1 byte | Action type of current target WP                |
| activeWpNumber  | 1 byte | 1-based index of current target WP              |
| navError        | 1 byte | Navigation error code                           |
| targetHeading   | 2 bytes| Target heading in degrees (int16)               |

The **activeWpNumber** determines which waypoint marker receives the green highlight ring on the map.

## Nav-Mode Aware UAV Coloring

The UAV symbol changes color based on the current nav mode:

| Nav Mode | UAV Color | Meaning                          |
|----------|-----------|----------------------------------|
| NAV      | Green     | Actively navigating to waypoint  |
| HOLD     | Green     | Position hold at waypoint        |
| RTH      | Orange    | Returning to home                |
| NONE     | White     | No active navigation             |

## Widget Settings

### Waypoint download (INAV)
- **Type**: Boolean (on/off)
- **Default**: On
- **Effect**: When disabled, the MSP module only polls arming state (for home position detection) but skips the full waypoint download. This reduces telemetry bandwidth usage when waypoint overlay is not needed.
