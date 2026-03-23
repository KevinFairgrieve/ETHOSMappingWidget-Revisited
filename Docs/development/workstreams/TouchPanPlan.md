# Touch Pan Implementation Plan

**Target platform:** STM32H7 (ARM Cortex-M7, ~480 MHz), 8 MB extended SDRAM  
**Lua runtime:** Lua 5.4 embedded (no LuaJIT), ~40k instruction limit per frame  
**Status:** Planning

---

## Objective

Enable finger-drag panning of the map on ETHOS touchscreen radios. The map must decouple from the aircraft position while dragging and render at an acceptable frame rate on the constrained MCU hardware.

---

## Key Challenges

1. **Widget swipe conflict:** ETHOS uses horizontal swipes to navigate between widget screens. Pan gestures must be fully intercepted while dragging to prevent accidental screen switches.
2. **Frame budget:** The ~40k instruction limit and ~2–3 fps baseline leaves very little headroom. Drawing overlays and formatting bar strings during a drag is wasted work.
3. **Tile availability:** Panning exposes map regions that may not be loaded yet. Tiles in the drag direction must be prioritized.
4. **Auto-recenter:** The existing `drawMap()` always re-centers on the aircraft. This must be suppressed during panning.

---

## Fullscreen-Only Restriction

Drag-to-pan is **only enabled when the widget runs at a known fullscreen resolution.** In split layouts (e.g., FULL21 which gives 529×480), the smaller viewport combined with dynamic scaling makes drag zones unreliable and creates UI overlap issues.

**Detection:** `lcd.getWindowSize()` returns the widget's pixel dimensions. If these match a known ETHOS display resolution, drag is enabled. Otherwise, drag is silently disabled (zoom buttons still work normally).

**Whitelist of known ETHOS fullscreen resolutions:**

| Resolution | Radios |
|------------|--------|
| 800×480 | X20, X20S, X20 Pro, Twin X Lite |
| 640×360 | X14, X14S |
| 480×320 | X18, X18S |
| 480×272 | X10 Express, X10S Express |
| 320×240 | Boxer, Zorro, Commando8 (if touch) |

```lua
local FULLSCREEN_RESOLUTIONS = {
  ["800x480"] = true,
  ["640x360"] = true,
  ["480x320"] = true,
  ["480x272"] = true,
  ["320x240"] = true,
}

local function isDragEnabled(w, h)
  return FULLSCREEN_RESOLUTIONS[w .. "x" .. h] == true
end
```

Checked once per `paint()` cycle in `checkSize()`. Stored as `mapStatus.dragEnabled`.

---

## ETHOS Touch Event Model

ETHOS delivers touch events to the widget's `event(widget, category, value, x, y)` callback:

| value | Meaning | Notes |
|-------|---------|-------|
| **16640** | `TOUCH_FIRST` (finger down) | Sent **once** at the start of a touch sequence |
| **16641** | `TOUCH_END` (finger up) | Sent on hardware — **reliable for taps, unreliable for long drags** |
| **16642** | `TOUCH_SLIDE` (finger move/hold) | Sent **continuously** while finger is on screen — **including when stationary** |
| **16643** | Unknown (observed on HW) | Seen during long hold in `PAN_PENDING`. Does **not** carry movement. Safely ignored. |

> **Confirmed via Step 0 hardware + simulator logging** (TouchTest widget, March 2026).

### Platform Differences

| | Simulator | Hardware |
|--|-----------|----------|
| Event rate | ~33/s (~30ms interval) | ~10/s (~100ms interval) |
| `16641` (TOUCH_END) | **Never sent** | Sent for **taps**, often **missing** after long drags |
| `16642` when stationary | Continuous | Continuous |

### Release Detection Strategy

**Dual mechanism** — both are needed for reliable finger-up detection:

1. **Primary: `TOUCH_END` (16641)** — When received, immediately enter GRACE. Works for taps and some drags.
2. **Fallback: Timeout** — In `wakeup()`, if `getTime() - lastTouchTime > TOUCH_TIMEOUT_CS` (20 centiseconds = 200ms), enter GRACE. Catches long drags where 16641 is never sent, and covers the simulator which never sends 16641 at all.

