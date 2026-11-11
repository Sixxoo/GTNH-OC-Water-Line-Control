-- Water Line Control: controls a GTNH Water Purification Plant from OpenComputers.
-- Runs from its folder (/home/water-line), with its addons in addons/.

-- OpenOS keeps loaded libraries until the computer restarts, also after an update: load our own fresh
for name in pairs(package.loaded) do
  if name:match("^lib%.") or name:match("^src%.") or name:match("^addons%.") then
    package.loaded[name] = nil
  end
end

local computer = require("computer")
local event = require("event")
local term = require("term")
local shell = require("shell")
local keyboard = require("keyboard")

local addons = require("addons.core")
local cfg = addons.load("config")
local clock = addons.load("clock")
local screen = addons.load("screen")
local ui = addons.load("neon-ui")
-- With nobody watching (e.g. the machines' chunks unloaded while you are away) the program keeps
-- the plant off after 5 minutes of errors but goes on trying every minute, and runs again by itself
local recovery = addons.load("recovery", {keepTrying = true, keepTryingSeconds = 60})
local wiring = addons.load("wiring-check")
local power = addons.load("power")
local installer = addons.load("installer")
local tabs = addons.load("tabs")
local touch = addons.load("touch")
local windows = addons.load("windows")
local statsData = addons.load("stats")
local log = addons.load("event-log", {
  filePath = "logs.log",
  tagColors = {["[QC]"] = "cyan", ["[Line]"] = "white"},
})

local schema = require("src.schema")
local lineControllerClass = require("src.line-controller")
local discord = require("src.discord")
local neonScreen = require("src.neon-screen")

local configPath = "config.lua"
local program = cfg.read("program.lua") or {name = "Water Line Control", version = "?", id = "water-line"}

---@type table Running config, checked
local config = nil

---What "no such component" usually means here
local function explain(problem)
  problem = tostring(problem)

  if problem:find("no such component") and not problem:find("left the network") then
    problem = problem.."\nA machine, adapter or ME interface left the network: its chunk unloaded (chunk loading),"..
      " a cable broke or an MFU lost its link. The program goes on when it is back."
  end

  return problem
end

---Since when runs keep failing (nil while it works), for the error screen
local failingSince, failingFor = nil, 0
---@type table Controllers t1..t8 of the running config
local controllers = {}
---@type table
local quantityController = nil
---@type table
local lineController = nil
---@type table The values of config.lua the running program was built from
local runningRaw = nil

local logOffset = 0
local controllersStates = {}
local isFirstStart = true
local quitAsked, editAsked = false, false
local isDrawing = true
local isEditing = false   -- keys typed in the editor must not reach the program

---Counted since the program started, kept when it starts again after an error
local stats = {startedAt = computer.uptime(), cycles = 0, unitCycles = {}}

-- Kept across restarts in stats.dat: every cycle and which units ran
stats.onCycle = function (running)
  statsData.add("cycles")

  for _, name in ipairs(running) do
    statsData.add("cycles."..name:lower())
  end
end

---Touch buttons of the screen and pop-up windows over it
local buttons = touch.new()
local popups = windows.new()

---Pages of the screen
local pages = tabs.new({
  {id = "overview", title = "OVERVIEW"},
  {id = "stats", title = "STATISTICS"},
  {id = "log", title = "LOG"},
})

-- ---------- update at start ----------

---Ask about a new version before anything runs. true when it was installed (the program ends then)
local function checkUpdate()
  local raw = cfg.read(configPath)

  if type(raw) == "table" and raw.enableAutoUpdate == false then
    return false
  end

  term.write("Looking for a new version...\n")
  local latest = installer.latest(program)

  if latest == nil or latest.version == nil or installer.compareVersions(latest.version, program.version) <= 0 then
    return false
  end

  term.write(program.name.." "..latest.version.." is out (you have "..program.version.."). Install it now? [y/N] ")
  local _, _, char, code = event.pull(15, "key_down")

  if code then
    event.pull(2, "key_up", nil, nil, code)
  end

  term.write("\n")

  if char == nil or string.char(char):lower() ~= "y" then
    return false
  end

  local isOk, lines = installer.install(program, latest.version)

  for _, line in ipairs(lines) do
    term.write(line.."\n")
  end

  if isOk then
    term.write("Updated. Start it again with: main\n")
  end

  return isOk
end

-- ---------- config ----------

---Read and check config.lua; mistakes are an error (the program shows it and tries again)
local function loadConfig()
  local checked, warnings = cfg.load(configPath, schema.config)
  local raw = cfg.read(configPath)

  for _, warning in ipairs(warnings) do
    log.warning("[Config] "..warning)
  end

  return checked, raw
end

local function isSame(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then
    return a == b
  end

  for key, value in pairs(a) do
    if not isSame(value, b[key]) then return false end
  end

  for key in pairs(b) do
    if a[key] == nil then return false end
  end

  return true
end

---Changes that need a fresh start: units and the ME interface are found when the program starts
local function restartReasons(oldRaw, newRaw)
  local reasons = {}
  local oldQc, newQc = oldRaw.quantityController or {}, newRaw.quantityController or {}

  if not isSame(oldRaw.controllers, newRaw.controllers) then
    reasons[#reasons + 1] = "units (enable, transposers, maxQuarkCount)"
  end

  if oldQc.meInterfaceAddress ~= newQc.meInterfaceAddress then
    reasons[#reasons + 1] = "ME interface address"
  end

  if (tostring(oldQc.controlMode):lower() == "disabled") ~= (tostring(newQc.controlMode):lower() == "disabled") then
    reasons[#reasons + 1] = "Quantity Controller on or off"
  end

  return reasons
end

---New settings that work without a fresh start: log level, Discord, the Quantity Controller's mode and amounts
local function applyLive(newConfig)
  addons.load("event-log", {filePath = "logs.log", tagColors = log.settings.tagColors,
    screenLevel = newConfig.logLevel, fileLevel = newConfig.logLevel})
  config.logLevel = newConfig.logLevel
  config.discord = newConfig.discord
  config.enableAutoStart = newConfig.enableAutoStart
  config.enableAutoUpdate = newConfig.enableAutoUpdate
  discord.configure(config.discord)

  local _, newQuantity = schema.build(newConfig)
  quantityController.controlMode = newQuantity.controlMode
  quantityController.floorQty = newQuantity.floorQty
  quantityController.minQty = newQuantity.minQty
  quantityController.waterThresholds = newQuantity.waterThresholds

  if quantityController.controlMode ~= "disabled" then
    quantityController:checkSettings()
    quantityController:updateWaterLevels()
    quantityController:updateControllerEnablement()
  end
end

local function readKey()
  local _, _, char, code = event.pull("key_down")
  event.pull(2, "key_up", nil, nil, code)
  return string.char(char or 0):lower()
end

---E while running: edit config.lua, then use it live, start again, or keep the old settings.
---Returns "restart" when the program should start again with it
local function editConfig()
  isDrawing, isEditing = false, true
  screen.close()
  local result = nil

  while true do
    shell.execute('edit "'..configPath..'"')
    term.setCursorBlink(false)

    local newConfig, problems = nil, nil
    local isOk, err = pcall(function ()
      newConfig, problems = cfg.check(cfg.read(configPath) or {}, schema.config)
    end)

    if not isOk or #problems > 0 then
      term.clear()
      term.write("config.lua has a mistake, so it was not used:\n\n  ")
      term.write((isOk and table.concat(problems, "\n  ") or tostring(err)).."\n\n")
      term.write("E: edit it again    any other key: keep the old settings\n")

      if readKey() ~= "e" then
        log.warning("[Config] Mistake, old settings kept")
        break
      end
    else
      local newRaw = cfg.read(configPath)
      local reasons = restartReasons(runningRaw, newRaw)

      if isSame(runningRaw, newRaw) then
        -- nothing changed
      elseif #reasons > 0 then
        term.clear()
        term.write("These changes need the program to start again: "..table.concat(reasons, ", ")..".\n")
        term.write("The plant keeps running, and units that need attention stay off.\n\nStart again now? [y/N] ")

        if readKey() == "y" then
          log.info("[Config] Starting again with the new settings")
          result = "restart"
        else
          log.warning("[Config] Not used until the program starts again")
        end
      else
        applyLive(newConfig)
        runningRaw = newRaw
        log.info("[Config] New settings in use")
      end

      break
    end
  end

  screen.open()
  isDrawing, isEditing = true, false
  quitAsked, editAsked = false, false
  return result
end

-- ---------- screen ----------

local function highestLimit()
  local highest = 0

  for index = 1, 9 do
    if controllers["t"..math.min(index, 8)] ~= nil then
      highest = math.max(highest, quantityController.waterThresholds[index] or 0)
    end
  end

  return highest
end

local function unitViews()
  local views = {}

  for index = 1, 9 do
    local controller = controllers["t"..math.min(index, 8)]

    if controller ~= nil then
      local info = neonScreen.units[index]

      table.insert(views, {
        tier = index,
        label = index <= 8 and ("T"..index) or "BM",
        name = info.name,
        short = info.short,
        water = info.water,
        level = quantityController.waterLevels[index] or 0,
        target = quantityController.waterThresholds[index] or 0,
        state = index <= 8 and controllersStates["t"..index] or nil,
        isNext = index <= 8 and quantityController.isTierActive[index] == true,
        used = true,
        needsAttention = index <= 8 and controller.needsAttention == true,
        attentionReason = index <= 8 and (controller.attentionReason or "") or "",
      })
    end
  end

  return views
end

---What the statistics page shows
local function statsView()
  local view = {
    total = statsData.total("cycles"),
    last24 = statsData.last("cycles", 24),
    rate24 = statsData.rate("cycles", 24),
    units = {}, waters = {},
    hours = {},
    hourLabels = {},
    uptime = statsData.uptime(),
  }

  local since = view.uptime.since
  view.since = since and clock.format("%d.%m.%Y %H:%M", since) or nil

  local hour = math.floor(clock.now() / 3600)
  local perHour = statsData.hours("cycles", 24)

  for i = 1, 24 do
    view.hours[i] = perHour[i] or 0   -- nothing counted yet (e.g. just after a reset) is 0
  end

  for i = 1, 24 do
    view.hourLabels[i] = clock.format("%H", (hour - 24 + i) * 3600)
  end

  for tier = 1, 9 do
    if controllers["t"..math.min(tier, 8)] ~= nil then
      local info = neonScreen.units[tier]
      local label = tier <= 8 and ("T"..tier) or "BM"

      if tier <= 8 then
        view.units[#view.units + 1] = {label = label, short = info.short,
          total = statsData.total("cycles.t"..tier), last24 = statsData.last("cycles.t"..tier, 24)}
      end

      local reading = statsData.reading("water.t"..tier, 24)
      view.waters[#view.waters + 1] = {label = label, water = info.water,
        now = quantityController.waterLevels[tier], min = reading and reading.min, max = reading and reading.max,
        change = reading and reading.first and quantityController.waterLevels[tier] and
          (quantityController.waterLevels[tier] - reading.first) or nil}
    end
  end

  return view
end

---Write each water's stock into the statistics
local function recordWater()
  for tier = 1, 9 do
    local level = quantityController and quantityController.waterLevels[tier]

    if controllers["t"..math.min(tier, 8)] ~= nil and level ~= nil then
      statsData.record("water.t"..tier, level)
    end
  end
end

local function draw()
  if not isDrawing or lineController == nil then
    return
  end

  local progress, maxProgress = lineController:getCycleProgress()
  local width, height = screen.size()

  local lines, offset = neonScreen.render(width, height, {
    clock = clock.format("%H:%M:%S"),
    version = program.version,
    mode = quantityController.controlMode,
    plantRunning = maxProgress > 0,
    progress = progress,
    maxProgress = maxProgress,
    floorQty = quantityController.floorQty,
    minQty = quantityController.minQty,
    highestLimit = highestLimit(),
    units = unitViews(),
    decision = quantityController.lastDecision,
    reason = quantityController.lastReason,
    logs = log.lines(),
    logOffset = logOffset,
    tab = pages:current(),
    tabs = pages,
    buttons = buttons,
    overlay = function (cv) popups:draw(cv) end,
    statsView = pages:current() == "stats" and statsView() or nil,
    stats = {uptime = computer.uptime() - stats.startedAt, cycles = stats.cycles, unitCycles = stats.unitCycles},
  })

  logOffset = offset
  screen.show(lines)
end

---Screen while waiting to start again after an error
local function drawError(problem, left, attempt, giveUpIn, isSafe)
  local width, height = screen.size()
  local C = ui.colors
  local cv = ui.canvas(width, height)

  ui.header(cv, {clock = clock.format("%H:%M:%S"), title = "WATER LINE CONTROL", by = "by Sixxo",
    status = "ERROR", statusColor = C.red, badge = "STARTING AGAIN", badgeColor = C.amber, version = program.version})
  ui.card(cv, 1, 3, width, 9, "THE PROGRAM HAD AN ERROR", {right = "attempt "..attempt, rightColor = C.amber})

  -- The error over up to 4 rows: its own lines, long ones wrapped
  local y = 4

  for line in (explain(problem).."\n"):gmatch("(.-)\n") do
    local chars, first = ui.split(line), 1

    repeat
      if y > 7 then break end
      cv:put(3, y, table.concat(chars, "", first, math.min(#chars, first + width - 5)), C.red, C.card)
      first, y = first + width - 4, y + 1
    until first > #chars
  end

  ui.row(cv, 3, 9, width - 4, "Starting again in", left.." s", C.text, C.card)

  if isSafe then
    ui.row(cv, 3, 10, width - 4, "Plant switched off, trying every minute", ui.duration(failingFor), C.red, C.card)
  else
    ui.row(cv, 3, 10, width - 4, "Plant off in", ui.duration(giveUpIn), C.amber, C.card)
  end
  ui.log(cv, 1, 12, width, height - 12, "EVENT LOG", log.lines(), 0)
  ui.footer(cv, {keys = {{"E", "edit config"}, {"Q", "stop now (plant off)"}}})
  screen.show(cv:lines())
end

-- ---------- keys ----------

---Keys while the program waits after an error; the listener lives across runs
local waitingKeys = event.listen("key_down", function (_, _, char)
  if isEditing then
    return
  end

  local key = string.char(char or 0):lower()

  if key == "q" then quitAsked = true end
  if key == "e" then editAsked = true end
end)

---Ask, then clear all statistics
local function askReset()
  if popups:isOpen() then
    return
  end

  popups:confirm("RESET STATISTICS?", {
    "All cycles, water history and uptime are cleared.",
    "This can't be undone.",
  }, function (yes)
    if yes then
      statsData.reset()
      pcall(statsData.save)
      stats.cycles, stats.unitCycles, stats.startedAt = 0, {}, computer.uptime()
      log.info("Statistics reset")
    end
  end)
end

local function onKey(_, _, char, code)
  if isEditing then
    return
  elseif popups:isOpen() then
    popups:key(char, code)
    draw()
  elseif pages:current() == "stats" and (char == 114 or char == 82) then   -- r / R
    askReset()
    draw()
  elseif pages:key(char, code) then
    draw()
  elseif code == keyboard.keys.up then
    logOffset = math.max(0, logOffset - 1)
  elseif code == keyboard.keys.down then
    logOffset = logOffset + 1
  end
end

-- ---------- runs ----------

local function start()
  local newConfig, newRaw = loadConfig()
  config, runningRaw = newConfig, newRaw

  -- Every transposer and ME interface of the config is there; else say which and what could replace it
  local wired = wiring.check(schema.wiring(config))

  if not wired.ok then
    error(table.concat(wiring.problems(wired), "\n"), 0)
  end
  addons.load("event-log", {filePath = "logs.log", tagColors = log.settings.tagColors,
    screenLevel = config.logLevel, fileLevel = config.logLevel})
  discord.configure(config.discord)

  -- Units that needed attention before an error still need it
  local attention = {}

  for key, controller in pairs(controllers) do
    if controller.needsAttention then
      attention[key] = controller.attentionReason
    end
  end

  controllers, quantityController = schema.build(config)

  for tier = 1, 8 do
    local key = "t"..tier
    controllersStates[key] = controllers[key] and "Loading" or "Unused"

    if controllers[key] and attention[key] then
      controllers[key].needsAttention = true
      controllers[key].attentionReason = attention[key]
    end
  end

  screen.open()
  term.clear()

  if isFirstStart then
    isFirstStart = false
    log.info("Program started, QC mode "..config.quantityController.controlMode)
    local units = {}

    for tier = 1, 8 do
      if controllers["t"..tier] then units[#units + 1] = "T"..tier end
    end

    discord.start()
    discord.info("started", "Water Line Control started",
      "Mode "..config.quantityController.controlMode..", units "..(#units > 0 and table.concat(units, " ") or "none")..".")
  end

  lineController = lineControllerClass:new()
  lineController.stats = stats
  lineController:init(controllers)

  for tier = 1, 8 do
    if controllers["t"..tier] then
      controllers["t"..tier]:init()
    end
  end

  quantityController:init(controllers)

  if config.enableAutoStart ~= false then
    lineController:enable()
  end

  recovery.listen("key_down", onKey)
  recovery.listen("touch", function (_, _, x, y)
    x, y = math.floor(x), math.floor(y)

    if popups:touch(x, y) then
      draw()
    elseif pages:current() == "stats" and buttons:press(x, y) == "reset" then
      askReset()
      draw()
    elseif pages:touch(x, y) then
      draw()
    end
  end)
  statsData.start()
  recovery.timer(60, recordWater, math.huge)
  recovery.timer(1, draw, math.huge)
  quitAsked, editAsked = false, false
end

local function step()
  quantityController:loop()
  lineController:loop()

  for tier = 1, 8 do
    local key = "t"..tier

    if controllers[key] then
      controllers[key]:loop()
      controllersStates[key] = controllers[key]:getCurrentState()
    end

    os.sleep(0.1)
  end

  os.sleep(1)

  if editAsked then
    editAsked = false

    if editConfig() == "restart" then
      return "restart"
    end
  end

  return not quitAsked
end

local function errorText(problem)
  return (explain(problem):gsub("\nstack traceback:.*$", ""):gsub("%s*\n%s*", " "))
end

local function stop(reason)
  pcall(statsData.stop)

  if reason == "quit" or reason == "restart" then
    return
  end

  log.error(errorText(reason))
  discord.alert("error", "errors", "Error, starting again", errorText(reason):gsub("[%.%s]*$", "")
    ..". The program starts again every 30 s, and switches the plant off if it still fails after 5 minutes.")
end

local function safe(problem)
  if lineController ~= nil then
    pcall(lineController.disable, lineController)
  end

  if problem ~= nil then
    log.error("Plant switched off after 5 minutes of errors, trying again every minute")
    discord.alert("gaveUp", "errors", "Plant switched off after 5 minutes of errors",
      "The Water Purification Plant is switched off; the program tries again every minute and switches it on"..
      " when it works. Last error: "..errorText(problem))
  end
end

local function waiting(problem, left, attempt, giveUpIn, isSafe)
  if editAsked then
    isEditing = true
    screen.close()
    shell.execute('edit "'..configPath..'"')
    screen.open()
    isEditing = false
    quitAsked, editAsked = false, false
  end

  failingSince = failingSince or computer.uptime()
  failingFor = computer.uptime() - failingSince
  pcall(drawError, problem, left, attempt, giveUpIn, isSafe)

  if quitAsked then
    return "quit"
  end
end

local function started()
  if failingSince ~= nil then
    log.info("Running again after "..ui.duration(computer.uptime() - failingSince).." of errors")
  end

  failingSince = nil
  discord.clear("error", "errors", "Running again after an error", "")
end

-- ---------- main ----------

if not checkUpdate() then
  log.start()
  power.start()   -- logs when the computer went off without stopping the program, and when its energy runs low
  screen.open()
  local result, problem = recovery.run({start = start, step = step, stop = stop, safe = safe,
    waiting = waiting, started = started})

  if result == "quit" and lineController ~= nil then
    pcall(lineController.disable, lineController)   -- Stopping the program switches the plant off
  end

  power.stop()
  discord.finish(10)
  discord.stop()
  log.stop()
  event.cancel(waitingKeys)
  screen.close()
  term.clear()

  if result == "gave up" then
    io.stderr:write("Stopped after 5 minutes of errors. Last error:\n"..errorText(problem).."\n")
  else
    print("Water Line Control stopped. The plant is switched off. Start it again with: main")
  end
else
  event.cancel(waitingKeys)
end
