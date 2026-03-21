# ETHOS Mapping Widget – UI Performance Experiments Plan

**Branch:** `performance-experiments`  
**Goal:** Improve UI responsiveness (screen swipe + general ETHOS UI smoothness) while keeping map behavior stable.

---

## 1) Problem Statement

Current behavior with visible widget:
- ETHOS UI stutters heavily
- Screen swipe can drop below ~5 FPS
- Prior attempts (fixed draw-rate, redraw-on-change) gave only minor gains and introduced regressions

Target outcome:
- noticeably smoother widget screen switching
- lower CPU pressure from widget draw/update loop
- maintain correct tile loading and map behavior
- prepare technical baseline for future touch panning

---

## 2) Ground Rules (Strict Process)

1. **One change at a time** (single experiment per step)
2. **Test after every step** (same test scenario each time)
3. **Rollback fast** if behavior regresses
4. **No mixed refactors** during experiments
5. **Document observed effect** before moving to next step

### Testing Environment Rules

- **Functional correctness** (map loads, zoom, provider switch, touch, tile behavior) is verified in the **ETHOS Simulator** after every change.
- **Performance numbers** (PERF WINDOW metrics) are **never recorded from the simulator** — simulator timing does not reflect hardware.
- **All PERF measurements** come exclusively from **real hardware logs**, provided after each step when hardware testing is done.
- Hardware log data is pasted into the Notes Log (section 7) before the step result is considered final.

---

## 3) Measurement Protocol (Before/After Each Step)

Use the same route/screen flow for every run:
1. Open model screen with widget visible
2. Swipe between widget screens repeatedly for ~20–30 seconds
3. Perform map interaction (zoom +/-)
4. Observe map redraw smoothness and UI latency

Record per run:
- Swipe smoothness (subjective score 1–5)
- Visible stutter severity (low/medium/high)
- Any lag spikes or black flashes
- Tile loading correctness (yes/no)
- Regression symptoms (wrong map type, stale tiles, no-map, touch issues)

Additionally (from profiler log every 5 seconds):
- `paintFPS`
- `wakeup_total_ms` (avg/max)
- `paint_total_ms` (avg/max)
- `layout_draw_ms` (avg/max)
- `tile_update_ms` (avg/max)
- `tile_rebuild_count`

---

## 3.1) Profiler Output Format (5s Window)

Profiler logs every 5 seconds in an ASCII table layout under category `PERF`.

Example:
```
PERF | === PERF WINDOW 5.0s ===
PERF | +----------+------------------+------------------+------------------+
PERF | | rate     | fps=6.20         | wakeups=31       | paints=31        |
PERF | | draw     | paintMs=119.35   | layoutMs=112.42  | tileMs=0.00      |
PERF | | misc     | bgMs=3.29        | flushMs=0.13     | eventMs=0.00     |
PERF | | counts   | rebuilds=0       | tileCalls=0      | touches=0        |
PERF | | sched    | invalidates=31   | frame100ms=31    | frame200ms=0     |
PERF | | gc       | gcCalls=0        | -=-              | -=-              |
PERF | +----------+------------------+------------------+------------------+
```

Interpretation guide:
- High `paint_total_ms` / `layout_draw_ms` => draw pipeline bottleneck
- High `tile_update_ms` + many rebuilds => tile/recenter workload bottleneck
- High `wakeup_total_ms` with low paint FPS => scheduler/background pressure

---

## 4) Step-by-Step Experiment Roadmap

## Step 0 — Baseline Profiling (No behavior change)

**Goal:** collect trustworthy reference numbers before optimization.

**Change scope:**
- Enable perf profiling only
- No scheduler/cache/math modifications

**Success criteria:**
- Stable 5s PERF windows appear in debug log
- Baseline metrics captured for comparison against Step A/B/C

---

## Step A — Frame Scheduler + Dirty Invalidate

**Hypothesis:** Unconditional `lcd.invalidate()` in wakeup drives excessive redraw pressure.

**Change scope:**
- Introduce update cadence modes:
  - interactive: ~10–12 FPS
  - idle: ~2–4 FPS
- Call `lcd.invalidate()` only when:
  - state is marked dirty, or
  - frame deadline is reached for active mode

**Do NOT change yet:** tile math, cache behavior, map data flow.

**Success criteria:**
- UI swipe becomes noticeably smoother
- no functional map regressions

---

## Step B — Garbage Collection Strategy

**Hypothesis:** aggressive/full `collectgarbage()` on tile changes causes frame spikes.

**Change scope:**
- Remove immediate full-GC in hot tile path
- Replace with periodic/incremental GC stepping (time-gated)
- Keep memory safety (no unbounded growth)

**Success criteria:**
- fewer visible stutter spikes
- stable memory behavior during prolonged use

---

