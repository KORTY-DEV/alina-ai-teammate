local Acquisition = require("scripts.executor.acquisition")
local Conflict = require("scripts.conflict.manager")
local PrototypeIndex = require("scripts.sensors.prototype_index")
local RecipeIndex = require("scripts.sensors.recipe_index")
local ModulePolicy = require("scripts.autonomy.module_policy")
local SitePolicy = require("scripts.construction.site_policy")

local AssemblyPlanner = {}

local DEFAULT_MACHINE_COUNT = 4
local HIGH_THROUGHPUT_MACHINE_COUNT = 8
local BUFFER_CRAFTS = 10
local MAX_PLACEMENT_ACQUISITION_ATTEMPTS = 12

local function sorted_values(values)
  local result = {}
  for key, value in pairs(values or {}) do
    result[#result + 1] = type(key) == "number" and value or key
  end
  table.sort(result)
  return result
end

local function expected_product(product)
  local amount = product.amount
  if not amount and product.amount_min and product.amount_max then
    amount = (product.amount_min + product.amount_max) / 2
  end
  return (amount or 1) * (product.probability or 1)
end

local function recipe_choice(player, target_item)
  local best, best_score = nil, nil
  for _, recipe in ipairs(RecipeIndex.find_producers(target_item, player.force, 32) or {}) do
    local valid = recipe.enabled and #recipe.ingredients >= 1 and #recipe.ingredients <= 4
    local ingredient_total = 0
    for _, ingredient in ipairs(recipe.ingredients or {}) do
      if ingredient.type ~= "item" or not ingredient.amount then valid = false; break end
      ingredient_total = ingredient_total + ingredient.amount
    end
    local output = 0
    for _, product in ipairs(recipe.products or {}) do
      if product.type == "item" and product.name == target_item then
        output = output + expected_product(product)
      elseif product.type == "fluid" then
        valid = false
      end
    end
    if valid and output > 0 then
      local score = ingredient_total * 1000 + (recipe.energy or 1) * 10 / output
      if not best_score or score < best_score then best, best_score = recipe, score end
    end
  end
  return best
end

local function acquisition_score(plan)
  local score = #(plan.operations or {}) * 10000
  for _, operation in ipairs(plan.operations or {}) do
    score = score + (operation.count or operation.crafts or operation.output_count or 1)
  end
  return score
end

local function item_unlock_rank(agent, item_name, required_count)
  local inventory = agent.get_inventory(defines.inventory.character_main)
  if inventory and inventory.get_item_count(item_name) >= required_count then return 0 end
  if RecipeIndex.has_enabled_producer(item_name, agent.force) then return 1 end
  return 2
end

local function placement_choice(agent, rows, count, predicate, preference, acquisition_options, max_attempts)
  local candidates = {}
  for _, row in ipairs(rows or {}) do
    if not predicate or predicate(row) then
      for _, item in ipairs(row.items or {}) do
        local required = count * (item.count or 1)
        candidates[#candidates + 1] = {
          row = row,
          item = item,
          required = required,
          unlock_rank = item_unlock_rank(agent, item.name, required),
          preference = preference and preference(row) or 0
        }
      end
    end
  end
  -- Prototype packs can expose hundreds of historical, creative and remote-
  -- planet entities of the same type. Calling the recursive acquisition
  -- planner for every one freezes a large modded factory for seconds. Prefer
  -- items already carried, then currently unlocked tiers, and within that set
  -- try the strongest/smallest requested prototype first. Acquisition remains
  -- the authority for actual stock, chest sources and recursive crafting.
  table.sort(candidates, function(a, b)
    if a.unlock_rank ~= b.unlock_rank then return a.unlock_rank < b.unlock_rank end
    if a.preference ~= b.preference then return a.preference < b.preference end
    local a_area = (a.row.tile_width or 1) * (a.row.tile_height or 1)
    local b_area = (b.row.tile_width or 1) * (b.row.tile_height or 1)
    if a_area ~= b_area then return a_area < b_area end
    if a.row.entity ~= b.row.entity then return a.row.entity < b.row.entity end
    return a.item.name < b.item.name
  end)
  local last_error = nil
  for index = 1, math.min(#candidates, max_attempts or MAX_PLACEMENT_ACQUISITION_ATTEMPTS) do
    local candidate = candidates[index]
    local plan, err = Acquisition.make_plan(
      agent, candidate.item.name, candidate.required, "autonomous", acquisition_options)
    if plan then
      return {
        row = candidate.row,
        item = candidate.item.name,
        item_count = candidate.item.count or 1
      }, nil
    end
    last_error = candidate.item.name .. ":" .. tostring(err)
  end
  return nil, last_error
end

local function machine_rows(recipe)
  local rows, seen = {}, {}
  for _, category in ipairs(sorted_values(recipe.categories)) do
    for _, row in ipairs(PrototypeIndex.machines_for(category) or {}) do
      if row.entity_type == "assembling-machine" and not seen[row.entity] then
        seen[row.entity] = true
        rows[#rows + 1] = row
      end
    end
  end
  return rows
end

local function container_rows()
  local rows = {}
  for _, entity_type in ipairs({"container", "linked-container"}) do
    for _, row in ipairs(PrototypeIndex.entities_for_type(entity_type) or {}) do rows[#rows + 1] = row end
  end
  return rows
end

local function logistic_rows(modes)
  local rows = {}
  for _, row in ipairs(PrototypeIndex.entities_for_type("logistic-container") or {}) do
    if modes[row.logistic_mode] then rows[#rows + 1] = row end
  end
  return rows
end

local function buffer_stacks(recipe)
  local stacks = 0
  for _, ingredient in ipairs(recipe.ingredients) do
    local prototype = prototypes.item[ingredient.name]
    if not prototype then return math.huge end
    stacks = stacks + math.ceil(ingredient.amount * BUFFER_CRAFTS / math.max(1, prototype.stack_size))
  end
  return stacks
end

local function chest_accepts_recipe(row, recipe)
  local prototype = prototypes.entity[row.entity]
  local size = prototype and prototype.get_inventory_size(defines.inventory.chest) or nil
  return size and size >= buffer_stacks(recipe)
end

local function fuel_choice(agent, categories, count)
  local best, best_score = nil, nil
  for _, fuel in ipairs(PrototypeIndex.fuels_for(categories) or {}) do
    local plan = Acquisition.make_plan(agent, fuel.name, count, "autonomous")
    if plan then
      local score = acquisition_score(plan) - math.min(5000, math.floor((fuel.fuel_value or 0) / 10000))
      if not best_score or score < best_score then best, best_score = fuel, score end
    end
  end
  return best
end

local function snap_axis(value, size)
  if (size or 1) % 2 == 0 then return math.floor(value + 0.5) end
  return math.floor(value) + 0.5
end

local function half_tile(value)
  return math.floor(value) + 0.5
end

local function distance(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

local function add_row(rows, seen, row)
  local key = string.format("%.2f:%.2f", row.position.x, row.position.y)
  if seen[key] then return false end
  seen[key] = true
  row.bootstrap = true
  rows[#rows + 1] = row
  return true
end

local function validate(surface, force, rows)
  for _, row in ipairs(rows) do
    if Conflict.is_blocked(surface.index, row.position, "autonomous") then return false end
    if not SitePolicy.can_plan(surface, force, row.name, row.position, row.direction) then return false end
  end
  return true
end

local function powered_poles(agent, marker)
  local origin = marker and marker.surface_index == agent.surface.index and marker.position or agent.position
  local poles = agent.surface.find_entities_filtered({
    position = origin,
    radius = marker and 96 or 512,
    type = "electric-pole",
    force = agent.force,
    limit = 256
  })
  local result = {}
  for _, pole in ipairs(poles) do
    if pole.valid and pole.electric_network_id then result[#result + 1] = pole end
  end
  table.sort(result, function(a, b) return distance(a.position, origin) < distance(b.position, origin) end)
  return result
end

local function ingredient_buffer(recipe)
  local result = {}
  for _, ingredient in ipairs(recipe.ingredients) do
    result[#result + 1] = {name = ingredient.name, count = ingredient.amount * BUFFER_CRAFTS}
  end
  return result
end

local function logistic_network_at(surface, force, position)
  local ok, network = pcall(function() return surface.find_logistic_network_by_position(position, force) end)
  if not ok or not network or not network.valid then return nil end
  if (network.all_logistic_robots or 0) <= 0 then return nil end
  return network
end

local function layout_at(agent, recipe, target_item, existing_pole, machine, inserter, chest, pole, fuel,
    requester, provider, module, machine_count, x_sign, y_sign)
  local surface, force = agent.surface, agent.force
  local machine_width, machine_height = machine.tile_width or 3, machine.tile_height or 3
  -- One tile is sufficient between adjacent machine footprints. The selected
  -- 1x1 distribution pole occupies that service tile exactly; an extra empty
  -- tile multiplied over a long row only wastes factory space.
  local spacing = machine_width + 1
  local start = {
    x = snap_axis(existing_pole.position.x + x_sign * 2, machine_width),
    y = snap_axis(existing_pole.position.y + y_sign * 5, machine_height)
  }
  local pole_offset = machine_width / 2 + 0.5
  local inserter_fuel = inserter.burner_categories and {name = fuel.name, count = 10} or nil
  local rows, seen, output_rows = {}, {}, {}
  -- Keep the compact footprint, but build it as straight service lanes. The
  -- old per-machine order (upper chest -> machine -> lower chest -> next
  -- machine) made the physical character run a large saw-tooth path and look
  -- as if it was stuttering. Alternating lane direction keeps every transition
  -- at the end of the row without changing the final factory topology.
  local lanes = {
    input_chests = {}, input_inserters = {}, machines = {},
    poles = {}, output_inserters = {}, output_chests = {}
  }
  local producer = nil
  local previous_pole = existing_pole
  for index = 0, machine_count - 1 do
    local machine_position = {x = start.x + x_sign * index * spacing, y = start.y}
    local pole_position = {x = half_tile(machine_position.x + x_sign * pole_offset), y = half_tile(machine_position.y)}
    local wire_limit = math.min(previous_pole.prototype.get_max_wire_distance(), pole.max_wire_distance or 0)
    if wire_limit <= 0 or distance(previous_pole.position, pole_position) > wire_limit * 0.96 then return nil end
    if math.abs(pole_position.x - machine_position.x) > (pole.supply_area_distance or 0)
        or math.abs(pole_position.y - machine_position.y) > (pole.supply_area_distance or 0) then return nil end

    local input_chest_position = {
      x = half_tile(machine_position.x),
      y = half_tile(machine_position.y - machine_height / 2 - 1.5)
    }
    local input_inserter_position = {x = half_tile(machine_position.x), y = half_tile(input_chest_position.y + 1)}
    local output_chest_position = {
      x = half_tile(machine_position.x),
      y = half_tile(machine_position.y + machine_height / 2 + 1.5)
    }
    local output_inserter_position = {x = half_tile(machine_position.x), y = half_tile(output_chest_position.y - 1)}

    local input_chest = chest
    local output_chest = chest
    local continuous = false
    if requester and provider
        and logistic_network_at(surface, force, input_chest_position)
        and logistic_network_at(surface, force, output_chest_position) then
      input_chest = requester
      output_chest = provider
      continuous = true
    end
    local input_row = {name = input_chest.entity, entity_type = input_chest.entity_type,
      position = input_chest_position, direction = defines.direction.north,
      contents = ingredient_buffer(recipe),
      logistic_requests = continuous and ingredient_buffer(recipe) or nil}
    local machine_row = {name = machine.entity, entity_type = machine.entity_type,
      position = machine_position, direction = defines.direction.north, recipe = recipe.name,
      modules = module and {{name = module.name, count = module.count, quality = "normal"}} or nil}
    local output_row = {name = output_chest.entity, entity_type = output_chest.entity_type,
      position = output_chest_position, direction = defines.direction.north}
    lanes.input_chests[#lanes.input_chests + 1] = input_row
    lanes.input_inserters[#lanes.input_inserters + 1] = {
      name = inserter.entity, entity_type = "inserter",
      position = input_inserter_position, direction = defines.direction.north, fuel = inserter_fuel}
    lanes.machines[#lanes.machines + 1] = machine_row
    lanes.poles[#lanes.poles + 1] = {
      name = pole.entity, entity_type = "electric-pole",
      position = pole_position, direction = defines.direction.north}
    lanes.output_inserters[#lanes.output_inserters + 1] = {
      name = inserter.entity, entity_type = "inserter",
      position = output_inserter_position, direction = defines.direction.north, fuel = inserter_fuel}
    lanes.output_chests[#lanes.output_chests + 1] = output_row
    output_rows[#output_rows + 1] = output_row
    producer = producer or machine_row
    previous_pole = {position = pole_position, prototype = prototypes.entity[pole.entity]}
    if continuous then output_row.continuous = true end
  end
  local function append_lane(lane, reverse)
    if reverse then
      for index = #lane, 1, -1 do add_row(rows, seen, lane[index]) end
    else
      for index = 1, #lane do add_row(rows, seen, lane[index]) end
    end
  end
  append_lane(lanes.input_chests, false)
  append_lane(lanes.input_inserters, true)
  append_lane(lanes.machines, false)
  append_lane(lanes.poles, true)
  append_lane(lanes.output_inserters, false)
  append_lane(lanes.output_chests, true)
  if not validate(surface, force, rows) then return nil end
  local ingredients = {}
  for _, ingredient in ipairs(recipe.ingredients) do ingredients[#ingredients + 1] = ingredient.name end
  return {
    bootstrap = true,
    assembly_bootstrap = true,
    recipe = recipe.name,
    input_item = table.concat(ingredients, "+"),
    target_item = target_item,
    entities = rows,
    construction_lane_sweep = true,
    producer_target = producer,
    output_row = output_rows[1],
    output_rows = output_rows,
    approach_position = start,
    source_position = {x = existing_pole.position.x, y = existing_pole.position.y},
    remote = false,
    drill_count = 0,
    machine_count = machine_count,
    continuous = output_rows[1] and output_rows[1].continuous == true,
    module = module and module.name or nil,
    module_count = module and module.count * machine_count or 0
  }
end

function AssemblyPlanner.plan(player, agent, target_item, marker, options)
  if not PrototypeIndex.is_ready() or not RecipeIndex.is_ready() then return nil, "indexes_not_ready" end
  local recipe = recipe_choice(player, target_item)
  if not recipe then return nil, "no_buffered_item_recipe" end
  local high_throughput = (options and options.high_throughput)
    or (marker and marker.high_throughput) or false
  local acquisition_options = {preview = true}
  local machine_count = high_throughput and HIGH_THROUGHPUT_MACHINE_COUNT or DEFAULT_MACHINE_COUNT
  local machines = machine_rows(recipe)
  local machine, machine_error = placement_choice(agent, machines, machine_count, function(row)
    return row.electric == true
  end, function(row)
    return -math.min(8000, math.floor((row.crafting_speed or 0) * 1200
      + (row.module_inventory_size or 0) * 200))
  end, acquisition_options)
  -- Runtime prototype packs disagree on the coordinate reported for a folded
  -- inserter's pickup point (base 2.1 can report zero here). Physical placement
  -- below is still validated by the engine, while acquisition scoring naturally
  -- prefers the ordinary obtainable inserter already present in Alina's reserve.
  local inserter, inserter_error = placement_choice(agent,
    PrototypeIndex.entities_for_type("inserter"), machine_count * 2, function(row)
      return not high_throughput or not row.burner_categories
    end, function(row)
      return -math.min(3000, math.floor((row.inserter_rotation_speed or 0) * 12000))
    end, acquisition_options)
  local chest, chest_error = placement_choice(agent, container_rows(), machine_count * 2, function(row)
    return (row.tile_width or 1) == 1 and (row.tile_height or 1) == 1 and chest_accepts_recipe(row, recipe)
  end, nil, acquisition_options)
  local requester = placement_choice(agent, logistic_rows({requester = true}), machine_count, function(row)
    return (row.tile_width or 1) == 1 and (row.tile_height or 1) == 1 and chest_accepts_recipe(row, recipe)
  end, nil, acquisition_options, 1)
  local provider = placement_choice(agent,
    logistic_rows({["passive-provider"] = true, storage = true}), machine_count, function(row)
      return (row.tile_width or 1) == 1 and (row.tile_height or 1) == 1
    end, nil, acquisition_options, 1)
  local pole, pole_error = placement_choice(agent, PrototypeIndex.entities_for_type("electric-pole"), machine_count,
    function(row) return (row.tile_width or 1) == 1 and (row.tile_height or 1) == 1 end,
    function(row) return -math.min(3000, math.floor((row.supply_area_distance or 0) * 300
      + (row.max_wire_distance or 0) * 40)) end, acquisition_options, 3)
  if not machine or not inserter or not chest or not pole then
    return nil, "assembly_components_not_obtainable:machine=" .. tostring(machine ~= nil)
      .. ",inserter=" .. tostring(inserter ~= nil) .. ",chest=" .. tostring(chest ~= nil)
      .. ",pole=" .. tostring(pole ~= nil) .. ",errors="
      .. table.concat({tostring(machine_error), tostring(inserter_error), tostring(chest_error), tostring(pole_error)}, "|")
  end
  local fuel = inserter.row.burner_categories
      and fuel_choice(agent, inserter.row.burner_categories, machine_count * 20) or {name = ""}
  if inserter.row.burner_categories and not fuel then return nil, "assembly_inserter_fuel_unavailable" end
  local module = ModulePolicy.choose(agent, machine.row, recipe, high_throughput, machine_count)
  for _, ingredient in ipairs(recipe.ingredients) do
    local plan, err = Acquisition.make_plan(
      agent, ingredient.name, ingredient.amount * BUFFER_CRAFTS * machine_count,
      "autonomous", acquisition_options)
    if not plan then return nil, "assembly_input_unavailable:" .. ingredient.name .. ":" .. tostring(err) end
  end
  for _, existing_pole in ipairs(powered_poles(agent, marker)) do
    for _, direction in ipairs({{1, 1}, {1, -1}, {-1, 1}, {-1, -1}}) do
      local layout = layout_at(agent, recipe, target_item, existing_pole, machine.row, inserter.row,
        chest.row, pole.row, fuel, requester and requester.row or nil, provider and provider.row or nil,
        module, machine_count, direction[1], direction[2])
      if layout then
        if marker then layout.marker_goal = marker end
        return layout
      end
    end
  end
  return nil, "no_powered_safe_assembly_site"
end

return AssemblyPlanner
