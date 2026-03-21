--
-- A FRSKY SPort/FPort/FPort2 and TBS CRSF telemetry widget for the Ethos OS
-- based on ArduPilot's passthrough telemetry protocol
--
-- Author: Alessandro Apostoli, https://github.com/yaapu
--
-- This program is free software; you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation; either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY, without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program; if not, see <http://www.gnu.org/licenses>.


local function getTime()
  -- Uses a monotonic wall-clock-like timer in centiseconds.
  -- os.clock() tracks CPU time and can stall when the widget is not in fullscreen,
  -- which pauses scheduler-driven redraws.
  if system ~= nil and type(system.getTimeCounter) == "function" then
    local ms = system.getTimeCounter()
    if type(ms) == "number" and ms >= 0 then
      return ms / 10
    end
  end

  local wallSec = os.time()
  if type(wallSec) == "number" and wallSec > 0 then
    return wallSec * 100
  end

  return os.clock() * 100
end

local hasLfs, lfs = pcall(require, "lfs")
if not hasLfs then
  lfs = nil
end

local logDebugSessionStart
local configRebuildInProgress = false


local mapStatus = {
  -- Runtime telemetry cache populated from Ethos sources and consumed by layout and map drawing code.
  telemetry = {
    yaw = nil,
    roll = nil,
    pitch = nil,
    -- GPS position and derived navigation values.
    lat = nil,
    lon = nil,
    strLat = "---",
    strLon = "---",
    groundSpeed = 0,
    cog = 0,
    -- Home position and vector from aircraft to home.
    homeLat = nil,
    homeLon = nil,
    homeAngle = 0,
    homeDist = 0,
    -- Link quality values mirrored from radio telemetry.
    rssi = 0,
    rssiCRSF = 0,
  },

  -- Persistent widget settings loaded from storage and used by UI, map, and unit conversions.
  conf = {
    horSpeedUnit = 1,
    horSpeedMultiplier = 1,
    horSpeedLabel = "m/s",
    vertSpeedUnit = 1,
    vertSpeedMultiplier = 1,
    vertSpeedLabel = "m/s",
    distUnit = 1,
    distUnitLabel = "m",
    distUnitScale = 1,
    distUnitLong = 1,
    distUnitLongLabel = "km",
    distUnitLongScale = 0.001,
    language = "en",
    -- Map provider and rendering settings.
    mapProvider = 2, -- 1 = GMapCatcher, 2 = Google
    mapType = "Satellite",
    mapZoomLevel = 19,
    mapZoomMax = 20,
    mapZoomMin = 1,
    mapTrailLength = 5,  -- Trail length in km (0=off, 1, 5, 10, 25, 50).
    enableDebugLog = false,   -- Enables the on-device debug log.
    enablePerfProfile = false, -- Emits 5s performance summaries into debug.log.
    gpsFormat = 0, -- 0 = decimal, 1 = DMS
    -- Layout selection persisted for future layout variants.
    layout = 1,
  },

  -- Layout module registry and shared lifecycle counters.
  layoutFilenames = { "layout_default" },
  counter = 0,

  -- Current screen bookkeeping and per-screen loaded layout modules.
  lastScreen = 1,
  loadCycle = 0,
  layout = { nil },

  -- Telemetry visibility flags shared with warning overlays.
  noTelemetryData = 1,
  hideNoTelemetry = false,

  -- Map state used for redraw throttling, trail updates, and debug logging.
  screenTogglePage = 1,
  mapZoomLevel = 19,
  lastLat = nil,
  lastLon = nil,
  mapLastLat = nil,   -- Dedicated to map redraw throttling so COG tracking can use its own history.
  mapLastLon = nil,
  mapLastZoom = 0,
  mapRedrawPending = false,
  mapTickSerial = 0,
  barTickSerial = 0,
  lastLoggedLat = 0,
  lastLoggedLon = 0,
  lastSelectionAutoFixKey = nil,
  cachedProviderChoices = nil,
  cachedMapTypeChoices = {},  -- keyed by provider
  consumeZoomRelease = false,

  avgSpeed = {
    lastSampleTime = nil,
    avgTravelDist = 0,
    avgTravelTime = 0,
    travelDist = 0,
    prevLat = nil,
    prevLon = nil,
    value = 0,
  },

  -- Optional top bar telemetry sources selected by the user.
  linkQualitySource = nil,
  userSensor1 = nil,
  userSensor2 = nil,
  userSensor3 = nil,

  -- Shared blink state consumed by drawing helpers.
  blinkon = false,

  -- Shared lookup tables and UI colors used across libraries.
  unitConversion = {},
  battPercByVoltage = {},
  colors = {
    white = WHITE,
    red = RED,
    green = GREEN,
    black = BLACK,
    yellow = lcd.RGB(255,206,0),
    panelLabel = lcd.RGB(150,150,150),
    panelText = lcd.RGB(255,255,255),
    panelBackground = lcd.RGB(56,60,56),
    barBackground = BLACK,
    barText = WHITE,
    hudSky = lcd.RGB(123,157,255),
    hudTerrain = lcd.RGB(100,185,95),
    hudDashes = lcd.RGB(250, 205, 205),
    hudLines = lcd.RGB(220, 220, 220),
    hudSideText = lcd.RGB(0,238,49),
    hudText = lcd.RGB(255,255,255),
    rpmBar = lcd.RGB(240,192,0),
    background = lcd.RGB(60, 60, 60)
  },

  -- Current widget dimensions and scale factors propagated to layouts and libraries.
  widgetWidth = 800,
  widgetHeight = 480,
  scaleX = 1.0,
  scaleY = 1.0,
  widget = nil,
  compactWidthThreshold = 450,
  tinyWidthThreshold = 350,
  tinyHeightThreshold = 190,
  verticalMedium = false,
  sessionLogged = false,

  perfProfile = {
    windowMs = 5000,
    windowStartMs = 0,
    metrics = {},
    counters = {},
  },
}

-- Performance profiler helper functions (must be defined before paint/wakeup/event use them).
local function perfNowMs()
  return os.clock() * 1000
end

local function perfWindowNowMs()
  -- Use wall-clock seconds for window scheduling; os.clock() is CPU-time and can stall under low load.
  local wallSec = os.time()
  if type(wallSec) == "number" and wallSec > 0 then
    return wallSec * 1000
  end
  -- Fallback to widget timer when RTC is unavailable.
  return getTime() * 10
end

-- Dedicated perf window timer state, independent from mutable config/status tables.
local perfWindowStartMs = nil

-- Map redraws at full wakeup speed for responsive tile fill and reliable touch event delivery.
-- Bars update at ~1s intervals since telemetry values change slowly.
local frameWakeupCount = 0
local scheduledRenderCount = 0
local lastBarTickCs = 0
local BAR_TICK_INTERVAL_CS = 100  -- centiseconds (1 second)

local function markMapDirty()
  mapStatus.mapRedrawPending = true
end

local function resolveWidget(widget)
  -- ETHOS can invoke callbacks with a nil widget in some contexts (non-fullscreen,
  -- background scheduling). Keep the last valid instance as fallback so wakeup/paint
  -- continue to run.
  if widget ~= nil then
    mapStatus.widget = widget
    return widget
  end
  return mapStatus.widget
end

local function configFlagEnabled(value)
  if value == true then
    return true
  end
  local valueType = type(value)
  if valueType == "number" then
    return value ~= 0
  end
  if valueType == "string" then
    local normalized = string.lower(value)
    return normalized == "true" or normalized == "1" or normalized == "on"
  end
  return false
end

local function perfProfileEnabled()
  return mapStatus ~= nil and mapStatus.conf ~= nil and configFlagEnabled(mapStatus.conf.enablePerfProfile) and configFlagEnabled(mapStatus.conf.enableDebugLog)
end

local function perfEnsureMetric(metricName)
  local metrics = mapStatus.perfProfile.metrics
  local metric = metrics[metricName]
  if metric == nil then
    metric = { sum = 0, count = 0, max = 0 }
    metrics[metricName] = metric
  end
  return metric
end

local function perfAddMs(metricName, elapsedMs)
  if not perfProfileEnabled() then
    return
  end
  if type(elapsedMs) ~= "number" then
    return
  end
  if elapsedMs < 0 then
    elapsedMs = 0
  end
  local metric = perfEnsureMetric(metricName)
  metric.sum = metric.sum + elapsedMs
  metric.count = metric.count + 1
  if elapsedMs > metric.max then
    metric.max = elapsedMs
  end
end

local function perfInc(counterName, delta)
  if not perfProfileEnabled() then
    return
  end
  if mapStatus.perfProfile.counters[counterName] == nil then
    mapStatus.perfProfile.counters[counterName] = 0
  end
  mapStatus.perfProfile.counters[counterName] = mapStatus.perfProfile.counters[counterName] + (delta or 1)
end

local function perfResetWindow(nowMs)
  mapStatus.perfProfile.metrics = {}
  mapStatus.perfProfile.counters = {}
  perfWindowStartMs = nowMs
  mapStatus.perfProfile.windowStartMs = nowMs
