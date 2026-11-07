local event = require("event")
local term = require("term")
local computer = require("computer")

local classBuilder = require("lib.class-builder.index")
local componentDiscover = require("lib.component-discover.index")

local formatAmount = require("src.format-amount")
local listeners = require("src.listeners")
local discord = require("src.discord")

---Fluids read from the ME network. Index 9 (Stabilised Baryonic Matter) is made by T8
local fluidNames = {
  "grade1purifiedwater",
  "grade2purifiedwater",
  "grade3purifiedwater",
  "grade4purifiedwater",
  "grade5purifiedwater",
  "grade6purifiedwater",
  "grade7purifiedwater",
  "grade8purifiedwater",
  "stablebaryonicmatter",
}

---Seconds between reads of the stock for the screen
local stockReadSeconds = 10

---Get the tier which makes the fluid at an index of fluidNames
---@param index integer
---@return integer
local function tierOf(index)
  return math.min(index, 8)
end

---Get the short name of the fluid at an index of fluidNames, for the log
---@param index integer
---@return string
local function fluidLabel(index)
  return index == 9 and "BM" or "G"..index
end

---@alias QuantityControlMode "disabled"|"multiThread"|"singleThread"|"singleThreadBalancing"

---@class QuantityController
---@field controlMode QuantityControlMode
---@field meInterfaceAddress string
---@field minQty number
---@field floorQty number
---@field waterThresholds number[] 0 is no cap
---@field controllers ControllersConfig
---@field meInterfaceProxy me_interface
---@field waterLevels number[]
---@field waterLevelsReadAt number
---@field isFluidLookupBroken boolean
---@field isTierActive boolean[]
---@field lastDecision string|nil
---@field isAttentionLogged boolean[]
---@field missedStarts integer[]
---@field isDecisionLate boolean
local quantityController = {}

---Constructor
---@param controlMode QuantityControlMode
---@param meInterfaceAddress string
---@param minQty number
---@param waterThresholds number[] 0 is no cap
---@param floorQty? number
---@return QuantityController
function quantityController:constructor(controlMode, meInterfaceAddress, minQty, waterThresholds, floorQty)
  self.controlMode = controlMode
  self.meInterfaceAddress = meInterfaceAddress
  self.minQty = minQty
  self.floorQty = floorQty or 0
  self.waterThresholds = waterThresholds

  self.waterLevels = {0, 0, 0, 0, 0, 0, 0, 0, 0}
  self.waterLevelsReadAt = 0
  self.isFluidLookupBroken = false
  self.isTierActive = {false, false, false, false, false, false, false, false}
  self.lastDecision = nil
  self.isAttentionLogged = {}
  self.missedStarts = {}
  self.isDecisionLate = false

  return self
end

---Init
---@param controllers ControllersConfig
function quantityController:init(controllers)
  self.controllers = controllers

  if self.controlMode == "disabled" then
    return
  end

  term.write("Init Quantity Controller: ")
  self.meInterfaceProxy = componentDiscover.proxy(self.meInterfaceAddress, "me_interface", "[QC] ME Interface")
  self:checkSettings()

  listeners.listen("cycle_pre_end", function (_, isLate)
    if isLate == true then
      event.push("log_debug", "[QC] Cycle end seen late, the units chosen now start one cycle later")
    end

    self.isDecisionLate = isLate == true

    self:updateWaterLevels()
    self:updateControllerEnablement()
  end)

  listeners.listen("cycle_end", function (_, isNextCycleRunning)
    -- When the plant stopped, no unit could start
    if isNextCycleRunning == true then
      self:checkChosenStarted()
    end
  end)

  -- Enable the right units now, so the next cycle doesn't start every unit that was left on
  self:updateWaterLevels()
  self:updateControllerEnablement()
  term.write("ok\n")
end

---Loop
function quantityController:loop()
  self:checkAttentionStates()

  if self.controlMode == "disabled" then
    return
  end

  -- Only the screen uses these; the choice before each cycle end reads them fresh
  if computer.uptime() - self.waterLevelsReadAt >= stockReadSeconds then
    self:updateWaterLevels()
  end
end

---Log units that need attention after a fault, and let units that were switched on by hand be used again
---@private
function quantityController:checkAttentionStates()
  for tier = 1, 8 do
    local controller = self.controllers["t"..tier]

    if controller ~= nil and controller:checkAttentionCleared() then
      event.push("log_info", "[T"..tier.."] Switched on by hand, back in use")
      self.isAttentionLogged[tier] = false
      discord.clear("attention:T"..tier, "needsAttention", "T"..tier.." is back in use", "Switched on by hand.")

      -- The Quantity Controller decides when it runs again, so it doesn't start next to the unit it chose
      if self.controlMode ~= "disabled" then
        controller:setEnabled(self.isTierActive[tier])
      end
    elseif controller ~= nil and controller.needsAttention == true and self.isAttentionLogged[tier] ~= true then
      event.push("log_warning", "[T"..tier.."] Needs attention, switch it on when fixed")
      self.isAttentionLogged[tier] = true

      local reason = controller.attentionReason ~= "" and (controller.attentionReason..". ") or ""
      discord.alert("attention:T"..tier, "needsAttention", "T"..tier.." needs attention",
        reason.."Switch it on by hand when it is fixed.", "T"..tier.." still needs attention")
    end
  end
