--
-- msp.lua — MSP transport and waypoint download library
--
-- Communicates with an INAV flight controller over SmartPort or CRSF
-- telemetry passthrough to download stored waypoint missions.
--
-- Protocol layers:
--   SmartPort: [ETHOS Lua] → sport sensor → [SmartPort MSP Transport]
--              → [FrSky Rx] → [FC UART] → [INAV MSP Handler]
--   CRSF:      [ETHOS Lua] → crsf sensor → [CRSF MSP Passthrough]
--              → [ELRS/TBS Rx] → [FC UART] → [INAV MSP Handler]
--
-- Supports MSPv1 (commands < 256) and MSPv2-over-V1 encapsulation
-- (cmd=0xFF wrapper) for future 16-bit command IDs.
--
-- Transport auto-detection: tries SmartPort first, then CRSF.
-- CRSF support is UNTESTED — needs verification on ELRS/TBS hardware.
--
-- Usage from widget:
--   libs.msp.open()      — acquire sensor + auto-detect transport
--   libs.msp.poll()      — drive state machine (call in wakeup)
--   libs.msp.close()     — release sensor (call in close)
--   libs.msp.getState()  — read current state + wp data
--

local msp = {}

-- ============================================================================
-- Injected shared state (set by init)
-- ============================================================================
local status = nil
local libs   = nil

-- ============================================================================
-- Bitwise helpers  (ETHOS Lua 5.4 — no bit32)
-- ============================================================================
local function band(a, b)   return a & b end
local function bor(a, b)    return a | b end
local function bxor(a, b)   return a ~ b end
local function lshift(a, n) return (a << n) & 0xFFFFFFFF end
local function rshift(a, n) return (a & 0xFFFFFFFF) >> n end
local function btest(a, b)  return (a & b) ~= 0 end
local fmt   = string.format
local char  = string.char
local clock = os.clock

-- ============================================================================
-- CRC8 DVB-S2  (for MSPv2)
-- ============================================================================
local function crc8_dvb_s2(crc, byte)
    crc = bxor(crc, byte)
    for _ = 1, 8 do
        if btest(crc, 0x80) then
            crc = bxor(lshift(band(crc, 0xFF), 1), 0xD5)
        else
            crc = lshift(band(crc, 0xFF), 1)
        end
        crc = band(crc, 0xFF)
    end
    return crc
end

-- ============================================================================
-- MSP command IDs
-- ============================================================================
local MSP_V2_FRAME_ID = 255     -- MSPv1 cmd for V2-over-V1 encapsulation
local MSP_FC_VARIANT  = 2       -- 4-char FC identifier ("INAV")
local MSP_STATUS      = 101     -- cycleTime + i2cErr + sensors + flightModeFlags + profile
local MSP_WP_GETINFO  = 20      -- reserved(1)+maxWP(1)+valid(1)+count(1)
local MSP_WP          = 118     -- get single WP by index
local MSP_NAV_STATUS  = 121     -- navMode(1)+navState(1)+activeWpAction(1)+activeWpNumber(1)+navError(1)+targetHeading(2)

-- Waypoint action names (INAV)
local WP_ACTION_NAMES = {
    [1] = "WAYPOINT",
    [2] = "POSHOLD_UNLIM",
    [3] = "POSHOLD_TIME",
    [4] = "RTH",
    [5] = "SET_POI",
    [6] = "JUMP",
    [7] = "SET_HEAD",
    [8] = "LAND",
}

-- ============================================================================
-- SmartPort transport constants
-- ============================================================================
local LOCAL_SENSOR_ID  = 0x0D
local REQUEST_FRAME_ID = 0x30
local REPLY_FRAME_ID   = 0x32
local SP_REMOTE_ID     = 0x1B
local FP_REMOTE_ID     = 0x00

-- MSP-over-SmartPort framing
local MSP_VERSION_BITS = lshift(1, 5)   -- V1 in status byte bits 5-6
local MSP_STARTFLAG    = lshift(1, 4)

