local sides = require("sides")
local event = require("event")
local computer = require("computer")
local term = require("term")

local classBuilder = require("lib.class-builder.index")
local componentDiscover = require("lib.component-discover.index")
local stateMachineBuilder = require("lib.state-machine-builder.index")
local gtSensorParser = require("lib.gt-sensor-parser.index")

local baseController = require("src.base-controller")
local listeners = require("src.listeners")

---@class T4Controller: BaseController
---@field stateMachine StateMachine
---@field hydrochloricAcidTransposerAddress string
---@field sodiumHydroxideTransposerAddress string
---@field controllerProxy gt_machine
---@field hydrochloricAcidTransposerProxy transposer
---@field sodiumHydroxideTransposerProxy transposer
---@field gtSensorParser GtSensorParser
---@field transposerLiquids table<string, TransposerFluidStorageDescriptor>
---@field transposerItems table<string, TransposerItemStorageDescriptor>
local t4controller = {}

---Constructor
---@param hydrochloricAcidTransposerAddress string
---@param sodiumHydroxideTransposerAddress string
---@return T4Controller
function t4controller:constructor(hydrochloricAcidTransposerAddress, sodiumHydroxideTransposerAddress)
  self.hydrochloricAcidTransposerAddress = hydrochloricAcidTransposerAddress
  self.sodiumHydroxideTransposerAddress = sodiumHydroxideTransposerAddress

  self.transposerLiquids = {}
  self.transposerItems = {}

  self.stateMachine = stateMachineBuilder.stateMachine:new()

  return self
end

---Init
function t4controller:init()
  term.write("Init T4 components: ")
  self:initComponents()
  term.write("ok\n")

  term.write("Init T4 state machine: ")
  self:initStateMachine()
  term.write("ok\n")
end

---Loop
function t4controller:loop()
  self:readState()
  self.stateMachine:loop()
end

---Get current state
---@return string
function t4controller:getCurrentState()
  if self.needsAttention == true then
    return "Needs attention"
  end

  -- A unit that may no longer work still finishes the cycle it is running
  if self.isWorking == false then
    if self.controllerProxy.isWorkAllowed() == false then
      return "Controller disabled"
    end

    return "Wait cycle"
  end

  local successChance = self.gtSensorParser:getNumber(2)

  if successChance == nil then
    successChance = 0
  end

  return "State: ["..self.stateMachine:getCurrentStateName().."] Success: ["..successChance.."%]"
end

---Init components
---@private
function t4controller:initComponents()
  self.controllerProxy = componentDiscover.gtMachine("multimachine.purificationunitphadjustment")

  if self.controllerProxy == nil then
    error("[T4] pH Neutralization Purification Unit not found")
  end

  self.hydrochloricAcidTransposerProxy = componentDiscover.proxy(
    self.hydrochloricAcidTransposerAddress,
    "transposer",
    "[T4] Hydrochloric Acid Transposer"
  )

  self.sodiumHydroxideTransposerProxy = componentDiscover.proxy(
    self.sodiumHydroxideTransposerAddress,
    "transposer",
    "[T4] Sodium Hydroxide Transposer"
  )

  self.gtSensorParser = gtSensorParser.parser:new(self.controllerProxy)

  self:findTransposerFluid(self.hydrochloricAcidTransposerProxy, {"hydrochloricacid_gt5u"})
  self:findTransposerItem(self.sodiumHydroxideTransposerProxy, {"Sodium Hydroxide Dust"})

  self.gtSensorParser:getInformation()
end

