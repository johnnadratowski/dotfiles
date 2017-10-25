require('window')
require('caffiene')
-- Force paste into applications that disallow
hs.hotkey.bind({"cmd", "alt"}, "V", function() hs.eventtap.keyStrokes(hs.pasteboard.getContents()) end)