### Key Takeaways for Implementation

1. **`16640` is always the first event** of a new touch sequence. Use it to start a drag.
2. **`16642` follows immediately** and continues at platform-dependent intervals. It carries updated x,y coordinates even if the finger hasn't moved.
3. **`16641` is unreliable.** It exists on hardware but is not guaranteed after long drags. Always have the timeout fallback.
4. **Timeout must account for hardware event spacing** (~100ms). Use `TOUCH_TIMEOUT_CS = 20` (200ms) — 2x the worst-case event interval.

---

## Architecture Overview

### Two Independent Concepts

The pan system consists of **two separate, independent mechanisms**:

#### 1. Drag-to-Pan (temporary, gesture-based)

A **drag zone** in the center of the map allows the user to drag the map by touching and sliding. No explicit mode toggle required.

- **Drag start zone:** The entire map viewport **minus** button hit-areas on the left edge (zoom +/−) and right edge (follow toggle). The drag zone is generous — essentially all map area that isn't a button.
- **Tap vs. Drag disambiguation:** A touch in the drag zone does **not** immediately start a drag. Instead:
  1. `TOUCH_FIRST (16640)` in drag zone → **NOT consumed** (`return false`). ETHOS receives it. State enters `PAN_PENDING`. Position recorded.
  2. **Immediately on next frame:** Overlays and bars are **suppressed** (same as DRAGGING). This gives the user instant visual feedback that their touch was registered, even at ~2 FPS where event processing is delayed by up to one full frame.
  3. First `TOUCH_SLIDE (16642)` → **Consumed immediately** → State enters `PAN_DRAGGING`. Grace timer starts on release.
  4. If `TOUCH_END (16641)` arrives while still `PAN_PENDING` (no SLIDE ever came) → It was a **tap**. Since TOUCH_FIRST was not consumed, ETHOS received a complete FIRST+END sequence = **widget menu opens normally**. Overlays immediately restored.
  5. `PAN_PENDING` has **no timeout**. ETHOS has no long-press gesture — holding a finger down indefinitely is safe. This avoids a race condition at low FPS (~2 FPS) where a timeout could expire before the widget processes the first SLIDE event.
  
  > **Rationale:** ETHOS needs to see both TOUCH_FIRST and TOUCH_END (unhandled) to register a tap/menu action. A single TOUCH_FIRST alone (without follow-up) does not trigger a swipe — swipes require sustained horizontal movement via TOUCH_SLIDE. By not consuming TOUCH_FIRST and only grabbing TOUCH_SLIDE, we allow taps to pass through while intercepting drags before ETHOS can interpret them as swipes.
  >
  > **Validated on hardware** (TouchTest, March 2026): Confirmed at ~1.9 FPS with CPU load simulation. Taps reliably open the widget menu, drags work correctly even when SLIDE arrives >1s after FIRST.

- **Once dragging starts:** The finger can move **anywhere on the entire screen** — the drag continues even outside the original zone (confirmed in HW testing).
- **During drag:** Auto-recenter on UAV is disabled. Bars are frozen. Overlays are suppressed. All touch events are consumed to prevent widget-screen swiping.
- **Releasing:** On `TOUCH_END (16641)` or timeout (200ms no events), the widget enters `PAN_GRACE`.
- **Grace period (5 seconds):** Bars remain frozen, overlays suppressed. If the user touches the drag zone again, drag resumes immediately. When grace expires, the map **auto-recenters on the UAV** and bars/overlays resume.

This makes panning feel completely natural — no buttons to activate, just grab the map and move it.

#### 2. UAV Follow Toggle (permanent, button-based)

A **toggle button** on the right side of the map permanently disables/enables UAV auto-follow.

- When follow is **OFF**: The map stays at its current center position. The UAV arrow moves on the map as the aircraft moves, but the map does not track it. This is useful for monitoring a static area.
- When follow is **ON** (default): Normal behavior — map auto-centers on UAV.
- This is **independent of dragging.** Dragging works exactly the same whether follow is on or off. The only difference: when grace expires after a drag, if follow is OFF the map stays at the dragged position instead of snapping back to the UAV.
- Button visual: A small crosshair/target icon. Highlighted when follow is ON, dimmed when OFF.

