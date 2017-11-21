
constants = require('constants')

-- Application quick switching
hs.hotkey.bind(constants.hyper, '1', function() hs.application.launchOrFocus('Terminal') end)
hs.hotkey.bind(constants.hyper, '2', function() hs.application.launchOrFocus(constants.defaultBrowser) end)
hs.hotkey.bind(constants.hyper, '3', function() hs.application.launchOrFocus('Slack') end)
hs.hotkey.bind(constants.hyper, '4', function() hs.application.launchOrFocus('Gmail') end)
hs.hotkey.bind(constants.hyper, '5', function() hs.application.launchOrFocus('Gcal') end)

hs.hotkey.bind(constants.hyper, 'D', function() hs.application.launchOrFocus('DevDocs') end)

function ensureOpen(app, timeout, delay, fn)
    local app = hs.application.open(app, timeout, true)
    if app == nil then
        hs.alert.show("Could not open " .. app)
        return
    end

    local done = os.time() + timeout
    while os.time() < done do
        hs.timer.usleep(delay)
        if hs.application.frontmostApplication():name() == app:name() then
            break
        end
    end

    if fn == nil then
        return app
    end

    return fn(app)
end

function google()
    ensureOpen(constants.defaultBrowser, 3, 100000):selectMenuItem("New Tab")
end
hs.hotkey.bind(constants.hyper, 'G', google)


-- if hs.urlevent.getDefaultHandler("http") ~= "org.hammerspoon.hammerspoon" then
--     hs.urlevent.setDefaultHandler("http")
-- end

-- local active_browser = hs.settings.get("active_browser") or "com.apple.safari"
-- local browser_menu = hs.menubar.new()
-- local available_browsers = {
--     ["com.apple.safari"] = {
--         name = "Safari",
--         icon = os.getenv("HOME") .. "/.hammerspoon/icons/safari.png"
--     },
--     ["org.mozilla.firefox"] = {
--         name = "Firefox",
--         icon = os.getenv("HOME") .. "/.hammerspoon/icons/firefox.png"
--     },
--     ["com.google.chrome"] = {
--         name = "Google Chrome",
--         icon = os.getenv("HOME") .. "/.hammerspoon/icons/chrome.png"
--     },
-- }

-- function init_browser_menu()
--     local menu_items = {}

--     for browser_id, browser_data in pairs(available_browsers) do
--         local image = hs.image.imageFromPath(browser_data["icon"]):setSize({w=16, h=16})

--         if browser_id == active_browser then
--             browser_menu:setIcon(image)
--         end

--         table.insert(menu_items, {
--             title = browser_data["name"],
--             image = image,
--             checked = browser_id == active_browser,
--             fn = function()
--                 active_browser = browser_id
--                 hs.settings.set("active_browser", browser_id)
--                 init_browser_menu()
--             end
--         })
--     end

--     browser_menu:setMenu(menu_items)
-- end

-- init_browser_menu()

-- hs.urlevent.httpCallback = function(scheme, host, params, fullURL)
--     hs.urlevent.openURLWithBundle(fullURL, active_browser)
-- end