-- INIT

local files = require('files')
local constants = require("constants")
local alert = require('hs.alert')
local alerts = require('alerts')
local dialog = require("dialog")
local dbug = require("dbug")
local logger = require("log")
local snippets = require("snippets")

require("hs.crash")
require("applications")
require("caffiene")
require("colorpicker")
require("diff")
require("escape")
require("humanfilesize")
require("humanseconds")
require("mic")
--require("mouse")
require("fmtnum")
require("ocr")
require("ping")
require("timestamp")
require("uuid")
require("window")


---- SEED THE RNG

math.randomseed(os.time())

-- DEBUGGING

hs.crash.crashLogToNSLog = false
configFileWatcher = hs.pathwatcher.new(constants.hammerspoonHome, dbug.reloadConfig)
--debug.sethook(debug.lineTraceHook, "l")
--configFileWatcher:start()

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

---- DO not show alert when hotkey pressed
hs.hotkey.alertDuration = 0
hs.alert.defaultStyle.textFont = "Fira Code"
hs.alert.defaultStyle.textSize = 16

---- Show hotkeys
function showHelp()
  local t=hs.hotkey.getHotkeys()
  print(t)
  local s=''
  for i=1,#t do s=s..t[i].msg..'\n' end
  alerts.alertI(s:sub(1,-2))
end
hs.hotkey.bind(constants.hyper, "h", "Show Hotkeys", showHelp, alert.closeAll)
--hs.hotkey.showHotkeys(constants.hyper, "h")

---- Lorem Ipsum Generator
hs.hotkey.bind(
    constants.hyper,
    "L",
    "Lorem Ipsum",
    function()
        input = dialog("Lorem Ipsum Number of sentences", "error", "5")
        if input == "" or tonumber(input) == nil then
            alerts.alert(string.format("Invalid Input: %s", input))
            return
        end
        code, output, headers = hs.http.doRequest(string.format("http://metaphorpsum.com/sentences/%s", input), "GET")
        if code ~= 200 then
            alerts.alert(string.format("Lorem Ipsum Error Response code: %d", code))
            logger.ef("Error response for lorem ipsum: %s", output)
        else
            alerts.alert("Lorem Ipsum copied to clipboard")
            hs.pasteboard.setContents(output)
        end
    end
)

---- Snippets
hs.hotkey.bind(constants.hyper, "J", "Snippets", snippets.snippets)

---- Notes
hs.hotkey.bind(constants.hyper, "K", "Notes", function() 
  hs.task.new('/usr/bin/open', function(code, out, err) 
        if code ~= 0 then
          alerts.alert("Error: " .. err, 5)
        end
      end, {'-a', '/Applications/MacVim.app', constants.home .. '/Dropbox/notes.md'}):start()
end)

---- Toggle Dock
hs.hotkey.bind(constants.hyper, "Z", "Toggle Dock", function() 
  alerts.alert(constants.home .. '/scripts/toggle-dock.sh')
  hs.task.new(constants.home .. '/scripts/toggle-dock.sh', function(code, out, err) 
        if code ~= 0 then
          alerts.alert("Error: " .. err, 5)
        end
      end):start()
end)

alerts.alert("Hammerspoon Reloaded")

