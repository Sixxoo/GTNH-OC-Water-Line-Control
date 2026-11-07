local event = require("event")
local term = require("term")
local internet = require("internet")
local shell = require("shell")
local filesystem = require("filesystem")
local computer = require("computer")

local classBuilder = require("lib.class-builder.index")

---Compare two semver-style version strings (e.g. "1.2.10") component-wise.
---@param a string
---@param b string
---@return number # -1 if a < b, 1 if a > b, 0 if equal
local function compareVersions(a, b)
  local aIter = a:gmatch("%d+")
  local bIter = b:gmatch("%d+")
  while true do
    local aPart = aIter()
    local bPart = bIter()

    if aPart == nil and bPart == nil then
      return 0
    end

    local aNumber = tonumber(aPart) or 0
    local bNumber = tonumber(bPart) or 0

    if aNumber ~= bNumber then
      return aNumber < bNumber and -1 or 1
    end
  end
end

---Wait for one key, without Enter. Keys without a character (Shift, Ctrl) don't count.
---Its key_up is waited for too, so a Q pressed here can't reach the program's Q afterwards
---@param timeout number
---@return string # the key's character in lower case, or "" when the time ran out
local function waitForKey(timeout)
  local deadline = computer.uptime() + timeout

  while computer.uptime() < deadline do
    local signal, _, char, code = event.pull(deadline - computer.uptime(), "key_down")

    if signal ~= nil and char ~= nil and char > 0 then
      event.pull(2, "key_up", nil, nil, code)
      return string.char(char):lower()
    end
  end

  return ""
end

---@param path string
---@return string|nil
local function readFile(path)
  local file = io.open(path, "r")

  if not file then
    return nil
  end

  local text = file:read("*a")
  file:close()

  return text
end

---@param path string
---@param text string
local function writeFile(path, text)
  local file = assert(io.open(path, "w"))
  file:write(text)
  file:close()
end

---config.old.lua, or config.old2.lua, ... if that is taken
---@return string
local function backupName()
  local name, number = "config.old.lua", 1

  while filesystem.exists("/home/"..name) do
    number = number + 1
    name = "config.old"..number..".lua"
  end

  return name
end

---@class ProgramUpdater
---@field program Program
---@field interval number
local programUpdater = {}

---@return ProgramUpdater
function programUpdater:constructor(program)
  self.program = program
  self.interval = 3600

  return self
end

---Get timer for check autoupdate
---@return function callback
---@return number times
---@return number interval
function programUpdater:checkUpdateTimer()
  local isUpdateNeededNotified = false

  local callback = function ()
    if isUpdateNeededNotified == true then
      return
    end

    local isUpdateNeeded = self:isUpdateNeeded()

    if isUpdateNeededNotified == false and isUpdateNeeded == true then
      event.push("log_warning", "[Autoupdate] New version released, update available.");
      event.push("log_warning", "[Autoupdate] Reboot program to auto install it.");
      isUpdateNeededNotified = true
    end
  end

  return callback, math.huge, self.interval
end

---Try auto update program
function programUpdater:autoUpdate()
  local isUpdateNeeded, isConfigUpdateNeeded, isSetupUpdateNeeded, isGTNHUpdateNeeded, remoteVersion = self:isUpdateNeeded()
  local currentVersion = self.program.version ~= nil and self.program.version.programVersion or "nil"

  term.setCursor(1, 1)
  term.write("Current version: "..currentVersion.."\n")
  term.write("Check for new version...\n")

  if isUpdateNeeded == false or remoteVersion == nil then
    term.write("Current version is latest\n")
    os.sleep(3)
    term.clear()
    return
  end

  term.clear()
  term.write("Find new version: "..remoteVersion.programVersion.."\n\n")

  if isConfigUpdateNeeded then
    term.write("This update changes config.lua. Your values are carried into the new one.\n\n")
  end

  if isSetupUpdateNeeded then
    term.write("This update requires changes in the multiblock setup, without which program may not work.\n\n")
  end

  if isGTNHUpdateNeeded then
    term.write("This update needed GTNH version: " .. remoteVersion.gtnhVersion .. " or higher.\n")
    term.write("If you're playing on an older version, the update might break the program.\n\n")
  end

  term.write("Press Y to update, any other key to skip (skips in 60 s)\n")

  if waitForKey(60) ~= "y" then
    term.write("Skipped.\n")
    os.sleep(1)
    term.clear()
    return
  end

  self:tryDownloadTarUtility()

  local url = "https://github.com/"..self.program.repository.."/releases/download/v"..remoteVersion.programVersion.."/"..self.program.archiveName..".tar"

  term.clear()
  term.write("Updating to version: "..remoteVersion.programVersion.."\n")

  local lines = self:downloadAndInstall(url, remoteVersion.programVersion)

  for _, line in ipairs(lines) do
    term.write(line.."\n")
  end

  term.write("\nUpdate completed. Press any key to restart (restarts in 30 s)\n")
  waitForKey(30)

  computer.shutdown(true)
