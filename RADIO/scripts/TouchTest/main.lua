--
-- TouchTest — Standalone ETHOS widget for touch event discovery & drag testing
--
-- Purpose:
--   1. Log ALL touch event (category, value, x, y) tuples to discover
--      which value codes ETHOS uses for press, slide/move, and release.
--   2. Provide a visual demo grid that can be dragged around with the finger
--      to test panning mechanics before integrating into the main widget.
--
-- Usage:
--   Copy the TouchTest folder to /scripts/ on the SD card.
--   Add the "Touch Test" widget to any screen on the radio.
--   Touch, drag, and release — watch the on-screen log and grid.
--
-- Author: b14ckyy
-- License: GPLv3
--

-- Cached stdlib for embedded Lua performance
local floor = math.floor
local abs = math.abs
local fmt = string.format
local type = type
local tostring = tostring
local io_open = io.open
local os_clock = os.clock
local math_sin = math.sin
local math_cos = math.cos
local math_sqrt = math.sqrt

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------

local GRID_SIZE   = 100   -- grid cell size in pixels
local LOG_MAX     = 12    -- max visible log lines on screen
local GRACE_CS    = 500   -- grace period in centiseconds (5s)

-- Pan states
local PAN_IDLE     = 0
local PAN_DRAGGING = 1
local PAN_GRACE    = 2
local PAN_PENDING  = 3    -- TOUCH_FIRST received, waiting to see if tap or drag

-- ETHOS touch event values (discovered via this widget!)
local TOUCH_FIRST  = 16640  -- finger down (first event of a sequence)
local TOUCH_END    = 16641  -- finger up (exists on HW, unreliable for long drags)
local TOUCH_SLIDE  = 16642  -- finger move/hold (continuous ~10/s HW, ~33/s sim)
-- TOUCH_END is sent reliably for TAPS but often MISSING after long drags.
-- Release is detected by TOUCH_END when available, with timeout as fallback.
local TOUCH_TIMEOUT_CS = 20 -- ~200ms in centiseconds (HW events ~100ms apart)

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------

local widgetW = 480
local widgetH = 272
local gridW   = 288   -- touch-active zone width (updated in paint)

-- Touch event log (ring buffer)
local logLines = {}
local logHead  = 0
local logCount = 0

-- Known touch values (discovered during testing)
local touchValueNames = {}  -- [value] = "name" — filled automatically

-- Touch event counters per value
local touchValueCounts = {} -- [value] = count

-- Grid origin (virtual offset in pixels, corresponds to panCenterLat/Lon in main widget)
local gridOffsetX = 0
local gridOffsetY = 0

-- Pan state machine
local panState   = PAN_IDLE
local panLastX   = 0
local panLastY   = 0
local graceEnd   = 0

-- Touch timing for timeout-based release detection
local lastTouchTime = 0  -- centiseconds, updated on every touch event

-- Stats
local totalEvents = 0
local dragPixels  = 0

-- CPU Load Simulation
-- Tune LOAD_ITERATIONS to achieve ~2 FPS on hardware.
-- Start with 0 (no load) and increase until FPS drops to target.
local LOAD_ITERATIONS = 2800  -- adjust this! 0=off, 5000→1.2FPS, 2800→~2.2FPS
local loadTimeMs    = 0       -- ms spent in load function (last frame)
local paintTimeMs   = 0       -- ms spent in entire paint() (last frame)

-- FPS Counter
local fpsFrameCount = 0
local fpsLastTime   = 0       -- os.clock seconds
local fpsDisplay    = 0       -- current measured FPS
local fpsMinDisplay = 999     -- lowest FPS seen

-- File logging
local LOG_FILE = "/scripts/TouchTest/touchlog.txt"
local LOG_FLUSH_INTERVAL = 50  -- flush every N events
local fileLogBuffer = {}
local fileLogCount = 0
local fileLogTotal = 0
local sessionStartClock = os_clock()

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function getTime()
  if system and system.getTimeCounter then
    local ok, t = pcall(system.getTimeCounter)
    if ok and t then return t end
  end
  return os.clock() * 100
