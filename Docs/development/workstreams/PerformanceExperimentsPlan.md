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
- Result:
- Keep/revert:

### Step B result
- Change summary:
- Result:
- Keep/revert:

### Step C result
- Change summary:
- Result:
- Keep/revert:

### Step D result
- Change summary:
- Result:
- Keep/revert:

---

## 8) Next Action

Start with **Step 0** (baseline profiler run), capture reference metrics, then proceed to **Step A only**.

Related setup doc:
- `Docs/development/tools/EthosSimulatorWorkflow.md`
