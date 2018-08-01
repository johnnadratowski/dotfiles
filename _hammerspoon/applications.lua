constants = require("constants")
log = require("log")

-- More flexible app searches
hs.application.enableSpotlightForNameSearches(true)

-- Application quick switching
local ctrlTab =
    hs.hotkey.new(
    {"ctrl"},
    "tab",
    nil,
    function()
        hs.eventtap.keyStroke({"alt"}, "w")
    end
)

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

function gmail()
    ensureOpen(constants.defaultBrowser, 3, 100000)
    hs.eventtap.keyStroke({"cmd"}, "1")
end

function gcal()
    ensureOpen(constants.defaultBrowser, 3, 100000)
    hs.eventtap.keyStroke({"cmd"}, "2")
end

local curEditor = -1
function editor()
    local front = hs.application.frontmostApplication()
    if curEditor == -1 or front:path() == constants.editors[curEditor] then
        local matchIndex = -1
        for idx, path in pairs(constants.editors) do
            if path == front:path() then
                matchIndex = idx
            end
        end

        if matchIndex > -1 and curEditor ~= matchIndex then
            if curEditor == -1 then
                curEditor = matchIndex + 1
            else
                curEditor = matchIndex
            end
        elseif curEditor == -1 or curEditor + 1 > #constants.editors then
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
local exports = {}
exports.ensureOpen = ensureOpen
exports.google = google
exports.print_running = function()
    for id, app in pairs(hs.application.runningApplications()) do
        log.d(id, app:path() or app:name())
    end
end

hs.hotkey.bind(
    constants.hyper,
    "Space",
    function()
        hs.application.launchOrFocus("Terminal")
    end
)

hs.hotkey.bind(
    constants.hyper,
    "1",
    function()
        hs.application.launchOrFocus("/Applications/Visual Studio Code.app")
    end
)

hs.hotkey.bind(
    constants.hyper,
    "2",
    function()
        hs.application.launchOrFocus(constants.defaultBrowser)
    end
)

hs.hotkey.bind(
    constants.hyper,
    "3",
    function()
        hs.application.launchOrFocus("Slack")
    end
)

hs.hotkey.bind(constants.hyper, "4", gmail)

hs.hotkey.bind(constants.hyper, "5", gcal)

hs.hotkey.bind(
    constants.hyper,
    "D",
    function()
        hs.application.launchOrFocus("DevDocs")
    end
)

-- hs.hotkey.bind(constants.hyper, 'Space', editor)
hs.hotkey.bind(constants.hyper, "G", google)

return exports
