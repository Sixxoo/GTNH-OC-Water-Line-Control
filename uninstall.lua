-- Removes Water Line Control: its files (listed in water-line.files), its autostart line and its entry in
-- /home/.programs. config.lua stays unless you answer y.
package.path = "/home/water-line/?.lua;/home/water-line/?/init.lua;" .. package.path
local installer = require("addons.core").load("installer")

io.write("Remove Water Line Control? [y/N] ")
if (io.read() or ""):lower():sub(1, 1) ~= "y" then
  return
end

io.write("Remove your config.lua too? [y/N] ")
local removeConfig = (io.read() or ""):lower():sub(1, 1) == "y"
local _, lines = installer.uninstall("water-line", removeConfig)

for _, line in ipairs(lines) do
  print(line)
end