end

local function perfMetricAvg(metricName)
  local metric = mapStatus.perfProfile.metrics[metricName]
  if metric == nil or metric.count == 0 then
    return 0
  end
  return metric.sum / metric.count
end

local function perfValueText(value, decimals)
  local scale = 10 ^ (decimals or 0)
  return tostring(math.floor(value * scale + 0.5) / scale)
end

local function perfTableCell(label, value)
  return string.format("%-16s", label .. "=" .. tostring(value))
end

local function perfTableRow(rowLabel, firstCell, secondCell, thirdCell)
  return string.format("| %-8s | %-16s | %-16s | %-16s |", rowLabel, firstCell, secondCell, thirdCell)
end

-- Export performance profiler callbacks to mapStatus so libraries can access them.
mapStatus.perfProfileInc = perfInc
mapStatus.perfProfileAddMs = perfAddMs

-- Maps exported source names to default values, formatting metadata, and the telemetry field they mirror.
mapStatus.luaSourcesConfig = {}
mapStatus.luaSourcesConfig.HomeDistance =  {0, 0, UNIT_METER, "homeDist", 1}
mapStatus.luaSourcesConfig.CourseOverGround =  {0, 0, UNIT_DEGREE, "cog", 1}
mapStatus.luaSourcesConfig.GroundSpeed =  {0, 1, UNIT_METER_PER_SECOND, "groundSpeed", 1}

local function makeSourceWakeup(sourceName)
  -- Returns a wakeup callback bound to a single source config entry to avoid relying on source:name() at runtime.
  return function(source)
    if source == nil or type(source.value) ~= "function" then
      return
    end

    local cfg = mapStatus.luaSourcesConfig[sourceName]
    if cfg == nil then
      pcall(function() source:value(0) end)
      return
    end

    local telemetryField = cfg[4]
    local scale = cfg[5] or 1
    local decimals = cfg[2] or 0
    local telemetryValue = tonumber(mapStatus.telemetry[telemetryField])
    if telemetryValue == nil then
      pcall(function() source:value(0) end)
      return
    end

    local out = telemetryValue * scale
    if decimals == 0 then
      out = math.floor(0.5 + out)
    end
    pcall(function() source:value(out) end)
  end
end

local function makeSourceInit(sourceName)
  -- Returns an init callback bound to a single source config entry and applies stable defaults.
  return function(source)
    if source == nil then
      return
    end

    local cfg = mapStatus.luaSourcesConfig[sourceName]
    if cfg == nil then
      if type(source.value) == "function" then
        pcall(function() source:value(0) end)
      end
      return
    end

    if type(source.value) == "function" then
      pcall(function() source:value(cfg[1] or 0) end)
    end
    if type(source.decimals) == "function" then
      pcall(function() source:decimals(cfg[2] or 0) end)
    end
    if type(source.unit) == "function" then
      pcall(function() source:unit(cfg[3]) end)
    end
  end
end

local mapLibs = {
  drawLib    = nil,
  resetLib   = nil,
  tileLoader = nil,
  mapLib     = nil,
  utils      = nil,
}

function loadLib(name)
  -- Loads a library module from disk, injects shared state through init(), and returns the initialized library table.
  local lib = dofile("/scripts/ethosmaps/lib/"..name..".lua")
  if lib.init ~= nil then
    lib.init(mapStatus, mapLibs)
  end
  return lib
end

local function initLibs()
  -- Lazily loads shared libraries once and stores them in mapLibs for later callbacks.
  -- tileLoader must be loaded before mapLib so mapLib can reference libs.tileLoader.
  if mapLibs.utils == nil then mapLibs.utils = loadLib("utils") end
  if mapLibs.drawLib == nil then mapLibs.drawLib = loadLib("drawlib") end
  if mapLibs.resetLib == nil then mapLibs.resetLib = loadLib("resetLib") end
  if mapLibs.tileLoader == nil then mapLibs.tileLoader = loadLib("tileloader") end
  if mapLibs.mapLib == nil then mapLibs.mapLib = loadLib("maplib") end
end

local function checkSize(widget)
  -- Refreshes widget dimensions from the active LCD window and writes the derived scale back into mapStatus.
  local w, h = lcd.getWindowSize()
  mapStatus.widgetWidth = w
  mapStatus.widgetHeight = h
  mapStatus.scaleX = w / 800
  mapStatus.scaleY = h / 480
  mapStatus.verticalMedium = w < (mapStatus.compactWidthThreshold or 450)

  return true
end

local function createOnce(widget)
  -- Marks a widget instance as ready for background processing after the first valid lifecycle callback.
  widget.runBgTasks = true
end

local function reset(widget)
  -- Delegates a user-triggered reset to resetLib so layouts and cached map data are rebuilt.
  if mapLibs and mapLibs.mapLib and mapLibs.mapLib.clearTrail then
    mapLibs.mapLib.clearTrail()
  end
  mapLibs.resetLib.reset(widget)
  markMapDirty()
end

local function loadLayout(widget)
  -- Draws a temporary loading overlay, then loads the layout module for the current screen into mapStatus.layout.
  lcd.pen(SOLID)
  lcd.color(lcd.RGB(20, 20, 20))
  lcd.drawFilledRectangle(mapStatus.widgetWidth/4, mapStatus.widgetHeight/4, mapStatus.widgetWidth/2, mapStatus.widgetHeight/4)
  lcd.color(mapStatus.colors.white)
  lcd.drawRectangle(mapStatus.widgetWidth/4, mapStatus.widgetHeight/4, mapStatus.widgetWidth/2, mapStatus.widgetHeight/4,3)
  lcd.color(mapStatus.colors.white)
  lcd.font(FONT_XXL)
  lcd.drawText(mapStatus.widgetWidth/2, mapStatus.widgetHeight/2, "loading layout...", CENTERED)

  if mapStatus.layout[widget.screen] == nil then
    mapStatus.layout[widget.screen] = loadLib(mapStatus.layoutFilenames[widget.screen])
  end
  widget.ready = true
end

mapStatus.blinkTimer = getTime()
local bgclock = 0

local function bgtasks(widget)
  -- Collects telemetry from Ethos sources, derives navigation values, and writes the updated state back into mapStatus.
  local now = getTime()
  mapStatus.counter = mapStatus.counter + 1

  -- Re-emit session header if it was skipped (e.g. after a log rollover or a failed first attempt).
  if not mapStatus.sessionLogged then
    logDebugSessionStart("bgtasks-retry")
  end
  local gpsSrcLat = system.getSource({name="GPS", options=OPTION_LATITUDE})
  local gpsSrcLon = system.getSource({name="GPS", options=OPTION_LONGITUDE})
  local gpsData = {}
  gpsData.lat = gpsSrcLat and gpsSrcLat:value() or nil
  gpsData.lon = gpsSrcLon and gpsSrcLon:value() or nil
  if gpsData.lat ~= nil and gpsData.lon ~= nil then
    mapStatus.telemetry.lat = gpsData.lat
    mapStatus.telemetry.lon = gpsData.lon

    -- Log GPS position at most once every 15 seconds to avoid flooding the debug log.
    if mapStatus and mapStatus.conf and configFlagEnabled(mapStatus.conf.enableDebugLog) and mapLibs and mapLibs.utils then -- Safeguard: avoid logger access before config and libraries are initialized.
      local lat = mapStatus.telemetry.lat or 0
      local lon = mapStatus.telemetry.lon or 0
      local gpsLogInterval = 1500 -- centiseconds (15 seconds)
      if now - (mapStatus.lastGpsLogTime or 0) >= gpsLogInterval then
        mapLibs.utils.logDebug("GPS", string.format("lat=%.6f lon=%.6f", lat, lon))
        mapStatus.lastGpsLogTime = now
        mapStatus.lastLoggedLat = lat
        mapStatus.lastLoggedLon = lon
      end
    end
  end

  if mapStatus.telemetry.lat ~= nil and mapStatus.telemetry.lon ~= nil then
    if mapStatus.avgSpeed.lastLat == nil or mapStatus.avgSpeed.lastLon == nil then
      mapStatus.avgSpeed.lastLat = mapStatus.telemetry.lat
      mapStatus.avgSpeed.lastLon = mapStatus.telemetry.lon
      mapStatus.avgSpeed.lastSampleTime = now
    end

    if now - mapStatus.avgSpeed.lastSampleTime > 100 then
      local travelDist = mapLibs.utils.haversine(mapStatus.telemetry.lat, mapStatus.telemetry.lon, mapStatus.avgSpeed.lastLat, mapStatus.avgSpeed.lastLon)
      local travelTime = now - mapStatus.avgSpeed.lastSampleTime
      if travelDist < 10000 then
        mapStatus.avgSpeed.avgTravelDist = mapStatus.avgSpeed.avgTravelDist * 0.8 + travelDist*0.2
        mapStatus.avgSpeed.avgTravelTime = mapStatus.avgSpeed.avgTravelTime * 0.8 + 0.01 * travelTime * 0.2
        mapStatus.avgSpeed.value = mapStatus.avgSpeed.avgTravelDist/mapStatus.avgSpeed.avgTravelTime
        mapStatus.avgSpeed.travelDist = mapStatus.avgSpeed.travelDist + mapStatus.avgSpeed.avgTravelDist
        mapStatus.telemetry.groundSpeed = mapStatus.avgSpeed.value
      end
      mapStatus.avgSpeed.lastLat = mapStatus.telemetry.lat
      mapStatus.avgSpeed.lastLon = mapStatus.telemetry.lon
      mapStatus.avgSpeed.lastSampleTime = now

      if mapStatus.telemetry.homeLat ~= nil and mapStatus.telemetry.homeLon ~= nil then
        mapStatus.telemetry.homeDist = mapLibs.utils.haversine(mapStatus.telemetry.lat, mapStatus.telemetry.lon, mapStatus.telemetry.homeLat, mapStatus.telemetry.homeLon)
        mapStatus.telemetry.homeAngle = mapLibs.utils.getAngleFromLatLon(mapStatus.telemetry.lat, mapStatus.telemetry.lon, mapStatus.telemetry.homeLat, mapStatus.telemetry.homeLon)
      end
    end
  end

  if bgclock % 4 == 2 then
    if mapStatus.telemetry.lat ~= nil and mapStatus.telemetry.lon ~= nil then
      if mapStatus.conf.gpsFormat == 1 then
        mapStatus.telemetry.strLat = mapLibs.utils.decToDMSFull(mapStatus.telemetry.lat)
        mapStatus.telemetry.strLon = mapLibs.utils.decToDMSFull(mapStatus.telemetry.lon, mapStatus.telemetry.lat)
      else
        mapStatus.telemetry.strLat = string.format("%.06f", mapStatus.telemetry.lat)
        mapStatus.telemetry.strLon = string.format("%.06f", mapStatus.telemetry.lon)
      end
    end
    mapLibs.utils.updateCog()
  end

  if now - mapStatus.blinkTimer > 60 then
    mapStatus.blinkon = not mapStatus.blinkon
    mapStatus.blinkTimer = now
  end
  bgclock = (bgclock%4)+1
