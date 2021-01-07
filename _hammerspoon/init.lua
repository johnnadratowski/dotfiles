-- INIT

require("hs.crash")

require("applications")
require("caffiene")
require("colorpicker")
local dialog = require("dialog")
local dbug = require("dbug")
require("humanfilesize")
local logger = require("log")
require("mic")
--require("mouse")
require("ping")
local snippets = require("snippets")
require("timestamp")
require("window")

constants = require("constants")

---- SEED THE RNG

math.randomseed(os.time())

-- DEBUGGING

hs.crash.crashLogToNSLog = false
configFileWatcher = hs.pathwatcher.new(constants.home, dbug.reloadConfig)
--debug.sethook(debug.lineTraceHook, "l")
--configFileWatcher:start()

-- SPOONS

---- EMOJI SPOONS
hs.loadSpoon("Emojis")
spoon.Emojis:bindHotkeys({toggle = {constants.hyper, "E"}})

---- SEAL SPOONS
-- hs.loadSpoon("Seal")
-- spoon.Seal:loadPlugins({"apps", "vpn", "screencapture", "safari_bookmarks", "calc", "useractions"})
-- spoon.Seal:bindHotkeys({show = {constants.hyper, ";"}})
-- spoon.Seal:start()
-- spoon.Seal.plugins.useractions.actions = {
--     ["Red Hat Bugzilla"] = {
--         url = "https://bugzilla.redhat.com/show_bug.cgi?id=${query}",
--         icon = "favicon",
--         keyword = "bz"
--     },
--     ["Launchpad Bugs"] = {url = "https://launchpad.net/bugs/${query}", icon = "favicon", keyword = "lp"}
-- }

-- WINDOW

--hs.window.animationDuration = 0.1

-- OTHER

---- Force paste into applications that disallow
hs.hotkey.bind(
    constants.hyper,
    "V",
    "Force Paste",
    function()
        hs.eventtap.keyStrokes(hs.pasteboard.getContents())
    end
)

---- Reload hammerspoon with HYPER+R
hs.hotkey.bind(constants.hyper, "R", "Reload", hs.reload)

---- Hammerspoon Console
hs.hotkey.bind(constants.hyper, "`", "Console", hs.toggleConsole)
hs.preferencesDarkMode(true)
hs.console.darkMode(true)
hs.console.outputBackgroundColor {white = 0}
hs.console.consoleCommandColor {white = 1}
hs.console.alpha(1)

---- Show hotkeys
hs.hotkey.alertDuration = 0
hs.hotkey.showHotkeys(constants.hyper, "h")

---- Reload hammerspoon with HYPER+R
hs.alert.show("Hammerspoon Reloaded")

---- Lorem Ipsum Generator

hs.hotkey.bind(
    constants.hyper,
    "L",
    "Lorem Ipsum",
    function()
        input = dialog("Lorem Ipsum Number of sentences", "error", "5")
        if input == "" or tonumber(input) == nil then
            hs.alert.show(string.format("Invalid Input: %s", input))
            return
        end
        code, output, headers = hs.http.doRequest(string.format("http://metaphorpsum.com/sentences/%s", input), "GET")
        if code ~= 200 then
            hs.alert.show(string.format("Lorem Ipsum Error Response code: %d", code))
            logger.ef("Error response for lorem ipsum: %s", output)
        else
            hs.alert.show("Lorem Ipsum copied to clipboard")
            hs.pasteboard.setContents(output)
        end
    end
)

---- Snippets
hs.hotkey.bind(constants.hyper, "J", "Snippets", snippets.snippets)
