

-- if hs.urlevent.getDefaultHandler("http") ~= "org.hammerspoon.hammerspoon" then
--     hs.urlevent.setDefaultHandler("http")
-- end

-- local active_browser = hs.settings.get("active_browser") or "org.mozilla.firefox"
-- local browser_menu = hs.menubar.new()

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