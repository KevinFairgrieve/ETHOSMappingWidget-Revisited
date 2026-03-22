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


local mapLib = {}

local status = nil
local libs = nil

-- getTime() removed — use status.getTime() (published by main.lua)
-- flagEnabled() removed — use status.flagEnabled() (published by utils.init)

-- Global map geometry constants and runtime state shared across draw calls.
local MAP_X = 0
local MAP_Y = 0

-- Cached map support state for tiles, screen coordinates, trail history, and redraw throttling.
local myScreenX, myScreenY
local homeScreenX, homeScreenY
local estimatedHomeScreenX, estimatedHomeScreenY
local tile_x, tile_y, offset_x, offset_y
local tiles = {}
local tiles_path_to_idx = {} -- Maps tile file paths back to their active slot in the visible tile grid.
local world_tiles
local tiles_per_radian
local tile_dim
local scaleLen
local scaleLabel
-- GPS-based trail: ring-buffer of up to TRAIL_MAX_WAYPOINTS lat/lon anchors.
-- A new waypoint is committed only when BOTH the configured minimum distance has
-- been travelled AND the angle between the last committed segment and the pending
-- segment (last WP → UAV) exceeds the configured threshold.  This measures the
-- actual visual bend in the trail rather than relying on heading/COG which can
-- fluctuate with wind and gusts.
local TRAIL_MAX_WAYPOINTS = 51
local trailWaypoints = {}
local trailWpCount = 0
local trailHead = 0       -- ring-buffer write index (1-based, wraps at TRAIL_MAX_WAYPOINTS)
local trailAccumDist = 0
local trailLastLat = nil
local trailLastLon = nil
local trailCachedLevel = nil  -- zoom level for which tpx/tpy are cached
local trailTpx = {}           -- cached tile-pixel X per waypoint slot
local trailTpy = {}           -- cached tile-pixel Y per waypoint slot
local homeNeedsRefresh = true
local lastHomePosUpdate = 0   -- Initialised to 0; first check after init always triggers.
local lastZoomLevel = -99
local lastMapProvider = -99
local lastMapType = nil
local estimatedHomeGps = {
  lat = nil,
  lon = nil
}

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

local zoomUpdateTimer = 0    -- Initialised to 0; first zoom label always shows briefly.
local zoomUpdate = false

local lastHeavyUpdate = 0    -- Initialised to 0; first loadAndCenterTiles always runs.
local HEAVY_UPDATE_INTERVAL = 25
local mapNeedsHeavyUpdate = true
local RASTER_REBUILD_OFFSET_THRESHOLD = 40

local DIRECTIONAL_LEAD_TILES = 1
local DIRECTIONAL_LEAD_MIN_SPEED = 1.5
local DIRECTIONAL_LEAD_OFFSET_THRESHOLD = 90
local PREFETCH_LEAD_OFFSET_THRESHOLD = 60
local PREFETCH_STRIP_DEPTH = 1

local function getDirectionalLeadFromHeading(heading)
  if DIRECTIONAL_LEAD_TILES <= 0 then
    return 0, 0
  end

  local speed = (status and status.telemetry and status.telemetry.groundSpeed) or 0
  if heading == nil or speed < DIRECTIONAL_LEAD_MIN_SPEED then
    return 0, 0
  end

  local normalizedHeading = heading % 360
  local octant = math.floor((normalizedHeading + 22.5) / 45) % 8
  local octantLead = {
    [0] = { 0, -1 }, -- N
    [1] = { 1, -1 }, -- NE
    [2] = { 1,  0 }, -- E
    [3] = { 1,  1 }, -- SE
    [4] = { 0,  1 }, -- S
    [5] = {-1,  1 }, -- SW
    [6] = {-1,  0 }, -- W
    [7] = {-1, -1 }, -- NW
  }

  local lead = octantLead[octant] or { 0, 0 }
  return lead[1] * DIRECTIONAL_LEAD_TILES, lead[2] * DIRECTIONAL_LEAD_TILES
end

