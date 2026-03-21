#!/usr/bin/env python3
"""
Generate deterministic telemetry CSV for performance testing.
- 250ms tick rate
- 1 minute duration → 240 rows
- Constant velocity in straight line (lat/lon increasing)
- Same start coordinates as DemoTelemetry.csv
- All non-GPS fields held constant or realistically varied
"""

import csv
from datetime import datetime, timedelta
import math

# Configuration
START_TIME = datetime.strptime("2025-02-09 16:15:40.610", "%Y-%m-%d %H:%M:%S.%f")
TICK_INTERVAL = 0.250  # seconds (250ms)
DURATION_SECONDS = 60
NUM_RECORDS = int(DURATION_SECONDS / TICK_INTERVAL)

# Start coordinates (from DemoTelemetry.csv first row)
START_LAT = 51.442148
START_LON = 11.576354

# Velocity: moving northeast at constant speed
# 20 m/s = 72 km/h (realistic test flight speed)
VELOCITY_MS = 20  # m/s (10x faster for realistic flight)
HEADING_DEG = 45  # northeast

# Helper: convert velocity + heading to lat/lon delta per tick
def get_lat_lon_delta_per_tick(velocity_ms, heading_deg, duration_s):
    """Calculate lat/lon change given velocity, heading, and time."""
    # Convert heading to radians (0=East, π/2=North, π=West, 3π/2=South)
    heading_rad = math.radians(heading_deg)
    
    # Distance traveled in this tick
    distance_m = velocity_ms * duration_s
    
    # Earth radius (meters)
    EARTH_RADIUS_M = 6371000
    
    # Convert distance to degrees
    # At equator: 1 degree ≈ 111,320 meters
    # For more accuracy, use: dlat_deg = distance / EARTH_RADIUS * cos(lat)
    lat_rad = math.radians(START_LAT)
    
    # Δ latitude (northward component)
    dlat = (distance_m * math.cos(heading_rad)) / (EARTH_RADIUS_M)
    
    # Δ longitude (eastward component)  
    dlon = (distance_m * math.sin(heading_rad)) / (EARTH_RADIUS_M * math.cos(lat_rad))
    
    return math.degrees(dlat), math.degrees(dlon)

dlat, dlon = get_lat_lon_delta_per_tick(VELOCITY_MS, HEADING_DEG, TICK_INTERVAL)

print(f"Generating {NUM_RECORDS} records ({NUM_RECORDS * TICK_INTERVAL}s total)")
print(f"  Start: {START_LAT:.6f}, {START_LON:.6f}")
print(f"  Δ per tick: {dlat:.9f}°, {dlon:.9f}°")
print(f"  Velocity: {VELOCITY_MS} m/s, Heading: {HEADING_DEG}°")
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

output_path = "DemoTelemetry_Synthetic_1min_250ms.csv"
with open(output_path, 'w', newline='') as f:
    writer = csv.writer(f)
    writer.writerow(header)
    
    current_time = START_TIME
    lat = START_LAT
    lon = START_LON
    
    for i in range(NUM_RECORDS):
        # Time formatting
        date_str = current_time.strftime("%Y-%m-%d")
        time_str = current_time.strftime("%H:%M:%S.%f")[:-3]  # Keep milliseconds only
        
        # GPS coordinates (updated each tick)
        gps_str = f"{lat:.6f} {lon:.6f}"
        
        # Row: copy all template values from first row of DemoTelemetry
        # Most fields stay constant; we only vary GPS
        row = [
            date_str, time_str,
            "-19", "0", "100", "0", "0", "1", "250",  # 1RSS, 2RSS, RQly, RSNR, ANT, RFMD, TPWR(mW)
            "-18", "100", "11", "100", "50", "100", "24",  # TRSS, TQly, TSNR, TRSP, TFPS, RRSP, TPWR(dBm)
            "-0.04", "0.00", "-0.32", "ANGL", "16.6", "0.3", "202", "97",  # Ptch, Roll, Yaw, FM, RxBt, Curr, Capa, Bat%
            gps_str,  # GPS
            "5.0", "45", "50", "9", "0.0", "45", "1.4",  # GSpd(kmh), Hdg, Alt, Sats, VSpd, Hdg(duplicate), GSpd(m/s)
            "0", "0", "0", "0",  # Rud, Ele, Thr, Ail
            "-148", "-13", "-1024", "-1024", "-1024",  # P1, P2, P3
            "928", "23", "0", "0", "0", "0", "0", "0", "0", "0", "1", "0",  # SL1-SH, LSW
            "-1", "0x0500001800000000",  # filler
            "1494", "1511", "1428", "1505", "1000", "1275", "1000", "1500",  # CH1-CH8
            "1040", "1500", "1500", "1000", "1500", "988", "1500", "1500",  # CH9-CH16
            "1500", "1500", "1500", "1500", "1500", "1500", "1500", "1500",  # CH17-CH24
            "1500", "1500", "1500", "1500", "1500", "1500", "1500", "1500",  # CH25-CH32
            "8.2"  # TxBat(V)
        ]
        
        writer.writerow(row)
        
        # Update for next iteration
        current_time += timedelta(seconds=TICK_INTERVAL)
        lat += dlat
        lon += dlon

print(f"✓ Written {NUM_RECORDS} records to: {output_path}")
print(f"  First row: {START_TIME.strftime('%H:%M:%S.%f')[:-3]} → {START_LAT:.6f}, {START_LON:.6f}")
last_time = START_TIME + timedelta(seconds=TICK_INTERVAL * (NUM_RECORDS - 1))
last_lat = START_LAT + dlat * (NUM_RECORDS - 1)
last_lon = START_LON + dlon * (NUM_RECORDS - 1)
print(f"  Last row:  {last_time.strftime('%H:%M:%S.%f')[:-3]} → {last_lat:.6f}, {last_lon:.6f}")
print(f"  Total distance: ~{VELOCITY_MS * DURATION_SECONDS}m at {HEADING_DEG}° heading")