end

local function addLog(msg)
  logHead = logHead + 1
  if logHead > LOG_MAX then logHead = 1 end
  logLines[logHead] = msg
  if logCount < LOG_MAX then logCount = logCount + 1 end
end

local function flushFileLog()
  if fileLogCount == 0 then return end
  local f = io_open(LOG_FILE, "a")
  if f then
    for i = 1, fileLogCount do
      f:write(fileLogBuffer[i])
      f:write("\n")
    end
    f:close()
  end
  fileLogCount = 0
end

local function fileLog(line)
  fileLogCount = fileLogCount + 1
  fileLogBuffer[fileLogCount] = line
  fileLogTotal = fileLogTotal + 1
  if fileLogCount >= LOG_FLUSH_INTERVAL then
    flushFileLog()
  end
end

local function writeFileLogHeader()
  local f = io_open(LOG_FILE, "a")
  if f then
    f:write("\n")
    f:write(fmt("=== TouchTest session started at clock=%.3f ===\n", sessionStartClock))
    f:write("# seq | clock_s | category | value | x | y | panState | gridOffX | gridOffY\n")
    f:close()
  end
end

local function classifyTouchValue(value, x, y)
  touchValueCounts[value] = (touchValueCounts[value] or 0) + 1
end

------------------------------------------------------------------------
-- CPU Load Simulation
------------------------------------------------------------------------

local function simulateCPULoad()
  if LOAD_ITERATIONS <= 0 then
    loadTimeMs = 0
    return
  end
  local t0 = os_clock()
  -- Burn CPU with trigonometric math — each iteration is ~5 Lua
  -- instructions (sin, cos, sqrt, multiply, add) but heavy on FPU.
  -- This mimics the real widget's tile drawing + overlay formatting.
  local x = 1.0
  for i = 1, LOAD_ITERATIONS do
    x = math_sin(x) * math_cos(x) + math_sqrt(x * x + 1.0)
  end
  loadTimeMs = (os_clock() - t0) * 1000
  -- Use x to prevent dead-code elimination by the Lua compiler
  if x == -999 then loadTimeMs = -1 end
end

------------------------------------------------------------------------
-- Grid Drawing
------------------------------------------------------------------------

local function drawGrid(x0, y0, w, h, offsetX, offsetY)
  -- Draw a simple tiled grid with coordinates, shifted by offset
  lcd.color(lcd.RGB(40, 40, 40))
  lcd.pen(SOLID)
  lcd.drawFilledRectangle(x0, y0, w, h)

  -- Grid lines
  lcd.color(lcd.RGB(80, 80, 80))
  lcd.pen(SOLID)

  -- Grid cell origin in pixel space
  local startX = (offsetX % GRID_SIZE) - GRID_SIZE
  local startY = (offsetY % GRID_SIZE) - GRID_SIZE

  -- Vertical lines
  local gx = startX
  while gx < w do
    if gx >= 0 then
      lcd.drawLine(x0 + gx, y0, x0 + gx, y0 + h)
    end
    gx = gx + GRID_SIZE
  end

  -- Horizontal lines
  local gy = startY
  while gy < h do
    if gy >= 0 then
      lcd.drawLine(x0, y0 + gy, x0 + w, y0 + gy)
    end
    gy = gy + GRID_SIZE
  end

  -- Tile labels (column/row indices)
  lcd.color(lcd.RGB(120, 120, 120))
  lcd.font(FONT_S)

  gx = startX
  while gx < w do
    gy = startY
    while gy < h do
      if gx >= 0 and gy >= 0 and gx < w and gy < h then
        -- Calculate tile index from offset
        local tileCol = floor((gx - offsetX % GRID_SIZE) / GRID_SIZE)
        local tileRow = floor((gy - offsetY % GRID_SIZE) / GRID_SIZE)
        -- Shift by grid origin
        local absCol = floor(-gridOffsetX / GRID_SIZE) + tileCol + 1
        local absRow = floor(-gridOffsetY / GRID_SIZE) + tileRow + 1
        lcd.drawText(x0 + gx + 4, y0 + gy + 2, fmt("%d,%d", absCol, absRow))
      end
      gy = gy + GRID_SIZE
    end
    gx = gx + GRID_SIZE
  end

  -- Center crosshair (where the "aircraft" would be)
  local cx = x0 + w / 2 + offsetX
  local cy = y0 + h / 2 + offsetY
  -- Only draw if visible
  if cx >= x0 and cx <= x0 + w and cy >= y0 and cy <= y0 + h then
    lcd.color(lcd.RGB(255, 80, 80))
    lcd.pen(SOLID)
    lcd.drawLine(cx - 10, cy, cx + 10, cy)
    lcd.drawLine(cx, cy - 10, cx, cy + 10)
    lcd.drawCircle(cx, cy, 6)
  else
    -- Draw edge indicator arrow pointing toward center
    lcd.color(lcd.RGB(255, 80, 80))
    lcd.font(FONT_S)
    local indX = math.max(x0 + 2, math.min(x0 + w - 20, cx))
    local indY = math.max(y0 + 2, math.min(y0 + h - 12, cy))
    lcd.drawText(indX, indY, "UAV")
  end
