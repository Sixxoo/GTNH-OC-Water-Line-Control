# GTNH-OC-Water-Line-Control

This is a fork of [Willshaper/GTNH-OC-Water-Line-Control](https://github.com/Willshaper/GTNH-OC-Water-Line-Control) (singlethread fork),
which is based on the `develop` branch of [Navatusein/GTNH-OC-Water-Line-Control](https://github.com/Navatusein/GTNH-OC-Water-Line-Control/tree/develop).
It adds the **Quantity Controller** from [ehami/gtnh-oc-water-line-control](https://github.com/ehami/gtnh-oc-water-line-control),
which can run the water line single threaded: one Purification Unit per cycle, chosen by how much of each water is in your ME network.

What the fork adds:
- The [Quantity Controller](#quantity-controller) with four modes: `disabled`, `multiThread`, `singleThread` and `singleThreadBalancing`.
- `singleThreadBalancing` fills every water to `floorQty`, then to `minQty`, lowest tier first, then keeps the least-stocked water running. A threshold of 0 means no cap. See [how it picks a unit](#balancing).
- T1 and T2 modules, so the Clarifier and the Ozonation unit can be switched on and off too.
- Units that stop because something is missing stay off ("Needs attention"), so the Quantity Controller never switches them back on. Switch one back on by hand once it's fixed.
- A coloured screen: each water's stock and threshold, the units the Quantity Controller chose (`▶`), and a countdown to the next cycle.
- The program switches the Water Purification Plant back on when it starts (`enableAutoStart`), so stopping it to edit `config.lua` no longer leaves the plant off.
- The log on the screen shows the time, which units the Quantity Controller chose and why, and when a unit or the plant stops.
- Auto update and the installer use this fork's releases.

## Addons

Water Line Control is built on [**GTNH-OC-Addons**](https://github.com/Sixxoo/GTNH-OC-Addons), shared parts used by all my OpenComputers programs.
The addons it needs are bundled into each release (`addons/` in the install folder), nothing extra to download.
They are listed in [`addons.lua`](addons.lua).

| Addon | Version | What it does here |
|---|---|---|
| [`core`](https://github.com/Sixxoo/GTNH-OC-Addons/tree/main/addons/core) | 1.1 | Loads the addons and their settings (always included) |
| [`config`](https://github.com/Sixxoo/GTNH-OC-Addons/tree/main/addons/config) | 1.0 | Checks `config.lua` and lists every mistake, edit with E, keeps your values on update |
| [`clock`](https://github.com/Sixxoo/GTNH-OC-Addons/tree/main/addons/clock) | 1.1 | Real time with your time zone for the screen and the log |
| [`event-log`](https://github.com/Sixxoo/GTNH-OC-Addons/tree/main/addons/event-log) | 1.0 | The log on the screen (coloured, repeats folded) and `logs.log` |
| [`screen`](https://github.com/Sixxoo/GTNH-OC-Addons/tree/main/addons/screen) | 1.0 | Draws the screen without flicker and fits the resolution to the monitor |
| [`neon-ui`](https://github.com/Sixxoo/GTNH-OC-Addons/tree/main/addons/neon-ui) | 1.0 | The neon look: cards, bars, header and footer |
| [`recovery`](https://github.com/Sixxoo/GTNH-OC-Addons/tree/main/addons/recovery) | 1.2 | Restarts after an error with a countdown, switches the plant off after 5 minutes of errors |
| [`installer`](https://github.com/Sixxoo/GTNH-OC-Addons/tree/main/addons/installer) | 1.0 | Install, update, `update-all` and `uninstall` |
| [`autostart`](https://github.com/Sixxoo/GTNH-OC-Addons/tree/main/addons/autostart) | 1.0 | Starts the program when the computer boots, wake on redstone |

> [!CAUTION]
> For GTNH **2.9** and newer only.
> Its `config.lua` has new settings (`t1`, `t2` and `quantityController`), so a config from the original program will not work.

> [!CAUTION]
> The fluid transfer rate of an OpenComputers Transposer depends on the Fluid Regulator it was crafted with in an Assembler.
> Use transposers made with at least an LuV Fluid Regulator. A weaker one moves less fluid per transfer than the program needs.
>
> ![Transposer](/docs/transposer.png)

## Content

- [Addons](#addons)
- [Information](#information)
- [Installation](#installation)
- [Water Line Setup](#water-line-setup)
- [Quantity Controller](#quantity-controller)
- [Configuration](#configuration)
- [Credits](#credits)

<a id="information"></a>

## Information

Program is designed to automate the water line from T3 to T8 water, and can switch T1 and T2 on and off.
Program is modular, you can choose which water types you want to automate.
The Quantity Controller can also decide which units run, from the amount of each water in your ME network.
It can send messages to Discord when a unit needs attention, the plant stops, or the program has an error, see [Discord messages](#discord).
And there is also the possibility of auto update at startup.

#### Controls

<kbd>Q</kbd> - Closing the program

<kbd>E</kbd> - Edit `config.lua` while the program runs, see [Changing the config while it runs](#live-edit)

<kbd>Arrow Left</kbd> / <kbd>Arrow Right</kbd>, <kbd>Tab</kbd>, <kbd>1</kbd> <kbd>2</kbd> <kbd>3</kbd> or a touch on the tab - Switch pages

<kbd>Arrow Up</kbd> - Scroll the log up

<kbd>Arrow Down</kbd> - Scroll the log down

#### Interface

![Interface](/docs/interface-neon.png)

The screen fits its width to the screen's shape at 35 rows (made for a 5 x 3 screen, at least 80 x 25 works too).

- Header: the time, the control mode, and `[ RUNNING ]` or `[ PLANT STOPPED ]`.
- **Purification Units**: each enabled unit with its state ("Working" with the success chance, "Waiting", "Idle" or "Needs attention"), its water and the stock against its target.
  The full bar is the water's limit (its threshold in `waterThresholds`, a water without a cap uses the highest limit of the others); the percent is the stock against that limit and goes above 100% when the stock is over it.
  Stock is red under `floorQty`, orange under `minQty` (both only in `singleThreadBalancing`), yellow under its limit minus 2M, and green from 2M under its limit up and over it. A red slider marks the stock on the bar.
- `▶` marks the units the Quantity Controller chose for the next cycle, `✗` a unit that needs attention (see [Quantity Controller](#quantity-controller)).
- **Event Log** (bottom right): newest at the top, scroll with the arrow keys, see [Configuration](#configuration).
- **Cycle**: time to the next cycle as a bar, the units running now and the units chosen for the next cycle.
- **Control**: the amounts of the control mode and the unit the Quantity Controller chose (why is in the log).

The screen has three pages, shown next to the control mode on the second row:

1. **Overview**: everything above.
2. **Statistics**: kept in `stats.dat`, so they survive restarts and updates.
   Cycles all time, in the last 24 hours and per hour, and per unit; each water's stock now, its lowest and highest in the last 24 hours
   and how much it changed; uptime of this run and of all runs; and a chart of cycles per hour over the last 24 hours.
3. **Log**: the event log over the whole screen.

![Statistics](/docs/interface-stats.png)

<a id="installation"></a>

## Installation

> [!CAUTION]
> On Java 8 the download from GitHub can fail, because Java rejects GitHub's certificates.
> Then the only way to install the program is to copy its files to the computer by hand.

To install program, you need a server (in a Server Rack) with:
- Graphics Card (Tier 3): 1
- Central Processing Unit (CPU) (Tier 3): 1
- Memory (Tier 3.5): 2
- Component Bus (Tier 3): 1
- Hard Disk Drive (Tier 3) (4MB): 1
- EEPROM (Lua BIOS): 1
- Internet Card: 1

![Computer setup](/docs/server.png)

It has to be a server: a whole line connects about 30 components (machines, transposers, ME interfaces and the computer's own parts).
A Tier 3 CPU allows 16, and only a server can hold the Component Bus that adds 16 more.

1. In the rack's GUI, link the server's connector to the side of the rack where the cable to the screen and the machines comes in.
   A screen or cable touching the rack is not enough: until it is linked, the server only sees its own parts and the screen stays blank.
2. Install OpenOS on the hard drive: boot from an OpenOS floppy (a Disk Drive mountable in the rack, or a normal computer with a disk drive), run `install` and pick the hard drive.
3. Run this command to install the fork. It downloads the latest release into `/home/water-line`.

```shell
wget -f https://raw.githubusercontent.com/Sixxoo/GTNH-OC-Water-Line-Control/main/setup.lua && setup
```

If there is a `/home/water-line/config.lua` already, your values are carried into the new one, with its new settings and comments, and the installer lists what changed.
A new setting that means something when it is left out gets the value that keeps what the program did: a missing `floorQty` becomes `0` (no floor stage), not the default.
Your old file is kept as `config.old.lua` (or `config.old2.lua` and so on). If your file can't be read, it stays as it is and the new one is saved as `config.default.lua`.

The installer then asks for your time zone (once per computer, kept in `/home/addons.cfg` for every program),
whether to start Water Line Control when the computer boots, and, with a Redstone Card in the computer,
whether a redstone signal should turn the computer on (see below).

The installer of the original program (`pastebin run ESUAMAGx`) installs the original, without the Quantity Controller.

To start the program, run:

```shell
cd /home/water-line && main
```

To start it whenever the computer boots, answer yes to the installer's question.

To turn the server back on after a power loss, put a Redstone Card in it and answer yes to the installer's question
(or run `lua` and enter `component.redstone.setWakeThreshold(1)`; the card remembers it).
Then wire a slow redstone clock (one pulse every 30 to 60 seconds) to the Server Rack. Each pulse turns the server on if it is off, and it starts the program with the line above.
Keep the clock away from the screen: a redstone pulse turns an OpenComputers screen off and on.

#### Updating and removing

With `enableAutoUpdate = true`, the program checks for a new version when it starts and asks before installing it.
`update-all` checks every program installed with the addons installer and updates them after one yes.
Both keep your values in the new `config.lua`, as described above.

`cd /home/water-line && uninstall` removes the files Water Line Control installed (listed in `water-line.files`),
its auto-start line and its entry in `/home/.programs`. It asks before removing `config.lua`.

#### Coming from 2.1.x

Up to 2.1.7 the program was installed straight into `/home`. 2.2.0 lives in `/home/water-line`.
Install it with the setup command above (the old version can't update itself to the new place), then copy your settings over
and remove the old files:

```shell
cp /home/config.lua /home/water-line/config.old.lua
rm -r /home/src /home/lib /home/main.lua /home/version.lua /home/update.lua /home/uninstall.lua /home/waterline.files
```

Then open `/home/water-line/config.lua` and set your addresses and limits (your old values are in `config.old.lua` next to it).
The `logger` block is gone: the time zone is asked by the installer, and `logLevel` sets what the screen and `logs.log` show.

#### When something goes wrong

If an error stops the program, for example a unit that can't be read while its chunk reloads, or a mistake in `config.lua`,
it shows the error, waits 30 seconds and starts again. The plant keeps running in the meantime, and units that need attention stay off.
The screen counts down to the next try. For a mistake in `config.lua`, press E to fix it: the program tries it as soon as you close the editor.
If it still fails after 5 minutes, it switches the plant off and stops: fix the problem, then run `main`.

Press Q to stop the program at any time. This switches the plant off too.

#### Computer setup

The program interface is configured for a 3x2 monitor.

![Computer setup](/docs/computer-setup.png)

<a id="water-line-setup"></a>

## Water Line Setup

> [!NOTE]  
> For easy copying of addresses, use "Analyzer" from the OpenComputers mod. Right-click on the component, its address will be written in the chat. 
> If you click on it, it will be copied.
>
> <img src="docs/analyzer.png" alt="Analyzer" width="120"/>

### Water Purification Plant

#### Components

To build a setup, you will need:
- Adapter: 1
- MFU: 1

#### Description

The main multiblock of the line. The cycle of the entire line is read from it.

> [!CAUTION]
> Water Purification Plant must be connected.

The controller is connected via MFU to keep it accessible.

#### Example setup

![Water Purification Plant](/docs/water-purification-plant.png)

<a id="t1-t2"></a>

### [T1] Filtered Water (Grade 1) and [T2] Ozonated Water (Grade 2)

#### Components

To build a setup, you will need for each of them:
- Adapter: 1
- MFU: 1

#### Description

These modules only switch the unit on and off, so the Quantity Controller can choose them.
They don't supply anything: keep the Clarifier stocked with Activated Carbon Filter Mesh and the Ozonation unit with Ozone yourself.
Enable them with `enable = true` in the `config.lua`. You only need them when you use the Quantity Controller.

The controllers are connected via MFU, like the Water Purification Plant.

> [!CAUTION]
> The Ozonation unit explodes if its input hatch holds more than 1,024,000 L of Ozone.

#### T1 and T2 Config part

```Lua
t1 = { -- Controller for T1 Filtered Water (Grade 1)
  enable = false -- Enable module for T1 water
},

t2 = { -- Controller for T2 Ozonated Water (Grade 2)
  enable = false -- Enable module for T2 water
},
```

### [T3] Flocculated Water (Grade 3)

> [!CAUTION]
> Use transposers made with at least an LuV Fluid Regulator.

#### Components

To build a setup, you will need:
- Adapter: 1
- Transposer: 1
- MFU: 1

#### Description

To use the module for t3 water in the `config.lua`
file you need to enable the module by changing `enable = false` to `enable = true`. 
You must also specify the address of the transposer in the `transposerAddress` field, to which the input hatch and the tank with the
Polyaluminium chloride are connected. `hatchSide` is the side of the transposer with the input hatch: `"up"` (the default, transposer under the hatch),
`"down"` (transposer above the hatch), `"north"`, `"south"`, `"west"` or `"east"`. The tank can be on any other side.

The controller is connected via MFU to keep it accessible.

Each cycle the program puts exactly 900,000 L of Polyaluminium Chloride into the hatch: +10% success for every full 100,000 L,
and any amount over a full 100,000 L cuts the success hard. A hatch that holds less (a LuV hatch holds 512,000 L) gets it in parts
of full 100,000 L, since the unit uses up the hatch every second. With less than 900,000 L in the tank it uses the full 100,000 L parts
it has and marks T3 "Needs attention".

#### T3 Config part

```Lua
t3 = { -- Controller for T3 Flocculated Water (Grade 3)
  enable = false, -- Enable module for T3 water
  transposerAddress = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", -- Address of transposer which provide Polyaluminium Chloride
  hatchSide = "up" -- Side of the transposer with the unit's input hatch
},
```

#### Example setup

![T3 Setup](/docs/t3-setup.png)

### [T4] pH Neutralized Water (Grade 4)

> [!CAUTION]
> Use transposers made with at least an LuV Fluid Regulator.

#### Components

To build a setup, you will need:
- Adapter: 1
- Transposer: 2

#### Description

To use the module for t4 water in the `config.lua`
file you need to enable the module by changing `enable = false` to `enable = true`. 
It is also necessary to specify transposer addresses in 
the fields `hydrochloricAcidTransposerAddress` and `sodiumHydroxideTransposerAddress`, 
they are respectively located above the input hatch for Hydrochloric Acid next to the 
tank and above the input bus for Sodium Hydroxide next to the interface.

#### T4 Config part

```Lua
t4 = { -- Controller for T4 pH Neutralized Water (Grade 4)
  enable = false, -- Enable module for T4 water
  hydrochloricAcidTransposerAddress = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", -- Address of transposer which provide Hydrochloric Acid
  sodiumHydroxideTransposerAddress = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" -- Address of transposer which provide Sodium Hydroxide Dust
},
```

#### Example setup

![T4 Setup](/docs/t4-setup.png)

### [T5] Extreme-Temperature Treated Water (Grade 5)

> [!CAUTION]
> Use transposers made with at least an LuV Fluid Regulator.

#### Components

To build a setup, you will need:
- Adapter: 1
- Transposer: 2

#### Description

To use the module for t5 water in the `config.lua`
file you need to enable the module by changing `enable = false` to `enable = true`. 
It is also necessary to specify transposer addresses in 
the fields `plasmaTransposerAddress` and `coolantTransposerAddress`, 
they are respectively located below the input hatch for Helium Plasma next to the 
tank and below the input hatch for Super Coolant next to the tank.

#### T5 Config part

```Lua
t5 = { -- Controller for T5 Extreme-Temperature Treated Water (Grade 5)
  enable = false, -- Enable module for T5 water
  plasmaTransposerAddress = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", -- Address of transposer which provide Helium Plasma
  coolantTransposerAddress = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" -- Address of transposer which provide Super Coolant
},
```

#### Example setup

![T5 Setup](/docs/t5-setup.png)

### [T6] Ultraviolet Treated Electrically Neutral Water (Grade 6)

#### Components

To build a setup, you will need:
- Adapter: 1
- Transposer: 1

#### Description

To use the module for t6 water in the `config.lua`
file you need to enable the module by changing `enable = false` to `enable = true`. 
You must also specify the address of the transposer in the `transposerAddress` field, which is located above the Lens Housing and to which the chest with lenses connected.

The chest should contain all 9 lenses: Orundum Lens, Amber Lens, Aer Lens, Emerald Lens, Mana Diamond Lens, Blue Topaz Lens, Amethyst Lens, Fluor-Buergerite Lens, Dilithium Lens.

> [!NOTE]  
> Dilithium Lens is optional.

![Chest With Lenses](/docs/chest-with-lenses.png)

#### T6 Config part

```Lua
t6 = { -- Controller for T6 Ultraviolet Treated Electrically Neutral Water (Grade 6)
  enable = false, -- Enable module for T6 water
  transposerAddress = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" -- Address of transposer which provide Lenses
},
```

#### Example setup

![T6 Setup](/docs/t6-setup.png)

### [T7] Degassed Decontaminant-Free Water (Grade 7)

> [!CAUTION]
> Use transposers made with at least an LuV Fluid Regulator.

#### Components

To build a setup, you will need:
- Adapter: 1
- Transposer: 4
- MFU: 1

#### Description

> [!NOTE]  
> The structure needs a `Degasser Control Hatch` to form. The program doesn't use it: it reads the control signal from the controller.

To use the module for t7 water in the `config.lua`
file you need to enable the module by changing `enable = false` to `enable = true`.
You must also specify the addresses of the transposers: 
`inertGasTransposerAddress` here is the address of the transposer that will supply Helium, Neon, Krypton, Xenon.
`superConductorTransposerAddress` here is the address of the transposer that will supply Superconductor Base.
`netroniumTransposerAddress` here is the address of the transposer that will supply Molten Neutronium.
`coolantTransposerAddress` here is the address of the transposer that will supply Super Coolant.

The controller is connected via MFU to keep it accessible.

#### T7 Config part

```Lua
t7 = { -- Controller for T7 Degassed Decontaminant-Free Water (Grade 7)
  enable = false, -- Enable module for T7 water
  inertGasTransposerAddress = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", -- Address of transposer which provide Inert Gas
  superConductorTransposerAddress = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", -- Address of transposer which provide Super Conductor
  netroniumTransposerAddress = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", -- Address of transposer which provide Molten Neutronium
  coolantTransposerAddress = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" -- Address of transposer which provide Super Coolant
},
```

#### Example setup

![T7 Setup](/docs/t7-setup.png)

### [T8] Subatomically Perfect Water (Grade 8)

#### Components

To build a setup, you will need:
- Adapter: 2
- Transposer: 1
- MFU: 1

#### Description

To use the module for t8 water in the `config.lua`
file you need to enable the module by changing `enable = false` to `enable = true`.
You must also specify the address of the transposer in the `transposerAddress` 
field, which is located under the hv input bus and to which the interface with the Quarks connected.
Also the address of the adapter connected to me interface in the `subMeInterfaceAddress` field.
Also in the configs you can change the number of quarks the computer must support in this field ` maxQuarkCount`.
There you need to specify the number of quarks that are in the subnet. So if you put 7 quarks of each type in the subnet. 
3 will go into the interface, then you need to specify 4. Because that's how many are left in the subnet.

The controller is connected via MFU to keep it accessible.

The idea is that a separate subnet is made for quarks. The Absolute Baryonic Perfection Purification Unit returns unused quarks and 2 
Unaligned Quark Releasing Catalysts after crafting is complete. The computer looks to see which quarks are less than the specified 
number (`maxQuarkCount` in the default configs is 4) and orders them. That is, the subnet must have at least 2 CPUs and a 
Hyper-Intensity Laser Engraver connected to order quarks. It is possible without a subnet, but the condition is that the computer can order quarks. 
Stabilised Baryonic Matter can be fed into the subsystem or directly into the Laser Engraver.

> [!NOTE]  
> Maximum 42 infinity ingots used per cycle. But usually less. Consumption can be 6, 18, 42 ingots per cycle. Depends on luck.

#### T8 Config part

```Lua
t8 = { -- Controller for T8 Subatomically Perfect Water (Grade 8)
  enable = false, -- Enable module for T8 water
  maxQuarkCount = 4, -- Maximum number of each quark in the sub AE
  transposerAddress = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", -- Address of transposer which provide Quarks
  subMeInterfaceAddress = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" -- Address of me interface which connected to sub AE
}
```

#### Example setup

![T8 Setup 1](/docs/t8-setup-1.png)

![T8 Setup 2](/docs/t8-setup-2.png)

<a id="quantity-controller"></a>

## Quantity Controller

The Quantity Controller reads how much of each water, and of Stabilised Baryonic Matter, is in your ME network.
About 10 seconds before each cycle of the Water Purification Plant ends, it chooses which units may start in the next cycle,
and turns every other unit off. A unit that is turned off still finishes the cycle it is running.

Single threaded, each unit can get enough parallels to use all the power of the Water Purification Plant.
Parallels are set in each unit's GUI. GregTech caps the water a unit makes at 2,147,483,647 L per cycle, so more than about 2.39 million parallels gain nothing.
Catalysts (Polyaluminium Chloride, Ozone, plasma, Super Coolant, quark catalysts, Molten Infinity and so on) don't scale with parallels,
so fewer cycles with more parallels use less of them. See [Singlethreaded Waterline](https://wiki.gtnewhorizons.com/wiki/Water_Line#Singlethreaded_Waterline) on the wiki.

#### Components

- Adapter: 1, next to an ME Interface on the network which stores the water
- Adapters with MFUs for the T1 and T2 controllers, see [T1 and T2](#t1-t2)

Only units with an enabled module (`enable = true`) are controlled.
In the single thread modes, every unit of the line needs its module, or the units without one keep running on their own.

#### Modes

The names can be written in any case, so `SingleThreadBalancing` works too. A misspelled mode is refused, and the error lists the valid ones.

- `"disabled"` - No quantity control. Every enabled unit runs every cycle, like the original program.
- `"multiThread"` - Every tier below its threshold runs.
- `"singleThread"` - The lowest tier below its threshold runs. This is how the wiki's singlethreaded waterline works.
- `"singleThreadBalancing"` - One unit runs each cycle, chosen in three stages, see below.

A threshold of `0`, or one left out, means no cap: that water keeps being made.
In `singleThread` a water without a cap always wins, so no tier above it runs. The log warns about this at start-up.
In `multiThread` its unit runs every cycle.

<a id="balancing"></a>

#### How singleThreadBalancing picks a unit

About 10 seconds before each cycle ends, the program picks **one** unit for the next cycle.
It checks three stages in order, and the first one that applies decides:

1. **Floor** (`floorQty`, e.g. 1M): if any water is under the floor, the **lowest tier** of those runs.
   Every water gets a basic stock first, from the bottom up.
2. **Min** (`minQty`, e.g. 8M): if any water is under min, the **lowest tier** of those runs.
3. **Least stock**: otherwise the water with the **least stock** runs, until it reaches its threshold (e.g. 32M). A lower tier wins a tie.

Only units that are enabled in `config.lua`, not marked "Needs attention", and whose water is under its threshold take part.
Each unit uses the water of the tier below it: when that runs low, it runs fewer parallels that cycle.

Example with a 1M floor, an 8M min and 32M thresholds: with G1 at 500k and G2 at 550k, T1 runs (both are under the floor, T1 is lower).
Once both are over 1M, T1 runs until G1 has 8M, then T2 until G2 has 8M.
After that the water with the least stock runs each cycle, so the waters climb to 32M together.

A water without a cap (threshold `0`) also takes part in stage 3, so it climbs along with the others.
Once every capped water is at its threshold, it gets every cycle, and the plant never goes idle.
When a capped water drops under its threshold again, it usually has less stock than the uncapped one by then, so it runs first.

Keep `floorQty` below `minQty`, and `minQty` below every threshold: the log warns at start-up when they are out of order.
`minQty` should be at least one cycle's input (your highest parallel count × 1000).
Players usually start with few parallels: a higher `minQty` builds a reserve before you raise them.
`floorQty = 0` skips the floor stage, and a `config.lua` without `floorQty` has none.

T8 also runs when Stabilised Baryonic Matter is below its threshold. T8 makes it, and it's needed to realign quark catalysts.

A unit that ran out of materials, or has another fault such as a wrong lens slot, is shown as "Needs attention", and the Quantity Controller doesn't switch it on again.
The yellow warning just before it in the log says what is wrong.
Once it's fixed, switch the unit back on by hand (soft mallet, or the button in its GUI): the program then uses it again.
In the multi and single thread modes the program switches it off again within a few seconds and keeps it off until it chooses that unit.
Switched on in the last few seconds of a cycle, it can start once next to the unit the Quantity Controller chose.

#### Quantity Controller Config part

```Lua
quantityController = { -- Decides which units run, from the amount of each water in the ME network
  controlMode = "disabled", -- "disabled", "multiThread", "singleThread" or "singleThreadBalancing"
  meInterfaceAddress = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", -- Address of me interface on the network which stores the water

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
```

> [!NOTE]
> A unit's output only reaches the ME network when its cycle ends, after the next cycle is already chosen.
> So the tier that just ran is often chosen once more before the new water counts.

<a id="configuration"></a>

## Configuration

General configuration in file `config.lua`
The configuration of water line modules is described in paragraph [Water Line Setup](#water-line-setup),
and the `quantityController` settings in [Quantity Controller](#quantity-controller).

<a id="live-edit"></a>

#### Changing the config while it runs

Press E while the program runs: `config.lua` opens in the editor. Save with Ctrl+S and close with Ctrl+W.
The water line keeps running while you edit, and the Quantity Controller keeps choosing units.

- Changes to the mode, `floorQty`, `minQty`, the thresholds, the log and Discord are used at once.
- Changes to which units are enabled, their transposers, `maxQuarkCount`, the ME interface address, or switching the Quantity Controller on or off
  need the program to start again. It asks: Y starts it again in place, without switching the plant off. N keeps the running settings until the next start.
- If the file has a mistake, it is shown: E edits it again, any other key keeps the settings that are running.

Look for a new version when the program starts, and ask before installing it.

```lua
enableAutoUpdate = true, -- Look for a new version when the program starts, and ask before installing it
```

The program switches the Water Purification Plant off whenever it stops, for example when you stop it to edit `config.lua` or when it crashes.
The plant still finishes the cycle it is running, but doesn't start a new one.
With `enableAutoStart` the program switches the plant back on when it starts. Set it to `false` to switch the plant on by hand.
A `config.lua` without this line counts as `true`.

```lua
enableAutoStart = true, -- Switch the Water Purification Plant on when the program starts. Stopping the program switches it off
```

What the screen's log and `logs.log` show. The time zone is set once per computer in `/home/addons.cfg`
(the installer asks for it; change it with `addons-config`).

```lua
logLevel = "info", -- Lowest level on the screen and in logs.log: "debug", "info", "warning" or "error"
```

The log on the screen shows the time and what the program does, newest on top. Scroll it with the arrow keys.
- `[QC] Next cycle: T2 (G2 7.3M, lowest stock)` - the units the Quantity Controller chose, each time the choice changes, and why ("under floor", "under min", "lowest stock").
- `[T3] Needs attention, switch it on when fixed` and `[T3] Switched on by hand, back in use`.
- `[Line] Plant stopped (switched off or no power)` and `[Line] Water Purification Plant switched on`.
- `[Line] Cycle started: T2` - the units running in each new cycle. This is a `debug` line, shown with `logLevel = "debug"`.
  "Cycle started: no units" while a unit was chosen means GregTech didn't start it, usually because an input (water, Ozone, a catalyst) was missing.

The same line again doesn't add a new row, the newest row gets a count instead, e.g. `[Line] Cycle started: T2 (x4)`.
`logs.log` keeps every line; at 64 KB it becomes `logs.log.old` and a new file starts.

<a id="discord"></a>

#### Discord messages

The program can post to a Discord channel when something needs you. The computer needs an internet card.

1. In Discord, open the channel's settings > Integrations > Webhooks > New Webhook, and Copy Webhook URL.
2. Put it in `webhookUrl` in the `discord` block of `config.lua`.
3. Optionally set `name` to tell several computers apart, and `mention` to be pinged. Discord only pings IDs:
   turn on Settings > Advanced > Developer Mode, then right-click yourself > Copy User ID, and write it as `"<@123456789>"` (a role is `"<@&123456789>"`).

```lua
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
```

| Message | Colour | When |
|---|---|---|
| T3 needs attention / is back in use | red, pings / green | A unit stopped after a fault, with what is wrong (e.g. "Not enough Polyaluminium Chloride for craft"), and when you switched it back on. |
| Water Purification Plant stopped / runs again | red, pings / green | The plant stopped (switched off, or no power), and runs again. Not when you stop the program with Q. |
| T2 didn't start / starts again | red, pings / green | The Quantity Controller chose a unit for 2 cycles in a row, but GregTech didn't start it: usually a missing input. |
| Error, starting again / Running again after an error | red, pings / green | The program had an error and starts again in 30 s, and when it runs again. |
| Stopped after 5 minutes of errors | red, pings | The program switched the plant off and stopped. |
| Water Line Control started | gray | The program started, with the mode and the units. |

With `reminderHours`, a reminder follows while a unit still needs attention, a unit still doesn't start, or the plant is still stopped.
An alert that clears and comes back is sent again at most once every 30 minutes.
Messages are sent in the background, so a slow or unreachable Discord never holds up the water line.
If sending doesn't work (no internet card, a wrong webhook), the log says why, once.

Keep the webhook URL private: anyone who has it can post in that channel. The program never shows it on the screen or in the log.



<a id="credits"></a>

## Credits

- [Navatusein](https://github.com/Navatusein) wrote Water Line Control.
- [Willshaper](https://github.com/Willshaper) made the singlethread fork this one is based on.
- [ehami](https://github.com/ehami) wrote the Quantity Controller, the T1 and T2 modules and the Needs attention state (called "Admin disabled" there), ported here to the 2.9 version.
