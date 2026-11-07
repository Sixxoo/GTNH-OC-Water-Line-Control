-- Checks GitHub for a newer version of Water Line Control and installs it with setup,
-- which keeps your config.lua values. Stop the program with Q first, then run: update
local component = require("component")
local filesystem = require("filesystem")
local internet = require("internet")
local shell = require("shell")

local repository = "Sixxoo/GTNH-OC-Water-Line-Control"
local branch = "main"
local setupTemp = "/tmp/waterline-setup.lua"

---@param question string
---@return boolean
local function ask(question)
  io.write(question.." [y/N] ")
  local answer = io.read()

  return answer ~= nil and answer:lower():sub(1, 1) == "y"
end

---The version on GitHub, or nil and why not
---@return string|nil
---@return string|nil
local function latestVersion()
  if not component.isAvailable("internet") then
    return nil, "this computer has no internet card"
  end

  local isOk, text = pcall(function ()
    local result = ""

    for chunk in internet.request("https://raw.githubusercontent.com/"..repository.."/refs/heads/"..branch.."/version.lua") do
      result = result..chunk
    end

    return result
  end)

  if not isOk then
    return nil, tostring(text)
  end

  local loader = load(text, "=version.lua", "t", {})
  local isLoaded, version = pcall(loader or error)

  if not isLoaded or type(version) ~= "table" or type(version.programVersion) ~= "string" then
    return nil, "GitHub's version.lua can't be read"
  end

  return version.programVersion, nil
end

local installed = "unknown"
local isRead, localVersion = pcall(dofile, "/home/version.lua")

if isRead and type(localVersion) == "table" and localVersion.programVersion then
  installed = localVersion.programVersion
end

print("Installed: "..installed)

local latest, problem = latestVersion()

if latest == nil then
  print("Could not check for a new version: "..problem)
  return
end

print("Latest:    "..latest)

if latest == installed then
  print("You have the latest version.")

  if not ask("Reinstall it anyway?") then
    print("Nothing was changed.")
    return
  end
elseif not ask("Update now?") then
  print("Nothing was changed.")
  return
end

filesystem.remove(setupTemp)
shell.execute("wget -fq https://raw.githubusercontent.com/"..repository.."/refs/heads/"..branch.."/setup.lua "..setupTemp)

if not filesystem.exists(setupTemp) or filesystem.size(setupTemp) == 0 then
  print("Could not download setup; nothing was changed.")
  return
end

shell.execute(setupTemp)
filesystem.remove(setupTemp)