end

---Check that the units chosen for the cycle that just started run. GregTech doesn't start a unit
---that misses an input, which the program can't see otherwise
---@private
function quantityController:checkChosenStarted()
  -- A late choice is for the next cycle, not this one
  if self.isDecisionLate then
    self.isDecisionLate = false
    return
  end

  for tier = 1, 8 do
    local controller = self.controllers["t"..tier]

    if controller ~= nil and self.isTierActive[tier] and controller.needsAttention ~= true then
      if controller.controllerProxy.hasWork() == true then
        if (self.missedStarts[tier] or 0) >= 2 then
          event.push("log_info", "[T"..tier.."] Started again")
        end

        self.missedStarts[tier] = 0
        discord.clear("didNotStart:T"..tier, "unitDidNotStart", "T"..tier.." starts again", "")
      else
        self.missedStarts[tier] = (self.missedStarts[tier] or 0) + 1

        if self.missedStarts[tier] == 2 then
          event.push("log_warning", "[T"..tier.."] Chosen twice, didn't start: check inputs")
          discord.alert("didNotStart:T"..tier, "unitDidNotStart", "T"..tier.." didn't start",
            "It was chosen for 2 cycles in a row, but GregTech didn't start it. Check its inputs (water, Ozone, catalysts).",
            "T"..tier.." still doesn't start")
        end
      end
    elseif not self.isTierActive[tier] then
      -- Only cycles in a row count, and a unit that isn't chosen any more isn't reported
      self.missedStarts[tier] = 0
      discord.forget("didNotStart:T"..tier)
    end
  end
end

---Get current control mode
---@return string
function quantityController:getCurrentState()
  return self.controlMode
end

---Check if the tier has a working controller the Quantity Controller may enable
---@param tier integer
---@return boolean
---@private
function quantityController:isTierUsable(tier)
  local controller = self.controllers["t"..tier]

  return controller ~= nil and controller.needsAttention ~= true
end

---Check if the fluid at an index of fluidNames has a threshold. Without one it keeps being made
---@param index integer
---@return boolean
function quantityController:isCapped(index)
  return self.waterThresholds[index] > 0
end

---Check if the fluid at an index of fluidNames is below its threshold
---@param index integer
---@return boolean
---@private
function quantityController:isBelowThreshold(index)
  return self:isCapped(index) == false or self.waterLevels[index] < self.waterThresholds[index]
end

---Check if the unit which makes the fluid at an index of fluidNames may run for it
---@param index integer
---@return boolean
---@private
function quantityController:isCandidate(index)
  return self:isTierUsable(tierOf(index)) and self:isBelowThreshold(index)
end

---Find the lowest tier whose fluid is under an amount
---@param amount number
---@return integer|nil index
---@private
function quantityController:findLowestUnder(amount)
  if amount <= 0 then
    return nil
  end

  for index = 1, 9 do
    if self:isCandidate(index) and self.waterLevels[index] < amount then
      return index
    end
  end

  return nil
end

---Warn about settings that can never take effect
---@private
function quantityController:checkSettings()
  if self.controlMode == "singleThreadBalancing" then
    if self.floorQty > 0 and self.floorQty > self.minQty then
      event.push("log_warning", "[QC] floorQty "..formatAmount(self.floorQty).." is above minQty "..formatAmount(self.minQty))
    end

    for index = 1, 9 do
      local threshold = self.waterThresholds[index]

      if self.controllers["t"..tierOf(index)] ~= nil and self:isCapped(index) then
        if threshold < self.floorQty then
          event.push("log_warning", "[QC] "..fluidLabel(index).." Want "..formatAmount(threshold).." is under floor "..formatAmount(self.floorQty))
        elseif threshold < self.minQty then
          event.push("log_warning", "[QC] "..fluidLabel(index).." Want "..formatAmount(threshold).." is under min "..formatAmount(self.minQty))
        end
      end
    end
  elseif self.controlMode == "singleThread" then
    -- The lowest tier without a cap always wins, so no tier above it runs
    for index = 1, 8 do
      if self.controllers["t"..index] ~= nil and self:isCapped(index) == false then
        for tier = index + 1, 8 do
          if self.controllers["t"..tier] ~= nil then
            event.push("log_warning", "[QC] "..fluidLabel(index).." has no cap: T"..tier.." and up never run")
            return
          end
        end

        return
      end
    end
  end
end

