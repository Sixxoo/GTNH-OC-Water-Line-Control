local configManager = require("lib.config-manager.index")
local logger = require("lib.oc-logger.index")

local quantityController = require("src.quantity-controller")
local t1controller = require("src.t1-controller")
local t2controller = require("src.t2-controller")
local t3controller = require("src.t3-controller")
local t4controller = require("src.t4-controller")
local t5controller = require("src.t5-controller")
local t6controller = require("src.t6-controller")
local t7controller = require("src.t7-controller")
local t8controller = require("src.t8-controller")

---@class ControllersConfig
---@field t1? T1Controller
---@field t2? T2Controller
---@field t3? T3Controller
---@field t4? T4Controller
---@field t5? T5Controller
---@field t6? T6Controller
---@field t7? T7Controller
---@field t8? T8Controller

---@class Config
---@field enableAutoUpdate boolean
---@field enableAutoStart? boolean
---@field logger Logger
---@field discord? table
---@field controllers ControllersConfig
---@field quantityController QuantityController

---Check is controller module disabled
---@param value any
---@return boolean
local function isDisabled(value)
  return type(value) == "table" and value.enable == false
end

---Check is quantity control disabled. An unknown mode counts as disabled here, so its own error is the one shown
---@param value any
---@param config table
---@return boolean
local function isQuantityControlDisabled(value, config)
  local activeModes = {multithread = true, singlethread = true, singlethreadbalancing = true}
  local mode = type(config.quantityController) == "table" and config.quantityController.controlMode

  return type(mode) ~= "string" or activeModes[mode:lower()] ~= true
end

---Amount validator for water thresholds
---@param isNullable? boolean
---@return NumberValidator
local function amountValidator(isNullable)
  return configManager.validators.number:new({
    isNullable = isNullable == true,
    min = {value = 0}
  })
end

