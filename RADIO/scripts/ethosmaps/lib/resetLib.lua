local resetLib = {}
local status = nil
local libs = nil

local function flagEnabled(value)
  if value == true then
    return true
  end
  local valueType = type(value)
  if valueType == "number" then
    return value ~= 0
  end
  if valueType == "string" then
    local normalized = string.lower(value)
    return normalized == "true" or normalized == "1" or normalized == "on"
  end
  return false
end

-- Recursively clears a table tree so cached layouts, tiles, and other transient state can be released.
function resetLib.clearTable(t)
  if type(t)=="table" then
    for i,v in pairs(t) do
      if type(v) == "table" then
        resetLib.clearTable(v)
      end
      t[i] = nil
    end
  end
  t = nil
end

function resetLib.resetLayout(widget)
  -- Clears the loaded layout cache, resets per-screen layout state, and marks the widget for a fresh layout load.
  status.loadCycle = 0
  resetLib.clearTable(status.layout)
  status.layout = { nil }
  widget.ready = false

  if status and status.perfProfileInc and status.conf and flagEnabled(status.conf.enableDebugLog) and flagEnabled(status.conf.enablePerfProfile) then
    status.perfProfileInc("gc_count", 2)
  end
  -- GC wird jetzt periodisch im wakeup() ausgeführt
end

function resetLib.reset(widget)
  -- Performs a full widget reset by clearing layout state and forcing Lua garbage collection afterwards.
  resetLib.resetLayout(widget)
  if status and status.perfProfileInc and status.conf and flagEnabled(status.conf.enableDebugLog) and flagEnabled(status.conf.enablePerfProfile) then
    status.perfProfileInc("gc_count", 2)
  end
  -- GC wird jetzt periodisch im wakeup() ausgeführt
end

function resetLib.init(param_status, param_libs)
  -- Stores shared state references so reset helpers can mutate widget status and cooperate with sibling libraries.
  status = param_status
  libs = param_libs
  return resetLib
end

return resetLib
