local burner_generator = table.deepcopy(data.raw["generator-equipment"]["fission-reactor-equipment"])
burner_generator.name = "alina-test-burner-generator-equipment"
burner_generator.take_result = "alina-test-burner-generator-equipment"
burner_generator.power = "100kW"
burner_generator.shape = {width = 1, height = 1, type = "full"}
burner_generator.burner = {
  type = "burner",
  fuel_categories = {"chemical"},
  fuel_inventory_size = 1,
  burnt_inventory_size = 1,
  effectivity = 1,
  auto_refuel = false
}

local burner_generator_item = table.deepcopy(data.raw.item["fission-reactor-equipment"])
burner_generator_item.name = "alina-test-burner-generator-equipment"
burner_generator_item.place_as_equipment_result = "alina-test-burner-generator-equipment"
burner_generator_item.order = "zzz[alina-test-burner-generator-equipment]"

-- A private fast-replace pair keeps the runtime upgrade/rollback test isolated
-- from whichever vanilla or modded assembler tiers earlier fixture stages have
-- unlocked or stocked. It also proves that Alina follows runtime prototypes.
local test_assembler_1 = table.deepcopy(data.raw["assembling-machine"]["assembling-machine-1"])
test_assembler_1.name = "alina-test-assembler-1"
test_assembler_1.minable = {mining_time = 0.2, result = "alina-test-assembler-1"}
test_assembler_1.next_upgrade = "alina-test-assembler-2"
test_assembler_1.crafting_speed = 0.5

local test_assembler_2 = table.deepcopy(data.raw["assembling-machine"]["assembling-machine-2"])
test_assembler_2.name = "alina-test-assembler-2"
test_assembler_2.minable = {mining_time = 0.2, result = "alina-test-assembler-2"}
test_assembler_2.next_upgrade = nil
test_assembler_2.crafting_speed = 1.25

local test_assembler_item_1 = table.deepcopy(data.raw.item["assembling-machine-1"])
test_assembler_item_1.name = "alina-test-assembler-1"
test_assembler_item_1.place_result = "alina-test-assembler-1"
test_assembler_item_1.order = "zzz[alina-test-assembler-1]"

local test_assembler_item_2 = table.deepcopy(data.raw.item["assembling-machine-2"])
test_assembler_item_2.name = "alina-test-assembler-2"
test_assembler_item_2.place_result = "alina-test-assembler-2"
test_assembler_item_2.order = "zzz[alina-test-assembler-2]"

local capacity_product = {
  type = "item",
  name = "alina-capacity-product",
  icon = "__base__/graphics/icons/iron-gear-wheel.png",
  icon_size = 64,
  stack_size = 100,
  order = "zzz[alina-capacity-product]"
}

local capacity_recipe = {
  type = "recipe",
  name = "alina-capacity-product",
  enabled = true,
  energy_required = 0.5,
  ingredients = {{type = "item", name = "iron-plate", amount = 2}},
  results = {{type = "item", name = "alina-capacity-product", amount = 1}}
}

data:extend({
  burner_generator,
  burner_generator_item,
  test_assembler_1,
  test_assembler_2,
  test_assembler_item_1,
  test_assembler_item_2,
  capacity_product,
  capacity_recipe,
  {
    type = "technology",
    name = "alina-test-research",
    icon = "__base__/graphics/technology/automation-1.png",
    icon_size = 256,
    effects = {},
    unit = {
      count = 100,
      ingredients = {{"automation-science-pack", 1}},
      time = 30
    },
    order = "zzz[alina-test-research]"
  },
  {
    type = "technology",
    name = "alina-player-research",
    icon = "__base__/graphics/technology/logistics-1.png",
    icon_size = 256,
    effects = {},
    unit = {
      count = 100,
      ingredients = {{"automation-science-pack", 1}},
      time = 30
    },
    order = "zzz[alina-player-research]"
  }
})
