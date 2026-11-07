-- Messages to a Discord channel through a webhook: a unit needs attention, the plant stopped,
-- a chosen unit didn't start, the program had an error, and the program started.
-- Requests go straight to the internet card and are never waited for: each one is checked
-- on the next ticks, so a slow or unreachable Discord can't hold up the water line.
-- Nothing here may stop the program, so every public function catches its own errors.
-- The sending part comes from Willshaper/GTNH-PowerDisplay.
local component = require("component")
local computer = require("computer")
local event = require("event")
local filesystem = require("filesystem")

local discord = {}

local FLAP_COOLDOWN = 1800 -- seconds before an alert that cleared is sent again
local REQUEST_TIMEOUT = 30 -- seconds before a request without an answer is given up
local MAX_OPEN = 2 -- requests open at once (an internet card allows 4 connections)
local MAX_QUEUE = 20 -- messages waiting to be sent; the oldest are dropped beyond this
local MAX_ATTEMPTS = 3 -- tries per message for errors other than rate limits
local MAX_RATE_LIMITED = 5 -- tries per message when Discord answers "too many requests"
local RETRY_WAIT = 60 -- seconds before a message that failed to send is tried again
local MAX_EMBEDS = 10 -- Discord takes at most 10 embeds per message
local CLOCK_FILE = "/tmp/.waterline_clock"
local RED, GREEN, GRAY = 0xE74C3C, 0x2ECC71, 0x95A5A6
local HEADERS = {
  ["Content-Type"] = "application/json",
  ["User-Agent"] = "DiscordBot (https://github.com/Sixxoo/GTNH-OC-Water-Line-Control, 1)",
}

-- From config.lua, via discord.configure()
local settings = {}
local url, name, mention = "", "", ""

local cardChecked = false -- whether the internet card was checked since config.lua was loaded
local cardOk = false
local disabled = false -- Discord rejected the webhook; off until config.lua is loaded again
local warned = {} -- problems already logged, so each is logged once

local alerts = {} -- kind -> {since, reported, lastSent, reminderTitle, description} while the alert is on
local lastReport = {} -- kind -> uptime of its last message (kept after it clears)
local pending = {} -- embeds waiting for the next tick, so what happens together goes in one message