### Interaction Matrix

| Follow | Drag State | Map centers on | After grace expires |
|--------|------------|----------------|---------------------|
| ON     | IDLE       | UAV (live)     | —                   |
| ON     | DRAGGING   | Finger (pan)   | —                   |
| ON     | GRACE      | Last pan pos   | Snap back to UAV    |
| OFF    | IDLE       | Last position  | —                   |
| OFF    | DRAGGING   | Finger (pan)   | —                   |
| OFF    | GRACE      | Last pan pos   | Stay at pan pos     |

### State Machine

```
FOLLOW (default, followMode=true)
  │
  ├─ [TOUCH_FIRST in drag zone] ──► PAN_PENDING (not consumed!)
  │                                    │  overlays suppressed immediately
  │                                    │  (visual feedback at low FPS)
  │                                    ├─ [TOUCH_SLIDE] ──► PAN_DRAGGING (consumed)
  │                                    │                      │
  │                                    │                      ├─ [TOUCH_SLIDE] ──► update panCenterLat/Lon
  │                                    │                      │                    bars frozen, overlays off
  │                                    │                      │                    consume all touch events
  │                                    │                      │
  │                                    │                      └─ [finger up / timeout] ──► PAN_GRACE (5s)
  │                                    │                                                    │
  │                                    │                          ┌─────────────────────────┤
  │                                    │                          │                         │
  │                                    │                   [TOUCH_FIRST]              [timer expires]
  │                                    │                          │                         │
  │                                    │                     ► PAN_PENDING            followMode?
  │                                    │                                               │        │
  │                                    │                                              YES       NO
  │                                    │                                               │        │
  │                                    │                                          ► FOLLOW   ► IDLE
  │                                    │                                          (snap back) (keep pos)
  │                                    │
  │                                    ├─ [TOUCH_END while PENDING] ──► IDLE (was a tap, menu opens)
  │                                    │
  │                                    └─ (no timeout — PENDING persists until SLIDE or END)
  │
  ├─ [follow button tap] ──► IDLE (followMode=false)
  │                           │
  │                           ├─ [TOUCH_FIRST in drag zone] ──► PAN_PENDING (same flow)
  │                           │
  │                           └─ [follow button tap] ──► FOLLOW (snap back to UAV)
  │
  └─ [zoom +/- tap] ──► zoom (works in all states)
```

**Design constraints:**
- **No kinetic scrolling / inertia.** The map stops immediately when the finger lifts. Simplicity > smoothness on this platform.
- **Grace period: 5 seconds.** After finger-up, bars stay frozen and overlays suppressed for 5 seconds. This gives the user time to reposition their finger for consecutive drags without UI flickering. A new finger-down during grace immediately resumes dragging.
- **Drag zone is generous.** Essentially the entire map surface minus button hit-areas. Since a drag that starts in-zone can continue anywhere on screen, accidental swipes are prevented.

---

## New State Variables (`mapStatus`)

```lua
-- Pan / Follow
followMode = true,        -- true = auto-center on UAV (default), false = static map
panState = 0,             -- 0 = idle, 1 = dragging, 2 = grace, 3 = pending (tap/drag TBD)
panLastX = 0,             -- Last finger X (for delta calculation)
panLastY = 0,             -- Last finger Y (for delta calculation)
panCenterLat = nil,       -- Virtual map center latitude (nil = follow aircraft)
panCenterLon = nil,       -- Virtual map center longitude
panDragDirX = 0,          -- Normalized drag direction X (-1, 0, +1) for tile prioritization
panDragDirY = 0,          -- Normalized drag direction Y (-1, 0, +1)
panGraceEnd = 0,          -- getTime() timestamp when grace period expires
lastTouchTime = 0,        -- getTime() timestamp of last touch event (for timeout release detection)
dragEnabled = false,      -- true when widget is at a known fullscreen resolution
```

### Pan State Values