## Step C — Recenter Hysteresis (GPS Jitter Filter)

**Hypothesis:** micro GPS movement triggers excessive map/tile updates.

**Change scope:**
- recenter only if movement exceeds threshold (pixel or tile-space threshold)
- keep aircraft marker updates responsive

**Success criteria:**
- reduced tile rebuild frequency when stationary/slow drift
- map still follows aircraft correctly in motion

---

## Step D — Heavy Work Scheduling (Optional, after A–C)

**Hypothesis:** expensive operations still cluster in single cycles.

**Change scope:**
- split heavy map housekeeping across cycles
- time-gate non-critical tasks

**Success criteria:**
- no long frame hitches
- no delayed critical updates (position, zoom feedback)

---

## 5) Rollback Criteria (Immediate)

Rollback current step if any of these appears:
- wrong/unchanging map type after switch
- stale tile cache effects
- frequent no-tile fallback on valid datasets
- touch input anomalies
- major visual artifacts/black flashes introduced by new logic

---

## 6) Testing Matrix (Minimum)

Run each step with:
- Provider: Google (native)
- Provider: ESRI (native)
- Provider: OSM (native)
- Google Yaapu fallback active
- Small widget + fullscreen widget

---

## 7) Notes Log (Fill During Execution)

### Baseline
- Date: 2026-03-20
- Build/commit: `89d51b0`
- Observed baseline issues:
  - **Cold entry spike (first swipe from home screen into widget)** causes a multi-second hitch.
  - First measured window during cold entry:
    - `window=7.0s`, `fps=0.29`, `wakeups=120`, `paints=2`
    - `paintMs=2066.0`, `layoutMs=4008.0`, `tileMs=118.0`
    - `rebuilds=1`, `tileCalls=2`, `gcCalls=1`
    - `invalidates=119`, `frame100ms=3`, `frame200ms=1`
  - Warm/steady-state windows after initial tile load:
    - `window=5.0s`, `fps≈5.0–6.2`
    - `paintMs≈113.5–119.4`, `layoutMs≈106.3–112.4`, `tileMs=0.0`
    - `bgMs≈3.0–3.6`, `flushMs≈0.2–0.3`, `eventMs=0.0`
    - `rebuilds=0`, `tileCalls=0`, `gcCalls=0`
    - `frame100ms` often equals paint count in warm windows (frame-time pressure remains visible even without tile rebuilds)

### Step A result
- Change summary:
  - Dirty-invalidate Frame Scheduler aktiv (statt unbedingtem `lcd.invalidate()` in jedem Wakeup).
  - `markDirty()` bei GPS-Update, Blink-Toggle und Zoom-Events.
  - Idle-Cadence über `FRAME_IDLE_INTERVAL`.
- Result:
  - **Warm/steady-state (ohne Tile-Rebuild):**
    - `fps≈5.0–5.6` (meist 5.2–5.6)
    - `paintMs≈119–134`, `layoutMs≈113–127`, `tileMs=0`
    - `rebuilds=0`, `tileCalls=0`, `gcCalls=0`
    - `invalidates≈26–28` pro 5s Fenster
  - **Zoom/Rebuild-Fenster (mit Tile-Last):**
    - `fps≈1.0–2.83`
    - `paintMs≈304–915`, `layoutMs≈298–908`, `tileMs≈119–131`
    - `rebuilds=1–2`, `tileCalls=2–4`, `gcCalls=1–2`
  - **Init/Cold-Ladefenster:** weiterhin sehr langsam (real ~3–4s, im Log nur teilweise abgebildet).
  - Funktional insgesamt gut; vereinzelt visuelle Artefakte beobachtet.
- Keep/revert:
  - **Keep** (Step A bleibt aktiv). Hauptproblem verschiebt sich auf Tile/GC-Spikes bei Rebuild/Zoom, nicht auf den Invalidate-Scheduler.

### Step B result
- Change summary:
  - Alle direkten collectgarbage()-Aufrufe aus Hot-Paths entfernt (drawlib, maplib, resetLib).
  - Periodische GC im zentralen wakeup-Loop (alle 10 Wakeups) implementiert.
  - Keine weiteren Änderungen an Tile- oder Scheduler-Logik.
- Result:
  - **Simulator:** Läuft stabil, keine neuen Bugs.
  - **Hardware:**
    - Coldstart: Initiales Fenster weiterhin langsam (paintMs > 2s, layoutMs > 3s, wie Step A/Baseline).
    - Warm/steady-state (idle, swipe, touch):
      - `fps=5.0–5.4`, `paintMs=120–137`, `layoutMs=114–130`, `tileMs=0`, `gcCalls=2–3` pro 5s Fenster
      - Keine sichtbaren Stutter-Spikes mehr durch GC, keine neuen Artefakte.
    - Zoom/Rebuild: Einzelne Fenster mit niedrigerem FPS (1.0–1.8), paint/layoutMs 400–900ms, tileMs 46–56ms, gcCalls=1–3
    - Touch/Swipe: Responsivität wie Step A, keine neuen Lags.
    - Memory: Kein ungebremstes Wachstum, keine Abstürze.
  - **Fazit:**
    - Unterschied zu Step A gering, aber keine Verschlechterung. GC-Spikes sind weniger ausgeprägt, aber initiale Ladehänger bleiben.
    - Funktionalität und Stabilität voll gegeben.