end

local function gpsDataAvailable(lat,lon)
  -- Validates a GPS fix before map and overlay code consume the coordinates.
  return lat ~= nil and lon ~= nil and lat ~= 0 and lon ~= 0
end

local function paint(widget)
  -- Clears the widget area and routes drawing to the active layout using the latest shared state.
  local perfActive = perfProfileEnabled() -- Performance profiler trigger (disabled unless debug + perf profile are both enabled).
  local perfStartMs = nil
  if perfActive then
    perfStartMs = perfNowMs()
    perfInc("paint_calls", 1)
  end
  widget = resolveWidget(widget)
  if not widget then return end -- Safeguard: Ethos can call paint before a widget instance is fully available.
  lcd.color(mapStatus.colors.background)
  lcd.pen(SOLID)
  lcd.drawFilledRectangle(0, 0, mapStatus.widgetWidth, mapStatus.widgetHeight)

  if mapStatus.lastScreen ~= widget.screen then
    mapStatus.lastScreen = widget.screen
  end

  if not checkSize(widget) then return end

  if not widget.ready then
    loadLayout(widget)
  else
    if mapStatus.layout[widget.screen] ~= nil then
      local drawStartMs = nil
      if perfActive then
        drawStartMs = perfNowMs()
      end
      mapStatus.layout[widget.screen].draw(widget)
      if perfActive then
        perfAddMs("layout_draw_ms", perfNowMs() - drawStartMs)
      end
    else
      loadLayout(widget)
    end
  end

  if not gpsDataAvailable(mapStatus.telemetry.lat, mapStatus.telemetry.lon) then
    mapLibs.drawLib.drawNoGPSData(widget)
  end
  if perfActive then
    local paintElapsedMs = perfNowMs() - perfStartMs
    perfAddMs("paint_total_ms", paintElapsedMs)
    if paintElapsedMs >= 100 then
      perfInc("long_frame_count_100ms", 1)
    end
    if paintElapsedMs >= 200 then
      perfInc("long_frame_count_200ms", 1)
    end
  end
end

local function event(widget, category, value, x, y)
  -- Handles touch input from Ethos, updates zoom state, and consumes handled events before they reach other UI code.
  local perfActive = perfProfileEnabled() -- Performance profiler trigger (disabled unless debug + perf profile are both enabled).
  local perfStartMs = nil
  if perfActive then
    perfStartMs = perfNowMs()
  end
  widget = resolveWidget(widget)
  local kill = false

  if category == EVT_TOUCH and x ~= nil and y ~= nil then
    if perfActive then
      perfInc("touch_events", 1)
    end
    local w, h = lcd.getWindowSize()
    if w ~= nil and h ~= nil and w > 0 and h > 0 then
      mapStatus.widgetWidth = w
      mapStatus.widgetHeight = h
      mapStatus.scaleX = w / 800
      mapStatus.scaleY = h / 480
    end

    if mapStatus and mapStatus.conf and configFlagEnabled(mapStatus.conf.enableDebugLog) and mapLibs and mapLibs.utils then
      mapLibs.utils.logDebug("TOUCH", string.format("value=%s x=%s y=%s", tostring(value), tostring(x), tostring(y)))
    end

    local scaleFactor = 0.15 + 0.8 * mapStatus.scaleX
    local btnSize = math.floor(52 * scaleFactor)
    local btnX = 12 * mapStatus.scaleX
    local ultraTiny =
      (mapStatus.widgetWidth < (mapStatus.tinyWidthThreshold or 350)) and
      (mapStatus.widgetHeight < (mapStatus.tinyHeightThreshold or 190))

    local btnYPlus, btnYMinus
    if ultraTiny then
      local edgeMargin = btnX
      btnYPlus = edgeMargin
      btnYMinus = mapStatus.widgetHeight - btnSize - edgeMargin
    else
      btnYPlus = 0.27 * mapStatus.widgetHeight
      btnYMinus = mapStatus.widgetHeight - 0.27 * mapStatus.widgetHeight - btnSize
    end

    local touchPadding
    if ultraTiny then
      local maxUltraPadding = math.floor((mapStatus.widgetHeight - 2 * (btnSize + btnX)) / 2) - 1
      if maxUltraPadding < 0 then
        maxUltraPadding = 0
      end
      touchPadding = math.min(12, maxUltraPadding)
    else
      touchPadding = 20
    end

    local touchSize = btnSize + 2 * touchPadding
    local plusLeft = btnX - touchPadding
    local plusTop = btnYPlus - touchPadding
    local minusLeft = btnX - touchPadding
    local minusTop = btnYMinus - touchPadding

    local hitPlus = mapLibs.drawLib.isInside(x, y, plusLeft, plusTop, plusLeft + touchSize, plusTop + touchSize)
    local hitMinus = mapLibs.drawLib.isInside(x, y, minusLeft, minusTop, minusLeft + touchSize, minusTop + touchSize)

    if value == 16641 then
      if mapStatus.consumeZoomRelease or hitPlus or hitMinus then
        mapStatus.consumeZoomRelease = false
        system.killEvents(value)
        return true
      end
      return false
    end

    if value ~= 16640 then
      return false -- Process zoom only on press events; release events must not trigger zoom.
    end
    kill = true

    -- Evaluate minus first so lower-zone taps win in edge overlap scenarios.
    if hitMinus then
      mapStatus.mapZoomLevel = math.max(mapStatus.conf.mapZoomMin, mapStatus.mapZoomLevel - 1)
      mapStatus.consumeZoomRelease = true
      markMapDirty()
      if configFlagEnabled(mapStatus.conf.enableDebugLog) and mapLibs and mapLibs.utils then
        mapLibs.utils.logDebug("TOUCH", ">>> ZOOM - PRESSED <<<", true)
      end

    elseif hitPlus then
      mapStatus.mapZoomLevel = math.min(mapStatus.conf.mapZoomMax, mapStatus.mapZoomLevel + 1)
      mapStatus.consumeZoomRelease = true
      markMapDirty()
      if configFlagEnabled(mapStatus.conf.enableDebugLog) and mapLibs and mapLibs.utils then
        mapLibs.utils.logDebug("TOUCH", ">>> ZOOM + PRESSED <<<", true)
      end

    else
      mapStatus.consumeZoomRelease = false
      kill = false
    end
  end

  
  if kill then
    system.killEvents(value)
    if perfActive then
      perfAddMs("event_total_ms", perfNowMs() - perfStartMs)
    end
    return true
  end
  if perfActive then
    perfAddMs("event_total_ms", perfNowMs() - perfStartMs)
  end
  return false
end

local function setHome(widget)
  -- Copies the current aircraft position from telemetry into the stored home position used by map overlays.
  mapStatus.telemetry.homeLat = mapStatus.telemetry.lat
  mapStatus.telemetry.homeLon = mapStatus.telemetry.lon
  markMapDirty()
