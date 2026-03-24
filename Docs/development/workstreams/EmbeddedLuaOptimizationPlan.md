# Embedded Lua Optimization Plan

**Target platform:** STM32H7 (ARM Cortex-M7, ~480 MHz), 8 MB extended SDRAM  
**Lua runtime:** Lua 5.4 embedded (no LuaJIT)  
**Status:** Complete — all tiers implemented on `embedded-lua-optimization` branch

---

## Background

On embedded Lua without JIT compilation:

- **Every global access** (`math.sin`, `string.format`, `type()`, `os.clock()`) is a hash-table lookup in `_ENV`.
- **Every `.` field access** (`status.telemetry.lat`) is a hash lookup per dot.
- **Every `{}` table literal** allocates heap memory and increases GC pressure.
- **Every `string.format()` / `..` concatenation** creates a new string object on the heap.
- **`collectgarbage()`** can stall the CPU for 5–50 ms depending on heap size.

These costs are negligible on desktop Lua or LuaJIT but compound significantly on a 480 MHz MCU running a real-time UI at ~2–3 fps with ~200–400 ms frame times.

---

## Instruction Limit Problem

ETHOS imposes a per-frame Lua instruction limit (~40k instructions). Several code paths — especially with debug logging enabled — can exceed this limit, causing the widget to be killed or skipped for that frame.

**Known triggers:**
- `drawTopBar()` with multiple sensor entries and font-selection loops
- `bgtasks()` with debug-enabled GPS logging + coordinate formatting
- `loadAndCenterTiles()` when rebuilding the full tile grid (24 tiles × path generation)
- Performance profiling blocks (`perfTableRow()` × 8 string.format calls every 5 seconds)

**Required solution:**
- Identify the instruction-heaviest code paths and reduce their instruction count
- Consider splitting heavy work across multiple frames (cooperative yielding)
- Evaluate whether some debug-only code paths can be gated more aggressively or deferred to a background cycle
- The local-caching optimizations listed below directly reduce instruction count (fewer hash lookups = fewer VM instructions per operation)

---

## Tier 1 — High Impact

### 1. Module-level local caching of stdlib functions (all files)

**Problem:** `math.sin`, `math.floor`, `string.format`, `os.clock`, `type()`, `tostring()`, `lcd.font()`, etc. are looked up via hash table on every call. Estimated ~200–400 unnecessary hash lookups per frame across all files.

**Fix:** Cache at the top of each `.lua` file:
```lua
local floor, abs, sin, cos, log, atan, deg, rad, pi =
  math.floor, math.abs, math.sin, math.cos, math.log,
  math.atan, math.deg, math.rad, math.pi
local fmt = string.format
local type = type
local tostring = tostring
local tonumber = tonumber
```
Then replace all `math.floor(x)` → `floor(x)`, `string.format(...)` → `fmt(...)`, etc.

**Files affected:** main.lua, maplib.lua, drawlib.lua, layout_default.lua, tileloader.lua, utils.lua

**Estimated savings:** 200–400 hash lookups/frame → near-zero (local access is a register read)

---

### 2. Eliminate per-frame table allocation in bgtasks() (main.lua)

**Problem:** `local gpsData = {}` is allocated on every `bgtasks()` call (~50×/s). It only holds `.lat` and `.lon`.

**Fix:** Replace with two local variables:
```lua
local gpsLat, gpsLon = nil, nil
-- ... later:
gpsLat = srcLat:value()
gpsLon = srcLon:value()
```

**Estimated savings:** ~50 table allocations/second eliminated

---

### 3. Cache math globals in coord_to_tiles() (maplib.lua)

**Problem:** `math.sin`, `math.log`, `math.pi`, `math.floor` — 5+ global lookups per call. This function is called every frame + per trail waypoint.

