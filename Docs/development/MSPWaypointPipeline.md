# MSP Waypoint Mission — Technical Reference

> **Version**: 2.0

Technical implementation details for the MSP-based waypoint download and rendering pipeline. For user-facing documentation, see `Docs/manuals/WaypointMission.md`.

## Transport Layer

### Auto-Detection Order

1. **SmartPort**: Check for `RSSI` telemetry source + `sport.getSensor()` API
2. **CRSF/ELRS**: Check for `1RSS` telemetry source + `crsf.getSensor()` API
3. If neither found → `STATE_ERROR`, retry after 5 seconds

### Payload Sizes

| Transport  | Detection API                      | Max Payload | Frame Style        |
|------------|-------------------------------------|-------------|--------------------|
| SmartPort  | `sport.getSensor()`                 | 6 bytes     | Object: `pushFrame({table})` / `popFrame() → SPortFrame` |
| CRSF/ELRS  | `crsf.getSensor()`                  | 58 bytes    | Positional: `pushFrame(command, data)` / `popFrame(filterMin, filterMax)` |

### CRSF Frame Filtering

```lua
sensor:popFrame(CRSF_FRAMETYPE_MSP_RESP, CRSF_FRAMETYPE_MSP_RESP)
```

## Download State Machine

### States (`msp.lua`)

```lua
STATE_OFF         = 0
STATE_CONNECTING  = 1   -- MSP_FC_VARIANT (cmd 2)
STATE_GET_VERSION = 2   -- MSP_FC_VERSION (cmd 3)
STATE_GET_WP_INFO = 3   -- MSP_WP_GETINFO (cmd 20)
STATE_DOWNLOADING = 4   -- MSP_WP (cmd 118), one per index
STATE_DONE        = 5   -- Polling: MSP_STATUS + MSP_NAV_STATUS
STATE_ERROR       = 6   -- Retry after 5 seconds
```

### Download Sequence

```
FC_VARIANT (cmd 2) → 4-char identifier (e.g. "INAV")
    ↓
FC_VERSION (cmd 3) → major.minor.patch (e.g. "7.1.2")
    ↓
WP_GETINFO (cmd 20) → waypoint count + validity flag
    ↓
WP (cmd 118) × N → 21 bytes per waypoint
    ↓
DONE → polling loop
```

### MSP_WP Response (21 bytes)

| Field    | Size    | Description                         |
|----------|---------|-------------------------------------|
| idx      | 1 byte  | Waypoint index                      |
| action   | 1 byte  | Action type (see table below)       |
| lat      | 4 bytes | Latitude × 10⁷                     |
| lon      | 4 bytes | Longitude × 10⁷                    |
| alt      | 4 bytes | Altitude in cm                      |
| p1       | 2 bytes | Parameter 1 (action-specific)       |
| p2       | 2 bytes | Parameter 2                         |
| p3       | 2 bytes | Parameter 3                         |
| flags    | 1 byte  | `0xA5` = mission end marker         |

### MSP Protocol Versions

Auto-selected based on command ID:
- **MSP V1** (`0x20`): cmd ≤ 254
- **MSP V2** (`0x40`): cmd > 254

## Waypoint Action Types

| Action         | ID | Has Position | Navigable | p1 Usage                  |
|----------------|----|--------------|-----------|---------------------------|
| WAYPOINT       | 1  | Yes          | Yes       | Speed (cm/s)              |
| POSHOLD_TIME   | 3  | Yes          | Yes       | Hold time (seconds)       |
| RTH            | 4  | No           | No        | Land after RTH (0/1)      |
| SET_POI        | 5  | Yes          | No        | —                         |
| JUMP           | 6  | No           | No        | Target WP index           |
| SET_HEAD       | 7  | No           | No        | Heading degrees           |
| LAND           | 8  | Yes          | Yes       | Speed (cm/s)              |

## Polling (DONE State)

| MSP Command      | Interval | Condition        |
|------------------|----------|------------------|
| MSP_STATUS       | 5 s      | Always           |
| MSP_NAV_STATUS   | 2 s      | Only when armed  |

### MSP_NAV_STATUS Response

| Field           | Size    | Description                              |
|-----------------|---------|------------------------------------------|
| navMode         | 1 byte  | 0=NONE, 1=HOLD, 2=RTH, 3=NAV, 15=EMERGENCY |
| navState        | 1 byte  | Internal nav state machine value         |
| activeWpAction  | 1 byte  | Action type of current target WP         |
| activeWpNumber  | 1 byte  | 1-based index of current target WP       |
| navError        | 1 byte  | Navigation error code                    |
| targetHeading   | 2 bytes | Target heading in degrees (int16)        |

## Rendering Pipeline (`maplib.lua` — `drawWaypoints()`)

### 2-Pass System

**Pass 1 — Path Lines & Connections** (always rendered):
- Green path lines between consecutive navigable waypoints
- Dashed yellow JUMP connection lines with directional chevrons

**Pass 2 — Markers & Annotations** (skipped when `isPanning == true`):
- WP circles: `lcd.RGB(0,0,0)` alpha 0.4 fill + contrast ring
- Active WP highlight: `RGB(0, 255, 43)` ring
- WP number labels centered in circle
- POSHOLD_TIME duration label ("Ns")
- LAND label ("L")
- SET_HEAD heading chevrons on preceding navigable WP
- JUMP iteration counts (N or "∞")
- RTH dashed line back to home (viewport-clipped)
- Dense mode: small dots only when WPs are closely spaced at current zoom

### Nav-Mode UAV Coloring

| navMode | Color  | RGB               |
|---------|--------|-------------------|
| NAV (3) | Green  | —                 |
| HOLD (1)| Green  | —                 |
| RTH (2) | Orange | —                 |
| NONE (0)| White  | —                 |
