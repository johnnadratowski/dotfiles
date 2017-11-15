
constants = require('constants')

-- Application quick switching
hs.hotkey.bind(constants.hyper, '1', function() hs.application.launchOrFocus('Terminal') end)
hs.hotkey.bind(constants.hyper, '2', function() hs.application.launchOrFocus('Google Chrome') end)
hs.hotkey.bind(constants.hyper, '3', function() hs.application.launchOrFocus('Slack') end)
hs.hotkey.bind(constants.hyper, '4', function() hs.application.launchOrFocus('Gmail') end)
hs.hotkey.bind(constants.hyper, '5', function() hs.application.launchOrFocus('Gcal') end)

hs.hotkey.bind(constants.hyper, 'D', function() hs.application.launchOrFocus('DevDocs') end)

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

function google()
    ensureOpen('Google Chrome', 3, 100000):selectMenuItem("New Tab")
end
hs.hotkey.bind(constants.hyper, 'G', google)

-- function devdocs()
--     ensureOpen('Google Chrome', 3, 100000):selectMenuItem("New Tab")
--     hs.eventtap.keyStrokes('devdocs.io\n')
-- end
-- hs.hotkey.bind(constants.hyper, 'D', devdocs)


-- SWITCHER - probably won't use

-- hs.hotkey.bind(constants.hyper, 'l', hs.window.switcher.nextWindow, nil, hs.window.switcher.nextWindow)
-- hs.hotkey.bind(constants.hyper, 'h', hs.window.switcher.previousWindow, nil, hs.window.switcher.previousWindow)
-- switcher = hs.window.switcher.new(hs.window.filter.new())
-- hs.hotkey.bind(constants.hyper, 'l', function()switcher:next()end)
-- hs.hotkey.bind(constants.hyper, 'h', function()switcher:previous()end)