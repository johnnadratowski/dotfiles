function move_window(direction)  
    return function()  
        local win = hs.window.focusedWindow()  
        local app = win:application()  
        local app_name = app:name()  
        local f = win:frame()  
        local screen = win:screen()  
        local max = screen:frame()

        if direction == "left" then  
            if app_name == "Tweetbot" then  
                f.x = max.x  
            else  
                f.x = max.x  
                f.w = max.w / 2  
            end  
        elseif direction == "right" then  
            if app_name == "Tweetbot" then  
                f.x = max.x + (max.w - f.w)  
            else  
                f.x = max.x + (max.w / 2)  
                f.w = max.w / 2  
            end  
        elseif direction == "up" then  
            f.x = max.x  
            f.w = max.w  
        elseif direction == "down" then  
            f.x = max.x + (max.w / 6)  
            f.w = max.w * 2 / 3  
        else  
            hs.alert.show("move_window(): Freaky parameter received " .. direction)  
        end

        f.y = max.y  
        f.h = max.h  
        win:setFrame(f, 0)  
    end  
end

local hyper = {"cmd", "ctrl", "alt"}  
hs.hotkey.bind(hyper, "Left", move_window("left"))  
hs.hotkey.bind(hyper, "Right", move_window("right"))  
hs.hotkey.bind(hyper, "Up", move_window("up"))  
hs.hotkey.bind(hyper, "Down", move_window("down"))  
