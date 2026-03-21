#!/usr/bin/env python3
"""
Generate deterministic 5-minute telemetry CSV for performance testing.
- 250ms tick rate → 1200 records total
- Minute 0-1: Circular path (500m diameter) starting at the requested origin
- Minute 1-5: Random direction changes every 20s, same start coords
- Constant velocity: 20 m/s (72 km/h)
"""

import csv
from datetime import datetime, timedelta
import math
import random

# Configuration
START_TIME = datetime.strptime("2025-02-09 16:15:40.610", "%Y-%m-%d %H:%M:%S.%f")
TICK_INTERVAL = 0.250  # seconds
DURATION_SECONDS = 300  # 5 minutes
NUM_RECORDS = int(DURATION_SECONDS / TICK_INTERVAL)

# Start coordinates (from actual log entry)
START_LAT = 51.442243
START_LON = 11.576507

# Velocity
VELOCITY_MS = 20  # m/s (72 km/h)
CIRCLE_RADIUS_M = 250  # 500m diameter circle

# Time segments
CIRCLE_DURATION_S = 60  # First minute
RANDOM_DURATION_S = 240  # Remaining 4 minutes
DIRECTION_CHANGE_INTERVAL_S = 20  # Change direction every 20s in random phase

# Earth radius
EARTH_RADIUS_M = 6371000

def lat_lon_to_meters(lat_deg, lon_deg):
    """Convert lat/lon to meters from origin."""
    lat_rad = math.radians(lat_deg)
    xm = lon_deg * EARTH_RADIUS_M * math.cos(lat_rad) * (math.pi / 180)
    ym = lat_deg * EARTH_RADIUS_M * (math.pi / 180)
    return xm, ym

def meters_to_lat_lon(xm, ym, origin_lat_deg, origin_lon_deg):
    """Convert meters back to lat/lon."""
    origin_lat_rad = math.radians(origin_lat_deg)
    dlat_deg = ym / EARTH_RADIUS_M * (180 / math.pi)
    dlon_deg = xm / (EARTH_RADIUS_M * math.cos(origin_lat_rad)) * (180 / math.pi)
    return origin_lat_deg + dlat_deg, origin_lon_deg + dlon_deg

def get_circle_position(elapsed_s, radius_m, velocity_ms):
    """Get a continuous circular arc that starts at the origin with a 45° tangent."""
    angular_velocity = velocity_ms / radius_m

    # Choose the circle center so the path starts exactly at the origin and the
    # initial tangent points northeast (45°), matching the requested heading.
    center_xm = -radius_m / math.sqrt(2)
    center_ym = radius_m / math.sqrt(2)
    start_angle_rad = -math.pi / 4
    angle_rad = start_angle_rad + angular_velocity * elapsed_s

    xm = center_xm + radius_m * math.cos(angle_rad)
    ym = center_ym + radius_m * math.sin(angle_rad)

    tangent_east = -velocity_ms * math.sin(angle_rad)
    tangent_north = velocity_ms * math.cos(angle_rad)
    heading_deg = math.degrees(math.atan2(tangent_east, tangent_north)) % 360

    return xm, ym, heading_deg

def get_random_direction_position(elapsed_s, initial_lat, initial_lon, velocity_ms, change_interval_s):
    """Get position following random direction changes (starting from 0,0 offset)."""
    # We work entirely in meters, starting from origin (0,0)
    
    # Determine which direction segment and how far into it
    segment_num = int(elapsed_s / change_interval_s)
    elapsed_in_segment = elapsed_s - (segment_num * change_interval_s)
    
    # Create deterministic but pseudo-random heading for this segment
    random.seed(segment_num)
    heading_deg = random.uniform(0, 360)
    
    # Distance traveled in this segment
    distance = velocity_ms * elapsed_in_segment
    
    heading_rad = math.radians(heading_deg)
    
    # Accumulate all previous segments' distances
    total_xm = 0
    total_ym = 0
    
    for seg in range(segment_num):
        random.seed(seg)
        seg_heading_deg = random.uniform(0, 360)
        seg_heading_rad = math.radians(seg_heading_deg)
        
        seg_distance = velocity_ms * change_interval_s
        seg_xm = seg_distance * math.cos(seg_heading_rad)
        seg_ym = seg_distance * math.sin(seg_heading_rad)
        
        total_xm += seg_xm
        total_ym += seg_ym
    
    # Add current segment progress
    current_xm = distance * math.cos(heading_rad)
    current_ym = distance * math.sin(heading_rad)
    
    final_xm = total_xm + current_xm
    final_ym = total_ym + current_ym
    
    return final_xm, final_ym

print(f"Generating {NUM_RECORDS} records ({DURATION_SECONDS}s = 5min total)")
print(f"  Start: {START_LAT:.6f}, {START_LON:.6f}")
print(f"  Velocity: {VELOCITY_MS} m/s (72 km/h)")
print(f"  Phase 1 (0-60s): Circle with {CIRCLE_RADIUS_M}m radius")
print(f"  Phase 2 (60-300s): Random 20s direction changes")
print()

