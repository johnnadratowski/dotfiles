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
hs.hotkey.bind(constants.hyper, '`', hs.toggleConsole)

-- Show colorpicker
hs.hotkey.bind(constants.hyper, 'C', function() hs.osascript.applescript('choose color') end)

hs.alert.show("Hammerspoon Reloaded")