# Telemetry Replay Helper

## Purpose
`replay-telemetry-log.ps1` replays a CSV telemetry log line by line into `RADIO/sensors.json` so the ETHOS simulator receives live sensor updates.

The replay tooling and demo logs currently live in:

`Docs/development/tools/ETHOS VSCode Sim Telemetry Injection/`

## Files
| File | Purpose |
|---|---|
| `Docs/development/tools/ETHOS VSCode Sim Telemetry Injection/replay-telemetry-log.ps1` | Replay script |
| `Docs/development/tools/ETHOS VSCode Sim Telemetry Injection/DemoTelemetry.csv` | Base demo log (EdgeTX format) |
| `Docs/development/tools/ETHOS VSCode Sim Telemetry Injection/Synthetic_Logs/DemoTelemetry_Synthetic_1min_straightLine_250ms.csv` | Deterministic 1-minute straight-line demo log |
| `Docs/development/tools/ETHOS VSCode Sim Telemetry Injection/Synthetic_Logs/DemoTelemetry_Synthetic_5min_pattern_250ms.csv` | Deterministic 5-minute mixed-pattern demo log |
| `RADIO/sensors.json` | Output — read live by the ETHOS extension |

## Default behavior

Without parameters the script starts immediately with sensible defaults:

- **Log**: `DemoTelemetry.csv` in the same folder as the script
- **Target**: `RADIO/sensors.json` at the repository root (auto-detected from any working directory)
- **Speed**: real-time (`-Speed 1`)
- **Timing**: computed from CSV timestamps

## Deterministic demo logs

For repeatable simulator tests, two generated logs are available next to the replay script:

- `DemoTelemetry_Synthetic_1min_straightLine_250ms.csv`
	- 240 rows
	- constant 20 m/s straight-line flight
	- fixed 250 ms cadence

- `DemoTelemetry_Synthetic_5min_pattern_250ms.csv`
	- 1200 rows
	- first minute on a continuous 500 m diameter circle
	- remaining four minutes with deterministic 20 s direction segments
	- fixed 250 ms cadence

Both generated logs are intended for reproducible A/B tests in the simulator.

## Terminal output

At startup the script prints a header, then an in-place progress line:

```
Replay source : ...\DemoTelemetry.csv
Streaming to  : ...\RADIO/sensors.json
Rows          : 1234
Speed         : 1x
Format        : EdgeTX
ESC sensor    : False
Log rate      : ~2 Hz (median dt 500 ms)

Row 42/1234 (3%)  lat=51.36459 lon=11.93512 alt=43.0m hdg=316.5° sats=12
```

The progress line updates in-place and shows percentage, position, altitude, heading, and satellite count.

## Examples

From the workspace root or the script folder:

```powershell
# Real-time replay with demo log (recommended for simulator tests)
.\Docs\development\tools\ETHOS VSCode Sim Telemetry Injection\replay-telemetry-log.ps1 -Speed 1 -Loop

# Replay deterministic 1-minute straight line log
.\Docs\development\tools\ETHOS VSCode Sim Telemetry Injection\replay-telemetry-log.ps1 -LogPath ".\Docs\development\tools\ETHOS VSCode Sim Telemetry Injection\Synthetic_Logs\DemoTelemetry_Synthetic_1min_straightLine_250ms.csv" -Speed 1 -Loop

# Replay deterministic 5-minute pattern log
.\Docs\development\tools\ETHOS VSCode Sim Telemetry Injection\replay-telemetry-log.ps1 -LogPath ".\Docs\development\tools\ETHOS VSCode Sim Telemetry Injection\Synthetic_Logs\DemoTelemetry_Synthetic_5min_pattern_250ms.csv" -Speed 1 -Loop

# Custom log, double speed
.\Docs\development\tools\ETHOS VSCode Sim Telemetry Injection\replay-telemetry-log.ps1 -LogPath ".\Docs\development\tools\ETHOS VSCode Sim Telemetry Injection\MyFlight.csv" -Speed 2 -Loop

# EdgeTX log from .vscode, 5x speed
.\Docs\development\tools\ETHOS VSCode Sim Telemetry Injection\replay-telemetry-log.ps1 -LogPath ".\vscode\MyFlight.csv" -Speed 5

# With ESC sensor (useful for multirotor logs)
.\Docs\development\tools\ETHOS VSCode Sim Telemetry Injection\replay-telemetry-log.ps1 -Speed 1 -Loop -IncludeEsc
```

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `-LogPath` | `DemoTelemetry.csv` | Input CSV |
| `-SensorsPath` | `RADIO/sensors.json` | Output JSON; relative paths are resolved against the repo root |
| `-Speed` | `1.0` | Replay speed (`1` = real-time, `2` = double, etc.) |
| `-Loop` | — | Restart from the beginning after the last frame |
| `-Format` | `auto` | `auto` / `edgetx` / `generic` — detects format from CSV headers |
| `-IncludeEsc` | — | Optional ESC sensor (RPM/voltage/current) |

## Using your own log

1. Put the CSV next to the replay script or anywhere else in the repo (or pass any path with `-LogPath`)
2. Let the script auto-detect the format or force `-Format edgetx` / `-Format generic`

**EdgeTX format** (auto-detected):
- Required columns: `Date`, `Time`, `GPS`, `1RSS(dB)`, `RxBt(V)`, `Ptch(rad)`, `Roll(rad)`
- Timing derived from `Date` + `Time`

**Generic format**:
- Required field: `timestamp_ms` (Unix milliseconds)
- GPS: `lat`, `lon`, `alt_m`, `speed_mps`, `course_deg`, `sats`

## Technical details

- **Timing**: uses real timestamps from the CSV and waits exactly `delta / Speed` ms between rows. No fixed tick.
- **Write**: atomic write via temp file + `File.Replace`, so the extension never reads a partial JSON.
- **Encoding**: UTF-8 without BOM, so `JSON.parse()` in the ETHOS extension works reliably.
- **Project path**: detects the repo root based on `RADIO/` and `Docs/`.

## Requirements

- ETHOS simulator running (extension `bsongis.ethos`)
- VS Code Developer: Reload Window after extension patches
- PowerShell 5.1 (Windows) or pwsh