---Init state machine
---@private
function t4controller:initStateMachine()
  self.stateMachine:createState("idle", "Idle", {
    onUpdate = function ()
      if self.isWorking == true then
        self.stateMachine:setState("work")
      end
    end
  })

  -- The unit starts each cycle at a random pH between 4.5 and 9.5 and succeeds at 7.00 +- 0.05.
  -- Every second it uses up what is in its input bus and hatch: each Sodium Hydroxide Dust raises the pH
  -- by 0.01, each 10 L of Hydrochloric Acid lowers it by 0.01. The program reads the pH, adds what
  -- brings it to 7, waits until the unit used it up and reads again, until the pH is within 0.02
  self.stateMachine:createState("work", "Work", {
    onInit = function ()
      self.waitUntil = 0
      self.doses = 0
    end,
    onUpdate = function ()
      if computer.uptime() < self.waitUntil then
        return
      end

      local phValue = self.gtSensorParser:getNumber(4)

      if phValue == nil then
        return
      end

      local diffPh = 7 - phValue
      local count = math.floor(math.abs(diffPh) / 0.01 + 0.5)

      if math.abs(diffPh) <= 0.02 or count == 0 then
        event.push("log_debug", "[T4] pH "..phValue.." after "..self.doses.." doses")
        self.stateMachine:setState("waitEnd")
        return
      end

      local added

      if diffPh > 0 then
        added = self:putSodiumHydroxide(count)
      else
        added = self:putHydrochloricAcid(count)
      end

      if added == false then
        self.stateMachine:setState("waitEnd")
        return
      end

      self.doses = self.doses + 1
      self.waitUntil = computer.uptime() + 2   -- the unit takes it in within a second; then read again
    end
  })

  self.stateMachine:createState("waitEnd", "Wait End")

  listeners.listen("cycle_end", function ()
    if self.stateMachine:getCurrentStateKey() == "waitEnd" then
      self.stateMachine:setState("idle")
    end
  end)

  self.stateMachine:setState("idle")
end

---Find side of transposer with fluid
---@param proxy transposer
---@param fluidNames string[]
---@private
function t4controller:findTransposerFluid(proxy, fluidNames)
  local result, skipped = componentDiscover.transposerFluidStoragesByNames(proxy, fluidNames, {sides.up, sides.bottom})

  if #skipped ~= 0 then
    error("[T4] Can't find liquid: "..table.concat(skipped, ", "))
  end

  for key, value in pairs(result) do
    self.transposerLiquids[key] = value
  end
end

---Find side of transposer with item
---@param proxy transposer
---@param itemLabels string[]
---@private
function t4controller:findTransposerItem(proxy, itemLabels)
  local result, skipped = componentDiscover.transposerItemStoragesByLabels(proxy, itemLabels, {sides.up, sides.bottom})

  if #skipped ~= 0 then
    error("[T4] Can't find items: "..table.concat(skipped, ", "))
  end

  for key, value in pairs(result) do
    self.transposerItems[key] = value
  end
end

---Put Sodium Hydroxide Dust into the input bus, at most 64 at a time (an ME interface slot refills
---between doses). Returns false when there is none
---@param count integer
---@return boolean|integer
---@private
function t4controller:putSodiumHydroxide(count)
  local moved = self.sodiumHydroxideTransposerProxy.transferItem(
    self.transposerItems["Sodium Hydroxide Dust"].side,
    sides.bottom,
    math.min(64, count)
  )

  moved = tonumber(moved) or 0

  if moved == 0 then
    self:markNeedsAttention("Not enough Sodium Hydroxide for craft")
    event.push("log_warning", "[T4] Not enough Sodium Hydroxide for craft")
    return false
  end

  return moved
end

---Put Hydrochloric Acid into the input hatch (10 L per 0.01 pH). Returns false when there is none
---@param count integer
---@return boolean|integer
---@private
function t4controller:putHydrochloricAcid(count)
  local _, moved = self.hydrochloricAcidTransposerProxy.transferFluid(
    self.transposerLiquids["hydrochloricacid_gt5u"].side,
    sides.bottom,
    count * 10,
    self.transposerLiquids["hydrochloricacid_gt5u"].tank
  )

  moved = tonumber(moved) or 0

  if moved == 0 then
    self:markNeedsAttention("Not enough Hydrochloric Acid for craft")
    event.push("log_warning", "[T4] Not enough Hydrochloric Acid for craft")
    return false
  end

  return moved
end

return classBuilder.createClass(t4controller, t4controller.constructor, "T4Controller", baseController)