-- Water Line's screen, built from neon-ui pieces: the units with their water bars, cycle, control,
-- statistics and the log. Returns the lines for the screen addon
local formatAmount = require("src.format-amount")
local ui = require("addons.core").load("neon-ui")

local neonScreen = {}

neonScreen.colors = ui.colors
neonScreen.logPalette = ui.logPalette
local C = ui.colors

local CH = {
  h = "─", lt = "├", rt = "┤", next = "▶", cross = "✗", mark = "┃",
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

local textLength = ui.length
local fit = ui.fit
local row = ui.row
local duration = ui.duration

function neonScreen.canvas(width, height)
  return ui.canvas(width, height)
end

local function cardFrame(cv, x, y, w, h, title, right, rightColor)
  ui.card(cv, x, y, w, h, title, {right = right, rightColor = rightColor})
end

---Bar without the slider; stockBar adds it where the stock is
local function thinBar(cv, x, y, w, fraction, color, bg)
  ui.bar(cv, x, y, w, fraction, {color = color, bg = bg, slider = false})
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

---How far under its limit a water still counts as full (green)
neonScreen.fullMargin = 2000000

---Colour of a stock (bar, slider-free part and amount): red under floor, orange under min
---(both only in balancing), yellow under the limit minus fullMargin, green from there up and over the limit
local function stockColor(unit, ctx)
  if ctx.mode == "singleThreadBalancing" then
    if ctx.floorQty > 0 and unit.level < ctx.floorQty then
      return C.red
    elseif unit.level < ctx.minQty then
      return C.orange
    end
  end

  if unit.target > 0 and unit.level < unit.target - neonScreen.fullMargin then
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

  -- The pages, after the mode
  if ctx.tabs ~= nil then
    ctx.tabs:draw(cv, 2 + textLength(mode) + 2, 2)
  end

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

  local height = ctx.mode == "singleThreadBalancing" and 5 or 3
  cardFrame(cv, x, y, w, height, "CONTROL", modeLabels[ctx.mode], C.neon)

  local top = y + 1

  if ctx.mode == "singleThreadBalancing" then
    row(cv, x + 2, top, inner, "Floor", ctx.floorQty > 0 and formatAmount(ctx.floorQty) or "off", C.red, C.card)
    row(cv, x + 2, top + 1, inner, "Min", formatAmount(ctx.minQty), C.orange, C.card)
    top = top + 2
  end

  row(cv, x + 2, top, inner, "Chosen", ctx.decision ~= nil and ctx.decision ~= "" and ctx.decision or "none", C.neon, C.card)

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
  local keys = {{"←→", "pages"}, {"↑↓", "log"}, {"E", "edit config"}, {"Q", "quit"}}

  if ctx.tab == "stats" then
    keys = {{"←→", "pages"}, {"E", "edit config"}, {"Q", "quit"}}
  end
  local column = 2

  for _, key in ipairs(keys) do
    cv:put(column, y, key[1], C.neon, C.bg)
    cv:put(column + textLength(key[1]) + 1, y, key[2], C.na, C.bg)
    column = column + textLength(key[1]) + textLength(key[2]) + 4
  end

  local legend = (ctx.tab == nil or ctx.tab == "overview") and {{CH.next, "next cycle", C.neon}, {CH.cross, "needs attention", C.red}} or {}
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

-- ---------- statistics page ----------

local function signed(value)
  if value == nil then
    return "-", C.na
  elseif value >= 0 then
    return "+"..formatAmount(value), C.green
  end

  return "-"..formatAmount(-value), C.red
end

---Cycles: all time, last 24 hours, per hour, and each unit
local function drawCycleTotals(cv, view, x, y, w, h)
  local inner = w - 4
  cardFrame(cv, x, y, w, h, "CYCLES", "all time", C.dim)

  row(cv, x + 2, y + 1, inner, "All time", tostring(view.total), C.text, C.card)
  row(cv, x + 2, y + 2, inner, "Last 24 hours", tostring(view.last24), C.neon, C.card)
  row(cv, x + 2, y + 3, inner, "Per hour (24 h)", string.format("%.1f", view.rate24), C.neon, C.card)

  local top = y + 5
  cv:put(x + 2, top, "UNIT", C.na, C.card)
  local heads = {"ALL", "24 H", "SHARE"}
  local columns = {x + w - 26, x + w - 17, x + w - 8}

  for i, head in ipairs(heads) do
    cv:put(columns[i] + 6 - textLength(head), top, head, C.na, C.card)
  end

  for i, unit in ipairs(view.units) do
    local rowY = top + i

    if rowY > y + h - 2 then
      break
    end

    cv:put(x + 2, rowY, unit.label, C.neon, C.card)
    cv:put(x + 5, rowY, fit(unit.short, columns[1] - x - 6), C.text, C.card)

    local share = view.total > 0 and (math.floor(unit.total / view.total * 100 + 0.5).."%") or "-"
    local values = {tostring(unit.total), tostring(unit.last24), share}

    for c, value in ipairs(values) do
      cv:put(columns[c] + 6 - textLength(value), rowY, value, c == 3 and C.na or C.text, C.card)
    end
  end
end

---Each water over the last 24 hours: now, lowest, highest, change
local function drawWaterHistory(cv, view, x, y, w, h)
  cardFrame(cv, x, y, w, h, "WATER", "last 24 h", C.dim)

  local columns = {x + w - 42, x + w - 32, x + w - 22, x + w - 12}
  local heads = {"NOW", "LOWEST", "HIGHEST", "CHANGE"}

  for i, head in ipairs(heads) do
    cv:put(columns[i] + 8 - textLength(head), y + 1, head, C.na, C.card)
  end

  for i, water in ipairs(view.waters) do
    local rowY = y + 1 + i

    if rowY > y + h - 2 then
      break
    end

    cv:put(x + 2, rowY, water.label, C.neon, C.card)
    cv:put(x + 5, rowY, fit((water.water:gsub(" Water$", "")), columns[1] - x - 6), C.sub, C.card)

    local change, changeColor = signed(water.change)
    local values = {
      {water.now and formatAmount(water.now) or "-", C.text},
      {water.min and formatAmount(water.min) or "-", C.dim},
      {water.max and formatAmount(water.max) or "-", C.dim},
      {change, changeColor},
    }

    for c, value in ipairs(values) do
      cv:put(columns[c] + 8 - textLength(value[1]), rowY, value[1], value[2], C.card)
    end
  end
end

local function drawUptime(cv, view, x, y, w)
  local inner = w - 4
  cardFrame(cv, x, y, w, 5, "UPTIME")
  row(cv, x + 2, y + 1, inner, "This run", duration(view.uptime.session), C.text, C.card)
  row(cv, x + 2, y + 2, inner, "All runs", duration(view.uptime.total), C.text, C.card)
  row(cv, x + 2, y + 3, inner, "Counting since", view.since or "-", C.dim, C.card)
  return 5
end

---Cycles per hour over the last 24 hours as columns, the hour under every third
local function drawHourChart(cv, view, x, y, w, h)
  cardFrame(cv, x, y, w, h, "CYCLES PER HOUR", "last 24 h", C.dim)

  local hours = view.hours
  local count = #hours
  local chartTop, chartBottom = y + 1, y + h - 3
  local rows = chartBottom - chartTop + 1
  local columnWidth = math.max(2, math.floor((w - 6) / count))
  local left = x + 3 + math.floor((w - 6 - columnWidth * count) / 2)
  local highest = 0

  for _, value in ipairs(hours) do
    highest = math.max(highest, value or 0)
  end

  -- a faint baseline
  cv:put(left, chartBottom + 1, string.rep(CH.h, columnWidth * count), C.track, C.card)

  for i, value in ipairs(hours) do
    local columnX = left + (i - 1) * columnWidth
    local height = highest > 0 and math.floor((value or 0) / highest * rows + 0.5) or 0
    local color = i == count and C.neon or C.sub

    for r = 1, height do
      cv:put(columnX, chartBottom - r + 1, string.rep("█", columnWidth - 1), color, C.card)
    end

    if (value or 0) > 0 and height < rows then
      local text = tostring(value)

      if textLength(text) <= columnWidth then
        cv:put(columnX, chartBottom - height, text, C.na, C.card)
      end
    end

    if (count - i) % 3 == 0 and view.hourLabels[i] then
      cv:put(columnX, chartBottom + 2, view.hourLabels[i], i == count and C.neon or C.na, C.card)
    end
  end

  if highest == 0 then
    local text = "No cycles counted in the last 24 hours yet"
    cv:put(x + math.floor((w - textLength(text)) / 2), chartTop + math.floor(rows / 2), text, C.na, C.card)
  end
end

local function drawStatsPage(cv, ctx, bottom)
  local view = ctx.statsView
  local W = cv.width
  local LW = neonScreen.leftWidth(W)
  local RX = LW + 2
  local RW = W - RX + 1
  local chartHeight = math.max(8, math.floor((bottom - 2) * 0.42))
  local topHeight = bottom - 2 - chartHeight

  drawCycleTotals(cv, view, 1, 3, LW, topHeight)

  local uptimeY = 3 + topHeight - 5
  drawWaterHistory(cv, view, RX, 3, RW, topHeight - 5)
  drawUptime(cv, view, RX, uptimeY, RW)

  drawHourChart(cv, view, 1, 3 + topHeight, W, chartHeight)
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

  if ctx.tab == "stats" and ctx.statsView ~= nil then
    drawStatsPage(cv, ctx, bottom)
    drawFooter(cv, ctx)
    return cv:lines(), ctx.logOffset or 0
  elseif ctx.tab == "log" then
    local logOffset = drawLog(cv, ctx, 1, 3, width, bottom - 2)
    drawFooter(cv, ctx)
    return cv:lines(), logOffset
  end

  -- Left: the units, down to the bottom
  drawUnits(cv, ctx, 1, 3, LW, bottom - 2)

  -- Right: cycle, control, statistics, then the log down to the bottom
  local y = 3
  y = y + drawCycle(cv, ctx, RX, y, RW)
  y = y + drawControl(cv, ctx, RX, y, RW)

  -- The log at the bottom, about a third of the screen, never over the cards above
  local logHeight = math.min(bottom - y + 1, math.max(6, math.floor((bottom - 2) / 3)))
  local logOffset = drawLog(cv, ctx, RX, bottom - logHeight + 1, RW, logHeight)

  drawFooter(cv, ctx)

  return cv:lines(), logOffset
end

return neonScreen
