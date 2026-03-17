-- Fullscreen 1:1 split layout (800x480 resolution)
-- No outer margin (starts at 0,0), only 4px gap BETWEEN widgets
local function init()
    system.registerLayout({
        key = "FULL 1:1",
        widgets = {
            {x=0,   y=0, w=398, h=480},  -- Left widget
            {x=402, y=0, w=398, h=480}   -- Right widget (4px gap)
        }
    })
end

return { init = init }