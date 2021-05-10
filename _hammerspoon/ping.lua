local alerts = require('alerts')
constants = require("constants")

function pingResult(object, message, seqnum, error)
    if message == "didFinish" then
        avg = tonumber(string.match(object:summary(), "/(%d+.%d+)/"))
        if avg == 0.0 then
            alerts.alert("No network")
        elseif avg < 200.0 then
            alerts.alert("Network good (" .. avg .. "ms)")
        elseif avg < 500.0 then
            alerts.alert("Network poor(" .. avg .. "ms)")
        else
            alerts.alert("Network bad(" .. avg .. "ms)")
        end
    end
end
hs.hotkey.bind(
    constants.hyper,
    "p",
    "Ping",
    function()
        hs.network.ping.ping("8.8.8.8", 1, 0.01, 1.0, "any", pingResult)
    end
)
