-- Screen in the neon style: blue framed cards on near black, red corners, coloured by meaning.
-- Everything is drawn into a grid of cells first. Each row of the grid becomes one line with
-- colour codes (&0xRRGGBB; foreground, &&0xRRGGBB; background) for simple-gui, which only
-- sends the rows that changed to the screen.
local formatAmount = require("src.format-amount")

local neonScreen = {}

---Colours
neonScreen.colors = {
  bg = 0x03050A, card = 0x090C14, face = 0x0B0F18, alt = 0x101826,
  neon = 0x00B4FF, red = 0xFF2A3D, green = 0x2BE05A, amber = 0xFFB020, yellow = 0xFFE14D,
  orange = 0xFF8A1F, cyan = 0x2EF0F0,
  text = 0xFFFFFF, dim = 0xB9C7DB, sub = 0xA9D4FF, na = 0x6B7A8F, track = 0x1E2C40, line = 0x14507A,
}

local C = neonScreen.colors

---Colour names used in log lines, in the neon colours
neonScreen.logPalette = {
  white = C.text, lightGray = C.na, gray = C.na, yellow = C.amber, red = C.red,
  cyan = C.neon, green = C.green, lime = C.green, darkOrange = C.orange,
}

local CH = {
  tl = "┌", tr = "┐", bl = "└", br = "┘", h = "─", v = "│", hh = "━",
  lt = "├", rt = "┤", next = "▶", cross = "✗", mark = "┃",
}

---Units of the Water Purification Plant, by tier. Index 9 is Stabilised Baryonic Matter, made by T8
neonScreen.units = {
  {name = "CLARIFIER", water = "Filtered Water", short = "Clarifier"},
  {name = "OZONATION", water = "Ozonated Water", short = "Ozonation"},
  {name = "FLOCCULATION", water = "Flocculated Water", short = "Flocculation"},
  {name = "PH NEUTRALIZATION", water = "pH Neutralized Water", short = "pH Neutralization"},
  {name = "EXTREME TEMPERATURE", water = "Extreme-Temp Treated Water", short = "Extreme Temp."},
  {name = "UV TREATMENT", water = "UV Treated Neutral Water", short = "UV Treatment"},
  {name = "DEGASSER", water = "Degassed Decontaminant-Free Water", short = "Degasser"},
  {name = "QUARK", water = "Subatomically Perfect Water", short = "Quark"},
  {name = "BARYONIC MATTER", water = "Stabilised Baryonic Matter", short = "Baryonic Matter"},
}

local modeLabels = {
  disabled = "QC OFF",
  multiThread = "MULTI THREAD",
  singleThread = "SINGLE THREAD",
  singleThreadBalancing = "BALANCING",
}

