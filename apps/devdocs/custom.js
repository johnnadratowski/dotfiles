const {remote} = require('electron')

document.addEventListener("keydown", keyDownTextField, false)

function keyDownTextField(e) {
    if (!e.ctrlKey && !e.metaKey) return
    if (e.key == 'n' || e.key == 'j') press('Down')
    if (e.key == 'p' || e.key == 'k') press('Up')
    if (e.key == 'b') press('Left')
    if (e.key == 'f') press('Right')
}

function press(key) {
  const win = remote.getCurrentWindow()
  win.webContents.sendInputEvent({ type: 'keyDown', keyCode: key })
}