-- ============================================================================
-- CRSF transport constants  (UNTESTED — needs hardware verification)
-- ============================================================================
local CRSF_FRAMETYPE_MSP_REQ  = 0x7A  -- MSP request  (Radio → FC via Rx)
local CRSF_FRAMETYPE_MSP_RESP = 0x7B  -- MSP response (FC → Radio via Rx)
local CRSF_ADDRESS_FC         = 0xC8  -- Flight Controller
local CRSF_ADDRESS_RADIO      = 0xEA  -- Radio Transmitter

-- ============================================================================
-- Transport abstraction
-- ============================================================================
local TRANSPORT_NONE  = 0
local TRANSPORT_SPORT = 1
local TRANSPORT_CRSF  = 2

-- Max bytes per transport chunk (status byte + MSP body):
--   SmartPort: 6 (2 dataId + 4 value, all repurposed as MSP chunk)
--   CRSF:     58 (64 max frame - sync - framelen - type - dest - orig - CRC)
--             → 1 status byte + up to 57 MSP body bytes per CRSF frame
local SPORT_FRAME_PAYLOAD = 6
local CRSF_FRAME_PAYLOAD  = 58

-- ============================================================================
-- Timing
-- ============================================================================
local POST_REPLY_DELAY = 0.02     -- seconds after reply before next request
local REQUEST_TIMEOUT  = 1.00     -- seconds before retry
local CONNECT_TIMEOUT  = 3.00     -- seconds without reply → disconnected
local MAX_RETRIES      = 10
local FC_DETECT_TIMEOUT = 10.0    -- seconds to wait for FC before giving up
local RETRY_DELAY      = 5.0     -- seconds to wait before auto-retry after ERROR
local ARM_POLL_INTERVAL = 5.0    -- seconds between arming state queries
local NAV_STATUS_POLL_INTERVAL = 2.0  -- seconds between MSP_NAV_STATUS queries

-- ============================================================================
-- State machine constants
-- ============================================================================
local STATE_OFF         = 0  -- MSP disabled / not started
local STATE_CONNECTING  = 1  -- Identifying FC (MSP_FC_VARIANT)
local STATE_GET_WP_INFO = 2  -- Requesting waypoint count
local STATE_DOWNLOADING = 3  -- Downloading individual waypoints
local STATE_DONE        = 4  -- Download complete
local STATE_ERROR       = 5  -- Unrecoverable error

-- Expose state constants for external code
msp.STATE_OFF         = STATE_OFF
msp.STATE_CONNECTING  = STATE_CONNECTING
msp.STATE_GET_WP_INFO = STATE_GET_WP_INFO
msp.STATE_DOWNLOADING = STATE_DOWNLOADING
msp.STATE_DONE        = STATE_DONE
msp.STATE_ERROR       = STATE_ERROR

msp.TRANSPORT_NONE  = TRANSPORT_NONE
msp.TRANSPORT_SPORT = TRANSPORT_SPORT
msp.TRANSPORT_CRSF  = TRANSPORT_CRSF

-- ============================================================================
-- Module-level state
-- ============================================================================

-- ETHOS sensor handle
local sensor = nil

-- Transport state (set during open(), preserved across resetState())
local transportType    = TRANSPORT_NONE
local maxFramePayload  = SPORT_FRAME_PAYLOAD
local rawSend          = nil   -- function(chunk) -> bool
local rawPoll          = nil   -- function() -> chunk_table or nil

-- MSP transport state
local mspSeq       = 0
local mspRemoteSeq = 0
local mspTxBuf     = {}
local mspTxIdx     = 1
local mspTxCRC     = 0
local mspRxBuf     = {}
local mspRxError   = false
local mspRxSize    = 0
local mspRxCRC     = 0
local mspRxReq     = 0
local mspStarted   = false
local mspLastReq   = 0
local mspRealCmd   = 0   -- actual command (for V2 unwrapping)

-- Duplicate-frame filter
local prevSensorId, prevFrameId, prevDataId, prevValue

-- Application state
local state        = STATE_OFF
local fcVariant    = nil
local connected    = false
local currentCmd   = nil
local lastReqTime  = 0
local lastRspTime  = 0
local retries      = 0

