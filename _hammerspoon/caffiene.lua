caffeine = hs.menubar.new()
function setCaffeineDisplay(state)
    if state then  
        caffeine:setIcon(os.getenv("HOME") .. "/.hammerspoon/caffiene-active.png")  
    else  
        caffeine:setIcon(os.getenv("HOME") .. "/.hammerspoon/caffiene-inactive.png")  
    end  
end

function caffeineClicked()
    setCaffeineDisplay(hs.caffeinate.toggle("displayIdle"))
end

if caffeine then
    caffeine:setClickCallback(caffeineClicked)
    setCaffeineDisplay(hs.caffeinate.get("displayIdle"))
end
