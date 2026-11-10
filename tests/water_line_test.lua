-- Water Line Control in a fake OpenOS. Run from the addons repo:
--   python3 testkit/run.py --root <this repo>
local oc = require("testkit.oc")
local t = require("testkit.test")
oc.install()

local function read(path)
  local file = io.open(path, "r")
  if file == nil then return nil end
  local text = file:read("*a") file:close() return text
end

-- Sixxo's setup: plant, T1, T2, T3 (PAC above the transposer, hatch below), the ME interface with the waters
local gpu, display = oc.addScreen(160, 50, {5, 3})
local _, plant = oc.gtMachine("multimachine.purificationplant", {work = true, progress = 200, maxProgress = 2400})
oc.gtMachine("multimachine.purificationunitclarifier", {work = true, progress = 200, maxProgress = 2400,
  sensor = {"Status: Work", "Success chance: 100%"}})
oc.gtMachine("multimachine.purificationunitozonation", {work = false})
oc.gtMachine("multimachine.purificationunitflocculator", {work = false, sensor = {"a", "b", "c", "0"}})
oc.transposer({[0] = {{capacity = 2000000}}, [1] = {{name = "polyaluminiumchloride", amount = 4000000}}}, nil,
  "5dcf2167-a9de-4f5a-8727-8287e7e4d98e")
oc.meInterface({grade1purifiedwater = 33600000, grade2purifiedwater = 87200, grade3purifiedwater = 0}, nil,
  "0604d547-0b75-4990-bd55-4ac86f1df51d")

local cfg = require("addons.core").load("config")

