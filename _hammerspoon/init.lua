-- INIT

apps = require("applications")
require("caffiene")
require("mic")
require("ping")
require("timestamp")
require("window")

constants = require("constants")

-- SPOONS

hs.loadSpoon("Emojis")
spoon.Emojis:bindHotkeys({toggle = {constants.hyper, "E"}})

-- OTHER

-- Force paste into applications that disallow
hs.hotkey.bind(
    constants.hyper,
    "V",
    function()
        hs.eventtap.keyStrokes(hs.pasteboard.getContents())
    end
)

-- Reload hammerspoon with HYPER+R
hs.hotkey.bind(constants.hyper, "R", hs.reload)

-- Hammerspoon Console
hs.hotkey.bind(constants.hyper, "`", hs.toggleConsole)
hs.preferencesDarkMode(true)
hs.console.darkMode(true)
hs.console.outputBackgroundColor {white = 0}
hs.console.consoleCommandColor {white = 1}
hs.console.alpha(1)

-- Show colorpicker
hs.hotkey.bind(
    constants.hyper,
    "C",
    function()
        hs.osascript.applescript(
            [[
tell application "System Events"
    set frontApp to name of first application process whose frontmost is true
end tell

property my_color : {0, 32896, 65535}

tell application frontApp
    set my_color to choose color default color my_color
end tell

set red to round (first item of my_color) / 257
set green to round (second item of my_color) / 257
set blue to round (third item of my_color) / 257

set red_web to dec_to_hex(red)
set green_web to dec_to_hex(green)
set blue_web to dec_to_hex(blue)

set red_web to normalize(red_web, 2)
set green_web to normalize(green_web, 2)
set blue_web to normalize(blue_web, 2)

set red to normalize(red, 3)
set green to normalize(green, 3)
set blue to normalize(blue, 3)

set decimal_text to "R: " & red & " G: " & green & " B: " & blue
set web_text to "#" & red_web & green_web & blue_web

set dialog_text to decimal_text & return & "Web: " & web_text

set d to display dialog dialog_text with icon 1 buttons {"Cancel", "Copy as Decimal", "Copy for Web"} default button 3

if button returned of d is "Copy as Decimal" then
    set the clipboard to decimal_text
else if button returned of d is "Copy for Web" then
    set the clipboard to web_text
end if


on dec_to_hex(the_number)
    if the_number is 0 then
        return "0"
    end if

    set hex_list to {"0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E", "F"}
    set the_result to ""

    set the_quotient to the_number

    repeat until the_quotient is 0
        set the_quotient to the_number div 16
        set the_result to (item (the_number mod 16 + 1) of hex_list) & the_result
        set the_number to the_quotient
    end repeat

    return the_result

end dec_to_hex

on normalize(the_number, the_length)
    set the_number to the_number as string

    if length of the_number is the_length then
        return the_number
    end if

    repeat until length of the_number is equal to the_length
        set the_number to "0" & the_number
    end repeat

    return the_number
end normalize

]]
        )
    end
)

hs.alert.show("Hammerspoon Reloaded")
