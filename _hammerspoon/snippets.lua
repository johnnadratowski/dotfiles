constants = require("constants")

local mod = {}

local function isempty(s)
  return s == nil or s == ""
end

local function read_file(path)
  local file = io.open(path, "rb") -- r read mode and b binary mode
  if not file then
    return nil
  end
  local content = file:read "*a" -- *a or *all reads the whole file
  file:close()
  return content
end

function str_split(str, split)
  split = split or "%S+"
  out = {}
  for i in string.gmatch(str, split) do
    table.insert(out, i)
  end

  return out
end

function table.contains(table, element)
  for _, value in pairs(table) do
    if value == element then
      return true
    end
  end
  return false
end

function str_starts_with(str, start)
  return str:sub(1, #start) == start
end

function list_dir(dir)
  out = {}
  local iterFn, dirObj = hs.fs.dir(dir)
  if iterFn then
    for file in iterFn, dirObj do
      if not str_starts_with(file, ".") then
        table.insert(out, file)
      end
    end
  else
    hs.alert.show(string.format("The following error occurred: %s", dirObj))
  end

  return out
end

function mod.snippets()
  local SNIPPET_DIR = constants.home .. "snippets/"
  local current = hs.application.frontmostApplication()
  local choices = {}

  local chooser =
    hs.chooser.new(
    function(chosen)
      if chosen == nil then
        return
      end
      if copy then
        copy:delete()
      end
      if tab then
        tab:delete()
      end
      current:activate()
      -- hs.eventtap.keyStrokes(chosen.data)
      hs.pasteboard.writeObjects(chosen.data)
      hs.eventtap.keyStroke("cmd", "v")
    end
  )

  -- Removes all items in list
  function reset()
    chooser:choices({})
  end

  tab =
    hs.hotkey.bind(
    "",
    "tab",
    function()
      local id = chooser:selectedRow()
      local item = choices[id]
      -- If no row is selected, but tab was pressed
      if not item then
        return
      end
      chooser:query(item.text)
      reset()
      updateChooser()
    end
  )

  copy =
    hs.hotkey.bind(
    "cmd",
    "c",
    function()
      local id = chooser:selectedRow()
      local item = choices[id]
      if item then
        chooser:hide()
        hs.pasteboard.setContents(item.text)
        hs.alert.show("Copied to clipboard", 1)
      else
        hs.alert.show("No search result to copy", 1)
      end
    end
  )

  function get_matches(str, queries)
    local matches = 0
    for _, query in pairs(queries) do
      if string.match(str:lower(), query:lower()) then
        matches = matches + 1
      end
    end
    return matches
  end

  function updateChooser()
    local query = chooser:query()

    local all_dirs = list_dir(SNIPPET_DIR)
    local dirs = all_dirs
    local queries
    if not isempty(query) then
      local first = str_split(query)[1]
      local found = table.contains(all_dirs, first:lower())
      if found then
        dirs = {first}
        queries = str_split(query:sub(#first + 1))
      else
        queries = str_split(query)
      end
    end

    local choices = {}
    local no_queries = queries == nil or #queries == 0
    for _, dir in pairs(dirs) do
      local cur_dir = SNIPPET_DIR .. dir .. "/"
      local files = list_dir(cur_dir)
      for _, file in pairs(files) do
        local filePath = cur_dir .. file
        local data = read_file(filePath)
        local matches
        if not no_queries then
          matches = get_matches(file .. " " .. data, queries)
        end

        if no_queries or matches > 0 then
          table.insert(
            choices,
            {
              ["text"] = dir:upper() .. ": " .. file,
              ["subText"] = data:gsub("\n", ""):sub(0, 75),
              ["data"] = data,
              ["matches"] = matches
            }
          )
        end
      end
    end

    table.sort(
      choices,
      function(x, y)
        return x.matches == nil or x.matches < y.matches
      end
    )

    chooser:choices(choices)
  end

  chooser:queryChangedCallback(updateChooser)

  chooser:searchSubText(false)

  chooser:show()
end

return mod