| Value | Name | Bars | Overlays | TOUCH_FIRST consumed? | TOUCH_SLIDE consumed? |
|-------|------|------|----------|----------------------|----------------------|
| 0 | `PAN_IDLE` | Live | All rendered | No | No |
| 3 | `PAN_PENDING` | **Frozen** | **Suppressed** | **No** (passed to ETHOS) | **Yes** (drag starts) |
| 1 | `PAN_DRAGGING` | Frozen | Suppressed | Yes | Yes |
| 2 | `PAN_GRACE` | Frozen | Suppressed | Enters PENDING | Yes (resumes drag) |

> **Low-FPS UX flow:** Finger down → ~1 frame delay → PENDING (overlays removed = visual feedback) → SLIDE arrives → DRAGGING → finger up → GRACE (5s) → IDLE. If finger lifts during PENDING without SLIDE → immediate IDLE (tap, menu opens).

Grace period duration: **5 seconds** (configurable constant `PAN_GRACE_DURATION_CS = 500`).

---

## Implementation Steps

### Step 0 — Hardware Touch Event Discovery

**File:** main.lua (`event()`)

**Task:** Before any implementation, log all touch event data on real hardware to discover the complete ETHOS touch value vocabulary.

**Implementation:**
- Temporarily log **every** `EVT_TOUCH` event (all values, not just 16640/16641)
- Format: `value=%d x=%d y=%d` to the debug log
- Run on hardware, drag finger across the screen, and analyze log output
- Document the complete event map (press, move/slide, release, cancel, etc.)

**Deliverable:** Confirmed value constants for TOUCH_FIRST, TOUCH_SLIDE, TOUCH_END (or whatever ETHOS calls them).

---

### Step 1 — Drag Zone Detection & Follow Toggle Button

**Files:** main.lua (`event()`), drawlib.lua or layout_default.lua (button rendering)

**Task:** Implement drag-zone touch handling and a Follow toggle button.

**Sub-tasks:**
1. Add `followMode`, `panState`, `lastTouchTime` fields to `mapStatus`
2. Define **button hit-areas** (zoom +/-, follow toggle) — these are excluded from the drag zone
3. Add a **Follow toggle button** on the right side of the map:
   - Icon: crosshair/target bitmap
   - Highlighted when `followMode == true` (default), dimmed when `followMode == false`
   - Tap toggles `followMode`. When toggling ON: snap map back to UAV (`panCenterLat/Lon = nil`)
4. In `event()`, handle `TOUCH_FIRST (16640)`:
   - Check if tap hits a button → handle button action (zoom, follow toggle), don't start drag
   - Otherwise (tap is in drag zone): set `panState = PAN_DRAGGING`, record `panLastX/Y`
   - Consume the event (`system.killEvents()` + `return true`)
5. In `event()`, handle `TOUCH_SLIDE (16642)`:
   - If `panState == PAN_DRAGGING`: compute delta, update `panCenterLat/Lon`, consume event
   - If `panState == PAN_GRACE` and touch is in drag zone: resume drag (`panState = PAN_DRAGGING`)
   - If `panState == PAN_IDLE`: pass through to ETHOS (allow widget-screen swiping)
6. In `event()`, handle `TOUCH_END (16641)`:
   - If `panState == PAN_DRAGGING`: enter `PAN_GRACE`, set `panGraceEnd = getTime() + 500`

**Event consumption strategy:**
```lua
-- During DRAGGING: consume ALL touch events (prevent swipe between screens)
-- During GRACE: consume touches in drag zone only (allow button taps)
-- During IDLE: only consume button taps, pass everything else to ETHOS
if panState == PAN_DRAGGING then
  system.killEvents(value)
  return true
end
```

---

### Step 2 — Drag Tracking (pixel-level panning)

**File:** main.lua (`event()`), also `wakeup()`

**Task:** Track finger movement, convert to lat/lon deltas, and handle release detection.

**Sub-tasks:**
1. On `TOUCH_FIRST (16640)` in drag zone (already handled in Step 1):
   - Set `panState = PAN_DRAGGING`, record `panLastX/Y = x, y`
   - Set `lastTouchTime = getTime()`