**Fix:** Use module-level cached locals (see #1). Also pre-compute `DEG_TO_RAD = pi / 180`.

**Estimated savings:** 10–20 hash lookups per frame in the most CPU-intensive function

---

### 4. Pre-allocate drawTopBar tables (drawlib.lua)

**Problem:** Three tables created every frame in `drawTopBar()`:
- `sensorEntries{}` — sensor config table
- `sensorNames{}` — temporary name cache
- `candidateFonts{}` — font selection array

**Fix:** Allocate as module-level tables. Clear and reuse in-place instead of creating new ones each frame.

**Estimated savings:** ~3 table allocations/frame (~150+ bytes of garbage/frame)

---

### 5. Cache formatted bar strings in layout_default.lua

**Problem:** 4× `string.format("%.01f", ...)` per paint for speed, heading, travel distance, home distance — even when the value hasn't changed.

**Fix:** Delta-check against last formatted value. Only re-format when the value changes:
```lua
if lastGroundSpeed ~= groundSpeed then
  lastGroundSpeed = groundSpeed
  cachedSpeedStr = fmt("%.01f", groundSpeed * multiplier)
end
```

**Estimated savings:** 4 string allocations/frame → typically 0 (values change slowly)

---

## Tier 2 — Medium Impact

### 6. Cache nested table access in bgtasks() (main.lua)

**Problem:** `mapStatus.telemetry.lat/lon` read 5–10× without local cache. `mapStatus.avgSpeed.*` has ~15+ nested lookups in the speed calculation block.

**Fix:** Cache subtables at function start:
```lua
local telemetry = mapStatus.telemetry
local avgSpeed = mapStatus.avgSpeed
local conf = mapStatus.conf
```

---

### 7. Cache status/conf fields in layout_default paint (layout_default.lua)

**Problem:** `status.conf.horSpeedMultiplier`, `status.colors.white`, `barSnapshot.groundSpeed` etc. accessed without locals: 30+ hash lookups per paint.

**Fix:** Cache `conf`, `colors`, and `barSnapshot` fields at paint function start.

---

### 8. Reduce pcall overhead in safeSensorName() (drawlib.lua)

**Problem:** `pcall(function() return sensor:name() end)` + `tostring()` called ~10×/frame in drawTopBar.

**Note:** `pcall()` is necessary because ETHOS sensor API can throw. However, results could be cached per-sensor per frame tick, reducing 10 pcall+tostring to ~3.

---

### 9. tiles_to_path string allocations (maplib.lua)

**Problem:** `string.format("/%d/%.0f/%.0f", ...)` called up to 24× in tile loop during heavy updates.

**Note:** These strings serve as cache keys. Alternative approaches (numeric composite keys) would be too invasive. Accept as-is or explore numeric key encoding later.

---

### 10. Cache queue length in processQueue (tileloader.lua)

**Problem:** `#highQueue` evaluated in while-loop condition every iteration.

**Fix:** Cache length before loop: `local highLen = #highQueue`

---

## Tier 3 — Low Impact / Cleanup

### 11. Optimize getTime() (main.lua)

**Problem:** Checks 3 global sources sequentially (`system.getTimeCounter`, `os.time`, `os.clock`) — called ~2× per frame.

**Fix:** Cache the winning source on first successful call.

---

### 12. Touch event handler (main.lua)

**Problem:** `math.floor()` called 8× uncached, `tostring()` 3× — only during touch events.

**Fix:** Apply local caching (covered by #1). Low priority since touch events are infrequent.

---

## Explicitly NOT Recommended

| Item | Reason |
|------|--------|
| Remove double `collectgarbage()` in wakeup | Intentional for ETHOS bitmap `__gc` finalizers. Removing risks OOM crashes. |
| Replace `pcall()` in sensor access | ETHOS API can throw on invalid sensors. Safety > performance. |
| Numeric tile cache keys | Too invasive for marginal gain. String keys work and are debuggable. |

---

## Implementation Order

1. ~~**Module-level local caching** (#1)~~ — ✅ Done
2. ~~**gpsData elimination** (#2)~~ — ✅ Done
3. ~~**drawTopBar table reuse** (#4)~~ — ✅ Done
4. ~~**Layout string caching** (#5)~~ — ✅ Done
5. ~~**Nested field caching** (#6, #7)~~ — ✅ Done
6. ~~**pcall cache in safeSensorName** (#8)~~ — ✅ Done
7. ~~**Cache queue length** (#10)~~ — ✅ Done
8. ~~**Cache getTime() source** (#11)~~ — ✅ Done
9. #3 covered by #1, #9 accepted as-is, #12 covered by #1