# Header from DemoTelemetry.csv
header = [
    "Date", "Time", "1RSS(dB)", "2RSS(dB)", "RQly(%)", "RSNR(dB)", "ANT", "RFMD", "TPWR(mW)",
    "TRSS(dB)", "TQly(%)", "TSNR(dB)", "TRSP(%)", "TFPS(Hz)", "RRSP(%)", "TPWR(dBm)",
    "Ptch(rad)", "Roll(rad)", "Yaw(rad)", "FM", "RxBt(V)", "Curr(A)", "Capa(mAh)", "Bat%(%)",
    "GPS", "GSpd(kmh)", "Hdg(°)", "Alt(m)", "Sats", "VSpd(m/s)", "Hdg(°)", "GSpd(m/s)",
    "Rud", "Ele", "Thr", "Ail", "P1", "P2", "P3",
    "SL1", "SL2", "SA", "SB", "SC", "SD", "SE", "SF", "SG", "SH", "LSW",
    "CH1(us)", "CH2(us)", "CH3(us)", "CH4(us)", "CH5(us)", "CH6(us)", "CH7(us)", "CH8(us)",
    "CH9(us)", "CH10(us)", "CH11(us)", "CH12(us)", "CH13(us)", "CH14(us)", "CH15(us)", "CH16(us)",
    "CH17(us)", "CH18(us)", "CH19(us)", "CH20(us)", "CH21(us)", "CH22(us)", "CH23(us)", "CH24(us)",
    "CH25(us)", "CH26(us)", "CH27(us)", "CH28(us)", "CH29(us)", "CH30(us)", "CH31(us)", "CH32(us)",
    "TxBat(V)"
]

output_path = "Synthetic_Logs/DemoTelemetry_Synthetic_5min_pattern_250ms.csv"
with open(output_path, 'w', newline='') as f:
    writer = csv.writer(f)
    writer.writerow(header)
    
    current_time = START_TIME
    
    for i in range(NUM_RECORDS):
        elapsed_s = i * TICK_INTERVAL
        
        # Determine phase and calculate position offset from start
        if elapsed_s < CIRCLE_DURATION_S:
            # Phase 1: Circle
            xm_offset, ym_offset, heading = get_circle_position(elapsed_s, CIRCLE_RADIUS_M, VELOCITY_MS)
        else:
            # Phase 2: Random directions
            elapsed_in_phase2 = elapsed_s - CIRCLE_DURATION_S
            xm_offset, ym_offset = get_random_direction_position(
                elapsed_in_phase2, START_LAT, START_LON, VELOCITY_MS, DIRECTION_CHANGE_INTERVAL_S
            )
            
            # Calculate heading from velocity direction
            segment_num = int(elapsed_in_phase2 / DIRECTION_CHANGE_INTERVAL_S)
            random.seed(segment_num)
            heading = random.uniform(0, 360)
        
        # Convert offset to lat/lon (offset from start position)
        lat, lon = meters_to_lat_lon(xm_offset, ym_offset, START_LAT, START_LON)
        
        # Time formatting
        date_str = current_time.strftime("%Y-%m-%d")
        time_str = current_time.strftime("%H:%M:%S.%f")[:-3]
        
        gps_str = f"{lat:.6f} {lon:.6f}"
        
        # Row
        row = [
            date_str, time_str,
            "-19", "0", "100", "0", "0", "1", "250",
            "-18", "100", "11", "100", "50", "100", "24",
            "-0.04", "0.00", "-0.32", "ANGL", "16.6", "0.3", "202", "97",
            gps_str,
            "72.0", str(int(heading) % 360), "50", "9", "0.0", "45", "20.0",
            "0", "0", "0", "0",
            "-148", "-13", "-1024", "-1024", "-1024",
            "928", "23", "0", "0", "0", "0", "0", "0", "0", "0", "1", "0",
            "-1", "0x0500001800000000",
            "1494", "1511", "1428", "1505", "1000", "1275", "1000", "1500",
            "1040", "1500", "1500", "1000", "1500", "988", "1500", "1500",
            "1500", "1500", "1500", "1500", "1500", "1500", "1500", "1500",
            "1500", "1500", "1500", "1500", "1500", "1500", "1500", "1500",
            "8.2"
        ]
        
        writer.writerow(row)
        current_time += timedelta(seconds=TICK_INTERVAL)

print(f"✓ Written {NUM_RECORDS} records to: {output_path}")

# Calculate some statistics
circle_end_lat, circle_end_lon = meters_to_lat_lon(0, 0, START_LAT, START_LON)  # Back at origin

# Get final position
final_xm_offset, final_ym_offset = get_random_direction_position(RANDOM_DURATION_S, START_LAT, START_LON, VELOCITY_MS, DIRECTION_CHANGE_INTERVAL_S)
final_lat, final_lon = meters_to_lat_lon(final_xm_offset, final_ym_offset, START_LAT, START_LON)

print(f"  Phase 1 end (60s): Back at start → {circle_end_lat:.6f}, {circle_end_lon:.6f}")
print(f"  Phase 2 start (60s): {START_LAT:.6f}, {START_LON:.6f}")
print(f"  Phase 2 end (300s): ~{final_lat:.6f}, ~{final_lon:.6f}")
print(f"  Total duration: {DURATION_SECONDS}s (5 min)")