end

local function menu(widget)
  -- Builds the widget context menu from the current telemetry state and dispatches actions back into shared status.
  if mapStatus.telemetry.lat ~= nil and mapStatus.telemetry.lon ~= nil then
    return {
      { "Maps: Reset", function() reset(widget) end },
      { "Maps: Set Home", function() setHome(widget) end },
      { "Maps: Zoom in", function() mapStatus.mapZoomLevel = math.min(mapStatus.conf.mapZoomMax, mapStatus.mapZoomLevel+1); markMapDirty() end},
      { "Maps: Zoom out", function() mapStatus.mapZoomLevel = math.max(mapStatus.conf.mapZoomMin, mapStatus.mapZoomLevel-1); markMapDirty() end},
    }
  end
  return { { "Maps: Reset", function() reset(widget) end } }
end

local function wakeup(widget)
  -- Runs recurring background work between paint calls and invalidates the LCD so Ethos schedules a redraw.
  local perfActive = perfProfileEnabled() -- Performance profiler trigger (disabled unless debug + perf profile are both enabled).
  local perfStartMs = nil
  if perfActive then
    perfStartMs = perfNowMs()
    perfInc("wakeup_calls", 1)
  end
  widget = resolveWidget(widget)
  if not widget then return end -- Safeguard: Ethos can schedule wakeup before the widget handle is ready.
  local now = getTime()

  if mapStatus.initPending then
    createOnce(widget)
    mapStatus.initPending = false
  end

  if widget.runBgTasks then
    local bgStartMs = nil
    if perfActive then
      bgStartMs = perfNowMs()
    end
    bgtasks(widget)
    if perfActive then
      perfAddMs("bgtasks_ms", perfNowMs() - bgStartMs)
    end
  end

  if mapLibs and mapLibs.tileLoader then
    local tileLoadStartMs = nil
    if perfActive then
      tileLoadStartMs = perfNowMs()
    end
    if mapLibs.tileLoader.getQueueLength() > 0 then
      mapLibs.tileLoader.processQueue(2)
    end
    if perfActive then
      perfAddMs("tile_load_ms", perfNowMs() - tileLoadStartMs)
    end
  end

  if configFlagEnabled(mapStatus and mapStatus.conf and mapStatus.conf.enableDebugLog)
      and mapLibs and mapLibs.utils and mapLibs.utils.flushLogs then
    local flushStartMs = nil
    if perfActive then
      flushStartMs = perfNowMs()
    end
    mapLibs.utils.flushLogs(false)
    if perfActive then
      perfAddMs("log_flush_ms", perfNowMs() - flushStartMs)
    end
  end

  if perfActive then
    perfAddMs("wakeup_total_ms", perfNowMs() - perfStartMs)
    local perfNowWallMs = perfWindowNowMs()
    local startMs = perfWindowStartMs or tonumber(mapStatus.perfProfile.windowStartMs) or 0
    local windowMs = tonumber(mapStatus.perfProfile.windowMs) or 5000

    if startMs == 0 then
      perfWindowStartMs = perfNowWallMs
      mapStatus.perfProfile.windowStartMs = perfNowWallMs
      startMs = perfNowWallMs
    end

    local elapsedMs = perfNowWallMs - startMs
    if elapsedMs >= windowMs and mapLibs and mapLibs.utils and mapLibs.utils.logDebug then
      local elapsedSec = elapsedMs / 1000
      local wakeupCalls = mapStatus.perfProfile.counters.wakeup_calls or 0
      local paintCalls = mapStatus.perfProfile.counters.paint_calls or 0
      local fps = 0
      if elapsedSec > 0 then
        fps = paintCalls / elapsedSec
      end

      mapLibs.utils.logDebug("PERF", "=== PERF WINDOW " .. perfValueText(elapsedSec, 1) .. "s ===", true)
      mapLibs.utils.logDebug("PERF", "+----------+------------------+------------------+------------------+", true)
      mapLibs.utils.logDebug(
        "PERF",
        perfTableRow(
          "rate",
          perfTableCell("fps", perfValueText(fps, 2)),
          perfTableCell("wakeups", wakeupCalls),
          perfTableCell("paints", paintCalls)
        ),
        true
      )
      mapLibs.utils.logDebug(
        "PERF",
        perfTableRow(
          "draw",
          perfTableCell("paintMs", perfValueText(perfMetricAvg("paint_total_ms"), 2)),
          perfTableCell("layoutMs", perfValueText(perfMetricAvg("layout_draw_ms"), 2)),
          perfTableCell("tileMs", perfValueText(perfMetricAvg("tile_update_ms"), 2))
        ),
        true
      )
      mapLibs.utils.logDebug(
        "PERF",
        perfTableRow(
          "misc",
          perfTableCell("bgMs", perfValueText(perfMetricAvg("bgtasks_ms"), 2)),
          perfTableCell("tileLoadMs", perfValueText(perfMetricAvg("tile_load_ms"), 2)),
          perfTableCell("flushMs", perfValueText(perfMetricAvg("log_flush_ms"), 2))
        ),
        true
      )
      mapLibs.utils.logDebug(
        "PERF",
        perfTableRow(
          "counts",
          perfTableCell("rebuilds", mapStatus.perfProfile.counters.tile_rebuild_count or 0),
          perfTableCell("tileCalls", mapStatus.perfProfile.counters.tile_update_calls or 0),
          perfTableCell("touches", mapStatus.perfProfile.counters.touch_events or 0)
        ),
        true
      )
      mapLibs.utils.logDebug(
        "PERF",
        perfTableRow(
          "sched",
          perfTableCell("invalidates", mapStatus.perfProfile.counters.invalidate_count or 0),
          perfTableCell("frame100ms", mapStatus.perfProfile.counters.long_frame_count_100ms or 0),
          perfTableCell("frame200ms", mapStatus.perfProfile.counters.long_frame_count_200ms or 0)
        ),
        true
      )
      mapLibs.utils.logDebug(
        "PERF",
        perfTableRow(
          "gc",
          perfTableCell("gcCalls", mapStatus.perfProfile.counters.gc_count or 0),
          perfTableCell("-", "-"),
          perfTableCell("-", "-")
        ),
        true
      )
      mapLibs.utils.logDebug(
        "PERF",
        "+----------+------------------+------------------+------------------+",
        true
      )
      perfResetWindow(perfNowWallMs)
    end
  end

  frameWakeupCount = frameWakeupCount + 1
  scheduledRenderCount = scheduledRenderCount + 1
  mapStatus.mapTickSerial = scheduledRenderCount
  if now - lastBarTickCs >= BAR_TICK_INTERVAL_CS then
    mapStatus.barTickSerial = mapStatus.barTickSerial + 1
    lastBarTickCs = now
  end
  if perfActive then
    perfInc("invalidate_count", 1)
  end
  lcd.invalidate()

  -- Step B: Periodische Garbage Collection (alle 10 Wakeups)
  if frameWakeupCount % 10 == 0 then
    collectgarbage()
    if perfActive then
      perfInc("gc_count", 1)
    end
  end
end

local function create()
  -- Creates a fresh widget instance, initializes shared libraries, and returns the per-instance state table to Ethos.
  if not mapStatus.initPending then
    mapStatus.initPending = true
  end

  initLibs()
  -- Reset session logging flag so fresh widget initializations emit a new debug marker.
  mapStatus.sessionLogged = false


  mapStatus.perfProfileAddMs = perfAddMs
  mapStatus.perfProfileInc = perfInc

  -- Emit a visible session marker once so each debug log session has a clear start record.
  logDebugSessionStart("widget create")

  return {
    conf = mapStatus.conf,
    ready = false,
    runBgTasks = false,
    drawOffsetX = 0,
    drawOffsetY = 0,
    lastW = 0,
    lastH = 0,
    lastZoom = 0,
    screen = 1,
    centerPanelIndex = 1,
    leftPanelIndex = 1,
    rightPanelIndex = 1,
    layout = nil,
    centerPanel = nil,
    leftPanel = nil,
    rightPanel = nil,
    name = "ETHOS Maps",
  }
end

local function applyDefault(value, defaultValue, lookup)
  -- Resolves a value through a default and optional lookup table before configuration fields consume it.
  local v = value ~= nil and value or defaultValue
  if lookup ~= nil then return lookup[v] end
  return v
end

local function storageToConfig(name, defaultValue, lookup)
  -- Reads a persisted setting from storage and normalizes it into the in-memory config format.
  local storageValue = storage.read(name)
  return applyDefault(storageValue, defaultValue, lookup)
end

local function storageToConfigWithFallback(name, defaultValue, fallbackNames, lookup)
  -- Reads a setting from primary storage key and falls back to legacy keys for backward compatibility.
  local storageValue = storage.read(name)
  if storageValue == nil and fallbackNames ~= nil then
    for i=1,#fallbackNames do
      storageValue = storage.read(fallbackNames[i])
      if storageValue ~= nil then
        break
      end
    end
  end
  return applyDefault(storageValue, defaultValue, lookup)