end

------------------------------------------------------------------------
-- Event Log Drawing
------------------------------------------------------------------------

local function drawEventLog(x0, y0, w, h)
  -- Semi-transparent log overlay
  lcd.color(lcd.RGB(0, 0, 0))
  lcd.pen(SOLID)
  lcd.drawFilledRectangle(x0, y0, w, h)

  lcd.font(FONT_S)
  lcd.color(lcd.RGB(0, 255, 0))

  -- Title
  lcd.drawText(x0 + 4, y0 + 2, fmt("Touch Events (%d total)", totalEvents))

  -- Log lines (newest first)
  local lineH = 14
  local maxLines = floor((h - 20) / lineH)
  local idx = logHead
  for i = 1, math.min(logCount, maxLines) do
    if logLines[idx] then
      lcd.color(lcd.RGB(180, 255, 180))
      lcd.drawText(x0 + 4, y0 + 18 + (i - 1) * lineH, logLines[idx])
    end
    idx = idx - 1
    if idx < 1 then idx = LOG_MAX end
  end
end

------------------------------------------------------------------------
-- Status Panel Drawing
------------------------------------------------------------------------

local function drawStatus(x0, y0, w, h)
  lcd.color(lcd.RGB(20, 20, 40))
  lcd.pen(SOLID)
  lcd.drawFilledRectangle(x0, y0, w, h)

  lcd.font(FONT_S)
  local lineH = 15
  local ty = y0 + 4

  -- Pan state
  local stateNames = { [PAN_IDLE] = "IDLE", [PAN_DRAGGING] = "DRAGGING", [PAN_GRACE] = "GRACE", [PAN_PENDING] = "PENDING" }
  lcd.color(WHITE)
  lcd.drawText(x0 + 4, ty, fmt("State: %s", stateNames[panState] or "?"))
  ty = ty + lineH

  -- Grid offset
  lcd.color(lcd.RGB(200, 200, 255))
  lcd.drawText(x0 + 4, ty, fmt("Offset: %d, %d px", gridOffsetX, gridOffsetY))
  ty = ty + lineH

  -- Total drag distance
  lcd.drawText(x0 + 4, ty, fmt("Drag: %d px total", floor(dragPixels)))
  ty = ty + lineH

  -- File log count
  lcd.drawText(x0 + 4, ty, fmt("Log: %d lines", fileLogTotal))
  ty = ty + lineH

  -- FPS / Performance
  lcd.color(lcd.RGB(255, 100, 100))
  lcd.drawText(x0 + 4, ty, fmt("FPS: %.1f", fpsDisplay))
  ty = ty + lineH

  -- Discovered touch values
  lcd.color(lcd.RGB(255, 255, 100))
  lcd.drawText(x0 + 4, ty, "Touch values seen:")
  ty = ty + lineH

  for val, count in pairs(touchValueCounts) do
    local label = touchValueNames[val] or "?"
    lcd.color(lcd.RGB(255, 200, 100))
    lcd.drawText(x0 + 4, ty, fmt("  %d (%s) x%d", val, label, count))
    ty = ty + lineH
    if ty > y0 + h - lineH then break end
  end
