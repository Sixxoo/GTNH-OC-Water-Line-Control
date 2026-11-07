local event = require("event")
local thread = require("thread")
local component = require("component")
local computer = require("computer")
local keyboard = require("keyboard")
local term = require("term")

local classBuilder = require("lib.class-builder.index")
local programUpdater = require("lib.program-controller.program-updater")

---Get the first line of an error
---@param message any
---@return string
local function firstLine(message)
  return (tostring(message):match("^[^\n]*"))
end

---Whether an error is Ctrl+Alt+C, which OpenOS raises in whatever is waiting for a signal
---@param message any
---@return boolean
local function isInterrupt(message)
  return firstLine(message) == "interrupted"
end

---Try Catch. An error is pushed as "program_error" with the run it happened in, so the program can recover.
---Ctrl+Alt+C stops the program as Q does
---@param callback function
---@param runId? integer
---@return function
local function try(callback, runId)
  return function(...)
    local result = table.pack(xpcall(callback, debug.traceback, ...))
    if not result[1] then
      if isInterrupt(result[2]) then
        event.push("exit")
      else
        event.push("program_error", result[2], runId)
      end
    end
    return table.unpack(result, 2, result.n)
  end
end

---Only the program's own signals. event.pull matches names as patterns, so "exit" would also catch "thread_exit"
---@param name any
---@return boolean
local function isProgramSignal(name)
  return name == "exit" or name == "program_error" or name == "program_edit"
end