---Choose which tiers run in the next cycle and enable only those
function quantityController:updateControllerEnablement()
  if self.controlMode == "disabled" then
    return
  end

  local isTierActive = {false, false, false, false, false, false, false, false}
  local reason = nil

  if self.controlMode == "multiThread" then
    -- Every tier below its threshold runs
    for tier = 1, 8 do
      if self:isTierUsable(tier) then
        isTierActive[tier] = self:isBelowThreshold(tier) or (tier == 8 and self:isBelowThreshold(9))
      end
    end
  elseif self.controlMode == "singleThread" then
    -- The lowest tier below its threshold runs
    for index = 1, 9 do
      if self:isCandidate(index) then
        isTierActive[tierOf(index)] = true
        reason = self:describeLevel(index, self:isCapped(index) and "under "..formatAmount(self.waterThresholds[index]) or "no cap")
        break
      end
    end
  elseif self.controlMode == "singleThreadBalancing" then
    -- 1. A water under floorQty: the lowest tier runs, so every water gets a stock, bottom up
    -- 2. A water under minQty: the lowest tier runs
    -- 3. Otherwise the water with the least stock (below its threshold) runs, lower tiers win ties
    local winner = self:findLowestUnder(self.floorQty)
    local why = "under floor "..formatAmount(self.floorQty)

    if winner == nil then
      winner = self:findLowestUnder(self.minQty)
      why = "under min "..formatAmount(self.minQty)
    end

    if winner == nil then
      local candidateCount = 0

      for index = 1, 9 do
        if self:isCandidate(index) then
          candidateCount = candidateCount + 1

          if winner == nil or self.waterLevels[index] < self.waterLevels[winner] then
            winner = index
          end
        end
      end

      if winner ~= nil and candidateCount == 1 and self:isCapped(winner) then
        why = "under "..formatAmount(self.waterThresholds[winner])
      else
        why = "lowest stock"
      end
    end

    if winner ~= nil then
      isTierActive[tierOf(winner)] = true
      reason = self:describeLevel(winner, why)
    end
  end

  self.isTierActive = isTierActive
  self.lastReason = reason
  self:logDecision(isTierActive, reason)

  -- Disable every unit before enabling any, so two units never start in the same cycle
  for tier = 1, 8 do
    if self.controllers["t"..tier] ~= nil then
      self.controllers["t"..tier]:setEnabled(false)
    end
  end

  for tier = 1, 8 do
    if self.controllers["t"..tier] ~= nil and isTierActive[tier] then
      self.controllers["t"..tier]:setEnabled(true)
    end
  end
end

---Describe the stock of the fluid at an index of fluidNames, e.g. "G2 7.3M, lowest stock"
---@param index integer
---@param why string
---@return string
---@private
function quantityController:describeLevel(index, why)
  return fluidLabel(index).." "..formatAmount(self.waterLevels[index])..", "..why
end

---Log the units chosen for the next cycle, when they differ from the last choice
---@param isTierActive boolean[]
---@param reason string|nil
---@private
function quantityController:logDecision(isTierActive, reason)
  local tiers = {}

  for tier = 1, 8 do
    if isTierActive[tier] then
      table.insert(tiers, "T"..tier)
    end
  end

  local decision = table.concat(tiers, " ")

  if decision == self.lastDecision then
    return
  end

  self.lastDecision = decision

  if decision == "" then
    event.push("log_info", "[QC] Next cycle: none, "..(self:isNeedBlockedByAttention() and "units need attention" or "all units at threshold"))
  elseif reason ~= nil then
    event.push("log_info", "[QC] Next cycle: "..decision.." ("..reason..")")
  else
    event.push("log_info", "[QC] Next cycle: "..decision)
  end
end

---Check if a fluid is below its threshold, but the unit which makes it needs attention
---@return boolean
---@private
function quantityController:isNeedBlockedByAttention()
  for index = 1, 9 do
    local controller = self.controllers["t"..tierOf(index)]

    if controller ~= nil and controller.needsAttention == true and self:isBelowThreshold(index) then
      return true
    end
  end

  return false
end

---Read the amount of each water grade and Stabilised Baryonic Matter in the ME network
---@private
function quantityController:updateWaterLevels()
  local waterLevels = {0, 0, 0, 0, 0, 0, 0, 0, 0}
  local proxy = self.meInterfaceProxy

  -- Looking up the 9 fluids costs the server far less than the list of every fluid in the network (GTNH 2.9)
  if proxy.getFluidInNetwork ~= nil and self.isFluidLookupBroken ~= true then
    for index, fluidName in ipairs(fluidNames) do
      local isOk, fluid = pcall(proxy.getFluidInNetwork, fluidName)

      if not isOk then
        event.push("log_debug", "[QC] Looking up one fluid failed, reading the whole list instead: "..tostring(fluid))
        self.isFluidLookupBroken = true
        return self:updateWaterLevels()
      end

      waterLevels[index] = type(fluid) == "table" and (fluid.amount or fluid.size) or 0
    end
  else
    local fluids = proxy.getFluidsInNetwork() or {}

    for _, fluid in ipairs(fluids) do
      for index, fluidName in ipairs(fluidNames) do
        if fluid.name == fluidName then
          waterLevels[index] = fluid.amount or 0
        end
      end
    end
  end

  self.waterLevels = waterLevels
  self.waterLevelsReadAt = computer.uptime()
end

return classBuilder.createClass(quantityController, quantityController.constructor, "QuantityController")
