local component = require("component")
local computer = require("computer")
local term = require("term")
local serialization = require("serialization")
local unicode = require("unicode")

local classBuilder = require("lib.class-builder.index")
local stringUtilities = require("lib.string-utilities.index")

local formatters = require("lib.simple-gui.formatters")
local justifier = require("lib.simple-gui.justifier")

---Seconds between frames that draw every line, not only the changed ones
local fullRenderSeconds = 60

---@class SimpleGui
---@field program Program
---@field width number
---@field height number
---@field template GuiTemplate
---@field allowRender boolean
---@field registeredKeys table
---@field palette table<string, number>
---@field shownLines? string[] The lines on the screen, nil when it must be drawn again
---@field fullRenderAt? number
local simpleGui = {}

---Constructor
---@return SimpleGui
function simpleGui:constructor(program)
  self.program = program

  self.width = 32
  self.height = 1

  self.template = nil

  self.allowRender = true

  self.shownLines = nil
  self.fullRenderAt = nil

  self.registeredKeys = {}

  self.palette = {
    white = 0xFFFFFF,
    black = 0x000000,
    red = 0xCC0000,
    green = 0x009200,
    blue = 0x0000C0,
    lightBlue = 0xADDFFF,
    yellow = 0xFFDB00,
    pink = 0xFF007F,
    lime = 0x00FF00,
    magenta = 0xFF00FF,
    cyan = 0x00FFFF,
    greenYellow = 0xADFF2F,
    darkOliveGreen = 0x556B2F,
    indigo = 0x4B0082,
    purple = 0x800080,
    electricBlue = 0x00A6FF,
    dodgerBlue = 0x1E90FF,
    steelBlue = 0x4682B4,
    darkSlateBlue = 0x483D8B,
    midnightBlue = 0x191970,
    darkBlue = 0x000080,
    darkOrange = 0xFFA500,
    rosyBrown = 0xBC8F8F,
    golden = 0xDAA520,
    maroon = 0x800000,
    gray = 0x3C5B72,
    lightGray = 0xA9A9A9,
    darkGray = 0x181828,
    darkSlateGrey = 0x2F4F4F
  }

  return self
end

---Set template
---@param template GuiTemplate
function simpleGui:setTemplate(template)
  self.template = template
  self.width = template.width
  self.height = #template.lines

  if template.widgets then
    for _, key in pairs(self.registeredKeys) do 
      self.program:removeKeyHandler(key);
    end

    for name, widget in pairs(template.widgets) do
      widget:init(template, name)

      local keyHandlers = widget:registerKeyHandlers()

      for key, callback in pairs(keyHandlers) do
        self.program:registerKeyHandler(key, callback)
        table.insert(self.registeredKeys, key)
      end
    end
  end

  component.gpu.setResolution(self.width, self.height)
  self.shownLines = nil
end

---Reset Screen
function simpleGui:resetScreen()
  local width, height = component.gpu.maxResolution()
  component.gpu.freeAllBuffers()
  component.gpu.setResolution(width, height)
  component.gpu.fill(1, 1, width, height, " ")
  term.setCursor(0, 0)
  self.shownLines = nil
end

---Reset To Template
function simpleGui:resetToTemplate()
  component.gpu.freeAllBuffers()
  component.gpu.setResolution(self.width, self.height)
  component.gpu.fill(1, 1, self.width, self.height, " ")
  term.setCursor(0, 0)
  self.shownLines = nil
end

---Bind the graphics card to the screen again if it lost it. A screen that leaves the network
---(a broken cable) is unbound, and stays unbound when it comes back
---@return boolean # true if it was bound again
function simpleGui:ensureScreen()
  local gpu = component.gpu

  if gpu.getScreen() ~= nil then
    return false
  end

  local screen = component.list("screen")()

  if screen == nil then
    return false
  end

  gpu.bind(screen)
  gpu.setResolution(self.width, self.height)

  return true
end

---Render. Only the lines that changed since the last frame are drawn and sent to the screen
---@param values table<string, string|number|table|boolean>
function simpleGui:render(values)
  if not self.allowRender then
    return
  end

  local lines = {}

  for y, line in ipairs(self.template.lines) do
    local renderedString = line
    renderedString = self:renderConditions(renderedString, values)
    renderedString = self:renderValues(renderedString, values)
    renderedString = self:renderWidgets(renderedString, values, y)
    renderedString = self:renderLineContentJustify(renderedString)

    lines[y] = renderedString
  end

  self:show(lines)
end

