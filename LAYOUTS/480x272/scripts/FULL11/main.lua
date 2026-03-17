-- Fullscreen 1:1 split layout (480x272 resolution)
-- No outer margin (starts at 0,0), only 4px gap BETWEEN widgets
local function init()
    system.registerLayout({
        key = "FULL 1:1 272",
        widgets = {
            {x=0,   y=0, w=238, h=272},  -- Left widget
            {x=242, y=0, w=238, h=272}   -- Right widget (4px gap)
        }
    })
end

return { init = init }