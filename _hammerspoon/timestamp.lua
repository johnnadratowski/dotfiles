constants = require("constants")

function timestampToDate()
    copy = hs.pasteboard.getContents()
    copy = copy:match("^%s*(.-)%s*$")
    if copy:len() <= 10 then
        ts = tonumber(copy)
        if ts == nil then
            return
        end
        hs.alert.show(os.date("%Y-%m-%d %H:%M:%S", ts))
    end
end
hs.hotkey.bind(constants.hyper, "t", timestampToDate)
