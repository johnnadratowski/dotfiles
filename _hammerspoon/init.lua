-- INIT

local files = require('files')
require("hs.crash")
local alert = require('hs.alert')
require("applications")
require("caffiene")
require("colorpicker")
local dialog = require("dialog")
local dbug = require("dbug")
require("humanfilesize")
require("humanseconds")
local logger = require("log")
require("mic")
--require("mouse")
require("fmtnum")
require("ping")
local snippets = require("snippets")
require("timestamp")
require("window")

constants = require("constants")

---- SEED THE RNG

math.randomseed(os.time())

-- DEBUGGING

hs.crash.crashLogToNSLog = false
configFileWatcher = hs.pathwatcher.new(constants.hammerspoonHome, dbug.reloadConfig)
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

-- store last pastes for meld
hs.hotkey.bind(constants.hyper, "M", "Meld", function() 
  local first = constants.tmp .. 'cp-1'
  local second = constants.tmp .. 'cp-2'
  if not files.exists(first) or not files.exists(second) then
    hs.alert.show("No copy files found for meld command")
    return
  end

  task = hs.task.new('/usr/local/bin/meld', nil, {first, second}):start()
end)

hs.pasteboard.watcher.new(function(data)
  if not data then
    hs.alert.show("No pasteboard data found for copy files")
    return
  end

  local prefix = constants.tmp .. 'cp-'
  print('copy files')
  for i=9,1,-1 do
    if files.exists(prefix .. i) then
      os.rename(prefix .. i, prefix .. (i+1))
    end
  end
  print('open ' .. prefix .. 1)
  file = io.open(prefix .. 1, "w+")
  print('write')
  file:write(data)
  print('close')
  file:close()
  print('fin')
end)

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

---- Show hotkeys
function showHelp()
  local t=hs.hotkey.getHotkeys()
  print(t)
  local s=''
  for i=1,#t do s=s..t[i].msg..'\n' end
  alert(s:sub(1,-2), { atScreenEdge = 1 }, 3600)
end
hs.hotkey.bind(constants.hyper, "h", "Show Hotkeys", showHelp, alert.closeAll)
--hs.hotkey.showHotkeys(constants.hyper, "h")

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
