-- INIT

require('applications')
require('caffiene')
require('mic')
require('ping')
require('window')

constants = require('constants')



-- SPOONS

hs.loadSpoon('Emojis')
spoon.Emojis:bindHotkeys({toggle={constants.hyper, 'E'}})



-- OTHER

-- Force paste into applications that disallow
hs.hotkey.bind(constants.hyper, 'V', function() 
    hs.eventtap.keyStrokes(hs.pasteboard.getContents()) 
end)

-- Reload hammerspoon with HYPER+R
hs.hotkey.bind(constants.hyper, 'R', hs.reload)

-- How Hammerspoon Console
hs.hotkey.bind(constants.hyper, 'C', hs.openConsole)

function google()
    hs.application.launchOrFocus('Google Chrome')

    local found
    while found == nil do
        hs.timer.usleep(100000)
        found = hs.application.frontmostApplication():selectMenuItem("New Tab")
        if hs.application.frontmostApplication():name() == 'Google Chrome' then
            break -- Just double check this to prevent infinite loop
        end
    end
end
hs.hotkey.bind(constants.hyper, 'G', google)

function devdocs()
    hs.application.launchOrFocus('Google Chrome')

    local found
    while found == nil do
        hs.timer.usleep(100000)
        found = hs.application.frontmostApplication():selectMenuItem("New Tab")
        if hs.application.frontmostApplication():name() == 'Google Chrome' then
            break -- Just double check this to prevent infinite loop
        end
    end
    hs.eventtap.keyStrokes('devdocs.io\n')
end
hs.hotkey.bind(constants.hyper, 'D', devdocs)

hs.alert.show("Hammerspoon Reloaded")