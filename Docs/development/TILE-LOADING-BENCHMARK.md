# Tile Loading Performance Benchmark

## Overview

Performance analysis of tile loading in the ETHOS Mapping Widget on an **X20S** (STM32H743 ARM Cortex-M7, 8 MB SDRAM).  
Four test configurations were compared, varying **storage medium** (internal 8 GB vs external SD card) and **tile scheduling strategy** (fixed count-budget vs time-budget).

**Viewport**: 800×399 px — 9×6 tile grid = 54 tiles per full raster (100×100 px PNG).  
**Test scenario**: Repeated zoom-in / zoom-out cycles (no panning), tiles loaded from `GOOGLE/Satellite` provider at zoom level 16–18.  
**Perf windows**: 5 s aggregation intervals. First window after boot and idle windows excluded from averages.

---

## Test Configurations

| Config | Storage | Scheduling | Description |
|--------|---------|------------|-------------|
| **A** | Internal 8 GB | Count-budget (max 2 tiles/wakeup) | Baseline — loads at most 2 tiles per `processQueue()` call |
| **B** | SD card | Count-budget (max 2 tiles/wakeup) | Same code, tiles moved to external SD |
| **C** | Internal 8 GB | Time-budget (150 ms/wakeup) | New method — loads tiles until 150 ms elapsed |
| **D** | SD card | Time-budget (150 ms/wakeup) | New method on external SD |

---

## Results Summary

### Steady-State Tile Loading (zoom cycling)

| Metric | A — Internal / Count | B — SD / Count | C — Internal / Time | D — SD / Time |
|--------|:--------------------:|:--------------:|:-------------------:|:-------------:|
| **FPS** | **2.4** | **2.4** | **1.2** | **1.0** |
| **paintMs (avg)** | 307 ms | 318 ms | 624 ms | 718 ms |
| **Tile I/O min** | 11–14 ms | 12–14 ms | 11–14 ms | 12–13 ms |
| **Tile I/O max** | 32–40 ms | 32–43 ms | 29–32 ms | 30–34 ms |
| **Tiles loaded / 5 s** | ~36 | ~35 | ~34 | ~38 |
| **Tiles / second** | ~7.2 | ~7.0 | ~6.7 | ~7.7 |
| **frame > 200 ms** | 100% | 100% | 100% | 100% |
| **Wakeups / 5 s** | 12 | 12 | 5 | 5 |

### Idle (all tiles cached, no disk I/O)

| Metric | A — Internal | B — SD | C — Internal | D — SD |
|--------|:------------:|:------:|:------------:|:------:|
| **FPS** | 4.2–4.8 | *(not captured)* | 3.4–3.6 | 3.0–4.6 |
| **paintMs** | 152–175 ms | — | 157–218 ms | 155–255 ms |

---

## Key Findings

### 1. `lcd.loadBitmap()` dominates tile load time — not storage I/O

Per-tile load times are **virtually identical** across internal storage and SD card:

- **Minimum**: 11–14 ms on both media
- **Maximum**: 29–43 ms on both media

If raw file I/O were the bottleneck, we would expect the SD card (connected via SDMMC1) to show measurably different times than the internal 8 GB storage. The near-identical values strongly indicate that **PNG decoding inside `lcd.loadBitmap()` is the dominant cost**, not the filesystem read.

Each 100×100 px PNG tile takes approximately **14 ms** to decode + load, with occasional peaks up to ~40 ms (likely GC pressure or filesystem cache misses).

### 2. Time-budget scheduling reduces FPS by 2× without improving throughput

| | Count-budget (A/B) | Time-budget (C/D) |
|---|:---:|:---:|
| FPS during tile loading | **2.4** | **1.0–1.2** |
| Total tiles/second | **~7** | **~7** |

The time-budget method (150 ms) loads **6–10 tiles per wakeup** in one large batch, blocking the paint loop for 400–880 ms per frame. The count-budget method loads **3 tiles per wakeup**, keeping paint times around 300 ms and achieving 2× more frames.

**Net tile throughput is identical** (~7 tiles/sec) because both approaches are bounded by the same `lcd.loadBitmap()` decode rate. The time-budget merely batches more work into fewer, longer frames — making the UI feel less responsive without loading tiles any faster.

### 3. ETHOS wakeup scheduling adapts to paint time

