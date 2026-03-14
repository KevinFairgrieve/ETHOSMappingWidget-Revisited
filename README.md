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

## Installation

1. Copy the files to your SD card:
RADIO/
├── scripts/
│   └── ethosmaps/          ← all .lua files
├── bitmaps/
│   └── ethosmaps/
│       └── maps/           ← your map tiles go here
└── SOUNDS/
└── ethosmaps/          ← err.wav and inf.wav (optional)
2. Restart your radio completely.
3. Add the widget to any screen. It automatically adapts to the assigned size.

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
