# WP Mission — Waypoint Rendering Plan

## Overview
Display INAV waypoint missions on the map widget. MSP download is already implemented
in `lib/msp.lua`. This document covers the rendering and UI integration.

## MSP Download (already done)
- `msp.open()` in `create()`, `msp.poll()` in `wakeup()`, `msp.close()` in `close()`
- Downloads ALL waypoints from the FC via SmartPort MSP passthrough
- 10s global timeout, no auto-retry (re-trigger on widget reload or map reset)
- `parseMissions()` splits flat `wpList` at `flag=0xA5` boundaries into `missions[]`
- `missions[1]` through `missions[N]` — INAV internally determines which is active

## Multi-Mission Toggle
- **State variable:** `mapStatus.mspMissionIdx` (1-based, default 1)
- **Button:** Right side, below the follow-lock button. Text label "M1", "M2", etc.
  - Only visible when `followLock == false` AND `#missions > 1`
  - Each tap cycles to next mission: `idx = (idx % #missions) + 1`
- **Rendering:** Only the selected mission is drawn with full detail
  - Other missions are not shown (keeps the map clean)

## Waypoint Drawing (in `maplib.lua`, inside `drawMap()`)

### Coordinate Conversion
For each WP with a position (WAYPOINT, POSHOLD_TIME, LAND, SET_POI):
```
tx, ty, ox, oy = mapLib.coord_to_tiles(wp.lat, wp.lon, level)
wpScreenX = myScreenX + (tx - uav_tile_x) * TILES_SIZE + (ox - uav_offset_x) + renderOffsetX
wpScreenY = myScreenY + (ty - uav_tile_y) * TILES_SIZE + (oy - uav_offset_y) + renderOffsetY
```

### Colors
- **Path lines:** helles Orange `lcd.RGB(255, 165, 0)` — 2px solid
- **WP text (numbers, labels):** Gelb `lcd.RGB(255, 206, 0)` (= `colors.yellow`)
- **WP circles/rings:** Schwarz `BLACK`
- **SET_POI bullseye:** Rot `RED`

### Rendering by WP Type

| Action | Has Position | Visual |
|--------|-------------|--------|
| WAYPOINT(1) | yes | Black circle + WP number |
| POSHOLD_TIME(3) | yes | Black circle + seconds from p1 above circle |
| LAND(8) | yes | Black circle + "L" |
| SET_POI(5) | yes | Red bullseye (outer circle, inner circle, center dot) |
| RTH(4) | no | Not drawn on map |
| JUMP(6) | no | Iteration count (p2) shown at jump source WP |
| SET_HEAD(7) | no | Not drawn on map |

### Path Lines
- Connect navigable WPs (WAYPOINT, POSHOLD_TIME, LAND) in sequence with orange lines
- JUMP: draw a dashed line from the JUMP's previous navigable WP back to the target WP
- SET_POI, RTH, SET_HEAD: do not interrupt the line sequence

### Density Handling
- Calculate pixel distance between consecutive navigable WPs
- If spacing < 100px: draw only filled dots (radius=3) + orange lines, NO symbols/text
- If spacing >= 100px: draw full symbols + text labels

### Mission Index Label
- At the first navigable WP of the displayed mission, draw "M1", "M2" etc. below the circle
- Yellow text, small font

### Clipping
- Only draw WPs whose screen coordinates fall within the visible viewport (with margin)
- Use `computeOutCode()` like the existing home/vehicle markers

## Implementation Steps

### 1. Add state to `mapStatus` (main.lua)
- `mapStatus.mspMissionIdx = 1`
- `mapStatus.mspMissions = {}` (populated from msp.getState() in wakeup)

### 2. Publish mission data in `wakeup()` (main.lua)
- After `msp.poll()`, if `msp.isDone()`, copy `msp.getState().missions` to `mapStatus.mspMissions`

### 3. Draw waypoints in `drawMap()` (maplib.lua)
- New function `mapLib.drawWaypoints(...)` called after trail drawing, before vehicle
- Takes: minX, minY, myScreenX, myScreenY, uav_tile_x/y, uav_offset_x/y, renderOffsetX/Y, level
- Reads mission from `status.mspMissions[status.mspMissionIdx]`
- Two-pass rendering: first path lines, then WP markers (so markers are on top)

### 4. Mission toggle button (layout_default.lua)
- Below follow-lock, same X position
- Draw only when unlocked AND missions > 1
- Small colored rectangle with "M1" text label

### 5. Touch handler for mission toggle (main.lua event())
- Hit test for the mission toggle button
- On tap: cycle `mapStatus.mspMissionIdx`
- `markMapDirty()` to trigger redraw

## File Changes
- `RADIO/scripts/ethosmaps/main.lua` — state init, wakeup data copy, event handler
- `RADIO/scripts/ethosmaps/lib/maplib.lua` — `drawWaypoints()` function
- `RADIO/scripts/ethosmaps/lib/layout_default.lua` — mission toggle button rendering
- `RADIO/scripts/ethosmaps/lib/msp.lua` — no changes needed (already done)
