-- INIT

require("hs.crash")

require("applications")
require("caffiene")
require("colorpicker")
local dbug = require("dbug")
require("mic")
require("mouse")
require("ping")
require("timestamp")
require("window")

constants = require("constants")

---- SEED THE RNG

math.randomseed(os.time())

-- DEBUGGING

hs.crash.crashLogToNSLog = false
configFileWatcher = hs.pathwatcher.new(os.getenv("HOME") .. "/.hammerspoon/", dbug.reloadConfig)
--debug.sethook(debug.lineTraceHook, "l")
--configFileWatcher:start()

-- SPOONS

---- EMOJI SPOONS
hs.loadSpoon("Emojis")
spoon.Emojis:bindHotkeys({toggle = {constants.hyper, "E"}})

---- SEAL SPOONS
hs.loadSpoon("Seal")
spoon.Seal:loadPlugins({"apps", "vpn", "screencapture", "safari_bookmarks", "calc", "useractions"})
spoon.Seal:bindHotkeys({show = {constants.hyper, ";"}})
spoon.Seal:start()
spoon.Seal.plugins.useractions.actions = {
    ["Red Hat Bugzilla"] = {
        url = "https://bugzilla.redhat.com/show_bug.cgi?id=${query}",
        icon = "favicon",
        keyword = "bz"
    },
    ["Launchpad Bugs"] = {url = "https://launchpad.net/bugs/${query}", icon = "favicon", keyword = "lp"}
}

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
hs.hotkey.showHotkeys(constants.hyper, "K")
hs.alert.show("Hammerspoon Reloaded")
