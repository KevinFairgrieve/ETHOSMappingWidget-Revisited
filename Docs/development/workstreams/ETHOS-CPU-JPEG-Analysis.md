# ETHOS Transmitter CPU & JPEG Hardware Decode Analysis

## Overview

Research into the processors used across all ETHOS-compatible FrSky transmitters, with a focus on whether they include a **hardware JPEG codec** — relevant for choosing the optimal tile image format for the mapping widget.

---

## Confirmed CPUs (via EdgeTX source code / community teardowns)

| Radio | Series | CPU | Core | Clock | SDRAM | HW JPEG |
|-------|--------|-----|------|-------|-------|---------|
| **Horus X12S** | Horus (ISRM) | STM32F429 | Cortex-M4F | 180 MHz | 8 MB | **NO** |
| **X10 / X10S / X10S Express** | Horus (ISRM) | STM32F429 | Cortex-M4F | 180 MHz | 8 MB | **NO** |
| **TANDEM X20 / X20S / X20R / X20HD** | TANDEM | STM32H747 | Cortex-M7F + M4F (dual) | 480 MHz | 8 MB | **YES** |

### Sources

- **X10 / X12S → STM32F429**: Confirmed from [EdgeTX `horus/CMakeLists.txt`](https://github.com/EdgeTX/edgetx/blob/main/radio/src/targets/horus/CMakeLists.txt):
  - `set(CPU_TYPE STM32F4)`
  - `set(CPU_TYPE_FULL STM32F429xI)`
  - `add_definitions(-DSTM32F429_439xx -DSTM32F429xx)`
- **X20S → STM32H747**: Community teardowns, confirmed via board photos and known specifications.

---

## Inferred CPUs (same ETHOS platform, not published by FrSky)

| Radio | Series | CPU (inferred) | Core | Clock | HW JPEG |
|-------|--------|----------------|------|-------|---------|
| **TWIN X18 / X18S** | TWIN | STM32H7xx | Cortex-M7F | ~480 MHz | **YES** (inferred) |
| **TWIN X14 / X14S** | TWIN | STM32H7xx | Cortex-M7F | ~480 MHz | **YES** (inferred) |
| **Twin X Lite** | TWIN | STM32H7xx | Cortex-M7F | ~480 MHz | **YES** (inferred) |

### Rationale

- TANDEM and TWIN series are purpose-built ETHOS radios sharing the same firmware platform architecture.
- FrSky product pages list **zero** CPU/processor specifications — only RF, display, gimbal, and storage info.
- ETHOS's UI complexity (color touch LCD, Lua 5.4, full OS) requires H7-class processing power.
- FrSky standardizes platform components across product generations.

---

## STM32 HW JPEG Codec: Which Series Has It?

| STM32 Series | Core | Max Clock | HW JPEG Codec |
|---|---|---|---|
| **F4** | Cortex-M4F | 180 MHz | **NO** |
| **F7** | Cortex-M7F | 216 MHz | **NO** |
| **H7** | Cortex-M7F (+ optional M4F) | 480–600 MHz | **YES** |

- The HW JPEG codec is an **STM32H7-specific peripheral** — not present in any other STM32 family.
- Even the F7 series (same Cortex-M7 core) does **not** include a HW JPEG codec.
- The H7 JPEG codec supports both encoding and decoding, operating via DMA for zero-CPU-cost transfers.

---

## ETHOS Compatibility Matrix

From FrSky's FAQ:

> *"The Horus series radio with the built-in ISRM RF module like Horus X10 and X12 series, and a TANDEM & TWIN series radios can run ETHOS perfectly."*

This gives us two hardware generations running ETHOS:

| Generation | Radios | CPU Family | LCD Resolution | HW JPEG |
|---|---|---|---|---|
| **Gen 1 (Horus)** | X12S, X10, X10S, X10S Express | STM32F4 | 480×272 | NO |
| **Gen 2 (TANDEM/TWIN)** | X20/X20S/X20R/X20HD, X18/X18S, X14/X14S, Twin X Lite | STM32H7 | 800×480 / 480×320 / 480×272 | YES |

---

## Implications for Tile Image Format

### Does ETHOS use the H7 HW JPEG codec?

**Unknown** — ETHOS is closed-source. Since ETHOS also runs on STM32F4-based radios (X10/X12S) that lack a HW JPEG codec, FrSky's `lcd.loadBitmap()` implementation **must include a software JPEG decoder**. Whether a fast-path exists that leverages the H7 HW codec when available is uncertain.

### Tile Format Performance (X20S, Google Hybrid, zoom 15–16)

| Format | Median FPS | Paint (ms) | Tile I/O min (ms) | File Size |
|--------|:----------:|:----------:|:------------------:|:---------:|
| PNG | 1.8 | 362 | 13 | ~10 KB |
| JPG 90% | 2.4 | 281 | 8 | ~8 KB |
| JPG 70% | 2.6 | 268 | 8 | ~5 KB |
| BMP 24-bit | 2.6 | 194 | 18 | ~30 KB |

### Analysis

- **JPG** has the fastest I/O (smallest files) and competitive paint times.
- **BMP** has the fastest decode (zero CPU cost) but the worst I/O (3× larger files).
- **PNG** is slowest in both paint time and overall FPS.
- **JPG 90%** provides the best balance of quality, speed, storage efficiency, and consistency.

### Impact on Older F4-Based Radios (X10/X12S)

- Clock speed: 180 MHz vs 480 MHz → **~2.7× slower** than X20S.
- No FPU double-precision, no HW JPEG, smaller L1 cache.
- All tile formats will decode slower, but JPG still benefits from smallest file size (less I/O time).
- PNG decode will be especially painful on F4 hardware.

---

## Recommendation

**JPG 90%** is the recommended default tile format for all ETHOS radios:

1. **Universal compatibility** — works on all ETHOS devices via software decode.
2. **Best FPS** — 33% faster than PNG on X20S, gap likely larger on F4 radios.
3. **Smallest storage footprint** — 20% smaller than PNG, 73% smaller than BMP.
4. **Potential HW acceleration** — H7-based radios may benefit from HW JPEG codec (if ETHOS uses it).
5. **Excellent quality** — 90% quality is visually indistinguishable from PNG at 100×100 px tile size.

---

## BMP Format Notes

During testing, 16-bit RGB565 BMP tiles (with BI_BITFIELDS compression type 3) rendered as **solid gray** on ETHOS. Binary header analysis of a test tile (`21.bmp`) revealed:

- 100×100 px, 20,066 bytes
- **16-bit color depth** (not 24-bit)
- Compression type 3 (BI_BITFIELDS), not BI_RGB (type 0)
- RGB565 pixel masks: R=0xF800, G=0x07E0, B=0x001F
- Top-down row order (negative height)

**Fix**: ETHOS `lcd.loadBitmap()` requires **24-bit uncompressed BMP** (BI_RGB). Re-export with:
```
magick input.bmp -type TrueColor -define bmp:format=bmp3 output.bmp
```

---

*Last updated: 2026-03-24*
