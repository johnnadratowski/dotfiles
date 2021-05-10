local alerts = require('alerts')

hs.pasteboard.callbackWhenChanged(5, function(state)
  alerts.alert('here')
  if state then
