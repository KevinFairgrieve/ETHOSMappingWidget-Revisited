# Flight Trail

The Flight Trail feature draws a yellow line on the map showing the path your aircraft has flown. It uses an intelligent waypoint system that adapts to your flight path — placing more points in turns and fewer on straight segments — to keep the trail accurate while minimizing performance overhead.

## Settings

The trail is configured through two settings in the widget configuration screen.

### Trail Resolution

Controls the minimum distance (in meters) the aircraft must travel before a new trail waypoint *can* be committed. A shorter distance produces a more detailed trail but uses more waypoints; a longer distance conserves waypoints for extended flights.

| Option | Description |
|--------|-------------|
| **Off** | Trail is disabled. No waypoints are recorded. |
| **20 m** | Very high detail — suitable for slow or close-range flights. |
| **50 m** | Good balance between detail and waypoint budget (default). |
| **100 m** | Medium detail — recommended for general flying. |
| **500 m** | Low detail — suitable for long-range or high-speed flights. |
| **1 km** | Minimal detail — best for very long cross-country flights. |

When the trail is set to **Off**, any previously recorded trail data is cleared immediately to free memory.

### Trail Bend Threshold

Controls how much the flight path must bend (in degrees) before a waypoint is actually committed. Even after the resolution distance has been reached, the system will only record a new waypoint if the change in direction exceeds this threshold. This prevents unnecessary waypoints on straight flight segments.

- **Range:** 3° to 15°
- **Default:** 5°

A **lower** value captures more subtle turns, producing a smoother trail at the cost of using waypoints faster. A **higher** value only records sharper turns, stretching the trail over longer distances but potentially cutting corners on gentle curves.

## How It Works

1. **Distance accumulation:** As the aircraft moves, the system continuously measures the distance traveled (via the haversine formula) since the last committed waypoint.

2. **Bend detection:** Once the accumulated distance reaches the configured resolution, the system computes the angle between the last committed flight segment and the pending segment toward the current aircraft position. This is a *geometric segment bend* — it measures the actual visual angle of the path, not the aircraft's heading or course-over-ground, making it robust against wind drift and GPS jitter.

3. **Waypoint commit:** A new waypoint is committed only if the bend angle meets or exceeds the threshold. If the aircraft is still flying straight, the waypoint is deferred and the existing segment simply extends.

4. **Ring buffer:** Trail data is stored in a fixed-size ring buffer holding up to **50 waypoints**. When the buffer is full, the oldest waypoint is overwritten. This guarantees constant memory usage regardless of flight duration.

5. **Dynamic segment:** A live segment is always drawn from the newest waypoint to the aircraft's current position, so the trail visually follows the aircraft in real time even between committed waypoints.

6. **Viewport clipping:** Every trail segment is clipped to the widget viewport before drawing (using the Cohen–Sutherland algorithm). Segments that are entirely off-screen are skipped at near-zero cost, so a long trail with most segments outside the current view has negligible impact on rendering time.

## Recommended Settings

| Flight Style | Resolution | Bend Threshold |
|---|---|---|
| Close-range, slow flying (e.g. training) | 20 m | 3° – 5° |
| General purpose | 50 m | 5° |
| Fast or long-range flights | 100 m – 500 m | 5° – 10° |
| Long cross-country | 500 m – 1 km | 10° – 15° |

## Performance Considerations

The trail system is designed to have minimal impact on frame rate:

- **Bend-based triggering** significantly reduces the number of waypoints recorded during straight flight. Fewer waypoints means fewer line segments to draw per frame.
- **Viewport clipping** ensures that off-screen segments (common when zoomed in or when the trail extends far behind the aircraft) are rejected early and never sent to the display.
- **Ring buffer** with a fixed size of 50 waypoints provides an upper bound on both memory usage and per-frame draw cost. There is no unbounded growth.
- **No per-frame allocations:** The trail update logic reuses existing data structures and does not create temporary objects that would pressure the garbage collector.

In simulator testing, 50 visible trail segments added approximately **0.7 ms** to the layout time (~2.1 ms vs. ~1.5 ms baseline) with no measurable fps drop. When most segments were off-screen (e.g. after a long straight flight), the overhead dropped to approximately **0.4 ms** due to clipping.

On hardware with more constrained resources, the overhead will be proportionally higher, but the same optimizations apply. If you experience performance issues, increase the **Trail Resolution** to reduce the total number of waypoints, or increase the **Bend Threshold** to commit fewer waypoints on moderate turns.

## Clearing the Trail

The trail is automatically cleared when:

- **Trail Resolution** is set to **Off** — all waypoint data is freed immediately.
- A **widget reset** is triggered (via the reset function in the widget menu).

The trail is **not** cleared when changing zoom level or map provider, since the recorded GPS coordinates remain valid across all projection settings.
