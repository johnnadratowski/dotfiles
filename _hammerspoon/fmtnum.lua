
function string:center(input)
  local lines = input:split("\n")

  local max = 0
  for _, line in ipairs(lines) do
    if line:len() > max then
      max = line:len()
    end
  end

  out = ""
  for i=1,#lines,1 do
    if i > 1 then
      out = out .. "\n"
    end
    local line = lines[i]
    diff = max - line:len() 
    for j=1,diff/2,1 do
      line = " " .. line
    end
    out = out .. line
  end
  return out
end

function string:split( inSplitPattern, outResults )
  if not outResults then
    outResults = { }
  end
  local theStart = 1
  local theSplitStart, theSplitEnd = string.find( self, inSplitPattern, theStart )
  while theSplitStart do
    table.insert( outResults, string.sub( self, theStart, theSplitStart-1 ) )
    theStart = theSplitEnd + 1
    theSplitStart, theSplitEnd = string.find( self, inSplitPattern, theStart )
  end
  table.insert( outResults, string.sub( self, theStart ) )
  return outResults
end

function comma_value(amount)
  local formatted = amount
  while true do  
    formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", '%1,%2')
    if (k==0) then
      break
    end
  end
  return formatted
end

function getName(num)
  single = {'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine'}
  teens = {'Ten', 'Eleven', 'Twelve', 'Thirteen', 'Fourteen', 'Fifteen', 'Sixteen', 'Seventeen', 'Eighteen', 'Nineteen'}
  doubs = {'', 'Twenty', 'Thirty', 'Fourty', 'Fifty', 'Sixty', 'Seventy', 'Eighty', 'Ninety'}

  while string.len(num) < 3 do
    num = '0' .. num
  end

  out = ''
  hundred = string.sub(num, 1, 1)
  if hundred ~= '0' then
    i = tonumber(hundred)
    out = single[i] .. ' hundred'
  end

  isTeens = false
  tens = string.sub(num, 2, 2)
  if tens ~= '0' then
    i = tonumber(tens)
    isTeens = i == 1
    if out ~= '' then
      out = out .. ' '
    end
    if isTeens then
      teenI = tonumber(string.sub(num, 3, 3))
      out = out .. teens[teenI + 1]
    else
      out = out .. doubs[i]
    end
  end

  ones = string.sub(num, 3, 3)
  if not isTeens and ones ~= '0' then
    i = tonumber(ones)
    if out ~= '' then
      out = out .. ' '
    end
    out = out .. single[i]
  end
  return out
end

function getOutput(ts)
end

function fmtNum()
  copy = hs.pasteboard.getContents()

  ts = tonumber(copy)
  if ts == nil then
      hs.alert.show("Invalid number: " .. copy:sub(0, 15))
      return
  end

  val = comma_value(ts)

  parts = val:split(",")
  names = {
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
  nameI = #parts
  out = val .. '\n\n'
  for i=1,#parts,1 do 
    if parts[i] ~= '000' then
      out = out .. getName(parts[i])
      curName = names[nameI]
      if curName ~= '' then
        out = out .. ' ' .. curName .. ' '
      end
    end
    nameI = nameI - 1
  end

  hs.alert(out, #parts)
end
hs.hotkey.bind(constants.hyper, "n", "Format Number", fmtNum, hs.alert.closeAll)
