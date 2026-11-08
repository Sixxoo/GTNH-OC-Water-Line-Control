-- Event listeners of the controllers, through the recovery addon: an error in a callback stops the
-- run and starts it again, and every listener is cancelled when a run ends
local recovery = require("addons.core").load("recovery")

local listeners = {}

---Listen to an event for the current run
---@param name string
---@param callback function
---@return number id
function listeners.listen(name, callback)
  return recovery.listen(name, callback)
end

---Nothing to do: recovery cancels a run's listeners when it ends
function listeners.cancelAll()
end

return listeners
