-- Installs or updates Water Line Control in /home
--   wget -f https://raw.githubusercontent.com/Sixxoo/GTNH-OC-Water-Line-Control/main/setup.lua && setup
-- An existing config.lua is kept: its values are carried into the new config.lua, and the old file is kept as config.old.lua
local shell = require("shell")
local filesystem = require("filesystem")
local component = require("component")
local internet = require("internet")

local repository = "Sixxoo/GTNH-OC-Water-Line-Control"
local branch = "main"
local archiveName = "WaterLineControl"
local home = "/home"
-- Not in /tmp: OpenOS keeps /tmp in memory, 64 KB by default, which is too small for the release
local archive = "/home/waterline-update.tar"

local tarManUrl = "https://raw.githubusercontent.com/Navatusein/GTNH-OC-Installer/refs/heads/main/tar/tar.man"
local tarBinUrl = "https://raw.githubusercontent.com/Navatusein/GTNH-OC-Installer/refs/heads/main/tar/tar.lua"

---Get the version.lua of the branch
---@return table|nil
local function getLatestVersion()
  local success, request = pcall(internet.request, "https://raw.githubusercontent.com/"..repository.."/refs/heads/"..branch.."/version.lua")

  if not success or not request then
    return nil
  end

  local result = ""

  local readSuccess = pcall(function ()
    for chunk in request do
      result = result..chunk
    end
  end)

  if not readSuccess then
    return nil
  end

  local loader = load(result)

  if loader == nil then
    return nil
  end

  local loadSuccess, version = pcall(loader)

  if not loadSuccess or type(version) ~= "table" then
    return nil
  end

  return version
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

---@param question string
---@return boolean
local function ask(question)
  io.write(question.." [y/N] ")
  local answer = io.read()

  return answer ~= nil and answer:lower():sub(1, 1) == "y"
end

---config.old.lua, or config.old2.lua, ... if that is taken
---@return string
local function backupName()
  local name, number = "config.old.lua", 1

  while filesystem.exists(home.."/"..name) do
    number = number + 1
    name = "config.old"..number..".lua"
  end

  return name
end

---Whether /home/.shrc already starts the program
---@param text string
---@return boolean
local function hasAutostart(text)
  for line in (text.."\n"):gmatch("(.-)\r?\n") do
    if line:match("^%s*main%s*$") or line:match("&&%s*main%s*$") then
      return true
    end
  end

  return false
end

---The computer's redstone card. A Redstone I/O block doesn't sit in a slot
---@return table|nil
local function redstoneCard()
  for address in component.list("redstone") do
    local isOk, slot = pcall(component.slot, address)

    if isOk and type(slot) == "number" and slot >= 0 then
      return component.proxy(address)
    end
  end

  return nil
end

if not component.isAvailable("internet") then
  io.stderr:write("This computer needs an internet card.\n")
  return
end

local version = getLatestVersion()

if version == nil then
  io.stderr:write("Could not read the latest version from GitHub.\n")
  return
end

print("Installing Water Line Control "..version.programVersion)

if not filesystem.exists("/bin/tar.lua") then
  shell.setWorkingDirectory("/usr/man")
  shell.execute("wget -fq "..tarManUrl)
  shell.setWorkingDirectory("/bin")
  shell.execute("wget -fq "..tarBinUrl)
end

local url = "https://github.com/"..repository.."/releases/download/v"..version.programVersion.."/"..archiveName..".tar"

filesystem.remove(archive)
shell.execute("wget -fq "..url.." "..archive)

if not filesystem.exists(archive) or filesystem.size(archive) == 0 then
  filesystem.remove(archive)
  io.stderr:write("Could not download "..url.."\n")
  return
end

-- The player's config.lua is copied before the archive replaces it with the new one
local oldText = readFile(home.."/config.lua")
local backup = nil

if oldText ~= nil then
  backup = backupName()
  writeFile(home.."/"..backup, oldText)
end

shell.setWorkingDirectory(home)
shell.execute("tar -xf "..archive)
filesystem.remove(archive)

-- A download that stopped early unpacks only part of the files
local isInstalled, installed = pcall(dofile, home.."/version.lua")

if not isInstalled or type(installed) ~= "table" or installed.programVersion ~= version.programVersion then
  io.stderr:write("The download was incomplete, so some files are missing or cut off. Run setup again.\n")
end

if oldText ~= nil then
  local newText = readFile(home.."/config.lua") or ""
  local isLoaded, merger = pcall(dofile, home.."/lib/program-controller/config-merger.lua")
  local merged, report = nil, "the merger couldn't be loaded"

  if isLoaded then
    merged, report = merger.merge(oldText, newText)
  end

  if merged ~= nil then
    writeFile(home.."/config.lua", merged)
    filesystem.remove(home.."/config.default.lua")
    print("Your settings are in the new config.lua (your old file is "..backup.."):")

    for _, line in ipairs(merger.describe(report)) do
      print("  "..line)
    end
  else
    writeFile(home.."/config.default.lua", newText)
    writeFile(home.."/config.lua", oldText)
    print("Kept your config.lua as it was: "..tostring(report))
    print("The new one is config.default.lua.")
  end
end

-- Auto-start: OpenOS runs /home/.shrc when its shell starts
local shrc = home.."/.shrc"

if hasAutostart(readFile(shrc) or "") then
  print("Auto-start is on ("..shrc..").")
elseif ask("Start Water Line Control when the computer boots?") then
  local file = assert(io.open(shrc, "a"))
  file:write("cd /home && main\n")
  file:close()
  print("Auto-start on. Delete the main line in "..shrc.." to turn it off.")
end

local card = redstoneCard()

if card ~= nil then
  if card.getWakeThreshold() > 0 then
    print("Wake on redstone is on.")
  elseif ask("Turn the computer on when it gets a redstone signal (after a power loss)?") then
    card.setWakeThreshold(1)
    print("Wake on redstone on. Wire a slow redstone clock (a pulse every 30 to 60 s) to the computer or rack.")
  end
end

print("Installed. Start it with: main")
