local alerts = require('alerts')
local constants = require('constants')

local function uuid()
  hs.task.new('/usr/bin/uuidgen', function(code, out, err)
    if code == 0 then
      local result = out:lower():gsub("%s+", "")
      alerts.alertI(result)
      hs.pasteboard.setContents(result)
    else
      alerts.alertI("Error: " .. (err or "unknown error"))
    end
  end):start()
end

hs.hotkey.bind(constants.hyper, "u", "UUID", uuid, hs.alert.closeAll)
