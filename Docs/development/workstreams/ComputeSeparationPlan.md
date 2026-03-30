# ETHOS Mapping Widget – Compute Separation Plan

**Branch:** `2.1-dev`  
**Goal:** Move all heavy computation out of `paint()` into `wakeup()` to eliminate "Maximum number of instructions reached" errors permanently. Maximize overall widget performance through scheduled, incremental computation. Remove the `pcall` wrapper added as a 2.0 stopgap.  
**Constraint:** No functionality loss. Rendering must stay visually identical. Tile management stays in `tileloader.lua`.

---

## Problem Statement

ETHOS enforces a hard instruction limit (~40,000 VM opcodes) on `paint()`. The widget hits this limit when a viewport change (zoom or tile boundary crossing) coincides with waypoint drawing. The 2.0 release mitigates this with a `pcall` wrapper that silently catches the transient error — the next frame renders normally. This is a workaround, not a fix.

The root cause is that `paint()` performs **computation AND rendering** in the same call:
- Coordinate projection (Mercator math, trig)
- Tile grid rebuilding and cache trimming
- Waypoint path construction, line clipping, marker layout
- Trail ring-buffer processing and segment clipping
- Telemetry snapshot caching

`wakeup()` has **no hard instruction limit** (preempted since ETHOS 1.5.10) and runs before every `paint()`. All non-rendering work should move there.

However, simply moving all computation into a single `wakeup()` call creates a new bottleneck: a heavy wakeup cycle delays the subsequent `paint()`, reducing frame rate. The solution is a **compute scheduler** that distributes work across multiple wakeup cycles.

---

## Design Priorities

These principles guide every phase of the refactoring:

### P1: Compute Scheduler — Staggered Workloads

Do NOT run all dirty computations in a single `wakeup()` call. Instead, implement a **priority-based task scheduler** that processes one or two tasks per cycle:

- **Task queue with priorities:** HIGH = tile grid + vehicle position (visible every frame), MEDIUM = waypoint layout + trail segments, LOW = sensor cache + scale bar + prefetch
- **One-task-per-cycle default:** Each `wakeup()` picks the highest-priority dirty task, executes it, then yields. If wakeup still has budget (no preemption), it may process a second LOW task.
- **Starvation prevention:** LOW tasks get promoted after N skipped cycles.
- **Result:** Shorter wakeup cycles → faster paint → higher FPS. Computation spreads over 3-5 frames instead of spiking in one.

### P2: Avoid Redundant Computation

Never recompute what hasn't changed:

- **Input change detection:** Track a lightweight state fingerprint (zoom level, center tile X/Y, pixel offset, WP revision counter, trail write index). Skip the entire compute cycle when the fingerprint matches.
- **Dirty flags per subsystem:** `needsTileGrid`, `needsWpLayout`, `needsTrailClip`, `needsBarSnapshot`, `needsScale`. Only set when the relevant input actually changes.
- **Incremental/delta updates for pan:** When the viewport shifts by a few pixels (pan or tracking), apply a pixel offset to existing screen coordinates instead of full Mercator reprojection. Full reprojection only on zoom change or tile boundary crossing.

### P3: Minimize Allocation — Table Reuse

GC pressure matters even in `wakeup()` because `collectgarbage()` can spike in any callback:

- **Reuse result tables:** Overwrite `results.waypoints.markers[i].x = ...` instead of `results.waypoints.markers = {}`.
- **Pre-allocate arrays** to expected size (e.g., max WP count, tile grid size) during `init()`.
- **No closures in hot paths:** Use upvalue references or module-level functions.

### P4: Bugfixes Deferred

Small, non-system-breaking bugs are collected in the "Known Bugs" section and fixed **after** the compute separation is complete and stable. This avoids scope creep during the refactoring.

---

## Current Module Responsibilities

### maplib.lua (~1,970 LOC, 32 functions)
The computational heavyweight. **59% computation**, 16% rendering, 25% state management.

**Computation in paint() that must move:**
- `google_coord_to_tiles()`, `gmapcatcher_coord_to_tiles()` — Mercator projection (trig-heavy)
- `pixel_to_coord()` — inverse Mercator
- `getScreenCoordinates()` — tile-local to screen coords via path lookup
- `getDirectionalLeadFromHeading()` + gating helpers — prefetch offset calculation
- `clipLine()` used by `drawWaypoints()` — Cohen-Sutherland clipping per segment
- `shortenLine()` — geometry helper for WP path segments
- `calculateScale()` — scale bar distance computation
- `loadAndCenterTiles()` — tile grid rebuild + spiral enqueue (called from `drawMap()`)

