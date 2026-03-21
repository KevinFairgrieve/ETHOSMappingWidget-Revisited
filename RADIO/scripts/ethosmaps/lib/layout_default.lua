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
  -- Converts Lua CPU time into centiseconds so layout timing stays aligned with the other libraries.
  return os.clock()*100
end


local panel = {}

local status = nil
local libs = nil
local MAP_TILE_SIZE = 100
local MAP_TILE_BUFFER_X = 1
local MAP_TILE_BUFFER_Y = 1
local MAP_MIN_TILES_X = 3
local MAP_MIN_TILES_Y = 3

local function getBarSnapshot()
  local barTickSerial = status.barTickSerial or 0

  if status.barSnapshot == nil then
    status.barSnapshot = {
      lastTickSerial = -1,
      groundSpeed = 0,
      heading = 0,
      travelDist = 0,
      homeDist = 0,
    }
  end

  if status.barSnapshot.lastTickSerial ~= barTickSerial then
    status.barSnapshot.groundSpeed = (status.avgSpeed and status.avgSpeed.value) or 0
    status.barSnapshot.heading = (status.telemetry and status.telemetry.cog) or 0
    status.barSnapshot.travelDist = (status.avgSpeed and status.avgSpeed.travelDist) or 0
    status.barSnapshot.homeDist = (status.telemetry and status.telemetry.homeDist) or 0
    status.barSnapshot.lastTickSerial = barTickSerial
  end

  return status.barSnapshot
end

local function drawBarSensor(x, barTop, barHeight, label, value, unit, font, label_font, unit_font, color, label_color, blink, flags)
  -- Draws one labeled sensor readout for the layout bars and returns the width consumed by the rendered block.
  lcd.font(label_font)
  local lw, lh = lcd.getTextSize(label)
  local sw, sh = lcd.getTextSize(" ")
  lcd.font(unit_font)
  local uw, uh = lcd.getTextSize(unit)
  lcd.font(font)
  local vw, vh = lcd.getTextSize(value)

  local valueY = barTop + math.floor((barHeight - vh) / 2)
  local valueBottomY = valueY + vh
  local labelY = valueBottomY - lh
  local unitY = valueBottomY - uh

  if flags == RIGHT then
    libs.drawLib.drawText(x, unitY, unit, unit_font, color, RIGHT, blink)
    libs.drawLib.drawText(x-uw, valueY, value, font, color, RIGHT, blink)
    libs.drawLib.drawText(x-(uw+sw+vw), labelY, label, label_font, label_color, RIGHT, blink)
  else
    libs.drawLib.drawText(x, labelY, label, label_font, label_color, LEFT, blink)
    libs.drawLib.drawText(x+lw+sw, valueY, value, font, color, LEFT, blink)
    libs.drawLib.drawText(x+lw+sw+vw, unitY, unit, unit_font, color, LEFT, blink)
  end
  return lw + vw + uw + 3*sw
end