local configTemplate = {
  enableAutoUpdate = configManager.validators.boolean:new(),
  -- Optional, so a config.lua from before this option still loads. Missing means true
  enableAutoStart = configManager.validators.boolean:new({isNullable = true}),

  logger = configManager.validators.object:new(
    {
      template = {
        name = configManager.validators.string:new(),
        timeZone = configManager.validators.number:new({
          isInteger = {value = true}
        }),
        handlers = configManager.validators.typedObjectList:new({
          templates = {
            -- The old Discord log handler. Still accepted, so a config.lua that has it loads, but it sends nothing:
            -- the discord block replaces it
            ["discord"] = configManager.validators.object:new(
              {
                template = {},
                objectFactory = function ()
                  return {logLevel = "error", messageFormat = "{Message}", log = function () end}
                end
              }
            ),
            ["file"] = configManager.validators.object:new(
              {
                template = {
                  logLevel = configManager.validators.enum:new({
                    "debug", "info", "warning", "error"
                  }),
                  messageFormat = configManager.validators.string:new(),
                  filePath = configManager.validators.string:new(),
                },
                objectFactory = function (value)
                  return logger.handlers.file:new(value.logLevel, value.messageFormat, value.filePath)
                end
              }
            ),
            ["scrollList"] = configManager.validators.object:new(
              {
                template = {
                  logLevel = configManager.validators.enum:new({
                    "debug", "info", "warning", "error"
                  }),
                  logsListSize = configManager.validators.number:new({
                    min = {value = 16}
                  }),
                  -- Optional, so a config.lua from before this option still loads
                  messageFormat = configManager.validators.string:new({isNullable = true}),
                },
                objectFactory = function (value)
                  return logger.handlers.scrollList:new(
                    value.logLevel,
                    value.logsListSize,
                    value.messageFormat or "{Time:%H:%M} {Message}",
                    {["[QC]"] = "cyan"}
                  )
                end
              }
            ),
          }
        }),
      },
      objectFactory = function (value)
        return logger.logger:new(value.name, value.timeZone, value.handlers)
      end
    }
  ),

  -- Optional, so a config.lua from before this option still loads. Missing means no Discord messages
  discord = configManager.validators.object:new({
    isNullable = true,
    template = {
      webhookUrl = configManager.validators.string:new({isNullable = true}),
      name = configManager.validators.string:new({isNullable = true}),
      mention = configManager.validators.string:new({isNullable = true}),
      reminderHours = configManager.validators.number:new({isNullable = true, min = {value = 0}}),
      needsAttention = configManager.validators.boolean:new({isNullable = true}),
      plantStopped = configManager.validators.boolean:new({isNullable = true}),
      unitDidNotStart = configManager.validators.boolean:new({isNullable = true}),
      errors = configManager.validators.boolean:new({isNullable = true}),
      started = configManager.validators.boolean:new({isNullable = true}),
    }
  }),

  controllers = configManager.validators.object:new({
    template = {
      t1 = configManager.validators.object:new({
        skipper = isDisabled,
        template = {
          enable = configManager.validators.boolean:new(),
        },
        objectFactory = function (value)
          if value.enable == false then
            return nil
          end

          return t1controller:new()
        end
      }),

      t2 = configManager.validators.object:new({
        skipper = isDisabled,
        template = {
          enable = configManager.validators.boolean:new(),
        },
        objectFactory = function (value)
          if value.enable == false then
            return nil
          end

          return t2controller:new()
        end
      }),

      t3 = configManager.validators.object:new({
        skipper = isDisabled,
        template = {
          enable = configManager.validators.boolean:new(),
          transposerAddress = configManager.validators.address:new(),
        },
        objectFactory = function (value)
          if value.enable == false then
            return nil
          end

          return t3controller:new(value.transposerAddress)
        end
      }),

      t4 = configManager.validators.object:new({
        skipper = isDisabled,
        template = {
          enable = configManager.validators.boolean:new(),
          hydrochloricAcidTransposerAddress = configManager.validators.address:new(),
          sodiumHydroxideTransposerAddress = configManager.validators.address:new(),
        },
        objectFactory = function (value)
          if value.enable == false then
            return nil
          end

          return t4controller:new(
            value.hydrochloricAcidTransposerAddress,
            value.sodiumHydroxideTransposerAddress
          )
        end
      }),

      t5 = configManager.validators.object:new({
        skipper = isDisabled,
        template = {
          enable = configManager.validators.boolean:new(),
          plasmaTransposerAddress = configManager.validators.address:new(),
          coolantTransposerAddress = configManager.validators.address:new(),
        },
        objectFactory = function (value)
          if value.enable == false then
            return nil
          end

          return t5controller:new(
            value.plasmaTransposerAddress,
            value.coolantTransposerAddress
          )
        end
      }),

      t6 = configManager.validators.object:new({
        skipper = isDisabled,
        template = {
          enable = configManager.validators.boolean:new(),
          transposerAddress = configManager.validators.address:new(),
        },
        objectFactory = function (value)
          if value.enable == false then
            return nil
          end

          return t6controller:new(value.transposerAddress)
        end
      }),

      t7 = configManager.validators.object:new({
        skipper = isDisabled,
        template = {
          enable = configManager.validators.boolean:new(),
          inertGasTransposerAddress = configManager.validators.address:new(),
          superConductorTransposerAddress = configManager.validators.address:new(),
          netroniumTransposerAddress = configManager.validators.address:new(),
          coolantTransposerAddress = configManager.validators.address:new(),
        },
        objectFactory = function (value)
          if value.enable == false then
            return nil
          end

          return t7controller:new(
            value.inertGasTransposerAddress,
            value.superConductorTransposerAddress,
            value.netroniumTransposerAddress,
            value.coolantTransposerAddress
          )
        end
      }),

      t8 = configManager.validators.object:new({
        skipper = isDisabled,
        template = {
          enable = configManager.validators.boolean:new(),
          maxQuarkCount = configManager.validators.number:new({
            isInteger = {value = true},
            min = {value = 1}
          }),
          transposerAddress = configManager.validators.address:new(),
          subMeInterfaceAddress = configManager.validators.address:new(),
        },
        objectFactory = function (value)
          if value.enable == false then
            return nil
          end

          return t8controller:new(
            value.maxQuarkCount,
            value.transposerAddress,
            value.subMeInterfaceAddress
          )
        end
      }),
    }
  }),

  quantityController = configManager.validators.object:new({
    template = {
      controlMode = configManager.validators.enum:new({
        "disabled", "multiThread", "singleThread", "singleThreadBalancing"
      }),
      meInterfaceAddress = configManager.validators.address:new({
        skipper = isQuantityControlDisabled
      }),
      -- Optional, so a config.lua from before this option still loads. Missing means no floor stage
      floorQty = amountValidator(true),
      minQty = amountValidator(),
      -- A missing threshold, or 0, means no cap
      waterThresholds = configManager.validators.object:new({
        isNullable = true,
        template = {
          t1 = amountValidator(true),
          t2 = amountValidator(true),
          t3 = amountValidator(true),
          t4 = amountValidator(true),
          t5 = amountValidator(true),
          t6 = amountValidator(true),
          t7 = amountValidator(true),
          t8 = amountValidator(true),
          stabilisedBaryonicMatter = amountValidator(true),
        }
      }),
    },
    objectFactory = function (value)
      local thresholds = value.waterThresholds or {}

      return quantityController:new(
        value.controlMode,
        value.meInterfaceAddress,
        value.minQty,
        {
          thresholds.t1 or 0, thresholds.t2 or 0, thresholds.t3 or 0, thresholds.t4 or 0,
          thresholds.t5 or 0, thresholds.t6 or 0, thresholds.t7 or 0, thresholds.t8 or 0,
          thresholds.stabilisedBaryonicMatter or 0
        },
        value.floorQty or 0
      )
    end
  })
}

return configTemplate