local queue = {} -- messages waiting to be sent: {body, attempts, limited, notBefore}
local open = {} -- requests sent and not answered yet: {handle, item, started}
local waitUntil = 0 -- uptime before which nothing is sent (Discord's rate limit)
local timerId = nil

-- Hides the webhook URL (and any other web address) in text that is shown:
-- anyone who has it can post to the channel
local function hideUrls(text)
  text = tostring(text)
  if url:find("^https?://") then
    local start, stop = text:find(url, 1, true)
    while start do
      text = text:sub(1, start - 1) .. "<webhook URL>" .. text:sub(stop + 1)
      start, stop = text:find(url, start + 13, true)
    end
  end
  return (text:gsub("https?://[^%s\"'<>]+", "<URL>"))
end

-- A problem with sending, e.g. no internet card. Logged once
local function warn(key, message)
  if not warned[key] then
    warned[key] = true
    event.push("log_warning", "[Discord] " .. message)
  end
end

-- JSON --------------------------------------------------------------------------

local ARRAY = {} -- metatable that marks a table as a JSON array, so an empty one is []
local function array(list)
  return setmetatable(list, ARRAY)
end

local ESCAPES = {['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r",
  ["\t"] = "\\t"}

-- A JSON string of plain ASCII. OpenComputers sends the body in the server's default
-- charset, so everything else is written as \uXXXX, decoded from UTF-8 by hand.
-- A byte that isn't valid UTF-8 becomes U+FFFD.
local function encodeString(text)
  if not text:find('[%c"\\\128-\255]') then
    return '"' .. text .. '"'
  end
  local out = {'"'}
  local i, size = 1, #text
  while i <= size do
    local byte = text:byte(i)
    if byte < 0x80 then
      local char = string.char(byte)
      if ESCAPES[char] then
        table.insert(out, ESCAPES[char])
      elseif byte < 0x20 or byte == 0x7F then
        table.insert(out, string.format("\\u%04x", byte))
      else
        table.insert(out, char)
      end
      i = i + 1
    else
      local length, code
      if byte >= 0xC2 and byte <= 0xDF then
        length, code = 2, byte - 0xC0
      elseif byte >= 0xE0 and byte <= 0xEF then
        length, code = 3, byte - 0xE0
      elseif byte >= 0xF0 and byte <= 0xF4 then
        length, code = 4, byte - 0xF0
      end
      for k = 1, (length or 1) - 1 do
        local follow = text:byte(i + k)
        if not follow or follow < 0x80 or follow > 0xBF then
          length = nil
          break
        end
        code = code * 64 + (follow - 0x80)
      end
      -- Overlong forms, surrogates and anything above U+10FFFF aren't valid either
      if length == 3 and (code < 0x800 or (code >= 0xD800 and code <= 0xDFFF)) then
        length = nil
      elseif length == 4 and (code < 0x10000 or code > 0x10FFFF) then
        length = nil
      end
      if not length then
        table.insert(out, "\\ufffd")
        i = i + 1
      elseif code >= 0x10000 then
        -- Above U+FFFF JSON needs a surrogate pair
        code = code - 0x10000
        table.insert(out, string.format("\\u%04x\\u%04x", 0xD800 + code // 0x400, 0xDC00 + code % 0x400))
        i = i + length
      else
        table.insert(out, string.format("\\u%04x", code))
        i = i + length
      end
    end
  end
  table.insert(out, '"')
  return table.concat(out)
end

local function encode(value)
  local kind = type(value)
  if kind == "string" then
    return encodeString(value)
  elseif kind == "number" then
    if value == math.floor(value) and math.abs(value) < 2^53 then
      return string.format("%d", value)
    end
    return string.format("%.14g", value)
  elseif kind == "boolean" then
    return tostring(value)
  elseif kind == "table" then
    local parts = {}
    if getmetatable(value) == ARRAY or value[1] ~= nil then
      for _, item in ipairs(value) do
        table.insert(parts, encode(item))
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for key in pairs(value) do
      table.insert(keys, key)
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
      table.insert(parts, encodeString(key) .. ":" .. encode(value[key]))
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end

discord.encode = encode -- for testing

-- Message text --------------------------------------------------------------------

-- Cuts text to at most `limit` bytes without splitting a UTF-8 character
local function cut(text, limit)
  if #text <= limit then
    return text
  end
  local stop = limit
  while stop > 0 and text:byte(stop + 1) >= 0x80 and text:byte(stop + 1) < 0xC0 do
    stop = stop - 1
  end
  return text:sub(1, stop)
end

-- "2h 05m", "45m", "30s"
local function duration(seconds)
  seconds = math.floor(seconds)
  if seconds >= 3600 then
    return string.format("%dh %02dm", seconds // 3600, (seconds % 3600) // 60)
  elseif seconds >= 60 then
    return string.format("%dm", seconds // 60)
  end
  return string.format("%ds", seconds)
end

-- The real time, read from when a file was last written (nil if it can't be)
local function realTime()
  local ok, modified = pcall(function()
    local file = io.open(CLOCK_FILE, "w")
    if not file then
      return nil
    end
    file:close()
    return tonumber(filesystem.lastModified(CLOCK_FILE))
  end)
  if ok and modified and modified > 0 then
    return modified / 1000
  end
  return nil
end

-- Current time for the embeds, e.g. "2026-10-29T14:02:11Z" (nil without a real clock)
local function isoTime()
  local now = realTime()
  if not now then
    return nil
  end
  local t = os.date("!*t", math.floor(now))
  return string.format("%04d-%02d-%02dT%02d:%02d:%02dZ", t.year, t.month, t.day, t.hour, t.min, t.sec)
end

-- The content and allowed_mentions for the mention setting. Only the users and roles in
-- it are pinged.
local function mentionParts()
  local text = mention
  if text:match("^%s*%d+%s*$") then
    text = "<@" .. text:match("%d+") .. ">" -- a bare user id
  end
  local users, roles, parse = array({}), array({}), array({})
  for id in text:gmatch("<@!?(%d+)>") do
    table.insert(users, id)
  end
  for id in text:gmatch("<@&(%d+)>") do
    table.insert(roles, id)
  end
  if text:find("@everyone", 1, true) or text:find("@here", 1, true) then
    table.insert(parse, "everyone")
  end
  return cut(text, 1000), {parse = parse, users = users, roles = roles}
end

-- Warns once about anything in the mention setting that can't ping, e.g. a plain
-- "@Willshaper": Discord only pings user and role IDs, @here and @everyone
local function checkMention()
  if mention:match("^%s*%d+%s*$") then
    return -- a bare user id
  end
  local rest = mention:gsub("<@[!&]?%d+>", ""):gsub("@everyone", ""):gsub("@here", "")
  rest = rest:match("^%s*(.-)%s*$")
  if rest ~= "" then
    warn("mention", '"' .. cut(rest, 20) .. '" in mention won\'t ping, it needs an ID')
  end
end

-- Sending -----------------------------------------------------------------------

local function closeOpen()
  for _, request in ipairs(open) do
    pcall(request.handle.close)
  end
  open = {}
end

-- Whether this computer can reach Discord at all (warns why not, once)
local function checkCard()
  if not component.isAvailable("internet") then
    warn("card", "No internet card in this computer")
    return false
  end
  local ok, enabled = pcall(component.getPrimary("internet").isHttpEnabled)
  if ok and enabled == false then
    warn("http", "HTTP is off in the server's OpenComputers config")
    return false
  end
  return true
end

local function active()
  if url == "" or disabled then
    return false
  end
  if not cardChecked then
    cardChecked = true
    cardOk = checkCard()
  end
  return cardOk
end

local function enqueue(body)
  table.insert(queue, {body = body, attempts = 0, limited = 0, notBefore = 0})
  while #queue > MAX_QUEUE do
    table.remove(queue, 1)
  end
end

-- The HTTP status from a failed connection. Java reports 4xx/5xx answers as an error
-- ("Server returned HTTP response code: 429 for URL: ..."), and a 404 as just the URL.
local function codeFromError(problem)
  local code = tonumber(problem:match("response code: (%d%d%d)"))
  if not code and (problem:find("FileNotFound", 1, true) or problem:match("^%s*<webhook URL>%s*$")) then
    code = 404
  end
  return code
end

-- Seconds from a Retry-After header (header names are matched in any case)
local function retryAfter(headers)
  if type(headers) ~= "table" then
    return nil
  end
  for key, value in pairs(headers) do
    if type(key) == "string" and key:lower() == "retry-after" then
      if type(value) == "table" then
        value = value[1]
      end
      local seconds = tonumber(value)
      if seconds then
        return math.min(math.max(seconds, 1), 600)
      end
    end
  end
  return nil
end

-- What happened to a sent message: done, retried later, or dropped
local function handleResult(item, code, problem, headers, now)
  if disabled then
    return
  end
  if code and code >= 200 and code < 300 then
    warned.send = nil -- a later failure is worth a warning again
    return
  end
  if code == 401 or code == 403 or code == 404 then
    disabled = true
    queue = {}
    warn("rejected", "Webhook rejected (HTTP " .. code .. "), check webhookUrl")
    return
  end
  if code == 429 then
    waitUntil = now + (retryAfter(headers) or 5)
    item.limited = item.limited + 1
    if item.limited < MAX_RATE_LIMITED then
      table.insert(queue, 1, item)
    end
    return
  end
  item.attempts = item.attempts + 1
  warn("send", "Sending failed (" .. (code and ("HTTP " .. code) or cut(hideUrls(problem), 30)) .. "), trying again")
  if item.attempts < MAX_ATTEMPTS then
    item.notBefore = now + RETRY_WAIT * item.attempts
    table.insert(queue, 1, item)
  end
end

-- Checks the open requests and closes the ones that are answered or took too long
local function poll(now)
  local still = {}
  local done = {}
  for _, request in ipairs(open) do
    local finished, code, problem, headers = false, nil, nil, nil
    local ok, connected = pcall(request.handle.finishConnect)
    if not ok then
      finished = true
      problem = hideUrls(connected)
      code = codeFromError(problem)
    elseif connected then
      local answered, status, _, responseHeaders = pcall(request.handle.response)
      if answered and status then
        finished, code, headers = true, tonumber(status), responseHeaders
      end
    end
    if not finished and now - request.started >= REQUEST_TIMEOUT then
      finished, problem = true, "no answer after " .. REQUEST_TIMEOUT .. "s"
    end
    if finished then
      pcall(request.handle.close)
      table.insert(done, {request.item, code, problem, headers})
    else
      table.insert(still, request)
    end
  end
  open = still
  -- Handled in reverse, so retried messages go back to the front of the queue in order
  for i = #done, 1, -1 do
    handleResult(done[i][1], done[i][2], done[i][3], done[i][4], now)
  end
end

local function send(now)
  while #open < MAX_OPEN and queue[1] and now >= waitUntil and now >= queue[1].notBefore do
    if not component.isAvailable("internet") then
      cardChecked = false -- the card was removed; warns once and stops
      if not active() then
        queue = {}
      end
      return
    end
    local item = table.remove(queue, 1)
    local ok, handle, reason = pcall(component.getPrimary("internet").request, url, item.body, HEADERS)
    if ok and handle then
      table.insert(open, {handle = handle, item = item, started = now})
    else
      handleResult(item, nil, ok and (reason or "request refused") or handle, nil, now)
      return
    end
  end
end

-- Messages with the waiting embeds, at most MAX_EMBEDS each; red ones ping the mention setting
local function flush()
  while #pending > 0 do
    local embeds = {}
    while #pending > 0 and #embeds < MAX_EMBEDS do
      table.insert(embeds, table.remove(pending, 1))
    end
    local time = isoTime() -- only now: reading the clock writes a file
    local author = "Water Line Control"
    if name ~= "" then
      author = cut(author .. " - " .. name, 200)
    end
    local red = false
    for _, each in ipairs(embeds) do
      each.author, each.timestamp = {name = author}, time
      red = red or each.color == RED
    end
    local body = {embeds = embeds, allowed_mentions = {parse = array({})}}
    if red and mention ~= "" then
      body.content, body.allowed_mentions = mentionParts()
    end
    enqueue(encode(body))
  end
end

local function embed(color, title, description)
  if not active() then
    return
  end
  local item = {title = cut(title, 250), color = color}
  if description and description ~= "" then
    item.description = cut(description, 2000)
  end
  table.insert(pending, item)
end

-- Whether a kind of message is switched on in config.lua (on unless set to false)
local function isOn(setting)
  return settings[setting] ~= false
end

-- Reminders for alerts that are still on
local function remind(now)
  local reminder = (tonumber(settings.reminderHours) or 0) * 3600
  if reminder <= 0 then
    return
  end
  for _, state in pairs(alerts) do
    if state.reported and state.reminderTitle and now - state.lastSent >= reminder then
      state.lastSent = now
      embed(RED, state.reminderTitle, state.description .. " For " .. duration(now - state.since) .. ".")
    end
  end
end

-- Every second: reminders, then send what is waiting and check what was sent
local function tick()
  local now = computer.uptime()
  poll(now)
  remind(now)
  flush()
  send(now)
end

-- Public --------------------------------------------------------------------------

-- Wraps a public function so an error in it is logged once instead of reaching the
-- program. "interrupted" (Ctrl+Alt+C) still stops the program.
local function guarded(fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then
      if err == "interrupted" then
        error(err, 0)
      end
      warn("bug", "Error: " .. hideUrls(err))
    end
  end
end

-- Takes the discord settings from config.lua (when the program starts, and every time it starts
-- again after an error). A rejected webhook is tried again and problems are logged again.
discord.configure = guarded(function(config)
  config = config or {}
  settings = config
  local newUrl = config.webhookUrl or ""
  if newUrl ~= url then
    queue = {} -- messages for the old webhook (or none) aren't sent to the new one
    pending = {}
  end
  url = newUrl
  name = config.name or ""
  mention = config.mention or ""
  disabled, cardChecked, waitUntil, warned = false, false, 0, {}
  if url ~= "" then
    checkMention()
  end
end)

-- Starts the timer that sends. Once per run of the program, not when it starts again after an error
discord.start = guarded(function()
  alerts, lastReport, pending = {}, {}, {}
  if timerId == nil then
    timerId = event.timer(1, guarded(tick), math.huge)
  end
end)

-- Something is wrong (red, pings). `kind` tells alerts apart, e.g. "attention:T3". Sent once
-- while it lasts, and again at most every FLAP_COOLDOWN after it cleared. With reminderTitle,
-- a reminder follows every reminderHours.
discord.alert = guarded(function(kind, setting, title, description, reminderTitle)
  if not isOn(setting) or url == "" then
    return
  end
  local now = computer.uptime()
  local state = alerts[kind]
  if not state then
    state = {since = now, reported = false}
    alerts[kind] = state
  end
  if state.reported or (lastReport[kind] and now - lastReport[kind] < FLAP_COOLDOWN) then
    return
  end
  state.reported, state.lastSent = true, now
  state.reminderTitle, state.description = reminderTitle, description or ""
  lastReport[kind] = now
  embed(RED, title, description)
end)

-- Something is right again (green), only when its alert had been sent
discord.clear = guarded(function(kind, setting, title, description)
  local state = alerts[kind]
  alerts[kind] = nil
  if state ~= nil and state.reported and isOn(setting) then
    embed(GREEN, title, description)
  end
end)

-- An alert that no longer applies, without a message
discord.forget = guarded(function(kind)
  alerts[kind] = nil
end)

-- Something to know (gray)
discord.info = guarded(function(setting, title, description)
  if isOn(setting) and url ~= "" then
    embed(GRAY, title, description)
  end
end)

-- Sends what is waiting before the program ends, for at most `seconds`
discord.finish = guarded(function(seconds)
  local deadline = computer.uptime() + seconds
  tick()
  while (#queue > 0 or #open > 0) and computer.uptime() < deadline do
    os.sleep(0.5)
    tick()
  end
end)

-- Stops the timer and closes open requests when the program ends
discord.stop = guarded(function()
  if timerId ~= nil then
    event.cancel(timerId)
    timerId = nil
  end
  closeOpen()
  queue, pending = {}, {}
end)

return discord
