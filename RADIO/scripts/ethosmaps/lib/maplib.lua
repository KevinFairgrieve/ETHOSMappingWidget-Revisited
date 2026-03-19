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
  -- Converts Lua CPU time into centiseconds so map throttling uses the same timing base as the widget.
  return os.clock()*100
end

local mapLib = {}

local status = nil
local libs = nil

-- Global map geometry constants and runtime state shared across draw calls.
local MAP_X = 0
local MAP_Y = 0
local DIST_SAMPLES = 10

-- Cached map support state for tiles, screen coordinates, trail history, and redraw throttling.
local posUpdated = false
local myScreenX, myScreenY
local homeScreenX, homeScreenY
local estimatedHomeScreenX, estimatedHomeScreenY
local tile_x, tile_y, offset_x, offset_y
local tiles = {}
local tiles_path_to_idx = {} -- Maps tile file paths back to their active slot in the visible tile grid.
local mapBitmapByPath = {}
local nomap = nil
local lastNoTilesLogKey = nil
local lastTileFormatLogByKey = {}
local world_tiles
local tiles_per_radian
local tile_dim
local scaleLen
local scaleLabel
local posHistory = {}
local homeNeedsRefresh = true
local sample = 0
local sampleCount = 0
local lastPosUpdate = getTime()
local lastPosSample = getTime()
local lastHomePosUpdate = getTime()
local lastZoomLevel = -99
local lastMapProvider = -99
local estimatedHomeGps = {
  lat = nil,
  lon = nil
}
local drawOffsetX = 0
local drawOffsetY = 0

local lastProcessCycle = getTime()
local processCycle = 0

local avgDistSamples = {}
local avgDist = 0
local avgDistSum = 0
local avgDistSample = 0
local avgDistSampleCount = 0
local avgDistLastSampleTime = getTime()
avgDistSamples[0] = 0

local coord_to_tiles = nil
local tiles_to_path = nil
local MinLatitude = -85.05112878
local MaxLatitude = 85.05112878
local MinLongitude = -180
local MaxLongitude = 180

local TILES_X = 8
local TILES_Y = 3
local TILES_SIZE = 100
local TILES_DIM = 76.5
local TILES_IDX_BMP = 1
local TILES_IDX_PATH = 2

local zoomUpdateTimer = getTime()
local zoomUpdate = false

local lastHeavyUpdate = getTime()
local HEAVY_UPDATE_INTERVAL = 25
local mapNeedsHeavyUpdate = true

local lastTrailUpdate = getTime()
local TRAIL_UPDATE_INTERVAL = 50

function mapLib.clip(n, min, max)
  -- Constrains a numeric value to a valid range before projection and tile math use it.
  return math.min(math.max(n, min), max)
end

function mapLib.tiles_on_level(level)
  -- Converts a user-facing zoom level (1..20) into the number of tiles on one map axis.
  -- Both providers now receive user-facing levels; GMapCatcher internal offset is applied only where tiles are addressed.
  if status.conf.mapProvider == 1 then
    return 2^(level-1)  -- same as legacy form 2^(17-(18-level)); simplified algebraically
  else
    return 2^level
  end
end

--[[
  total tiles on the web mercator projection = 2^zoom*2^zoom
--]]
function mapLib.get_tile_matrix_size_pixel(level)
  -- Converts a zoom level into the full Web Mercator pixel dimensions for projection math.
  local size = 2^level * TILES_SIZE
  return size, size
end

--[[
  https://developers.google.com/maps/documentation/javascript/coordinates
  https://github.com/judero01col/GMap.NET
--]]
function mapLib.google_coord_to_tiles(lat, lng, level)
  -- Projects GPS coordinates into Google tile indexes and pixel offsets for the current zoom level.
  lat = mapLib.clip(lat, MinLatitude, MaxLatitude)
  lng = mapLib.clip(lng, MinLongitude, MaxLongitude)

  local x = (lng + 180) / 360
  local sinLatitude = math.sin(lat * math.pi / 180)
  local y = 0.5 - math.log((1 + sinLatitude) / (1 - sinLatitude)) / (4 * math.pi)

  local mapSizeX, mapSizeY = mapLib.get_tile_matrix_size_pixel(level)

    -- Convert the normalized Mercator position into absolute pixel coordinates for this zoom level.
  local rx = mapLib.clip(x * mapSizeX + 0.5, 0, mapSizeX - 1)
  local ry = mapLib.clip(y * mapSizeY + 0.5, 0, mapSizeY - 1)
    -- Return tile indexes plus the pixel offset inside the resolved tile.
  return math.floor(rx/TILES_SIZE), math.floor(ry/TILES_SIZE), math.floor(rx%TILES_SIZE), math.floor(ry%TILES_SIZE)
