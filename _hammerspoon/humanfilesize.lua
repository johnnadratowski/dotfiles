local alerts = require('alerts')
local constants = require('constants')
local dbug = require('dbug')
local str = require('str')

local function toFilesize()
  local copy = hs.pasteboard.getContents()
  if not copy then
    alerts.alert("Clipboard is empty")
    return
  end

  local args = {"--to=si", "--suffix=B"}

  local ts = string.match(copy, '%d[%d.,]*')
  if ts == nil or ts == '' then
    alerts.alert("Invalid size: " .. copy:sub(0, 15))
    return
  end

  local unit = string.match(copy, '[a-zA-Z]+$')
  if not str.isempty(unit) then
    table.insert(args, "--from-unit=" .. string.sub(unit, 1, 1))
  end

  table.insert(args, ts)

  print(ts)
  print(dbug.dump(args))
  hs.task.new('/opt/homebrew/bin/numfmt', function(code, out, err)
    if code == 0 then
      local result = str.trim(out)
      print(result)
      alerts.alertI(result, 3600)
    else
      alerts.alertI("Error: " .. (err or "unknown error"))
    end
  end, args):start()
end

hs.hotkey.bind(constants.hyper, "b", "Human Bytes", toFilesize, hs.alert.closeAll)
