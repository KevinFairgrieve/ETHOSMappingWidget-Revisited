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

function drawLib.drawText(x, y, txt, font, color, flags, blink)
  -- Draws text with optional blinking support
  lcd.font(font)
  lcd.color(color)
  if status.blinkon == true or blink == nil or blink == false then
    lcd.drawText(x, y, txt, flags)
  end
end

function drawLib.drawNumber(x, y, num, precision, font, color, flags, blink)
  -- Draws a number with optional blinking support
  lcd.font(font)
  lcd.color(color)
  if status.blinkon == true or blink == nil or blink == false then
    lcd.drawNumber(x, y, num, nil, precision, flags)
  end
end

function drawLib.resetBacklightTimeout()
  -- Resets the screen backlight timeout (Ethos API call)
  if system and system.resetBacklightTimeout then
    system.resetBacklightTimeout()
  end
end

function drawLib.drawNoTelemetryData(widget)
  -- Shows "NO TELEMETRY" warning box when no data is received
  if not libs.utils.telemetryEnabled() then
    local w = status.widgetWidth
    local h = status.widgetHeight
    local sx = status.scaleX
    local sy = status.scaleY

    local fontBig = (w < 450) and FONT_L or FONT_XXL
    local fontSmall = (w < 450) and FONT_S or FONT_STD

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
  -- Shows "...waiting for GPS" warning box when no GPS fix
  local w = status.widgetWidth
  local h = status.widgetHeight
  local sx = status.scaleX
  local sy = status.scaleY

  local fontBig = (w < 450) and FONT_L or FONT_XXL

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
  -- Placeholder: HUD compass ribbon drawing is currently disabled
end

function drawLib.drawWindArrow(widget, ...)
  -- Placeholder: HUD wind arrow drawing is currently disabled
end

function drawLib.drawTopBar(widget)
  -- Draws the top black bar with model name, TX voltage and user sensors
  local w = status.widgetWidth
  local sx = status.scaleX
  local sy = status.scaleY

  lcd.color(status.colors.barBackground)
  lcd.pen(SOLID)
  lcd.drawFilledRectangle(0, 0, w, math.floor(26 * sy))

  if w >= 450 then
    drawLib.drawText(8*sx, 2*sy, status.modelString or model.name(), FONT_L, status.colors.barText, LEFT)
  end

  local offset = 12*sx
  offset = offset + drawLib.drawTopBarSensor(widget, w - offset, system.getSource({category=CATEGORY_SYSTEM, member=MAIN_VOLTAGE, options=0}), "TX")
  offset = offset + drawLib.drawTopBarSensor(widget, w - offset, status.conf.linkQualitySource)

  if status.conf.userSensor1 and status.conf.userSensor1:name() ~= "---" then
    offset = offset + drawLib.drawTopBarSensor(widget, w - offset, status.conf.userSensor1)
  end
  if status.conf.userSensor2 and status.conf.userSensor2:name() ~= "---" then
    offset = offset + drawLib.drawTopBarSensor(widget, w - offset, status.conf.userSensor2)
  end
  if status.conf.userSensor3 and status.conf.userSensor3:name() ~= "---" then
    offset = offset + drawLib.drawTopBarSensor(widget, w - offset, status.conf.userSensor3)
  end
end

function drawLib.drawTopBarSensor(widget, x, sensor, label)
  -- Helper to draw a single sensor value in the top bar
  if sensor == nil or sensor:name() == "---" then
    return 80
  end

  local barFont = (status.widgetWidth < 450) and FONT_S or FONT_L
  local lblFont = FONT_XS

  local name = label or sensor:name()
  if status.widgetWidth < 450 then
    name = string.sub(name, 1, 4)
  end

  lcd.font(barFont)
  local valW = lcd.getTextSize(sensor:stringValue())
  lcd.font(lblFont)
  local lblW = lcd.getTextSize(name)

  drawLib.drawText(x - valW - 2, 2, name, lblFont, status.colors.barText, RIGHT)
  drawLib.drawText(x - valW, 0, sensor:stringValue(), barFont, status.colors.barText, LEFT)

  return valW + lblW + 10
end

function drawLib.drawRArrow(x,y,r,angle,color)
  -- Draws a rotated arrow (used for home direction and UAV symbol)
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
  -- Draws a cached bitmap from the bitmaps folder
  lcd.drawBitmap(x, y, drawLib.getBitmap(bitmap), w, h)
end

function drawLib.drawBlinkBitmap(x, y, bitmap, w, h)
  -- Draws a bitmap only when blink is active
  if status.blinkon == true then
    lcd.drawBitmap(x, y, drawLib.getBitmap(bitmap), w, h)
  end
end

function drawLib.getBitmap(name)
  -- Loads and caches bitmap from SD card (lazy loading)
  if bitmaps[name] == nil then
    bitmaps[name] = lcd.loadBitmap("/bitmaps/ethosmaps/bitmaps/"..name..".png")
  end
  return bitmaps[name]
end

function drawLib.unloadBitmap(name)
  -- Unloads a bitmap from memory and forces garbage collection
  if bitmaps[name] ~= nil then
    bitmaps[name] = nil
    collectgarbage()
    collectgarbage()
  end
end

function drawLib.drawLineWithClippingXY(x0, y0, x1, y1, xmin, ymin, xmax, ymax)
  -- Draws a line with clipping to a rectangular area
  lcd.setClipping(xmin, ymin, xmax-xmin, ymax-ymin)
  lcd.drawLine(x0,y0,x1,y1)
  lcd.setClipping()
end

function drawLib.drawLineWithClipping(ox, oy, angle, len, xmin,ymin, xmax, ymax)
  -- Draws a line of given length and angle with clipping
  local xx = math.cos(math.rad(angle)) * len * 0.5
  local yy = math.sin(math.rad(angle)) * len * 0.5

  local x0 = ox - xx
  local x1 = ox + xx
  local y0 = oy - yy
  local y1 = oy + yy

  drawLib.drawLineWithClippingXY(x0,y0,x1,y1,xmin,ymin,xmax,ymax)
end

function drawLib.computeOutCode(x,y,xmin,ymin,xmax,ymax)
  -- Computes Cohen-Sutherland outcode for clipping tests
  local code = 0
  if x < xmin then code = code | 1 end
  if x > xmax then code = code | 2 end
  if y < ymin then code = code | 8 end
  if y > ymax then code = code | 4 end
  return code
end

function drawLib.isInside(x,y,xmin,ymin,xmax,ymax)
  -- Returns true if point is inside the given rectangle
  return drawLib.computeOutCode(x,y,xmin,ymin,xmax,ymax) == 0
end

function drawLib.drawHomeIcon(x,y)
  -- Draws the small orange home icon
  drawLib.drawBitmap(x,y,"minihomeorange")
end

function drawLib.init(param_status, param_libs)
  -- Initializes the draw library and stores references to status and libs
  status = param_status
  libs = param_libs
  return drawLib
end

return drawLib