local alerts = require('alerts')
local constants = require('constants')

local function timestampToDate()
  local copy = hs.pasteboard.getContents()
  if not copy then
    local ts = os.time(os.date("!*t"))
    hs.pasteboard.setContents(ts)
    alerts.alertI("No timestamp on clipboard. Showing current timestamp and copying to clipboard: " .. ts)
    return
  end

  copy = copy:match("^%s*(.-)%s*$")

  local ts = tonumber(copy)
  if ts == nil then
    ts = os.time(os.date("!*t"))
    hs.pasteboard.setContents(ts)
    alerts.alertI("No timestamp on clipboard. Showing current timestamp and copying to clipboard: " .. ts)
    return
  end

  while tostring(ts):len() > 10 do
    ts = math.floor(ts / 1000)
  end

  local result = os.date("%Y-%m-%d %H:%M:%S", ts)
  hs.pasteboard.setContents(result)
  alerts.alertI("Timestamp from clipboard: " .. result)
end

hs.hotkey.bind(constants.hyper, "t", "Timestamp", timestampToDate, hs.alert.closeAll)
