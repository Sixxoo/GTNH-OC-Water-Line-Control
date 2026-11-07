-- OpenOS keeps loaded libraries until the computer restarts, also after this program was updated.
-- Load this program's own fresh, so an update works without a reboot
for name in pairs(package.loaded) do
  if name:match("^lib%.") or name:match("^src%.") then
    package.loaded[name] = nil
  end
end

local component = require("component")
local computer = require("computer")
local event = require("event")
local term = require("term")
local keyboard = require("keyboard")
local shell = require("shell")

local configManager = require("lib.config-manager.index")
local programController = require("lib.program-controller.index")
local simpleGui = require("lib.simple-gui.index")

local configTemplate = require("src.config-template")
local lineControllerClass = require("src.line-controller")
local listeners = require("src.listeners")
local discord = require("src.discord")
local neonScreen = require("src.neon-screen")

local version = require("version")

---Read config.lua and build it. A mistake in it is an error, which the program shows and retries
---@return Config config
---@return table raw The values as written in config.lua
local function loadConfig()
  package.loaded.config = nil
  local raw = require("config")
  return configManager.manager:new(configTemplate):build(raw), raw
end

---Find config.lua the way require finds it
---@return string
local function configPath()
  return package.searchpath("config", package.path) or "config.lua"
end

local repository = "Sixxoo/GTNH-OC-Water-Line-Control"
local archiveName = "WaterLineControl"

local program = programController.program:new(version, repository, archiveName)
local gui = simpleGui.gui:new(program)

---@type Config
local config = nil

---The values of config.lua the running program was built from
---@type table
local runningRaw = nil

---@type LineController
local lineController = nil

local isStarted = false

local logo = {
  "__        __    _              _     _               ____            _             _ ",
  "\\ \\      / /_ _| |_ ___ _ __  | |   (_)_ __   ___   / ___|___  _ __ | |_ _ __ ___ | |",
  " \\ \\ /\\ / / _` | __/ _ \\ '__| | |   | | '_ \\ / _ \\ | |   / _ \\| '_ \\| __| '__/ _ \\| |",
  "  \\ V  V / (_| | ||  __/ |    | |___| | | | |  __/ | |__| (_) | | | | |_| | | (_) | |",
  "   \\_/\\_/ \\__,_|\\__\\___|_|    |_____|_|_| |_|\\___|  \\____\\___/|_| |_|\\__|_|  \\___/|_|"
}

---Rows of the screen
local screenHeight = 35

---Width that fills the screen at screenHeight rows: a character cell is twice as tall as wide
---@return integer width
---@return integer height
local function fitResolution()
  local gpu = component.gpu
  local maxWidth, maxHeight = gpu.maxResolution()
  local height = math.min(screenHeight, maxHeight)
  local width = math.min(80, maxWidth)

  local isOk, a, b = pcall(function ()
    return component.proxy(gpu.getScreen()).getAspectRatio()
  end)

  if isOk and type(a) == "number" and type(b) == "number" and a > 0 and b > 0 then
    width = math.max(80, math.min(math.floor(height * 2 * a / b + 0.5), maxWidth))
  end

  return width, height
end

---Template with one line per row: the screen module draws every row itself
---@return GuiTemplate
local function buildTemplate()
  local width, height = fitResolution()
  local lines = {}

  for y = 1, height do
    lines[y] = ""
  end

  return {
    width = width,
    background = neonScreen.colors.bg,
    foreground = neonScreen.colors.text,
    lines = lines
  }
end

---Scroll position of the log, 0 is the newest line
local logOffset = 0

---Counted since the program started, kept when it starts again after an error
local stats = {
  startedAt = computer.uptime(),
  cycles = 0,
  unitCycles = {}
}

local controllersStates = {}

---Keep what the previous run knew when the program starts again after an error:
---the log on the screen, and the units that need attention
---@param oldConfig Config
---@param newConfig Config
local function carryOver(oldConfig, newConfig)
  local oldLog = oldConfig.logger.handlers["scrollList"]
  local newLog = newConfig.logger.handlers["scrollList"]

  if oldLog ~= nil and newLog ~= nil then
    newLog.logs = oldLog.logs
    newLog.lastMessage = oldLog.lastMessage
    newLog.repeatCount = oldLog.repeatCount
  end

  for tier = 1, 8 do
    local key = "t"..tier
    local oldController = oldConfig.controllers[key]
    local newController = newConfig.controllers[key]

    if oldController ~= nil and newController ~= nil and oldController.needsAttention == true then
      newController.needsAttention = true
      newController.attentionReason = oldController.attentionReason
      newConfig.quantityController.isAttentionLogged[tier] = oldConfig.quantityController.isAttentionLogged[tier]
    end
  end

  oldConfig.logger:stop()
end

