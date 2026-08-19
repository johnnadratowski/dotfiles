local constants = require("constants")

local caffeine = hs.menubar.new()

local function setCaffeineDisplay(state)
  if state then
    caffeine:setIcon(constants.hammerspoonHome .. "icons/caffiene-active.png")
  else
    caffeine:setIcon(constants.hammerspoonHome .. "icons/caffiene-inactive.png")
  end
end

local function caffeineClicked()
  setCaffeineDisplay(hs.caffeinate.toggle("displayIdle"))
end

if caffeine then
  caffeine:setClickCallback(caffeineClicked)
  setCaffeineDisplay(hs.caffeinate.get("displayIdle"))
end