- When `paint()` takes ~300 ms → ETHOS schedules ~12 wakeups/5 s (2.4/s)
- When `paint()` takes ~700 ms → ETHOS schedules ~5 wakeups/5 s (1.0/s)
- When idle (~150 ms paint) → ETHOS schedules ~20+ wakeups/5 s (4.0+/s)

This confirms that ETHOS does not use a fixed timer but instead re-schedules based on how long the previous frame took. Longer frames → fewer callbacks → compounding slowdown effect with the time-budget approach.

### 4. Base rendering cost is ~150 ms per frame

With all tiles cached (no disk I/O), `paint()` takes 150–175 ms to composite a 9×6 tile grid (54 `lcd.drawBitmap()` calls, overlays, trail rendering). This sets the theoretical maximum FPS at approximately **6.0–6.5** for this viewport size.

### 5. Tile I/O spikes on first load

The very first perf window after a cold start shows I/O outliers (210–470 ms) — likely caused by filesystem metadata reads, FAT table traversal, or initial PNG library warm-up. These settle to <40 ms within the first 5 seconds.

---

## Conclusion & Recommendations

1. **The count-budget approach (max 2–3 tiles per wakeup) delivers the best user experience.** It maintains ~2.4 FPS during tile loading — the highest achievable rate under the 300 ms paint-time constraint — while loading the same ~7 tiles/second as the time-budget method.

2. **Storage medium has no measurable impact** on tile loading performance in these benchmarks. The 14 ms per-tile floor is set by `lcd.loadBitmap()` PNG decode, not by storage throughput.

3. **To improve tile loading speed, `lcd.loadBitmap()` would need to be optimized** (e.g., use a lighter image format than PNG, hardware-accelerated decode, or pre-decoded tile cache in RAM). A raw bitmap format or DMA2D-compatible pixel format could bypass the PNG decode entirely.

4. **Potential API improvement**: An asynchronous `lcd.loadBitmapAsync()` that decodes in a background thread or DMA transfer would allow the widget to continue painting while tiles load, potentially doubling effective FPS during tile population.

---

## Raw Perf Windows (Representative Samples)

### Config A — Internal / Count-budget
```
fps=2.4  | paintMs=302  | tileIO min=12 max=38 count=36 | frame200ms=12
fps=2.4  | paintMs=308  | tileIO min=11 max=35 count=36 | frame200ms=12
fps=2.4  | paintMs=306  | tileIO min=12 max=40 count=36 | frame200ms=12
fps=2.4  | paintMs=308  | tileIO min=12 max=34 count=36 | frame200ms=12
fps=2.6  | paintMs=308  | tileIO min=11 max=40 count=39 | frame200ms=13
```

### Config B — SD / Count-budget
```
fps=2.4  | paintMs=324  | tileIO min=14 max=33 count=36 | frame200ms=12
fps=2.4  | paintMs=319  | tileIO min=14 max=32 count=36 | frame200ms=12
fps=2.2  | paintMs=316  | tileIO min=14 max=41 count=33 | frame200ms=11
fps=2.4  | paintMs=320  | tileIO min=14 max=42 count=36 | frame200ms=12
fps=2.4  | paintMs=317  | tileIO min=13 max=41 count=36 | frame200ms=12
```

### Config C — Internal / Time-budget (150 ms)
```
fps=1.0  | paintMs=689  | tileIO min=12 max=32 count=40 | frame200ms=5
fps=0.8  | paintMs=881  | tileIO min=11 max=29 count=36 | frame200ms=4
fps=2.0  | paintMs=345  | tileIO min=13 max=32 count=27 | frame200ms=5
fps=1.0  | paintMs=754  | tileIO min=13 max=30 count=28 | frame200ms=5
fps=1.0  | paintMs=807  | tileIO min=13 max=32 count=40 | frame200ms=5
```

### Config D — SD / Time-budget (150 ms)
```
fps=1.0  | paintMs=710  | tileIO min=12 max=32 count=42 | frame200ms=5
fps=0.8  | paintMs=882  | tileIO min=12 max=30 count=36 | frame200ms=4
fps=1.0  | paintMs=747  | tileIO min=13 max=30 count=43 | frame200ms=5
fps=1.17 | paintMs=581  | tileIO min=12 max=34 count=37 | frame200ms=6
fps=1.0  | paintMs=745  | tileIO min=12 max=33 count=44 | frame200ms=5
```

---

*Benchmark conducted on ETHOS 26.1 nightly, X20RS, 100×100 px PNG satellite tiles (Google provider), 800×480 display.*
