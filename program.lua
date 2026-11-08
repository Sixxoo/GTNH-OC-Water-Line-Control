return {
  id = "water-line",
  name = "Water Line Control",
  version = "2.2.1",
  repository = "Sixxoo/GTNH-OC-Water-Line-Control",
  branch = "main",
  archive = "WaterLineControl.tar",
  start = "main",
  config = "config.lua",
  configRules = {
    whenMissing = {
      {pattern = "^quantityController%.floorQty$", value = 0, why = "0 is no floor stage, as before"},
      {pattern = "^quantityController%.waterThresholds%.", value = 0, why = "0 is no cap, as before"},
    },
  },
}
