-- Fullscreen 1+2 split layout (800x480 resolution)
-- No outer margin (starts at 0,0), only 4px gap BETWEEN widgets
local function init()
    system.registerLayout({
        key = "FULL 1+2",
        widgets = {
            {x=0,   y=0,   w=529, h=480},  -- Left big widget (2/3 width)
            {x=533, y=0,   w=267, h=238},  -- Right top small
            {x=533, y=242, w=267, h=238}   -- Right bottom small (4px vertical gap)
        }
    })
end

return { init = init }