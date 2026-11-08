local event = require("event")
local term = require("term")
local computer = require("computer")

local classBuilder = require("lib.class-builder.index")
local componentDiscover = require("lib.component-discover.index")

local discord = require("src.discord")

---Ticks before the end of a cycle when "cycle_pre_end" is sent. 10 seconds, so a slow loop with all eight tiers still sees it
local preEndTicks = 200

---@class LineController
---@field lastWorkProgress integer
---@field workMaxProgress integer
---@field progressReadAt number|nil
---@field isPreEndSent boolean
---@field wasWorking boolean
---@field controllers ControllersConfig
---@field controllerProxy gt_machine
local lineController = {}

---Constructor
---@return LineController
function lineController:constructor()
  self.lastWorkProgress = 0
  self.workMaxProgress = 0
  self.progressReadAt = nil
  self.isPreEndSent = false

  return self
end

---Init
---@param controllers ControllersConfig
function lineController:init(controllers)
  self.controllers = controllers or {}

  term.write("Init Line components: ")
  self:initComponents()
  self.wasWorking = self.controllerProxy.hasWork()
  term.write("ok\n")
end

---Loop
function lineController:loop()
  local workProgress = self.controllerProxy.getWorkProgress()
  local workMaxProgress = self.controllerProxy.getWorkMaxProgress()
  local hasWork = self.controllerProxy.hasWork()

  if self.lastWorkProgress > workProgress or (hasWork == false and self.lastWorkProgress ~= 0) then
    -- The loop missed the last seconds of the cycle, so choose the units for the cycle after this one
    if self.isPreEndSent == false then
      event.push("cycle_pre_end", true)
    end

    -- true when the next cycle already runs, false when the plant stopped
    event.push("cycle_end", hasWork == true)
    self.lastWorkProgress = 0
    self.isPreEndSent = false

    if hasWork == true then
      self:logCycleStart()
    end
  elseif hasWork == true and self.wasWorking == false then
    self:logCycleStart()
    discord.clear("plant", "plantStopped", "Water Purification Plant runs again", "")
  end

  if hasWork == false and self.wasWorking == true then
    event.push("log_warning", "[Line] Plant stopped (switched off or no power)")
    discord.alert("plant", "plantStopped", "Water Purification Plant stopped",
      "It was switched off, or has no power.", "Water Purification Plant still stopped")
  end

  self.wasWorking = hasWork

  -- Units must be chosen before the cycle ends, because the next one starts in the same tick
  if workMaxProgress ~= 0 and workProgress >= workMaxProgress - preEndTicks and self.isPreEndSent == false then
    event.push("cycle_pre_end")
    self.isPreEndSent = true
  end

  if hasWork == true then
    self.lastWorkProgress = workProgress
  end

  -- For the screen, which counts on from here instead of asking the plant every second
  self.workMaxProgress = hasWork == true and workMaxProgress or 0
  self.progressReadAt = computer.uptime()
end

---Log the units running in the cycle that just started
---@private
function lineController:logCycleStart()
  local running = {}

  for tier = 1, 8 do
    local controller = self.controllers["t"..tier]

    if controller ~= nil and controller.controllerProxy ~= nil and controller.controllerProxy.hasWork() == true then
      table.insert(running, "T"..tier)
    end
  end

  event.push("log_debug", "[Line] Cycle started: "..(#running > 0 and table.concat(running, " ") or "no units"))

  -- For the statistics on the screen
  if self.stats ~= nil then
    self.stats.cycles = self.stats.cycles + 1

    for _, name in ipairs(running) do
      local tier = tonumber(name:sub(2))
      self.stats.unitCycles[tier] = (self.stats.unitCycles[tier] or 0) + 1
    end

    if self.stats.onCycle ~= nil then
      pcall(self.stats.onCycle, running)
    end
  end
end

---Get the progress of the running cycle in ticks, 0 and 0 when the plant isn't running.
---Counted on from the last loop, which reads the plant every few seconds. The next cycle starts in
---the tick the last one ends, so past the end it counts into the next one
---@return integer progress
---@return integer maxProgress
function lineController:getCycleProgress()
  if self.progressReadAt == nil or self.workMaxProgress == 0 then
    return 0, 0
  end

  local progress = self.lastWorkProgress + math.floor((computer.uptime() - self.progressReadAt) * 20)

  return progress % self.workMaxProgress, self.workMaxProgress
end

---Enable line controller, if it is switched off
function lineController:enable()
  if self.controllerProxy ~= nil and self.controllerProxy.isWorkAllowed() == false then
    self.controllerProxy.setWorkAllowed(true)
    event.push("log_info", "[Line] Water Purification Plant switched on")
  end
end

---Disable line controller
function lineController:disable()
  if self.controllerProxy ~= nil then
    self.controllerProxy.setWorkAllowed(false)
  end
end

---Init components
---@private
function lineController:initComponents()
  self.controllerProxy = componentDiscover.gtMachine("multimachine.purificationplant")

  if self.controllerProxy == nil then
    error("[Line] Water Purification Plant not found")
  end
end

return classBuilder.createClass(lineController, lineController.constructor, "LineController")