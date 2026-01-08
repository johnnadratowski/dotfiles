local alerts = require('alerts')
local constants = require('constants')
local log = require('log')

local function ocr()
  hs.task.new(constants.ocr, function(code, out, err)
    log.d("CODE: " .. code .. " OUT: " .. out .. " ERR: " .. err)
    if code == 0 then
      local contents = out:gsub("^%s*(.-)%s*$", "%1")
      alerts.alert(contents, 1)
      hs.pasteboard.setContents(contents)
    else
      alerts.alert("Error: " .. (err or "unknown error"), 2)
    end
  end):start()
end

hs.hotkey.bind(constants.hyper, "4", "OCR", ocr)
