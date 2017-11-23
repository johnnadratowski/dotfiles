
constants = require('constants')
log = require('log')

-- More flexible app searches
hs.application.enableSpotlightForNameSearches(true)

-- Application quick switching
hs.hotkey.bind(constants.hyper, '1', function() hs.application.launchOrFocus('Terminal') end)
hs.hotkey.bind(constants.hyper, '2', function() hs.application.launchOrFocus(constants.defaultBrowser) end)
hs.hotkey.bind(constants.hyper, '3', function() hs.application.launchOrFocus('Slack') end)
hs.hotkey.bind(constants.hyper, '4', function() hs.application.launchOrFocus('Gmail') end)
hs.hotkey.bind(constants.hyper, '5', function() hs.application.launchOrFocus('Gcal') end)

hs.hotkey.bind(constants.hyper, 'D', function() hs.application.launchOrFocus('DevDocs') end)

function ensureOpen(appName, timeout, delay)
    local app = hs.application.open(appName, timeout, timeout > 0)
    if app == nil then
        hs.alert.show("Could not open " .. appName)
        return
    end

    local done = os.time() + timeout
    while os.time() < done do
        hs.timer.usleep(delay)
        if hs.application.frontmostApplication():name() == app:name() then
            break
        end
    end

    return app
end

function google()
    ensureOpen(constants.defaultBrowser, 3, 100000):selectMenuItem("New Tab")
end
hs.hotkey.bind(constants.hyper, 'G', google)

local curEditor = -1
function editor()
    local front = hs.application.frontmostApplication()
    if curEditor == -1 or front:path() == constants.editors[curEditor] then
        if curEditor == -1 or curEditor + 1 > #constants.editors then
            curEditor = 1
        else
            curEditor = curEditor + 1
        end
    end

    local next = constants.editors[curEditor]

    if not hs.application.launchOrFocus(next) then
        log.e("Could not launch app", next)
    end
end
hs.hotkey.bind(constants.hyper, 'X', editor)

local exports = {}
exports.ensureOpen = ensureOpen
exports.google = google
exports.print_running = function()
    for id, app in pairs(hs.application.runningApplications()) do
        log.d(id, app:path() or app:name())
    end
end
return exports