end

local function configToStorage(value, lookup)
  -- Converts an in-memory config value back into the stored lookup index when persistence needs it.
  if lookup == nil then return value end
  for i=1,#lookup do
    if lookup[i] == value then return i end
  end
  return 1
end

local MAP_PROVIDER_LABELS = {
  [1] = "GMapCatcher (Yaapu)",
  [2] = "Google",
  [3] = "ESRI",
  [4] = "OSM",
}

local MAP_TYPE_LABELS = {
  [1] = "Satellite",
  [2] = "Hybrid",
  [3] = "Map",
  [4] = "Terrain",
  [5] = "Street",
}

-- On-disk folder names for each map provider under /bitmaps/ethosmaps/maps/
local PROVIDER_FOLDER_NAMES = {
  [2] = "GOOGLE",
  [3] = "ESRI",
  [4] = "OSM",
}

local function pathExists(path)
  if path == nil or path == "" then
    return false
  end
  local f = io.open(path, "r")
  if f ~= nil then
    io.close(f)
    return true
  end
  local ok, _, code = os.rename(path, path)
  if ok then
    return true
  end
  return code == 13
end

local function getProviderRootCandidates(provider)
  local roots = {}
  if provider == 1 then
    table.insert(roots, "/bitmaps/yaapu/maps")
    return roots
  end
  local folderName = PROVIDER_FOLDER_NAMES[provider] or ("PROVIDER" .. tostring(provider or ""))
  table.insert(roots, "/bitmaps/ethosmaps/maps/" .. folderName)
  return roots
end

local function getMapTypeFolder(provider, mapTypeId)
  if provider == 0 or mapTypeId == 0 then
    return nil
  end
  if provider == 1 then
    -- GMapCatcher/Yaapu internal folder names.
    return applyDefault(mapTypeId, 1, {"sat_tiles","tiles","tiles","ter_tiles"})
  end
  if provider == 3 then
    -- ESRI: Satellite, Hybrid, Street.
    if mapTypeId == 1 then return "Satellite" end
    if mapTypeId == 2 then return "Hybrid" end
    if mapTypeId == 5 then return "Street" end
    return nil
  end
  if provider == 4 then
    -- OSM: Street only.
    if mapTypeId == 5 then return "Street" end
    return nil
  end
  -- Google (provider 2): Satellite, Hybrid, Map, Terrain.
  if mapTypeId == 1 then return "Satellite" end
  if mapTypeId == 2 then return "Hybrid" end
  if mapTypeId == 3 then return "Map" end
  if mapTypeId == 4 then return "Terrain" end
  return nil
end

local function getGoogleMapTypeYaapuName(mapTypeId)
  -- Maps Google map type IDs to their Yaapu folder names (for fallback).
  return applyDefault(mapTypeId, 1, {"GoogleSatelliteMap","GoogleHybridMap","GoogleMap","GoogleTerrainMap"})
end

local function mapTypeFolderExists(provider, mapTypeId)
  local folder = getMapTypeFolder(provider, mapTypeId)
  if folder == nil then
    return false
  end
  
  if provider == 2 then
    -- For Google, check BOTH ethosmaps and Yaapu paths for availability.
    local ethosmapsRoot = "/bitmaps/ethosmaps/maps/GOOGLE"
    if pathExists(ethosmapsRoot .. "/" .. folder) then
      return true
    end
    local yaapuFolder = getGoogleMapTypeYaapuName(mapTypeId)
    if pathExists("/bitmaps/yaapu/maps/" .. yaapuFolder) then
      return true
    end
    return false
  end
  
  local roots = getProviderRootCandidates(provider)
  for r=1,#roots do
    if pathExists(roots[r] .. "/" .. folder) then
      return true
    end
  end
  return false
end

local function choiceContainsValue(choices, value)
  for i=1,#choices do
    if choices[i][2] == value then
      return true
    end
  end
  return false
end

local function invalidateAvailabilityCaches(provider)
  -- Kept for compatibility with existing call sites; availability now uses live scanning.
  mapStatus.cachedProviderChoices = nil
  mapStatus.cachedMapTypeChoices = {}
end

local function getAvailableProviderChoices(forceRefresh)
  local choices = {}
  for provider=1,4 do
    local available = false
    for typeId=1,5 do
      if mapTypeFolderExists(provider, typeId) then
        available = true
        break
      end
    end
    if available then
      table.insert(choices, {MAP_PROVIDER_LABELS[provider], provider})
    end
  end

  if #choices == 0 then
    table.insert(choices, {"NONE", 0})
  end
  return choices
end

local function getAvailableMapTypeChoices(provider, forceRefresh)
  if provider == 0 then
    return {{"NONE", 0}}
  end

  local choices = {}
  for typeId=1,5 do
    local folder = getMapTypeFolder(provider, typeId)
    if folder ~= nil and mapTypeFolderExists(provider, typeId) then
      table.insert(choices, {MAP_TYPE_LABELS[typeId], typeId})
    end
  end

  if #choices == 0 then
    table.insert(choices, {"NONE", 0})
  end
  return choices
end

local getSortedDirectories

local function getAvailableZoomBounds(provider, mapTypeId)
  local folder = getMapTypeFolder(provider, mapTypeId)
  if folder == nil then
    return nil, nil
  end

  local searchRoots = {}
  if provider == 2 then
    table.insert(searchRoots, "/bitmaps/ethosmaps/maps/GOOGLE/" .. folder)
    local yaapuFolder = getGoogleMapTypeYaapuName(mapTypeId)
    if yaapuFolder ~= nil then
      table.insert(searchRoots, "/bitmaps/yaapu/maps/" .. yaapuFolder)
    end
  elseif provider == 1 then
    table.insert(searchRoots, "/bitmaps/yaapu/maps/" .. folder)
  else
    local roots = getProviderRootCandidates(provider)
    for i = 1, #roots do
      table.insert(searchRoots, roots[i] .. "/" .. folder)
    end
  end

  local minZoom = nil
  local maxZoom = nil

  for i = 1, #searchRoots do
    local dirs = getSortedDirectories(searchRoots[i])
    if type(dirs) == "table" then
      for j = 1, #dirs do
        local zoom = tonumber(dirs[j])
        if zoom ~= nil and zoom >= 1 and zoom <= 20 and math.floor(zoom) == zoom then
          if minZoom == nil or zoom < minZoom then
            minZoom = zoom
          end
          if maxZoom == nil or zoom > maxZoom then
            maxZoom = zoom
          end
        end
      end
    end
  end

  return minZoom, maxZoom
end

local function replaceChoices(targetChoices, sourceChoices)
  if targetChoices == nil then
    return
  end
  for i = #targetChoices, 1, -1 do
    targetChoices[i] = nil
  end
  for i = 1, #sourceChoices do
    targetChoices[i] = {sourceChoices[i][1], sourceChoices[i][2]}
  end
end

local function refreshConfigureForm()
  if form == nil then
    return false
  end

  local refreshMethods = { "reinit", "invalidate", "refresh", "reload" }
  for i = 1, #refreshMethods do
    local methodName = refreshMethods[i]
    local method = form[methodName]
    if type(method) == "function" then
      local ok = pcall(method)
      if ok then
        return true
      end
    end
  end
  return false
end

local function syncMapTypeChoicesForProvider(widget, provider, forceRefresh)
  local availableTypes = getAvailableMapTypeChoices(provider, forceRefresh)
  local oldMapTypeId = mapStatus.conf.mapTypeId

  if not choiceContainsValue(availableTypes, mapStatus.conf.mapTypeId) then
    mapStatus.conf.mapTypeId = availableTypes[1][2]
  end

  if widget ~= nil and widget.mapTypeChoices ~= nil then
    replaceChoices(widget.mapTypeChoices, availableTypes)
  end

  if widget ~= nil and widget.mapTypeField ~= nil then
    widget.mapTypeField:enable(provider ~= 0)
  end

  return availableTypes, oldMapTypeId
end

local function logMapSelectionAutofix(message)
  if mapStatus and mapStatus.conf and configFlagEnabled(mapStatus.conf.enableDebugLog) and mapLibs and mapLibs.utils and mapLibs.utils.logDebug then
    mapLibs.utils.logDebug("SETTINGS", message, true)
  end
end

local function toLogValue(value)
  if value == nil then
    return "nil"
  end
  local valueType = type(value)
  if valueType == "boolean" then
    return value and "true" or "false"
  end
  if valueType == "userdata" or valueType == "function" or valueType == "thread" then
    return "<" .. valueType .. ">"
  end
  return tostring(value)
end