2. On `TOUCH_SLIDE (16642)` while `panState == PAN_DRAGGING`:
   - Compute delta `dx = x - panLastX`, `dy = y - panLastY`
   - Reverse-project pixel delta to lat/lon shift (see Step 5)
   - Update `panLastX/Y = x, y`
   - Update `lastTouchTime = getTime()`
   - Compute drag direction for tile prioritization:
     ```lua
     panDragDirX = (dx > 2) and -1 or (dx < -2) and 1 or 0
     panDragDirY = (dy > 2) and -1 or (dy < -2) and 1 or 0
     ```
     (Inverted: dragging right → map shifts left → new tiles needed east)
   - Call `markMapDirty()` to schedule redraw
3. On `TOUCH_END (16641)` — primary release detection:
   - If `panState == PAN_DRAGGING`: set `panState = PAN_GRACE`, `panGraceEnd = getTime() + PAN_GRACE_DURATION_CS`
4. Timeout fallback — in `wakeup()`:
   - If `panState == PAN_DRAGGING` and `getTime() - lastTouchTime > TOUCH_TIMEOUT_CS (20)`:
     - Set `panState = PAN_GRACE`, `panGraceEnd = getTime() + PAN_GRACE_DURATION_CS`
5. Grace period check — in `wakeup()`:
   - If `panState == PAN_GRACE` and `getTime() >= panGraceEnd`:
     - Set `panState = PAN_IDLE`, clear `panDragDirX/Y = 0`
     - If `followMode == true`: reset `panCenterLat/Lon = nil` (snap back to UAV)
     - If `followMode == false`: keep `panCenterLat/Lon` (stay at panned position)
     - Bars resume live updates, overlays return
6. Grace → Drag shortcut:
   - If `panState == PAN_GRACE` and `TOUCH_FIRST` lands in drag zone: immediately set `panState = PAN_DRAGGING`, reset `panLastX/Y`

**Performance note at <3fps:** With ~100ms between hardware touch events and ~333ms between frames, multiple touch events may queue between paint() calls. The event() callback processes each one independently, so drag deltas accumulate correctly. The visual update just lags slightly — acceptable.

---

### Step 3 — Map Rendering in Pan Mode

**Files:** maplib.lua (`drawMap()`), layout_default.lua (`panel.draw()`)

**Task:** Modify rendering to support pan offset and minimize draw cost during active drag.

#### 3a — Apply pan offset to tile grid

In `drawMap()`, when `panMode == true`:
- **Skip auto-recenter:** Don't override `widget.drawOffsetX/Y` from aircraft GPS
- Instead, apply `panOffsetX/Y` to the render offset:
  ```lua
  if status.panMode then
    renderOffsetX = renderOffsetX + status.panOffsetX
    renderOffsetY = renderOffsetY + status.panOffsetY
  end
  ```
- Continue drawing tiles with the shifted offset

#### 3b — Suppress overlays during active drag / grace

When `panState == 1 or panState == 2` (dragging or grace period):
- **Keep:** Tile rendering (essential)
- **Keep:** Home icon (stays at its GPS-projected position — will scroll naturally)
- **Keep:** UAV arrow (stays at its GPS-projected position — will scroll off-screen)
- **Skip:** Trail rendering (save instruction budget)
- **Skip:** Scale bar (save instruction budget)
- **Skip:** Zoom label overlay
- **Skip:** Debug grid

When `panState == 0` and `panMode == true` (panned, grace expired):
- Re-enable all overlays (trail, scale bar, etc.) — render them at their panned positions

#### 3c — Freeze top/bottom bars during drag / grace

In `panel.draw()`:
- When `panState == 1 or panState == 2`: **freeze** the bars — skip their draw/update cycle entirely
- The bars remain visible with their last-rendered content (ETHOS retains the framebuffer)
- The map viewport size stays unchanged (bars still occupy their height)
- This means the map area is smaller than full-widget, so we redraw **fewer pixels** per drag frame
- When grace expires (`panState == 0`): bars resume live updates

```lua
local freezeBars = (status.panState == 1 or status.panState == 2)
if not freezeBars then
  -- draw top bar (full update)
  -- draw bottom bar (full update)
end
-- map always draws into its normal viewport (between top and bottom bar)
```

