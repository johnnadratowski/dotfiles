local alert = require('hs.alert')

local alerts = {}

function alerts.alert(data, timeout)
  local atScreenEdge = 0
  if select(2, data:gsub('\n', '\n')) > 20 then
    atScreenEdge = 1
  end
  alert(data, { atScreenEdge = atScreenEdge }, timeout)
end

function alerts.alertI(data)
  alerts.alert(data, "indefinite")
end

return alerts
