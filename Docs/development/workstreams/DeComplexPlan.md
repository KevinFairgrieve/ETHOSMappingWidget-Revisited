# ETHOS Mapping Widget – De-Complexity Plan

**Branch:** `de-complex`  
**Goal:** Reduce Lua instruction count per frame to avoid ETHOS "Maximum number of instructions reached" aborts and create headroom for future features.  
**Constraint:** No functionality loss. Debug/log functions that exit early when disabled are kept.

---

## Problem Statement

The widget periodically hits the ETHOS instruction limit during normal operation. While it recovers, adding future features will make this worse. The root causes are:

- Duplicated utility functions across 6 files
- Verbose guard patterns evaluated every frame (~40 call sites)
- Dead code inherited from the Yaapu base that is never called
- Redundant fallback chains in hot paths (tile drawing, filesystem access)

---

## Simplification Steps (Priority Order)

### HIGH – Direct Instruction Savings Per Frame

#### Step 1: Remove Dead Code (Yaapu Leftovers)

**Impact:** ~150 lines removed, fewer function registrations in module tables.  
**Risk:** None – these functions have zero callers.

Functions to remove from **utils.lua**:
- `utils.processTelemetry()` – empty placeholder
- `utils.playTime()` – voice announcements, never called
- `utils.getMaxValue()` – references `status.minmaxValues` which doesn't exist
- `utils.calcMinValue()` – never called
- `utils.getNonZeroMin()` – never called
- `utils.resetTimer()` / `startTimer()` / `stopTimer()` – Yaapu timer, never used
- `utils.playSound()` – references `enableHaptic`/`disableAllSounds` which don't exist in conf
- `utils.getBitmask()` / `bitExtract()` – only self-referencing, never called externally
- `bitmaskCache` table – only used by the above

Related cleanup from **utils.lua**:
- `alwaysOn` / `alwaysOff` source handles – only used by removed timer functions
- `sources` table + `getSourceValue()` / `getRSSI()` – only used by `telemetryEnabled()`

Functions to remove from **drawlib.lua**:
- `drawLib.drawCompassRibbon()` – empty placeholder
- `drawLib.drawWindArrow()` – empty placeholder
- `drawLib.drawBlinkBitmap()` – never called
- `drawLib.unloadBitmap()` – never called
- `drawLib.drawHomeIcon()` – never called
- `drawLib.drawLineWithClipping()` – only called by itself (internal)
- `drawLib.drawLineWithClippingXY()` – only called by `drawLineWithClipping`

**Note:** `telemetryEnabled()` and `getRSSI()` are referenced from `drawLib.drawNoTelemetryData()`. These need to be evaluated: either inline the RSSI check or keep a minimal version.

---

#### Step 2: Consolidate Duplicate `flagEnabled()` (6 copies → 1)

**Impact:** ~60 lines removed, single function registration.  
**Files affected:** main.lua (`configFlagEnabled`), maplib.lua, tileloader.lua, drawlib.lua, resetLib.lua, utils.lua

**Approach:** Keep one canonical copy in `utils.lua`, export via `status.flagEnabled` during `init()`. All other files reference `status.flagEnabled` instead of local copies.

---

#### Step 3: Consolidate Duplicate `getTime()` (4 copies → 1)

**Impact:** ~40 lines removed.  
**Files affected:** main.lua (full 3-fallback), maplib.lua (full 3-fallback), layout_default.lua (`os.clock()*100`), utils.lua (`os.clock()*100`)

**Approach:** Keep canonical copy in main.lua (has the best implementation with `system.getTimeCounter`), export via `status.getTime`. All libraries use `status.getTime()`.

---

#### Step 4: Simplify Debug/Perf Guard Patterns (~40 sites)

**Impact:** Saves ~200+ instructions per frame when debug is disabled.  
**Current pattern (4-6 conditions per call site):**
```lua
if status and status.conf and flagEnabled(status.conf.enableDebugLog)
   and libs and libs.utils and libs.utils.logDebug then
```

