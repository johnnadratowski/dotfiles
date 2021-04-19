constants = require("constants")
log = require("log")

-- More flexible app searches
hs.application.enableSpotlightForNameSearches(true)

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

-- hs.hints.showTitleThresh = 4
-- hs.hints.style = "vimperator"
-- hs.hotkey.bind(constants.hyper, "0", "Window Hints", hs.hints.windowHints)

hs.hotkey.bind(
    constants.hyper,
    "space",
    "Terminal",
    function()
        hs.application.launchOrFocus("iTerm")
    end
)

hs.hotkey.bind(
    constants.hyper,
    "return",
    "VSCode",
    function()
        hs.application.launchOrFocus("/Applications/Visual Studio Code.app")
    end
)

hs.hotkey.bind(
    constants.hyper,
    "tab",
    "Browser",
    function()
        hs.application.launchOrFocus(constants.defaultBrowser)
    end
)

-- hs.hotkey.bind(
--     constants.hyper,
--     "1",
--     "VSCode",
--     function()
--         hs.application.launchOrFocus("/Applications/Visual Studio Code.app")
--     end
-- )

-- hs.hotkey.bind(
--     constants.hyper,
--     "1",
--     "Browser",
--     function()
--         hs.application.launchOrFocus(constants.defaultBrowser)
--     end
-- )

-- hs.hotkey.bind(
--     constants.hyper,
--     "2",
--     "Slack",
--     function()
--         hs.application.launchOrFocus("Slack")
--     end
-- )

-- hs.hotkey.bind(
--     constants.hyper,
--     "D",
--     "DevDocs",
--     function()
--         hs.application.launchOrFocus("DevDocs")
--     end
-- )

hs.hotkey.bind(constants.hyper, "G", "Google", google)

return exports