end

function mapLib.gmapcatcher_coord_to_tiles(lat, lon, level)
  -- Projects GPS coordinates into GMapCatcher tile indexes and pixel offsets for the current zoom level.
  local x = world_tiles / 360 * (lon + 180)
  local e = math.sin(lat * (1/180 * math.pi))
  local y = world_tiles / 2 + 0.5 * math.log((1+e)/(1-e)) * -1 * tiles_per_radian
  return math.floor(x % world_tiles), math.floor(y % world_tiles), math.floor((x - math.floor(x)) * TILES_SIZE), math.floor((y - math.floor(y)) * TILES_SIZE)
end

function mapLib.google_tiles_to_path(tile_x, tile_y, level)
  -- Builds the extension-free SD-card path for native Google/OSM tiles in /z/x/y format.
  return string.format("/%d/%.0f/%.0f", level, tile_x, tile_y)
end

function mapLib.esri_tiles_to_path(tile_x, tile_y, level)
  -- Builds the extension-free SD-card path for ESRI tiles in /z/y/x format.
  return string.format("/%d/%.0f/%.0f", level, tile_y, tile_x)
end

function mapLib.gmapcatcher_tiles_to_path(tile_x, tile_y, level)
  -- Builds the relative SD-card path for a GMapCatcher tile from tile coordinates and zoom.
  -- Translate user-facing level (1..20) to the GMapCatcher internal level (-2..17) for the on-disk path.
  local internalLevel = 18 - level
  return string.format("/%d/%.0f/%.0f/%.0f/s_%.0f.png", internalLevel, tile_x/1024, tile_x%1024, tile_y/1024, tile_y%1024)
end

local function fileExists(path)
  local f = io.open(path, "r")
  if f ~= nil then
    io.close(f)
    return true
  end
  return false
end

local function getGoogleFallbackBasePath(mapType, tilePath)
  -- Returns the extension-free Yaapu base path for a Google map type.
  -- Yaapu Google tiles use legacy /z/y/s_x naming even when native tiles use /z/x/y.
  local yaapuMapTypeMap = {
    ["Satellite"] = "GoogleSatelliteMap",
    ["Hybrid"] = "GoogleHybridMap",
    ["Map"] = "GoogleMap",
    ["Terrain"] = "GoogleTerrainMap"
  }
  local yaapuMapType = yaapuMapTypeMap[mapType] or mapType

  local fallbackTilePath = tilePath
  local z, x, y = tilePath:match("^/(%d+)/(%d+)/(%d+)$")
  if z ~= nil and x ~= nil and y ~= nil then
    fallbackTilePath = string.format("/%s/%s/s_%s", z, y, x)
  end

  return "/bitmaps/yaapu/maps/" .. yaapuMapType .. fallbackTilePath
end

local function loadFirstExisting(tilePath, ...)
  -- Tries each full file path in order and loads the first one that exists on disk.
  local paths = {...}
  for i = 1, #paths do
    if fileExists(paths[i]) then
      mapBitmapByPath[tilePath] = lcd.loadBitmap(paths[i])
      return mapBitmapByPath[tilePath], paths[i]
    end
  end
  return nil, nil
end

