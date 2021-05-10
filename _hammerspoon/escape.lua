local alerts = require('alerts')

function escape()
    copy = hs.pasteboard.getContents()

    task = hs.task.new('/usr/bin/python3', function(code, out, err) 
      if code == 0 then
        alerts.alertI(out)
        hs.pasteboard.setContents(out)
      else
        alerts.alertI("Error: " .. err)
      end
    end, {"-c", "print('''" .. copy .. "''')"}):start()
end
hs.hotkey.bind(constants.hyper, "x", "Escape String", escape, hs.alert.closeAll)
