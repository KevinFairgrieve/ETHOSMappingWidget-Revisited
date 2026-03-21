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

### Local extension patch: live `sensors.json` reload (reproducible)

For simulator telemetry injection, the locally installed `bsongis.ethos` extension has a small custom patch so the running simulator notices external updates to `RADIO/sensors.json` without reopening the telemetry panel.

Important clarification:
- The watched file is `sensors.json` under `ethos.root`.
- It is **not** `settings.json`.

Patched file (local machine, not repo):
- `C:\Users\{USERNAME}\.vscode\extensions\bsongis.ethos-0.1.11\out\extension.js`

Official baseline for comparison:
- Extension package: `bsongis.ethos-0.1.11` from VS Code Marketplace
- Unmodified file: the shipped `out/extension.js` in that package

#### Re-apply procedure (from official extension)

1. Install/update `bsongis.ethos` from Marketplace.
2. Close VS Code windows using the extension.
3. Backup file:
   - `C:\Users\marcb\.vscode\extensions\bsongis.ethos-0.1.11\out\extension.js`
4. Re-apply the code changes listed below.
5. Restart VS Code.
6. In workspace settings, use:
   - `ethos.version = nightly26`
   - `ethos.root = RADIO`     <-- your project folder
7. Run `Ethos: Stop Ethos` then `Ethos: Start Ethos`.

#### Exact modifications vs official `out/extension.js`

- Added module-level state:
  - `let sensorsFileMtimeMs = 0;`
  - `let sensorsInterval;`
  - `let injectSPortFrameAvailable = false;`
- In `stopEthos(context)`:
  - reset `sensorsFileMtimeMs = 0;`
  - reset `injectSPortFrameAvailable = false;`
  - `clearInterval(sensorsInterval)` and set `sensorsInterval = undefined`
- In `startEthos(context, output)` after `Module._start()`:
  - detect support with `typeof Module['_injectSPortFrame'] === 'function'`
  - call `loadSensors()` once on startup if no sensors are loaded yet
  - start a `setInterval(..., 10)` loop that:
    - resolves `${ethos.root}/sensors.json`
    - checks the file modification time
    - reloads the file only when `mtimeMs` increased
    - injects current sensor frames only when `injectSPortFrame` is exported by the simulator build
  - if the export is missing, log a clear message that live `sensors.json` replay is disabled for that simulator version
- In `loadSensors()`:
  - update `sensorsFileMtimeMs = fs.statSync(sensorsFilePath).mtimeMs || 0;`

Verification checklist:
- On simulator start with `nightly26`, no assert about `injectSPortFrame` appears.
- While replay script runs, updated `RADIO/sensors.json` values are reflected live.
- On `Ethos: Stop Ethos`, no background polling remains active.

Why this patch exists:
- The replay helper writes `RADIO/sensors.json` continuously.
- Without the local extension patch, the simulator extension does not reliably pick up those external file changes during runtime.
- With the patch, telemetry replay works as a live file-driven input path for simulator tests.

Compatibility note:
- Live telemetry injection requires simulator builds that export `injectSPortFrame`.
- Confirmed working: `nightly26`.
- Public `1.6.5` does **not** export `injectSPortFrame`.
- Policy for this project: use `nightly26` now; in future, telemetry injection is expected to work with ETHOS `1.7+` (once those builds export `injectSPortFrame`).

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
