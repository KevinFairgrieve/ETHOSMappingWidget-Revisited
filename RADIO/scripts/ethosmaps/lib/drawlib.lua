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


local status = nil
local libs = nil

local drawLib = {}
local bitmaps = {}
local topBarUnifiedFont = nil
local topBarValueCache = {}

local function safeSensorName(sensor)
  if sensor == nil then
    return nil
  end
  local ok, value = pcall(function() return sensor:name() end)
  if not ok or value == nil then
    return nil
  end
  value = tostring(value)
  if value == "" or value == "---" then
    return nil
  end
  return value
end

local function safeSensorValueText(sensor)
  if sensor == nil then
    return "--"
  end

  local barTickSerial = (status and status.barTickSerial) or 0
  local cacheKey = tostring(sensor)
  local sensorName = safeSensorName(sensor)
  if sensorName ~= nil then
    cacheKey = sensorName .. "|" .. cacheKey
  end

  local cached = topBarValueCache[cacheKey]
  if cached ~= nil and cached.tickSerial == barTickSerial then
    return cached.text
  end

  local valueText = "--"

  local okStr, text = pcall(function() return sensor:stringValue() end)
  if okStr and text ~= nil then
    valueText = tostring(text)
  else
    local okVal, value = pcall(function() return sensor:value() end)
    if okVal and value ~= nil then
      valueText = tostring(value)
    end
  end

  topBarValueCache[cacheKey] = {
    tickSerial = barTickSerial,
    text = valueText
  }

  return valueText
end

local function getFontRank(font)
  if font == FONT_XS then
    return 1
  elseif font == FONT_S then
    return 2
  elseif font == FONT_L then
    return 3
  end
  return 0
end

local function getTopBarSensorName(sensor, label, compactNames)
  local sensorName = safeSensorName(sensor)
  local name = label or sensorName or "SRC"
  if compactNames then
    name = string.sub(name, 1, 4)
  end
  return name
end

local function getTopBarSensorBlockWidth(name, valueText, barFont, labelFont)
  lcd.font(barFont)
  local valW = lcd.getTextSize(tostring(valueText or "--"))
  lcd.font(labelFont)
  local lblW = lcd.getTextSize(tostring(name or "SRC"))
  return valW + lblW + 10, valW
end

local function getTopBarLabelFont(valueFont)
  if valueFont == FONT_L then
    return FONT_XS
  elseif valueFont == FONT_S then
    return FONT_XS
  end
  return FONT_XS
end

function drawLib.drawText(x, y, txt, font, color, flags, blink)
  -- Draws text with the requested font and color, using the shared blink state to optionally suppress output.
  lcd.font(font)
  lcd.color(color)
  if status.blinkon == true or blink == nil or blink == false then
    lcd.drawText(x, y, txt, flags)
  end
end

function drawLib.drawNumber(x, y, num, precision, font, color, flags, blink)
  -- Draws a formatted number with optional blink gating and sends it directly to the LCD.
  lcd.font(font)
  lcd.color(color)
  if status.blinkon == true or blink == nil or blink == false then
    lcd.drawNumber(x, y, num, nil, precision, flags)
  end
end

function drawLib.resetBacklightTimeout()
  -- Requests a backlight timeout reset through Ethos so user-facing alerts keep the screen awake.
  if system and system.resetBacklightTimeout then
    system.resetBacklightTimeout()
  end
end

