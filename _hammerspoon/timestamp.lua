constants = require("constants")

function timestampToDate()
    copy = hs.pasteboard.getContents()
    copy = copy:match("^%s*(.-)%s*$")
    if copy:len() > 10 then
        hs.alert.show("Invalid Timestamp: " .. copy:sub(0, 15))
        return
    end

    ts = tonumber(copy)
    if ts == nil then
        hs.alert.show("Invalid Timestamp: " .. copy:sub(0, 15))
        return
    end
    hs.alert.show(os.date("%Y-%m-%d %H:%M:%S", ts))
end
hs.hotkey.bind(constants.hyper, "t", "Timestamp", timestampToDate)
