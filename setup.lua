-- setup.lua of a program: copied into the program's repository by its release workflow, with the
-- repository filled in. Downloads the newest release, unpacks it into /home/<id>/, then lets the
-- installer addon (now on the disk) do the rest: config, registry, shared settings, autostart.
--   wget -f https://raw.githubusercontent.com/<repository>/main/setup.lua && setup
local repository = "Sixxoo/GTNH-OC-Water-Line-Control"
local branch = "main"

local component = require("component")
local filesystem = require("filesystem")
local shell = require("shell")

local function fetch(url)
  local isOk, result = pcall(function ()
    local parts = {}
    for chunk in require("internet").request(url) do parts[#parts + 1] = chunk end
    return table.concat(parts)
  end)
  return isOk and result or nil
end

local function readTable(text)
  local chunk = text and load(text, "=program.lua", "t", {})
  local isOk, value = pcall(chunk or error)
  return isOk and type(value) == "table" and value or nil
end

if not component.isAvailable("internet") then
  io.stderr:write("This computer needs an internet card.\n")
  return
end

local program = readTable(fetch("https://raw.githubusercontent.com/"..repository.."/refs/heads/"..branch.."/program.lua"))

if program == nil then
  io.stderr:write("Could not read program.lua from GitHub.\n")
  return
end

print("Installing "..program.name.." "..program.version)

-- tar for OpenOS, once
if not filesystem.exists("/bin/tar.lua") then
  shell.execute("wget -fq https://raw.githubusercontent.com/mpmxyz/ocprograms/master/home/bin/tar.lua /bin/tar.lua")
end

local folder = "/home/"..program.id
local archive = "/home/"..program.id.."-update.tar"   -- not /tmp: a 64 KB RAM disk
local url = "https://github.com/"..repository.."/releases/download/v"..program.version.."/"..program.archive

filesystem.makeDirectory(folder)
filesystem.remove(archive)
shell.execute("wget -fq "..url.." "..archive)

if not filesystem.exists(archive) or filesystem.size(archive) == 0 then
  filesystem.remove(archive)
  io.stderr:write("Could not download "..url.."\n")
  return
end

-- The player's config before the archive replaces it
local configPath = folder.."/"..(program.config or "config.lua")
local oldConfig = nil
local file = io.open(configPath, "r")
if file then oldConfig = file:read("*a") file:close() end

shell.setWorkingDirectory(folder)
shell.execute("tar -xf "..archive)
filesystem.remove(archive)

local installed = readTable((function ()
  local f = io.open(folder.."/program.lua", "r")
  if f == nil then return nil end
  local text = f:read("*a") f:close() return text
end)())

if installed == nil or installed.version ~= program.version then
  io.stderr:write("The download was incomplete, so some files are missing or cut off. Run setup again.\n")
  return
end

package.path = folder.."/?.lua;"..folder.."/?/init.lua;"..package.path
for name in pairs(package.loaded) do
  if name:match("^addons%.") then package.loaded[name] = nil end
end

for _, line in ipairs(require("addons.installer").finish(installed, oldConfig)) do
  print(line)
end

print("Installed. Start it with: cd "..folder.." && "..(installed.start or "main"))