**Rendering that stays in paint():**
- `drawTiles()` — `lcd.drawBitmap()` calls only
- `drawWaypoints()` — draws pre-computed markers and lines
- `drawMap()` — orchestrates tile draw, vehicle, home, trail, mission overlay
- `drawChevron()`, `drawWpMarker()` — primitive shape drawing

### drawlib.lua (~1,065 LOC, 20 functions)
Balanced: **40% computation**, 50% rendering, 10% state management.

**Computation in paint() that must move:**
- `safeSensorName()`, `safeSensorValueText()` — sensor reads with pcall and LRU cache
- `getTopBarSensorName()`, `getTopBarSensorBlockWidth()` — text measurement for layout
- `computeOutCode()`, `isInside()`, `clipLine()` — Cohen-Sutherland clipping

**Rendering that stays in paint():**
- `drawText()`, `drawNumber()`, `drawTopBar()`, `drawTopBarSensor()` — text/bar rendering
- `drawVehicle()`, `drawRArrow()`, `drawRAirplane()`, `drawRMultirotor()` — vehicle symbols
- `drawBitmap()`, `drawNoGPSData()` — bitmap and overlay rendering

### layout_default.lua (~455 LOC, 5 functions)
Purely orchestration: **0% computation**, 40% rendering, 60% state management.

**State management that should move to wakeup():**
- `getBarSnapshot()` — telemetry snapshot with tick-based caching (groundSpeed, heading, travelDist, homeDist)

**Rendering that stays in paint():**
- `panel.draw()` — calls `drawMap()`, draws bars, zoom overlay, scale, warnings
- `drawBarSensor()` — labeled sensor block rendering

### tileloader.lua (~475 LOC, 16 functions)
I/O and cache management: **25% computation**, 0% rendering, 75% state management.
**Stays as-is.** Tile management (queue, cache, disk I/O) remains in `tileloader.lua`. The `processQueue()` function already runs in `wakeup()`.

---

## Phased Implementation

### Phase 1: compute.lua Foundation

**Create `src/scripts/ethosmaps/lib/compute.lua`** — new module that runs exclusively in `wakeup()`.

Responsibilities:
- Owns a `compute.update(widget)` entry point called from `wakeup()` in `main.lua`
- Implements the **priority-based task scheduler** (see Design Priorities P1)
- Maintains pre-computed result tables that `paint()` reads (read-only during paint)
- Tracks dirty flags per subsystem with input fingerprinting (see P2)
- Pre-allocates and reuses all result tables (see P3)

Initial skeleton:
```lua
local compute = {}
local results = {}           -- shared read-only results for paint()
local dirty = {}             -- per-subsystem dirty flags
local fingerprint = {}       -- input state for change detection
local skipCount = {}         -- starvation counters for LOW tasks

-- Task registry: { name, priority, fn, dirtyKey }
local tasks = {}

local function registerTask(name, priority, fn, dirtyKey)
    tasks[#tasks + 1] = { name = name, pri = priority, fn = fn, key = dirtyKey }
end

function compute.setDirty(key)
    dirty[key] = true
end

function compute.update(widget)
    -- 1. Check fingerprint — skip entirely if nothing changed
    -- 2. Pick highest-priority dirty task, execute it
    -- 3. If budget remains, pick one LOW task
    -- 4. Increment skip counters, promote starved tasks
end

function compute.getResults()
    return results
end

function compute.init(param_status, param_libs)
    -- store references, pre-allocate result tables
end

return compute
```

Integration in `main.lua`:
```lua
-- in wakeup():
libs.compute.update(widget)
-- in paint():
local cr = libs.compute.getResults()  -- read-only access
```

### Phase 2: Waypoint Pre-computation

Move waypoint path construction out of `drawWaypoints()`:

| Function | From | To |
|----------|------|----|
| Screen coordinate projection for each WP | `maplib.getScreenCoordinates()` in paint | `compute.projectWaypoints()` in wakeup |
| Path segment clipping (`clipLine`) | `maplib.drawWaypoints()` in paint | `compute.clipWpSegments()` in wakeup |
| `shortenLine()` for WP markers | `maplib.drawWaypoints()` in paint | `compute.clipWpSegments()` in wakeup |
| JUMP arc geometry | `maplib.drawWaypoints()` in paint | `compute.prepareJumpArcs()` in wakeup |
| Dense mode layout decisions | `maplib.drawWaypoints()` in paint | `compute.layoutWpMarkers()` in wakeup |

**Result table:** `results.waypoints = { segments = {}, markers = {}, jumps = {}, rthLine = {} }`