function panel.draw(widget)
  -- Renders the default layout by combining the map, status bars, warnings, and navigation overlays from shared widget state.
  local w = status.widgetWidth
  local h = status.widgetHeight
  local sx = status.scaleX
  local sy = status.scaleY

  -- Guard: widget area too small to render meaningfully.
  if w < 200 or h < 100 then
    lcd.color(lcd.RGB(255, 220, 0))
    lcd.drawFilledRectangle(0, 0, w, h)
    lcd.color(lcd.RGB(0, 0, 0))
    lcd.font(FONT_STD)
    local line1 = "TOO SMALL!"
    local line2 = w .. " x " .. h .. " px"
    local line3 = "Min. 200x100"
    local tw1, th1 = lcd.getTextSize(line1)
    local tw2, th2 = lcd.getTextSize(line2)
    lcd.font(FONT_XS)
    local tw3, th3 = lcd.getTextSize(line3)
    local totalH = th1 + 4 + th2 + 2 + th3
    local startY = math.floor((h - totalH) / 2)
    lcd.font(FONT_STD)
    lcd.drawText(math.floor((w - tw1) / 2), startY, line1)
    lcd.drawText(math.floor((w - tw2) / 2), startY + th1 + 4, line2)
    lcd.font(FONT_XS)
    lcd.drawText(math.floor((w - tw3) / 2), startY + th1 + 4 + th2 + 2, line3)
    return
  end

  -- Detect compact screen classes so overlays can scale down without overlapping the map.
  local verticalTiny = (w < (status.tinyWidthThreshold or 350))
  local horizontalTiny = (h < (status.tinyHeightThreshold or 190))
  local verticalMedium = status.verticalMedium == true or (w < (status.compactWidthThreshold or 450))
  local ultraTiny = verticalTiny and horizontalTiny

  -- Derive the map viewport after reserving space for the top and bottom bars.
  local topH, bottomH
  if horizontalTiny then
    topH = 0
    bottomH = 0
  else
    local topValueFont = verticalMedium and FONT_S or FONT_L
    local topLabelFont = FONT_XS
    lcd.font(topValueFont)
    local _, topValueH = lcd.getTextSize("TX 99.9V")
    lcd.font(topLabelFont)
    local _, topLabelH = lcd.getTextSize("SRC")
    local topContentH = math.max(topValueH, topLabelH)
    topH = math.max(math.floor(26 * sy), topContentH + math.floor(8 * sy))

    local bottomValueFont = verticalMedium and FONT_S or FONT_L
    local bottomMetaFont = FONT_XS
    lcd.font(bottomValueFont)
    local _, bottomValueH = lcd.getTextSize("999.9")
    lcd.font(bottomMetaFont)
    local _, bottomMetaH = lcd.getTextSize("km/h")
    local bottomContentH = math.max(bottomValueH, bottomMetaH)
    bottomH = math.max(math.floor(46 * sy), bottomContentH + math.floor(12 * sy))
  end
  local mapY    = topH
  local mapH    = h - topH - bottomH
  local mapTilesX = math.max(MAP_MIN_TILES_X, math.ceil(w / MAP_TILE_SIZE) + MAP_TILE_BUFFER_X)
  local mapTilesY = math.max(MAP_MIN_TILES_Y, math.ceil(h / MAP_TILE_SIZE) + MAP_TILE_BUFFER_Y)

  local mapTickSerial = status.mapTickSerial or 0
  local zoomChanged = status.mapZoomLevel ~= (status.mapLastZoom or 0)
  local mapNeedsUpdate = status.mapRedrawPending == true or zoomChanged or mapTickSerial ~= (status.mapLastTickSerial or -1)

  if zoomChanged then
    libs.mapLib.setNeedsHeavyUpdate()
  end

  if mapNeedsUpdate then
    status.mapRedrawPending = false
    status.mapLastTickSerial = mapTickSerial
  end

  status.mapLastZoom = status.mapZoomLevel

  -- Draw the map viewport for the current layout.
  libs.mapLib.drawMap(widget, 0, mapY, w, mapH, status.mapZoomLevel, mapTilesX, mapTilesY, status.telemetry.cog, mapNeedsUpdate)

  -- Draw the dedicated left-side zoom buttons.
  local scaleFactor = 0.15 + 0.8 * status.scaleX
  local btnSize     = math.floor(52 * scaleFactor)
  local btnX        = 12 * status.scaleX

  -- In ultra-tiny mode, anchor buttons to top and bottom edges with symmetric margins.
  local btnYPlus, btnYMinus
  if ultraTiny then
    local edgeMargin = btnX
    btnYPlus  = edgeMargin
    btnYMinus = status.widgetHeight - btnSize - edgeMargin
  else
    btnYPlus  = 0.27 * status.widgetHeight
    btnYMinus = status.widgetHeight - 0.27 * status.widgetHeight - btnSize
  end

  -- Draw the actual zoom buttons.
  libs.drawLib.drawBitmap(btnX, btnYPlus, "zoom_plus", btnSize, btnSize)
  libs.drawLib.drawBitmap(btnX, btnYMinus, "zoom_minus", btnSize, btnSize)

  -- Draw the top bar and text overlays only when the layout has enough vertical space.
  if not horizontalTiny then
    lcd.color(lcd.RGB(0,0,0))
    lcd.pen(SOLID)
    lcd.drawFilledRectangle(0, 0, w, topH)
    lcd.drawFilledRectangle(0, h - bottomH, w, bottomH)

    libs.drawLib.drawTopBar(widget, 0, topH)

    local overlayFont = verticalMedium and FONT_XS or FONT_L
    lcd.font(overlayFont)

    local overlayPadX = math.max(6, math.floor(8 * sx))
    local overlayPadY = math.max(3, math.floor(4 * sy))
    local overlayMargin = math.max(6, math.floor(8 * sx))

    local gpsText = status.telemetry.strLat .. " " .. status.telemetry.strLon
    local gpsTw, gpsTh = lcd.getTextSize(gpsText)
    local gpsBoxW = gpsTw + 2 * overlayPadX
    local gpsBoxH = gpsTh + 2 * overlayPadY
    local gpsBoxX = math.max(overlayMargin, w - gpsBoxW - overlayMargin)
    local gpsBoxY = mapY + overlayMargin

    lcd.color(lcd.RGB(0,0,0,0.45))
    lcd.drawFilledRectangle(gpsBoxX, gpsBoxY, gpsBoxW, gpsBoxH)
    lcd.color(status.colors.white)
    lcd.drawText(gpsBoxX + math.floor((gpsBoxW - gpsTw) / 2), gpsBoxY + math.floor((gpsBoxH - gpsTh) / 2), gpsText)

    local zoomText = "zoom " .. tostring(status.mapZoomLevel)
    local zoomTw, zoomTh = lcd.getTextSize(zoomText)
    local zoomBoxW = zoomTw + 2 * overlayPadX
    local zoomBoxH = zoomTh + 2 * overlayPadY
    local zoomBoxX = overlayMargin
    local zoomBoxY = mapY + overlayMargin

    lcd.color(lcd.RGB(0,0,0,0.45))
    lcd.drawFilledRectangle(zoomBoxX, zoomBoxY, zoomBoxW, zoomBoxH)
    lcd.color(status.colors.white)
    lcd.drawText(zoomBoxX + math.floor((zoomBoxW - zoomTw) / 2), zoomBoxY + math.floor((zoomBoxH - zoomTh) / 2), zoomText)
  end

  -- Draw the bottom flight-data bar except on the narrowest horizontal layouts.
  if not horizontalTiny then
    local barSnapshot = getBarSnapshot()

    lcd.color(lcd.RGB(0,0,0))
    lcd.pen(SOLID)
    lcd.drawFilledRectangle(0, h - bottomH, w, bottomH)

    local labelColor = lcd.RGB(170,170,170)
    local barTop = h - bottomH
    local barFont = verticalMedium and FONT_S or FONT_L
    local barMetaFont = FONT_XS
    local spacing = verticalMedium and 8*sx or 22*sx
    local hideHomeDistAndHeading = w < (status.tinyWidthThreshold or 350)

    local gspdLabel   = verticalMedium and "GS" or "GSpd"
    local homeLabel   = verticalMedium and "HD" or "HomeDist"

    if hideHomeDistAndHeading then
      drawBarSensor(12*sx, barTop, bottomH, gspdLabel,
        string.format("%.01f", barSnapshot.groundSpeed * status.conf.horSpeedMultiplier),
        status.conf.horSpeedLabel, barFont, barMetaFont, barFont, status.colors.white, labelColor, false)

      drawBarSensor(w - 12*sx, barTop, bottomH, "TR",
        string.format("%.01f", barSnapshot.travelDist * status.conf.distUnitLongScale),
        status.conf.distUnitLongLabel, barFont, barMetaFont, barFont, status.colors.white, labelColor, false, RIGHT)
    else
      local offset = drawBarSensor(12*sx, barTop, bottomH, gspdLabel,
        string.format("%.01f", barSnapshot.groundSpeed * status.conf.horSpeedMultiplier),
        status.conf.horSpeedLabel, barFont, barMetaFont, barFont, status.colors.white, labelColor, false)

      offset = offset + drawBarSensor(12*sx + offset + spacing, barTop, bottomH, "HDG",
        string.format("%.0f", barSnapshot.heading or 0), "°",
        barFont, barMetaFont, barFont, status.colors.white, labelColor, false)

      local travelOffset = drawBarSensor(w, barTop, bottomH, "TR",
        string.format("%.01f", barSnapshot.travelDist * status.conf.distUnitLongScale),
        status.conf.distUnitLongLabel, barFont, barMetaFont, barFont, status.colors.white, labelColor, false, RIGHT)

      drawBarSensor(w - travelOffset - spacing - 15*sx, barTop, bottomH, homeLabel,
        string.format("%.01f", barSnapshot.homeDist * status.conf.distUnitScale),
        status.conf.distUnitLabel, barFont, barMetaFont, barFont, status.colors.white, labelColor, false, RIGHT)
    end
  end

  -- Draw the home-direction arrow whenever a home position is available.
  if status.telemetry.homeLat ~= nil and status.telemetry.homeLon ~= nil then
    local baseArrowSize = math.floor(42 * math.min(sx, sy))
    local arrowSize = baseArrowSize
    if ultraTiny then
      arrowSize = math.min(math.max(math.floor(baseArrowSize * 1.2), baseArrowSize + 4), baseArrowSize + 10)
    elseif horizontalTiny or verticalTiny then
      arrowSize = math.min(math.max(math.floor(baseArrowSize * 1.15), baseArrowSize + 2), baseArrowSize + 8)
    end

    local arrowX = w - arrowSize * 1.2
    local arrowY = horizontalTiny and (h - 55*sy - 20) or (h - bottomH + (bottomH / 2) - 60*sy - 20)

    local homeHeading = status.telemetry.homeAngle - (status.telemetry.yaw or status.telemetry.cog or 0)
    libs.drawLib.drawRArrow(arrowX, arrowY, arrowSize - 7, math.floor(homeHeading), status.colors.yellow)
    libs.drawLib.drawRArrow(arrowX, arrowY, arrowSize, math.floor(homeHeading), status.colors.black)
  end

  -- Warn the pilot when live GPS is present but no home position has been stored yet.
  if status.telemetry.lat ~= nil and (status.telemetry.homeLat == nil or status.telemetry.homeLon == nil) then
    local warningText = "WARNING: HOME NOT SET!"
    local font = verticalMedium and FONT_S or FONT_L
    lcd.font(font)
    local tw, th = lcd.getTextSize(warningText)

    local padX = math.max(8, math.floor(14 * sx))
    local padY = math.max(4, math.floor(8 * sy))
    local boxW = tw + 2 * padX
    local boxH = th + 2 * padY
    local boxX = math.floor((w - boxW) / 2)

    local boxY = math.floor((h - boxH) / 2)

    lcd.color(lcd.RGB(0, 0, 0, 0.45))
    lcd.drawFilledRectangle(boxX, boxY, boxW, boxH)

    lcd.color(WHITE)
    lcd.drawRectangle(boxX, boxY, boxW, boxH, 2)

    lcd.color(status.colors.yellow)
    libs.drawLib.drawText(boxX + boxW/2, boxY + (boxH - th) / 2, warningText, font, status.colors.yellow, CENTERED, true)
  end

    -- Draw the map scale bar when the viewport is large enough to keep it readable.
  if not ultraTiny then
    local scaleLen, scaleLabel = libs.mapLib.calculateScale(status.mapZoomLevel)
    if scaleLen ~= 0 then
      local scaleFont = verticalMedium and FONT_S or FONT_STD
      lcd.font(scaleFont)
      local labelW, labelH = lcd.getTextSize(scaleLabel)

      local scaleY_line  = mapY + mapH - 18*sy
      local scaleY_label = scaleY_line - labelH - 4*sy

      lcd.color(lcd.RGB(0, 0, 0, 0.45))
      lcd.drawFilledRectangle(8*sx, scaleY_label - 5*sy, scaleLen + 20*sx, labelH + 22*sy)

      lcd.color(WHITE)
      lcd.drawLine(12*sx, scaleY_line, 12*sx + scaleLen, scaleY_line)
      lcd.drawText(12*sx, scaleY_label, scaleLabel)
    end
  end

end

function panel.background(widget)
  -- Placeholder background callback required by Ethos when the widget is off-screen.
end

function panel.init(param_status, param_libs)
  -- Stores shared state references so the layout can read telemetry/config data and call drawing/map helpers.
  status = param_status
  libs = param_libs
  return panel
end

return panel