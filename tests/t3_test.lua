-- T3 doses exactly 900,000 L PAC per cycle in full 100,000 L parts that fit the hatch
local oc = require("testkit.oc")
local t = require("testkit.test")
oc.install()

local component = require("component")
local logs = {}
require("event").listen("log_warning", function (_, text) logs[#logs + 1] = text end)

local function setup(hatchCapacity, pac, rate)
  local tanks = {[0] = {capacity = hatchCapacity, amount = 0}, [1] = {name = "polyaluminiumchloride", amount = pac, capacity = 4000000}}
  local world = {consumed = 0}
  local proxy = {
    getTankCount = function (side) return tanks[side] and 1 or nil end,
    getFluidInTank = function (side)
      local tank = tanks[side]
      if (tank.amount or 0) <= 0 then return {capacity = tank.capacity} end
      return {name = tank.name or "polyaluminiumchloride", amount = tank.amount, capacity = tank.capacity}
    end,
    transferFluid = function (from, to, amount)
      local moved = math.min(amount, tanks[from].amount, tanks[to].capacity - tanks[to].amount, rate or math.huge)
      tanks[from].amount = tanks[from].amount - moved
      tanks[to].amount = tanks[to].amount + moved
      return true, moved
    end,
  }
  -- the unit uses up the whole hatch every second
  world.tick = function () world.consumed = world.consumed + tanks[0].amount tanks[0].amount = 0 end
  local address = oc.addComponent("transposer", proxy)
  local machine = oc.gtMachine("multimachine.purificationunitflocculator", {work = true, sensor = {"a", "b", "c"}})

  local controller = require("src.t3-controller"):new(address, "down")
  controller:init()
  return controller, world, machine
end

local function run(controller, world, seconds)
  for _ = 1, seconds do
    controller:loop()
    world.tick()
  end
end

t.test("LuV hatch (512k): 500k + 400k, exactly 900k", function ()
  local controller, world = setup(512000, 4000000)
  run(controller, world, 5)
  t.equal(world.consumed, 900000)
  t.equal(controller.stateMachine:getCurrentStateKey(), "waitEnd")
end)

t.test("big hatch: 900k at once", function ()
  local controller, world = setup(2048000, 4000000)
  run(controller, world, 2)
  t.equal(world.consumed, 900000)
end)

t.test("slow transposer: parts add up to exactly 900k", function ()
  local controller, world = setup(512000, 4000000, 64000)
  run(controller, world, 30)
  t.equal(world.consumed, 900000)
end)

t.test("not enough PAC: full 100k parts only, needs attention", function ()
  local controller, world = setup(512000, 650000)
  run(controller, world, 5)
  t.equal(world.consumed, 600000)
  t.equal(controller.needsAttention, true)
  t.contains(logs[#logs], "650k of 900k")
end)

return t.finish()
