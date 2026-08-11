local State = require("scripts.core.state")
local Factory = require("scripts.sensors.factory")
local Conflict = require("scripts.conflict.manager")
local RecipeIndex = require("scripts.sensors.recipe_index")
local WorldModel = require("scripts.sensors.world_model")

local World = {}

local function distance(a, b)
  local dx = a.x - b.x
  local dy = a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

local function setting(name, fallback)
  local value = settings.global[name]
  return value and value.value or fallback
end

local function mining_products(prototype)
  local properties = prototype and prototype.mineable_properties or nil
  local result = {}
  if not properties or not properties.products then return result end

  for _, product in ipairs(properties.products) do
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

local function bounded_nearby_resources(surface, position, radius, limit)
  -- LuaSurface does not promise distance ordering when a filter has a limit.
  -- A single large far-away patch could therefore hide a resource beside the
  -- player. Concentric queries preserve a hard upper bound while giving nearby
  -- entities the first chance to enter the snapshot.
  local steps = {}
  local function add_step(value)
    value = math.min(value, radius)
    if value > 0 and steps[#steps] ~= value then steps[#steps + 1] = value end
  end
  add_step(16)
  add_step(32)
  add_step(radius)

  local result = {}
  local seen = {}
  local truncated = false
  for _, scan_radius in ipairs(steps) do
    local batch = surface.find_entities_filtered({
      position = position,
      radius = scan_radius,
      type = "resource",
      limit = limit
    })
    if #batch >= limit then truncated = true end

    for _, entity in ipairs(batch) do
      -- Resource entities normally have no unit_number. A resource prototype
      -- can occupy each map position only once, so this key is stable for the
      -- lifetime of this one snapshot and works for modded resource names too.
      local key = entity.name .. "@" .. tostring(entity.position.x) .. "," .. tostring(entity.position.y)
      if not seen[key] then
        seen[key] = true
        result[#result + 1] = entity
        if #result >= limit then return result, true end
      end
    end
  end
  return result, truncated
end

local function resource_snapshot(surface, position)
  local radius = setting("alina-sensor-radius", 64)
  local limit = setting("alina-resource-scan-limit", 256)
  local entities, truncated = bounded_nearby_resources(surface, position, radius, limit)

  local grouped = {}
  for _, entity in ipairs(entities) do
    if entity.valid and entity.amount and entity.amount > 0 then
      local row = grouped[entity.name]
      local nearest = distance(position, entity.position)
      if not row then
        local properties = entity.prototype.mineable_properties
        row = {
          name = entity.name,
          amount = 0,
          entities = 0,
          nearest_distance = nearest,
          resource_category = entity.prototype.resource_category,
          required_fluid = properties and properties.required_fluid or nil,
          products = mining_products(entity.prototype)
        }
        grouped[entity.name] = row
      end

      row.amount = row.amount + entity.amount
      row.entities = row.entities + 1
      if nearest < row.nearest_distance then
        row.nearest_distance = nearest
      end
    end
  end

  local result = {}
  for _, row in pairs(grouped) do
    row.nearest_distance = math.floor(row.nearest_distance * 10 + 0.5) / 10
    result[#result + 1] = row
  end
  table.sort(result, function(a, b)
    if a.nearest_distance == b.nearest_distance then
      return a.name < b.name
    end
    return a.nearest_distance < b.nearest_distance
  end)

  while #result > 16 do
    table.remove(result)
  end
  return result, truncated
end

function World.snapshot(player)
  local root = State.ensure()
  local resources, truncated = resource_snapshot(player.surface, player.position)
  local known_resources = WorldModel.known_resources(player, 16)
  local model_summary = WorldModel.summary(player)
  root.metrics.sensor_scans = root.metrics.sensor_scans + 1

  local agent = root.agent.entity
  local agent_snapshot = {present = false}
  if agent and agent.valid then
    local inventory = agent.get_inventory(defines.inventory.character_main)
    agent_snapshot = {
      present = true,
      surface = agent.surface.name,
      position = {x = agent.position.x, y = agent.position.y},
      empty_inventory_slots = inventory and inventory.count_empty_stacks() or 0
    }
  end

  local research = nil
  if player.force.current_research then
    research = {
      name = player.force.current_research.name,
      progress = math.floor(player.force.research_progress * 1000 + 0.5) / 1000
    }
  end

  local researched_count = 0
  local available_technologies = {}
  for name, technology in pairs(player.force.technologies) do
    if technology.researched then
      researched_count = researched_count + 1
    elseif technology.enabled and not technology.prototype.hidden then
      local ready = true
      for _, prerequisite in pairs(technology.prerequisites or {}) do
        if not prerequisite.researched then ready = false; break end
      end
      if ready then available_technologies[#available_technologies + 1] = name end
    end
  end
  table.sort(available_technologies)
  while #available_technologies > 24 do table.remove(available_technologies) end

  local sensor_radius = setting("alina-sensor-radius", 64)
  local factory = Factory.snapshot(player)

  local available_items = {}
  local existing_products = {}
  for _, resource in ipairs(resources) do
    for _, product in ipairs(resource.products or {}) do
      if product.type == "item" then available_items[product.name] = true end
    end
  end
  for _, flow in ipairs(factory.item_flows or {}) do
    if (flow.produced_per_minute or 0) > 0.001 then available_items[flow.name] = true end
  end
  for _, group in ipairs(factory.storage or {}) do
    for _, item in ipairs(group.items or {}) do
      if (item.count or 0) > 0 then available_items[item.name] = true end
    end
  end
  local player_inventory = player.get_main_inventory()
  if player_inventory then
    -- Factorio 2.1 returns an array of ItemWithQualityCount tables here,
    -- not the pre-2.0 name -> count dictionary. Quality is intentionally
    -- collapsed because the development planner reasons on item prototypes.
    for _, item in ipairs(player_inventory.get_contents()) do
      if (item.count or 0) > 0 and item.name then
        available_items[item.name] = true
      end
    end
  end
  if agent and agent.valid then
    local agent_inventory = agent.get_inventory(defines.inventory.character_main)
    if agent_inventory then
      for _, item in ipairs(agent_inventory.get_contents()) do
        if (item.count or 0) > 0 and item.name then
          available_items[item.name] = true
        end
      end
    end
  end
  for _, recipe in ipairs(factory.active_recipes or {}) do
    for _, product in ipairs(recipe.products or {}) do
      if product.type == "item" then
        existing_products[product.name] = true
        available_items[product.name] = true
      end
    end
  end
  factory.development_candidates = RecipeIndex.development_candidates(
    player.force, available_items, existing_products, 8)

  local suppressed = {}
  for item_name, until_tick in pairs(root.autonomy.suppressed_items or {}) do
    if type(until_tick) == "number" and until_tick > game.tick then
      suppressed[#suppressed + 1] = item_name
    end
  end
  table.sort(suppressed)

  return {
    schema_version = 1,
    surface = player.surface.name,
    player_position = {x = player.position.x, y = player.position.y},
    alina = agent_snapshot,
    current_research = research,
    technology = {
      researched_count = researched_count,
      available = available_technologies
    },
    nearby_resources = resources,
    known_charted_resources = known_resources,
    known_factory = model_summary,
    resources_truncated = truncated,
    factory = factory,
    player_intent = Conflict.snapshot(player.surface.index, player.position, sensor_radius),
    sensor_radius = sensor_radius,
    autonomy_suppressed_items = suppressed,
    current_task = root.task.current and {
      type = root.task.current.type,
      status = root.task.current.status,
      summary = root.task.current.summary
    } or nil,
    paused = root.paused
  }
end

return World