local function gateLeadByTileOffsetThreshold(leadX, leadY, offsetX, offsetY, threshold)
  local gatedLeadX = leadX or 0
  local gatedLeadY = leadY or 0
  local gateThreshold = threshold or DIRECTIONAL_LEAD_OFFSET_THRESHOLD

  if gatedLeadX > 0 then
    if (offsetX or 0) < gateThreshold then
      gatedLeadX = 0
    end
  elseif gatedLeadX < 0 then
    if (offsetX or 0) > (100 - gateThreshold) then
      gatedLeadX = 0
    end
  end

  if gatedLeadY > 0 then
    if (offsetY or 0) < gateThreshold then
      gatedLeadY = 0
    end
  elseif gatedLeadY < 0 then
    if (offsetY or 0) > (100 - gateThreshold) then
      gatedLeadY = 0
    end
  end

  return gatedLeadX, gatedLeadY
end

local function gateLeadByTileOffset(leadX, leadY, offsetX, offsetY)
  return gateLeadByTileOffsetThreshold(leadX, leadY, offsetX, offsetY, DIRECTIONAL_LEAD_OFFSET_THRESHOLD)
end

local function gatePrefetchByTileOffset(leadX, leadY, offsetX, offsetY)
  return gateLeadByTileOffsetThreshold(leadX, leadY, offsetX, offsetY, PREFETCH_LEAD_OFFSET_THRESHOLD)
end

local function enqueueDirectionalPrefetch(centerTileX, centerTileY, level, prefetchLeadX, prefetchLeadY)
  if libs == nil or libs.tileLoader == nil then
    return
  end

  local leadX = math.max(-1, math.min(1, tonumber(prefetchLeadX) or 0))
  local leadY = math.max(-1, math.min(1, tonumber(prefetchLeadY) or 0))
  if leadX == 0 and leadY == 0 then
    return
  end

  local halfX = math.floor(TILES_X / 2 + 0.5)
  local halfY = math.floor(TILES_Y / 2 + 0.5)

  if leadX ~= 0 then
    for depth = 1, PREFETCH_STRIP_DEPTH do
      local gridX = leadX > 0 and (TILES_X + depth) or (1 - depth)
      for gridY = 1 - PREFETCH_STRIP_DEPTH, TILES_Y + PREFETCH_STRIP_DEPTH do
        local tilePath = mapLib.tiles_to_path(centerTileX + gridX - halfX, centerTileY + gridY - halfY, level)
        libs.tileLoader.enqueue(tilePath, true)
      end
    end
  end

  if leadY ~= 0 then
    for depth = 1, PREFETCH_STRIP_DEPTH do
      local gridY = leadY > 0 and (TILES_Y + depth) or (1 - depth)
      for gridX = 1 - PREFETCH_STRIP_DEPTH, TILES_X + PREFETCH_STRIP_DEPTH do
        local tilePath = mapLib.tiles_to_path(centerTileX + gridX - halfX, centerTileY + gridY - halfY, level)
        libs.tileLoader.enqueue(tilePath, true)
      end
    end
  end
end

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