**New pattern (1 condition):**
```lua
if status.debugEnabled then
```

**Approach:**
- Add `status.debugEnabled = false` and `status.perfActive = false` to `mapStatus`
- Toggle these booleans in the `configure()` write callbacks and in `applyConfig()`
- Replace all verbose guard chains with the cached boolean check

---

#### Step 5: Reduce Perf Profiler Overhead When Disabled

**Impact:** ~50-80 instructions saved per frame when profiler is off.  
**Current:** `perfProfileEnabled()` does 3 table lookups + 2 `configFlagEnabled` calls every `paint()`, `wakeup()`, and `event()`.

**Approach:** Use `status.perfActive` boolean (from Step 4). The `perfProfileEnabled()` function and all `if perfActive then` blocks become trivial single-boolean checks.

---

#### Step 6: Simplify `drawTiles()` Bitmap Fallback Chain

**Impact:** Saves ~3 function calls per tile (24-54 tiles per frame = 72-162 calls saved).  
**Current chain per tile:**
```lua
getBitmap() → getLoadingBitmap() → getNoMapBitmap() → getFallbackBitmap()
```

**Approach:** Cache `loadingBitmap` and `noMapBitmap` as local variables at function entry, inline the fallback: `bmp or loadingBmp or noMapBmp`.

---

### MEDIUM – Load-Time and Configuration Savings

#### Step 7: Simplify `clearTable()` Recursion

**Impact:** Minor per-frame, but simplifies code.  
**Current:** Recursive `type(v) == "table"` check on every entry.  
**Reality:** Only called on flat tables (`tiles`, `tiles_path_to_idx`, `trailWaypoints` with 1-level depth).

**Approach:** Replace with a simple for-loop nil-assignment or direct table reassignment.

---

#### Step 8: Remove `lfs` Loading and Fallback FS APIs

**Impact:** Saves startup `require` attempt; removes ~80 lines of dead filesystem fallback code.  
**Current:** `pcall(require, "lfs")` at main.lua startup. `getSortedDirectories()` tries 3 filesystem APIs.  
**Reality:** ETHOS only provides `system.listFiles`. The `lfs.dir()` and `dir()` paths are never entered on hardware.

**Approach:** Remove `lfs` require. Keep only `system.listFiles` path in `getSortedDirectories()`.

---

### LOW – Cleanup & Readability

#### Step 9: Inline Trivial `applyDefault()` Calls

**Impact:** Minor instruction savings, improved readability.  
**Current:** `applyDefault(value, 1, {"m/s","km/h",...})` called ~15 times.  
**Simple cases:** `value or default` without lookup table.

---

#### Step 10: Defer `string.format()` Inside Debug Guards

**Impact:** Minor – avoids string allocation when debug is off.  
**Current:** Some `string.format()` calls happen before the debug-enabled check.

---

## Execution Rules

1. **One step at a time** – commit after each step
2. **Test after each step** – verify widget loads and renders correctly
3. **Rollback fast** if any regression appears
4. **No mixed refactors** – each commit is one logical change
5. **Keep debug/log functions** that exit early when disabled

---

## File Inventory

| File | Lines | Role |
|------|-------|------|
| `main.lua` | ~1920 | Widget lifecycle, config, perf profiler |
| `maplib.lua` | ~730 | Map projection, tile rendering, trail |
| `tileloader.lua` | ~470 | Tile I/O, bitmap cache, load queue |
| `drawlib.lua` | ~440 | Drawing primitives, top bar, overlays |
| `layout_default.lua` | ~360 | Default layout composition |
| `utils.lua` | ~460 | GPS math, debug logger, telemetry helpers |
| `resetLib.lua` | ~60 | Table clearing, layout reset |

**Total:** ~4440 lines of Lua across 7 core files.  
**Estimated reduction after all steps:** ~400-500 lines removed, ~200+ instructions saved per frame.
