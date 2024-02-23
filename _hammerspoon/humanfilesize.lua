local alerts = require('alerts')
local dbug = require('dbug')
local str = require('str')

function toFilesize()
    copy = hs.pasteboard.getContents()

    args = {"--to=si", "--suffix=B"}

    ts = string.match(copy, '%d[%d.,]*')
    if ts == nil or ts == '' then
        alerts.alert("Invalid size: " .. copy:sub(0, 15))
        return
    end

    unit = string.match(copy, '[a-zA-Z]+$')
    if not str.isempty(unit) then
      table.insert(args, "--from-unit=" .. string.sub(unit, 1, 1))
    end

    table.insert(args, ts)

    print(ts)
    print(dbug.dump(args))
    task = hs.task.new('/opt/homebrew/bin/numfmt', function(code, out, err) 
      out = str.trim(out)
      print(out)
      if code == 0 then
        alerts.alertI(out, 3600)
      else
        alerts.alertI("Error: " .. err)
      end
    end, args):start()
end
hs.hotkey.bind(constants.hyper, "b", "Human Bytes", toFilesize, hs.alert.closeAll)
