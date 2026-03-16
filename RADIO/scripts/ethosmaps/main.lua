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
  -- Converts Lua CPU time into centiseconds so widget callbacks can share one timing base for throttling and animations.
  return os.clock()*100
end


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
    mapType = "GoogleSatelliteMap",
    mapZoomLevel = 19,
    mapZoomMax = 20,
    mapZoomMin = 1,
    mapTrailDots = 30,
    enableMapGrid = true,
    enableDebugLog = false,   -- Enables the on-device debug log.
    screenToggleChannelId = 0,
    screenWheelChannelId = 0,
    screenWheelChannelDelay = 20,
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
  lastLoggedLat = 0,
  lastLoggedLon = 0,

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
  sessionLogged = false,
}


-- Maps exported source names to default values, formatting metadata, and the telemetry field they mirror.
mapStatus.luaSourcesConfig = {}
mapStatus.luaSourcesConfig.HomeDistance =  {0, 0, UNIT_METER, "homeDist", 1}
mapStatus.luaSourcesConfig.CourseOverGround =  {0, 0, UNIT_DEGREE, "cog", 1}
mapStatus.luaSourcesConfig.GroundSpeed =  {0, 1, UNIT_METER_PER_SECOND, "groundSpeed", 1}

local function sourceWakeup(source)
  -- Pushes cached telemetry values from mapStatus into registered Ethos sources so other widgets can consume them.
  if source ~= nil then
    local v = mapStatus.luaSourcesConfig[source:name()]
    if v[2] == 0 then
      source:value(tonumber(mapStatus.telemetry[v[4]])==nil and 0 or math.floor(0.5 + mapStatus.telemetry[v[4]] * v[5]))
    else
      source:value(tonumber(mapStatus.telemetry[v[4]])==nil and 0 or (mapStatus.telemetry[v[4]] * v[5]))
    end
  end
end