---Show lines that already have their colour codes, one per row of the template.
---Only the lines that changed since the last frame are drawn and sent to the screen
---@param lines string[]
function simpleGui:show(lines)
  if not self.allowRender then
    return
  end

  if self:ensureScreen() then
    self.shownLines = nil
  end

  -- Now and then everything is drawn again, in case something else wrote on the screen
  local now = computer.uptime()

  if self.fullRenderAt == nil or now - self.fullRenderAt >= fullRenderSeconds or now < self.fullRenderAt then
    self.shownLines = nil
  end

  local changed = {}

  for y = 1, self.height do
    if self.shownLines == nil or self.shownLines[y] ~= lines[y] then
      table.insert(changed, y)
    end
  end

  if self.shownLines == nil then
    self.fullRenderAt = now
  end

  self.shownLines = lines

  if #changed == 0 then
    return
  end

  local gpu = component.gpu
  local buffer = gpu.allocateBuffer(self.width, self.height)
  gpu.setActiveBuffer(buffer)

  for _, y in ipairs(changed) do
    self:drawLine(lines[y], y)
  end

  gpu.setActiveBuffer(0)

  for _, y in ipairs(changed) do
    gpu.bitblt(0, 1, y, self.width, 1, buffer, 1, y)
  end

  gpu.freeAllBuffers()
end

---Draw a rendered line with its colour codes. Text in one colour is drawn with one call
---@param line string
---@param y integer
---@private
function simpleGui:drawLine(line, y)
  local gpu = component.gpu
  local foreground, background = self.template.foreground, self.template.background
  local x = 1
  local i = 1
  local run = {}

  gpu.setBackground(background)
  gpu.setForeground(foreground)

  local function drawRun()
    if #run > 0 then
      local text = table.concat(run)
      gpu.set(x, y, text)
      x = x + unicode.wlen(text)
      run = {}
    end
  end

  while i <= #line do
    local symbol = line:sub(i, i)

    if symbol == "&" then
      local colorString = ""
      local isBackgroundColor = false

      if line:sub(i + 1, i + 1) == "&" then
        isBackgroundColor = true
        i = i + 1
      end

      repeat
        i = i + 1
        local next = line:sub(i, i)
        if next ~= ";" then
          colorString = colorString .. next
        end
      until next == ";" or next == ""

      local color = self.palette[colorString] or tonumber(colorString)

      if isBackgroundColor and color and color ~= background then
        drawRun()
        background = color
        gpu.setBackground(color)
      elseif not isBackgroundColor and color and color ~= foreground then
        drawRun()
        foreground = color
        gpu.setForeground(color)
      end

      i = i + 1
    else
      -- Take the whole UTF-8 character, so symbols like "▶" stay one
      local byte = symbol:byte()
      local length = byte >= 0xF0 and 4 or byte >= 0xE0 and 3 or byte >= 0xC0 and 2 or 1

      table.insert(run, line:sub(i, i + length - 1))
      i = i + length
    end
  end

  drawRun()
end

---Render Line Content Justify
---@param line string
---@return string
---@private
function simpleGui:renderLineContentJustify(line)
  local justify = line:match("@([^;]+);")

  if not justify then
    return line
  end

  return justifier[justify](line:gsub("@([^;]+);", ""), self.template.width)
end

---Render Conditions
---@param line string
---@param values table<string, any>
---@return string, number
---@private
function simpleGui:renderConditions(line, values)
  return string.gsub(line, "?(.-)?", function (pattern)
    local condition, left, right = pattern:match("^(.*)|(.*)|(.*)$")
    local lambda = ""

    for key, value in pairs(values) do
      lambda = lambda..key.."="

      if type(value) == "string" then
        lambda = lambda.."\""..value.."\"\n"
      elseif type(value) == "table" then
        lambda = lambda..serialization.serialize(value).."\n"
      elseif type(value) == "boolean" then
        lambda = lambda..(value == true and "true" or "false").."\n"
      else
        lambda = lambda..value.."\n"
      end
    end

    lambda = lambda.."return "..condition

    local result = load(lambda)()

    return result and left or right
  end)
end

---Render Values
---@param line string
---@param values table<string, any>
---@return string, number
---@private
function simpleGui:renderValues(line, values)
  return string.gsub(line, "%$(.-)%$", function (pattern)
    local formatter
    local variable, args = pattern:match("^(.+):(.+)$")

    if not variable then
      variable = pattern
      formatter = "s"
      args = {"%s"}
    else
      args = stringUtilities.split(args, ",")
      formatter = args[1]
      table.remove(args, 1)
    end

    if formatter then
      return formatters[formatter](values[variable], table.unpack(args))
    end

    return values[variable]
  end)
end

---Render Widgets
---@param line string
---@param values table<string, any>
---@param y number
---@return string, number
---@private
function simpleGui:renderWidgets(line, values, y)
  return string.gsub(line, "#(.-)#", function (pattern)
    local name, args = pattern:match("^(.+):(.+)$")

    if not name then
      name = pattern
      args = {}
    else
      args = stringUtilities.split(args, ",")
    end

    if self.template.widgets[name] then
      return self.template.widgets[name]:render(values, y, table.unpack(args))
    end
  end)
end

return classBuilder.createClass(simpleGui, simpleGui.constructor, "SimpleGui")