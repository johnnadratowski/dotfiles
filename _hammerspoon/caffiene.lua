local constants = require("constants")

-- WHAT THIS TOGGLE CAN AND CANNOT PREVENT.
--
-- It exists so a long-running job (the agent fleet) is not cut off by the machine sleeping.
-- On 2026-08-18 that failed and cost a night's work, so the boundary is written down here
-- rather than left to be re-derived from the menubar icon:
--
--   IT PREVENTS  idle sleep — nobody has touched the machine for a while. `displayIdle`
--                already covers the system as well as the screen (hs.caffeinate's own docs:
--                "Controls whether the screen will be allowed to sleep (and also the system)
--                if the user is idle"), and `pmset -g assertions` corroborates it: powerd
--                adds its own PreventUserIdleSystemSleep for as long as the display is on.
--                `systemIdle` is asserted too so the guarantee does not RIDE on that — the
--                moment the display is off for any other reason, the transitive one is gone.
--
--   IT CANNOT PREVENT  the lid closing. `Clamshell Sleep` answers to no power assertion of
--                any kind, `system` included. This is the one that actually bit: the machine
--                slept at 22:23:41 with this toggle on and stayed asleep until the lid was
--                opened at 10:36. Only `sudo pmset -a disablesleep 1` stops it, which is a
--                root, machine-wide, persists-across-reboot setting and therefore not
--                something a menubar click should be doing silently.
--
-- Also: `hs.caffeinate.toggle` applies systemIdle to AC ONLY. `set(..., true)` is what makes
-- it hold on battery, which is when a sleeping machine is most likely and least wanted.
local caffeine = hs.menubar.new()

-- The icon is re-read from the ASSERTION, not remembered. It used to be set only at click
-- time, so anything that changed the assertion from elsewhere left the menubar asserting a
-- state that was no longer true — a claim standing in for an observation.
local POLL_SECONDS = 10

local function setCaffeineDisplay(state)
  if state then
    caffeine:setIcon(constants.hammerspoonHome .. "icons/caffiene-active.png")
  else
    caffeine:setIcon(constants.hammerspoonHome .. "icons/caffiene-inactive.png")
  end
  -- SAYS WHAT IT MEANS, because the icon alone was read as "the machine will not sleep" and
  -- that is not what any of this buys.
  if caffeine.setTooltip then
    caffeine:setTooltip(state
      and "Idle sleep prevented (AC and battery). The LID still sleeps the machine —"
          .. " for that: sudo pmset -a disablesleep 1"
      or "Idle sleep allowed")
  end
end

local function awake()
  return hs.caffeinate.get("systemIdle") == true
      or hs.caffeinate.get("displayIdle") == true
end

local function apply(on)
  hs.caffeinate.set("displayIdle", on, true)
  hs.caffeinate.set("systemIdle", on, true)
  setCaffeineDisplay(awake())
end

local function caffeineClicked()
  apply(not awake())
end

if caffeine then
  caffeine:setClickCallback(caffeineClicked)
  setCaffeineDisplay(awake())
  -- Kept in a module-level local so it is not collected out from under us.
  caffeineWatcher = hs.timer.doEvery(POLL_SECONDS, function()
    setCaffeineDisplay(awake())
  end)
end
