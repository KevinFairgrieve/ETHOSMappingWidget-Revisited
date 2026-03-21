# ETHOS Mapping Widget – Debug Logger Guide

**Version:** 1.2 (March 2026)  
**Status:** Current branch behavior

---

## 1. How to Enable the Logger

1. Long-press the widget → **Configure**.
2. Scroll all the way to the bottom.
3. Turn **"Enable debug log"** to **ON**.

The log file will be created at:  
`/scripts/ethosmaps/debug.log`

---

## 2. Basic Usage – How to Log Data

You can log from anywhere in the code with this single line:

```lua
libs.utils.logDebug("CATEGORY", "Your message here")
```

### Examples:

```lua
-- Simple message
libs.utils.logDebug("MYTEST", "I reached this point!")

-- With variables
local speed = 25.4
libs.utils.logDebug("SPEED", string.format("Groundspeed = %.1f km/h", speed))

-- Multiple values
libs.utils.logDebug("GPS", string.format("lat=%.6f lon=%.6f", lat, lon))
```

---

## 3. Existing Categories (already used in the code)

| Category   | When it logs                              | Example |
|------------|-------------------------------------------|---------|
| `SETTINGS` | Widget start + toggle + rollover          | `=== DEBUG SESSION STARTED ===` |
| `GPS`      | Only on real position change              | `lat=51.488651 lon=11.977728` |
| `TOUCH`    | Touch events and zoom button presses      | `value=16641 x=751 y=134` |
| `PERF`     | 5-second profiler windows and state changes | `=== PERF PROFILE ACTIVE (5s windows) ===` |
| `TILE`     | Tile load/cache/zoom/recenter + path diagnostics | `Tile format detected for provider:2|mapType:Hybrid: .png (source: yaapu-fallback)` |
| `ERROR`    | Recommended for pcall failures            | `Crash in myFunction(): nil value` |

---

## 4. Adding Custom Logs & Safe Error Checking

### Simple check:
```lua
if status.telemetry.lat == nil then
    libs.utils.logDebug("ERROR", "No GPS fix available!")
end
```

### With pcall (recommended for critical sections):
```lua
local success, err = pcall(function()
    -- your risky code here
    local result = myFunction()
end)

if not success then
    libs.utils.logDebug("ERROR", "Crash in myFunction(): " .. tostring(err))
else
    libs.utils.logDebug("OK", "myFunction() completed successfully")
end
```

---

## 5. Reading the Log File

- Connect the SD card to your PC.
- Open `/scripts/ethosmaps/debug.log` with any text editor.
- Line format:

```
HH:MM:SS.mm | CATEGORY | Message
```

Example:
```
02:41:05.59 | GPS      | lat=51.488674 lon=11.977743
```

---

## 6. Rollover Behavior (Automatic Cleanup)

- Maximum size (default): **5000 lines**
- When the limit is reached, the logger automatically keeps only the **last 3500 lines** (70 %)
- The oldest lines are discarded
- A clear marker is added:

```
00:00:00.00 | SETTINGS | === DEBUG LOG ROLLED (kept last 3500 lines) ===
```

The file stays small forever.

---

## 7. Tips & Best Practices

- Use your own category names (e.g. `ZOOM`, `HOME`, `MYTEST`) – they are right-aligned automatically.
- To stop logging completely: Turn "Enable debug log" **OFF** in settings.
- The perf profiler only runs when **both** `Enable debug log` and `Enable perf profile (5s)` are enabled.
- The perf profile option is only available while debug logging is enabled.
- To start completely fresh: Delete `debug.log` from the SD card.
- For quick debugging: Add `libs.utils.logDebug("DEBUG", "Value of X = " .. tostring(X))` anywhere you need to inspect something.
- When disabled, the logger exits before file writes, rollover work, and buffered flushes.

---

## 8. TILE Debug Diagnostics

The widget now logs detailed tile lookup information that makes path issues easy to pinpoint.

### Key TILE messages

- `loadAndCenterTiles: tiles changed (load/zoom/recenter)`
    - Normal event when recentering, zooming, or changing map source.

- `Tile format detected for provider:X|mapType:Y: .png/.jpg (source: ethosmaps|yaapu-fallback|yaapu)`
    - Confirms that real tile files were found and loaded.
    - `source: ethosmaps` = native folders.
    - `source: yaapu-fallback` = Google fallback from Yaapu folders.

- `No tile files found for provider:X|mapType:Y; using fallback bitmap (notiles/nomap)`
    - No tile found for current view.

- `First missing tile key: /z/x/y` (or `/z/y/x` for ESRI)
    - Shows the exact tile index the widget tried first.

- `Attempted path N: /bitmaps/...`
    - Shows the full real path probes in order.
    - Compare this directly with the SD card folder/file names.

### Fast troubleshooting flow

1. Find the first `No tile files found...` block for the failing provider/map type.
2. Compare `Attempted path` with your SD folders:
     - provider folder name (`GOOGLE`, `ESRI`, `OSM`)
     - map type folder (`Map`, `Satellite`, `Hybrid`, `Street`, `Terrain`)
     - zoom folder (`z`)
     - coordinate order (`z/x/y` or `z/y/x`)
     - filename pattern (`y.png` vs `s_x.png` for Yaapu Google)
3. If one path differs, fix downloader output or folder structure and retest.

### About "Maximum number of instructions reached"

- This warning can appear when too much work/logging happens in one cycle.
- For diagnosis, keep debug enabled only while reproducing the issue, then disable it.
- If needed, clear `debug.log` before a focused test to reduce noise.

---

**Ready to use.**  
This guide matches the current branch behavior as of March 2026.
