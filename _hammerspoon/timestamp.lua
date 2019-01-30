constants = require("constants")

function timestampToDate()
    copy = hs.pasteboard.getContents()
    copy = copy:match("^%s*(.-)%s*$")

    ts = tonumber(copy)
    if ts == nil then
        hs.alert.show("Invalid Timestamp: " .. copy:sub(0, 15))
        return
    end

    while tostring(ts):len() > 10 do
        ts = math.floor(ts / 1000)
    end

    hs.alert.show(os.date("%Y-%m-%d %H:%M:%S", ts))
end
hs.hotkey.bind(constants.hyper, "t", "Timestamp", timestampToDate)
