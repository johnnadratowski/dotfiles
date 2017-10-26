
constants = require('constants')

hs.hotkey.bind(constants.hyper, 'G', function() 
    hs.application.launchOrFocus('Google Chrome') 
end)

hs.hotkey.bind(constants.hyper, 'T', function() 
    hs.application.launchOrFocus('Terminal') 
end)

