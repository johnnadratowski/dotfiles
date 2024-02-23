local str = {}

function str.center(input)
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

function str.split( inSplitPattern, outResults )
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

function str.trim(string)
  return string.gsub(string, '^%s*(.-)%s*$', '%1')
end

function str.isempty(s)
  return s == nil or s == ''
end

return str