`drawWaypoints()` becomes a pure draw loop over pre-computed geometry.

**Dirty flag:** Set when WP data changes (MSP download), zoom changes, or viewport pans.

**Incremental optimization:** On pan (no zoom change), apply pixel delta to cached screen coordinates instead of full reprojection. Full recompute only on zoom change, tile boundary crossing, or WP data change.

### Phase 3: Trail Pre-computation

Move trail segment processing out of `drawMap()`:

| Function | From | To |
|----------|------|----|
| Trail ring-buffer iteration | `drawMap()` in paint | `compute.processTrail()` in wakeup |
| Trail segment clipping | `drawMap()` in paint | `compute.processTrail()` in wakeup |
| Trail coordinate projection | `drawMap()` in paint | `compute.processTrail()` in wakeup |

**Result table:** `results.trail = { segments = {} }` — pre-clipped screen-space line segments.

**Dirty flag:** Set when new trail point added, zoom changes, or viewport pans.

### Phase 4: Tile Grid Computation

Move tile grid math out of `drawMap()` while keeping tile I/O in `tileloader.lua`:

| Function | From | To |
|----------|------|----|
| `loadAndCenterTiles()` grid rebuild | `maplib.drawMap()` in paint | `compute.rebuildTileGrid()` in wakeup |
| `getDirectionalLeadFromHeading()` + gating | `maplib.loadAndCenterTiles()` in paint | `compute.rebuildTileGrid()` in wakeup |
| Prefetch enqueue (`enqueueDirectionalPrefetch`) | `maplib.loadAndCenterTiles()` in paint | `compute.rebuildTileGrid()` in wakeup |
| `tiles_to_path()` string building | `maplib.loadAndCenterTiles()` in paint | `compute.rebuildTileGrid()` in wakeup |

**Important:** `tileloader.processQueue()` and `tileloader.trimCache()` stay in `tileloader.lua` and continue running in `wakeup()`. Only the grid geometry calculation moves.

**Result table:** `results.tileGrid = { paths = {}, screenPositions = {} }`

**Dirty flag:** Set on viewport change, zoom, or heading-based lead shift.

### Phase 5: Telemetry & UI State

Move remaining computation out of paint():

| Function | From | To |
|----------|------|----|
| `getBarSnapshot()` | `layout_default.lua` in paint | `compute.updateBarSnapshot()` in wakeup |
| `safeSensorName/Value()` | `drawlib.lua` in paint | `compute.updateSensorCache()` in wakeup |
| `getTopBarSensorBlockWidth()` | `drawlib.lua` in paint | `compute.layoutTopBar()` in wakeup |
| `calculateScale()` | `maplib.lua` in paint | `compute.updateScale()` in wakeup |
| Home/vehicle screen position | `maplib.drawMap()` in paint | `compute.projectPositions()` in wakeup |

### Phase 6: Cleanup

After all phases are stable and tested:

1. **Remove `pcall` wrapper** from `paint()` — no longer needed when paint() only renders
2. **Remove GC stop/restart** brackets in paint() — instruction budget has massive headroom
3. **Remove `inPaint` guard** on `logDebug` — no longer needed if logDebug not called in paint path
4. **Audit dead computation functions** in maplib/drawlib that were fully replaced by compute.lua
5. **Update documentation** — DebugLogger.md, TELEMETRY-SOURCES.md, README architecture section

---

## Risk Mitigation

- **Data consistency:** `compute.update()` writes to result tables, `paint()` reads. No concurrent mutation since ETHOS runs wakeup→paint sequentially.
- **First-frame blank:** On first frame before any `wakeup()` runs, result tables are empty. paint() must handle nil/empty results gracefully (show loading state).
- **Regression testing:** Each phase must be tested on hardware (X20RS, 800×480) with:
  - Zoom in/out with WPs loaded
  - Tile boundary crossing at full speed
  - WP download during flight
  - Trail rendering with >100 segments

---

## Known Bugs (deferred — fix after compute separation is stable)

- **WP clearing/reload loop:** WPs sometimes get cleared and reload endlessly without completing. Investigate interaction between MSP state machine and WP cache invalidation.
- *(Add further non-breaking bugs here as discovered)*

---

## Success Criteria

- `paint()` uses < 15,000 instructions per frame (measured via checkpoint profiling)
- `wakeup()` compute cycle completes within 1-2 tasks per call (no frame-rate regression)
- `pcall` wrapper removed
- No visual regressions
- No new garbage created in paint() hot path
- No redundant recomputation when inputs are unchanged (verified via dirty-flag hit counters)