---"4m 30s", "45s"
---@param seconds number
---@return string
local function duration(seconds)
  seconds = math.max(0, math.ceil(seconds))

  if seconds >= 60 then
    return string.format("%dm %02ds", seconds // 60, seconds % 60)
  end

  return seconds.."s"
end

---Get the lines of an error to show: the message without the stack traceback, cut to the width
---@param message any
---@param width integer
---@return string[]
local function errorLines(message, width)
  local text = tostring(message):gsub("\nstack traceback:.*$", "")
  local lines = {}

  for line in text:gmatch("[^\n]+") do
    line = line:gsub("^%s+", "")

    while #line > width do
      table.insert(lines, line:sub(1, width))
      line = line:sub(width + 1)
    end

    table.insert(lines, line)
  end

  return lines
end

---@class Program
---@field enableAutoUpdate? boolean
---@field version? ProgramVersion
---@field repository? string
---@field archiveName? string
---@field debug boolean
---@field coroutines table
---@field running table
---@field keyHandlers table<number, fun()>
---@field keyListener? number
---@field errorListener? number
---@field pendingErrors table[]
---@field isEditing boolean
---@field runId integer
---@field runStartedAt number
---@field failingSince? number
---@field attempt integer
---@field statusRow integer
---@field retrySeconds number
---@field giveUpSeconds number
---@field defaultLoopInterval number
---@field defaultWidth number
---@field defaultHeight number
---@field defaultForeground number
---@field defaultBackground number
---@field logo? string[]
---@field onInit? fun()
---@field onStop? fun()
---@field onExit? fun()
---@field onRelease? fun()
---@field isExiting boolean
---@field onError? fun(problem: any)
---@field onRecovered? fun()
---@field onGiveUp? fun(problem: any)
---@field onEdit? fun(isRunning: boolean): string|nil
---@field updater ProgramUpdater
local program = {}

---Constructor
---@param enableAutoUpdate? boolean
---@param version? ProgramVersion
---@param repository? string
---@param archiveName? string
---@return Program
function program:constructor(enableAutoUpdate, version, repository, archiveName)
  self.enableAutoUpdate = enableAutoUpdate
  self.version = version
  self.repository = repository
  self.archiveName = archiveName

  self.debug = false
  self.coroutines = {}
  self.running = {}
  self.keyHandlers = {}
  self.keyListener = nil
  self.errorListener = nil
  self.pendingErrors = {}
  self.isEditing = false
  self.isExiting = false

  -- Where a run keeps its release function in package.loaded, which OpenOS keeps until reboot
  self.leftoverKey = "program-controller.leftover."..tostring(archiveName or "program")

  self.runId = 0
  self.runStartedAt = 0
  self.failingSince = nil
  self.attempt = 0
  self.statusRow = 1

  -- After an error the program starts again after retrySeconds. It gives up when it is still failing after giveUpSeconds
  self.retrySeconds = 30
  self.giveUpSeconds = 300

  self.defaultLoopInterval = 1/20
  self.defaultWidth = 0
  self.defaultHeight = 0
  self.defaultForeground = 0
  self.defaultBackground = 0

  self.logo = nil

  self.onInit = nil
  self.onStop = nil
  self.onExit = nil
  self.onRelease = nil
  self.onError = nil
  self.onRecovered = nil
  self.onGiveUp = nil
  self.onEdit = nil

  self.updater = programUpdater:new(self)

  return self
end

---Register logo
---@param logo string[]
function program:registerLogo(logo)
  self.logo = logo
end

---Register onInit function. It runs at the start, and again when the program starts again after an error
---@param callback function
function program:registerOnInit(callback)
  self.onInit = callback
end

---Register onStop function. It runs when a run of the program stops, after an error and before onExit
---@param callback function
function program:registerOnStop(callback)
  self.onStop = callback
end

---Register onExit function
---@param callback function
function program:registerOnExit(callback)
  self.onExit = callback
end

---Register onRelease function. It stops what lives longer than a run (log listeners, senders), last on exit.
---When a run ends without exit (Ctrl+Alt+C, a crash), the next start calls it instead
---@param callback function
function program:registerOnRelease(callback)
  self.onRelease = callback
end

---Register functions for errors: onError(problem) each time the program waits to start again,
---onRecovered() when it runs again, onGiveUp(problem) before it stops for good
---@param onError fun(problem: any)
---@param onRecovered fun()
---@param onGiveUp fun(problem: any)
function program:registerOnErrors(onError, onRecovered, onGiveUp)
  self.onError = onError
  self.onRecovered = onRecovered
  self.onGiveUp = onGiveUp
end

---Register the function that edits the config while the program runs (or waits after an error).
---It returns "restart" when the program should start again with the new config
---@param callback fun(isRunning: boolean): string|nil
function program:registerOnEdit(callback)
  self.onEdit = callback
end

---Register timer
---@param callback function
---@param times? number
---@param interval? number
function program:registerTimer(callback, times, interval)
  interval = interval or self.defaultLoopInterval

  local coroutineDescriptor = {
    type = "timer",
    interval = interval,
    callback = callback,
    times = times
  }

  table.insert(self.coroutines, coroutineDescriptor)
end

---Register thread
---@param callback function
function program:registerThread(callback)
  local coroutineDescriptor = {
    type = "thread",
    callback = callback,
  }

  table.insert(self.coroutines, coroutineDescriptor)
end

---Register button handler
---@param keyCode number
---@param callback function
function program:registerKeyHandler(keyCode, callback)
  if self.keyHandlers[keyCode] ~= nil then
    error("[Program] "..keyCode.." key is busy")
  end

  self.keyHandlers[keyCode] = try(callback)
end

---Remove button handler
---@param keyCode number
function program:removeKeyHandler(keyCode)
  self.keyHandlers[keyCode] = nil
end

---Program start
function program:start()
  -- OpenOS keeps a program's listeners, timers and threads after it ends. A run that ended without exit
  -- (Ctrl+Alt+C, a crash) would keep controlling the plant next to this one, so it is stopped first
  local leftover = package.loaded[self.leftoverKey]

  if type(leftover) == "function" then
    pcall(leftover)
  end

  package.loaded[self.leftoverKey] = function()
    self:release()
  end

  self.defaultWidth, self.defaultHeight = component.gpu.getResolution()
  self.defaultForeground = component.gpu.getForeground()
  self.defaultBackground = component.gpu.getBackground()

  if self.logo then
    self:displayLogo()
  end

  if self.enableAutoUpdate then
    self.updater:autoUpdate()
    self:registerTimer(self.updater:checkUpdateTimer())
  end

  self:registerKeyHandler(keyboard.keys.q, function()
    event.push("exit")
  end)

  -- Errors are collected by a listener: while the editor runs, it takes the signals, so they wouldn't reach the loop below
  self.errorListener = event.listen("program_error", function (_, message, runId)
    table.insert(self.pendingErrors, {message = message, runId = runId})
  end)

  self.keyListener = event.listen("key_up", try(function (_, address, char, keyCode)
    -- Keys typed in the editor are not the program's
    if self.isEditing then
      return
    end

    if self.debug == true then
      event.push("log_debug", "Pressed ["..string.char(char).."]: "..keyCode.."\n")
    end

    if self.keyHandlers[keyCode] then
      if self.debug == true then
        event.push("log_debug", "Action ["..string.char(char).."]: "..keyCode.."\n");
      end

      self.keyHandlers[keyCode]()
    end
  end))

  -- os.exit is an error too, which goes on to the shell as it is
  local isOk, problem = xpcall(self.runUntilExit, function (message)
    return self.isExiting and message or debug.traceback(message)
  end, self)

  -- Ctrl+Alt+C or an error outside a run: exit as Q does, so nothing of this run keeps going
  if not isOk and not self.isExiting then
    self:exit(not isInterrupt(problem) and problem or nil)
  end

  if not isOk then
    error(problem, 0)
  end
end

---Run the program, start it again after an error, and exit on Q or when it keeps failing
---@private
function program:runUntilExit()
  local isRunning, problem = self:startRun()

  while true do
    if isRunning then
      local pendingProblem = self:takeError()

      if pendingProblem ~= nil then
        -- A run that went well for a while starts a new count
        if computer.uptime() - self.runStartedAt >= self.giveUpSeconds then
          self.failingSince = nil
          self.attempt = 0
        end

        self:stopRun()
        isRunning, problem = false, pendingProblem
      else
        local name, message = event.pullFiltered(isProgramSignal)

        if name == "exit" then
          self:exit(message)
          return
        elseif name == "program_edit" and self:edit(true) == "restart" then
          self:stopRun()
          isRunning, problem = self:startRun()
        end
        -- "program_error" is collected by the error listener and handled at the top of the loop
      end
    else
      local now = computer.uptime()
      self.failingSince = self.failingSince or now
      local giveUpIn = self.giveUpSeconds - (now - self.failingSince)

      if giveUpIn <= 0 then
        event.push("log_error", "[Program] Still failing after "..math.floor(self.giveUpSeconds / 60).." min, stopping")

        if self.onGiveUp then
          pcall(self.onGiveUp, problem)
        end

        self:exit(problem)
        return
      end

      if self.onError then
        pcall(self.onError, problem)
      end

      event.push("log_error", "[Program] Error, restarting in "..self.retrySeconds.."s: "..firstLine(problem))
      self.attempt = self.attempt + 1
      self:showError(problem)

      local action = self:waitForExit(self.retrySeconds)

      if action == "exit" then
        self:exit()
        return
      elseif action == "edit" then
        -- The fixed config.lua is tried at once
        self:edit(false)
      end

      self:showStatus("Starting again now (attempt "..self.attempt..")...", nil)
      isRunning, problem = self:startRun()

      if isRunning then
        event.push("log_warning", "[Program] Started again after an error")

        if self.onRecovered then
          pcall(self.onRecovered)
        end
      end
    end
  end
end

---Start a run: onInit, then the timers and threads
---@return boolean isRunning
---@return string? problem
---@private
function program:startRun()
  self.runId = self.runId + 1
  self.runStartedAt = computer.uptime()
  self.pendingErrors = {}

  if self.onInit then
    local isOk, problem = xpcall(self.onInit, debug.traceback)

    if not isOk then
      self:stopRun()
      return false, problem
    end
  end

  for _, descriptor in ipairs(self.coroutines) do
    if descriptor.type == "timer" then
      table.insert(self.running, event.timer(descriptor.interval, try(descriptor.callback, self.runId), descriptor.times))
    elseif descriptor.type == "thread" then
      local handle = thread.create(try(descriptor.callback, self.runId))
      handle:detach()
      table.insert(self.running, handle)
    end
  end

  return true, nil
end

---Stop the timers and threads of a run, then onStop
---@private
function program:stopRun()
  for _, handle in ipairs(self.running) do
    if type(handle) == "table" and handle.kill then
      handle:kill()
    elseif type(handle) == "number" then
      event.cancel(handle)
    end
  end

  self.running = {}

  if self.onStop then
    pcall(self.onStop)
  end
end

---Get the first error of the current run, and forget the others
---@return any|nil
---@private
function program:takeError()
  local errors = self.pendingErrors
  self.pendingErrors = {}

  for _, each in ipairs(errors) do
    -- An error from a run that already stopped is ignored
    if each.runId == nil or each.runId == self.runId then
      return each.message
    end
  end

  return nil
end

---Edit the config with onEdit. The program's keys are ignored meanwhile
---@param isRunning boolean
---@return string|nil
---@private
function program:edit(isRunning)
  if self.onEdit == nil then
    return nil
  end

  self.isEditing = true
  local isOk, result = pcall(self.onEdit, isRunning)
  self.isEditing = false

  if not isOk then
    event.push("log_error", "[Program] Editing failed: "..firstLine(result))
    return nil
  end

  return result
end

---Wait with a countdown on the screen. Returns "exit" for Q, "edit" for E, or nil
---@param seconds number
---@return string|nil
---@private
function program:waitForExit(seconds)
  local deadline = computer.uptime() + seconds

  while computer.uptime() < deadline do
    local left = deadline - computer.uptime()
    local giveUpIn = self.giveUpSeconds - (computer.uptime() - self.failingSince)

    self:showStatus(
      "Starting again in "..duration(left).." (attempt "..self.attempt..")",
      "Gives up in "..duration(giveUpIn).." if it keeps failing (plant off)"
    )

    -- Wake up every second for the countdown
    local name = event.pullFiltered(math.min(1, left), isProgramSignal)

    if name == "exit" then
      return "exit"
    elseif name == "program_edit" and self.onEdit ~= nil then
      return "edit"
    end
  end

  return nil
end

---Show an error. The status lines under it say when the program starts again
---@param problem any
---@private
function program:showError(problem)
  local gpu = component.gpu
  local width, height = self.defaultWidth, self.defaultHeight

  -- A screen that left the network (a broken cable) is unbound, and stays unbound when it comes back
  if gpu.getScreen() == nil then
    local screen = component.list("screen")()

    if screen ~= nil then
      gpu.bind(screen)
    end
  end

  -- An error in the middle of drawing a frame leaves its buffer active
  gpu.freeAllBuffers()
  gpu.setActiveBuffer(0)
  gpu.setResolution(width, height)
  gpu.setBackground(self.defaultBackground)
  gpu.fill(1, 1, width, height, " ")

  gpu.setForeground(0xFF5555)
  gpu.set(1, 1, "The program had an error:")
  gpu.setForeground(self.defaultForeground)

  -- The error, leaving room for the status lines and the key help
  local row = 3

  for _, line in ipairs(errorLines(problem, width)) do
    if row > height - 5 then
      break
    end

    gpu.set(1, row, line)
    row = row + 1
  end

  self.statusRow = math.min(row + 1, height - 2)

  gpu.setForeground(0xA9A9A9)

  if self.onEdit ~= nil then
    gpu.set(1, self.statusRow + 2, "E: edit config.lua    Q: stop now (switches the plant off)")
  else
    gpu.set(1, self.statusRow + 2, "Q: stop now (switches the plant off)")
  end

  gpu.setForeground(self.defaultForeground)
end

---Show the status lines under the error
---@param first string
---@param second? string
---@private
function program:showStatus(first, second)
  local gpu = component.gpu

  gpu.fill(1, self.statusRow, self.defaultWidth, 2, " ")
  gpu.setForeground(0xFFDB00)
  gpu.set(1, self.statusRow, first)

  if second then
    gpu.setForeground(0xA9A9A9)
    gpu.set(1, self.statusRow + 1, second)
  end

  gpu.setForeground(self.defaultForeground)
end

---Program exit
---@param exception any
function program:exit(exception)
  self.isExiting = true
  self:stopRun()
  self:cancelListeners()

  component.gpu.freeAllBuffers()
  component.gpu.setResolution(self.defaultWidth, self.defaultHeight)
  component.gpu.setForeground(self.defaultForeground)
  component.gpu.setBackground(self.defaultBackground)

  term.clear()

  if exception then
    event.push("log_error", exception)
  end

  -- Hand out the log lines while the logger still listens; onRelease stops it
  pcall(os.sleep, 0)

  if self.onExit then
    pcall(self.onExit)
  end

  self:release()

  if exception then
    io.stderr:write(tostring(exception))
    os.exit(1)
  else
    os.exit(0)
  end
end

---Stop the program's own listeners
---@private
function program:cancelListeners()
  if self.keyListener then
    event.cancel(self.keyListener)
    self.keyListener = nil
  end

  if self.errorListener then
    event.cancel(self.errorListener)
    self.errorListener = nil
  end
end

---Stop everything of this program that OpenOS would keep after it ends. Called on exit, or by the next start
---when this one ended without exit. The plant is left as it is: the next start takes over
---@private
function program:release()
  pcall(self.stopRun, self)
  self:cancelListeners()

  if self.onRelease then
    pcall(self.onRelease)
  end

  package.loaded[self.leftoverKey] = nil
end

---Display logo
---@private
function program:displayLogo()
  local width = #self.logo[1] + 2
  local height = #self.logo + 2

  component.gpu.setResolution(width, height)
  component.gpu.fill(1, 1, width, height, " ")

  term.setCursor(1, 2)

  for _, line in pairs(self.logo) do
    term.write(" "..line.."\n")
  end

  os.sleep(1)

  component.gpu.fill(1, 1, width, height, " ")
  component.gpu.setResolution(self.defaultWidth, self.defaultHeight)
end

return classBuilder.createClass(program, program.constructor, "Program")
