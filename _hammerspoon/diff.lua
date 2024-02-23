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

  logger.d("Running diff: ", constants.diff)
  task = hs.task.new(constants.diff, nil, util.tableMerge(constants.diffargs, {first, second}, {})):start()
end)

-- store last pastes for diff and use diff application
hs.pasteboard.watcher.new(function(data)
  if not data then
    alerts.alert("No pasteboard data found for copy files")
    return
  end

  local prefix = constants.tmp .. 'cp-'
  print('copy files')
  for i=9,1,-1 do
    if files.exists(prefix .. i) then
      os.rename(prefix .. i, prefix .. (i+1))
    end
  end
  file = io.open(prefix .. 1, "w+")
  file:write(data)
  file:close()
end)
