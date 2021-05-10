local alerts = require('alerts')

function toFilesize()
    copy = hs.pasteboard.getContents()

    ts = tonumber(copy)
    if ts == nil then
        alerts.alert("Invalid size: " .. copy:sub(0, 15))
        return
    end

    task = hs.task.new('/usr/local/bin/numfmt', function(code, out, err) 
      if code == 0 then
        alerts.alertI(out:gsub("^%s*(.-)%s*$"), 3600)
      else
        alerts.alertI("Error: " .. err)
      end
    end, {"--to=si", "--suffix=B", copy}):start()
end
hs.hotkey.bind(constants.hyper, "b", "Human Bytes", toFilesize, hs.alert.closeAll)
