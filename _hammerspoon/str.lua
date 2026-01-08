local str = {}

-- Add split method to string metatable for convenient use (e.g., mystring:split(","))
function string:split(inSplitPattern, outResults)
  if not outResults then
    outResults = {}
  end
  local theStart = 1
  local theSplitStart, theSplitEnd = string.find(self, inSplitPattern, theStart)
  while theSplitStart do
    table.insert(outResults, string.sub(self, theStart, theSplitStart - 1))
    theStart = theSplitEnd + 1
    theSplitStart, theSplitEnd = string.find(self, inSplitPattern, theStart)
  end
  table.insert(outResults, string.sub(self, theStart))
  return outResults
end

-- Center text across multiple lines
function str.center(input)
  local lines = input:split("\n")

  local max = 0
  for _, line in ipairs(lines) do
    if line:len() > max then
      max = line:len()
    end
  end

  local out = ""
  for i = 1, #lines, 1 do
    if i > 1 then
      out = out .. "\n"
    end
    local line = lines[i]
    local diff = max - line:len()
    for j = 1, diff / 2, 1 do
      line = " " .. line
    end
    out = out .. line
  end
  return out
end

function str.trim(s)
  return string.gsub(s, '^%s*(.-)%s*$', '%1')
end

function str.isempty(s)
  return s == nil or s == ''
end

return str

