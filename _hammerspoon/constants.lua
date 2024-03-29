local constants = {}
constants.hyper = {"alt", "ctrl", "cmd", "shift"}
--constants.hyper = {"fn"}

constants.home = os.getenv("HOME")

constants.tmp = constants.home .. "/tmp/"

constants.hammerspoonHome = constants.home .. "/.hammerspoon/"

constants.loglevel = "debug"

constants.diff = "/usr/bin/open"
constants.diffargs = {"-na", "PyCharm.app", "--args", "diff"}

constants.ocr = constants.home .. '/bin/ocr'

constants.defaultBrowser = "Google Chrome"
--constants.defaultBrowser = 'FirefoxDeveloperEdition'
constants.defaultBrowserApp = "org.mozilla.firefox"
constants.availableBrowsers = {
    ["com.apple.safari"] = {
        name = "Safari",
        icon = os.getenv("HOME") .. "/.hammerspoon/icons/safari.png"
    },
    ["org.mozilla.firefox"] = {
        name = "FirefoxDeveloperEdition",
        icon = os.getenv("HOME") .. "/.hammerspoon/icons/firefox.png"
    },
    ["com.google.chrome"] = {
        name = "Google Chrome",
        icon = os.getenv("HOME") .. "/.hammerspoon/icons/chrome.png"
    }
}

constants.editors = {
    "/Applications/Visual Studio Code.app",
    "/Applications/PyCharm.app",
    "/usr/local/Cellar/macvim/8.0-133/MacVim.app",
    "/Applications/GoLand 1.0 EAP.app"
}
constants.editor = 0

return constants
