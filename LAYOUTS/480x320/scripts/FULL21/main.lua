-- Fullscreen 2:1 split layout (480x320 resolution)
-- No outer margin (starts at 0,0), only 4px gap BETWEEN widgets
-- Left big (2/3), right small (1/3)
local function init()
    system.registerLayout({
        key = "FULL 2:1",
        widgets = {
            {x=0,   y=0, w=316, h=320},  -- Left big widget
            {x=320, y=0, w=160, h=320}   -- Right small widget (4px gap)
        }
    })
end

return { init = init }