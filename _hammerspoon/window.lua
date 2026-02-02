local alerts = require('alerts')
local constants = require("constants")

-- MOTION

function move_window(direction)
    return function()
        local win = hs.window.frontmostWindow()
        local app = win:application()
        local app_name = app:name()
        local f = win:frame()
        local screen = win:screen()
        local max = screen:frame()

        -- Helper to check if two values are approximately equal (within 2 pixels)
        local function approx(a, b)
            return math.abs(a - b) < 2
        end

        if direction == "left" then
            -- Window on right half → expand left to 2/3
            if approx(f.x, max.x + max.w / 2) and approx(f.w, max.w / 2) then
                f.x = max.x + max.w / 3
                f.w = max.w * 2 / 3
            -- Window on right 2/3 → expand left to 3/4
            elseif approx(f.x, max.x + max.w / 3) and approx(f.w, max.w * 2 / 3) then
                f.x = max.x + max.w / 4
                f.w = max.w * 3 / 4
            -- Window on right quarter → expand left to 1/3
            elseif approx(f.x, max.x + max.w * 3 / 4) and approx(f.w, max.w / 4) then
                f.x = max.x + max.w * 2 / 3
                f.w = max.w / 3
            -- Window on right 1/3 → expand left to half
            elseif approx(f.x, max.x + max.w * 2 / 3) and approx(f.w, max.w / 3) then
                f.x = max.x + max.w / 2
                f.w = max.w / 2
            -- Window on left half → shrink to 1/3
            elseif approx(f.x, max.x) and approx(f.w, max.w / 2) then
                f.x = max.x
                f.w = max.w / 3
            -- Window on left 1/3 → shrink to quarter
            elseif approx(f.x, max.x) and approx(f.w, max.w / 3) then
                f.x = max.x
                f.w = max.w / 4
            -- Window on left 2/3 → shrink to half
            elseif approx(f.x, max.x) and approx(f.w, max.w * 2 / 3) then
                f.x = max.x
                f.w = max.w / 2
            -- Default → left half
            else
                f.x = max.x
                f.w = max.w / 2
            end
        elseif direction == "right" then
            -- Window on left half → expand right to 2/3
            if approx(f.x, max.x) and approx(f.w, max.w / 2) then
                f.x = max.x
                f.w = max.w * 2 / 3
            -- Window on left 2/3 → expand right to 3/4
            elseif approx(f.x, max.x) and approx(f.w, max.w * 2 / 3) then
                f.x = max.x
                f.w = max.w * 3 / 4
            -- Window on left quarter → expand right to 1/3
            elseif approx(f.x, max.x) and approx(f.w, max.w / 4) then
                f.x = max.x
                f.w = max.w / 3
            -- Window on left 1/3 → expand right to half
            elseif approx(f.x, max.x) and approx(f.w, max.w / 3) then
                f.x = max.x
                f.w = max.w / 2
            -- Window on right half → shrink to 1/3
            elseif approx(f.x, max.x + max.w / 2) and approx(f.w, max.w / 2) then
                f.x = max.x + max.w * 2 / 3
                f.w = max.w / 3
            -- Window on right 1/3 → shrink to quarter
            elseif approx(f.x, max.x + max.w * 2 / 3) and approx(f.w, max.w / 3) then
                f.x = max.x + max.w * 3 / 4
                f.w = max.w / 4
            -- Window on right 2/3 → shrink to half
            elseif approx(f.x, max.x + max.w / 3) and approx(f.w, max.w * 2 / 3) then
                f.x = max.x + max.w / 2
                f.w = max.w / 2
            -- Default → right half
            else
                f.x = max.x + max.w / 2
                f.w = max.w / 2
            end
        elseif direction == "up" then
            if win:isMinimized() then
                win:unminimize()
            elseif f.y == max.y and f.h < max.h then
                f.y = max.y
                f.h = max.h
            elseif f.y == max.y and f.h == max.h and f.w == max.w then
                f.y = max.y
                f.h = max.h
                f.x = max.x
                f.w = max.w / 2
            elseif f.y == max.y and f.h == max.h then
                f.y = max.y
                f.h = max.h
                f.x = max.x
                f.w = max.w
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
            alerts.alert("move_window(): Freaky parameter received " .. direction)
        end

        win:setFrame(f, 0)
    end
end

hs.hotkey.bind(constants.hyper, "Left", "Window Left", move_window("left"))
hs.hotkey.bind(constants.hyper, "Right", "Window Right", move_window("right"))
hs.hotkey.bind(constants.hyper, "Up", "Window Up", move_window("up"))
hs.hotkey.bind(constants.hyper, "Down", "Window Down", move_window("down"))

function moveWindowToDisplay(d)
  return function()
    local displays = hs.screen.allScreens()
    local win = hs.window.focusedWindow()
    win:moveToScreen(displays[d], false, true)
  end
end

hs.hotkey.bind(constants.hyper, "1", "Move to Display 1", moveWindowToDisplay(1))
hs.hotkey.bind(constants.hyper, "2", "Move to Display 2", moveWindowToDisplay(2))
hs.hotkey.bind(constants.hyper, "3", "Move to Display 3", moveWindowToDisplay(3))

hs.hotkey.bind(constants.hyper, "M", "Maximize", function() 
  hs.window.focusedWindow():maximize()
end)

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
