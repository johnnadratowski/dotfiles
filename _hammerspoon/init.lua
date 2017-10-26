constants = require('constants')
require('caffiene')
require('mic')
require('ping')
require('window')

-- Force paste into applications that disallow
hs.hotkey.bind(constants.hyper, "V", function() 
    hs.eventtap.keyStrokes(hs.pasteboard.getContents()) 
end)

-- Reload hammerspoon with HYPER+R
hs.hotkey.bind(constants.hyper, "R", function() 
    hs.reload() 
end)

