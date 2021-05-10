local alerts = require('alerts')

function uuid()
    task = hs.task.new('/usr/bin/uuidgen', function(code, out, err) 
      if code == 0 then
        o = out:lower():gsub("%s+", "")
        alerts.alertI(o)
        hs.pasteboard.setContents(o)
      else
        alerts.alertI("Error: " .. err)
      end
    end):start()
end
hs.hotkey.bind(constants.hyper, "u", "UUID", uuid, hs.alert.closeAll)