end

------------------------------------------------------------------------
-- ETHOS Callbacks
------------------------------------------------------------------------

local function create()
  writeFileLogHeader()
  return {
    name = "Touch Test",
  }
end

local function paint(widget)
  local paintT0 = os_clock()

  local w, h = lcd.getWindowSize()
  if w and h and w > 0 and h > 0 then
    widgetW = w
    widgetH = h
  end

  -- FPS measurement (1-second window)
  fpsFrameCount = fpsFrameCount + 1
  local nowClock = os_clock()
  local elapsed = nowClock - fpsLastTime
  if elapsed >= 1.0 then
    fpsDisplay = fpsFrameCount / elapsed
    if fpsDisplay < fpsMinDisplay and fpsFrameCount > 2 then
      fpsMinDisplay = fpsDisplay
    end
    fpsFrameCount = 0
    fpsLastTime = nowClock
  end

  -- Simulate CPU load (burns time like tile drawing does in real widget)
  simulateCPULoad()

  -- Layout: left = grid (60%), right = log + status (40%)
  gridW = floor(widgetW * 0.6)
  local logW  = widgetW - gridW
  local logH  = floor(widgetH * 0.55)
  local statusH = widgetH - logH

  -- Background
  lcd.color(BLACK)
  lcd.pen(SOLID)
  lcd.drawFilledRectangle(0, 0, widgetW, widgetH)

  -- Demo grid (draggable area)
  drawGrid(0, 0, gridW, widgetH, gridOffsetX, gridOffsetY)

  -- State indicator on grid
  lcd.font(FONT_L)
  if panState == PAN_DRAGGING then
    lcd.color(lcd.RGB(255, 50, 50))
    lcd.drawText(gridW / 2, 8, "DRAGGING", CENTERED)
  elseif panState == PAN_GRACE then
    lcd.color(lcd.RGB(255, 200, 50))
    lcd.drawText(gridW / 2, 8, "GRACE (5s)", CENTERED)
  elseif panState == PAN_PENDING then
    lcd.color(lcd.RGB(100, 150, 255))
    lcd.drawText(gridW / 2, 8, "PENDING (tap or drag?)", CENTERED)
  else
    lcd.color(lcd.RGB(100, 200, 100))
    lcd.drawText(gridW / 2, 8, "IDLE - touch grid to drag", CENTERED)
  end

  -- Pan mode indicator (bottom of grid)
  lcd.font(FONT_S)
  lcd.color(lcd.RGB(150, 150, 150))
  lcd.drawText(gridW / 2, widgetH - 16, fmt("Grid %dpx | Touch anywhere to drag", GRID_SIZE), CENTERED)

  -- Event log panel
  drawEventLog(gridW, 0, logW, logH)

  -- Status panel
  drawStatus(gridW, logH, logW, statusH)

  -- Border between panels
  lcd.color(lcd.RGB(60, 60, 60))
  lcd.drawLine(gridW, 0, gridW, widgetH)
  lcd.drawLine(gridW, logH, widgetW, logH)

  -- FPS / Load overlay (bottom-left of grid)
  lcd.font(FONT_S)
  lcd.color(lcd.RGB(255, 255, 0))
  paintTimeMs = (os_clock() - paintT0) * 1000
  lcd.drawText(4, widgetH - 46, fmt("FPS: %.1f (min %.1f)", fpsDisplay, fpsMinDisplay))
  lcd.drawText(4, widgetH - 32, fmt("Paint: %.0fms Load: %.0fms", paintTimeMs, loadTimeMs))
  lcd.drawText(4, widgetH - 18, fmt("Iterations: %d", LOAD_ITERATIONS))