function mapLib.getTileBitmap(tilePath)
  -- Loads a tile bitmap from the SD card, caches it in memory, and falls back to the shared no-map bitmap when missing.
  -- For ethosmaps providers the tile path has no extension; both .jpg and .png are probed in that order.
  local provider = (status and status.conf and status.conf.mapProvider) or 2
  local mapType = (status and status.conf and status.conf.mapType) or ""

  if mapBitmapByPath[tilePath] ~= nil then
    return mapBitmapByPath[tilePath]
  end

  local bmp
  local loadedPath
  local attemptedPaths = nil
  if provider == 1 then
    -- GMapCatcher/Yaapu: path already has extension baked in by gmapcatcher_tiles_to_path.
    local onlyPath = "/bitmaps/yaapu/maps/" .. mapType .. tilePath
    attemptedPaths = { onlyPath }
    bmp, loadedPath = loadFirstExisting(tilePath, onlyPath)
  else
    -- ethosmaps providers: probe .jpg then .png so any download tool output is accepted.
    local PROVIDER_FOLDERS = { [2]="GOOGLE", [3]="ESRI", [4]="OSM" }
    local providerFolder = PROVIDER_FOLDERS[provider] or ("PROVIDER" .. tostring(provider))
    local base = "/bitmaps/ethosmaps/maps/" .. providerFolder .. "/" .. mapType .. tilePath
    if provider == 2 then
      -- Google: also probe Yaapu folder as fallback (both extensions).
      local yaapuBase = getGoogleFallbackBasePath(mapType, tilePath)
      attemptedPaths = {
        base .. ".jpg", base .. ".png",
        yaapuBase .. ".jpg", yaapuBase .. ".png"
      }
      bmp, loadedPath = loadFirstExisting(tilePath,
        base .. ".jpg", base .. ".png",
        yaapuBase .. ".jpg", yaapuBase .. ".png")
    else
      attemptedPaths = { base .. ".jpg", base .. ".png" }
      bmp, loadedPath = loadFirstExisting(tilePath, base .. ".jpg", base .. ".png")
    end
  end

  if bmp ~= nil then
    if status and status.conf and status.conf.enableDebugLog and libs and libs.utils and libs.utils.logDebug then
      local logKey = string.format("provider:%s|mapType:%s", tostring(provider), tostring(mapType))
      if lastTileFormatLogByKey[logKey] == nil then
        local ext = "unknown"
        if type(loadedPath) == "string" then
          ext = (loadedPath:match("%.([%a%d]+)$") or "unknown"):lower()
        end
        local source = "ethosmaps"
        if type(loadedPath) == "string" and loadedPath:find("/bitmaps/yaapu/maps/", 1, true) == 1 then
          source = "yaapu-fallback"
        elseif provider == 1 then
          source = "yaapu"
        end
        libs.utils.logDebug("TILE", "Tile format detected for " .. logKey .. ": ." .. ext .. " (source: " .. source .. ")", true)
        lastTileFormatLogByKey[logKey] = ext .. "|" .. source
      end
    end
    return bmp
  end

  -- No tile found anywhere, use fallback bitmap.
  if status and status.conf and status.conf.enableDebugLog and libs and libs.utils and libs.utils.logDebug then
    local logKey = string.format("provider:%s|mapType:%s", tostring(provider), tostring(mapType))
    if lastNoTilesLogKey ~= logKey then
      libs.utils.logDebug("TILE", "No tile files found for " .. logKey .. "; using fallback bitmap (notiles/nomap)", true)
      if type(tilePath) == "string" then
        libs.utils.logDebug("TILE", "First missing tile key: " .. tilePath, true)
      end
      if type(attemptedPaths) == "table" then
        for i = 1, #attemptedPaths do
          libs.utils.logDebug("TILE", "Attempted path " .. tostring(i) .. ": " .. tostring(attemptedPaths[i]), true)
        end
      end
      lastNoTilesLogKey = logKey
    end
  end

  if nomap == nil then
    if fileExists("/bitmaps/ethosmaps/maps/notiles.png") then
      nomap = lcd.loadBitmap("/bitmaps/ethosmaps/maps/notiles.png")
    else
      nomap = lcd.loadBitmap("/bitmaps/ethosmaps/bitmaps/nomap.png")
    end
  end
  mapBitmapByPath[tilePath] = nomap
  return nomap
end

function mapLib.loadAndCenterTiles(tile_x, tile_y, offset_x, offset_y, width, level)
  -- Rebuilds the visible tile window around the current center tile and updates tile caches when the map moves or zooms.
  local now = getTime()

  if now - lastHeavyUpdate < HEAVY_UPDATE_INTERVAL and not mapNeedsHeavyUpdate then
    return
  end
  
  lastHeavyUpdate = now
  mapNeedsHeavyUpdate = false

  local tilesChanged = false

  for x=1,TILES_X do
    for y=1,TILES_Y do
      local tile_path = mapLib.tiles_to_path(tile_x + x - math.floor(TILES_X/2 + 0.5), tile_y + y - math.floor(TILES_Y/2 + 0.5), level)
      local idx = width*(y-1)+x

      if tiles[idx] == nil then
        tiles[idx] = tile_path
        tiles_path_to_idx[tile_path] = { idx, x, y }
        tilesChanged = true
      else
        if tiles[idx] ~= tile_path then
          tiles[idx] = tile_path
          tiles_path_to_idx[tile_path] = { idx, x, y }
          tilesChanged = true
        end
      end
    end
  end
  
  for path, bmp in pairs(mapBitmapByPath) do
    local remove = true
    for i=1,#tiles do
      if tiles[i] == path then remove = false end
    end
    if remove then
      mapBitmapByPath[path]=nil
      tiles_path_to_idx[path]=nil
      tilesChanged = true
    end
  end
  
  if tilesChanged then
    collectgarbage()
    if status and status.conf and status.conf.enableDebugLog and libs and libs.utils then
      libs.utils.logDebug("TILE", "loadAndCenterTiles: tiles changed (load/zoom/recenter)")
    end
  end