-- Waypoint data
local wpMaxCount   = 0       -- max WPs the FC supports
local wpCount      = 0       -- WPs in current mission
local wpValid      = false   -- mission validity flag
local wpNextIdx    = 1       -- next WP index to request
local wpList       = {}      -- downloaded waypoints { idx, action, actionName, lat, lon, alt, p1, p2, p3, flags }
local missions     = {}      -- parsed missions (list of wpList sub-tables, split at flag=0xA5)
local startTime    = 0       -- os.clock() when open() was called
local errorTime    = 0       -- os.clock() when ERROR state was entered

-- Arming state
local isArmed        = false   -- true once FC reports armed
local lastArmPollTime = 0      -- os.clock() of last MSP_STATUS request
local armingOnly     = false   -- true = skip WP download, only poll arming state

-- Nav status (MSP_NAV_STATUS, polled after armed)
local navMode          = 0     -- navSystemStatus_Mode_e: 0=NONE 1=HOLD 2=RTH 3=NAV 15=EMERG
local navState         = 0     -- navSystemStatus_State_e
local activeWpNumber   = 0     -- FC's current WP index (1-based)
local navError         = 0     -- navSystemStatus_Error_e
local lastNavPollTime  = 0     -- os.clock() of last MSP_NAV_STATUS request

-- ============================================================================
-- Debug logging helper (uses widget debug log if available)
-- ============================================================================
local function log(tag, msg)
    if status and status.debugEnabled and libs and libs.utils then
        libs.utils.logDebug(tag, msg, true)
    end
end

-- ============================================================================
-- SmartPort send / receive
-- ============================================================================

local function sportSend(payload)
    if not sensor then return false end
    local dataId = payload[1] + lshift(payload[2], 8)
    local value  = 0
    for i = 3, #payload do
        value = value + lshift(payload[i], (i - 3) * 8)
    end
    return sensor:pushFrame({
        physId = LOCAL_SENSOR_ID,
        primId = REQUEST_FRAME_ID,
        appId  = dataId,
        value  = value,
    })
end

local function sportPoll()
    if not sensor then return nil end
    while true do
        local frame = sensor:popFrame()
        if not frame then return nil end
        local sId = frame:physId()
        local fId = frame:primId()
        local dId = frame:appId()
        local val = frame:value()
        -- Duplicate-frame filter
        if sId == prevSensorId and fId == prevFrameId
           and dId == prevDataId and val == prevValue then
            -- skip duplicate
        else
            prevSensorId = sId
            prevFrameId  = fId
            prevDataId   = dId
            prevValue    = val
            if (sId == SP_REMOTE_ID or sId == FP_REMOTE_ID)
               and fId == REPLY_FRAME_ID then
                return {
                    band(dId, 0xFF),
                    band(rshift(dId, 8), 0xFF),
                    band(val, 0xFF),
                    band(rshift(val, 8), 0xFF),
                    band(rshift(val, 16), 0xFF),
                    band(rshift(val, 24), 0xFF),
                }
            end
        end
    end
end

-- ============================================================================
-- CRSF send / receive   (UNTESTED — needs hardware verification)
-- ============================================================================

--- Send an MSP chunk as a CRSF frame (type 0x7A).
--- Wraps the chunk with destination/origin address bytes.
--- NOTE: ETHOS CRSF sensor API field names may differ — verify on hardware.
local function crsfSend(chunk)
    if not sensor then return false end
    local payload = { CRSF_ADDRESS_FC, CRSF_ADDRESS_RADIO }
    for i = 1, #chunk do
        payload[i + 2] = chunk[i]
    end
    return sensor:pushFrame({
        frameType = CRSF_FRAMETYPE_MSP_REQ,
        data      = payload,
    })
end