function drawLib.drawNoTelemetryData(widget)
  -- Draws the telemetry-loss warning overlay after querying the utility layer for current link availability.
  if not libs.utils.telemetryEnabled() then
    local w = status.widgetWidth
    local h = status.widgetHeight
    local sx = status.scaleX
    local sy = status.scaleY
    local verticalMedium = status.verticalMedium == true or (w < (status.compactWidthThreshold or 450))

    local fontBig = verticalMedium and FONT_L or FONT_XXL
    local fontSmall = verticalMedium and FONT_S or FONT_STD

    lcd.font(fontBig)
    local textW, textH = lcd.getTextSize("NO TELEMETRY")

    local boxW = math.min(math.floor(textW + 80*sx), math.floor(w * 0.88))
    local boxH = math.floor(textH + 55*sy)
    local boxX = math.floor((w - boxW) / 2)
    local boxY = math.floor((h / 2) - boxH / 2) - 15*sy

    lcd.color(RED)
    lcd.drawFilledRectangle(boxX, boxY, boxW, boxH)

    lcd.color(WHITE)
    lcd.drawRectangle(boxX, boxY, boxW, boxH, 3)

    lcd.font(fontBig)
    lcd.drawText(w / 2, boxY + 25*sy, "NO TELEMETRY", CENTERED)
  end
end

function drawLib.drawNoGPSData(widget)
  -- Draws the no-GPS overlay when the layout detects that no valid position is available.
  local w = status.widgetWidth
  local h = status.widgetHeight
  local sx = status.scaleX
  local sy = status.scaleY
  local verticalMedium = status.verticalMedium == true or (w < (status.compactWidthThreshold or 450))

  local fontBig = verticalMedium and FONT_L or FONT_XXL

  lcd.font(fontBig)
  local textW, textH = lcd.getTextSize("...waiting for GPS")

  local boxW = math.min(math.floor(textW + 80*sx), math.floor(w * 0.88))
  local boxH = math.floor(textH + 55*sy)
  local boxX = math.floor((w - boxW) / 2)
  local boxY = math.floor((h / 2) - boxH / 2) - 15*sy

  lcd.color(RED)
  lcd.drawFilledRectangle(boxX, boxY, boxW, boxH)

  lcd.color(WHITE)
  lcd.drawRectangle(boxX, boxY, boxW, boxH, 3)

  lcd.font(fontBig)
  lcd.drawText(w / 2, boxY + 25*sy, "...waiting for GPS", CENTERED)
end

function drawLib.drawCompassRibbon(widget, ...)
  -- Placeholder for a future compass ribbon renderer.
end

function drawLib.drawWindArrow(widget, ...)
  -- Placeholder for a future wind-arrow renderer.
end

