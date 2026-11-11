-- T4 brings the pH to 7 step by step: reads it, adds Sodium Hydroxide or Hydrochloric Acid, reads again
local oc = require("testkit.oc")
local t = require("testkit.test")
oc.install()

local logs = {}
require("event").listen("log_warning", function (_, text) logs[#logs + 1] = text end)

local previous = {}

local function setup(ph, acid, dust)
  for _, address in ipairs(previous) do oc.removeComponent(address) end
  local unit = {ph = ph, bus = 0, hatch = 0}
  local machine = {work = true, sensor = {}}

  local function sensor()
    machine.sensor = {
      "GT5U.infodata.purification_unit_base.linked_at\\\\1\\\\2\\\\3",
      "GT5U.infodata.purification_unit_base.success_chance\\\\§e0%",
      "GT5U.infodata.parallel.current\\\\§e1",
      "GT5U.infodata.purification_unit_ph_adjustment.ph\\\\§e"..string.format("%.2f", unit.ph),
    }
  end
  sensor()

  -- acid: tank on the east (5), input hatch below (0)
  local acidTank = {name = "hydrochloricacid_gt5u", amount = acid, capacity = 64000}
  local acidAddress
  acidAddress = oc.addComponent("transposer", {
    getTankCount = function (side) return (side == 5 or side == 0) and 1 or nil end,
    getFluidInTank = function (side)
      if side == 5 then return acidTank.amount > 0 and {name = acidTank.name, amount = acidTank.amount, capacity = 64000} or {capacity = 64000} end
      return {capacity = 32000}
    end,
    transferFluid = function (from, to, amount)
      local moved = math.min(amount, acidTank.amount)
      acidTank.amount = acidTank.amount - moved
      unit.hatch = unit.hatch + moved
      return true, moved
    end,
  })

  -- dust: an ME interface on the east keeps 64 in its slot, the input bus is below
  local interface = {size = math.min(64, dust), left = dust}
  local dustAddress = oc.addComponent("transposer", {
    getInventorySize = function (side) return (side == 5 or side == 0) and 9 or nil end,
    getAllStacks = function (side)
      local all = {}
      if side == 5 and interface.size > 0 then all[0] = {name = "gregtech:gt.metaitem.01", label = "Sodium Hydroxide Dust", size = interface.size} end
      return {getAll = function () return all end}
    end,
    getStackInSlot = function () return nil end,
    transferItem = function (from, to, count)
      local moved = math.min(count, interface.size)
      interface.size, interface.left = interface.size - moved, interface.left - moved
      unit.bus = unit.bus + moved
      return moved
    end,
  })

  local machineAddress = oc.gtMachine("multimachine.purificationunitphadjustment", machine)
  previous = {acidAddress, dustAddress, machineAddress}

  local world = {unit = unit, acid = acidTank, interface = interface}
  world.tick = function ()
    -- the unit uses up its bus and hatch; the interface refills its slot from the ME
    unit.ph = unit.ph + unit.bus * 0.01 - math.floor(unit.hatch / 10) * 0.01
    unit.bus, unit.hatch = 0, unit.hatch % 10
    interface.size = math.min(64, interface.left)
    sensor()
  end

  local controller = require("src.t4-controller"):new(acidAddress, dustAddress)
  controller:init()
  return controller, world
end

local function run(controller, world, seconds)
  for _ = 1, seconds do
    controller:loop()
    world.tick()
    oc.advance(1)
  end
end

t.test("pH 9.37: acid brings it to 7 within 0.05", function ()
  local controller, world = setup(9.37, 64000, 64)
  run(controller, world, 15)
  t.truthy(math.abs(world.unit.ph - 7) <= 0.05, "pH "..world.unit.ph)
  t.equal(controller.stateMachine:getCurrentStateKey(), "waitEnd")
end)

t.test("pH 4.60: 240 dust in parts of 64 from an ME interface slot", function ()
  local controller, world = setup(4.60, 1000, 10000)
  run(controller, world, 30)
  t.truthy(math.abs(world.unit.ph - 7) <= 0.05, "pH "..world.unit.ph)
  t.equal(controller.stateMachine:getCurrentStateKey(), "waitEnd")
end)

t.test("no dust left: needs attention", function ()
  local controller, world = setup(5.00, 1000, 30)
  run(controller, world, 15)
  t.truthy(controller.needsAttention)
  t.contains(logs[#logs], "Not enough Sodium Hydroxide")
end)

return t.finish()
