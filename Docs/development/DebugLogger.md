# ETHOS Mapping Widget – Debug Logger Guide

**Version:** 1.1 (March 2026)  
**Status:** Production-ready & merged

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
| `TOUCH`    | Every touch event                         | `value=16641 x=751 y=134` |
| `TILE`     | Tile load / cache / zoom / recenter       | `loadAndCenterTiles: tiles changed` |
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
- To start completely fresh: Delete `debug.log` from the SD card.
- For quick debugging: Add `libs.utils.logDebug("DEBUG", "Value of X = " .. tostring(X))` anywhere you need to inspect something.
- The logger has **zero overhead** when disabled.

---

**Ready to use.**  
This guide is now 100 % up-to-date with the merged code.
```