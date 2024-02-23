-- Trace all Lua code
local function lineTraceHook(event, data)
  lineInfo = debug.getinfo(2, "Snl")
  print("TRACE: " .. (lineInfo["short_src"] or "<unknown source>") .. ":" .. (lineInfo["linedefined"] or "<??>"))
end

-- Reload config
local function reloadConfig(paths)
  doReload = false
  for _, file in pairs(paths) do
    if file:sub(-4) == ".lua" then
      print("A lua file changed, doing reload")
      doReload = true
    end
  end
  if not doReload then
    print("No lua file changed, skipping reload")
    return
  end

  hs.reload()
end

local function dump(o)
   if type(o) == 'table' then
      local s = '{ '
      for k,v in pairs(o) do
         if type(k) ~= 'number' then k = '"'..k..'"' end
         s = s .. '['..k..'] = ' .. dump(v) .. ','
      end
      return s .. '} '
   else
      return tostring(o)
   end
end

return {
  lineTraceHook = lineTraceHook,
  reloadConfig = reloadConfig,
  dump = dump,
}
