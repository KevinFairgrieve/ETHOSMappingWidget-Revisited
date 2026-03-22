# ETHOS Bitmap GC-Timing & RAM-Kill

## Problem

ETHOS kills the widget with an immediate OOM termination even though the
reported memory usage (~831 KB) is well below the per-widget limit (~2600 KB).
The ETHOS internal log shows multiple bitmap loads in rapid succession
(1–3 ms apart) right before the kill.

## Root Cause

Lua uses an **incremental garbage collector**.  When a reference to a bitmap
userdata object is set to `nil` (e.g. inside `trimCache()`), the object is
**not freed immediately**.  It remains in memory until the next full GC cycle
finalises it.

### The Critical Sequence

```
paint()
  └─ drawMap()
       └─ loadAndCenterTiles()
             └─ trimCache()          ← evicts old bitmaps (sets refs to nil)
                                       BUT: GC has NOT freed them yet!

wakeup()  (next tick)
  └─ processQueue(2)                ← loads 2 new bitmaps via lcd.loadBitmap()
                                       Old + new bitmaps coexist in RAM

wakeup()  (tick +2 through +9)
  └─ processQueue(2)                ← 2 more new bitmaps per tick
                                       transient RAM peak keeps growing

wakeup()  (tick +10)
  └─ collectgarbage()               ← old bitmaps are FINALLY freed
```

Between `trimCache()` and the next `collectgarbage()` (which runs every
10 wakeups), up to **20 new tiles** can be loaded while the old ones are still
occupying memory.  At ~20 KB per tile:

- 30 old tiles (evicted but not yet freed): **~600 KB**
- 20 new tiles (loaded between two GC cycles): **~400 KB**
- Combined: **~1000 KB in bitmaps alone** + Lua heap, UI bitmaps, stacks

This transient peak can exceed the ETHOS limit even though the steady-state
cache size is well within budget.

### Why clearCache() Was Not Affected

`clearCache()` (called on zoom level / provider changes) already recognised
this risk: it sets every reference to `nil` individually **before** reassigning
the table.  Additionally, the load queue is cleared in the same call, so no new
loads can happen before `clearCache()` returns.

`trimCache()` (called during map scrolling) had the same GC gap **without**
any mitigation — and new tiles are enqueued and loaded immediately afterwards.

## Fix

A `pendingGCBeforeLoad` flag in `tileloader.lua`:

```lua
local pendingGCBeforeLoad = false
```

**`trimCache()`** sets the flag whenever tiles are evicted:

```lua
if removed > 0 then
    cacheCount = cacheCount - removed
    pendingGCBeforeLoad = true
    -- ...
end
```

**`processQueue()`** runs a full GC cycle **before** allocating new bitmaps:

```lua
if pendingGCBeforeLoad then
    collectgarbage()
    collectgarbage()  -- two passes: first marks, second finalises/frees
    pendingGCBeforeLoad = false
end
```

### Why Two collectgarbage() Calls?

Lua's GC needs two full cycles to completely free userdata with a `__gc`
finaliser:

1. **First cycle**: Marks unreachable objects and invokes `__gc` finalisers.
   The object is "resurrected" because the finaliser could theoretically create
   a new reference to it.
2. **Second cycle**: The resurrected object is found unreachable again and its
   memory is actually released.

Bitmap userdata from `lcd.loadBitmap()` likely has a native finaliser, so both
passes are required to reliably free the native memory (not just the Lua
wrapper).

### Why Not Simply Run GC More Often?

`collectgarbage()` costs instructions.  ETHOS enforces a strict per-frame
instruction limit.  Running a full GC on every wakeup would waste budget on
frames where no eviction happened.  The flag-based approach ensures the GC runs
**exactly once** — at precisely the right moment: after eviction, before new
allocations.

## Cache Geometry (Reference)

The number of concurrently cached tiles is governed by the cache-ring constants:

| Constant                             | Value | Purpose                                  |
|--------------------------------------|-------|------------------------------------------|
| `TILE_CACHE_REFERENCE_MARGIN_TILES`  | 0     | Extra margin around the visible window   |
| `TILE_CACHE_RING_TILES`              | 0     | Symmetric buffer ring                    |
| `TILE_CACHE_DIRECTIONAL_GUARD_TILES` | 1     | Directional prefetch guard strip         |

The visible window is `TILES_X × TILES_Y` = **8 × 3 = 24 tiles**.

When scrolling with both X and Y components, the keep-window expands to
**(8+2) × (3+2) = 50 tiles** × ~20 KB ≈ **1000 KB** in bitmaps alone.

## Observed ETHOS Behaviour

- ETHOS checks memory usage **after every allocation**, not at frame end.
- The kill is immediate upon exceeding the limit, with no opportunity for the
  widget to free memory first.
- The RAM figure reported in the ETHOS log (~831 KB) can differ from the
  widget's own `collectgarbage("count")` because ETHOS also tracks native
  bitmap memory that is invisible to Lua.

## Files

- **Fix**: `RADIO/scripts/ethosmaps/lib/tileloader.lua` (`pendingGCBeforeLoad`)
- **GC scheduling**: `RADIO/scripts/ethosmaps/main.lua` (periodic GC every 10 wakeups)
- **Cache eviction**: `tileloader.trimCache()` (spatial ring eviction)
- **Cache clear**: `tileloader.clearCache()` (full reset on zoom/provider change)
