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

local function drawBarSensor(x, y, label, value, unit, font, label_font, unit_font, color, label_color, blink, flags)
  -- Draws one labeled sensor readout for the layout bars and returns the width consumed by the rendered block.
  lcd.font(label_font)
  local lw, lh = lcd.getTextSize(label)
  local sw, sh = lcd.getTextSize(" ")
  lcd.font(unit_font)
  local uw, uh = lcd.getTextSize(unit)
  lcd.font(font)
  local vw, vh = lcd.getTextSize(value)

  if flags == RIGHT then
    libs.drawLib.drawText(x, y+vh-uh, unit, unit_font, color, RIGHT, blink)
    libs.drawLib.drawText(x-uw, y, value, font, color, RIGHT, blink)
    libs.drawLib.drawText(x-(uw+sw+vw), y+vh-lh, label, label_font, label_color, RIGHT, blink)
  else
    libs.drawLib.drawText(x, y+vh-lh, label, label_font, label_color, LEFT, blink)
    libs.drawLib.drawText(x+lw+sw, y, value, font, color, LEFT, blink)
    libs.drawLib.drawText(x+lw+sw+vw, y+vh-uh, unit, unit_font, color, LEFT, blink)
  end
  return lw + vw + uw + 3*sw
end

function panel.draw(widget)
  -- Renders the default layout by combining the map, status bars, warnings, and navigation overlays from shared widget state.
  local w = status.widgetWidth
  local h = status.widgetHeight
  local sx = status.scaleX
  local sy = status.scaleY

  -- Detect compact screen classes so overlays can scale down without overlapping the map.
  local verticalTiny = (w < 350)
  local horizontalTiny = (h < 200)
  local ultraTiny = verticalTiny and horizontalTiny

  -- Derive the map viewport after reserving space for the top and bottom bars.
  local topH    = (horizontalTiny or verticalTiny) and 0 or math.floor(26 * sy)
  local bottomH = horizontalTiny and 0 or math.floor(46 * sy)
  local mapY    = topH
  local mapH    = h - topH - bottomH

  -- Request a full tile refresh only when position or zoom state actually changed.
  if status.telemetry.lat ~= (status.mapLastLat or 0) or 
     status.telemetry.lon ~= (status.mapLastLon or 0) or 
     status.mapZoomLevel ~= (status.mapLastZoom or 0) then
    libs.mapLib.setNeedsHeavyUpdate()
    status.mapLastLat = status.telemetry.lat
    status.mapLastLon = status.telemetry.lon
    status.mapLastZoom = status.mapZoomLevel
  end

  libs.mapLib.drawMap(widget, 0, mapY, w, mapH, status.mapZoomLevel, 8, 5, status.telemetry.cog)

  -- Draw the top bar and text overlays only when the layout has enough vertical space.
  if not (horizontalTiny or verticalTiny) then
    lcd.color(lcd.RGB(0,0,0))
    lcd.pen(SOLID)
    lcd.drawFilledRectangle(0, 0, w, topH)
    lcd.drawFilledRectangle(0, h - bottomH, w, bottomH)

    libs.drawLib.drawTopBar()

    local overlayFont = (w < 450) and FONT_S or FONT_L
    lcd.font(overlayFont)

    local gpsText = status.telemetry.strLat .. " " .. status.telemetry.strLon
    local tw, th = lcd.getTextSize(gpsText)
    lcd.color(lcd.RGB(0,0,0,0.45))
    lcd.drawFilledRectangle(w - tw - 12*sx, mapY + 8*sy, tw + 12*sx, th + 6*sy)
    lcd.color(status.colors.white)
    lcd.drawText(w - tw - 6*sx, mapY + 9*sy, gpsText)

    local zoomText = "zoom " .. tostring(status.mapZoomLevel)
    local zw, zh = lcd.getTextSize(zoomText)
    lcd.color(lcd.RGB(0,0,0,0.45))
    lcd.drawFilledRectangle(8*sx, mapY + 8*sy, zw + 12*sx, zh + 6*sy)
    lcd.color(status.colors.white)
    lcd.drawText(12*sx, mapY + 9*sy, zoomText)
  end

  -- Draw the bottom flight-data bar except on the narrowest horizontal layouts.
  if not horizontalTiny then
    lcd.color(lcd.RGB(0,0,0))
    lcd.pen(SOLID)
    lcd.drawFilledRectangle(0, h - bottomH, w, bottomH)

    local labelColor = lcd.RGB(170,170,170)
    local yBottom = h - bottomH + 6*sy
    local barFont = (w < 450) and FONT_S or FONT_L
    local spacing = (w < 450) and 8*sx or 22*sx

    local gspdLabel   = (w < 450) and "GS" or "GSpd"
    local homeLabel   = (w < 450) and "HD" or "HomeDist"

    if verticalTiny then
      local offset = drawBarSensor(12*sx, yBottom, gspdLabel,
        string.format("%.01f", status.avgSpeed.value * status.conf.horSpeedMultiplier),
        status.conf.horSpeedLabel, barFont, FONT_S, FONT_S, status.colors.white, labelColor, false)

      drawBarSensor(w - 120*sx, yBottom, homeLabel,
        string.format("%.01f", status.telemetry.homeDist * status.conf.distUnitScale),
        status.conf.distUnitLabel, barFont, FONT_S, FONT_S, status.colors.white, labelColor, false, RIGHT)
    else
      local offset = drawBarSensor(12*sx, yBottom, gspdLabel,
        string.format("%.01f", status.avgSpeed.value * status.conf.horSpeedMultiplier),
        status.conf.horSpeedLabel, barFont, FONT_S, FONT_S, status.colors.white, labelColor, false)

      offset = offset + drawBarSensor(offset + spacing, yBottom, "HDG",
        string.format("%.0f", status.telemetry.cog or 0), "°",
        barFont, FONT_S, FONT_STD, status.colors.white, labelColor, false)

      local travelOffset = drawBarSensor(w, yBottom, "TR",
        string.format("%.01f", status.avgSpeed.travelDist * status.conf.distUnitLongScale),
        status.conf.distUnitLongLabel, barFont, FONT_S, FONT_S, status.colors.white, labelColor, false, RIGHT)

      drawBarSensor(w - travelOffset - spacing - 15*sx, yBottom, homeLabel,
        string.format("%.01f", status.telemetry.homeDist * status.conf.distUnitScale),
        status.conf.distUnitLabel, barFont, FONT_S, FONT_S, status.colors.white, labelColor, false, RIGHT)
    end
  end

  -- Draw the home-direction arrow whenever a home position is available.
  if status.telemetry.homeLat ~= nil and status.telemetry.homeLon ~= nil then
    local arrowSize = math.floor(42 * math.min(sx, sy))
    local arrowX = w - arrowSize * 1.2
    local arrowY = horizontalTiny and (h - 55*sy) or (h - bottomH + (bottomH / 2) - 60*sy)

    local homeHeading = status.telemetry.homeAngle - (status.telemetry.yaw or status.telemetry.cog or 0)
    libs.drawLib.drawRArrow(arrowX, arrowY, arrowSize - 7, math.floor(homeHeading), status.colors.yellow)
    libs.drawLib.drawRArrow(arrowX, arrowY, arrowSize, math.floor(homeHeading), status.colors.black)
  end

  -- Warn the pilot when live GPS is present but no home position has been stored yet.
  if status.telemetry.lat ~= nil and (status.telemetry.homeLat == nil or status.telemetry.homeLon == nil) then
    local warningText = "WARNING: HOME NOT SET!"
    local font = (w < 450) and FONT_S or FONT_L
    local tw, th = lcd.getTextSize(warningText)

    local basePadding = (w < 450) and 45*sx or 120*sx
    local maxBoxW = math.floor(w * 0.85)
    local boxW = math.min(tw + basePadding, maxBoxW)
    local boxH = th + 18*sy
    local boxX = math.floor((w - boxW) / 2)

    local boxY
    if horizontalTiny then
      boxY = mapY + 40*sy
    elseif w < 450 then
      boxY = h - bottomH - boxH - 50*sy
    else
      boxY = h - bottomH - boxH - 5*sy
    end

    lcd.color(lcd.RGB(0, 0, 0, 0.45))
    lcd.drawFilledRectangle(boxX, boxY, boxW, boxH)

    lcd.color(WHITE)
    lcd.drawRectangle(boxX, boxY, boxW, boxH, 2)

    lcd.color(status.colors.yellow)
    libs.drawLib.drawText(boxX + boxW/2, boxY + (boxH - th) / 2 - 3*sy, warningText, font, status.colors.yellow, CENTERED, true)
  end

  -- Draw the map scale bar when the viewport is large enough to keep it readable.
  if not ultraTiny then
    local scaleLen, scaleLabel = libs.mapLib.calculateScale(status.mapZoomLevel)
    if scaleLen ~= 0 then
      local scaleFont = (w < 450) and FONT_S or FONT_STD
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