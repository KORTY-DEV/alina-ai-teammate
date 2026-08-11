local State = require("scripts.core.state")
local WorldModel = require("scripts.sensors.world_model")

local Factory = {}

local MACHINE_TYPES = {
  "assembling-machine",
  "furnace",
  "mining-drill",
  "lab",
  "beacon",
  "boiler",
  "generator",
  "reactor",
  "rocket-silo",
  "agricultural-tower",
  "asteroid-collector",
  "thruster"
}

local CRAFTING_MACHINE_TYPES = {
  ["assembling-machine"] = true,
  furnace = true,
  ["rocket-silo"] = true
}

local INFRASTRUCTURE_TYPES = {
  "transport-belt",
  "underground-belt",
  "splitter",
  "loader",
  "loader-1x1",
  "inserter",
  "electric-pole",
  "container",
  "logistic-container",
  "linked-container",
  "pipe",
  "pipe-to-ground",
  "storage-tank",
  "pump",
  "roboport"
}

local STORAGE_TYPES = {"container", "logistic-container", "linked-container"}

local function round(value, digits)
  local scale = 10 ^ (digits or 0)
  return math.floor(value * scale + 0.5) / scale
end

local function setting(name, fallback)
  local value = settings.global[name]
  return value and value.value or fallback
end

