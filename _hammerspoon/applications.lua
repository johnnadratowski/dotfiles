
constants = require('constants')

function ensureOpen(app, timeout, delay, fn)
    local app = hs.application.open(app, timeout, true)
    if app == nil then
        hs.alert.show("Could not open " .. app)
        return
    end

    local done = os.time() + timeout
    while os.time() < done do
        hs.timer.usleep(delay)
        if hs.application.frontmostApplication():name() == app:name() then
            break
        end
    end

    if fn == nil then
        return app
    end

    return fn(app)
end

hs.hotkey.bind(constants.hyper, 'T', function() 
    hs.application.launchOrFocus('Terminal') 
end)

function google()
    ensureOpen('Google Chrome', 3, 100000):selectMenuItem("New Tab")
end
hs.hotkey.bind(constants.hyper, 'G', google)

function devdocs()
    ensureOpen('Google Chrome', 3, 100000):selectMenuItem("New Tab")
    hs.eventtap.keyStrokes('devdocs.io\n')
end
hs.hotkey.bind(constants.hyper, 'D', devdocs)