getSortedDirectories = function(path)
  if system and type(system.listFiles) == "function" then
    local ok, entries = pcall(system.listFiles, path)
    if ok and type(entries) == "table" then
      local result = {}
      local seen = {}
      for i = 1, #entries do
        local rawName = entries[i]
        if type(rawName) == "string" and rawName ~= "." and rawName ~= ".." and rawName ~= "" then
          local name = rawName:gsub("/+$", "")
          if not seen[name] then
            seen[name] = true
            table.insert(result, name)
          end
        end
      end
      table.sort(result)
      return result, nil
    end
  end

  if lfs ~= nil then
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "directory" then
      return {}, nil
    end

    local result = {}
    for entry in lfs.dir(path) do
      if entry ~= "." and entry ~= ".." then
        local fullPath = path .. "/" .. entry
        local entryAttr = lfs.attributes(fullPath)
        if entryAttr and entryAttr.mode == "directory" then
          table.insert(result, entry)
        end
      end
    end
    table.sort(result)
    return result, nil
  end

  if type(dir) == "function" then
    local ok, iterator = pcall(dir, path)
    if not ok or type(iterator) ~= "function" then
      return {}, nil
    end

    local result = {}
    local seen = {}

    while true do
      local entry, entryAttr = iterator()
      if entry == nil then
        break
      end
      if entry ~= "." and entry ~= ".." then
        local isDirectory = false

        if type(entryAttr) == "table" then
          if entryAttr.mode == "directory" or entryAttr.isdir == true or entryAttr.directory == true then
            isDirectory = true
          end
        end

        if not isDirectory then
          local fullPath = path .. "/" .. entry
          local file = io.open(fullPath, "r")
          if file then
            io.close(file)
          elseif pathExists(fullPath) then
            isDirectory = true
          end
        end

        if isDirectory and not seen[entry] then
          seen[entry] = true
          table.insert(result, entry)
        end
      end
    end

    table.sort(result)
    return result, nil
  end

  return nil, "no_directory_api"
end

local function getRootPathCandidates(rootPath)
  local candidates = {}
  local seen = {}

  local function addCandidate(path)
    if path ~= nil and path ~= "" and not seen[path] then
      seen[path] = true
      table.insert(candidates, path)
    end
  end

  addCandidate(rootPath)
  addCandidate(rootPath:gsub("^/", ""))
  if rootPath:sub(1, 1) ~= "/" then
    addCandidate("/" .. rootPath)
  end

  return candidates
end

