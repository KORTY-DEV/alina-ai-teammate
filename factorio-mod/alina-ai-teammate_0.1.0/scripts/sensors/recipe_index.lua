local State = require("scripts.core.state")

local RecipeIndex = {}

local function sorted_recipe_names()
  local names = {}
  for name in pairs(prototypes.recipe) do names[#names + 1] = name end
  table.sort(names)
  return names
end

local function copy_ingredients(ingredients)
  local result = {}
  for _, ingredient in ipairs(ingredients or {}) do
    result[#result + 1] = {
      type = ingredient.type,
      name = ingredient.name,
      amount = ingredient.amount,
      fluidbox_index = ingredient.fluidbox_index,
      fluidbox_multiplier = ingredient.fluidbox_multiplier,
      minimum_temperature = ingredient.minimum_temperature,
      maximum_temperature = ingredient.maximum_temperature,
      temperature = ingredient.temperature,
      quality_min = ingredient.quality_min,
      quality_max = ingredient.quality_max
    }
  end
  return result
end

local function copy_products(products)
  local result = {}
  for _, product in ipairs(products or {}) do
    result[#result + 1] = {
      type = product.type,
      name = product.name,
      amount = product.amount,
      amount_min = product.amount_min,
      amount_max = product.amount_max,
      probability = product.probability,
      fluidbox_index = product.fluidbox_index,
      temperature = product.temperature
    }
  end
  return result
end

local function append(mapping, key, value)
  if not key then return end
  local values = mapping[key]
  if not values then values = {}; mapping[key] = values end
  values[#values + 1] = value
end

function RecipeIndex.start()
  local root = State.ensure()
  root.recipe_index = {
    status = "building",
    index = 1,
    names = sorted_recipe_names(),
    recipes = {},
    producers = {},
    consumers = {},
    started_tick = game.tick
  }
end

function RecipeIndex.on_nth_tick()
  local root = State.ensure()
  local index = root.recipe_index
  if not index or index.status ~= "building" then return end

  local processed = 0
  -- Match the bounded but responsive prototype bootstrap on large mod packs.
  while index.index <= #index.names and processed < 200 do
    local name = index.names[index.index]
    local prototype = prototypes.recipe[name]
    if prototype then
      local row = {
        name = name,
        energy = prototype.energy,
        categories = prototype.categories,
        hidden_from_player_crafting = prototype.hidden_from_player_crafting,
        allowed_effects = prototype.allowed_effects,
        allowed_module_categories = prototype.allowed_module_categories,
        ingredients = copy_ingredients(prototype.ingredients),
        products = copy_products(prototype.products)
      }
      index.recipes[name] = row
      for _, ingredient in ipairs(row.ingredients) do
        append(index.consumers, ingredient.name, name)
      end
      for _, product in ipairs(row.products) do
        append(index.producers, product.name, name)
      end
      root.metrics.recipe_index_rows = (root.metrics.recipe_index_rows or 0) + 1
    end
    index.index = index.index + 1
    processed = processed + 1
  end

  if index.index > #index.names then
    index.status = "ready"
    index.finished_tick = game.tick
    index.names = nil
  end
end

function RecipeIndex.is_ready()
  local index = State.ensure().recipe_index
  return index and index.status == "ready"
end

function RecipeIndex.find_producers(item_name, force, limit)
  local index = State.ensure().recipe_index
  if not index or index.status ~= "ready" then return nil end
  local result = {}
  for _, recipe_name in ipairs(index.producers[item_name] or {}) do
    local row = index.recipes[recipe_name]
    local force_recipe = force.recipes[recipe_name]
    if row and force_recipe then
      result[#result + 1] = {
        name = row.name,
        enabled = force_recipe.enabled,
        energy = row.energy,
        categories = row.categories,
        hidden_from_player_crafting = row.hidden_from_player_crafting,
        allowed_effects = row.allowed_effects,
        allowed_module_categories = row.allowed_module_categories,
        ingredients = row.ingredients,
        products = row.products
      }
    end
  end
  table.sort(result, function(a, b)
    if a.enabled ~= b.enabled then return a.enabled end
    return a.name < b.name
  end)
  while #result > (limit or 8) do table.remove(result) end
  return result
end

-- Allocation-free hot-path check used while ranking hundreds of modded
-- placement prototypes. `find_producers` intentionally materialises and sorts
-- rich recipe rows; doing that once per pole/inserter candidate caused visible
-- single-tick planning stalls on overhaul packs.
function RecipeIndex.has_enabled_producer(item_name, force)
  local index = State.ensure().recipe_index
  if not index or index.status ~= "ready" then return false end
  for _, recipe_name in ipairs(index.producers[item_name] or {}) do
    local force_recipe = force and force.recipes[recipe_name] or nil
    if force_recipe and force_recipe.enabled then return true end
  end
  return false
end

function RecipeIndex.consumer_count(item_name, force)
  local index = State.ensure().recipe_index
  if not index or index.status ~= "ready" then return 0 end
  local count = 0
  for _, recipe_name in ipairs(index.consumers[item_name] or {}) do
    if not force or (force.recipes[recipe_name] and force.recipes[recipe_name].enabled) then count = count + 1 end
  end
  return count
end

function RecipeIndex.resource_processing_candidates(force, input_item, limit)
  local index = State.ensure().recipe_index
  if not index or index.status ~= "ready" then return {} end
  local result, seen = {}, {}
  for _, recipe_name in ipairs(index.consumers[input_item] or {}) do
    local row = index.recipes[recipe_name]
    local force_recipe = force.recipes[recipe_name]
    if row and force_recipe and force_recipe.enabled and #row.ingredients == 1
        and row.ingredients[1].type == "item" and row.ingredients[1].name == input_item then
      for _, product in ipairs(row.products or {}) do
        if product.type == "item" and product.name ~= input_item
            and prototypes.item[product.name] and not seen[product.name] then
          seen[product.name] = true
          local consumers = #(index.consumers[product.name] or {})
          result[#result + 1] = {
            item = product.name,
            recipe = row.name,
            consumers = consumers,
            score = consumers * 1000 - math.floor((row.energy or 1) * 10)
          }
        end
      end
    end
  end
  table.sort(result, function(a, b)
    if a.score == b.score then return a.item < b.item end
    return a.score > b.score
  end)
  while #result > (limit or 8) do table.remove(result) end
  return result
end

function RecipeIndex.development_candidates(force, available_items, existing_products, limit)
  local index = State.ensure().recipe_index
  if not index or index.status ~= "ready" then return {} end
  available_items = available_items or {}
  existing_products = existing_products or {}
  local candidates = {}

  for recipe_name, row in pairs(index.recipes) do
    local force_recipe = force.recipes[recipe_name]
    if force_recipe and force_recipe.enabled and not row.hidden_from_player_crafting then
      local ready = #row.ingredients > 0
      local ingredient_count = 0
      if ready then
        for _, ingredient in ipairs(row.ingredients or {}) do
          if ingredient.type ~= "item" or not available_items[ingredient.name] then
            ready = false
            break
          end
          ingredient_count = ingredient_count + 1
        end
      end

      if ready then
        for _, product in ipairs(row.products or {}) do
          if product.type == "item" and prototypes.item[product.name] and not existing_products[product.name] then
            local consumers = #(index.consumers[product.name] or {})
            -- Prefer broadly useful intermediates and simple recipes. The LLM still
            -- chooses from this grounded frontier; this score only bounds/sorts it.
            local score = consumers * 100 - ingredient_count * 20 - math.floor((row.energy or 0) * 2)
            candidates[#candidates + 1] = {
              item = product.name,
              recipe = row.name,
              consumer_count = consumers,
              ingredient_count = ingredient_count,
              score = score
            }
          end
        end
      end
    end
  end

  table.sort(candidates, function(a, b)
    if a.score == b.score then
      if a.consumer_count == b.consumer_count then return a.item < b.item end
      return a.consumer_count > b.consumer_count
    end
    return a.score > b.score
  end)

  local result = {}
  local seen = {}
  for _, candidate in ipairs(candidates) do
    if not seen[candidate.item] then
      seen[candidate.item] = true
      result[#result + 1] = candidate
      if #result >= (limit or 8) then break end
    end
  end
  return result
end

return RecipeIndex