end


function mapLib.drawTiles(width, xmin, xmax, ymin, ymax, color, level)
  -- Draws the active tile cache into the map viewport and overlays the optional grid when enabled.

  for x=1,TILES_X do
    for y=1,TILES_Y do
      local idx = width*(y-1)+x
      if tiles[idx] ~= nil then
        lcd.drawBitmap(xmin+(x-1)*TILES_SIZE, ymin+(y-1)*TILES_SIZE, mapLib.getTileBitmap(tiles[idx]))
      end
    end
  end

  if status.conf.enableMapGrid and status.widgetWidth >= 480 then
    lcd.pen(DOTTED)
    lcd.color(color)
    for x=1,TILES_X-1 do
      lcd.drawLine(xmin+x*TILES_SIZE,ymin,xmin+x*TILES_SIZE,ymax)
    end
    for y=1,TILES_Y-1 do
      lcd.drawLine(xmin,ymin+y*TILES_SIZE,xmax,ymin+y*TILES_SIZE)
    end
  end
end


function mapLib.getScreenCoordinates(minX, minY, tile_x, tile_y, offset_x, offset_y, level)
  -- Resolves tile-local coordinates back into screen coordinates using the current visible tile cache.
  local tile_path = mapLib.tiles_to_path(tile_x, tile_y, level)
  local tcache = tiles_path_to_idx[tile_path]
  if tcache ~= nil then
    if tiles[tcache[1]] ~= nil then
      return minX + (tcache[2]-1)*TILES_SIZE + offset_x, minY + (tcache[3]-1)*TILES_SIZE + offset_y
    end
  end
  return status.widgetWidth / 2, -10
end

