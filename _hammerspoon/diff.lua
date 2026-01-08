local alerts = require('alerts')
local constants = require("constants")
local files = require('files')
local logger = require("log")
local util = require("util")

hs.hotkey.bind(constants.hyper, "D", "Diff", function()
  local first = constants.tmp .. 'cp-1'
  local second = constants.tmp .. 'cp-2'
  if not files.exists(first) or not files.exists(second) then
    alerts.alert("No copy files found for diff command")
    return
  end

  local args = util.tableMerge(constants.diffargs, {first, second}, {})
  local cmd = constants.diff .. " " .. table.concat(args, " ")
  local displayCmd = cmd:len() > 50 and cmd:sub(1, 47) .. "..." or cmd
  alerts.alert("Opening diff: " .. displayCmd)

  logger.d("Running diff: ", cmd)
  hs.task.new(constants.diff, nil, args):start()
end)

-- store last pastes for diff and use diff application
-- Store in variable to prevent garbage collection
local clipboardWatcher = hs.pasteboard.watcher.new(function(data)
  if not data then
    return
  end

  local prefix = constants.tmp .. 'cp-'
  print('copy files')
  for i=9,1,-1 do
    if files.exists(prefix .. i) then
      os.rename(prefix .. i, prefix .. (i+1))
    end
  end
  local file = io.open(prefix .. 1, "w+")
  if file then
    file:write(data)
    file:close()
  else
    alerts.alert("Error: Could not create clipboard history file")
  end
end)
clipboardWatcher:start()
