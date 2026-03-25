# MSP Serial Passthrough Guide for ETHOS Lua Widgets

**Beginner-friendly documentation** for sending and receiving MSP messages from an ETHOS Lua application/widget via RC link (FrSky, Crossfire, ELRS etc.)

This guide explains how to send MSP commands (e.g. change VTX channel, configure OSD, switch modes) from your Lua widget on the radio transmitter to the flight controller over the radio link — **without a USB cable**.

## 1. Basic Principle (Very Simple Explanation)

- Your Lua widget runs on the radio (ETHOS).  
- You want to send MSP data (a sequence of bytes) **through the RC link** to the receiver.  
- The receiver forwards the data **transparently** to the flight controller’s UART (this is called **Serial Passthrough** or **MSP over Telemetry**).  
- The flight controller can send answers back → they come back to your widget via telemetry.  

**You do NOT need to write any code for the receiver** — modern receivers and RF modules handle everything automatically when you use the correct Lua telemetry functions.

## 2. How to Send and Receive Serial Data from Lua

ETHOS gives you ready-made functions in the Lua API (see official ETHOS Lua API Reference Manual).

### Sending Data
Prepare your MSP packet as a Lua table of bytes and push it with the system-specific function.

**General pattern (copy-paste ready):**
```lua
-- Example: MSP packet (you will use a small helper function later)
local mspPacket = {0xEE, 0xEA, 0xFF, 0x01, ...}  -- your MSP command as bytes

-- Send it (function depends on your RC system – see table below)
local success = telemetryPushFunction(header, mspPacket)
```

### Receiving Answers
Register a telemetry listener that catches the responses from the flight controller.

```lua
local function myTelemetryHandler(frameType, data)
    if frameType == MSP_RESPONSE_HEADER then
        -- process the answer from the FC here
    end
end

system.registerTelemetry(myTelemetryHandler)  -- or sportTelemetryPop / crossfireTelemetryPop
```

## 3. Supported RC Systems and Push Functions

| RC System                  | Lua Push Function                              | Max. Payload Size per Message | Notes |
|----------------------------|------------------------------------------------|-------------------------------|-------|
| FrSky SmartPort / F.Port / FBUS | `sportTelemetryPush()` or `system.sportTelemetryPush()` | ~8 bytes per frame | Larger MSP packets are automatically split into multiple frames |
| CRSF via Crossfire         | `crossfireTelemetryPush()`                     | up to 64 bytes                | Very efficient |
| CRSF via ELRS              | `crossfireTelemetryPush()`                     | up to 64 bytes                | Same as Crossfire |
| Ghost (ImmersionRC)        | `ghostTelemetryPush()`                         | Large frames                  | Similar to CRSF |
| mLRS                       | `crossfireTelemetryPush()`                     | up to 64 bytes                | CRSF compatible |

**Pro-Tipp für Anfänger:**  
Schau dir die **RotorFlight ETHOS Lua Suite** auf GitHub an (`rotorflight/rotorflight-lua-ethos`). Dort gibt es eine fertige `msp.lua`-Datei, die du fast 1:1 übernehmen kannst.

## 4. Differences Between the Systems (Data Length)

- **FrSky systems**: Small packets → MSP messages are split automatically. Reliable but a bit slower.  
- **CRSF systems (Crossfire + ELRS)**: Big packets → Usually a whole MSP message fits in **one** frame → faster and cleaner.

## 5. How to Implement It Yourself (Step-by-Step for Beginners)

1. Download the latest **ETHOS Lua API Reference Manual**.  
2. Look at open-source examples (RotorFlight Lua or Yaapu Telemetry).  
3. Create a small helper file `msplib.lua` with functions like `mspSend(command, payload)`.  
4. Add the feature **as an optional setting** in your widget (just like the Debug Logger we are building).  
5. Test with simple commands first (e.g. request FC version).

The whole MSP feature stays **completely optional** and can be turned off in the settings — nothing will break.
