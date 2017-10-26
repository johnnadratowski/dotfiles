require('applications')
require('caffiene')
require('mic')
require('ping')
require('window')

constants = require('constants')

-- Spoons

hs.loadSpoon('ColorPicker')
spoon.ColorPicker.show_in_menubar = true
spoon.ColorPicker:bindHotkeys({show={constants.hyper, 'C'}})
-- spoon.ColorPicker:start()

hs.loadSpoon('Emojis')
spoon.Emojis:bindHotkeys({toggle={constants.hyper, 'E'}})
-- spoon.Emojis:start()

-- hs.loadSpoon('KSheet')
-- hs.hotkey.bind(constants.hyper, 'F', function() 
--     spoon.KSheet:show()
-- end)


-- Force paste into applications that disallow
hs.hotkey.bind(constants.hyper, 'V', function() 
    hs.eventtap.keyStrokes(hs.pasteboard.getContents()) 
end)

-- Reload hammerspoon with HYPER+R
hs.hotkey.bind(constants.hyper, 'R', function() 
    hs.reload() 
end)

