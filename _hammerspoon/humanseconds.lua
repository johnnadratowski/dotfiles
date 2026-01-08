local alerts = require('alerts')
local constants = require('constants')

local function toDays()
  local copy = hs.pasteboard.getContents()
  if not copy then
    alerts.alert("Clipboard is empty")
    return
  end

  local ts = tonumber(copy)
  if ts == nil then
    alerts.alert("Invalid seconds: " .. copy:sub(0, 15))
    return
  end

  local seconds = math.floor(ts % 60)
  local total_minutes = math.floor(ts / 60)
  local minutes = math.floor(total_minutes % 60)
  local total_hours = math.floor(total_minutes / 60)
  local hours = math.floor(total_hours % 24)
  local days = math.floor(total_hours / 24)

  local time = os.time()
  local date = os.date("*t", time + ts)

  local one = string.format("%d days, %d hours, %d minutes, %d seconds\n", days, hours, minutes, seconds)
  local two = string.format("%d-%02d-%02d %02d:%02d:%02d", date.year, date.month, date.day, date.hour, date.min, date.sec)
  local out = one .. two
  alerts.alertI(out)
end

hs.hotkey.bind(constants.hyper, "s", "Human Seconds", toDays, hs.alert.closeAll)