local function init()
  local newConfig, newRaw = loadConfig()

  if config ~= nil then
    carryOver(config, newConfig)
  end

  config = newConfig
  runningRaw = newRaw
  discord.configure(config.discord)

  for i = 1, 8, 1 do
    local key = "t"..i

    if config.controllers[key] ~= nil then
      controllersStates[key] = "Loading"
    else
      controllersStates[key] = "Unused"
    end
  end

  gui:setTemplate(buildTemplate())

  term.clear()

  if isStarted == false then
    event.push("log_info", "Program started, QC mode "..config.quantityController.controlMode)
    isStarted = true

    if config.logger.handlers["discord"] ~= nil then
      event.push("log_warning", "[Discord] Old log handler unused, see discord = {}")
    end

    local units = {}

    for tier = 1, 8 do
      if config.controllers["t"..tier] ~= nil then
        table.insert(units, "T"..tier)
      end
    end

    discord.start()
    discord.info("started", "Water Line Control started",
      "Mode "..config.quantityController.controlMode..", units "..(#units > 0 and table.concat(units, " ") or "none")..".")
  end

  lineController = lineControllerClass:new()
  lineController.stats = stats
  lineController:init(config.controllers)

  for i = 1, 8, 1 do
    local key = "t"..i

    if config.controllers[key] ~= nil then
      config.controllers[key]:init()
    end
  end

  config.quantityController:init(config.controllers)

  -- Stopping the program switches the plant off. The units are chosen above, so the first new cycle uses the right ones
  if config.enableAutoStart ~= false then
    lineController:enable()
  end
end

local function loop()
  while true do
    config.quantityController:loop()
    lineController:loop()

    for i = 1, 8, 1 do
      local key = "t"..i

      if config.controllers[key] ~= nil then
        config.controllers[key]:loop()
        controllersStates[key] = config.controllers[key]:getCurrentState()
      end

      os.sleep(0.1)
    end

    os.sleep(1)
  end
end

---Highest limit (threshold) of the waters whose unit is used: the full bar of a water without a cap
---@return number
local function highestLimit()
  local highest = 0

  for index = 1, 9 do
    if config.controllers["t"..math.min(index, 8)] ~= nil then
      highest = math.max(highest, config.quantityController.waterThresholds[index] or 0)
    end
  end

  return highest
end

---What the screen shows about each unit that is enabled in config.lua
---@return table[]
local function unitViews()
  local quantityController = config.quantityController
  local views = {}

  for index = 1, 9 do
    local tier = math.min(index, 8)
    local controller = config.controllers["t"..tier]

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
        attentionReason = index <= 8 and (controller.attentionReason or "") or ""
      })
    end
  end

  return views
end

local function guiLoop()
  local quantityController = config.quantityController
  local progress, maxProgress = lineController:getCycleProgress()
  local template = gui.template

  local lines, offset = neonScreen.render(template.width, #template.lines, {
    clock = config.logger:getTime("%H:%M:%S"),
    version = version.programVersion,
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
    logs = config.logger.handlers["scrollList"]:getLogs(),
    logOffset = logOffset,
    stats = {
      uptime = computer.uptime() - stats.startedAt,
      cycles = stats.cycles,
      unitCycles = stats.unitCycles
    }
  })

  logOffset = offset
  gui:show(lines)
end

