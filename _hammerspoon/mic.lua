micMuteStatusMenu = hs.menubar.new()

function getAudioDevice()
    local currentAudioInput = hs.audiodevice.current(true)
    return hs.audiodevice.findInputByUID(currentAudioInput.uid)
end

function displayMicMuteStatus()
    muted = getAudioDevice():inputMuted()
    if muted then
        micMuteStatusMenu:setIcon(os.getenv("HOME") .. "/.hammerspoon/muted.png")
    else
        micMuteStatusMenu:setIcon(os.getenv("HOME") .. "/.hammerspoon/unmuted.png")
    end
end

for i,dev in ipairs(hs.audiodevice.allInputDevices()) do
   dev:watcherCallback(displayMicMuteStatus):watcherStart()
end

function toggleMicMuteStatus()
    local currentAudioInputObject = getAudioDevice()
    currentAudioInputObject:setInputMuted(not getAudioDevice():inputMuted())
    displayMicMuteStatus()
end

if micMuteStatusMenu then
    micMuteStatusMenu:setClickCallback(toggleMicMuteStatus)
    displayMicMuteStatus()
end

