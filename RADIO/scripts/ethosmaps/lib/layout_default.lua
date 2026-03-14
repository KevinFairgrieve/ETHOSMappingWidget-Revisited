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
  return os.clock()*100 -- 1/100th
end


local panel = {}

local status = nil
local libs = nil

local function drawBarSensor(x,y,label,value,unit,font,label_font,unit_font,color,label_color,blink,flags)
  lcd.font(label_font)
  local lw,lh = lcd.getTextSize(label)
  local sw,sh = lcd.getTextSize(" ")
  lcd.font(unit_font)
  local uw,uh = lcd.getTextSize(unit)
  lcd.font(font)
  local vw,vh = lcd.getTextSize(value)

  if flags == RIGHT then
    libs.drawLib.drawText(x, y+vh-uh, unit, unit_font, color, RIGHT, blink)
    libs.drawLib.drawText(x-uw, y, value, font, color,RIGHT,blink)
    libs.drawLib.drawText(x-(uw+sw+vw), y+vh-lh, label, label_font, label_color,RIGHT,blink)
  else
    libs.drawLib.drawText(x, y+vh-lh, label, label_font, label_color,LEFT,blink)
    libs.drawLib.drawText(x+lw+sw, y, value, font, color,LEFT,blink)
    libs.drawLib.drawText(x+lw+sw+vw, y+vh-uh, unit, unit_font, color,LEFT,blink)
  end
  return lw + vw + uw + 3*sw
end

function panel.draw(widget)
  local w = status.widgetWidth
  local h = status.widgetHeight
  local sx = status.scaleX
  local sy = status.scaleY

  -- === SUPER TINY MODE DEFINITION ===
  local verticalTiny = (w < 350)
  local horizontalTiny = (h < 200)
  local ultraTiny = verticalTiny and horizontalTiny

  -- Dynamische Karte
  local topH    = (horizontalTiny or verticalTiny) and 0 or math.floor(26 * sy)
  local bottomH = horizontalTiny and 0 or math.floor(46 * sy)
  local mapY    = topH
  local mapH    = h - topH - bottomH

  -- NEU Phase 1: Throttling-Trigger (nur bei echter Änderung laden)
  if status.telemetry.lat ~= (status.lastLat or 0) or 
     status.telemetry.lon ~= (status.lastLon or 0) or 
     status.mapZoomLevel ~= (status.lastZoom or 0) then
    libs.mapLib.setNeedsHeavyUpdate()
    status.lastLat = status.telemetry.lat
    status.lastLon = status.telemetry.lon
    status.lastZoom = status.mapZoomLevel
  end

  libs.mapLib.drawMap(widget, 0, mapY, w, mapH, status.mapZoomLevel, 8, 5, status.telemetry.cog)

  -- === Top-Bar + GPS/Zoom-Text nur bei NICHT verticalTiny und NICHT horizontalTiny ===
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

  -- === Bottom-Bar (schwarz) bleibt bei Vertical Tiny ===
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

  -- === Home-Pfeil – IMMER sichtbar ===
  if status.telemetry.homeLat ~= nil and status.telemetry.homeLon ~= nil then
    local arrowSize = math.floor(42 * math.min(sx, sy))
    local arrowX = w - arrowSize * 1.2
    local arrowY = horizontalTiny and (h - 55*sy) or (h - bottomH + (bottomH / 2) - 60*sy)

    local homeHeading = status.telemetry.homeAngle - (status.telemetry.yaw or status.telemetry.cog or 0)
    libs.drawLib.drawRArrow(arrowX, arrowY, arrowSize - 7, math.floor(homeHeading), status.colors.yellow)
    libs.drawLib.drawRArrow(arrowX, arrowY, arrowSize, math.floor(homeHeading), status.colors.black)
  end

    -- === Home Not Set Warning (85% Maximalbreite) ===
  if status.telemetry.lat ~= nil and (status.telemetry.homeLat == nil or status.telemetry.homeLon == nil) then
    local warningText = "WARNING: HOME NOT SET!"
    local font = (w < 450) and FONT_S or FONT_L
    local tw, th = lcd.getTextSize(warningText)

    -- Intelligentes Padding + harte Obergrenze (max 85% der Widget-Breite)
    local basePadding = (w < 450) and 45*sx or 120*sx
    local maxBoxW = math.floor(w * 0.85)          -- 85% Maximalbreite
    local boxW = math.min(tw + basePadding, maxBoxW)
    local boxH = th + 18*sy
    local boxX = math.floor((w - boxW) / 2)

    -- Position: Slim Mode höher, Horizontal Tiny oben, Fullscreen normal
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

    -- Debug: immer sichtbar
    --lcd.color(RED)
    --lcd.font(FONT_S)
    --lcd.drawText(8*sx, 8*sy + 80*sy, string.format("boxW = %.0f px (max 85%%)", boxW), LEFT)
  end

    -- === SCALE BAR – fester Abstand + Schriftwechsel + neuer Hintergrund ===
  if not ultraTiny then
    local scaleLen, scaleLabel = libs.mapLib.calculateScale(status.mapZoomLevel)
    if scaleLen ~= 0 then
      local scaleFont = (w < 450) and FONT_S or FONT_STD
      lcd.font(scaleFont)
      local labelW, labelH = lcd.getTextSize(scaleLabel)

      local scaleY_line  = mapY + mapH - 18*sy          -- Linie
      local scaleY_label = scaleY_line - labelH - 4*sy  -- fester Abstand unter der Linie

      -- Neuer Hintergrund (0.45 Transparenz, perfekt ausgerichtet)
      lcd.color(lcd.RGB(0, 0, 0, 0.45))
      lcd.drawFilledRectangle(8*sx, scaleY_label - 5*sy, scaleLen + 20*sx, labelH + 22*sy)

      -- Scale Bar selbst
      lcd.color(WHITE)
      lcd.drawLine(12*sx, scaleY_line, 12*sx + scaleLen, scaleY_line)
      lcd.drawText(12*sx, scaleY_label, scaleLabel)
    end
  end

  -- === DEBUG OVERLAY ===
  if false then
    local debugX = 12 * sx
    local debugY = math.floor(h / 2) - 48*sy
    local lineH  = 24 * sy

    lcd.color(lcd.RGB(0, 255, 100))
    lcd.font(FONT_S)

    lcd.drawText(debugX, debugY,                    string.format("Width:  %d px", w), LEFT)
    lcd.drawText(debugX, debugY + lineH,            string.format("Height: %d px", h), LEFT)
    lcd.drawText(debugX, debugY + 2*lineH,          string.format("Tiny Mode: %s", (h < 200) and "ON" or "OFF"), LEFT)
    lcd.drawText(debugX, debugY + 3*lineH,          string.format("Slim Mode: %s", (w < 450) and "ON" or "OFF"), LEFT)
    lcd.drawText(debugX, debugY + 4*lineH,          string.format("barFont: %s", barFont), LEFT)
  end
end

function panel.background(widget)
end

function panel.init(param_status, param_libs)
  status = param_status
  libs = param_libs
  return panel
end

return panel