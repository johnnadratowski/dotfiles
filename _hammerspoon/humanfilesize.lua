function toFilesize()
    copy = hs.pasteboard.getContents()

    ts = tonumber(copy)
    if ts == nil then
        hs.alert.show("Invalid size: " .. copy:sub(0, 15))
        return
    end

    task = hs.task.new('/usr/local/bin/numfmt', function(code, out, err) 
      if code == 0 then
        hs.alert.show(out:gsub("^%s*(.-)%s*$", "%1"))
      else
        hs.alert.show("Error: " .. err)
      end
    end, {"--to=iec-i", "--suffix=B", copy}):start()
end
hs.hotkey.bind(constants.hyper, "b", "Human Bytes", toFilesize)
