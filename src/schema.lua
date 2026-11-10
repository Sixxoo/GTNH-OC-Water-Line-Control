-- What config.lua may contain (checked by the config addon), and building the controllers from it
local cfg = require("addons.core").load("config")

local quantityController = require("src.quantity-controller")
local t1controller = require("src.t1-controller")
local t2controller = require("src.t2-controller")
local t3controller = require("src.t3-controller")
local t4controller = require("src.t4-controller")
local t5controller = require("src.t5-controller")
local t6controller = require("src.t6-controller")
local t7controller = require("src.t7-controller")
local t8controller = require("src.t8-controller")

local schema = {}

---A unit's table: enable, plus addresses that are needed only when it is enabled
local function unit(fields)
  fields.enable = cfg.boolean()
  local addresses = {}

  for key, field in pairs(fields) do
    if field.kind == "address" then
      field.optional = true
      addresses[#addresses + 1] = key
    end
  end

  table.sort(addresses)

  return cfg.table(fields, {optional = true, check = function (value)
    if value.enable then
      for _, key in ipairs(addresses) do
        if value[key] == nil then
          return false, key.." is needed when enable = true"
        end
      end
    end

    return true
  end})
end

local amount = function () return cfg.number({min = 0, default = 0}) end

schema.config = cfg.table({
  enableAutoUpdate = cfg.boolean({default = true}),
  enableAutoStart = cfg.boolean({default = true}),
  logLevel = cfg.enum({"debug", "info", "warning", "error"}, {default = "info"}),

  -- Water Line's own Discord messages; missing means none
  discord = cfg.table({
    webhookUrl = cfg.string({optional = true}),
    name = cfg.string({optional = true}),
    mention = cfg.string({optional = true}),
    reminderHours = cfg.number({min = 0, optional = true}),
    needsAttention = cfg.boolean({optional = true}),
    plantStopped = cfg.boolean({optional = true}),
    unitDidNotStart = cfg.boolean({optional = true}),
    errors = cfg.boolean({optional = true}),
    started = cfg.boolean({optional = true}),
  }, {optional = true}),

  controllers = cfg.table({
    t1 = unit({}),
    t2 = unit({}),
    t3 = unit({transposerAddress = cfg.address(), hatchSide = cfg.side({default = "up"})}),
    t4 = unit({hydrochloricAcidTransposerAddress = cfg.address(), sodiumHydroxideTransposerAddress = cfg.address()}),
    t5 = unit({plasmaTransposerAddress = cfg.address(), coolantTransposerAddress = cfg.address()}),
    t6 = unit({transposerAddress = cfg.address()}),
    t7 = unit({inertGasTransposerAddress = cfg.address(), superConductorTransposerAddress = cfg.address(),
      netroniumTransposerAddress = cfg.address(), coolantTransposerAddress = cfg.address()}),
    t8 = unit({maxQuarkCount = cfg.number({min = 1, integer = true, default = 4}), transposerAddress = cfg.address(),
      subMeInterfaceAddress = cfg.address()}),
  }),

  quantityController = cfg.table({
    controlMode = cfg.enum({"disabled", "multiThread", "singleThread", "singleThreadBalancing"}),
    meInterfaceAddress = cfg.address({optional = true}),
    floorQty = amount(),
    minQty = amount(),
    waterThresholds = cfg.table({
      t1 = amount(), t2 = amount(), t3 = amount(), t4 = amount(), t5 = amount(), t6 = amount(), t7 = amount(),
      t8 = amount(), stabilisedBaryonicMatter = amount(),
    }, {optional = true}),
  }, {check = function (value)
    if value.controlMode ~= "disabled" and value.meInterfaceAddress == nil then
      return false, "meInterfaceAddress is needed unless controlMode is \"disabled\""
    end

    return true
  end}),
})

---Config rules for an update: settings that mean something when missing keep the old behaviour
schema.rules = {
  whenMissing = {
    {pattern = "^quantityController%.floorQty$", value = 0, why = "0 is no floor stage, as before"},
    {pattern = "^quantityController%.waterThresholds%.", value = 0, why = "0 is no cap, as before"},
  },
}

---Make the controllers of a checked config
---@param config table From the config addon
---@return table controllers t1..t8 (nil for units that are off)
---@return table quantity The Quantity Controller
function schema.build(config)
  local units = config.controllers
  local controllers = {}

  local function on(key)
    return units[key] ~= nil and units[key].enable == true
  end

  if on("t1") then controllers.t1 = t1controller:new() end
  if on("t2") then controllers.t2 = t2controller:new() end
  if on("t3") then controllers.t3 = t3controller:new(units.t3.transposerAddress, units.t3.hatchSide) end
  if on("t4") then
    controllers.t4 = t4controller:new(units.t4.hydrochloricAcidTransposerAddress, units.t4.sodiumHydroxideTransposerAddress)
  end
  if on("t5") then controllers.t5 = t5controller:new(units.t5.plasmaTransposerAddress, units.t5.coolantTransposerAddress) end
  if on("t6") then controllers.t6 = t6controller:new(units.t6.transposerAddress) end
  if on("t7") then
    controllers.t7 = t7controller:new(units.t7.inertGasTransposerAddress, units.t7.superConductorTransposerAddress,
      units.t7.netroniumTransposerAddress, units.t7.coolantTransposerAddress)
  end
  if on("t8") then
    controllers.t8 = t8controller:new(units.t8.maxQuarkCount, units.t8.transposerAddress, units.t8.subMeInterfaceAddress)
  end

  local qc = config.quantityController
  local thresholds = qc.waterThresholds or {}
  local quantity = quantityController:new(qc.controlMode, qc.meInterfaceAddress, qc.minQty, {
    thresholds.t1 or 0, thresholds.t2 or 0, thresholds.t3 or 0, thresholds.t4 or 0,
    thresholds.t5 or 0, thresholds.t6 or 0, thresholds.t7 or 0, thresholds.t8 or 0,
    thresholds.stabilisedBaryonicMatter or 0,
  }, qc.floorQty or 0)

  return controllers, quantity
end

---Components the config names, for the wiring check: transposers and ME interfaces of enabled units
---@return table[] {{name, type, address}}
function schema.wiring(config)
  local list = {}

  for tier = 1, 8 do
    local unit = (config.controllers or {})["t"..tier]

    if type(unit) == "table" and unit.enable then
      local keys = {}
      for key in pairs(unit) do keys[#keys + 1] = key end
      table.sort(keys)

      for _, key in ipairs(keys) do
        local value = unit[key]

        if type(value) == "string" and key:match("Address$") then
          list[#list + 1] = {name = "[T"..tier.."] "..key, address = value,
            type = key:lower():find("meinterface") and "me_interface" or "transposer"}
        end
      end
    end
  end

  local qc = config.quantityController

  if type(qc) == "table" and qc.controlMode ~= "disabled" and type(qc.meInterfaceAddress) == "string" then
    list[#list + 1] = {name = "[QC] meInterfaceAddress", type = "me_interface", address = qc.meInterfaceAddress}
  end

  return list
end

return schema
