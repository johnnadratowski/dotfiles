function uuid()
    task = hs.task.new('/usr/bin/uuidgen', function(code, out, err) 
      if code == 0 then
        o = out:lower():gsub("%s+", "")
        hs.alert.show(o, 3600)
        hs.pasteboard.setContents(o)
      else
        hs.alert.show("Error: " .. err, 3600)
      end
    end):start()
end
hs.hotkey.bind(constants.hyper, "u", "UUID", uuid, hs.alert.closeAll)
