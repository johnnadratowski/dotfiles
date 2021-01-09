function toDays()
    copy = hs.pasteboard.getContents()

    ts = tonumber(copy)
    if ts == nil then
        hs.alert.show("Invalid seconds: " .. copy:sub(0, 15))
        return
    end

    seconds = math.floor(ts % 60)
    total_minutes = math.floor(ts / 60)
    minutes = math.floor(total_minutes % 60)
    total_hours = math.floor(total_minutes / 60)
    hours = math.floor(total_hours % 24)
    days = math.floor(total_hours / 24)

    time = os.time()
    date = os.date("*t", time + ts)

    one = string.format("%d days, %d hours, %d minutes, %d seconds\n", days, hours, minutes, seconds)
    two = string.format("%d-%02d-%02d %02d:%02d:%02d", date.year, date.month, date.day, date.hour, date.min, date.sec)
    hs.alert.show(one .. two, 3600)
end
hs.hotkey.bind(constants.hyper, "s", "Human Seconds", toDays, hs.alert.closeAll)