local function logDirectoryTree(rootPath, title)
  if not (mapLibs and mapLibs.utils and mapLibs.utils.logDebug) then
    return
  end

  mapLibs.utils.logDebug("SETTINGS", "=== " .. title .. " ===", true)
  local activeRootPath = rootPath
  local providerDirs = nil
  local providerErr = nil

  local candidates = getRootPathCandidates(rootPath)
  for i = 1, #candidates do
    local candidate = candidates[i]
    local dirs, err = getSortedDirectories(candidate)
    if err == nil then
      activeRootPath = candidate
      providerDirs = dirs
      providerErr = nil
      if #dirs > 0 then
        break
      end
    else
      providerErr = err
    end
  end

  mapLibs.utils.logDebug("SETTINGS", activeRootPath, true)

  if providerErr ~= nil then
    mapLibs.utils.logDebug("SETTINGS", "(directory listing unavailable: no filesystem directory API)", true)
    mapLibs.utils.logDebug("SETTINGS", "=== END " .. title .. " ===", true)
    return
  end

  providerDirs = providerDirs or {}
  if #providerDirs == 0 then
    mapLibs.utils.logDebug("SETTINGS", "(empty or missing)", true)
    mapLibs.utils.logDebug("SETTINGS", "=== END " .. title .. " ===", true)
    return
  end

  local normalizedRoot = activeRootPath:gsub("^/", ""):lower()
  local yaapuReducedDepth = normalizedRoot == "bitmaps/yaapu/maps"

  for i = 1, #providerDirs do
    local providerName = providerDirs[i]
    local providerPath = activeRootPath .. "/" .. providerName
    local providerPrefix = (i < #providerDirs) and "|-- " or "`-- "
    local mapTypeIndent = (i < #providerDirs) and "|   " or "    "
    mapLibs.utils.logDebug("SETTINGS", providerPrefix .. providerName .. "/", true)

    if not yaapuReducedDepth then
      local mapTypeDirs = getSortedDirectories(providerPath) or {}
      if #mapTypeDirs == 0 then
        mapLibs.utils.logDebug("SETTINGS", mapTypeIndent .. "(no subfolders)", true)
      else
        for j = 1, #mapTypeDirs do
          local mapTypeName = mapTypeDirs[j]
          local mapTypePrefix = (j < #mapTypeDirs) and "|-- " or "`-- "
          mapLibs.utils.logDebug("SETTINGS", mapTypeIndent .. mapTypePrefix .. mapTypeName .. "/", true)
        end
      end
    end
  end

  mapLibs.utils.logDebug("SETTINGS", "=== END " .. title .. " ===", true)
end

local function logSettingsSnapshot()
  if not (mapLibs and mapLibs.utils and mapLibs.utils.logDebug) then
    return
  end

  mapLibs.utils.logDebug("SETTINGS", "=== SETTINGS SNAPSHOT ===", true)

  local keys = {}
  for key in pairs(mapStatus.conf) do
    table.insert(keys, key)
  end
  table.sort(keys)

  for i = 1, #keys do
    local key = keys[i]
    mapLibs.utils.logDebug("SETTINGS", key .. " = " .. toLogValue(mapStatus.conf[key]), true)
  end

  mapLibs.utils.logDebug("SETTINGS", "=== END SETTINGS SNAPSHOT ===", true)
end

logDebugSessionStart = function(reason)
  if not (mapStatus and mapStatus.conf and configFlagEnabled(mapStatus.conf.enableDebugLog) and mapLibs and mapLibs.utils and mapLibs.utils.logDebug) then
    return
  end
  if mapStatus.sessionLogged then
    return
  end

  -- Mark as logged first so a crash inside snapshot/tree doesn't put us in an infinite retry loop.
  mapStatus.sessionLogged = true

  local marker = "=== DEBUG SESSION STARTED ==="
  if reason and reason ~= "" then
    marker = marker .. " (" .. reason .. ")"
  end

  mapLibs.utils.logDebug("SETTINGS", marker, true)

  if configFlagEnabled(mapStatus.conf.enablePerfProfile) then
    mapLibs.utils.logDebug("PERF", "=== PERF PROFILE ACTIVE (5s windows) ===", true)
  end

  -- Wrap snapshot and tree in pcall so a crash in one doesn't prevent the other from running.
  pcall(logSettingsSnapshot)
  pcall(logDirectoryTree, "/bitmaps/ethosmaps/maps", "FOLDER TREE SNAPSHOT: ethosmaps/maps")
  pcall(logDirectoryTree, "/bitmaps/yaapu/maps", "FOLDER TREE SNAPSHOT: yaapu/maps")
end

local function providerLabelById(providerId)
  if providerId == 0 then
    return "NONE"
  end
  return MAP_PROVIDER_LABELS[providerId] or tostring(providerId)
end

local function mapTypeLabelById(mapTypeId)
  if mapTypeId == 0 then
    return "NONE"
  end
  return MAP_TYPE_LABELS[mapTypeId] or tostring(mapTypeId)
end

local function normalizeLegacyMapTypeIdForProvider(provider, mapTypeId)
  -- Migrate legacy Street id (3) used in earlier ESRI/OSM builds to dedicated Street id (5).
  if (provider == 3 or provider == 4) and mapTypeId == 3 then
    return 5
  end
  return mapTypeId
end

local function ensureAvailableMapSelections()
  local oldProvider = mapStatus.conf.mapProvider
  local oldMapTypeId = mapStatus.conf.mapTypeId

  mapStatus.conf.mapTypeId = normalizeLegacyMapTypeIdForProvider(mapStatus.conf.mapProvider, mapStatus.conf.mapTypeId)

  local providerChoices = getAvailableProviderChoices()
  if not choiceContainsValue(providerChoices, mapStatus.conf.mapProvider) then
    mapStatus.conf.mapProvider = providerChoices[1][2]
  end

  local mapTypeChoices = getAvailableMapTypeChoices(mapStatus.conf.mapProvider)
  if not choiceContainsValue(mapTypeChoices, mapStatus.conf.mapTypeId) then
    mapStatus.conf.mapTypeId = mapTypeChoices[1][2]
  end

  if oldProvider ~= mapStatus.conf.mapProvider or oldMapTypeId ~= mapStatus.conf.mapTypeId then
    local key = string.format("provider:%s->%s|mapType:%s->%s", tostring(oldProvider), tostring(mapStatus.conf.mapProvider), tostring(oldMapTypeId), tostring(mapStatus.conf.mapTypeId))
    if mapStatus.lastSelectionAutoFixKey ~= key then
      logMapSelectionAutofix("Auto-adjusted map selection because configured provider/map type folders are not available (" .. key .. ")")
      mapStatus.lastSelectionAutoFixKey = key
    end
  end

  return providerChoices, mapTypeChoices
end

local function applyConfig()
  -- Derives labels, unit multipliers, and active zoom limits from persisted settings and writes them into mapStatus.conf.
  ensureAvailableMapSelections()

  mapStatus.conf.horSpeedLabel = applyDefault(mapStatus.conf.horSpeedUnit, 1, {"m/s", "km/h", "mph", "kn"})
  mapStatus.conf.vertSpeedLabel = applyDefault(mapStatus.conf.vertSpeedUnit, 1, {"m/s", "ft/s", "ft/min"})
  mapStatus.conf.distUnitLabel = applyDefault(mapStatus.conf.distUnit, 1, {"m", "ft"})
  mapStatus.conf.distUnitLongLabel = applyDefault(mapStatus.conf.distUnitLong, 1, {"km", "mi"})

  mapStatus.conf.horSpeedMultiplier = applyDefault(mapStatus.conf.horSpeedUnit, 1, {1, 3.6, 2.23694, 1.94384})
  mapStatus.conf.vertSpeedMultiplier = applyDefault(mapStatus.conf.vertSpeedUnit, 1, {1, 3.28084, 196.85})
  mapStatus.conf.distUnitScale = applyDefault(mapStatus.conf.distUnit, 1, {1, 3.28084})
  mapStatus.conf.distUnitLongScale = applyDefault(mapStatus.conf.distUnitLong, 1, {1/1000, 1/1609.34})

  if mapStatus.conf.mapProvider == 0 or mapStatus.conf.mapTypeId == 0 then
    mapStatus.conf.mapType = "NONE"
  else
    mapStatus.conf.mapType = getMapTypeFolder(mapStatus.conf.mapProvider, mapStatus.conf.mapTypeId) or "NONE"
  end

  if mapStatus.conf.mapProvider == 0 then
    mapStatus.mapZoomLevel = math.max(1, mapStatus.conf.mapZoomMin or 1)
  else
    local min = mapStatus.conf.mapZoomMin or 1
    local max = mapStatus.conf.mapZoomMax or 20
    local def = mapStatus.conf.mapZoomDefault or 18

    local availableMin, availableMax = getAvailableZoomBounds(mapStatus.conf.mapProvider, mapStatus.conf.mapTypeId)
    if availableMin ~= nil and availableMax ~= nil then
      min = math.max(min, availableMin)
      max = math.min(max, availableMax)
      if max < min then
        min = availableMin
        max = availableMax
      end
      mapStatus.conf.mapZoomMin = min
      mapStatus.conf.mapZoomMax = max
    end

    if max < min then
      max = min
      mapStatus.conf.mapZoomMax = max
    end
    if def < min then
      def = min
    elseif def > max then
      def = max
    end

    mapStatus.conf.mapZoomDefault = def
    mapStatus.mapZoomLevel = def
  end
end

local function configure(widget)
  -- Builds the Ethos configuration form, reading current values from mapStatus.conf and writing user edits back into it.
  if not widget then return end -- Safeguard: configuration callbacks may arrive before the widget fields exist.
  local providerChoices, mapTypeChoices = ensureAvailableMapSelections()

  local line = form.addLine("Widget version")
  form.addStaticText(line, nil, "1.0.0 beta4")

  line = form.addLine("Link quality source")
  form.addSourceField(line, nil, function() return mapStatus.conf.linkQualitySource end, function(value) mapStatus.conf.linkQualitySource = value end)

  line = form.addLine("User sensor 1")
  form.addSourceField(line, nil, function() return mapStatus.conf.userSensor1 end, function(value) mapStatus.conf.userSensor1 = value end)

  line = form.addLine("User sensor 2")
  form.addSourceField(line, nil, function() return mapStatus.conf.userSensor2 end, function(value) mapStatus.conf.userSensor2 = value end)

  line = form.addLine("User sensor 3")
  form.addSourceField(line, nil, function() return mapStatus.conf.userSensor3 end, function(value) mapStatus.conf.userSensor3 = value end)

  line = form.addLine("Airspeed/Groundspeed unit")
  form.addChoiceField(line, form.getFieldSlots(line)[0], {{"m/s",1},{"km/h",2},{"mph",3},{"kn",4}}, function() return mapStatus.conf.horSpeedUnit end, function(value) mapStatus.conf.horSpeedUnit = value end)

  line = form.addLine("Vertical speed unit")
  form.addChoiceField(line, form.getFieldSlots(line)[0], {{"m/s",1},{"ft/s",2},{"ft/min",3}}, function() return mapStatus.conf.vertSpeedUnit end, function(value) mapStatus.conf.vertSpeedUnit = value end)

  line = form.addLine("Altitude/Distance unit")
  form.addChoiceField(line, form.getFieldSlots(line)[0], {{"m",1},{"ft",2}}, function() return mapStatus.conf.distUnit end, function(value) mapStatus.conf.distUnit = value end)

  line = form.addLine("Long distance unit")
  form.addChoiceField(line, form.getFieldSlots(line)[0], {{"km",1},{"mi",2}}, function() return mapStatus.conf.distUnitLong end, function(value) mapStatus.conf.distUnitLong = value end)

  line = form.addLine("GPS coordinates format")
  form.addChoiceField(line, form.getFieldSlots(line)[0], {{"DMS",1},{"Decimal",2}}, function() return mapStatus.conf.gpsFormat end, function(value) mapStatus.conf.gpsFormat = value end)

  -- Provider selection drives which zoom controls are enabled below.
  line = form.addLine("Map provider")
  widget.mapProviderField = form.addChoiceField(line, form.getFieldSlots(line)[0], providerChoices, function() return mapStatus.conf.mapProvider end,
    function(value)
      local oldProvider = mapStatus.conf.mapProvider
      mapStatus.conf.mapProvider = value
      mapStatus.conf.mapTypeId = normalizeLegacyMapTypeIdForProvider(value, mapStatus.conf.mapTypeId)

      if oldProvider ~= value then
        logMapSelectionAutofix("Provider changed: " .. providerLabelById(oldProvider) .. " -> " .. providerLabelById(value))
      end

      -- Force a fresh scan for provider/map type availability when provider changes.
      -- This avoids stale settings choices and prevents temporary "???" labels.
      invalidateAvailabilityCaches()
      local _, oldMapTypeId = syncMapTypeChoicesForProvider(widget, value, true)
      local mapTypeAdjusted = oldMapTypeId ~= mapStatus.conf.mapTypeId
      if oldMapTypeId ~= mapStatus.conf.mapTypeId then
        logMapSelectionAutofix("Map type adjusted after provider change: " .. mapTypeLabelById(oldMapTypeId) .. " -> " .. mapTypeLabelById(mapStatus.conf.mapTypeId))
      end
      applyConfig()

      -- Rebuild the settings form only when the previous map type became invalid and had to fallback.
      if mapTypeAdjusted then
        local rebuilt = false
        if (not configRebuildInProgress) and form ~= nil and type(form.clear) == "function" then
          configRebuildInProgress = true
          local cleared = pcall(form.clear)
          if cleared then
            local configured = pcall(configure, widget)
            rebuilt = configured
          end
          configRebuildInProgress = false
          if rebuilt then
            return
          end
        end

        -- Fallback for Ethos variants without form.clear().
        local refreshed = false
        if not rebuilt then
          refreshed = refreshConfigureForm()
        end
        if not refreshed and configFlagEnabled(mapStatus.conf.enableDebugLog) then
          logMapSelectionAutofix("Form refresh API unavailable after map type fallback; choices may update only after reopening settings")
        end
      end

      if widget.mapZoomField ~= nil then
        widget.mapZoomField:enable(value ~= 0)
      end
      if widget.mapZoomMaxField ~= nil then
        widget.mapZoomMaxField:enable(value ~= 0)
      end
      if widget.mapZoomMinField ~= nil then
        widget.mapZoomMinField:enable(value ~= 0)
      end
    end
  )
  widget.mapProviderField:enable(not (#providerChoices == 1 and providerChoices[1][2] == 0))

  line = form.addLine("Map type")
  widget.mapTypeChoices = {}
  replaceChoices(widget.mapTypeChoices, mapTypeChoices)
  widget.mapTypeField = form.addChoiceField(line, form.getFieldSlots(line)[0], widget.mapTypeChoices, function() return mapStatus.conf.mapTypeId end,
    function(value)
      local oldMapTypeId = mapStatus.conf.mapTypeId
      mapStatus.conf.mapTypeId = value
      if oldMapTypeId ~= value then
        logMapSelectionAutofix("Map type changed: " .. mapTypeLabelById(oldMapTypeId) .. " -> " .. mapTypeLabelById(value))
        applyConfig()
      end
    end
  )
  widget.mapTypeField:enable(mapStatus.conf.mapProvider ~= 0)
  syncMapTypeChoicesForProvider(widget, mapStatus.conf.mapProvider, false)

  line = form.addLine("Trail length")
  form.addChoiceField(line, form.getFieldSlots(line)[0],
    {{"Off", 0}, {"1 km", 1}, {"5 km", 5}, {"10 km", 10}, {"25 km", 25}, {"50 km", 50}},
    function() return mapStatus.conf.mapTrailLength end,
    function(value) mapStatus.conf.mapTrailLength = value end
  )

  line = form.addLine("Map zoom")
  widget.mapZoomField = form.addNumberField(line, nil, 1, 20,
    function()
      widget.mapZoomField:enable(mapStatus.conf.mapProvider ~= 0)
      return mapStatus.conf.mapZoomDefault
    end,
    function(value)
      local min = mapStatus.conf.mapZoomMin or 1
      local max = mapStatus.conf.mapZoomMax or 20
      if value < min then
        value = min
      elseif value > max then
        value = max
      end
      mapStatus.conf.mapZoomDefault = value
    end
  )

  line = form.addLine("Map zoom max")
  widget.mapZoomMaxField = form.addNumberField(line, nil, 1, 20,
    function()
      widget.mapZoomMaxField:enable(mapStatus.conf.mapProvider ~= 0)
      return mapStatus.conf.mapZoomMax
    end,
    function(value)
      -- Keep unified zoom range valid and clamp default zoom into that range.
      local min = mapStatus.conf.mapZoomMin or 1
      if value < min then
        value = min
      end
      mapStatus.conf.mapZoomMax = value
      local def = mapStatus.conf.mapZoomDefault
      if def == nil then
        def = value
      end
      if def < min then
        def = min
      elseif def > value then
        def = value
      end
      mapStatus.conf.mapZoomDefault = def
    end
  )

  line = form.addLine("Map zoom min")
  widget.mapZoomMinField = form.addNumberField(line, nil, 1, 20,
    function()
      widget.mapZoomMinField:enable(mapStatus.conf.mapProvider ~= 0)
      return mapStatus.conf.mapZoomMin
    end,
    function(value)
      -- Keep unified zoom range valid and clamp default zoom into that range.
      local max = mapStatus.conf.mapZoomMax or 20
      if value > max then
        value = max
      end
      mapStatus.conf.mapZoomMin = value
      local def = mapStatus.conf.mapZoomDefault
      if def == nil then
        def = value
      end
      if def < value then
        def = value
      elseif def > max then
        def = max
      end
      mapStatus.conf.mapZoomDefault = def
    end
  )

  -- Debug logging is opt-in because writes go to the SD card during runtime.
  line = form.addLine("Enable debug log")
  widget.enableDebugLogField = form.addBooleanField(line, nil, 
    function() return configFlagEnabled(mapStatus.conf.enableDebugLog) end, 
    function(value) 
      local previous = configFlagEnabled(mapStatus.conf.enableDebugLog)

      if value and not previous then
        mapStatus.conf.enableDebugLog = true
        mapStatus.sessionLogged = false
        logDebugSessionStart("debug enabled")
      elseif (not value) and previous then
        if mapLibs and mapLibs.utils and mapLibs.utils.logDebug then
          mapLibs.utils.logDebug("SETTINGS", "=== DEBUG LOG DISABLED ===", true)
        end
        mapStatus.conf.enableDebugLog = false
        mapStatus.sessionLogged = false
      else
        mapStatus.conf.enableDebugLog = value
      end

      -- Toggle perf profile field visibility based on debug log state
      if widget.enablePerfProfileField ~= nil then
        widget.enablePerfProfileField:enable(configFlagEnabled(value))
      end
    end
  )

  line = form.addLine("Enable perf profile (5s)")
  widget.enablePerfProfileField = form.addBooleanField(line, nil,
    function() return configFlagEnabled(mapStatus.conf.enablePerfProfile) end,
    function(value)
      local previous = configFlagEnabled(mapStatus.conf.enablePerfProfile)
      local enabled = configFlagEnabled(value)
      mapStatus.conf.enablePerfProfile = value

      if enabled and not previous then
        perfWindowStartMs = nil
        mapStatus.perfProfile.windowStartMs = 0
        if mapLibs and mapLibs.utils and mapLibs.utils.logDebug then
          mapLibs.utils.logDebug("PERF", "=== PERF PROFILE ENABLED (5s windows) ===", true)
        end
      elseif (not enabled) and previous then
        if mapLibs and mapLibs.utils and mapLibs.utils.logDebug then
          mapLibs.utils.logDebug("PERF", "=== PERF PROFILE DISABLED ===", true)
        end
      end
    end
  )
  -- Only show perf profile option when debug logging is enabled.
  widget.enablePerfProfileField:enable(configFlagEnabled(mapStatus.conf.enableDebugLog))

end

local function read(widget)
  if not widget then return end -- Safeguard: Ethos can call before a widget instance is fully available.
  -- Loads persisted widget settings from storage into the widget instance and shared config table.
  mapStatus.conf.horSpeedUnit = storageToConfig("horSpeedUnit", 1)
  mapStatus.conf.vertSpeedUnit = storageToConfig("vertSpeedUnit",1)
  mapStatus.conf.distUnit = storageToConfig("distUnit", 1)
  mapStatus.conf.distUnitLong = storageToConfig("distUnitLong", 1)
  mapStatus.conf.gpsFormat = storageToConfig("gpsFormat", 2)
  mapStatus.conf.mapProvider = storageToConfig("mapProvider", 2)
  mapStatus.conf.mapTypeId = storageToConfig("mapTypeId", 1)
  mapStatus.conf.mapZoomDefault = storageToConfigWithFallback("mapZoomDefault", 18, {"googleZoomDefault", "gmapZoomDefault"})
  mapStatus.conf.mapZoomMin = storageToConfigWithFallback("mapZoomMin", 1, {"googleZoomMin", "gmapZoomMin"})
  mapStatus.conf.mapZoomMax = storageToConfigWithFallback("mapZoomMax", 20, {"googleZoomMax", "gmapZoomMax"})
  mapStatus.conf.enableDebugLog = storageToConfig("enableDebugLog", false)
  mapStatus.conf.enablePerfProfile = storageToConfig("enablePerfProfile", false)
  mapStatus.conf.mapTrailLength = storageToConfig("mapTrailLength", 5)
  mapStatus.conf.linkQualitySource = storageToConfig("linkQualitySource", nil)
  mapStatus.conf.userSensor1 = storageToConfig("userSensor1", nil)
  mapStatus.conf.userSensor2 = storageToConfig("userSensor2", nil)
  mapStatus.conf.userSensor3 = storageToConfig("userSensor3", nil)

  applyConfig()
end

local function write(widget)
  if not widget then return end -- Safeguard: Ethos can call before a widget instance is fully available.
  -- Persists the current widget settings to storage, reapplies derived config values, and resets the active layout.
  storage.write("horSpeedUnit", mapStatus.conf.horSpeedUnit)
  storage.write("vertSpeedUnit", mapStatus.conf.vertSpeedUnit)
  storage.write("distUnit", mapStatus.conf.distUnit)
  storage.write("distUnitLong", mapStatus.conf.distUnitLong)
  storage.write("gpsFormat", mapStatus.conf.gpsFormat)
  storage.write("mapProvider", mapStatus.conf.mapProvider)
  storage.write("mapTypeId", mapStatus.conf.mapTypeId)
  storage.write("mapZoomDefault", mapStatus.conf.mapZoomDefault)
  storage.write("mapZoomMin", mapStatus.conf.mapZoomMin)
  storage.write("mapZoomMax", mapStatus.conf.mapZoomMax)
  storage.write("enableDebugLog", mapStatus.conf.enableDebugLog)
  storage.write("enablePerfProfile", mapStatus.conf.enablePerfProfile)
  storage.write("mapTrailLength", mapStatus.conf.mapTrailLength)
  storage.write("linkQualitySource", mapStatus.conf.linkQualitySource)
  storage.write("userSensor1", mapStatus.conf.userSensor1)
  storage.write("userSensor2", mapStatus.conf.userSensor2)
  storage.write("userSensor3", mapStatus.conf.userSensor3)

  applyConfig()
  mapLibs.resetLib.resetLayout(widget)
end

local function registerSources()
  -- Registers exported telemetry sources so other Ethos widgets can read values computed by this widget.
  system.registerSource({
    key="YM_HOME",
    name="HomeDistance",
    init=makeSourceInit("HomeDistance"),
    wakeup=makeSourceWakeup("HomeDistance")
  })
  system.registerSource({
    key="YM_GSPD",
    name="GroundSpeed",
    init=makeSourceInit("GroundSpeed"),
    wakeup=makeSourceWakeup("GroundSpeed")
  })
  system.registerSource({
    key="YM_COG",
    name="CourseOverGround",
    init=makeSourceInit("CourseOverGround"),
    wakeup=makeSourceWakeup("CourseOverGround")
  })
end

local function init()
  -- Registers the widget lifecycle callbacks and exported sources with Ethos during radio startup.
  system.registerWidget({key="ethosmw", name="ETHOS Mapping Widget", paint=paint, event=event, wakeup=wakeup, create=create, configure=configure, menu=menu, read=read, write=write })
  registerSources()
end

return {init=init}