function mapLib.drawMap(widget, x, y, w, h, level, tiles_x, tiles_y, heading)
  -- Draws the full map view by combining tile rendering, aircraft/home overlays, trail history, and zoom controls.
  lcd.setClipping(x, y, w, h)
  setupMaps(x, y, w, h, level, tiles_x, tiles_y)

  if #tiles == 0 or tiles[1] == nil then
    if status.telemetry.lat ~= nil and status.telemetry.lon ~= nil then
      tile_x, tile_y, offset_x, offset_y = mapLib.coord_to_tiles(status.telemetry.lat, status.telemetry.lon, level)
    else
      tile_x, tile_y, offset_x, offset_y = 0, 0, 0, 0
    end
    mapLib.loadAndCenterTiles(tile_x, tile_y, offset_x, offset_y, TILES_X, level)
  end

  if widget.drawOffsetX == nil then widget.drawOffsetX = 0 end
  if widget.drawOffsetY == nil then widget.drawOffsetY = 0 end

  if widget.lastW ~= w or widget.lastH ~= h or widget.lastZoom ~= level then
    widget.drawOffsetX = 0
    widget.drawOffsetY = 0
    widget.lastW = w
    widget.lastH = h
    widget.lastZoom = level
    mapLib.loadAndCenterTiles(tile_x or 0, tile_y or 0, offset_x or 0, offset_y or 0, TILES_X, level)
  end

  local vehicleR = math.floor(34 * math.min(status.scaleX, status.scaleY))

  if status.telemetry.lat ~= nil and status.telemetry.lon ~= nil then
    if zoomUpdate or (getTime() - lastPosUpdate > 50) then
      posUpdated = true
      lastPosUpdate = getTime()

      tile_x, tile_y, offset_x, offset_y = mapLib.coord_to_tiles(status.telemetry.lat, status.telemetry.lon, level)
      myScreenX, myScreenY = mapLib.getScreenCoordinates(MAP_X, MAP_Y, tile_x, tile_y, offset_x, offset_y, level)

      local borderX = math.floor(math.max(35, w * 0.085))
      local borderY = math.floor(math.max(35, h * 0.085))

      local myCode = libs.drawLib.computeOutCode(myScreenX, myScreenY,
                      MAP_X + borderX, MAP_Y + borderY,
                      MAP_X + w - borderX, MAP_Y + h - borderY)

      if myCode > 0 then
        mapLib.loadAndCenterTiles(tile_x, tile_y, offset_x, offset_y, TILES_X, level)
        tile_x, tile_y, offset_x, offset_y = mapLib.coord_to_tiles(status.telemetry.lat, status.telemetry.lon, level)
        myScreenX, myScreenY = mapLib.getScreenCoordinates(MAP_X, MAP_Y, tile_x, tile_y, offset_x, offset_y, level)

        local centerX = x + (w / 2)
        local centerY = y + (h / 2)
        widget.drawOffsetX = centerX - myScreenX
        widget.drawOffsetY = centerY - myScreenY
      end
    end
  end

  local minX = math.max(0, MAP_X)
  local minY = math.max(0, MAP_Y)
  local maxX = math.min(minX + w, minX + TILES_X * TILES_SIZE)
  local maxY = math.min(minY + h, minY + TILES_Y * TILES_SIZE)

  if getTime() - lastHomePosUpdate > 20 then
    lastHomePosUpdate = getTime()
    if homeNeedsRefresh then
      homeNeedsRefresh = false
      if status.telemetry.homeLat ~= nil then
        tile_x, tile_y, offset_x, offset_y = mapLib.coord_to_tiles(status.telemetry.homeLat, status.telemetry.homeLon, level)
        homeScreenX, homeScreenY = mapLib.getScreenCoordinates(MAP_X, MAP_Y, tile_x, tile_y, offset_x, offset_y, level)
      end
    else
      homeNeedsRefresh = true
      estimatedHomeGps.lat, estimatedHomeGps.lon = libs.utils.getLatLonFromAngleAndDistance(status.telemetry.homeAngle, status.telemetry.homeDist)
      if estimatedHomeGps.lat ~= nil then
        local t_x, t_y, o_x, o_y = mapLib.coord_to_tiles(estimatedHomeGps.lat, estimatedHomeGps.lon, level)
        estimatedHomeScreenX, estimatedHomeScreenY = mapLib.getScreenCoordinates(MAP_X, MAP_Y, t_x, t_y, o_x, o_y, level)
      end
    end
  end

  local now = getTime()
  if now - lastTrailUpdate > TRAIL_UPDATE_INTERVAL and posUpdated then
    lastTrailUpdate = now
    posUpdated = false
    local path = mapLib.tiles_to_path(tile_x, tile_y, level)
    posHistory[sample] = { path, offset_x, offset_y }
    sampleCount = sampleCount + 1
    sample = sampleCount % status.conf.mapTrailDots
  end

  mapLib.drawTiles(TILES_X, minX + widget.drawOffsetX, maxX + widget.drawOffsetX, minY + widget.drawOffsetY, maxY + widget.drawOffsetY, status.colors.yellow, level)

  if myScreenX ~= nil and myScreenY ~= nil then
    local drawX = myScreenX + widget.drawOffsetX
    local drawY = myScreenY + widget.drawOffsetY
    if heading ~= nil then
      libs.drawLib.drawRArrow(drawX, drawY, vehicleR - 5, heading, status.colors.white)
      libs.drawLib.drawRArrow(drawX, drawY, vehicleR, heading, status.colors.black)
    else
      lcd.color(WHITE)
      lcd.drawCircle(drawX, drawY, vehicleR - 3)
      lcd.color(BLACK)
      lcd.drawCircle(drawX, drawY, vehicleR)
    end
  end

  if status.telemetry.homeLat ~= nil and status.telemetry.homeLon ~= nil and homeScreenX ~= nil then
    local homeDrawX = homeScreenX + widget.drawOffsetX
    local homeDrawY = homeScreenY + widget.drawOffsetY
    local homeCode = libs.drawLib.computeOutCode(homeDrawX, homeDrawY, x + 11, y + 10, x + w - 11, y + h - 10)
    if homeCode == 0 then
      libs.drawLib.drawBitmap(homeDrawX - 11, homeDrawY - 10, "homeorange")
    end
  end

  lcd.color(status.colors.yellow)
  for p = 0, math.min(sampleCount - 1, status.conf.mapTrailDots - 1) do
    if p ~= (sampleCount - 1) % status.conf.mapTrailDots then
      local tcache = tiles_path_to_idx[posHistory[p][1]]
      if tcache ~= nil and tiles[tcache[1]] ~= nil then
        lcd.drawFilledRectangle(minX + widget.drawOffsetX + (tcache[2]-1)*TILES_SIZE + posHistory[p][2],
                                minY + widget.drawOffsetY + (tcache[3]-1)*TILES_SIZE + posHistory[p][3], 3, 3)
      end
    end
  end

  if zoomUpdate then
    lcd.color(WHITE)
    lcd.font(FONT_XL)
    lcd.drawText(x + w/2, y + h/2 - 25*status.scaleY, string.format("ZOOM %d", level), CENTERED)
    if getTime() - zoomUpdateTimer > 100 then zoomUpdate = false end
  end
  
  lcd.setClipping()
