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
  -- Converts a zoom level into the number of tiles on one map axis for the active provider.
  if status.conf.mapProvider == 1 then
    return 2^(17-level)
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
  -- Builds the relative SD-card path for a Google map tile from tile coordinates and zoom.
  return string.format("/%d/%.0f/s_%.0f.jpg", level, tile_y, tile_x)
end

function mapLib.gmapcatcher_tiles_to_path(tile_x, tile_y, level)
  -- Builds the relative SD-card path for a GMapCatcher tile from tile coordinates and zoom.
  return string.format("/%d/%.0f/%.0f/%.0f/s_%.0f.png", level, tile_x/1024, tile_x%1024, tile_y/1024, tile_y%1024)
end

function mapLib.getTileBitmap(tilePath)
  -- Loads a tile bitmap from the SD card, caches it in memory, and falls back to the shared no-map bitmap when missing.
  local fullPath = "/bitmaps/ethosmaps/maps/" .. status.conf.mapType .. tilePath
  
  if mapBitmapByPath[tilePath] ~= nil then
    return mapBitmapByPath[tilePath]
  end

  local tmp = io.open(fullPath, "r")
  if tmp ~= nil then
    io.close(tmp)
    mapBitmapByPath[tilePath] = lcd.loadBitmap(fullPath)
    return mapBitmapByPath[tilePath]
  else
    if nomap == nil then
      nomap = lcd.loadBitmap("/bitmaps/ethosmaps/maps/nomap.png")
    end
    mapBitmapByPath[tilePath] = nomap
    return nomap
  end
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

  -- On-screen status output for projection helper initialization.
  lcd.color(lcd.RGB(0, 255, 255))   -- Cyan
  lcd.font(FONT_L)
  if mapLib.tiles_to_path == nil or mapLib.coord_to_tiles == nil then
    lcd.drawText(x + 20, y + 20, "EARLY RETURN - tiles_to_path NIL!")
    return
  else
    lcd.drawText(x + 20, y + 20, "setupMaps OK - proceeding...")
  end

  if #tiles == 0 or tiles[1] == nil then
    if status.telemetry.lat ~= nil and status.telemetry.lon ~= nil then
      tile_x, tile_y, offset_x, offset_y = mapLib.coord_to_tiles(status.telemetry.lat, status.telemetry.lon, level)
    else
      tile_x, tile_y, offset_x, offset_y = 0, 0, 0, 0
    end
    mapLib.loadAndCenterTiles(tile_x, tile_y, offset_x, offset_y, TILES_X, level)
  end

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