local mapLibs = {
  drawLib = nil,
  resetLib = nil,
  mapLib = nil,
  utils = nil,
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
  if mapLibs.utils == nil then mapLibs.utils = loadLib("utils") end
  if mapLibs.drawLib == nil then mapLibs.drawLib = loadLib("drawlib") end
  if mapLibs.resetLib == nil then mapLibs.resetLib = loadLib("resetLib") end
  if mapLibs.mapLib == nil then mapLibs.mapLib = loadLib("maplib") end
end

local function checkSize(widget)
  -- Refreshes widget dimensions from the active LCD window and writes the derived scale back into mapStatus.
  local w, h = lcd.getWindowSize()
  mapStatus.widgetWidth = w
  mapStatus.widgetHeight = h
  mapStatus.scaleX = w / 800
  mapStatus.scaleY = h / 480
  text_w, text_h = lcd.getTextSize("")
  lcd.font(FONT_STD)
  lcd.drawText(w/2, (h - text_h)/2, w.." x "..h.." (scale "..string.format("%.2f",mapStatus.scaleX).."x"..string.format("%.2f",mapStatus.scaleY)..")", CENTERED)
  return true
end

local function createOnce(widget)
  -- Marks a widget instance as ready for background processing after the first valid lifecycle callback.
  widget.runBgTasks = true
end

local function reset(widget)
  -- Delegates a user-triggered reset to resetLib so layouts and cached map data are rebuilt.
  mapLibs.resetLib.reset(widget)
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
  local gpsSrcLat = system.getSource({name="GPS", options=OPTION_LATITUDE})
  local gpsSrcLon = system.getSource({name="GPS", options=OPTION_LONGITUDE})
  local gpsData = {}
  gpsData.lat = gpsSrcLat and gpsSrcLat:value() or nil
  gpsData.lon = gpsSrcLon and gpsSrcLon:value() or nil
  if gpsData.lat ~= nil and gpsData.lon ~= nil then
    mapStatus.telemetry.lat = gpsData.lat
    mapStatus.telemetry.lon = gpsData.lon

    -- Log GPS changes only when the debug logger is enabled and the utility library is available.
    if mapStatus and mapStatus.conf and mapStatus.conf.enableDebugLog and mapLibs and mapLibs.utils then -- Safeguard: avoid logger access before config and libraries are initialized.
      local lat = mapStatus.telemetry.lat or 0
      local lon = mapStatus.telemetry.lon or 0
    
      if lat ~= (mapStatus.lastLoggedLat or 0) or lon ~= (mapStatus.lastLoggedLon or 0) then
        mapLibs.utils.logDebug("GPS", string.format("lat=%.6f lon=%.6f", lat, lon))
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
      mapStatus.layout[widget.screen].draw(widget)
    else
      loadLayout(widget)
    end
  end

  if not gpsDataAvailable(mapStatus.telemetry.lat, mapStatus.telemetry.lon) then
    mapLibs.drawLib.drawNoGPSData(widget)
  end
end

local function event(widget, category, value, x, y)
  -- Handles touch input from Ethos, updates zoom state, and consumes handled events before they reach other UI code.
  local kill = false

  -- Logs raw touch data when debug logging is active.
  if mapStatus and mapStatus.conf and mapStatus.conf.enableDebugLog and mapLibs and mapLibs.utils and category == EVT_TOUCH then -- Safeguard: only log once settings and logger references exist.
    mapLibs.utils.logDebug("TOUCH", string.format("value=%d x=%d y=%d", value, x, y))
  end

  if category == EVT_TOUCH and value == 16641 then
    kill = true
    local rightX = mapStatus.widgetWidth * 0.80
    if mapLibs.drawLib.isInside(x, y, rightX, 0, mapStatus.widgetWidth, mapStatus.widgetHeight/2) then
      mapStatus.mapZoomLevel = math.min(mapStatus.conf.mapZoomMax, mapStatus.mapZoomLevel+1)
    elseif mapLibs.drawLib.isInside(x, y, rightX, mapStatus.widgetHeight/2, mapStatus.widgetWidth, mapStatus.widgetHeight) then
      mapStatus.mapZoomLevel = math.max(mapStatus.conf.mapZoomMin, mapStatus.mapZoomLevel-1)
    else
      kill = false
    end
  end
  if kill then
    system.killEvents(value)
    return true
  end
  return false
end

local function setHome(widget)
  -- Copies the current aircraft position from telemetry into the stored home position used by map overlays.
  mapStatus.telemetry.homeLat = mapStatus.telemetry.lat
  mapStatus.telemetry.homeLon = mapStatus.telemetry.lon
end

local function menu(widget)
  -- Builds the widget context menu from the current telemetry state and dispatches actions back into shared status.
  if mapStatus.telemetry.lat ~= nil and mapStatus.telemetry.lon ~= nil then
    return {
      { "Maps: Reset", function() reset(widget) end },
      { "Maps: Set Home", function() setHome(widget) end },
      { "Maps: Zoom in", function() mapStatus.mapZoomLevel = math.min(mapStatus.conf.mapZoomMax, mapStatus.mapZoomLevel+1) end},
      { "Maps: Zoom out", function() mapStatus.mapZoomLevel = math.max(mapStatus.conf.mapZoomMin, mapStatus.mapZoomLevel-1) end},
    }
  end
  return { { "Maps: Reset", function() reset(widget) end } }
end

local function wakeup(widget)
  -- Runs recurring background work between paint calls and invalidates the LCD so Ethos schedules a redraw.
  if not widget then return end -- Safeguard: Ethos can schedule wakeup before the widget handle is ready.
  local now = getTime()

  if mapStatus.initPending then
    createOnce(widget)
    mapStatus.initPending = false
  end

  if widget.runBgTasks then
    bgtasks(widget)
  end

  lcd.invalidate()   
end

local function create()
  -- Creates a fresh widget instance, initializes shared libraries, and returns the per-instance state table to Ethos.
  if not mapStatus.initPending then
    mapStatus.initPending = true
  end

  initLibs()

  -- Emit a visible session marker once so each debug log session has a clear start record.
  if mapStatus.conf.enableDebugLog and mapLibs and mapLibs.utils and not mapStatus.sessionLogged then
    mapLibs.utils.logDebug("SETTINGS", "=== DEBUG SESSION STARTED ===")
    mapStatus.sessionLogged = true
  end

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

local function configToStorage(value, lookup)
  -- Converts an in-memory config value back into the stored lookup index when persistence needs it.
  if lookup == nil then return value end
  for i=1,#lookup do
    if lookup[i] == value then return i end
  end
  return 1
end

local function applyConfig()
  -- Derives labels, unit multipliers, and active zoom limits from persisted settings and writes them into mapStatus.conf.
  mapStatus.conf.horSpeedLabel = applyDefault(mapStatus.conf.horSpeedUnit, 1, {"m/s", "km/h", "mph", "kn"})
  mapStatus.conf.vertSpeedLabel = applyDefault(mapStatus.conf.vertSpeedUnit, 1, {"m/s", "ft/s", "ft/min"})
  mapStatus.conf.distUnitLabel = applyDefault(mapStatus.conf.distUnit, 1, {"m", "ft"})
  mapStatus.conf.distUnitLongLabel = applyDefault(mapStatus.conf.distUnitLong, 1, {"km", "mi"})

  mapStatus.conf.horSpeedMultiplier = applyDefault(mapStatus.conf.horSpeedUnit, 1, {1, 3.6, 2.23694, 1.94384})
  mapStatus.conf.vertSpeedMultiplier = applyDefault(mapStatus.conf.vertSpeedUnit, 1, {1, 3.28084, 196.85})
  mapStatus.conf.distUnitScale = applyDefault(mapStatus.conf.distUnit, 1, {1, 3.28084})
  mapStatus.conf.distUnitLongScale = applyDefault(mapStatus.conf.distUnitLong, 1, {1/1000, 1/1609.34})

  mapStatus.conf.mapType = applyDefault(mapStatus.conf.mapTypeId, 1, mapStatus.conf.mapProvider == 1 and {"sat_tiles","tiles","tiles","ter_tiles"} or {"GoogleSatelliteMap","GoogleHybridMap","GoogleMap","GoogleTerrainMap"})

  if mapStatus.conf.mapProvider == 1 then
    mapStatus.mapZoomLevel = mapStatus.conf.gmapZoomDefault
    mapStatus.conf.mapZoomMin = mapStatus.conf.gmapZoomMin
    mapStatus.conf.mapZoomMax = mapStatus.conf.gmapZoomMax
  else
    mapStatus.mapZoomLevel = mapStatus.conf.googleZoomDefault
    mapStatus.conf.mapZoomMin = mapStatus.conf.googleZoomMin
    mapStatus.conf.mapZoomMax = mapStatus.conf.googleZoomMax
  end
end

local function configure(widget)
  -- Builds the Ethos configuration form, reading current values from mapStatus.conf and writing user edits back into it.
  if not widget then return end -- Safeguard: configuration callbacks may arrive before the widget fields exist.
  local line = form.addLine("Widget version")
  form.addStaticText(line, nil, "1.0.0 beta2")

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
  form.addChoiceField(line, form.getFieldSlots(line)[0], {{"GMapCatcher", 1}, {"Google", 2}}, function() return mapStatus.conf.mapProvider end,
    function(value)
      mapStatus.conf.mapProvider = value
      widget.googleZoomField:enable(value==2)
      widget.googleZoomMaxField:enable(value==2)
      widget.googleZoomMinField:enable(value==2)
      widget.gmapZoomField:enable(value==1)
      widget.gmapZoomMaxField:enable(value==1)
      widget.gmapZoomMinField:enable(value==1)
    end
  )

  line = form.addLine("Map type")
  form.addChoiceField(line, form.getFieldSlots(line)[0], {{"Satellite",1},{"Hybrid",2},{"Map",3},{"Terrain",4}}, function() return mapStatus.conf.mapTypeId end, function(value) mapStatus.conf.mapTypeId = value end)

  -- Provider-specific zoom fields stay in sync with the current provider selection.
  line = form.addLine("Google zoom")
  widget.googleZoomField = form.addNumberField(line, nil, 1, 20,
    function()
      widget.googleZoomField:enable(mapStatus.conf.mapProvider==2)
      return mapStatus.conf.googleZoomDefault
    end,
    function(value) mapStatus.conf.googleZoomDefault = value end
  )

  line = form.addLine("Google zoom max")
  widget.googleZoomMaxField = form.addNumberField(line, nil, 1, 20,
    function()
      widget.googleZoomMaxField:enable(mapStatus.conf.mapProvider==2)
      return mapStatus.conf.googleZoomMax
    end,
    function(value)
      -- Keep the Google zoom range valid and clamp the default zoom back into that range.
      local min = mapStatus.conf.googleZoomMin or 1
      if value < min then
        value = min
      end
      mapStatus.conf.googleZoomMax = value
      local def = mapStatus.conf.googleZoomDefault
      if def == nil then
        def = value
      end
      if def < min then
        def = min
      elseif def > value then
        def = value
      end
      mapStatus.conf.googleZoomDefault = def
    end
  )

  line = form.addLine("Google zoom min")
  widget.googleZoomMinField = form.addNumberField(line, nil, 1, 20,
    function()
      widget.googleZoomMinField:enable(mapStatus.conf.mapProvider==2)
      return mapStatus.conf.googleZoomMin
    end,
    function(value)
      -- Keep the Google zoom range valid and clamp the default zoom back into that range.
      local max = mapStatus.conf.googleZoomMax or 20
      if value > max then
        value = max
      end
      mapStatus.conf.googleZoomMin = value
      local def = mapStatus.conf.googleZoomDefault
      if def == nil then
        def = value
      end
      if def < value then
        def = value
      elseif def > max then
        def = max
      end
      mapStatus.conf.googleZoomDefault = def
    end
  )

  line = form.addLine("GMapCatcher zoom")
  widget.gmapZoomField = form.addNumberField(line, nil, -2, 17,
    function()
      widget.gmapZoomField:enable(mapStatus.conf.mapProvider==1)
      return mapStatus.conf.gmapZoomDefault
    end,
    function(value) mapStatus.conf.gmapZoomDefault = value end
  )

  line = form.addLine("GMapCatcher zoom max")
  widget.gmapZoomMaxField = form.addNumberField(line, nil, -2, 17,
    function()
      widget.gmapZoomMaxField:enable(mapStatus.conf.mapProvider==1)
      return mapStatus.conf.gmapZoomMax
    end,
    function(value)
      -- Keep the GMapCatcher zoom range valid and clamp the default zoom back into that range.
      local min = mapStatus.conf.gmapZoomMin
      if min ~= nil and value < min then
        value = min
      end
      mapStatus.conf.gmapZoomMax = value
      local def = mapStatus.conf.gmapZoomDefault
      if def ~= nil then
        if min ~= nil and def < min then
          def = min
        end
        if def > value then
          def = value
        end
        mapStatus.conf.gmapZoomDefault = def
      end
    end
  )

  line = form.addLine("GMapCatcher zoom min")
  widget.gmapZoomMinField = form.addNumberField(line, nil, -2, 17,
    function()
      widget.gmapZoomMinField:enable(mapStatus.conf.mapProvider==1)
      return mapStatus.conf.gmapZoomMin
    end,
    function(value)
      -- Keep the GMapCatcher minimum, maximum, and default zoom values consistent.
      local max = mapStatus.conf.gmapZoomMax
      if max ~= nil and value > max then
        max = value
        mapStatus.conf.gmapZoomMax = max
      end
      mapStatus.conf.gmapZoomMin = value
      local def = mapStatus.conf.gmapZoomDefault
      if def ~= nil then
        if def < value then
          def = value
        end
        if max ~= nil and def > max then
          def = max
        end
        mapStatus.conf.gmapZoomDefault = def
      end
    end
  )

  line = form.addLine("Enable map grid")
  form.addBooleanField(line, nil, function() return mapStatus.conf.enableMapGrid end, function(value) mapStatus.conf.enableMapGrid = value end)

  -- Debug logging is opt-in because writes go to the SD card during runtime.
  line = form.addLine("Enable debug log")
  form.addBooleanField(line, nil, 
    function() return mapStatus.conf.enableDebugLog end, 
    function(value) 
      mapStatus.conf.enableDebugLog = value
      
      -- Only log the transition to enabled because logging cannot record its own disabled state.
      if mapLibs and mapLibs.utils and value then
        mapLibs.utils.logDebug("SETTINGS", "=== DEBUG LOG ENABLED ===")
      end
    end
  )

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
  mapStatus.conf.googleZoomDefault = storageToConfig("googleZoomDefault", 18)
  mapStatus.conf.googleZoomMin = storageToConfig("googleZoomMin", 1)
  mapStatus.conf.googleZoomMax = storageToConfig("googleZoomMax", 20)
  mapStatus.conf.gmapZoomDefault = storageToConfig("gmapZoomDefault", 0)
  mapStatus.conf.gmapZoomMin = storageToConfig("gmapZoomMin", -2)
  mapStatus.conf.gmapZoomMax = storageToConfig("gmapZoomMax", 17)
  mapStatus.conf.enableMapGrid = storageToConfig("enableMapGrid", true)
  mapStatus.conf.enableDebugLog = storageToConfig("enableDebugLog", false)
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
  storage.write("googleZoomDefault", mapStatus.conf.googleZoomDefault)
  storage.write("googleZoomMin", mapStatus.conf.googleZoomMin)
  storage.write("googleZoomMax", mapStatus.conf.googleZoomMax)
  storage.write("gmapZoomDefault", mapStatus.conf.gmapZoomDefault)
  storage.write("gmapZoomMin", mapStatus.conf.gmapZoomMin)
  storage.write("gmapZoomMax", mapStatus.conf.gmapZoomMax)
  storage.write("enableMapGrid", mapStatus.conf.enableMapGrid)
  storage.write("enableDebugLog", mapStatus.conf.enableDebugLog)
  storage.write("linkQualitySource", mapStatus.conf.linkQualitySource)
  storage.write("userSensor1", mapStatus.conf.userSensor1)
  storage.write("userSensor2", mapStatus.conf.userSensor2)
  storage.write("userSensor3", mapStatus.conf.userSensor3)

  applyConfig()
  mapLibs.resetLib.resetLayout(widget)
end

local function sourceInit(source)
  -- Seeds each exported Ethos source with formatting metadata from luaSourcesConfig before wakeup updates its value.
  source:value(mapStatus.luaSourcesConfig[source:name()][1])
  source:decimals(mapStatus.luaSourcesConfig[source:name()][2])
  source:unit(mapStatus.luaSourcesConfig[source:name()][3])
end

local function registerSources()
  -- Registers exported telemetry sources so other Ethos widgets can read values computed by this widget.
  system.registerSource({key="YM_HOME", name="HomeDistance", init=sourceInit, wakeup=sourceWakeup})
  system.registerSource({key="YM_GSPD", name="GroundSpeed", init=sourceInit, wakeup=sourceWakeup})
  system.registerSource({key="YM_COG", name="CourseOverGround", init=sourceInit, wakeup=sourceWakeup})
end

local function init()
  -- Registers the widget lifecycle callbacks and exported sources with Ethos during radio startup.
  system.registerWidget({key="ethosmw", name="ETHOS Mapping Widget", paint=paint, event=event, wakeup=wakeup, create=create, configure=configure, menu=menu, read=read, write=write })
  registerSources()
end

return {init=init}