end

local function configureProjectionHelpers(provider)
  if provider == 1 then
    mapLib.coord_to_tiles = mapLib.gmapcatcher_coord_to_tiles
    mapLib.tiles_to_path = mapLib.gmapcatcher_tiles_to_path
  elseif provider == 3 then
    -- ESRI uses Web Mercator with /z/y/x tile addressing.
    mapLib.coord_to_tiles = mapLib.google_coord_to_tiles
    mapLib.tiles_to_path = mapLib.esri_tiles_to_path
  else
    -- Google (2) and OSM (4): Web Mercator with /z/x/y tile addressing.
    mapLib.coord_to_tiles = mapLib.google_coord_to_tiles
    mapLib.tiles_to_path = mapLib.google_tiles_to_path
  end
end

local function getScaleDistanceForLevel(level)
  local unitFactor = (status.conf.distUnitScale == 1 and 1 or 3)
  return unitFactor * 50 * 2^(20-level)
end

function setupMaps(x, y, w, h, level, tiles_x, tiles_y)
  -- Reconfigures projection helpers, tile caches, and scale metadata whenever map geometry or zoom changes.

  if level == nil or tiles_x == nil or tiles_y == nil or x == nil or y == nil then
    return -- Safeguard: map initialization requires complete viewport and zoom information.
  end

  MAP_X = x
  MAP_Y = y
  TILES_X = tiles_x
  TILES_Y = tiles_y

  local provider = (status and status.conf and status.conf.mapProvider) or 2
  if level ~= lastZoomLevel or provider ~= lastMapProvider or lastZoomLevel == -99 then
    zoomUpdateTimer = getTime()
    zoomUpdate = true

    libs.resetLib.clearTable(tiles)
    libs.resetLib.clearTable(mapBitmapByPath)
    libs.resetLib.clearTable(posHistory)

    sample = 0
    sampleCount = 0

    world_tiles = mapLib.tiles_on_level(level)
    tiles_per_radian = world_tiles / (2 * math.pi)
    configureProjectionHelpers(provider)
    tile_dim = (40075017/world_tiles) * status.conf.distUnitScale
    local scaleDistance = getScaleDistanceForLevel(level)
    scaleLabel = string.format("%.0f%s", scaleDistance, status.conf.distUnitLabel)
    scaleLen = (scaleDistance/tile_dim)*TILES_SIZE

    lastZoomLevel = level
    lastMapProvider = provider
  end
end

function mapLib.init(param_status, param_libs)
  -- Stores shared state references so map helpers can read telemetry/config data and call sibling libraries.
  status = param_status
  libs = param_libs
  configureProjectionHelpers((status and status.conf and status.conf.mapProvider) or 2)
  return mapLib
end

function mapLib.calculateScale(level)
  -- Converts the current zoom level into a scale-bar length and label for layout overlays.
  local scaleLen, scaleLabel = 0, ""

  if level == nil then
    return scaleLen, scaleLabel
  end

  local world_tiles = mapLib.tiles_on_level(level)
  local tile_dim = (40075017 / world_tiles) * status.conf.distUnitScale
  local scaleDistance = getScaleDistanceForLevel(level)

  if status.conf.mapProvider == 1 or status.conf.mapProvider == 2 then
    scaleLabel = string.format("%.0f%s", scaleDistance, status.conf.distUnitLabel)
    scaleLen = (scaleDistance/tile_dim)*TILES_SIZE
  end

  return scaleLen, scaleLabel
end

function mapLib.setNeedsHeavyUpdate()
  -- Flags the next draw cycle to rebuild the visible tile set instead of relying on throttled reuse.
  mapNeedsHeavyUpdate = true
end

return mapLib