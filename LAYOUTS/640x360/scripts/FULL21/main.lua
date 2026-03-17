-- Fullscreen 2:1 split layout (640x360 resolution)
-- No outer margin (starts at 0,0), only 4px gap BETWEEN widgets
-- Left big (2/3), right small (1/3)
local function init()
    system.registerLayout({
        key = "FULL 2:1 360",
        widgets = {
            {x=0,   y=0, w=426, h=360},  -- Left big widget
            {x=430, y=0, w=210, h=360}   -- Right small widget (4px gap)
        }
    })
end

return { init = init }