---Split UTF-8 text into characters. The screen font draws every character used here one cell wide
---@param text string
---@return string[]
local function chars(text)
  local list = {}

  for char in tostring(text):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    list[#list + 1] = char
  end

  return list
end

local function textLength(text)
  return #chars(text)
end

---Shorten text to a width, with a dot at the end when it was cut
---@param text string
---@param width integer
---@return string
local function fit(text, width)
  local list = chars(text)

  if #list <= width then
    return text
  end

  if width <= 1 then
    return table.concat(list, "", 1, math.max(0, width))
  end

  return table.concat(list, "", 1, width - 1).."."
end

---@class NeonCanvas
local canvas = {}
canvas.__index = canvas

---@param width integer
---@param height integer
---@return NeonCanvas
function neonScreen.canvas(width, height)
  local self = setmetatable({width = width, height = height, char = {}, fg = {}, bg = {}}, canvas)

  for y = 1, height do
    self.char[y], self.fg[y], self.bg[y] = {}, {}, {}

    for x = 1, width do
      self.char[y][x], self.fg[y][x], self.bg[y][x] = " ", C.text, C.bg
    end
  end

  return self
end

---Write text. With a width it is padded or cut to it
function canvas:put(x, y, text, fg, bg, width)
  if y < 1 or y > self.height then
    return
  end

  local list = chars(text)

  if width ~= nil then
    while #list < width do
      list[#list + 1] = " "
    end
  end

  for i, char in ipairs(list) do
    if width ~= nil and i > width then
      break
    end

    local cx = x + i - 1

    if cx >= 1 and cx <= self.width then
      self.char[y][cx] = char
      self.fg[y][cx] = fg or C.text

      if bg ~= nil then
        self.bg[y][cx] = bg
      end
    end
  end
end

function canvas:fill(x, y, width, height, bg)
  for row = y, y + height - 1 do
    self:put(x, row, string.rep(" ", width), C.text, bg)
  end
end

---Write a log line with colour names (&white; ...), cut to a width
function canvas:putCoded(x, y, text, width, bg)
  local fg = C.text
  local column = 0
  local i = 1

  while i <= #text and column < width do
    local code = text:match("^&&?([^;]*);", i)

    if code ~= nil then
      local isBackground = text:sub(i + 1, i + 1) == "&"
      local color = neonScreen.logPalette[code] or tonumber(code)

      if color ~= nil and not isBackground then
        fg = color
      end

      i = i + #code + (isBackground and 3 or 2)
    else
      local char = text:match("^[%z\1-\127\194-\244][\128-\191]*", i)
      self:put(x + column, y, char, fg, bg)
      column = column + 1
      i = i + #char
    end
  end
end

---The rows of the grid as lines with colour codes
---@return string[]
function canvas:lines()
  local lines = {}

  for y = 1, self.height do
    local parts = {}
    local fg, bg = nil, nil

    for x = 1, self.width do
      local char = self.char[y][x]

      if self.bg[y][x] ~= bg then
        bg = self.bg[y][x]
        parts[#parts + 1] = string.format("&&0x%06X;", bg)
      end

      -- A space shows only its background, so its foreground doesn't need a code
      if char ~= " " and self.fg[y][x] ~= fg then
        fg = self.fg[y][x]
        parts[#parts + 1] = string.format("&0x%06X;", fg)
      end

      parts[#parts + 1] = char
    end

    lines[y] = table.concat(parts)
  end

  return lines
end

-- ---------- pieces ----------

---Top edge of a card: title on the left, a value on the right
local function cardTop(cv, x, y, w, title, right, rightColor)
  cv:put(x, y, CH.tl..string.rep(CH.h, w - 2)..CH.tr, C.neon, C.card)
  cv:put(x, y, CH.tl, C.red, C.card)

  if title ~= nil and title ~= "" then
    cv:put(x + 2, y, " "..title.." ", C.text, C.card)
  end

  if right ~= nil and right ~= "" then
    local text = " "..right.." "
    cv:put(x + w - 2 - textLength(text), y, text, rightColor or C.dim, C.card)
  end
end

local function cardFrame(cv, x, y, w, h, title, right, rightColor)
  cv:fill(x, y, w, h, C.card)
  cardTop(cv, x, y, w, title, right, rightColor)
  cv:put(x, y + h - 1, CH.bl..string.rep(CH.h, w - 2)..CH.br, C.neon, C.card)
  cv:put(x + w - 1, y + h - 1, CH.br, C.red, C.card)

  for row = y + 1, y + h - 2 do
    cv:put(x, row, CH.v, C.neon, C.card)
    cv:put(x + w - 1, row, CH.v, C.neon, C.card)
  end
end

---Thin bar: heavy line for the filled part, light line for the rest
local function thinBar(cv, x, y, w, fraction, color, bg)
  local filled = math.max(0, math.min(w, math.floor((fraction or 0) * w + 0.5)))
  cv:put(x, y, string.rep(CH.hh, filled), color, bg)
  cv:put(x + filled, y, string.rep(CH.h, w - filled), C.track, bg)
end

---Label on the left and value on the right of a card row
local function row(cv, x, y, w, label, value, valueColor, bg)
  cv:put(x, y, fit(label, w), C.dim, bg)

  if value ~= nil then
    local text = fit(value, w - textLength(label) - 1)
    cv:put(x + w - textLength(text), y, text, valueColor or C.text, bg)
  end
end

local function duration(seconds)
  seconds = math.max(0, math.floor(seconds))
  local hours, minutes = math.floor(seconds / 3600), math.floor(seconds % 3600 / 60)

  if hours > 0 then
    return string.format("%dh %02dm", hours, minutes)
  end

  return string.format("%dm %02ds", minutes, seconds % 60)
end

---Text and colour of a unit's state
---@param state string
---@return string text
---@return integer color
---@return number|nil chance
local function stateText(state)
  if state == "Controller disabled" then
    return "IDLE", C.na
  elseif state == "Wait cycle" then
    return "WAITING", C.dim
  elseif state == "Needs attention" then
    return "NEEDS ATTENTION", C.red
  elseif state == "Loading" then
    return "LOADING", C.dim
  elseif state == nil or state == "Unused" then
    return "UNUSED", C.na
  end

  local name, chance = tostring(state):match("^State: %[(.-)%] Success: %[([%d%.]+)%%%]$")

  if name == nil then
    return tostring(state):upper(), C.text
  end

  -- A running unit whose dosing is idle still works on its cycle
  local text = (name == "Work" or name == "Idle") and "WORKING" or name:upper()

  return text, (name == "Work" or name == "Idle") and C.green or C.neon, tonumber(chance)
end

local function chanceColor(chance)
  return chance >= 90 and C.green or chance >= 50 and C.yellow or C.orange
end

---Colour of a stock: red under the floor, orange under min (both only in balancing),
---yellow under the target, otherwise green
local function stockColor(unit, ctx)
  if ctx.mode == "singleThreadBalancing" then
    if ctx.floorQty > 0 and unit.level < ctx.floorQty then
      return C.red
    elseif unit.level < ctx.minQty then
      return C.orange
    end
  end

  if unit.target > 0 and unit.level < unit.target then
    return C.yellow
  end

  return C.green
end

-- ---------- cards ----------

local function drawHeader(cv, ctx)
  local W = cv.width
  cv:put(2, 1, ctx.clock, C.na, C.bg)

  local title, by = "WATER LINE CONTROL", "by Sixxo"
  local titleX = math.floor((W - textLength(title) - 1 - textLength(by)) / 2) + 1
  cv:put(titleX, 1, title, C.text, C.bg)
  cv:put(titleX + textLength(title) + 1, 1, by, C.neon, C.bg)

  local label, color = "[ RUNNING ]", C.green

  if not ctx.plantRunning then
    label, color = "[ PLANT STOPPED ]", C.red
  end

  cv:put(W - textLength(label), 1, label, color, C.bg)

  -- Row 2: a line with the control mode and the version
  cv:put(1, 2, string.rep(CH.h, W), C.line, C.bg)
  local mode = " "..(modeLabels[ctx.mode] or tostring(ctx.mode):upper()).." "
  cv:put(2, 2, mode, C.bg, ctx.mode == "disabled" and C.na or C.neon)

  if ctx.version ~= nil then
    local version = " v"..ctx.version.." "
    cv:put(W - textLength(version), 2, version, C.na, C.bg)
  end
end

---Rows each unit takes in the units card, so they fit in the height of the card:
---4 = name, water, bar and a divider; 3 = name, water and bar; 2 = name and bar; 1 = name
local function unitRows(count, maxHeight)
  for _, rows in ipairs({4, 3, 2}) do
    if count * rows + (rows == 4 and 1 or 2) <= maxHeight then
      return rows
    end
  end

  return 1
end

---Bar of a water like the Drilling Fluid bar: heavy line up to the stock, light line for the rest.
---The full bar is the water's limit (its threshold in config.lua); a water without a cap uses the
---highest limit of the other waters. Returns the stock as a fraction of the limit, above 1 when over it
local function stockBar(cv, ctx, unit, x, y, w, color, bg)
  local limit = unit.target > 0 and unit.target or ctx.highestLimit or 0
  local fraction = limit > 0 and unit.level / limit or 0

  thinBar(cv, x, y, w, math.min(1, fraction), color, bg)

  -- Red slider at the stock, like the Drilling Fluid bar of the Meteor program
  local slider = math.min(w - 1, math.floor(math.max(0, math.min(1, fraction)) * w))
  cv:put(x + slider, y, CH.mark, C.red, bg)

  return fraction
end

local function drawUnits(cv, ctx, x, y, w, h)
  local units = ctx.units
  local inner = w - 2

  cardFrame(cv, x, y, w, h, "PURIFICATION UNITS")
  local header = " STOCK / TARGET "
  cv:put(x + w - 2 - textLength(header), y, header, C.text, C.card)

  if #units == 0 then
    cv:put(x + 2, y + 1, "No units enabled in config.lua", C.amber, C.card)
    return
  end

  local rows = unitRows(#units, h)

  for i, unit in ipairs(units) do
    local top = y + 1 + (i - 1) * rows
    local bg = i % 2 == 0 and C.alt or C.face
    local faceRows = rows == 4 and 3 or rows

    cv:fill(x + 1, top, inner, faceRows, bg)

    -- Mark: chosen for the next cycle, or needs attention
    local mark, markColor = " ", C.text

    if unit.needsAttention then
      mark, markColor = CH.cross, C.red
    elseif unit.isNext then
      mark, markColor = CH.next, C.neon
    end

    local state, color, chance = stateText(unit.state)

    -- Baryonic Matter has no unit of its own: T8 makes it
    if unit.tier == 9 then
      state, color, chance = "MADE BY T8", C.na, nil
    end

    local stockColorValue = stockColor(unit, ctx)
    local amount = formatAmount(unit.level)

    if ctx.mode ~= "disabled" then
      amount = amount.." / "..(unit.target > 0 and formatAmount(unit.target) or "no cap")
    end

    -- Row 1: mark, tier, unit name and state with the success chance
    local stateWidth = textLength(state) + (chance ~= nil and 6 or 0)
    local nameWidth = inner - 4 - textLength(unit.label) - stateWidth - 2

    cv:put(x + 1, top, mark, markColor, bg)
    cv:put(x + 3, top, unit.label, C.neon, bg)
    cv:put(x + 4 + textLength(unit.label), top, fit(unit.name, nameWidth), C.text, bg)
    cv:put(x + w - 2 - stateWidth, top, state, color, bg)

    if chance ~= nil then
      cv:put(x + w - 7, top, string.format("%5s", math.floor(chance).."%"), chanceColor(chance), bg)
    end

    -- Row 2: the water (or why the unit needs attention) and its stock
    local water, waterColor = unit.water, C.sub

    if unit.needsAttention and unit.attentionReason ~= "" then
      water, waterColor = unit.attentionReason, C.red
    end

    local barRow = top + 1

    if rows >= 3 then
      cv:put(x + 3, top + 1, fit(water, inner - textLength(amount) - 5), waterColor, bg)
      cv:put(x + w - 2 - textLength(amount), top + 1, amount, stockColorValue, bg)
      barRow = top + 2
    end

    -- Bar row: the stock as a bar, and its percent of the target
    if rows >= 2 then
      local barWidth = inner - 4 - 8
      local fraction = stockBar(cv, ctx, unit, x + 3, barRow, barWidth, stockColorValue, bg)

      if rows == 2 then
        -- No row for the water: the amount goes after the bar
        cv:put(x + w - 2 - 7, barRow, fit(formatAmount(unit.level), 6), stockColorValue, bg)
      else
        -- Rounded down, so 100% means the limit is reached
        cv:put(x + w - 7, barRow, string.format("%5s", math.floor(fraction * 100).."%"), stockColorValue, bg)
      end
    end

    if rows == 4 and i < #units then
      cv:put(x, top + 3, CH.lt..string.rep(CH.h, inner)..CH.rt, C.neon, C.card)
    end
  end
end

local function drawLog(cv, ctx, x, y, w, h)
  local logs = ctx.logs or {}
  local size = h - 2
  local maxOffset = math.max(0, #logs - size)
  local offset = math.min(ctx.logOffset or 0, maxOffset)

  cardFrame(cv, x, y, w, h, "EVENT LOG", #logs > 0 and (#logs.." events") or nil, C.na)

  for i = 1, size do
    local line = logs[i + offset]

    if line ~= nil then
      cv:putCoded(x + 2, y + i, line, w - 4, C.card)
    end
  end

  -- Scroll position on the right edge
  if maxOffset > 0 and size > 1 then
    local position = math.floor(offset / maxOffset * (size - 1) + 0.5)
    cv:put(x + w - 1, y + 1 + position, CH.mark, C.red, C.card)
  end

  return offset
end

local function drawCycle(cv, ctx, x, y, w)
  local inner = w - 4
  local state, color = "RUNNING", C.green

  if not ctx.plantRunning then
    state, color = "STOPPED", C.red
  end

  cardFrame(cv, x, y, w, 6, "CYCLE", state, color)

  if ctx.maxProgress > 0 then
    local left = math.ceil((ctx.maxProgress - ctx.progress) / 20)
    cv:put(x + 2, y + 1, "NEXT CYCLE IN", C.dim, C.card)
    local text = duration(left)
    cv:put(x + w - 2 - textLength(text), y + 1, text, C.text, C.card)
    thinBar(cv, x + 2, y + 2, inner, ctx.progress / ctx.maxProgress, C.neon, C.card)
  else
    cv:put(x + 2, y + 1, "Plant is switched off or has no power", C.red, C.card)
    thinBar(cv, x + 2, y + 2, inner, 0, C.neon, C.card)
  end

  local running, nextUnits = {}, {}

  for _, unit in ipairs(ctx.units) do
    local stateName = stateText(unit.state)

    if stateName == "WORKING" then
      running[#running + 1] = unit.label
    end

    if unit.isNext then
      nextUnits[#nextUnits + 1] = unit.label
    end
  end

  row(cv, x + 2, y + 3, inner, "Running now", #running > 0 and table.concat(running, " ") or "-", #running > 0 and C.green or C.na, C.card)
  row(cv, x + 2, y + 4, inner, "Next cycle", #nextUnits > 0 and table.concat(nextUnits, " ") or "-", #nextUnits > 0 and C.neon or C.na, C.card)

  return 6
end

local function drawControl(cv, ctx, x, y, w)
  local inner = w - 4

  if ctx.mode == "disabled" then
    cardFrame(cv, x, y, w, 3, "CONTROL", "OFF", C.na)
    cv:put(x + 2, y + 1, fit("Quantity Controller is off, units run as switched", inner), C.dim, C.card)
    return 3
  end

  local height = ctx.mode == "singleThreadBalancing" and 6 or 4
  cardFrame(cv, x, y, w, height, "CONTROL", modeLabels[ctx.mode], C.neon)

  local top = y + 1

  if ctx.mode == "singleThreadBalancing" then
    row(cv, x + 2, top, inner, "Floor (fill first)", ctx.floorQty > 0 and formatAmount(ctx.floorQty) or "off", C.red, C.card)
    row(cv, x + 2, top + 1, inner, "Min (then fill to)", formatAmount(ctx.minQty), C.orange, C.card)
    top = top + 2
  end

  row(cv, x + 2, top, inner, "Chosen", ctx.decision ~= nil and ctx.decision ~= "" and ctx.decision or "none", C.neon, C.card)
  cv:put(x + 2, top + 1, fit(ctx.reason or "", inner), C.sub, C.card)

  return height
end

---Height of the statistics card: a summary row, and the cycles of each unit in a grid
local function statsHeight(ctx, w)
  local count = 0

  for _, unit in ipairs(ctx.units) do
    if unit.tier <= 8 then
      count = count + 1
    end
  end

  local columns = math.max(1, math.floor((w - 4) / 12))

  return 3 + math.ceil(count / columns)
end

local function drawStats(cv, ctx, x, y, w, h)
  local inner = w - 4
  local stats = ctx.stats

  cardFrame(cv, x, y, w, h, "STATISTICS", "uptime "..duration(stats.uptime), C.dim)

  -- Summary row
  local parts = {{"Cycles", tostring(stats.cycles)}}

  if stats.uptime >= 600 and stats.cycles > 0 then
    parts[#parts + 1] = {"per hour", string.format("%.1f", stats.cycles / stats.uptime * 3600)}
  end

  local column = x + 2

  for _, part in ipairs(parts) do
    cv:put(column, y + 1, part[1], C.dim, C.card)
    cv:put(column + textLength(part[1]) + 1, y + 1, part[2], C.text, C.card)
    column = column + textLength(part[1]) + textLength(part[2]) + 4
  end

  -- Cycles of each unit, in columns like the miners of the Meteor program
  local columns = math.max(1, math.floor(inner / 12))
  local columnWidth = math.floor(inner / columns)
  local index = 0

  for _, unit in ipairs(ctx.units) do
    if unit.tier <= 8 then
      local rowY = y + 2 + math.floor(index / columns)
      local columnX = x + 2 + (index % columns) * columnWidth
      local count = stats.unitCycles[unit.tier] or 0

      if rowY <= y + h - 2 then
        cv:put(columnX, rowY, unit.label, C.text, C.card)
        cv:put(columnX + 3, rowY, tostring(count), C.neon, C.card)

        if stats.cycles > 0 then
          cv:put(columnX + 4 + #tostring(count), rowY, math.floor(count / stats.cycles * 100 + 0.5).."%", C.na, C.card)
        end
      end

      index = index + 1
    end
  end
end

local function drawFooter(cv, ctx)
  local y = cv.height
  local keys = {{"↑↓", "log"}, {"E", "edit config"}, {"Q", "quit"}}
  local column = 2

  for _, key in ipairs(keys) do
    cv:put(column, y, key[1], C.neon, C.bg)
    cv:put(column + textLength(key[1]) + 1, y, key[2], C.na, C.bg)
    column = column + textLength(key[1]) + textLength(key[2]) + 4
  end

  local legend = {{CH.next, "next cycle", C.neon}, {CH.cross, "needs attention", C.red}}
  local text = 0

  for _, item in ipairs(legend) do
    text = text + 2 + textLength(item[2]) + 3
  end

  column = cv.width - text + 2

  for _, item in ipairs(legend) do
    cv:put(column, y, item[1], item[3], C.bg)
    cv:put(column + 2, y, item[2], C.na, C.bg)
    column = column + 2 + textLength(item[2]) + 3
  end
end

---Width of the left column
function neonScreen.leftWidth(width)
  return math.floor(width * 0.5)
end

---Draw the whole screen
---@param width integer
---@param height integer
---@param ctx table
---@return string[] lines
---@return integer logOffset The scroll position of the log, kept inside the list
function neonScreen.render(width, height, ctx)
  local cv = neonScreen.canvas(width, height)
  local LW = neonScreen.leftWidth(width)
  local RX = LW + 2
  local RW = width - RX + 1
  local bottom = height - 1

  drawHeader(cv, ctx)

  -- Left: the units, down to the bottom
  drawUnits(cv, ctx, 1, 3, LW, bottom - 2)

  -- Right: cycle, control, statistics, then the log down to the bottom
  local y = 3
  y = y + drawCycle(cv, ctx, RX, y, RW)
  y = y + drawControl(cv, ctx, RX, y, RW)

  local height = statsHeight(ctx, RW)

  if bottom - y + 1 - height >= 4 then
    drawStats(cv, ctx, RX, y, RW, height)
    y = y + height
  end

  local logOffset = drawLog(cv, ctx, RX, y, RW, bottom - y + 1)

  drawFooter(cv, ctx)

  return cv:lines(), logOffset
end

return neonScreen
