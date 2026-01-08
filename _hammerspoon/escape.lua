local alerts = require('alerts')
local constants = require('constants')

local function escape()
  local copy = hs.pasteboard.getContents()
  if not copy then
    alerts.alert("Clipboard is empty")
    return
  end

  hs.task.new('/usr/bin/python3', function(code, out, err)
    if code == 0 then
      alerts.alertI(out)
      hs.pasteboard.setContents(out)
    else
      alerts.alertI("Error: " .. (err or "unknown error"))
    end
  end, {"-c", "print('''" .. copy .. "''')"}):start()
end

hs.hotkey.bind(constants.hyper, "x", "Escape String", escape, hs.alert.closeAll)
