# EthosMappingWidget

**Scalable Mapping Widget for Ethos OS**

A modern, fully scalable version of the popular Yaapu Mapping Widget for FrSky Ethos.  
It displays your real-time GPS position on a supported map type of your choice and works perfectly on **any** widget size — from Fullscreen down to very small custom layouts.

## Features

- Real-time moving map with satellite imagery
- Dynamic zoom levels (manual via touch or buttons)
- UAV position marker with heading
- Home position marker and Home Arrow
- Scale bar with distance indication
- Trail history
- Visual Zoom Buttons (+ / -) on the right edge
- Works in Fullscreen, Split-Screen and all custom widget sizes
- Optimized tile loading and performance

![As Full Screen Widget](images/screenshots/screenshot-2026-03-15-39603.jpg)

![Multi Instance Possible](images/screenshots/screenshot-2026-03-15-39795.jpg)

![Tiny Widget with others](images/screenshots/screenshot-2026-03-15-40068.jpg)

## Installation
1. Download the Repository to your PC
2. Copy the "scripts" and "bitmaps" folders to your SD card or Radio storage (the folder structure should look like this): 
```
RADIO/ or SD/
├── scripts/
│   └── ethosmaps/          ← all .lua files
|       └── audio/
|       └── lib/
|       └── main.lua
└── bitmaps/
    └── ethosmaps/
        └── maps/           ← your map tiles go here
        └── bitmaps/        
```
3. Restart your radio completely.
4. Add the widget to any screen. It automatically adapts to the assigned size.
NOTE: Script and Map Tiles must be on the same drive (Radio or SD) as all your other Scripts. 

## Usage

- Touch the right edge of the widget to zoom in/out
- The map centers automatically on the current UAV position
- The Home Arrow shows the direction and distance to home
- The Scale Bar shows the current map scale
- Basic Telemetry widgets at the Bottom show GroundSpeed, Heading, DistanceToHome and TravelDistance
- Customizable widgets (up to 4) at the top including one specifically for LQ or RSSI and Transmitter Voltage

## Custom Enhancements & Modifications

This version includes extensive custom improvements:
- Full dynamic scaling for any widget size (including Tiny and Ultra-Tiny modes)
- Smart element hiding (Top/Bottom bars, telemetry values, overlays) when space is limited
- Improved Scale Bar visibility and background
- Refined "Home Not Set" warning with dynamic box sizing
- Better performance and reduced tile loading in small widgets

## Credits

- Original concept and base code: Yaapu (Alessandro Apostoli)
- Heavy modifications and scalability enhancements: b14ckyy