function setupMaps(x, y, w, h, level, tiles_x, tiles_y)
  -- Reconfigures projection helpers, tile caches, and scale metadata whenever map geometry or zoom changes.

  -- Normalize unset provider values to Google before selecting projection helpers.
  if status.conf.mapProvider == 0 then
    status.conf.mapProvider = 2   -- Keep provider defaults consistent with main.lua.
  end

  if level == nil or tiles_x == nil or tiles_y == nil or x == nil or y == nil then
    return -- Safeguard: map initialization requires complete viewport and zoom information.
  end

  -- Force first-run initialization (lastZoomLevel = -99)
  if level ~= lastZoomLevel or lastZoomLevel == -99 then
    zoomUpdateTimer = getTime()
    zoomUpdate = true

    libs.resetLib.clearTable(tiles)
    libs.resetLib.clearTable(mapBitmapByPath)
    libs.resetLib.clearTable(posHistory)

    sample = 0
    sampleCount = 0

    world_tiles = mapLib.tiles_on_level(level)
    tiles_per_radian = world_tiles / (2 * math.pi)

    if status.conf.mapProvider == 1 then
      mapLib.coord_to_tiles = mapLib.gmapcatcher_coord_to_tiles
      mapLib.tiles_to_path = mapLib.gmapcatcher_tiles_to_path
      tile_dim = (40075017/world_tiles) * status.conf.distUnitScale
      scaleLabel = string.format("%.0f%s",(status.conf.distUnitScale==1 and 1 or 3)*50*2^(level+2),status.conf.distUnitLabel)
      scaleLen = ((status.conf.distUnitScale==1 and 1 or 3)*50*2^(level+2)/tile_dim)*TILES_SIZE
    elseif status.conf.mapProvider == 2 then
      mapLib.coord_to_tiles = mapLib.google_coord_to_tiles
      mapLib.tiles_to_path = mapLib.google_tiles_to_path
      tile_dim = (40075017/world_tiles) * status.conf.distUnitScale
      scaleLabel = string.format("%.0f%s", (status.conf.distUnitScale==1 and 1 or 3)*50*2^(20-level), status.conf.distUnitLabel)
      scaleLen = ((status.conf.distUnitScale==1 and 1 or 3)*50*2^(20-level)/tile_dim)*TILES_SIZE
    end
    lastZoomLevel = level
  end
  -- ========================================================

  MAP_X = x
  MAP_Y = y
  TILES_X = tiles_x
  TILES_Y = tiles_y

  if level ~= lastZoomLevel then
    zoomUpdateTimer = getTime()
    zoomUpdate = true

    libs.resetLib.clearTable(tiles)
    libs.resetLib.clearTable(mapBitmapByPath)
    libs.resetLib.clearTable(posHistory)

    sample = 0
    sampleCount = 0

    world_tiles = mapLib.tiles_on_level(level)
    tiles_per_radian = world_tiles / (2 * math.pi)

    if status.conf.mapProvider == 1 then
      mapLib.coord_to_tiles = mapLib.gmapcatcher_coord_to_tiles
      mapLib.tiles_to_path = mapLib.gmapcatcher_tiles_to_path
      tile_dim = (40075017/world_tiles) * status.conf.distUnitScale
      scaleLabel = string.format("%.0f%s",(status.conf.distUnitScale==1 and 1 or 3)*50*2^(level+2),status.conf.distUnitLabel)
      scaleLen = ((status.conf.distUnitScale==1 and 1 or 3)*50*2^(level+2)/tile_dim)*TILES_SIZE
    elseif status.conf.mapProvider == 2 then
      mapLib.coord_to_tiles = mapLib.google_coord_to_tiles
      mapLib.tiles_to_path = mapLib.google_tiles_to_path
      tile_dim = (40075017/world_tiles) * status.conf.distUnitScale
      scaleLabel = string.format("%.0f%s", (status.conf.distUnitScale==1 and 1 or 3)*50*2^(20-level), status.conf.distUnitLabel)
      scaleLen = ((status.conf.distUnitScale==1 and 1 or 3)*50*2^(20-level)/tile_dim)*TILES_SIZE
    end
    lastZoomLevel = level
  end
end

function mapLib.init(param_status, param_libs)
  -- Stores shared state references so map helpers can read telemetry/config data and call sibling libraries.
  status = param_status
  libs = param_libs
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

  if status.conf.mapProvider == 1 then
    scaleLabel = string.format("%.0f%s", (status.conf.distUnitScale==1 and 1 or 3)*50*2^(level+2), status.conf.distUnitLabel)
    scaleLen = ((status.conf.distUnitScale==1 and 1 or 3)*50*2^(level+2)/tile_dim)*TILES_SIZE
  elseif status.conf.mapProvider == 2 then
    scaleLabel = string.format("%.0f%s", (status.conf.distUnitScale==1 and 1 or 3)*50*2^(20-level), status.conf.distUnitLabel)
    scaleLen = ((status.conf.distUnitScale==1 and 1 or 3)*50*2^(20-level)/tile_dim)*TILES_SIZE
  end

  return scaleLen, scaleLabel
end

function mapLib.setNeedsHeavyUpdate()
  -- Flags the next draw cycle to rebuild the visible tile set instead of relying on throttled reuse.
  mapNeedsHeavyUpdate = true
end

return mapLib