end

---Get latest version number
---@return ProgramVersion|nil
---@private
function programUpdater:getLatestVersionNumber()
  local versionFileUrl = "https://raw.githubusercontent.com/"..self.program.repository.."/refs/heads/"..self.program.version.branch.."/version.lua"

  -- No internet card, a broken connection or an error page from GitHub: no update, and no error,
  -- which would stop the program at the start or make it start again every hour
  local isOk, version = pcall(function ()
    local text = ""

    for chunk in internet.request(versionFileUrl) do
      text = text..chunk
    end

    return load(text, "=version.lua", "t", {})()
  end)

  if not isOk or type(version) ~= "table" or type(version.programVersion) ~= "string"
    or type(version.configVersion) ~= "number" or type(version.setupVersion) ~= "number"
    or type(version.gtnhVersion) ~= "string" then
    return nil
  end

  return version
end

---Check if update is needed
---@return boolean # Need program update
---@return boolean # Need config update
---@return boolean # Need setup update
---@return boolean # Need gtnh update
---@return ProgramVersion|nil # Remote version
---@private
function programUpdater:isUpdateNeeded()
  if self.program.version == nil or internet == nil then
    return false, false, false, false, nil
  end

  local remoteVersion = self:getLatestVersionNumber()

  if remoteVersion == nil then
    return false, false, false, false, nil
  end

  local isUpdateNeeded = compareVersions(remoteVersion.programVersion, self.program.version.programVersion) > 0
  local isConfigUpdateNeeded = remoteVersion.configVersion > self.program.version.configVersion
  local isSetupUpdateNeeded = remoteVersion.setupVersion > self.program.version.setupVersion
  local isGTNHUpdateNeeded = compareVersions(remoteVersion.gtnhVersion, self.program.version.gtnhVersion) > 0

  return isUpdateNeeded, isConfigUpdateNeeded, isSetupUpdateNeeded, isGTNHUpdateNeeded, remoteVersion
end

---Download and install tar utility if not installed
---@private
function programUpdater:tryDownloadTarUtility()
  if filesystem.exists("/bin/tar.lua") then
    return
  end

  local tarManUrl = "https://raw.githubusercontent.com/mpmxyz/ocprograms/master/usr/man/tar.man"
  local tarBinUrl = "https://raw.githubusercontent.com/mpmxyz/ocprograms/master/home/bin/tar.lua"

  shell.setWorkingDirectory("/usr/man")
  shell.execute("wget -fq "..tarManUrl)
  shell.setWorkingDirectory("/bin")
  shell.execute("wget -fq "..tarBinUrl)
end

---Download and install latest version
---@param url string
---@private
function programUpdater:downloadAndInstall(url, expectedVersion)
  shell.setWorkingDirectory("/home")

  -- The player's config.lua is copied before the archive replaces it with the new one
  local oldText = readFile("/home/config.lua")
  local backup = nil

  if oldText ~= nil then
    backup = backupName()
    writeFile("/home/"..backup, oldText)
  end

  -- Not in /tmp: OpenOS keeps /tmp in memory, 64 KB by default, which is too small for the release
  shell.execute("wget -fq "..url.." /home/waterline-update.tar")
  shell.execute("tar -xf /home/waterline-update.tar")
  shell.execute("rm /home/waterline-update.tar")

  -- A download that stopped early unpacks only part of the files
  local warnings = {}
  local isInstalled, installed = pcall(dofile, "/home/version.lua")

  if expectedVersion ~= nil and (not isInstalled or type(installed) ~= "table" or installed.programVersion ~= expectedVersion) then
    table.insert(warnings, "The download was incomplete, so some files are missing or cut off.")
    table.insert(warnings, "Run setup again: wget -f https://raw.githubusercontent.com/"..self.program.repository.."/main/setup.lua && setup")
  end

  if oldText == nil then
    return warnings
  end

  local newText = readFile("/home/config.lua") or ""
  local isLoaded, merger = pcall(dofile, "/home/lib/program-controller/config-merger.lua")
  local merged, report = nil, "the merger couldn't be loaded"

  if isLoaded then
    merged, report = merger.merge(oldText, newText)
  end

  if merged == nil then
    writeFile("/home/config.default.lua", newText)
    writeFile("/home/config.lua", oldText)

    table.insert(warnings, "Kept your config.lua as it was: "..tostring(report))
    table.insert(warnings, "The new one is config.default.lua.")

    return warnings
  end

  writeFile("/home/config.lua", merged)
  filesystem.remove("/home/config.default.lua")

  local lines = warnings
  table.insert(lines, "Your settings are in the new config.lua (your old file is "..backup.."):")

  for _, line in ipairs(merger.describe(report)) do
    table.insert(lines, "  "..line)
  end

  return lines
end

return classBuilder.createClass(programUpdater, programUpdater.constructor, "ProgramUpdater")