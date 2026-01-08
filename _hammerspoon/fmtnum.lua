local alerts = require('alerts')
local constants = require('constants')
require('str')  -- Adds string:split to string metatable

local function comma_value(amount)
  local formatted = amount
  local k
  while true do
    formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", '%1,%2')
    if k == 0 then
      break
    end
  end
  return formatted
end

local function getName(num)
  local single = {'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine'}
  local teens = {'Ten', 'Eleven', 'Twelve', 'Thirteen', 'Fourteen', 'Fifteen', 'Sixteen', 'Seventeen', 'Eighteen', 'Nineteen'}
  local doubs = {'', 'Twenty', 'Thirty', 'Fourty', 'Fifty', 'Sixty', 'Seventy', 'Eighty', 'Ninety'}

  while string.len(num) < 3 do
    num = '0' .. num
  end

  local out = ''
  local hundred = string.sub(num, 1, 1)
  if hundred ~= '0' then
    local i = tonumber(hundred)
    out = single[i] .. ' hundred'
  end

  local isTeens = false
  local tens = string.sub(num, 2, 2)
  if tens ~= '0' then
    local i = tonumber(tens)
    isTeens = i == 1
    if out ~= '' then
      out = out .. ' '
    end
    if isTeens then
      local teenI = tonumber(string.sub(num, 3, 3))
      out = out .. teens[teenI + 1]
    else
      out = out .. doubs[i]
    end
  end

  local ones = string.sub(num, 3, 3)
  if not isTeens and ones ~= '0' then
    local i = tonumber(ones)
    if out ~= '' then
      out = out .. ' '
    end
    out = out .. single[i]
  end
  return out
end

local function fmtNum()
  local copy = hs.pasteboard.getContents()
  if not copy then
    alerts.alert("Clipboard is empty")
    return
  end

  local ts = tonumber(copy)
  if ts == nil then
    alerts.alert("Invalid number: " .. copy:sub(0, 15))
    return
  end

  local val = comma_value(ts)
  local parts = val:split(",")
  local names = {
    '',
    'Thousand',
    'Million',
    'Billion',
    'Trillion',
    'Quadrillion',
    'Quintillion',
    'Sextillion',
    'Septillion',
    'Octillion',
    'Nonillion',
    'Decillion',
    'Undecillion',
    'Duodecillion',
    'Tredecillion',
    'Quattuordecillion',
    'Quindecillion',
    'Sexdecillion',
    'Septendecillion',
    'Octodecillion',
    'Novemdecillion',
    'Vigintillion'
  }
  local nameI = #parts
  local out = val .. '\n\n'
  for i = 1, #parts, 1 do
    if parts[i] ~= '000' then
      out = out .. getName(parts[i])
      local curName = names[nameI]
      if curName ~= '' then
        out = out .. ' ' .. curName .. ' '
      end
    end
    nameI = nameI - 1
  end

  alerts.alert(out, #parts)
end

hs.hotkey.bind(constants.hyper, "n", "Format Number", fmtNum, hs.alert.closeAll)
