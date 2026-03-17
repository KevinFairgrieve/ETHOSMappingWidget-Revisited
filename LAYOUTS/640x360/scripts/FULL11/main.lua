-- Fullscreen 1:1 split layout (640x360 resolution)
-- No outer margin (starts at 0,0), only 4px gap BETWEEN widgets
local function init()
    system.registerLayout({
        key = "FULL 1:1 360",
        widgets = {
            {x=0,   y=0, w=318, h=360},  -- Left widget
            {x=322, y=0, w=318, h=360}   -- Right widget (4px gap)
        }
    })
end

return { init = init }