--- Poll for a CRSF MSP response frame (type 0x7B).
--- Strips destination/origin address bytes and returns the MSP chunk.
local function crsfPoll()
    if not sensor then return nil end
    while true do
        local frame = sensor:popFrame()
        if not frame then return nil end
        local fType = frame:frameType()
        if fType == CRSF_FRAMETYPE_MSP_RESP then
            local data = frame:data()
            if data and #data >= 3 then
                -- Strip dest(1) + orig(1), return MSP chunk from status byte
                local chunk = {}
                for i = 3, #data do
                    chunk[#chunk + 1] = data[i]
                end
                return chunk
            end
        end
    end
end

-- ============================================================================
-- MSP framing  (shared chunking for SmartPort and CRSF)
-- ============================================================================

local function mspProcessTxQ()
    if #mspTxBuf == 0 then return false end
    local frame = {}
    frame[1] = mspSeq + MSP_VERSION_BITS
    mspSeq = band(mspSeq + 1, 0x0F)
    if mspTxIdx == 1 then
        frame[1] = frame[1] + MSP_STARTFLAG
    end
    local i = 2
    while i <= maxFramePayload and mspTxIdx <= #mspTxBuf do
        frame[i] = mspTxBuf[mspTxIdx]
        mspTxIdx = mspTxIdx + 1
        mspTxCRC = bxor(mspTxCRC, frame[i])
        i = i + 1
    end
    if i <= maxFramePayload then
        -- SmartPort: append MSP CRC + pad to fixed 6-byte frame
        -- CRSF: NO MSP CRC (protected by CRSF frame CRC per spec)
        if transportType ~= TRANSPORT_CRSF then
            frame[i] = mspTxCRC
            i = i + 1
        end
        if transportType == TRANSPORT_SPORT then
            while i <= maxFramePayload do frame[i] = 0; i = i + 1 end
        end
        rawSend(frame)
        mspTxBuf = {}
        mspTxIdx = 1
        mspTxCRC = 0
        return false
    end
    rawSend(frame)
    return true
end

--- Queue a plain MSPv1 request (cmd < 256).
local function mspSendRequest(cmd, payload)
    if #mspTxBuf ~= 0 then return nil end
    payload = payload or {}
    mspTxBuf[1] = #payload
    mspTxBuf[2] = band(cmd, 0xFF)
    for i = 1, #payload do
        mspTxBuf[i + 2] = band(payload[i], 0xFF)
    end
    mspLastReq = cmd
    mspRealCmd = cmd
    return mspProcessTxQ()
end

--- Queue an MSPv2-over-V1 request (any cmd, 16-bit).
local function mspSendRequestV2(cmd, payload)
    if #mspTxBuf ~= 0 then return nil end
    payload = payload or {}
    local flag   = 0
    local cmdLo  = band(cmd, 0xFF)
    local cmdHi  = band(rshift(cmd, 8), 0xFF)
    local sizeLo = band(#payload, 0xFF)
    local sizeHi = band(rshift(#payload, 8), 0xFF)

    local crc = 0
    crc = crc8_dvb_s2(crc, flag)
    crc = crc8_dvb_s2(crc, cmdLo)
    crc = crc8_dvb_s2(crc, cmdHi)
    crc = crc8_dvb_s2(crc, sizeLo)
    crc = crc8_dvb_s2(crc, sizeHi)
    for i = 1, #payload do
        crc = crc8_dvb_s2(crc, band(payload[i], 0xFF))
    end

    local v2Len = 5 + #payload + 1
    mspTxBuf[1] = v2Len
    mspTxBuf[2] = MSP_V2_FRAME_ID
    local idx = 3
    mspTxBuf[idx] = flag;    idx = idx + 1
    mspTxBuf[idx] = cmdLo;   idx = idx + 1
    mspTxBuf[idx] = cmdHi;   idx = idx + 1
    mspTxBuf[idx] = sizeLo;  idx = idx + 1
    mspTxBuf[idx] = sizeHi;  idx = idx + 1
    for i = 1, #payload do
        mspTxBuf[idx] = band(payload[i], 0xFF)
        idx = idx + 1
    end
    mspTxBuf[idx] = crc

    mspLastReq = MSP_V2_FRAME_ID
    mspRealCmd = cmd
    return mspProcessTxQ()
end

--- Process a single received SmartPort frame as MSP reply fragment.
local function mspReceivedReply(frame)
    local idx    = 1
    local st     = frame[idx]
    local ver    = rshift(band(st, 0x60), 5)
    local start  = btest(st, 0x10)
    local seq    = band(st, 0x0F)
    idx = idx + 1
    if start then
        mspRxBuf   = {}
        mspRxError = btest(st, 0x80)
        mspRxSize  = frame[idx]
        mspRxReq   = mspLastReq
        idx = idx + 1
        if ver == 1 then
            mspRxReq = frame[idx]
            idx = idx + 1
        end
        mspRxCRC = bxor(mspRxSize, mspRxReq)
        if mspRxReq == mspLastReq then
            mspStarted = true
        else
            mspStarted = false
            return nil
        end
    elseif not mspStarted then
        return nil
    elseif band(mspRemoteSeq + 1, 0x0F) ~= seq then
        mspStarted = false
        return nil
    end
    local frameLen = #frame
    while idx <= frameLen and #mspRxBuf < mspRxSize do
        mspRxBuf[#mspRxBuf + 1] = frame[idx]
        mspRxCRC = bxor(mspRxCRC, frame[idx])
        idx = idx + 1
    end
    -- CRSF: no MSP CRC in frame (protected by CRSF frame CRC per spec)
    -- Response is complete once all mspRxSize bytes are collected.
    if transportType == TRANSPORT_CRSF then
        if #mspRxBuf >= mspRxSize then
            mspStarted = false
            return true
        end
        mspRemoteSeq = seq
        return false
    end
    -- SmartPort: expect MSP CRC byte after payload
    if idx > frameLen then
        mspRemoteSeq = seq
        return false
    end
    mspStarted = false
    if ver == 0 and mspRxCRC ~= frame[idx] then
        return nil
    end
    return true
end

--- Unwrap MSPv2-over-V1 response.
local function unwrapV2Response(cmd, buf)
    if cmd ~= MSP_V2_FRAME_ID then
        return cmd, buf, false
    end
    if #buf < 6 then
        return mspRealCmd, {}, true
    end
    local v2Cmd  = buf[2] + lshift(buf[3], 8)
    local v2Size = buf[4] + lshift(buf[5], 8)

    local crc = 0
    for i = 1, 5 + v2Size do
        if buf[i] then
            crc = crc8_dvb_s2(crc, buf[i])
        end
    end
    local expectedCrc = buf[6 + v2Size]
    if expectedCrc and crc ~= expectedCrc then
        return v2Cmd, {}, true
    end

    local inner = {}
    for i = 6, 5 + v2Size do
        inner[#inner + 1] = buf[i]
    end
    return v2Cmd, inner, false
end

--- Poll for a complete MSP reply.
--- Drains ALL available transport frames so multi-frame responses
--- are assembled in a single wakeup cycle.
local function mspPollReply()
    if not rawPoll then return nil end
    while true do
        local frame = rawPoll()
        if not frame then return nil end
        local result = mspReceivedReply(frame)
        if result then
            mspLastReq = 0
            local cmd, buf, err = mspRxReq, mspRxBuf, mspRxError
            if cmd == MSP_V2_FRAME_ID then
                cmd, buf, err = unwrapV2Response(cmd, buf)
            end
            return cmd, buf, err
        end
    end
end

-- ============================================================================
-- Byte-level helpers
-- ============================================================================

local function readInt16(buf, off)
    if not buf[off] or not buf[off + 1] then return 0 end
    local v = buf[off] + lshift(buf[off + 1], 8)
    if v >= 32768 then v = v - 65536 end
    return v
end

local function readInt32(buf, off)
    if not buf[off] or not buf[off + 3] then return 0 end
    local v = buf[off] + lshift(buf[off + 1], 8)
              + lshift(buf[off + 2], 16) + lshift(buf[off + 3], 24)
    if v >= 2147483648 then v = v - 4294967296 end
    return v
end

-- ============================================================================
-- MSP response handlers
-- ============================================================================

--- Split the flat wpList into per-mission sub-tables at flag=0xA5 boundaries.
local function parseMissions()
    missions = {}
    local current = {}
    for _, wp in ipairs(wpList) do
        current[#current + 1] = wp
        if wp.flags == 0xA5 then
            missions[#missions + 1] = current
            current = {}
        end
    end
    if #current > 0 then
        missions[#missions + 1] = current
    end
    log("MSP", fmt("Parsed %d mission(s) from %d waypoints", #missions, #wpList))
end

local function handleStatus(buf)
    -- MSP_STATUS response: uint16 cycleTime, uint16 i2cErr, uint16 sensors,
    --                      uint32 flightModeFlags, uint8 profile  (11 bytes)
    -- In INAV, ARM is always box index 0 → bit 0 of flightModeFlags.
    if #buf >= 10 then
        local flightModeFlags = buf[7] + lshift(buf[8], 8)
                              + lshift(buf[9], 16) + lshift(buf[10], 24)
        local armed = btest(flightModeFlags, 1)
        if armed and not isArmed then
            isArmed = true
            log("MSP", "FC ARMED detected")
        elseif not armed and isArmed then
            isArmed = false
            navMode = 0
            activeWpNumber = 0
            navError = 0
            log("MSP", "FC DISARMED detected")
        end
    end
end

local function handleNavStatus(buf)
    -- MSP_NAV_STATUS response: uint8 navMode, uint8 navState, uint8 activeWpAction,
    --                          uint8 activeWpNumber, uint8 navError, int16 targetHeading (7 bytes)
    if #buf >= 5 then
        navMode        = buf[1]
        navState       = buf[2]
        activeWpNumber = buf[4]
        navError       = buf[5]
        log("MSP", fmt("NAV_STATUS: mode=%d state=%d activeWP=%d err=%d",
                        navMode, navState, activeWpNumber, navError))
    end
end

local function handleFcVariant(buf)
    if #buf >= 4 then
        fcVariant = char(buf[1], buf[2], buf[3], buf[4])
        log("MSP", fmt("FC variant: %s", fcVariant))
        if fcVariant == "INAV" then
            if armingOnly then
                state = STATE_DONE
                log("MSP", "Arming-only mode — skipping WP download")
            else
                state = STATE_GET_WP_INFO
            end
        else
            log("MSP", fmt("Unsupported FC: %s (need INAV)", fcVariant))
            state = STATE_ERROR
            errorTime = clock()
        end
    end
end

local function handleWpGetInfo(buf)
    if #buf >= 4 then
        wpMaxCount = buf[2]
        wpValid    = buf[3] ~= 0
        wpCount    = buf[4]
        log("MSP", fmt("Mission: %d WPs, valid=%s, max=%d",
                        wpCount, wpValid and "yes" or "no", wpMaxCount))
        if wpCount > 0 then
            state     = STATE_DOWNLOADING
            wpNextIdx = 1
            retries   = 0
            log("MSP", fmt("Downloading %d waypoints...", wpCount))
        else
            state = STATE_DONE
            log("MSP", "No waypoints in mission")
        end
    else
        state = STATE_ERROR
    end
end

local function handleWp(buf)
    if #buf < 21 then return end

    local wp = {
        idx        = buf[1],
        action     = buf[2],
        actionName = WP_ACTION_NAMES[buf[2]] or fmt("UNK(%d)", buf[2]),
        lat        = readInt32(buf, 3) / 10000000.0,
        lon        = readInt32(buf, 7) / 10000000.0,
        alt        = readInt32(buf, 11) / 100.0,   -- meters
        p1         = readInt16(buf, 15),
        p2         = readInt16(buf, 17),
        p3         = readInt16(buf, 19),
        flags      = buf[21],
    }
    wpList[#wpList + 1] = wp

    log("MSP", fmt("WP#%d %s lat=%.7f lon=%.7f alt=%.1fm",
                    wp.idx, wp.actionName, wp.lat, wp.lon, wp.alt))

    wpNextIdx = wpNextIdx + 1
    retries   = 0
    if wpNextIdx > wpCount or wp.flags == 0xA5 then
        state = STATE_DONE
        parseMissions()
        log("MSP", fmt("Download complete: %d waypoints", #wpList))
    end
end

-- ============================================================================
-- Internal state reset
-- ============================================================================
local function resetState()
    mspSeq       = 0
    mspRemoteSeq = 0
    mspTxBuf     = {}
    mspTxIdx     = 1
    mspTxCRC     = 0
    mspRxBuf     = {}
    mspRxError   = false
    mspRxSize    = 0
    mspRxCRC     = 0
    mspRxReq     = 0
    mspStarted   = false
    mspLastReq   = 0
    mspRealCmd   = 0

    prevSensorId = nil
    prevFrameId  = nil
    prevDataId   = nil
    prevValue    = nil

    fcVariant    = nil
    connected    = false
    currentCmd   = nil
    lastReqTime  = 0
    lastRspTime  = 0
    retries      = 0

    wpMaxCount   = 0
    wpCount      = 0
    wpValid      = false
    wpNextIdx    = 1
    wpList       = {}
    missions     = {}
    startTime    = 0
    errorTime    = 0
    isArmed        = false
    lastArmPollTime = 0
    armingOnly     = false
    navMode          = 0
    navState         = 0
    activeWpNumber   = 0
    navError         = 0
    lastNavPollTime  = 0
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Acquire sensor, auto-detect transport (SmartPort → CRSF), start state machine.
--- @param opts table|nil  Optional { armingOnly = bool } to skip WP download
function msp.open(opts)
    resetState()
    if opts and opts.armingOnly then
        armingOnly = true
    end
    state     = STATE_CONNECTING
    startTime = clock()

    -- Try SmartPort first (FrSky ACCESS / ACCST / TD)
    local sportRssi =
        system.getSource("RSSI") or
        system.getSource("RSSI 2.4G") or
        system.getSource("RSSI 900M") or
        system.getSource("Rx RSSI1") or
        system.getSource("Rx RSSI2")

    if sportRssi then
        local sportSensor = sport.getSensor({primId = 0x32})
        if sportSensor then
            sensor          = sportSensor
            sensor:module(sportRssi:module())
            transportType   = TRANSPORT_SPORT
            maxFramePayload = SPORT_FRAME_PAYLOAD
            rawSend         = sportSend
            rawPoll         = sportPoll
            log("MSP", "SmartPort transport acquired")
            return
        end
    end

    -- Try CRSF (Crossfire / ELRS)  — UNTESTED, needs hardware verification
    local crsfRssi =
        system.getSource("1RSS") or
        system.getSource("2RSS") or
        system.getSource("RQly") or
        system.getSource("RSNR")

    if crsfRssi and type(crsf) == "table" and type(crsf.getSensor) == "function" then
        local ok, crsfSensor = pcall(crsf.getSensor, {})
        if ok and crsfSensor then
            sensor          = crsfSensor
            pcall(function() sensor:module(crsfRssi:module()) end)
            transportType   = TRANSPORT_CRSF
            maxFramePayload = CRSF_FRAME_PAYLOAD
            rawSend         = crsfSend
            rawPoll         = crsfPoll
            log("MSP", "CRSF transport acquired")
            return
        end
    end

    log("MSP", "No transport available (tried SmartPort and CRSF)")
    state     = STATE_ERROR
    errorTime = clock()
end

--- Release sensor and reset transport state.
function msp.close()
    sensor          = nil
    transportType   = TRANSPORT_NONE
    maxFramePayload = SPORT_FRAME_PAYLOAD
    rawSend         = nil
    rawPoll         = nil
    state           = STATE_OFF
    log("MSP", "Sensor released")
end

--- Drive the MSP state machine. Call once per wakeup cycle.
function msp.poll()
    if state == STATE_OFF then
        return
    end

    -- STATE_DONE: poll arming + nav status
    if state == STATE_DONE then
        local now = clock()
        if #mspTxBuf > 0 then mspProcessTxQ() end
        local cmd, buf, err = mspPollReply()
        if cmd then
            lastRspTime = now
            if cmd == MSP_STATUS and not err then
                handleStatus(buf)
            elseif cmd == MSP_NAV_STATUS and not err then
                handleNavStatus(buf)
            end
            currentCmd = nil
        end
        local readyToSend = currentCmd == nil
            and (now - lastRspTime) >= POST_REPLY_DELAY
            and (now - lastReqTime) >= POST_REPLY_DELAY
        if readyToSend then
            if isArmed and (now - lastNavPollTime) >= NAV_STATUS_POLL_INTERVAL then
                mspSendRequest(MSP_NAV_STATUS, {})
                currentCmd      = MSP_NAV_STATUS
                lastReqTime     = now
                lastNavPollTime = now
            elseif (now - lastArmPollTime) >= ARM_POLL_INTERVAL then
                mspSendRequest(MSP_STATUS, {})
                currentCmd      = MSP_STATUS
                lastReqTime     = now
                lastArmPollTime = now
            end
        end
        if currentCmd and (now - lastReqTime) > REQUEST_TIMEOUT then
            currentCmd = nil
        end
        return
    end

    -- Auto-retry after ERROR: wait RETRY_DELAY then restart
    if state == STATE_ERROR then
        local now = clock()
        if sensor and (now - errorTime) >= RETRY_DELAY then
            log("MSP", "Auto-retry after error...")
            local savedSensor = sensor
            local savedArmingOnly = armingOnly
            resetState()
            sensor     = savedSensor
            armingOnly = savedArmingOnly
            state      = STATE_CONNECTING
            startTime  = now
        end
        return
    end

    local now = clock()

    -- FC detection timeout (only during CONNECTING phase)
    if state == STATE_CONNECTING and (now - startTime) > FC_DETECT_TIMEOUT then
        log("MSP", fmt("No FC detected after %.0fs, retrying...", FC_DETECT_TIMEOUT))
        state = STATE_ERROR
        errorTime = clock()
        currentCmd = nil
        return
    end

    -- Continue transmitting multi-frame requests
    if #mspTxBuf > 0 then
        mspProcessTxQ()
    end

    -- Poll for MSP replies
    local cmd, buf, err = mspPollReply()
    if cmd then
        lastRspTime = now
        connected = true

        if err then
            log("MSP", fmt("Error response for cmd %d", cmd))
        else
            if cmd == MSP_FC_VARIANT then
                handleFcVariant(buf)
            elseif cmd == MSP_WP_GETINFO then
                handleWpGetInfo(buf)
            elseif cmd == MSP_WP then
                handleWp(buf)
            end
        end
        currentCmd = nil
    end

    -- Decide what to request next
    local readyToSend = currentCmd == nil
                        and (now - lastRspTime) >= POST_REPLY_DELAY
                        and (now - lastReqTime) >= POST_REPLY_DELAY

    if readyToSend then
        if state == STATE_CONNECTING then
            mspSendRequest(MSP_FC_VARIANT, {})
            currentCmd  = MSP_FC_VARIANT
            lastReqTime = now
        elseif state == STATE_GET_WP_INFO then
            mspSendRequest(MSP_WP_GETINFO, {})
            currentCmd  = MSP_WP_GETINFO
            lastReqTime = now
        elseif state == STATE_DOWNLOADING then
            mspSendRequest(MSP_WP, { wpNextIdx })
            currentCmd  = MSP_WP
            lastReqTime = now
        end
    end

    -- Timeout handling with progressive backoff
    local retryTimeout = REQUEST_TIMEOUT + retries * 0.5
    if currentCmd and (now - lastReqTime) > retryTimeout then
        retries = retries + 1
        if retries > MAX_RETRIES then
            log("MSP", fmt("Timeout after %d retries (cmd=%d)", MAX_RETRIES, currentCmd))
            state = STATE_ERROR
            errorTime = clock()
            currentCmd = nil
        else
            log("MSP", fmt("Timeout, retry %d (cmd=%d)", retries, currentCmd))
            currentCmd = nil  -- will re-send next cycle
        end
        connected = (now - lastRspTime) < CONNECT_TIMEOUT
    end
end

--- Return current state snapshot for external consumers.
--- @return table { state, fcVariant, connected, wpCount, wpValid, wpList, wpNextIdx }
local TRANSPORT_NAMES = { [0]="NONE", "SPORT", "CRSF" }
function msp.getState()
    return {
        state      = state,
        fcVariant  = fcVariant,
        connected  = connected,
        wpCount    = wpCount,
        wpValid    = wpValid,
        wpList     = wpList,
        wpNextIdx  = wpNextIdx,
        wpMaxCount = wpMaxCount,
        missions   = missions,
        isArmed    = isArmed,
        transport  = TRANSPORT_NAMES[transportType] or "UNKNOWN",
        navMode        = navMode,
        activeWpNumber = activeWpNumber,
    }
end

--- Check if the state machine has completed successfully.
function msp.isDone()
    return state == STATE_DONE
end

--- Check if the state machine hit an error.
function msp.isError()
    return state == STATE_ERROR
end

--- Check if MSP is currently active (open and not finished).
function msp.isActive()
    return state ~= STATE_OFF and state ~= STATE_DONE and state ~= STATE_ERROR
end

-- ============================================================================
-- Module init (called by loadLib)
-- ============================================================================
function msp.init(param_status, param_libs)
    status = param_status
    libs   = param_libs
    return msp
end

return msp