end

local function wakeup(widget)
  local now = getTime()

  -- Timeout-based release detection: no touch events for TOUCH_TIMEOUT_CS → GRACE
  if panState == PAN_DRAGGING then
    if lastTouchTime > 0 and (now - lastTouchTime) > TOUCH_TIMEOUT_CS then
      panState = PAN_GRACE
      graceEnd = now + GRACE_CS
      addLog(">> TIMEOUT -> GRACE (finger up)")
      fileLog(fmt("%d|%.3f|0|0|0|0|%d|%d|%d|FINGER_UP_TIMEOUT",
        totalEvents, os_clock() - sessionStartClock, panState, gridOffsetX, gridOffsetY))
    end
  end

  -- PAN_PENDING: NO timeout. Finger stays in PENDING until:
  --   - TOUCH_SLIDE arrives → DRAGGING (drag started)
  --   - TOUCH_END arrives   → IDLE (tap detected, menu opens)
  -- ETHOS has no long-press action, so holding = potential drag.

  -- Grace period expiry check
  if panState == PAN_GRACE then
    if now >= graceEnd then
      panState = PAN_IDLE
      addLog(">> Grace expired -> IDLE")
      fileLog(fmt("%d|%.3f|0|0|0|0|%d|%d|%d|GRACE_EXPIRED",
        totalEvents, os_clock() - sessionStartClock, panState, gridOffsetX, gridOffsetY))
    end
  end

  -- Periodic flush of file log buffer
  if fileLogCount > 0 then
    flushFileLog()
  end

  lcd.invalidate()
end