function drawLib.drawTopBar(widget, barTop, barHeight)
  -- Draws the top status bar by combining model info, system voltage, and user-selected telemetry sources.
  local w = status.widgetWidth
  local sx = status.scaleX
  local sy = status.scaleY
  local top = barTop or 0
  local barH = barHeight or math.floor(26 * sy)
  local verticalMedium = status.verticalMedium == true or (w < (status.compactWidthThreshold or 450))
  local verticalTiny = w < (status.tinyWidthThreshold or 350)
  local showModelName = w >= 600
  local compactNames = verticalMedium

  local sensorEntries = {
    { sensor = system.getSource({category=CATEGORY_SYSTEM, member=MAIN_VOLTAGE, options=0}), label = "TX" },
    { sensor = status.conf.linkQualitySource, label = nil },
  }
  if not verticalTiny and safeSensorName(status.conf.userSensor1) ~= nil then
    table.insert(sensorEntries, { sensor = status.conf.userSensor1, label = nil })
  end
  if not verticalTiny and safeSensorName(status.conf.userSensor2) ~= nil then
    table.insert(sensorEntries, { sensor = status.conf.userSensor2, label = nil })
  end
  if not verticalTiny and safeSensorName(status.conf.userSensor3) ~= nil then
    table.insert(sensorEntries, { sensor = status.conf.userSensor3, label = nil })
  end

  local candidateFonts = verticalMedium and {FONT_S, FONT_XS} or {FONT_L, FONT_S, FONT_XS}
  local modelText = status.modelString or model.name()
  local selectedFont = candidateFonts[#candidateFonts]
  local selectedUsedWidth = 0
  local selectedAvailableWidth = 0
  for i = 1, #candidateFonts do
    local candidateFont = candidateFonts[i]
    local candidateLabelFont = getTopBarLabelFont(candidateFont)

    local minTelemetryX = 6 * sx
    if showModelName then
      lcd.font(candidateFont)
      local modelW = lcd.getTextSize(modelText)
      minTelemetryX = 8 * sx + modelW + 12 * sx
    end

    local usedWidth = 0
    for e = 1, #sensorEntries do
      local entry = sensorEntries[e]
      if safeSensorName(entry.sensor) ~= nil then
        local name = getTopBarSensorName(entry.sensor, entry.label, compactNames)
        local valueText = safeSensorValueText(entry.sensor)
        local blockW = getTopBarSensorBlockWidth(name, valueText, candidateFont, candidateLabelFont)
        usedWidth = usedWidth + blockW
      end
    end

    local availableWidth = math.max(20, (w - 12 * sx) - minTelemetryX)
    selectedFont = candidateFont
    selectedUsedWidth = usedWidth
    selectedAvailableWidth = availableWidth
    if usedWidth <= availableWidth then
      break
    end
  end

  local cachedFont = topBarUnifiedFont
  if cachedFont ~= nil and getFontRank(selectedFont) > getFontRank(cachedFont) then
    if (selectedAvailableWidth - selectedUsedWidth) < 12 then
      selectedFont = cachedFont
    end
  end
  topBarUnifiedFont = selectedFont

  local selectedLabelFont = getTopBarLabelFont(selectedFont)
  local minTelemetryX = 6 * sx

  lcd.color(status.colors.barBackground)
  lcd.pen(SOLID)
  lcd.drawFilledRectangle(0, top, w, barH)

  if showModelName then
    local modelY = top + math.floor(2 * sy)
    drawLib.drawText(8*sx, modelY, modelText, selectedFont, status.colors.barText, LEFT)
    lcd.font(selectedFont)
    local modelW = lcd.getTextSize(modelText)
    minTelemetryX = 8 * sx + modelW + 12 * sx
  end

  local offset = 12*sx
  for e = 1, #sensorEntries do
    local entry = sensorEntries[e]
    offset = offset + drawLib.drawTopBarSensor(widget, w - offset, entry.sensor, entry.label, minTelemetryX, selectedFont, selectedLabelFont, compactNames, top, barH)
  end
end

function drawLib.drawTopBarSensor(widget, x, sensor, label, minX, barFont, labelFont, compactNames, barTop, barHeight)
  -- Draws one top-bar sensor block by reading its current string value and writing the label/value pair to the LCD.
  if safeSensorName(sensor) == nil then
    return 80 -- Safeguard: skip invalid sensor handles and reserve a stable fallback width.
  end

  local name = getTopBarSensorName(sensor, label, compactNames)
  local valueText = safeSensorValueText(sensor)
  local blockW, valW = getTopBarSensorBlockWidth(name, valueText, barFont, labelFont)

  lcd.font(barFont)
  local _, valueH = lcd.getTextSize(valueText)
  local valueY = (barTop or 0) + math.floor(((barHeight or 0) - valueH) / 2)
  local labelY = valueY

  drawLib.drawText(x - valW - 2, labelY, name, labelFont, status.colors.barText, RIGHT)
  drawLib.drawText(x - valW, valueY, valueText, barFont, status.colors.barText, LEFT)

  return blockW
end

function drawLib.drawRArrow(x,y,r,angle,color)
  -- Draws a rotated arrow primitive used by the map for aircraft heading and home direction overlays.
  local ang = math.rad(angle - 90)
  local x1 = x + r * math.cos(ang)
  local y1 = y + r * math.sin(ang)

  ang = math.rad(angle - 90 + 150)
  local x2 = x + r * math.cos(ang)
  local y2 = y + r * math.sin(ang)

  ang = math.rad(angle - 90 - 150)
  local x3 = x + r * math.cos(ang)
  local y3 = y + r * math.sin(ang)

  ang = math.rad(angle - 270)
  local x4 = x + r * 0.5 * math.cos(ang)
  local y4 = y + r * 0.5 * math.sin(ang)

  lcd.pen(SOLID)
  lcd.color(color)
  lcd.drawLine(x1,y1,x2,y2)
  lcd.drawLine(x1,y1,x3,y3)
  lcd.drawLine(x2,y2,x4,y4)
  lcd.drawLine(x3,y3,x4,y4)
end

function drawLib.drawBitmap(x, y, bitmap, w, h)
  -- Draws a named bitmap by resolving it through the local bitmap cache first.
  local bmp = drawLib.getBitmap(bitmap)
  if bmp ~= nil then
    lcd.drawBitmap(x, y, bmp, w, h)
  end
end

function drawLib.drawBlinkBitmap(x, y, bitmap, w, h)
  -- Draws a bitmap only on active blink phases so warning icons can flash without state duplication.
  if status.blinkon == true then
    local bmp = drawLib.getBitmap(bitmap)
    if bmp ~= nil then
      lcd.drawBitmap(x, y, bmp, w, h)
    end
  end
end

function drawLib.getBitmap(name)
  -- Lazily loads a bitmap from the SD card and keeps it cached for repeated draw calls.
  if bitmaps[name] == nil then
    bitmaps[name] = lcd.loadBitmap("/bitmaps/ethosmaps/bitmaps/"..name..".png")
  end
  return bitmaps[name]
end

function drawLib.unloadBitmap(name)
  -- Removes a cached bitmap from memory and nudges Lua garbage collection to reclaim it.
  if bitmaps[name] ~= nil then
    bitmaps[name] = nil
    if status and status.perfProfileInc and status.conf and status.conf.enableDebugLog and status.conf.enablePerfProfile then
      status.perfProfileInc("gc_count", 2)
    end
    -- GC wird jetzt periodisch im wakeup() ausgeführt
  end
end

function drawLib.drawLineWithClippingXY(x0, y0, x1, y1, xmin, ymin, xmax, ymax)
  -- Draws a line segment inside a temporary clipping rectangle and restores unclipped drawing afterwards.
  lcd.setClipping(xmin, ymin, xmax-xmin, ymax-ymin)
  lcd.drawLine(x0,y0,x1,y1)
  lcd.setClipping()
end

function drawLib.drawLineWithClipping(ox, oy, angle, len, xmin,ymin, xmax, ymax)
  -- Converts an origin, angle, and length into endpoints and forwards the result to the clipped line renderer.
  local xx = math.cos(math.rad(angle)) * len * 0.5
  local yy = math.sin(math.rad(angle)) * len * 0.5

  local x0 = ox - xx
  local x1 = ox + xx
  local y0 = oy - yy
  local y1 = oy + yy

  drawLib.drawLineWithClippingXY(x0,y0,x1,y1,xmin,ymin,xmax,ymax)
end

function drawLib.computeOutCode(x,y,xmin,ymin,xmax,ymax)
  -- Computes a Cohen-Sutherland outcode so callers can test whether a point lies outside a viewport.
  local code = 0
  if x < xmin then code = code | 1 end
  if x > xmax then code = code | 2 end
  if y < ymin then code = code | 8 end
  if y > ymax then code = code | 4 end
  return code
end

function drawLib.isInside(x,y,xmin,ymin,xmax,ymax)
  -- Returns whether a point falls inside the requested rectangle by reusing computeOutCode().
  return drawLib.computeOutCode(x,y,xmin,ymin,xmax,ymax) == 0
end

function drawLib.drawHomeIcon(x,y)
  -- Draws the compact home icon bitmap used by map overlays.
  drawLib.drawBitmap(x,y,"minihomeorange")
end

function drawLib.init(param_status, param_libs)
  -- Stores shared state references so drawing helpers can read status values and call sibling libraries.
  status = param_status
  libs = param_libs
  topBarValueCache = {}
  return drawLib
end

return drawLib