function mapLib.loadAndCenterTiles(tile_x, tile_y, offset_x, offset_y, width, level, leadX, leadY, prefetchLeadX, prefetchLeadY)
  -- Rebuilds the visible tile window around the current center tile and updates tile caches when the map moves or zooms.
  local perfActive = status.perfActive
  local perfStartMs = nil
  if perfActive then
    perfStartMs = os.clock() * 1000
    status.perfProfileInc("tile_update_calls", 1)
  end
  local now = status.getTime()

  if now - lastHeavyUpdate < HEAVY_UPDATE_INTERVAL and not mapNeedsHeavyUpdate then
    return
  end
  
  lastHeavyUpdate = now
  mapNeedsHeavyUpdate = false

  local windowLeadX = math.max(-1, math.min(1, tonumber(leadX) or 0))
  local windowLeadY = math.max(-1, math.min(1, tonumber(leadY) or 0))
  local centerTileX = tile_x + windowLeadX
  local centerTileY = tile_y + windowLeadY

  local tilesChanged = false
  local removedCacheEntries = 0

  libs.resetLib.clearTable(tiles_path_to_idx)

  local halfX = math.floor(TILES_X / 2 + 0.5)
  local halfY = math.floor(TILES_Y / 2 + 0.5)

  for x=1,TILES_X do
    for y=1,TILES_Y do
      local tile_path = mapLib.tiles_to_path(centerTileX + x - halfX, centerTileY + y - halfY, level)
      local idx = width*(y-1)+x

      tiles_path_to_idx[tile_path] = { idx, x, y }

      if tiles[idx] ~= tile_path then
        tiles[idx] = tile_path
        tilesChanged = true
      end
    end
  end

  -- Only run eviction and enqueue work when the visible window actually shifted.
  if tilesChanged then
    removedCacheEntries = libs.tileLoader.trimCache(centerTileX, centerTileY, level, TILES_X, TILES_Y, windowLeadX, windowLeadY)
    if removedCacheEntries > 0 then
    end

    -- Enqueue all tile slots for async loading; tiles near the center get high priority
    -- so the aircraft position renders sharply before the outer fringe fills in.
    local halfX = math.floor(TILES_X / 2 + 0.5)
    local halfY = math.floor(TILES_Y / 2 + 0.5)
    for x = 1, TILES_X do
      for y = 1, TILES_Y do
        local tp = tiles[width * (y - 1) + x]
        if tp ~= nil then
          local isHighPrio = (math.abs(x - halfX) <= 1 and math.abs(y - halfY) <= 1)
          libs.tileLoader.enqueue(tp, isHighPrio)
        end
      end
    end
  end

  if tilesChanged then
    if perfActive then
      status.perfProfileInc("tile_rebuild_count", 1)
    end
    if perfActive and removedCacheEntries > 0 then
      status.perfProfileInc("gc_count", 1)
    end
    if status.debugEnabled and libs and libs.utils then
      libs.utils.logDebug("TILE", string.format("loadAndCenterTiles: window rebuilt (queue=%d)", libs.tileLoader.getQueueLength()))
    end
  end

  enqueueDirectionalPrefetch(centerTileX, centerTileY, level, prefetchLeadX, prefetchLeadY)

  if perfActive then
    status.perfProfileAddMs("tile_update_ms", os.clock() * 1000 - perfStartMs)
  end
end


function mapLib.drawTiles(width, xmin, ymin)
  -- Draws the active tile cache into the map viewport.
  local perfActive = status.perfActive
  local perfStartMs = nil
  if perfActive then
    perfStartMs = os.clock() * 1000
  end

  -- Cache sentinel bitmaps and getBitmap reference outside the loop so each
  -- tile iteration pays only one table lookup instead of up to four function calls.
  local tileGet    = libs.tileLoader.getBitmap
  local loadingBmp = libs.tileLoader.getLoadingBitmap()
  local noMapBmp   = libs.tileLoader.getNoMapBitmap()

  for x=1,TILES_X do
    for y=1,TILES_Y do
      local idx = width*(y-1)+x
      if tiles[idx] ~= nil then
        local bmp = tileGet(tiles[idx]) or loadingBmp or noMapBmp
        if bmp ~= nil then
          lcd.drawBitmap(xmin+(x-1)*TILES_SIZE, ymin+(y-1)*TILES_SIZE, bmp)
        end
      end
    end
  end

  if status.debugEnabled then
    local gridXMax = xmin + TILES_X * TILES_SIZE
    local gridYMax = ymin + TILES_Y * TILES_SIZE
    lcd.pen(DOTTED)
    lcd.color(status.colors.yellow)
    for x=1,TILES_X-1 do
      local lineX = xmin + x*TILES_SIZE
      lcd.drawLine(lineX, ymin, lineX, gridYMax)
    end
    for y=1,TILES_Y-1 do
      local lineY = ymin + y*TILES_SIZE
      lcd.drawLine(xmin, lineY, gridXMax, lineY)
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

