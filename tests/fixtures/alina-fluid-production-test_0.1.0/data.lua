data:extend({
  {
    type = "item",
    name = "alina-fluid-test-product",
    icon = "__base__/graphics/icons/plastic-bar.png",
    icon_size = 64,
    subgroup = "intermediate-product",
    order = "z[alina-fluid-test-product]",
    stack_size = 100
  },
  {
    type = "recipe",
    name = "alina-fluid-test-product",
    categories = {"chemistry"},
    enabled = true,
    energy_required = 1,
    ingredients = {
      {type = "fluid", name = "water", amount = 10},
      {type = "fluid", name = "petroleum-gas", amount = 10}
    },
    results = {
      {type = "item", name = "alina-fluid-test-product", amount = 1},
      {type = "fluid", name = "heavy-oil", amount = 4},
      {type = "fluid", name = "light-oil", amount = 4}
    },
    main_product = "alina-fluid-test-product",
    allow_productivity = false
  }
})

-- Keep the isolated fixture long enough to require real powered segmentation,
-- but avoid the unrepresentative 40-tile pump cascade that dominated a small
-- test factory. Production reads the live value from the active mod pack.
data.raw["utility-constants"].default.default_pipeline_extent = 100
