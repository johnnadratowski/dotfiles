local alerts = require('alerts')

constants = require("constants")

function timestampToDate()
    copy = hs.pasteboard.getContents()
    copy = copy:match("^%s*(.-)%s*$")

    ts = tonumber(copy)
    if ts == nil then
        ts = os.time(os.date("!*t"))
        hs.pasteboard.setContents(ts)
        alerts.alertI("No timestamp on clipboard.  Showing current timestamp and copying to clipboard: " .. ts)
        return
    end

    while tostring(ts):len() > 10 do
        ts = math.floor(ts / 1000)
    end

    ts = os.date("%Y-%m-%d %H:%M:%S", ts)
    hs.pasteboard.setContents(ts)
    alerts.alertI("Timestamp from clipboard: " .. ts)
end
hs.hotkey.bind(constants.hyper, "t", "Timestamp", timestampToDate, hs.alert.closeAll)
