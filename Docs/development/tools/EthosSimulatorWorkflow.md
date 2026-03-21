# ETHOS Simulator Workflow (VS Code)

Goal: Significantly speed up the local test cycle for widget changes (without copying to hardware every time).

---

## 1) Prerequisites

VS Code extension installed:
- `bsongis.ethos` (Ethos simulator extension)

Workspace configuration (already set up):
- File: `.vscode/settings.json`
- Current values:
  - `ethos.server`: `https://ethos.studio1247.com`
  - `ethos.version`: `nightly26`
  - `ethos.firmware`: `X20S_FCC`
  - `ethos.root`: `RADIO`

Note:
- `ethos.root` must point to the folder containing `scripts/` and `bitmaps/`.
- Keep `ethos.root` workspace-relative (for example `RADIO`).

---

## 2) Available Ethos Commands

Via Command Palette (`Ctrl+Shift+P`):
- `Ethos: Start Ethos`
- `Ethos: Stop Ethos`
- `Ethos: Open Display`
- `Ethos: Open Telemetry`
- `Ethos: Set firmware`
- `Ethos: Set root directory`

---

## 3) Keybindings (Workspace)

File: `.vscode/keybindings.json`

Active shortcuts:
- `Ctrl+Alt+S` → Start Simulator
- `Ctrl+Alt+D` → Open Display
- `Ctrl+Alt+T` → Open Telemetry
- `Ctrl+Alt+X` → Stop Simulator
- `Ctrl+Alt+R` → **Restart Simulator** (`Stop` + `Start`)

Recommendation:
- After larger Lua changes, always use `Ctrl+Alt+R` for a clean state.

---

## 4) Recommended Test Sequence (fast & reproducible)

1. `Ctrl+Alt+R` (Restart)
2. `Ctrl+Alt+D` (Open Display)
3. Load the widget and run a fixed test sequence:
   - Home → Widget (Initial Entry)
   - Zoom `+/-`
   - Provider/MapType switch
   - 20–30s of normal use
4. Check logs (PERF + SETTINGS + TILE)
5. After a code change, repeat from step 1

Why:
- Comparable runs (A/B) only work with the same sequence and a clean restart.

---

## 5) Performance Tests (Baseline/Experiments)

For performance experiments:
- `Enable debug log = ON`
- `Enable perf profile = ON`

Expected output:
- A `PERF WINDOW` block as an ASCII table every 5s
- Plus `SETTINGS`/`TILE`/`TOUCH` events depending on actions

See also:
- `Docs/development/workstreams/PerformanceExperimentsPlan.md`

Telemetry replay (for repeatable sensor input in simulator):
- Helper doc: `Docs/development/helper/TelemetryReplay.md`
- Quick start: `.\Docs\development\tools\ETHOS VSCode Sim Telemetry Injection\replay-telemetry-log.ps1 -Speed 1 -Loop`
- Deterministic demo logs: `Docs/development/tools/ETHOS VSCode Sim Telemetry Injection/Synthetic_Logs/`

---

## 6) Troubleshooting

### Simulator does not start
- Open Command Palette and call `Ethos: Start Ethos` directly
- Check that `ethos.root` points correctly to `RADIO`
- `Ctrl+Alt+X`, then `Ctrl+Alt+S`

### Wrong or no scripts in the simulator
- Check `ethos.root`
- Must be `.../RADIO`, not the repo root

### Display does not open
- Start `Start Ethos` first, then `Open Display`

### Changes don't seem to be active
- `Ctrl+Alt+R` (Stop+Start)
- Then re-open the display

---

## 7) When Hardware Testing is Still Required

The simulator is ideal for fast iteration, but hardware remains mandatory for:
- Real touch latency on radio hardware
- Actual UI stutter during screen swipes
- SD I/O behavior and timing spikes
- Final verification before merge
