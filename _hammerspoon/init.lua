-- INIT

apps = require("applications")
require("caffiene")
require("colorpicker")
require("mic")
require("ping")
require("timestamp")
require("window")

constants = require("constants")

-- SPOONS

hs.loadSpoon("Emojis")
spoon.Emojis:bindHotkeys({toggle = {constants.hyper, "E"}})

-- OTHER

-- Force paste into applications that disallow
hs.hotkey.bind(
    constants.hyper,
    "V",
    function()
        hs.eventtap.keyStrokes(hs.pasteboard.getContents())
    end
)

-- Reload hammerspoon with HYPER+R
hs.hotkey.bind(constants.hyper, "R", hs.reload)

-- Hammerspoon Console
hs.hotkey.bind(constants.hyper, "`", hs.toggleConsole)
hs.preferencesDarkMode(true)
hs.console.darkMode(true)
hs.console.outputBackgroundColor {white = 0}
hs.console.consoleCommandColor {white = 1}
hs.console.alpha(1)

hs.alert.show("Hammerspoon Reloaded")