---Compare two values of config.lua
---@param a any
---@param b any
---@return boolean
local function isSame(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then
    return a == b
  end

  for key, value in pairs(a) do
    if not isSame(value, b[key]) then
      return false
    end
  end

  for key in pairs(b) do
    if a[key] == nil then
      return false
    end
  end

  return true
end

---Changes that need the program to start again: the units and the ME interface are found when it starts
---@param oldRaw table
---@param newRaw table
---@return string[]
local function restartReasons(oldRaw, newRaw)
  local reasons = {}
  local oldQc, newQc = oldRaw.quantityController or {}, newRaw.quantityController or {}

  if not isSame(oldRaw.controllers, newRaw.controllers) then
    table.insert(reasons, "units (enable, transposers, maxQuarkCount)")
  end

  if oldQc.meInterfaceAddress ~= newQc.meInterfaceAddress then
    table.insert(reasons, "ME interface address")
  end

  if (tostring(oldQc.controlMode):lower() == "disabled") ~= (tostring(newQc.controlMode):lower() == "disabled") then
    table.insert(reasons, "Quantity Controller on or off")
  end

  return reasons
end

---Use new settings without starting again: the log, Discord and the Quantity Controller's mode and amounts
---@param newConfig Config
local function applyLive(newConfig)
  local oldLog = config.logger.handlers["scrollList"]
  local newLog = newConfig.logger.handlers["scrollList"]

  if oldLog ~= nil and newLog ~= nil then
    newLog.logs = oldLog.logs
    newLog.lastMessage = oldLog.lastMessage
    newLog.repeatCount = oldLog.repeatCount
  end

  config.logger:stop()
  config.logger = newConfig.logger
  config.discord = newConfig.discord
  config.enableAutoStart = newConfig.enableAutoStart
  discord.configure(config.discord)

  local quantityController = config.quantityController
  local newQuantityController = newConfig.quantityController

  quantityController.controlMode = newQuantityController.controlMode
  quantityController.floorQty = newQuantityController.floorQty
  quantityController.minQty = newQuantityController.minQty
  quantityController.waterThresholds = newQuantityController.waterThresholds

  -- Choose again now, so the screen shows it. A unit switched on now starts in the next cycle,
  -- and one switched off finishes the cycle it is running
  if quantityController.controlMode ~= "disabled" then
    quantityController:checkSettings()
    quantityController:updateWaterLevels()
    quantityController:updateControllerEnablement()
  end
end

---Read one key. Its key_up is waited for too, so it can't reach the program's keys afterwards
---@return string
local function readKey()
  local _, _, char, code = event.pull("key_down")
  event.pull(2, "key_up", nil, nil, code)

  return string.char(char or 0):lower()
end

---E: edit config.lua while the program runs, or while it waits after an error.
---Returns "restart" when the program should start again with it
---@param isRunning boolean
---@return string|nil
local function onEdit(isRunning)
  local result = nil

  gui.allowRender = false
  gui:resetScreen()

  while true do
    shell.execute('edit "'..configPath()..'"')
    term.setCursorBlink(false)

    -- Waiting after an error: the program tries the new config.lua when it starts again
    if not isRunning then
      break
    end

    local isOk, newConfig, newRaw = pcall(loadConfig)

    if not isOk then
      term.clear()
      term.write("config.lua has a mistake, so it was not used:\n\n")
      term.write(tostring(newConfig):gsub("\nstack traceback:.*$", "").."\n\n")
      term.write("E: edit it again    any other key: keep the old settings\n")

      if readKey() ~= "e" then
        event.push("log_warning", "[Config] Mistake, old settings kept")
        break
      end
    else
      local reasons = restartReasons(runningRaw, newRaw)

      if isSame(runningRaw, newRaw) then
        newConfig.logger:stop()
      elseif #reasons > 0 then
        newConfig.logger:stop()
        term.clear()
        term.write("These changes need the program to start again: "..table.concat(reasons, ", ")..".\n")
        term.write("The plant keeps running, and units that need attention stay off.\n\n")
        term.write("Start again now? [y/N] ")

        if readKey() == "y" then
          event.push("log_info", "[Config] Starting again with the new settings")
          result = "restart"
        else
          event.push("log_warning", "[Config] Not used until the program starts again")
        end
      else
        applyLive(newConfig)
        runningRaw = newRaw
        event.push("log_info", "[Config] New settings in use")
      end

      break
    end
  end

  gui.allowRender = true

  -- Waiting after an error, the error screen is drawn again; a restart sets up the screen itself
  if isRunning and result ~= "restart" then
    gui:resetToTemplate()
  end

  return result
end

---A run stops: after an error, or before exiting. The plant is left as it is
local function onStop()
  listeners.cancelAll()
end

---The text of an error for Discord: without the stack traceback, on one line
---@param problem any
---@return string
local function errorText(problem)
  local text = tostring(problem):gsub("\nstack traceback:.*$", ""):gsub("%s*\n%s*", " ")
  return text
end

local function onError(problem)
  discord.alert("error", "errors", "Error, starting again", errorText(problem):gsub("[%.%s]*$", "")
    ..". The program starts again every 30 s, and switches the plant off if it still fails after 5 minutes.")
end

local function onRecovered()
  discord.clear("error", "errors", "Running again after an error", "")
end

local function onGiveUp(problem)
  discord.alert("gaveUp", "errors", "Stopped after 5 minutes of errors",
    "The Water Purification Plant is switched off. Fix the problem, then run main. Last error: "..errorText(problem))
end

local function onExit()
  if lineController ~= nil then
    lineController:disable()
  end

  -- Messages that are still waiting get a few seconds
  discord.finish(10)
end

---Stop what keeps running after a run: on exit, or when the next start finds this one never got to exit
local function onRelease()
  listeners.cancelAll()
  discord.stop()

  if config ~= nil then
    config.logger:stop()
  end
end

program:registerLogo(logo)
program:registerOnInit(init)
program:registerOnStop(onStop)
program:registerOnExit(onExit)
program:registerOnRelease(onRelease)
program:registerOnErrors(onError, onRecovered, onGiveUp)
program:registerOnEdit(onEdit)
program:registerKeyHandler(keyboard.keys.e, function ()
  event.push("program_edit")
end)
-- The newest line is at the top of the log: down shows older lines
program:registerKeyHandler(keyboard.keys.up, function ()
  logOffset = math.max(0, logOffset - 1)
end)
program:registerKeyHandler(keyboard.keys.down, function ()
  logOffset = logOffset + 1
end)
program:registerThread(loop)
program:registerTimer(guiLoop, math.huge, 1)
program:start()