- Keep/revert:
  - **Keep** (Step B bleibt aktiv). Nächster Engpass: Initiale Ladezeit und Tile-Rebuilds.

### Step C result
- Change summary:
  - Recenter-Hysterese in `mapLib.drawMap(...)` ergänzt:
    - Recenter bei Border-Verletzung nur noch, wenn zusätzlich eine Hysterese-Marge überschritten ist.
    - Zusätzliche Mindestzeit zwischen Recenter-Events (`RECENTER_MIN_INTERVAL`) zur Entkopplung von Mikro-Jitter.
    - Gedrosselte Debug-Logs ergänzt (`Recenter executed` / `Recenter deferred`), um Hysterese-Trigger im `debug.log` nachvollziehbar zu machen.
  - Marker-Update bleibt unverändert responsiv (Position wird weiterhin normal berechnet/gerendert), nur Tile-Recenter wird gefiltert.
- Result:
  - **Simulator:** Hysterese-Trigger im Log sichtbar (`Recenter deferred`), keine neuen Funktionsfehler.
  - **Hardware (dieser Lauf):**
    - Cold/Init-Fenster weiterhin langsam:
      - `fps=0.6`, `paintMs=1403.67`, `layoutMs=2042.5`, `tileMs=54.0`, `rebuilds=1`
    - Warm/steady-state (ohne Rebuild):
      - `fps≈4.8–5.6`, `paintMs≈120–136`, `layoutMs≈114–129`, `tileMs=0`, `rebuilds=0`, `tileCalls=0`
      - `gcCalls≈2–4` pro 5s Fenster
    - Zoom/Rebuild-Fenster:
      - `fps≈1.13–2.6`, `paintMs≈356–859`, `layoutMs≈349–852`, `tileMs≈44–52`
      - `rebuilds=1–2`, `tileCalls=2–4`, `gcCalls=2–3`
  - **Vergleich zu Step B:**
    - Keine klare messbare Verbesserung der warmen Framerate/Latenzen.
    - Rebuild-Spitzen bleiben vorhanden, teilweise leicht niedriger im `tileMs`-Bereich, aber weiterhin deutlich sichtbar.
    - Kein Hinweis auf neue Regressionen.
  - **Hinweis zu notiles:**
    - Auftretende `notiles` in diesem Lauf korrelieren mit fehlender Tile-Abdeckung im Datensatz (kein Step-C-Regressionseffekt).
- Keep/revert:
  - **Keep** (Step C bleibt aktiv): stabil, kein negativer Einfluss, Jitter-Recenter wird sauber gedämpft.

### Step D result
- Change summary:
  - **Step D1 (getestet):** Cache-Housekeeping im Tile-Pfad zeitlich/batch-limitiert entkoppelt.
  - Nach Hardware-Validierung wegen Regression zurückgerollt.
  - **Step D2 (noch offen):** ggf. weitere Aufteilung von Rebuild-Teilaufgaben über mehrere Wakeups.
- Result:
  - **Simulator:** funktional unauffällig.
  - **Hardware:** klare Verschlechterung gegenüber Step C.
    - Warm/steady-state deutlich schlechter:
      - Step C: `fps≈4.8–5.6`, `paintMs≈120–136`, `layoutMs≈114–129`
      - D1: `fps≈4.2–4.6`, `paintMs≈160–175`, `layoutMs≈153–167`
    - Zoom/Rebuild-Fenster ebenfalls schlechter:
      - Step C: `tileMs≈44–52`
      - D1: `tileMs≈60–63`
    - Zusätzlich auffällige Ausreißer im Init/Heavy-Bereich (z. B. sehr hohes `bgMs` im ersten Fenster).
  - **Fazit:** D1 liefert keinen Performance-Gewinn und verschlechtert die Kernmetriken.
- Keep/revert:
  - **Revert** (D1 verworfen, Code zurück auf Step-C-Stand).

---

## 8) Next Action


Proceed from **stable Step-C baseline**:
- Kein D2 auf Basis des verworfenen D1.
- Optional neuer, kleiner D1-Ansatz nur als separater Experiment-Branch/Commit (eine Änderung, sofortiger A/B-Hardwarevergleich).

Related setup doc:
- `Docs/development/tools/EthosSimulatorWorkflow.md`
