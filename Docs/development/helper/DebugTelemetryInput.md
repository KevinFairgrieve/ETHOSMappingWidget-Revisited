# Debug Telemetry Input — External Sensor Sources

## Purpose

The Mapping Widget can read GPS position, heading and speed from
**user-assigned ETHOS sources** instead of the hardcoded GPS sensor.
This enables testing with virtual/replayed telemetry data without a live
receiver connection.

The feature is a **developer/debug tool** — it is only visible when
debug logging is enabled.

## Settings Location

Widget Settings → **Debug & Developer Tools** section (bottom of form):

| Setting                     | Type         | Visible when                | Description |
|----------------------------|--------------|-----------------------------|-------------|
| **Telemetry source**        | Choice       | Debug = On                  | `ETHOS` (default) or `Sensors` |
| **GPS Lat source**          | Source field  | Debug = On, Mode = Sensors  | Latitude source (required) |
| **GPS Lon source**          | Source field  | Debug = On, Mode = Sensors  | Longitude source (required) |
| **Heading source (optional)** | Source field | Debug = On, Mode = Sensors  | Heading/yaw source — overrides calculated COG |
| **Speed source (optional)** | Source field  | Debug = On, Mode = Sensors  | Ground speed source — overrides calculated speed |

## Modes

### ETHOS (default)

Standard operation.  GPS position is read from the hardcoded ETHOS GPS source
(`system.getSource({name="GPS", options=OPTION_LATITUDE/LONGITUDE})`).
Speed and heading are calculated internally from GPS position deltas.

### Sensors

GPS position is read from the two user-assigned source fields.
The optional heading and speed sources allow overriding the internal
calculations:

| Optional source | If assigned | If left empty |
|----------------|-------------|---------------|
| **Heading**     | Value written to `telemetry.yaw` — used for map arrow and compass. Internal COG calculation is skipped. | COG is calculated from GPS movement (default behavior). |
| **Speed**       | Value written to `telemetry.groundSpeed` — used for speed display and tile prefetch. Internal speed calculation is skipped. | Speed is calculated from GPS position deltas (default behavior). |

## Expected Input Units

The widget works internally in **SI base units**.  Any source assigned in
Sensors mode must deliver values in these units:

| Input            | Expected unit | Notes |
|-----------------|---------------|-------|
| **GPS Latitude**  | Decimal degrees | e.g. `48.137154` |
| **GPS Longitude** | Decimal degrees | e.g. `11.576124` |
| **Heading**       | Degrees (0–360) | 0 = North, 90 = East, 180 = South, 270 = West |
| **Speed**         | **m/s** (metres per second) | The widget applies the user's display-unit multiplier (m/s, km/h, mph, kn) for rendering. A source delivering km/h will show values ~3.6× too high. |

> **Important:** ETHOS standard sensors deliver speed in m/s.
> Third-party tools or replay widgets may deliver speed in different units
> (e.g. km/h).  Make sure the source outputs m/s, or convert before
> registering the source in ETHOS.

## Recommended Tool: ETHOS-Telemetry-Replay

The **ETHOS-Telemetry-Replay** widget
([github.com/b14ckyy/ETHOS-Telemetry-Replay](https://github.com/b14ckyy/ETHOS-Telemetry-Replay))
is the recommended companion for testing with this feature.

It replays CSV telemetry logs as virtual ETHOS Lua sources that can be
assigned directly in the Mapping Widget's Sensors mode:

| Replay source name | Assign to              |
|--------------------|------------------------|
| `ReplayLat`        | GPS Lat source         |
| `ReplayLon`        | GPS Lon source         |
| `ReplayCOG`        | Heading source         |
| `ReplayGSpd`       | Speed source           |

### Quick setup

1. Install and configure the **ETHOS-Telemetry-Replay** widget on the same
   model.
2. Load a CSV telemetry log in the Replay widget and start playback.
3. In the Mapping Widget settings:
   - Set **Debug** → On
   - Set **Telemetry source** → Sensors
   - Assign `ReplayLat` / `ReplayLon` to the GPS fields
   - Optionally assign `ReplayCOG` / `ReplayGSpd`
4. The map will follow the replayed flight path.

> **Note:** As of March 2026, the Replay widget outputs `ReplayGSpd` in km/h.
> The Mapping Widget expects m/s.  Until the Replay widget supports
> configurable output units, the displayed speed will be ~3.6× too high when
> using the external speed source.  Heading (`ReplayCOG`) works correctly
> as both use degrees.

## Implementation Details

- Config keys: `telemetrySourceMode`, `sensorGpsLat`, `sensorGpsLon`,
  `sensorHeading`, `sensorSpeed`
- Sensor values are read in `bgtasks()` every wakeup cycle
- Values are persisted via `storage.read()` / `storage.write()`
- The heading fallback chain throughout the codebase is
  `telemetry.yaw or telemetry.cog` — the external heading source writes to
  `yaw`, which takes priority over the internally calculated `cog`
