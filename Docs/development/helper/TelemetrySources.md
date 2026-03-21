# ETHOS Telemetry Sources – Overview & Widget Usage

**Last updated:** March 2026  
**Widget:** ETHOS Mapping Widget

### Introduction

ETHOS normalizes telemetry from any radio system into standard sensors.  
The widget uses mostly these standardized sources.

**Important exception:**  
**Link Quality (LQ)** is **not** a standard sensor and must be selected manually.

### Sensor Overview

| Sensor Name                  | Standard ETHOS Sensor? | Used in Mapping Widget? | Exact Lua Call                                                                 | Notes |
|-----------------------------|------------------------|--------------------------|--------------------------------------------------------------------------------|-------|
| **GPS Latitude**            | Yes                    | Yes (hard-coded)         | `system.getSource({name="GPS", options=OPTION_LATITUDE}):value()`              | Always active |
| **GPS Longitude**           | Yes                    | Yes (hard-coded)         | `system.getSource({name="GPS", options=OPTION_LONGITUDE}):value()`             | Always active |
| **Ground Speed**            | Yes                    | Yes                      | `system.registerSource({ key="YM_GSPD", ... })` → `system.getSource("YM_GSPD"):value()` | Widget-exported source |
| **Course Over Ground (COG)**| Yes                    | Yes                      | `system.registerSource({ key="YM_COG", ... })` → `system.getSource("YM_COG"):value()` | Widget-exported source |
| **RSSI**                    | Yes                    | Yes                      | `utils.getRSSI()` or `system.getSource("RSSI"):value()`                        | Always active |
| **Link Quality (LQ)**       | **No**                 | Yes                      | `mapStatus.conf.linkQualitySource` (selected via settings form)                | Must be selected manually |
| **Home Distance**           | No                     | Yes                      | `system.registerSource({ key="YM_HOME", ... })` → `system.getSource("YM_HOME"):value()` | Calculated by widget |
| **Altitude (Baro)**         | Yes                    | No                       | `system.getSource("Alt"):value()`                                              | Only via User Sensor 1/2/3 |
| **Vertical Speed (Vario)**  | Yes                    | No                       | `system.getSource("Vario"):value()`                                            | Only via User Sensor 1/2/3 |
| **Battery Voltage**         | Yes                    | No                       | `system.getSource("Cels"):value()` or `system.getSource("Voltage"):value()`    | Only via User Sensor 1/2/3 |
| **Current**                 | Yes                    | No                       | `system.getSource("Curr"):value()`                                             | Only via User Sensor 1/2/3 |
| **Capacity / Fuel**         | Yes                    | No                       | `system.getSource("Fuel"):value()` or `system.getSource("Capacity"):value()`   | Only via User Sensor 1/2/3 |
| **Airspeed**                | Yes (some systems)     | No                       | `system.getSource("ASpd"):value()`                                             | Only via User Sensor 1/2/3 |
| **TX Voltage**              | Yes                    | Yes (Top Bar)            | `system.getSource({category=CATEGORY_SYSTEM, member=MAIN_VOLTAGE}):value()`    | Always shown in top bar |
| **Roll / Pitch / Yaw**      | Partial (CRSF)         | No                       | Not used                                                                       | Not used yet |

### Key Takeaways

- The widget is highly compatible because it relies on **ETHOS-standardized sensors**.
- Only **GPS**, **RSSI**, and **TX Voltage** are hard-coded.
- **YM_HOME**, **YM_GSPD**, and **YM_COG** are custom widget-exported telemetry sources registered at runtime.
- **Link Quality** is the only sensor that must be manually selected.
- **User Sensor 1/2/3** are custom sensors that can be manually selected for additional telemetry data.
