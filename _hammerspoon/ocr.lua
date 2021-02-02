local constants = require("constants")
local log = require("log")

function ocr()
    task = hs.task.new(constants.home .. '/bin/ocr', function(code, out, err) 
      log.d("CODE: " .. code .. " OUT: " .. out .. " ERR: " .. err)
      if code == 0 then
        hs.alert.show("👍 " .. out, 1)
        hs.pasteboard.setContents(out)
      else
        hs.alert.show("Error: " .. err, 2)
      end
    end):start()
end
hs.hotkey.bind(constants.hyper, "4", "OCR", ocr)