local function sorted_count_rows(counts, label)
  local rows = {}
  for name, count in pairs(counts) do
    rows[#rows + 1] = {[label] = name, count = count}
  end
  table.sort(rows, function(a, b)
    if a.count == b.count then return a[label] < b[label] end
    return a.count > b.count
  end)
  return rows
end

local function status_names()
  local result = {}
  for name, value in pairs(defines.entity_status) do result[value] = name end
  return result
end

local function copy_ingredients(ingredients)
  local result = {}
  for _, ingredient in ipairs(ingredients or {}) do
    result[#result + 1] = {
      type = ingredient.type,
      name = ingredient.name,
      amount = ingredient.amount
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
      probability = product.probability
    }
  end
  return result
end

local function nearby_machines(player, radius, limit)
  local steps = {math.min(32, radius)}
  if radius > 32 then steps[#steps + 1] = radius end
  local result = {}
  local seen = {}
  local truncated = false

  for _, scan_radius in ipairs(steps) do
    local batch = player.surface.find_entities_filtered({
      position = player.position,
      radius = scan_radius,
      type = MACHINE_TYPES,
      force = player.force,
      limit = limit
    })
    if #batch >= limit then truncated = true end
    for _, entity in ipairs(batch) do
      local key = entity.unit_number
      if key and not seen[key] then
        seen[key] = true
        result[#result + 1] = entity
        if #result >= limit then return result, true end
      end
    end
  end
  return result, truncated
end

local function production_snapshot(player, row_limit)
  local statistics = player.force.get_item_production_statistics(player.surface)
  local totals = {}
  for name, count in pairs(statistics.input_counts) do
    if prototypes.item[name] then
      totals[name] = {produced = count, consumed = 0}
    end
  end
  for name, count in pairs(statistics.output_counts) do
    if prototypes.item[name] then
      local row = totals[name] or {produced = 0, consumed = 0}
      row.consumed = count
      totals[name] = row
    end
  end

  local names = {}
  for name, row in pairs(totals) do
    names[#names + 1] = {name = name, activity = row.produced + row.consumed}
  end
  table.sort(names, function(a, b)
    if a.activity == b.activity then return a.name < b.name end
    return a.activity > b.activity
  end)

  local result = {}
  local minute = defines.flow_precision_index.one_minute
  local ten_minutes = defines.flow_precision_index.ten_minutes
  for index = 1, math.min(#names, row_limit) do
    local name = names[index].name
    local row = totals[name]
    result[#result + 1] = {
      name = name,
      produced_total = row.produced,
      consumed_total = row.consumed,
      produced_per_minute = round(statistics.get_flow_count({
        name = name,
        category = "input",
        precision_index = minute
      }), 3),
      consumed_per_minute = round(statistics.get_flow_count({
        name = name,
        category = "output",
        precision_index = minute
      }), 3),
      produced_ten_minute_average = round(statistics.get_flow_count({
        name = name,
        category = "input",
        precision_index = ten_minutes
      }), 3),
      consumed_ten_minute_average = round(statistics.get_flow_count({
        name = name,
        category = "output",
        precision_index = ten_minutes
      }), 3)
    }
  end
  return result, #names > row_limit
end

local function machine_snapshot(player, radius, limit)
  local entities, truncated = nearby_machines(player, radius, limit)
  local status_by_value = status_names()
  local machine_groups = {}
  local recipe_groups = {}
  local mining_groups = {}
  local issue_groups = {}
  local root = State.ensure()

  for _, entity in ipairs(entities) do
    local status = status_by_value[entity.status] or "unknown"
    local machine_key = entity.type .. ":" .. entity.name
    local machine = machine_groups[machine_key]
    if not machine then
      machine = {name = entity.name, entity_type = entity.type, count = 0, statuses = {}}
      machine_groups[machine_key] = machine
    end
    machine.count = machine.count + 1
    machine.statuses[status] = (machine.statuses[status] or 0) + 1

    if CRAFTING_MACHINE_TYPES[entity.type] then
      local recipe = entity.get_recipe()
      if recipe then
        local recipe_group = recipe_groups[recipe.name]
        if not recipe_group then
          recipe_group = {
            name = recipe.name,
            count = 0,
            energy = recipe.energy,
            ingredients = copy_ingredients(recipe.ingredients),
            products = copy_products(recipe.products),
            statuses = {}
          }
          recipe_groups[recipe.name] = recipe_group
        end
        recipe_group.count = recipe_group.count + 1
        recipe_group.statuses[status] = (recipe_group.statuses[status] or 0) + 1
      end
    elseif entity.type == "mining-drill" then
      local target = entity.mining_target
      local resource = target and target.valid and target.name or "none"
      local drill = mining_groups[resource]
      if not drill then drill = {resource = resource, count = 0, statuses = {}}; mining_groups[resource] = drill end
      drill.count = drill.count + 1
      drill.statuses[status] = (drill.statuses[status] or 0) + 1
    end

    if status ~= "working" and status ~= "normal" then
      local recipe = CRAFTING_MACHINE_TYPES[entity.type] and entity.get_recipe() or nil
      local mining_target = entity.type == "mining-drill" and entity.mining_target or nil
      local issue_key = status .. ":" .. entity.type .. ":" .. entity.name
        .. ":" .. (recipe and recipe.name or "") .. ":" .. (mining_target and mining_target.name or "")
      local issue = issue_groups[issue_key]
      if not issue then
        issue = {
          status = status,
          name = entity.name,
          entity_type = entity.type,
          recipe = recipe and recipe.name or nil,
          resource = mining_target and mining_target.name or nil,
          count = 0,
          owned_count = 0,
          samples = {}
        }
        issue_groups[issue_key] = issue
      end
      issue.count = issue.count + 1
      if entity.unit_number and root.owned_entities[entity.unit_number] then
        issue.owned_count = issue.owned_count + 1
      end
      if #issue.samples < 6 then
        local drop_target = entity.drop_target
        issue.samples[#issue.samples + 1] = {
          unit_number = entity.unit_number,
          position = {x = entity.position.x, y = entity.position.y},
          direction = entity.direction,
          energy = entity.energy,
          electric_network_id = entity.electric_network_id,
          drop_position = entity.drop_position and {x = entity.drop_position.x, y = entity.drop_position.y} or nil,
          drop_target = drop_target and drop_target.valid and {
            name = drop_target.name,
            entity_type = drop_target.type,
            position = {x = drop_target.position.x, y = drop_target.position.y}
          } or nil
        }
      end
    end
  end

  local machines = {}
  for _, row in pairs(machine_groups) do
    row.statuses = sorted_count_rows(row.statuses, "status")
    machines[#machines + 1] = row
  end
  table.sort(machines, function(a, b)
    if a.count == b.count then return a.name < b.name end
    return a.count > b.count
  end)

  local recipes = {}
  for _, row in pairs(recipe_groups) do
    row.statuses = sorted_count_rows(row.statuses, "status")
    recipes[#recipes + 1] = row
  end
  table.sort(recipes, function(a, b)
    if a.count == b.count then return a.name < b.name end
    return a.count > b.count
  end)

  local mining = {}
  for _, row in pairs(mining_groups) do
    row.statuses = sorted_count_rows(row.statuses, "status")
    mining[#mining + 1] = row
  end
  table.sort(mining, function(a, b)
    if a.count == b.count then return a.resource < b.resource end
    return a.count > b.count
  end)

  local issues = {}
  for _, row in pairs(issue_groups) do issues[#issues + 1] = row end
  table.sort(issues, function(a, b)
    if a.count == b.count then
      if a.status == b.status then return a.name < b.name end
      return a.status < b.status
    end
    return a.count > b.count
  end)

  return {
    machine_count = #entities,
    machines_truncated = truncated,
    machines = machines,
    active_recipes = recipes,
    mining = mining,
    issues = issues
  }
end

local function infrastructure_snapshot(player, radius, limit)
  local entities = player.surface.find_entities_filtered({
    position = player.position,
    radius = radius,
    type = INFRASTRUCTURE_TYPES,
    force = player.force,
    limit = limit
  })
  local counts = {}
  for _, entity in ipairs(entities) do
    local key = entity.type .. ":" .. entity.name
    local row = counts[key]
    if not row then
      row = {name = entity.name, entity_type = entity.type, count = 0, samples = {}}
      counts[key] = row
    end
    row.count = row.count + 1
    if #row.samples < 8 then
      row.samples[#row.samples + 1] = {
        unit_number = entity.unit_number,
        position = {x = entity.position.x, y = entity.position.y},
        direction = entity.direction,
        electric_network_id = entity.electric_network_id,
        energy = entity.energy
      }
    end
  end
  local rows = {}
  for _, row in pairs(counts) do rows[#rows + 1] = row end
  table.sort(rows, function(a, b)
    if a.count == b.count then return a.name < b.name end
    return a.count > b.count
  end)
  return rows, #entities, #entities >= limit
end

local function storage_snapshot(player, radius, limit)
  local entities = player.surface.find_entities_filtered({
    position = player.position,
    radius = radius,
    type = STORAGE_TYPES,
    force = player.force,
    limit = limit
  })
  local groups = {}
  for _, entity in ipairs(entities) do
    local row = groups[entity.name]
    if not row then row = {name = entity.name, count = 0, items = {}}; groups[entity.name] = row end
    row.count = row.count + 1
    local inventory = entity.get_inventory(defines.inventory.chest)
    if inventory then
      -- Factorio 2.1: get_contents() -> array[ItemWithQualityCount].
      -- Aggregate qualities by prototype name for the compact factory sensor.
      for _, item in ipairs(inventory.get_contents()) do
        if item.name and (item.count or 0) > 0 then
          row.items[item.name] = (row.items[item.name] or 0) + item.count
        end
      end
    end
  end
  local result = {}
  for _, row in pairs(groups) do
    local items = {}
    for name, count in pairs(row.items) do items[#items + 1] = {name = name, count = count} end
    table.sort(items, function(a, b)
      if a.count == b.count then return a.name < b.name end
      return a.count > b.count
    end)
    while #items > 24 do table.remove(items) end
    row.items = items
    result[#result + 1] = row
  end
  table.sort(result, function(a, b)
    if a.count == b.count then return a.name < b.name end
    return a.count > b.count
  end)
  return result, #entities >= limit
end

function Factory.snapshot(player)
  local radius = setting("alina-sensor-radius", 64)
  local entity_limit = setting("alina-resource-scan-limit", 256)
  local machines = machine_snapshot(player, radius, entity_limit)
  local infrastructure, infrastructure_count, infrastructure_truncated =
    infrastructure_snapshot(player, radius, entity_limit)
  local storage, storage_truncated = storage_snapshot(player, radius, 64)
  local production, production_truncated = production_snapshot(player, 24)
  machines.item_flows = production
  machines.item_flows_truncated = production_truncated
  machines.radius = radius
  machines.infrastructure = infrastructure
  machines.infrastructure_count = infrastructure_count
  machines.infrastructure_truncated = infrastructure_truncated
  machines.storage = storage
  machines.storage_truncated = storage_truncated

  local root = State.ensure()
  root.metrics.factory_scans = (root.metrics.factory_scans or 0) + 1
  root.metrics.factory_entities_examined = (root.metrics.factory_entities_examined or 0)
    + machines.machine_count + infrastructure_count
  return machines
end


function Factory.target_snapshot(player, target_item)
  local entities = WorldModel.entities_by_type(player, {"assembling-machine", "furnace", "rocket-silo"}, 768)
  local status_by_value = status_names()
  local recipes = {}
  local ingredient_names = {item = {}, fluid = {}}
  for _, entity in ipairs(entities) do
    local recipe = entity.get_recipe()
    if recipe then
      local makes_target = false
      for _, product in ipairs(recipe.products or {}) do
        if product.type == "item" and product.name == target_item then makes_target = true; break end
      end
      if makes_target then
        local row = recipes[recipe.name]
        if not row then
          row = {
            name = recipe.name,
            count = 0,
            energy = recipe.energy,
            ingredients = copy_ingredients(recipe.ingredients),
            products = copy_products(recipe.products),
            statuses = {}
          }
          recipes[recipe.name] = row
          for _, ingredient in ipairs(recipe.ingredients or {}) do
            if ingredient_names[ingredient.type] then
              ingredient_names[ingredient.type][ingredient.name] = true
            end
          end
        end
        row.count = row.count + 1
        local status = status_by_value[entity.status] or "unknown"
        row.statuses[status] = (row.statuses[status] or 0) + 1
      end
    end
  end

  local recipe_rows = {}
  for _, row in pairs(recipes) do
    row.statuses = sorted_count_rows(row.statuses, "status")
    recipe_rows[#recipe_rows + 1] = row
  end
  table.sort(recipe_rows, function(a, b) return a.name < b.name end)

  local stats = player.force.get_item_production_statistics(player.surface)
  local minute = defines.flow_precision_index.one_minute
  local ten_minutes = defines.flow_precision_index.ten_minutes
  local names = {[target_item] = true}
  for name in pairs(ingredient_names.item) do names[name] = true end
  local flows = {}
  for name in pairs(names) do
    flows[#flows + 1] = {
      name = name,
      produced_per_minute = round(stats.get_flow_count({name=name, category="input", precision_index=minute}) or 0, 3),
      consumed_per_minute = round(stats.get_flow_count({name=name, category="output", precision_index=minute}) or 0, 3),
      produced_ten_minute_average = round(stats.get_flow_count({name=name, category="input", precision_index=ten_minutes}) or 0, 3),
      consumed_ten_minute_average = round(stats.get_flow_count({name=name, category="output", precision_index=ten_minutes}) or 0, 3)
    }
  end
  table.sort(flows, function(a, b) return a.name < b.name end)
  local fluid_stats = player.force.get_fluid_production_statistics(player.surface)
  local fluid_flows = {}
  for name in pairs(ingredient_names.fluid) do
    fluid_flows[#fluid_flows + 1] = {
      name = name,
      produced_per_minute = round(fluid_stats.get_flow_count({name=name, category="input", precision_index=minute}) or 0, 3),
      consumed_per_minute = round(fluid_stats.get_flow_count({name=name, category="output", precision_index=minute}) or 0, 3),
      produced_ten_minute_average = round(fluid_stats.get_flow_count({name=name, category="input", precision_index=ten_minutes}) or 0, 3),
      consumed_ten_minute_average = round(fluid_stats.get_flow_count({name=name, category="output", precision_index=ten_minutes}) or 0, 3)
    }
  end
  table.sort(fluid_flows, function(a, b) return a.name < b.name end)
  return {active_recipes = recipe_rows, item_flows = flows, fluid_flows = fluid_flows, issues = {}}
end

return Factory