function mapLib.drawMap(widget, x, y, w, h, level, tiles_x, tiles_y, heading, allowStateUpdate)
  -- Draws the full map view by combining tile rendering, aircraft/home overlays, trail history, and zoom controls.
  local perfActive = status.perfActive
  local perfStartMs = nil
  if perfActive then
    perfStartMs = os.clock() * 1000
  end
  lcd.setClipping(x, y, w, h)
  setupMaps(x, y, w, h, level, tiles_x, tiles_y)

  local telemetry = status.telemetry
  local scaleX = status.scaleX
  local scaleY = status.scaleY
  local debugEnabled = status.debugEnabled
  local colors = status.colors

  if #tiles == 0 or tiles[1] == nil then
    if telemetry.lat ~= nil and telemetry.lon ~= nil then
      tile_x, tile_y, offset_x, offset_y = mapLib.coord_to_tiles(telemetry.lat, telemetry.lon, level)
    else
      tile_x, tile_y, offset_x, offset_y = 0, 0, 0, 0
    end
    mapLib.loadAndCenterTiles(tile_x, tile_y, offset_x, offset_y, TILES_X, level, 0, 0, 0, 0)
  end

  if widget.drawOffsetX == nil then widget.drawOffsetX = 0 end
  if widget.drawOffsetY == nil then widget.drawOffsetY = 0 end

  local viewportChanged = (widget.lastW ~= w or widget.lastH ~= h)
  local zoomChanged = (widget.lastZoom ~= level)
  if viewportChanged or zoomChanged then
    widget.drawOffsetX = 0
    widget.drawOffsetY = 0
    widget.lastW = w
    widget.lastH = h
    widget.lastZoom = level
    mapLib.loadAndCenterTiles(tile_x or 0, tile_y or 0, offset_x or 0, offset_y or 0, TILES_X, level, 0, 0, 0, 0)

    if viewportChanged and debugEnabled and libs and libs.utils and libs.utils.logDebug and libs.tileLoader then
      local gridTiles = TILES_X * TILES_Y
      local cacheTiles = libs.tileLoader.getCacheCount and libs.tileLoader.getCacheCount() or 0
      local queueTiles = libs.tileLoader.getQueueLength and libs.tileLoader.getQueueLength() or 0
      local totalTiles = cacheTiles + queueTiles
      libs.utils.logDebug("TILE", string.format("VIEWPORT_CHANGE | viewport=%dx%d | raster=%dx%d | rasterTiles=%d | cache=%d | queue=%d | total=%d", w, h, TILES_X, TILES_Y, gridTiles, cacheTiles, queueTiles, totalTiles), true)
    end
  end

  local vehicleR = math.floor(34 * math.min(scaleX, scaleY))

  local doStateUpdate = allowStateUpdate ~= false

  if telemetry.lat ~= nil and telemetry.lon ~= nil then
    if doStateUpdate then
      tile_x, tile_y, offset_x, offset_y = mapLib.coord_to_tiles(telemetry.lat, telemetry.lon, level)
      local rawLeadX, rawLeadY = getDirectionalLeadFromHeading(heading)
      local leadX, leadY = gateLeadByTileOffset(rawLeadX, rawLeadY, offset_x, offset_y)
      local prefetchLeadX, prefetchLeadY = gatePrefetchByTileOffset(rawLeadX, rawLeadY, offset_x, offset_y)
      myScreenX, myScreenY = mapLib.getScreenCoordinates(MAP_X, MAP_Y, tile_x, tile_y, offset_x, offset_y, level)

      local centerX = x + (w / 2)
      local centerY = y + (h / 2)
      if myScreenX == nil or myScreenY == nil or
         math.abs(centerX - myScreenX) > RASTER_REBUILD_OFFSET_THRESHOLD or
         math.abs(centerY - myScreenY) > RASTER_REBUILD_OFFSET_THRESHOLD then
        mapNeedsHeavyUpdate = true
      end

      mapLib.loadAndCenterTiles(tile_x, tile_y, offset_x, offset_y, TILES_X, level, leadX, leadY, prefetchLeadX, prefetchLeadY)
      myScreenX, myScreenY = mapLib.getScreenCoordinates(MAP_X, MAP_Y, tile_x, tile_y, offset_x, offset_y, level)

      widget.drawOffsetX = centerX - myScreenX
      widget.drawOffsetY = centerY - myScreenY
    end
  end

  local minX = math.max(0, MAP_X)
  local minY = math.max(0, MAP_Y)
  local maxX = math.min(minX + w, minX + TILES_X * TILES_SIZE)
  local maxY = math.min(minY + h, minY + TILES_Y * TILES_SIZE)
  local renderOffsetX = widget.drawOffsetX
  local renderOffsetY = widget.drawOffsetY

  -- Clamp render offset so the drawn tile grid always fully covers the viewport.
  local minRenderOffsetX = w - TILES_X * TILES_SIZE
  local minRenderOffsetY = h - TILES_Y * TILES_SIZE
  if renderOffsetX > 0 then
    renderOffsetX = 0
  elseif renderOffsetX < minRenderOffsetX then
    renderOffsetX = minRenderOffsetX
  end
  if renderOffsetY > 0 then
    renderOffsetY = 0
  elseif renderOffsetY < minRenderOffsetY then
    renderOffsetY = minRenderOffsetY
  end

  -- Save UAV tile coords before home calculation (which temporarily overwrites them).
  local uav_tile_x, uav_tile_y = tile_x, tile_y
  local uav_offset_x, uav_offset_y = offset_x, offset_y

  if status.getTime() - lastHomePosUpdate > 20 then
    lastHomePosUpdate = status.getTime()
    if homeNeedsRefresh then
      homeNeedsRefresh = false
      if telemetry.homeLat ~= nil and telemetry.homeLon ~= nil then
        local h_x, h_y, h_ox, h_oy = mapLib.coord_to_tiles(telemetry.homeLat, telemetry.homeLon, level)
        homeScreenX, homeScreenY = mapLib.getScreenCoordinates(MAP_X, MAP_Y, h_x, h_y, h_ox, h_oy, level)
      end
    else
      homeNeedsRefresh = true
      estimatedHomeGps.lat, estimatedHomeGps.lon = libs.utils.getLatLonFromAngleAndDistance(telemetry.homeAngle, telemetry.homeDist)
      if estimatedHomeGps.lat ~= nil then
        local e_x, e_y, e_ox, e_oy = mapLib.coord_to_tiles(estimatedHomeGps.lat, estimatedHomeGps.lon, level)
        estimatedHomeScreenX, estimatedHomeScreenY = mapLib.getScreenCoordinates(MAP_X, MAP_Y, e_x, e_y, e_ox, e_oy, level)
      end
    end
  end

  local trailResolution = tonumber((status and status.conf and status.conf.mapTrailResolution) or 0) or 0
  if trailResolution > 0 and doStateUpdate and telemetry.lat ~= nil and telemetry.lon ~= nil
      and (telemetry.lat ~= 0 or telemetry.lon ~= 0) then
    if trailLastLat ~= nil then
      local delta = libs.utils.haversine(trailLastLat, trailLastLon, telemetry.lat, telemetry.lon)
      trailAccumDist = trailAccumDist + delta
    end
    trailLastLat = telemetry.lat
    trailLastLon = telemetry.lon
    if trailWpCount == 0 then
      -- First GPS fix: place initial anchor so the dynamic segment starts immediately.
      trailWpCount = 1
      trailHead = 1
      trailWaypoints[1] = { telemetry.lat, telemetry.lon }
      trailCachedLevel = nil  -- force reproject on next paint
    elseif trailAccumDist >= trailResolution then
      -- Angle check: compute the bend between the last committed segment and the
      -- pending segment (last WP → current UAV position).  Only commit when the
      -- angle exceeds the configured threshold.
      local bendExceeded = true
      if trailWpCount >= 2 then
        -- Find the previous waypoint (N-1) in the ring-buffer.
        local prevIdx
        if trailWpCount < TRAIL_MAX_WAYPOINTS then
          prevIdx = trailHead - 1
        else
          prevIdx = ((trailHead - 2) % TRAIL_MAX_WAYPOINTS) + 1
        end
        local prevWp = trailWaypoints[prevIdx]
        local headWp = trailWaypoints[trailHead]
        -- Vectors: segment A (prevWp → headWp) and segment B (headWp → UAV)
        local ax, ay = headWp[2] - prevWp[2], headWp[1] - prevWp[1]
        local bx, by = telemetry.lon - headWp[2], telemetry.lat - headWp[1]
        -- Angle between the two segments via atan2 of cross/dot product.
        local cross = ax * by - ay * bx
        local dot   = ax * bx + ay * by
        local bendDeg = math.abs(math.deg(math.atan(cross, dot)))
        local threshold = tonumber((status.conf and status.conf.mapTrailHeadingThreshold) or 5) or 5
        bendExceeded = (bendDeg >= threshold)
      end
      if bendExceeded then
        trailAccumDist = 0
        local newSlot
        if trailWpCount < TRAIL_MAX_WAYPOINTS then
          trailWpCount = trailWpCount + 1
          trailHead = trailWpCount
          newSlot = trailWpCount
          trailWaypoints[newSlot] = { telemetry.lat, telemetry.lon }
        else
          -- Ring-buffer: overwrite oldest slot (O(1) instead of O(n) table.remove)
          trailHead = (trailHead % TRAIL_MAX_WAYPOINTS) + 1
          newSlot = trailHead
          trailWaypoints[newSlot] = { telemetry.lat, telemetry.lon }
        end
        -- Update tile-pixel cache for the new slot inline (avoids full reproject).
        if trailCachedLevel ~= nil then
          local tx, ty, ox, oy = mapLib.coord_to_tiles(telemetry.lat, telemetry.lon, trailCachedLevel)
          trailTpx[newSlot] = tx * TILES_SIZE + ox
          trailTpy[newSlot] = ty * TILES_SIZE + oy
        end
      end
    end
  elseif trailResolution == 0 and trailWpCount > 0 then
    -- Trail disabled: free waypoint memory immediately.
    mapLib.clearTrail()
  end

  mapLib.drawTiles(TILES_X, minX + renderOffsetX, minY + renderOffsetY)

  if myScreenX ~= nil and myScreenY ~= nil then
    local drawX = myScreenX + renderOffsetX
    local drawY = myScreenY + renderOffsetY
    if heading ~= nil then
      libs.drawLib.drawRArrow(drawX, drawY, vehicleR - 5, heading, colors.white)
      libs.drawLib.drawRArrow(drawX, drawY, vehicleR, heading, colors.black)
    else
      lcd.color(WHITE)
      lcd.drawCircle(drawX, drawY, vehicleR - 3)
      lcd.color(BLACK)
      lcd.drawCircle(drawX, drawY, vehicleR)
    end
  end

  if telemetry.homeLat ~= nil and telemetry.homeLon ~= nil and myScreenX ~= nil and uav_tile_x ~= nil then
    local htx, hty, hox, hoy = mapLib.coord_to_tiles(telemetry.homeLat, telemetry.homeLon, level)
    local homeDrawX = myScreenX + (htx - uav_tile_x) * TILES_SIZE + (hox - uav_offset_x) + renderOffsetX
    local homeDrawY = myScreenY + (hty - uav_tile_y) * TILES_SIZE + (hoy - uav_offset_y) + renderOffsetY
    local homeCode = libs.drawLib.computeOutCode(homeDrawX, homeDrawY, x + 11, y + 10, x + w - 11, y + h - 10)
    if homeCode == 0 then
      libs.drawLib.drawBitmap(homeDrawX - 11, homeDrawY - 10, "homeorange")
    end
  end

  if trailResolution > 0 and trailWpCount >= 1 and myScreenX ~= nil and uav_tile_x ~= nil then
    lcd.color(colors.yellow)
    lcd.pen(SOLID)
    local clipLine = libs.drawLib.clipLine
    local baseX = myScreenX - uav_tile_x * TILES_SIZE - uav_offset_x + renderOffsetX
    local baseY = myScreenY - uav_tile_y * TILES_SIZE - uav_offset_y + renderOffsetY

    -- Reproject trail waypoints only when zoom level changes (expensive trig).
    if trailCachedLevel ~= level then
      local coordToTiles = mapLib.coord_to_tiles
      for i = 1, trailWpCount do
        local slot
        if trailWpCount < TRAIL_MAX_WAYPOINTS then
          slot = i
        else
          slot = ((trailHead + i - 1) % TRAIL_MAX_WAYPOINTS) + 1
        end
        local wp = trailWaypoints[slot]
        local tx, ty, ox, oy = coordToTiles(wp[1], wp[2], level)
        trailTpx[slot] = tx * TILES_SIZE + ox
        trailTpy[slot] = ty * TILES_SIZE + oy
      end
      trailCachedLevel = level
    end

    -- Iterate ring-buffer in insertion order (oldest to newest).
    -- Segments shorter than MIN_TRAIL_PX are skipped to reduce draw calls.
    local MIN_TRAIL_PX_SQ = 15 * 15  -- squared to avoid sqrt per segment
    local anchorSX, anchorSY = nil, nil
    for k = 1, trailWpCount do
      -- Ring-buffer index: oldest is (trailHead % trailWpCount) + 1 when full.
      local idx
      if trailWpCount < TRAIL_MAX_WAYPOINTS then
        idx = k
      else
        idx = ((trailHead + k - 1) % TRAIL_MAX_WAYPOINTS) + 1
      end
      local sx = baseX + trailTpx[idx]
      local sy = baseY + trailTpy[idx]
      if anchorSX then
        local dx, dy = sx - anchorSX, sy - anchorSY
        if dx * dx + dy * dy >= MIN_TRAIL_PX_SQ then
          local cx1, cy1, cx2, cy2 = clipLine(anchorSX, anchorSY, sx, sy, x, y, x + w, y + h)
          if cx1 then lcd.drawLine(cx1, cy1, cx2, cy2) end
          anchorSX, anchorSY = sx, sy
        end
        -- else: segment too short, keep anchor, skip draw
      else
        anchorSX, anchorSY = sx, sy
      end
    end
    -- Dynamic segment: newest waypoint to current UAV position.
    if anchorSX then
      local uavX, uavY = myScreenX + renderOffsetX, myScreenY + renderOffsetY
      local cx1, cy1, cx2, cy2 = clipLine(anchorSX, anchorSY, uavX, uavY, x, y, x + w, y + h)
      if cx1 then lcd.drawLine(cx1, cy1, cx2, cy2) end
    end
  end

  if zoomUpdate then
    lcd.color(WHITE)
    lcd.font(FONT_XL)
    lcd.drawText(x + w/2, y + h/2 - 25*scaleY, string.format("ZOOM %d", level), CENTERED)
    if status.getTime() - zoomUpdateTimer > 100 then zoomUpdate = false end
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
  local mapType = (status and status.conf and status.conf.mapType) or ""
  if level ~= lastZoomLevel or provider ~= lastMapProvider or mapType ~= lastMapType or lastZoomLevel == -99 then
    zoomUpdateTimer = status.getTime()
    zoomUpdate = true

    libs.resetLib.clearTable(tiles)
    libs.tileLoader.clearCache()

    world_tiles = mapLib.tiles_on_level(level)
    tiles_per_radian = world_tiles / (2 * math.pi)
    configureProjectionHelpers(provider)
    tile_dim = (40075017/world_tiles) * status.conf.distUnitScale
    local scaleDistance = getScaleDistanceForLevel(level)
    scaleLabel = string.format("%.0f%s", scaleDistance, status.conf.distUnitLabel)
    scaleLen = (scaleDistance/tile_dim)*TILES_SIZE

    lastZoomLevel = level
    lastMapProvider = provider
    lastMapType = mapType
  end
end

function mapLib.clearTrail()
  -- Resets the GPS trail ring-buffer. Called on disable and user reset.
  libs.resetLib.clearTable(trailWaypoints)
  libs.resetLib.clearTable(trailTpx)
  libs.resetLib.clearTable(trailTpy)
  trailWpCount = 0
  trailHead = 0
  trailAccumDist = 0
  trailLastLat = nil
  trailLastLon = nil
  trailCachedLevel = nil
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

  scaleLabel = string.format("%.0f%s", scaleDistance, status.conf.distUnitLabel)
  scaleLen = (scaleDistance/tile_dim)*TILES_SIZE

  return scaleLen, scaleLabel
end

function mapLib.setNeedsHeavyUpdate()
  -- Flags the next draw cycle to rebuild the visible tile set instead of relying on throttled reuse.
  mapNeedsHeavyUpdate = true
end

return mapLib