# Map Panning & Observation Marker

The widget supports touch-based map panning and a custom observation marker feature. This allows free exploration of the map while the UAV continues to fly, and the ability to pin a marker at any position for reference.

## Panning

### Overview

By default, the map is locked to follow the UAV position (follow-lock). When panning is enabled (fullscreen widget), you can drag the map to explore the surrounding area. The map enters **detached mode** and stops following the UAV.

### Touch Controls

| Gesture       | Action                                        |
|---------------|-----------------------------------------------|
| Touch & drag  | Pan the map in any direction                  |
| Tap (no drag) | No action (touch released without movement)   |
| Release       | Map enters 5-second grace period, then re-centers on UAV |

### Pan State Machine

The panning system uses four states:

| State      | Description                                              |
|------------|----------------------------------------------------------|
| IDLE       | Map follows UAV (follow-lock active)                     |
| PENDING    | Touch detected, waiting for drag movement or release     |
| DRAGGING   | Finger down, map scrolling with touch movement           |
| GRACE      | Finger released, map stays at offset for 5 seconds       |

**Timing**:
- Touch timeout: 200 ms (distinguishes tap from drag)
- Grace period: 5 seconds after release before auto-recenter

### Performance During Panning

To maintain smooth scrolling, the widget reduces rendering complexity while panning:
- Heavy waypoint rendering passes (JUMP arrows, detailed markers, telemetry info) are skipped
- Only essential elements are drawn (path lines, simple WP dots, UAV position, home location, obervation marker)

## Follow-Lock

The lock button (visible in fullscreen mode) toggles the follow-lock behavior:

### Locked (default)
- Map follows UAV position in real time
- Pan offset is zero
- Panning via touch is available (temporarily breaks lock during drag + grace period)

### Unlocked (detached mode)
- Map freezes at the current viewport position
- UAV marker still updates on the frozen map
- No auto-recenter after grace period
- Pin button becomes available for placing observation markers

### Re-Locking
Pressing the lock button again snaps the map back to the UAV position and clears all pan state (offsets, anchors).

## Observation Marker

The observation marker is a persistent, user-placed pin on the map. It can be used to mark a point of interest such as a landing zone, a reference location, or any custom position.

### Placement

1. Unlock the map (press the lock button)
2. Pan the map so the desired location is at the **viewport center**
3. Press the **pin button**
4. A green filled circle with a black outline appears at the marker position

### Removal

Press the pin button again while an observation marker is active. It toggles off.

### Persistence

The observation marker coordinates are saved to widget storage immediately on placement or removal. The marker persists across widget restarts and power cycles until explicitly removed.

## UI Buttons

The panning and marker controls are rendered as overlay buttons on the right side of the map in fullscreen mode:

| Button | Icon   | Condition                    | Action                            |
|--------|--------|------------------------------|-----------------------------------|
| Lock   | 🔒/🔓 | Fullscreen + panning enabled  | Toggle follow-lock on/off        |
| Pin    | 📌     | Unlocked + panning enabled    | Place/remove observation marker  |
| Zoom + | ➕     | Always visible                | Increase map zoom level          |
| Zoom - | ➖     | Always visible                | Decrease map zoom level          |

> **Note**: The pin button is only available when the map is **unlocked** (detached mode). This ensures you are panning to the desired position before placing the marker.