t.test("config.lua of this version passes the schema", function ()
  local schema = require("src.schema")
  local config, problems = cfg.check(cfg.read("config.lua"), schema.config)
  t.equal(#problems, 0, table.concat(problems, "; "))
  t.equal(config.controllers.t3.hatchSide, 0, "down")
end)

t.test("a 2.1.7 config.lua is merged into this version's, and passes", function ()
  local merged, report = cfg.merge(read("tests/config-2.1.7.lua"), read("config.lua"), cfg.read("program.lua").configRules)
  t.truthy(merged ~= nil, tostring(report))
  t.contains(merged, 'transposerAddress = "5dcf2167-a9de-4f5a-8727-8287e7e4d98e"')
  t.contains(table.concat(report.removed, " "), "logger", "the old logger settings are left out")

  local value = load(merged, "=merged", "t", {})()
  local _, problems = cfg.check(value, require("src.schema").config)
  t.equal(#problems, 0, table.concat(problems, "; "))
end)

t.test("the program runs, draws its screen and stops with Q, switching the plant off", function ()
  local event = require("event")
  local keys = require("keyboard").keys

  -- A day of history in stats.dat, as earlier runs would leave it
  os.remove("stats.dat")
  local seed = require("addons.core").load("stats", {filePath = "stats.dat"})
  seed.start()
  local pattern = {3, 4, 2, 5, 3, 0, 1, 4, 5, 3, 2, 4, 3, 5, 4, 2, 3, 4, 5, 3, 4, 2, 3, 1}
  for hour = 1, 24 do
    for _ = 1, pattern[hour] do
      seed.add("cycles")
      seed.add(hour % 3 == 0 and "cycles.t3" or "cycles.t2")
      if hour % 4 == 0 then seed.add("cycles.t1") end
    end
    seed.record("water.t1", 30000000 + hour * 70000)
    seed.record("water.t2", 200000 + hour * 30000)
    seed.record("water.t3", 900000 - hour * 30000)
    oc.advance(3600)
  end
  seed.stop()

  local snapshot, statsPage, logPage = nil, nil, nil
  event.timer(60, function () snapshot = display.lines() end)
  event.timer(61, function () event.push("key_down", "keyboard", 0, keys.right) end)
  event.timer(63, function () statsPage = display.lines() end)
  event.timer(64, function () event.push("key_down", "keyboard", string.byte("3"), 4) end)
  event.timer(66, function () logPage = display.lines() end)
  event.timer(67, function () event.push("key_down", "keyboard", string.byte("1"), 2) end)
  event.timer(68, function ()
    event.push("key_down", "keyboard", string.byte("q"), 16)
    event.push("key_up", "keyboard", string.byte("q"), 16)
  end)

  local main = assert(loadfile("main.lua"))
  main()

  t.truthy(snapshot ~= nil, "screen drawn")
  t.snapshot("main", snapshot)
  local text = table.concat((function ()
    local rows = {}
    for y, line in ipairs(snapshot) do rows[y] = line:gsub("&&?0x%x+;", "") end
    return rows
  end)(), "\n")
  t.contains(text, "WATER LINE CONTROL")
  t.contains(text, "T3 FLOCCULATION")
  t.contains(text, "PURIFICATION UNITS")
  t.equal(plant.allowed, false, "plant switched off")
  t.equal(#oc.log, 0, "no errors in listeners: "..table.concat(oc.log, "; "))
  t.contains(read("logs.log") or "", "Program started")

  t.snapshot("stats", statsPage)
  t.snapshot("log", logPage)
  local statsText = table.concat(statsPage, "\n"):gsub("&&?0x%x+;", "")
  t.contains(statsText, "CYCLES PER HOUR")
  t.contains(statsText, "All time")
  t.contains(table.concat(logPage, "\n"):gsub("&&?0x%x+;", ""), "EVENT LOG")
  os.remove("stats.dat")
end)

t.test("a mistake in config.lua: error screen with a countdown, Q stops", function ()
  local event = require("event")
  local good = read("config.lua")
  local file = io.open("config.lua", "w")
  file:write((good:gsub('controlMode = "singleThreadBalancing"', 'controlMode = "fast"')))
  file:close()

  local snapshot = nil
  event.timer(5, function () snapshot = display.lines() end)
  event.timer(6, function () event.push("key_down", "keyboard", string.byte("q"), 16) end)

  local isOk, problem = pcall(assert(loadfile("main.lua")))
  file = io.open("config.lua", "w") file:write(good) file:close()
  t.truthy(isOk, tostring(problem))

  t.snapshot("error", snapshot)
  local text = table.concat(snapshot, "\n"):gsub("&&?0x%x+;", "")
  t.contains(text, "THE PROGRAM HAD AN ERROR")
  t.contains(text, 'quantityController.controlMode: is "fast"')
  t.contains(text, "Starting again in")
end)

t.test("a component gone for 20 minutes: plant off after 5, keeps trying, runs again by itself", function ()
  local event = require("event")
  local component = require("component")
  local address = "0604d547-0b75-4990-bd55-4ac86f1df51d"
  local me = component.proxy(address)
  oc.removeComponent(address)

  local began, waitingScreen, safeScreen = oc.now(), nil, nil
  event.timer(60, function () waitingScreen = display.lines() end)
  event.timer(8 * 60, function () safeScreen = display.lines() end)
  event.timer(20 * 60, function () oc.addComponent("me_interface", me, address) end)
  event.timer(23 * 60, function () event.push("key_down", "keyboard", string.byte("q"), 16) end)

  local isOk, problem = pcall(assert(loadfile("main.lua")))
  t.truthy(isOk, tostring(problem))

  local function text(lines) return table.concat(lines, "\n"):gsub("&&?0x%x+;", "") end
  t.snapshot("waiting", waitingScreen)
  t.snapshot("safe", safeScreen)
  t.contains(text(waitingScreen), "me_interface 0604d547) is missing")
  t.contains(text(waitingScreen), "Plant off in")
  t.contains(text(safeScreen), "Plant switched off, trying every minute")
  local logText = read("logs.log") or ""
  t.contains(logText, "Plant switched off after 5 minutes of errors")
  t.contains(logText, "Running again after")
  t.truthy(oc.now() - began >= 23 * 60)
end)

os.remove("logs.log")
return t.finish()
