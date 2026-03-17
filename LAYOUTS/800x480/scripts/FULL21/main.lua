-- Fullscreen 2:1 split layout (800x480 resolution)
-- No outer margin (starts at 0,0), only 4px gap BETWEEN widgets
local function init()
    system.registerLayout({
        key = "FULL 2:1",
        widgets = {
            {x=0,   y=0, w=529, h=480},  -- Left big widget (2/3)
            {x=533, y=0, w=267, h=480}   -- Right small widget (1/3)
        }
    })
end

return { init = init }