**Rationale:** Freezing bars instead of hiding them saves more instructions than expanding the map, because:
1. We skip ~8k instructions of bar formatting + drawing
2. The map viewport is smaller → fewer tiles to draw per frame
3. No layout recalculation needed when transitioning between drag/idle

---

### Step 4 — Tile Loading Prioritization

**Files:** maplib.lua (`loadAndCenterTiles()`), tileloader.lua

**Task:** Prioritize tiles in the drag direction and expand the ring cache in that direction.

#### 4a — Pan-direction tile loading

When `panState == 1` and `panDragDirX/Y` is nonzero:
- Pass drag direction as `leadX/leadY` to `loadAndCenterTiles()` — the existing directional lead mechanism already shifts the center tile in the lead direction
- This reuses the existing infrastructure: center tile shifts by `(leadX, leadY)`, and the 3×3 high-priority window follows

#### 4b — Ring cache extension (+1 in drag direction)

In `trimCache()`:
- When `panMode == true`: increase the keep margin by +1 tile in the drag direction
- This means tiles "behind" the drag (the side scrolling out of view) may evict faster, while tiles "ahead" (scrolling into view) are retained longer

```lua
local panMarginX = (status.panMode and status.panDragDirX ~= 0) and 1 or 0
local panMarginY = (status.panMode and status.panDragDirY ~= 0) and 1 or 0
-- Apply to keep bounds in drag direction
```

#### 4c — Prefetch strip in drag direction

Reuse `enqueueDirectionalPrefetch()` with drag direction instead of heading direction:
- When `panState == 1`: override `prefetchLeadX/Y` with `panDragDirX/Y`
- This loads the strip of tiles about to scroll into view as low-priority

---

### Step 5 — Pan Offset ↔ Tile Grid Synchronization

**File:** maplib.lua

**Task:** When `panOffsetX/Y` exceeds a tile boundary, convert pixel offset into a tile-grid shift.

**Problem:** If the user pans 200+ pixels, the tile grid (currently centered on the aircraft) no longer covers the viewport. We need to shift the tile grid origin.

**Solution — Virtual center point:**
- Maintain `panCenterLat / panCenterLon` as the virtual map center when in pan mode
- On each drag delta, reverse-project the pixel delta back to lat/lon delta:
  ```lua
  -- Approximate degrees-per-pixel at current zoom level
  local tileScale = 360 / (2^level * 256)
  panCenterLon = panCenterLon - dx * tileScale
  panCenterLat = panCenterLat + dy * tileScale * cos(panCenterLat * pi/180)
  ```
- Use `panCenterLat/Lon` instead of `telemetry.lat/lon` as the input to `coord_to_tiles()` and `loadAndCenterTiles()`
- This way the tile grid naturally re-centers as the user drags, and tiles always cover the viewport

**On pan mode exit:** Reset `panCenterLat/Lon` to nil → reverts to aircraft GPS tracking.

**Advantages over pure pixel offset:**
- No limit on pan distance
- Tile grid always covers the viewport
- Existing tile loading and caching works unmodified
- No need for separate "offset exceeds threshold" detection

---

### Step 6 — UAV & Home Positioning During Pan

**File:** maplib.lua (`drawMap()`)

**Task:** Keep UAV and Home icons at their correct GPS-projected screen positions (they scroll out of view as the user pans away).

**Implementation:**
- UAV arrow: already positioned via `getScreenCoordinates()` relative to tile grid. Since the tile grid shifts with the virtual center, the UAV will naturally appear at its GPS-projected position (which may be off-screen).
- Home icon: same — uses `coord_to_tiles()` → `getScreenCoordinates()`, will scroll naturally.
- Add out-of-bounds check: if UAV position is fully outside viewport, show a small **edge indicator** (arrow on the viewport border pointing toward the UAV). This is optional for v1.

---

### Step 7 — Return-to-Aircraft & Follow Toggle UX

**File:** main.lua, layout_default.lua

**Task:** Polish the follow toggle button UX and return-to-aircraft behavior.

