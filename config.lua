local config = {
  enableAutoUpdate = true, -- Look for a new version when the program starts, and ask before installing it
  enableAutoStart = true, -- Switch the Water Purification Plant on when the program starts. Stopping the program switches it off

  logLevel = "info", -- Lowest level on the screen and in logs.log: "debug", "info", "warning" or "error"

  discord = { -- Messages to a Discord channel through a webhook. Needs an internet card
    webhookUrl = "", -- Channel settings > Integrations > Webhooks > New Webhook > Copy Webhook URL. "" is off
    name = "", -- Shown in each message, to tell several computers apart
    mention = "", -- Pinged on red messages: a user "<@123456789>" or a role "<@&123456789>". "" is nobody
    reminderHours = 0, -- Hours between reminders while a unit still needs attention or the plant is still stopped. 0 is none
    needsAttention = true, -- A unit needs attention, and is back in use
    plantStopped = true, -- The Water Purification Plant stopped, and runs again
    unitDidNotStart = true, -- A unit was chosen for 2 cycles in a row but didn't start, and starts again
    errors = true, -- The program had an error, runs again, or stopped after 5 minutes of errors
    started = true -- The program started
  },

  controllers = {
    t1 = { -- Controller for T1 Filtered Water (Grade 1)
      enable = true -- Enable module for T1 water
    },

    t2 = { -- Controller for T2 Ozonated Water (Grade 2)
      enable = true -- Enable module for T2 water
    },

    t3 = { -- Controller for T3 Flocculated Water (Grade 3)
      enable = true, -- Enable module for T3 water
      transposerAddress = "5dcf2167-a9de-4f5a-8727-8287e7e4d98e", -- Address of transposer which provide Polyaluminium Chloride
      hatchSide = "down" -- Side of the transposer with the unit's input hatch: "up", "down", "north", "south", "west" or "east"
    },

    t4 = { -- Controller for T4 pH Neutralized Water (Grade 4)
      enable = false, -- Enable module for T4 water
      hydrochloricAcidTransposerAddress = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", -- Address of transposer which provide Hydrochloric Acid
      sodiumHydroxideTransposerAddress = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" -- Address of transposer which provide Sodium Hydroxide Dust
    },

    t5 = { -- Controller for T5 Extreme-Temperature Treated Water (Grade 5)
      enable = false, -- Enable module for T5 water
      plasmaTransposerAddress = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", -- Address of transposer which provide Helium Plasma
      coolantTransposerAddress = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" -- Address of transposer which provide Super Coolant
    },

    t6 = { -- Controller for T6 Ultraviolet Treated Electrically Neutral Water (Grade 6)
      enable = false, -- Enable module for T6 water
      transposerAddress = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" -- Address of transposer which provide Lenses
    },

    t7 = { -- Controller for T7 Degassed Decontaminant-Free Water (Grade 7)
      enable = false, -- Enable module for T7 water
      inertGasTransposerAddress = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", -- Address of transposer which provide Inert Gas
      superConductorTransposerAddress = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", -- Address of transposer which provide Super Conductor
      netroniumTransposerAddress = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", -- Address of transposer which provide Molten Neutronium
      coolantTransposerAddress = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" -- Address of transposer which provide Super Coolant
    },

    t8 = { -- Controller for T8 Subatomically Perfect Water (Grade 8)
      enable = false, -- Enable module for T8 water
      maxQuarkCount = 4, -- Maximum number of each quark in the sub AE
      transposerAddress = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", -- Address of transposer which provide Quarks
      subMeInterfaceAddress = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" -- Address of me interface which connected to sub AE
    }
  },

  quantityController = { -- Decides which units run, from the amount of each water in the ME network
    controlMode = "singleThreadBalancing", -- "disabled", "multiThread", "singleThread" or "singleThreadBalancing"
    meInterfaceAddress = "0604d547-0b75-4990-bd55-4ac86f1df51d", -- Address of me interface on the network which stores the water

    -- singleThreadBalancing picks one unit each cycle, in this order:
    -- 1. A water under floorQty: the lowest tier runs
    -- 2. A water under minQty: the lowest tier runs
    -- 3. Otherwise the water with the least stock (under its threshold) runs
    floorQty = 1000000, -- Every water is filled to this first (singleThreadBalancing)
    minQty = 8000000, -- Then every water is filled to this (singleThreadBalancing). At least one cycle's input (parallels * 1000), more builds a reserve
    waterThresholds = { -- Amount to keep stocked, in L. 0: no cap, the water keeps being made
      t1 = 32000000,
      t2 = 32000000,
      t3 = 32000000,
      t4 = 32000000,
      t5 = 32000000,
      t6 = 32000000,
      t7 = 32000000,
      t8 = 32000000,
      stabilisedBaryonicMatter = 32000000 -- Made by T8, needed to realign quark catalysts
    }
  }
}

return config