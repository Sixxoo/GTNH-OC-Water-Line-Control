local sides = require("sides")
local event = require("event")
local term = require("term")

local classBuilder = require("lib.class-builder.index")
local componentDiscover = require("lib.component-discover.index")
local stateMachineBuilder = require("lib.state-machine-builder.index")
local gtSensorParser = require("lib.gt-sensor-parser.index")

local baseController = require("src.base-controller")
local listeners = require("src.listeners")

---@class T3Controller: BaseController
---@field stateMachine StateMachine
---@field transposerAddress string
---@field requiredCount integer
---@field controllerProxy gt_machine
---@field transposerProxy transposer
---@field gtSensorParser GtSensorParser
---@field transposerLiquids table<string, TransposerFluidStorageDescriptor>
local t3controller = {}

---Constructor
---@param transposerAddress string
---@param hatchSide? string|integer Side of the transposer with the unit's input hatch: "up" (default), "down", ... or 0-5
---@return T3Controller
function t3controller:constructor(transposerAddress, hatchSide)
  self.transposerAddress = transposerAddress
  if type(hatchSide) == "number" then
    self.hatchSide = hatchSide
  else
    self.hatchSide = sides[tostring(hatchSide or "up"):lower()] or sides.up
  end

  self.requiredCount = 900000

  self.transposerLiquids = {}

  self.stateMachine = stateMachineBuilder.stateMachine:new()

  return self
end

---Init
function t3controller:init()
  term.write("Init T3 components: ")
  self:initComponents()
  term.write("ok\n")

  term.write("Init T3 state machine: ")
  self:initStateMachine()
  term.write("ok\n")
end

---Loop
function t3controller:loop()
  self:readState()
  self.stateMachine:loop()
end

---Get current state
---@return string
function t3controller:getCurrentState()
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

  -- While the unit runs, sensor line 2 is its success chance (when idle it is the parallel count)
  local successChance = self.gtSensorParser:getNumber(2)

  if successChance == nil then
    successChance = 0
  end

  return "State: ["..self.stateMachine:getCurrentStateName().."] Success: ["..successChance.."%]"
end

---Init components
---@private
function t3controller:initComponents()
  self.controllerProxy = componentDiscover.gtMachine("multimachine.purificationunitflocculator")

  if self.controllerProxy == nil then
    error("[T3] Flocculation Purification Unit not found")
  end

  self.transposerProxy = componentDiscover.proxy(self.transposerAddress, "transposer", "[T3] Transposer")
  self.gtSensorParser = gtSensorParser.parser:new(self.controllerProxy)

  self:findTransposerFluid(self.transposerProxy, {"polyaluminiumchloride"})
end

---Init state machine
---@private
function t3controller:initStateMachine()
  self.stateMachine:createState("idle", "Idle", {
    onUpdate = function ()
      if self.isWorking == true then
        self.stateMachine:setState("work")
      end
    end
  })

  -- The unit uses up all PAC in its hatch every second while it runs, and gives +10% success per full
  -- 100,000 L used in the cycle; any amount over a full 100,000 L cuts the success hard. So the
  -- program delivers exactly 900,000 L, in parts that fit the hatch (a LuV hatch holds 512,000 L),
  -- each part rounded down to 100,000 L
  self.stateMachine:createState("work", "Work", {
    onInit = function ()
      self.delivered = 0
      self.target = self.requiredCount
    end,
    onUpdate = function ()
      self:deliverPac()
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

---Move the next part of the 900,000 L PAC into the hatch; done when all of it is in
---@private
function t3controller:deliverPac()
  local remaining = self.target - self.delivered

  if remaining <= 0 then
    self.stateMachine:setState("waitEnd")
    return
  end

  local pac = self.transposerLiquids["polyaluminiumchloride"]
  local source = self.transposerProxy.getFluidInTank(pac.side, pac.tank)
  local available = type(source) == "table" and source.amount or 0

  -- Free room in the hatch; the unit empties it every second
  local hatch = self.transposerProxy.getFluidInTank(self.hatchSide, 1)
  local capacity = type(hatch) == "table" and hatch.capacity or self.requiredCount
  local free = capacity - (type(hatch) == "table" and hatch.amount or 0)

  if available < remaining then
    if self.delivered == 0 then
      self:markNeedsAttention("Not enough Polyaluminium Chloride for craft")
      event.push("log_warning", "[T3] Not enough Polyaluminium Chloride for craft ("..
        math.floor(available / 1000).."k of "..math.floor(remaining / 1000).."k)")
    end

    -- Only full 100,000 L parts: what is over a full part cuts the success
    remaining = math.min(remaining, available - (available + self.delivered) % 100000)

    if remaining <= 0 then
      self.stateMachine:setState("waitEnd")
      return
    end

    self.target = self.delivered + remaining
  end

  local part = math.min(remaining, free)

  if part < remaining then
    part = part - part % 100000
  end

  if part <= 0 then
    return   -- the hatch is still full, the unit empties it within a second
  end

  local _, moved = self.transposerProxy.transferFluid(pac.side, self.hatchSide, part, pac.tank)
  moved = tonumber(moved) or 0
  self.delivered = self.delivered + moved

  if moved == 0 then
    event.push("log_warning", "[T3] Can't move Polyaluminium Chloride into the hatch")
    self.stateMachine:setState("waitEnd")
  elseif moved < part then
    -- A slow transposer moves less per call; the next parts make up for it
    event.push("log_debug", "[T3] Moved "..math.floor(moved / 1000).."k of "..math.floor(part / 1000).."k PAC")
  end

  if self.delivered >= self.target then
    self.stateMachine:setState("waitEnd")
  end
end

---Find side of transposer with fluid
---@param proxy transposer
---@param fluidNames string[]
---@private
function t3controller:findTransposerFluid(proxy, fluidNames)
  local result, skipped = componentDiscover.transposerFluidStoragesByNames(proxy, fluidNames, {self.hatchSide})

  if #skipped ~= 0 then
    error("[T3] Can't find liquid: "..table.concat(skipped, ", "))
  end

  for key, value in pairs(result) do
    self.transposerLiquids[key] = value
  end
end

return classBuilder.createClass(t3controller, t3controller.constructor, "T3Controller", baseController)