**Sub-tasks:**
1. **Follow toggle button rendering:**
   - Draw on the right edge of the map (e.g., below zoom buttons)
   - Icon: crosshair/target — bright when follow=ON, dim/crossed-out when OFF
   - Must be tappable without starting a drag (excluded from drag zone)
2. **Follow ON → OFF:** Map stays at current center. UAV arrow moves independently.
3. **Follow OFF → ON:** Map immediately snaps back to UAV position (`panCenterLat/Lon = nil`).
4. **After drag with follow=ON:** Grace expires → auto-snap back to UAV (already handled in Step 2).
5. **After drag with follow=OFF:** Grace expires → map stays at dragged position.

---

## Performance Budget Analysis

### Normal mode (current baseline):
- `drawMap()`: tiles + overlays + trail → ~25k instructions
- `panel.draw()`: top bar + bottom bar → ~8k instructions  
- Event handling: ~1k instructions
- **Total: ~34k / 40k limit**

### Pan dragging / grace mode (optimized):
- `drawMap()`: tiles only (no trail, no scale bar) → ~15k instructions
- `panel.draw()`: bars frozen (0 instructions), smaller map viewport → fewer tiles
- Event handling: drag deltas + tile shift → ~2k instructions
- Tile loading: directional prioritization → ~1k additional
- **Total: ~18k / 40k limit — comfortable headroom**

### Pan idle (grace expired, still panned):
- Same as normal mode but with pan offset applied, bars resume
- **Total: ~34k / 40k — same as baseline**

---

## Configuration Options (widget settings)

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| Enable Touch Pan | Toggle | On | Master enable for drag-to-pan on the map |
| Grace Period | Number | 5s | Seconds after finger-up before auto-recenter (if follow=ON) or overlays resume |

---

## Implementation Order

1. **Step 0** — Hardware touch event discovery ✅ DONE
2. **Steps 1+2+3 (Core Pan MVP)** — ✅ DONE (combined implementation)
   - Pan state machine (IDLE→PENDING→DRAGGING→GRACE) in `main.lua event()`
   - Timeout-based release detection in `main.lua wakeup()`
   - Grace period (5s) with auto-recenter on expiry
   - Drag zone: full map height, excluding left+right button columns
   - Fullscreen resolution whitelist in `checkSize()`
   - Overlay suppression during PENDING/DRAGGING/GRACE in `layout_default.lua`
   - Pixel-offset panning via `panOffsetX/Y` applied in `maplib.lua drawMap()`
   - Zoom resets pan state (returns to IDLE)
   - PAN_PENDING: no timeout, persists until SLIDE or END
3. **Step 5** — Virtual center point (panCenterLat/Lon) — needed for unlimited pan distance
4. **Step 4** — Tile loading prioritization
5. **Step 6** — UAV/Home edge indicators (optional, can defer)
6. **Step 7** — Follow toggle button UX polish

Steps 1–3 MVP is implemented. Current approach uses pixel offsets (panOffsetX/Y) which
allows panning within the tile grid. Step 5 (virtual center) is needed if pan distance
exceeds the loaded tile area.

---

## Open Questions

1. ~~**ETHOS touch slide events**~~ → **Resolved.** 16640=FIRST, 16641=END (unreliable), 16642=SLIDE. Dual release detection (16641 + timeout).
2. ~~**Touch event rate**~~ → **Resolved.** ~10/s on hardware (~100ms interval), ~33/s in simulator.
3. **Maximum pan distance:** Should we limit how far the user can pan from the aircraft? Probably not — tiles will just show loading placeholders for unmapped areas.
4. **Bitmap loading during drag:** Missing tiles show the loading placeholder during rapid panning — acceptable.
5. **Zoom while panned:** Should zooming re-center on the panned position or on the aircraft? Recommendation: re-center on panned position (virtual center).
6. **Low FPS impact:** At <3fps, multiple touch events queue between paint() calls. event() processes them independently, so drag deltas accumulate correctly. Visual update lags but behavior is correct.
7. **Follow button placement:** Right edge of map, below or separate from zoom buttons. Exact position TBD during implementation.