local function event(widget, category, value, x, y)
  -- ═══════════════════════════════════════════════════════════
  -- THIS IS THE KEY FUNCTION: log everything ETHOS sends us
  -- ═══════════════════════════════════════════════════════════

  if category == EVT_TOUCH and x ~= nil and y ~= nil then
    totalEvents = totalEvents + 1

    -- Log to file (unlimited, CSV-style for easy parsing)
    fileLog(fmt("%d|%.3f|%d|%d|%d|%d|%d|%d|%d",
      totalEvents, os_clock() - sessionStartClock,
      category, value, x, y, panState, gridOffsetX, gridOffsetY))

    -- Log to screen (ring buffer)
    addLog(fmt("v=%d x=%d y=%d", value, x, y))

    -- Count per-value
    classifyTouchValue(value, x, y)

    -- ─── Touch zone check ───
    -- Only the grid area (left side) is the drag zone.
    -- Touches on the right panel pass through to ETHOS so the
    -- widget menu / system gestures remain accessible.
    if x >= gridW and panState ~= PAN_DRAGGING then
      return false  -- let ETHOS handle it
    end

    -- Record timestamp for timeout-based release detection
    lastTouchTime = getTime()

    -- Auto-label discovered values
    if not touchValueNames[value] then
      if value == TOUCH_FIRST then
        touchValueNames[value] = "FIRST"
      elseif value == TOUCH_END then
        touchValueNames[value] = "END"
      elseif value == TOUCH_SLIDE then
        touchValueNames[value] = "SLIDE"
      else
        touchValueNames[value] = fmt("UNKNOWN(%d)", value)
      end
    end

    -- ═══════════════════════════════════════════════════════════
    -- TAP-VS-DRAG STATE MACHINE
    --
    -- Key insight: TOUCH_FIRST is NOT consumed in IDLE/GRACE.
    -- ETHOS receives it. Only TOUCH_SLIDE triggers drag mode.
    -- If TOUCH_END arrives without any SLIDE, ETHOS saw a
    -- complete FIRST+END sequence = tap = widget menu opens.
    -- ═══════════════════════════════════════════════════════════

    if value == TOUCH_FIRST then
      if panState == PAN_IDLE or panState == PAN_GRACE then
        -- Finger down in drag zone — enter PENDING
        -- DO NOT CONSUME: ETHOS needs FIRST for tap detection
        panState = PAN_PENDING
        panLastX = x
        panLastY = y
        addLog(fmt(">> FIRST -> PENDING (not consumed)"))
        fileLog(fmt("%d|%.3f|0|0|0|0|%d|%d|%d|PENDING_START",
          totalEvents, os_clock() - sessionStartClock, panState, gridOffsetX, gridOffsetY))
        return false  -- LET ETHOS HAVE IT

      elseif panState == PAN_DRAGGING then
        -- New TOUCH_FIRST while dragging = new finger sequence
        panLastX = x
        panLastY = y
        system.killEvents(value)
        return true
      end
      -- PAN_PENDING + TOUCH_FIRST: shouldn't happen, ignore
      return false

    elseif value == TOUCH_END then
      if panState == PAN_PENDING then
        -- TOUCH_END without any SLIDE = this was a TAP
        -- DO NOT CONSUME: let ETHOS handle it (widget menu)
        panState = PAN_IDLE
        addLog(">> END while PENDING -> IDLE (TAP!)")
        fileLog(fmt("%d|%.3f|0|0|0|0|%d|%d|%d|TAP_DETECTED",
          totalEvents, os_clock() - sessionStartClock, panState, gridOffsetX, gridOffsetY))
        return false  -- LET ETHOS HAVE IT (tap = widget menu)

      elseif panState == PAN_DRAGGING then
        -- Finger lifted during drag → GRACE
        panState = PAN_GRACE
        graceEnd = getTime() + GRACE_CS
        addLog(">> END(16641) -> GRACE")
        fileLog(fmt("%d|%.3f|0|0|0|0|%d|%d|%d|TOUCH_END_GRACE",
          totalEvents, os_clock() - sessionStartClock, panState, gridOffsetX, gridOffsetY))
        system.killEvents(value)
        return true
      end
      -- IDLE/GRACE + TOUCH_END: not our concern
      return false

    elseif value == TOUCH_SLIDE then
      if panState == PAN_PENDING then
        -- First SLIDE after FIRST → this IS a drag, not a tap
        -- CONSUME from here on to prevent swipe
        panState = PAN_DRAGGING
        -- Apply delta from the recorded FIRST position
        local dx = x - panLastX
        local dy = y - panLastY
        if dx ~= 0 or dy ~= 0 then
          gridOffsetX = gridOffsetX + dx
          gridOffsetY = gridOffsetY + dy
          dragPixels = dragPixels + abs(dx) + abs(dy)
        end
        panLastX = x
        panLastY = y
        addLog(fmt(">> SLIDE -> DRAGGING (consumed!)"))
        fileLog(fmt("%d|%.3f|0|0|0|0|%d|%d|%d|DRAG_START",
          totalEvents, os_clock() - sessionStartClock, panState, gridOffsetX, gridOffsetY))
        system.killEvents(value)
        return true

      elseif panState == PAN_DRAGGING then
        -- Continue drag — apply pixel delta
        local dx = x - panLastX
        local dy = y - panLastY
        if dx ~= 0 or dy ~= 0 then
          gridOffsetX = gridOffsetX + dx
          gridOffsetY = gridOffsetY + dy
          dragPixels = dragPixels + abs(dx) + abs(dy)
        end
        panLastX = x
        panLastY = y
        system.killEvents(value)
        return true

      elseif panState == PAN_GRACE then
        -- SLIDE during grace → resume drag
        panState = PAN_DRAGGING
        panLastX = x
        panLastY = y
        addLog(">> SLIDE in GRACE -> DRAGGING (resume)")
        system.killEvents(value)
        return true
      end
      -- IDLE + TOUCH_SLIDE: not our concern
      return false
    end

    -- Unknown touch values: don't consume
    return false

  end

  return false
end

------------------------------------------------------------------------
-- Registration
------------------------------------------------------------------------

local function init()
  system.registerWidget({
    key = "tchtest",
    name = "Touch Test",
    paint = paint,
    event = event,
    wakeup = wakeup,
    create = create,
  })
end

return { init = init }
