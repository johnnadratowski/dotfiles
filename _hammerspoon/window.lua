constants = require('constants')

-- MOTION

function move_window(direction)  
    return function()  
        local win = hs.window.frontmostWindow()  
        local app = win:application()  
        local app_name = app:name()  
        local f = win:frame()  
        local screen = win:screen()  
        local max = screen:frame()

        if direction == "left" then  
            if f.x == max.x + (max.w / 2) and f.w == max.w / 2 then
                f.x = max.x + (max.w * (1/4))
                f.w = max.w * (3/4)
            elseif f.x == max.x + ((max.w / 4) * 3) and f.w == max.w / 4 then
                f.x = max.x + (max.w / 2)  
                f.w = max.w / 2  
            elseif f.w == max.w / 2 and f.x == max.x then
                f.x = max.x  
                f.w = max.w / 4  
            else
                f.x = max.x  
                f.w = max.w / 2  
            end
        elseif direction == "right" then  
            if f.x == max.x and f.w == max.w / 2 then
                f.x = max.x  
                f.w = max.w * (3/4)
            elseif f.x == max.x and f.w == max.w / 4 then
                f.x = max.x  
                f.w = max.w / 2  
            elseif f.w == max.w / 2 and f.x == max.x + (max.w / 2) then
                f.x = max.x + ((max.w / 4) * 3)
                f.w = max.w / 4  
            else
                f.x = max.x + (max.w / 2)  
                f.w = max.w / 2  
            end
        elseif direction == "up" then  
            if win:isMinimized() then
                win:unminimize()
            elseif f.y == max.y and f.h == max.h / 2 then
                f.y = max.y
                f.h = max.h
                f.x = max.x
                f.w = max.w
            elseif f.y == max.y + (max.h / 2) and f.h == max.h / 2 then
                f.y = max.y
                f.h = max.h
            else
                f.y = max.y
                f.h = max.h / 2
            end
        elseif direction == "down" then  
            if win:isFullScreen() then
                win:toggleFullScreen()
            elseif f.h == max.h / 2 and f.y == max.y then
                f.h = max.h
            elseif f.h == max.h / 2 and f.y == max.y + (max.h / 2) then
                win:minimize()
            else
                f.y = max.y + (max.h / 2)
                f.h = max.h / 2
            end
        else  
            hs.alert.show("move_window(): Freaky parameter received " .. direction)  
        end

        win:setFrame(f, 0)  
    end  
end

hs.hotkey.bind(constants.hyper, "Left", move_window("left"))  
hs.hotkey.bind(constants.hyper, "Right", move_window("right"))  
hs.hotkey.bind(constants.hyper, "Up", move_window("up"))  
hs.hotkey.bind(constants.hyper, "Down", move_window("down"))  

-- LAYOUTS

-- function layoutWindows(layoutType)
--     return function()
--         if layoutType == 2 then
--             windowLayoutObject = hs.window.layout.new({hs.window.filter.new(),"move 1 foc [50,0,100,100] 0,0 | move 1 foc [0,0,50,100] 0,0 | min"})
--         end
--         hs.window.layout.applyLayout(windowLayoutObject)
--     end
-- end


-- SWITCHER
-- hs.hotkey.bind(constants.hyper, "2", layoutWindows(2))

-- hs.hotkey.bind(constants.hyper, "Space", hs.hints.windowHints)
