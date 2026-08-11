local State = require("scripts.core.state")
local Conflict = require("scripts.conflict.manager")
local WorldModel = require("scripts.sensors.world_model")

local PrototypeIndex = {}

local function sorted_entity_names()
  local names = {}
  for name in pairs(prototypes.entity) do names[#names + 1] = name end
  table.sort(names)
  return names
end

local function append(mapping, key, value)
  if not key then return end
  local values = mapping[key]
  if not values then values = {}; mapping[key] = values end
  values[#values + 1] = value
end

local function expected_amount(product)
  local amount = product.amount
  if not amount and product.amount_min and product.amount_max then
    amount = (product.amount_min + product.amount_max) / 2
  end
  return (amount or 1) * (product.probability or 1)
end

local function safe_property(prototype, name, fallback)
  local ok, value = pcall(function() return prototype[name] end)
  if ok then return value end
  return fallback
end

local function safe_method(prototype, name, fallback, ...)
  local method = prototype and prototype[name] or nil
  if type(method) ~= "function" then return fallback end
  local ok, value = pcall(method, ...)
  if ok and value ~= nil then return value end
  return fallback
end

local function copy_position(position)
  if not position then return nil end
  return {x = position.x or position[1] or 0, y = position.y or position[2] or 0}
end

local function copy_string_array(values)
  local result = {}
  for key, value in pairs(values or {}) do
    result[#result + 1] = type(key) == "number" and value or key
  end
  table.sort(result)
  return result
end

-- Never retain LuaObjects in storage. Fluid geometry is copied into plain
-- tables so saves stay serialisable and multiplayer peers derive identical
-- plans from the same runtime prototypes.
local function copy_fluidboxes(prototype)
  local result = {}
  for _, fluidbox in ipairs(safe_property(prototype, "fluidbox_prototypes", {}) or {}) do
    local connections = {}
    for _, connection in ipairs(fluidbox.pipe_connections or {}) do
      local positions = {}
      for _, position in ipairs(connection.positions or {}) do
        positions[#positions + 1] = copy_position(position)
      end
      connections[#connections + 1] = {
        connection_type = connection.connection_type,
        flow_direction = connection.flow_direction,
        direction = connection.direction,
        alt_direction = connection.alt_direction,
        alt_position = copy_position(connection.alt_position),
        max_underground_distance = connection.max_underground_distance,
        connection_category = copy_string_array(connection.connection_category),
        positions = positions
      }
    end
    result[#result + 1] = {
      index = fluidbox.index,
      production_type = fluidbox.production_type,
      filter = fluidbox.filter and fluidbox.filter.name or nil,
      minimum_temperature = fluidbox.minimum_temperature,
      maximum_temperature = fluidbox.maximum_temperature,
      volume = safe_method(fluidbox, "get_volume", 0, "normal"),
      pipe_connections = connections
    }
  end
  table.sort(result, function(a, b) return (a.index or 0) < (b.index or 0) end)
  return result
end

local function prototype_metadata(prototype)
  local burner_categories = nil
  if prototype.burner_prototype then
    burner_categories = {}
    for category in pairs(prototype.burner_prototype.fuel_categories or {}) do
      burner_categories[category] = true
    end
  end
  local resource_categories = nil
  if prototype.resource_categories then
    resource_categories = {}
    for category in pairs(prototype.resource_categories) do resource_categories[category] = true end
  end
  local inserter_reach = nil
  if prototype.type == "inserter" and prototype.inserter_pickup_position then
    inserter_reach = math.max(math.abs(prototype.inserter_pickup_position.x or 0),
      math.abs(prototype.inserter_pickup_position.y or 0))
  end
  return {
    tile_width = prototype.tile_width,
    tile_height = prototype.tile_height,
    burner_categories = burner_categories,
    electric = prototype.electric_energy_source_prototype ~= nil,
    resource_categories = resource_categories,
    mining_radius = prototype.type == "mining-drill" and prototype.get_mining_drill_radius() or nil,
    inserter_reach = inserter_reach,
    logistic_mode = prototype.type == "logistic-container" and safe_property(prototype, "logistic_mode") or nil,
    crafting_speed = safe_method(prototype, "get_crafting_speed", nil, "normal"),
    mining_speed = safe_property(prototype, "mining_speed"),
    module_inventory_size = safe_property(prototype, "module_inventory_size", 0),
    allowed_effects = safe_property(prototype, "allowed_effects"),
    allowed_module_categories = safe_property(prototype, "allowed_module_categories"),
    belt_speed = safe_property(prototype, "belt_speed"),
    inserter_rotation_speed = safe_method(prototype, "get_inserter_rotation_speed", nil, "normal"),
    pumping_speed = safe_method(prototype, "get_pumping_speed", nil, "normal"),
    fluid_source_offset = copy_position(safe_property(prototype, "fluid_source_offset")),
    fluidboxes = copy_fluidboxes(prototype)
  }
end

local function add_metadata(row, prototype)
  local metadata = prototype_metadata(prototype)
  for key, value in pairs(metadata) do row[key] = value end
  return row
end

local function index_mineable(index, prototype)
  local properties = prototype.mineable_properties
  if not properties or not properties.minable or properties.required_fluid then return end
  for _, product in ipairs(properties.products or {}) do
    if (product.type == "item" and prototypes.item[product.name])
        or (product.type == "fluid" and prototypes.fluid[product.name]) then
      append(index.resources_by_product, product.name, {
        entity = prototype.name,
        entity_type = prototype.type,
        category = prototype.resource_category,
        product_type = product.type,
        expected_amount = expected_amount(product)
      })
    end
  end
end

local function index_machine(index, prototype)
  local categories = prototype.crafting_categories
  local placement = prototype.items_to_place_this
  if not categories or not placement or #placement == 0 then return end
  local items = {}
  for _, item in ipairs(placement) do
    if prototypes.item[item.name] then items[#items + 1] = {name = item.name, count = item.count or 1} end
  end
  if #items == 0 then return end
  table.sort(items, function(a, b) return a.name < b.name end)
  local row = add_metadata({
    entity = prototype.name,
    entity_type = prototype.type,
    items = items
  }, prototype)
  for category in pairs(categories) do append(index.machines_by_category, category, row) end
end

local function index_placeable(index, prototype)
  local placement = prototype.items_to_place_this
  if not placement or #placement == 0 then return end
  local items = {}
  for _, item in ipairs(placement) do
    if prototypes.item[item.name] then items[#items + 1] = {name = item.name, count = item.count or 1} end
  end
  if #items == 0 then return end
  table.sort(items, function(a, b) return a.name < b.name end)
  local row = add_metadata({entity = prototype.name, entity_type = prototype.type, items = items}, prototype)
  if prototype.type == "electric-pole" then
    row.supply_area_distance = prototype.get_supply_area_distance()
    row.max_wire_distance = prototype.get_max_wire_distance()
  end
  append(index.entities_by_type, prototype.type, row)
end

function PrototypeIndex.start()
  local root = State.ensure()
  local fuels_by_category = {}
  for name, item in pairs(prototypes.item) do
    if item.fuel_category and item.fuel_value and item.fuel_value > 0 then
      append(fuels_by_category, item.fuel_category, {name = name, fuel_value = item.fuel_value})
    end
  end
  for _, fuels in pairs(fuels_by_category) do
    table.sort(fuels, function(a, b)
      if a.fuel_value == b.fuel_value then return a.name < b.name end
      return a.fuel_value < b.fuel_value
    end)
  end
  root.prototype_index = {
    status = "building",
    index = 1,
    names = sorted_entity_names(),
    resources_by_product = {},
    machines_by_category = {},
    entities_by_type = {},
    fuels_by_category = fuels_by_category,
    started_tick = game.tick
  }
end

function PrototypeIndex.on_nth_tick()
  local root = State.ensure()
  local index = root.prototype_index
  if not index or index.status ~= "building" then return end
  local processed = 0
  -- This is a one-time persistent bootstrap. Large K2SO packs can expose over
  -- ten thousand entity prototypes; batches of 250 finish in tens of seconds
  -- without the single-frame stall of a full synchronous index.
  while index.index <= #index.names and processed < 250 do
    local prototype = prototypes.entity[index.names[index.index]]
    if prototype then
      index_placeable(index, prototype)
      if prototype.type == "resource" or prototype.type == "tree" or prototype.type == "simple-entity" then
        index_mineable(index, prototype)
      end
      if prototype.type == "assembling-machine" or prototype.type == "furnace" or prototype.type == "rocket-silo" then
        index_machine(index, prototype)
      end
      root.metrics.prototype_index_rows = (root.metrics.prototype_index_rows or 0) + 1
    end
    index.index = index.index + 1
    processed = processed + 1
  end
  if index.index > #index.names then
    index.status = "ready"
    index.finished_tick = game.tick
    index.names = nil
    for _, rows in pairs(index.resources_by_product) do
      table.sort(rows, function(a, b) return a.entity < b.entity end)
    end
    for _, rows in pairs(index.machines_by_category) do
      table.sort(rows, function(a, b) return a.entity < b.entity end)
    end
    for _, rows in pairs(index.entities_by_type) do
      table.sort(rows, function(a, b) return a.entity < b.entity end)
    end
  end
end

function PrototypeIndex.is_ready()
  local index = State.ensure().prototype_index
  return index and index.status == "ready"
end

function PrototypeIndex.resources_for(item_name)
  local index = State.ensure().prototype_index
  return index and index.status == "ready" and index.resources_by_product[item_name] or nil
end

function PrototypeIndex.resource_products()
  local index = State.ensure().prototype_index
  if not index or index.status ~= "ready" then return {} end
  local result = {}
  for item_name, rows in pairs(index.resources_by_product or {}) do
    local resource_count = 0
    for _, row in ipairs(rows) do
      if row.entity_type == "resource" then resource_count = resource_count + 1 end
    end
    if resource_count > 0 and prototypes.item[item_name] then
      result[#result + 1] = {item = item_name, resource_count = resource_count}
    end
  end
  table.sort(result, function(a, b) return a.item < b.item end)
  return result
end

function PrototypeIndex.machines_for(category)
  local index = State.ensure().prototype_index
  return index and index.status == "ready" and index.machines_by_category[category] or nil
end

function PrototypeIndex.entities_for_type(entity_type)
  local index = State.ensure().prototype_index
  return index and index.status == "ready" and index.entities_by_type[entity_type] or nil
end

function PrototypeIndex.entity_row(entity_name)
  local index = State.ensure().prototype_index
  if not index or index.status ~= "ready" then return nil end
  for _, rows in pairs(index.entities_by_type or {}) do
    for _, row in ipairs(rows) do
      if row.entity == entity_name then return row end
    end
  end
  return nil
end

function PrototypeIndex.fuels_for(categories)
  local index = State.ensure().prototype_index
  if not index or index.status ~= "ready" then return nil end
  local result = {}
  local seen = {}
  for category in pairs(categories or {}) do
    for _, fuel in ipairs(index.fuels_by_category[category] or {}) do
      if not seen[fuel.name] then seen[fuel.name] = true; result[#result + 1] = fuel end
    end
  end
  table.sort(result, function(a, b)
    if a.fuel_value == b.fuel_value then return a.name < b.name end
    return a.fuel_value < b.fuel_value
  end)
  return result
end

local function resource_excluded(entity, exclusions)
  for _, exclusion in ipairs(exclusions or {}) do
    local dx = entity.position.x - exclusion.x
    local dy = entity.position.y - exclusion.y
    local radius = exclusion.radius or 48
    if dx * dx + dy * dy <= radius * radius then return true end
  end
  return false
end

local function store_resource_search(diagnostics, best)
  if best and best.valid then
    diagnostics.result = {
      name = best.name,
      type = best.type,
      position = {x = best.position.x, y = best.position.y}
    }
  end
  State.ensure().metrics.last_resource_search = diagnostics
end

local function find_resource_patch(agent, candidates, source, max_radius, allow_machine_only,
    exclusions, diagnostics, character_categories)
  local names = {}
  for _, candidate in ipairs(candidates) do
    if candidate.entity_type == "resource"
        and (allow_machine_only or character_categories[candidate.category]) then
      names[#names + 1] = candidate.entity
    end
  end
  if #names == 0 then return nil end
  table.sort(names)
  local name_filter = #names == 1 and names[1] or names
  local center_x = math.floor(agent.position.x / 32)
  local center_y = math.floor(agent.position.y / 32)
  local max_ring = math.ceil(max_radius / 32) + 1
  diagnostics.chunk_ring_queries = 0

  -- The background index already knows which charted chunks contain each
  -- resource prototype. Resolve only the nearest candidate chunks against the
  -- live surface. The old expanding-ring search could issue around a hundred
  -- large spatial queries and freeze a 50k-entity factory for 0.8 seconds each
  -- time autonomy selected its next mining chain.
  local indexed = WorldModel.resource_chunk_candidates(agent, names, agent.position, max_radius, 64)
  diagnostics.indexed_chunk_candidates = #indexed
  local indexed_best, indexed_best_distance = nil, nil
  for _, chunk in ipairs(indexed) do
    if indexed_best_distance and chunk.minimum_distance > indexed_best_distance then break end
    diagnostics.chunk_ring_queries = diagnostics.chunk_ring_queries + 1
    local entities = agent.surface.find_entities_filtered({
      area = chunk.area,
      type = "resource",
      name = name_filter,
      limit = 256
    })
    for _, entity in ipairs(entities) do
      if entity.valid and entity.amount and entity.amount > 0
          and not resource_excluded(entity, exclusions)
          and not Conflict.is_blocked(entity.surface.index, entity.position, source) then
        local dx = entity.position.x - agent.position.x
        local dy = entity.position.y - agent.position.y
        local distance = dx * dx + dy * dy
        if distance <= max_radius * max_radius
            and (not indexed_best_distance or distance < indexed_best_distance) then
          indexed_best, indexed_best_distance = entity, distance
        end
      end
    end
  end
  if indexed_best then
    diagnostics.source = "world_model_chunk_index"
    return indexed_best
  end

  local function scan_chunk_rectangle(min_x, min_y, max_x, max_y, best, best_distance)
    diagnostics.chunk_ring_queries = diagnostics.chunk_ring_queries + 1
    local entities = agent.surface.find_entities_filtered({
      area = {{min_x * 32, min_y * 32}, {(max_x + 1) * 32, (max_y + 1) * 32}},
      type = "resource",
      name = name_filter,
      limit = 256
    })
    for _, entity in ipairs(entities) do
      if entity.valid and entity.amount and entity.amount > 0
          and not resource_excluded(entity, exclusions)
          and not Conflict.is_blocked(entity.surface.index, entity.position, source) then
        local dx = entity.position.x - agent.position.x
        local dy = entity.position.y - agent.position.y
        local candidate_distance = dx * dx + dy * dy
        if candidate_distance <= max_radius * max_radius
            and (not best_distance or candidate_distance < best_distance) then
          best, best_distance = entity, candidate_distance
        end
      end
    end
    return best, best_distance
  end

  -- Engine result limits are not nearest-first. Querying one expanding chunk
  -- ring at a time prevents a distant, earlier-created ore patch from hiding
  -- the closer marked/fixture deposit while keeping each result set bounded.
  for ring = 0, max_ring do
    local best, best_distance = nil, nil
    if ring == 0 then
      best, best_distance = scan_chunk_rectangle(center_x, center_y, center_x, center_y)
    else
      best, best_distance = scan_chunk_rectangle(center_x - ring, center_y - ring,
        center_x + ring, center_y - ring, best, best_distance)
      best, best_distance = scan_chunk_rectangle(center_x - ring, center_y + ring,
        center_x + ring, center_y + ring, best, best_distance)
      if ring > 1 then
        best, best_distance = scan_chunk_rectangle(center_x - ring, center_y - ring + 1,
          center_x - ring, center_y + ring - 1, best, best_distance)
        best, best_distance = scan_chunk_rectangle(center_x + ring, center_y - ring + 1,
          center_x + ring, center_y + ring - 1, best, best_distance)
      end
    end
    if best then
      diagnostics.found_ring = ring
      return best
    end
  end
  return nil
end

function PrototypeIndex.find_resource(agent, item_name, source, radius, allow_machine_only, exclusions, resource_only)
  local candidates = PrototypeIndex.resources_for(item_name)
  local diagnostics = {
    tick = game.tick,
    item = item_name,
    source = source,
    surface = agent.surface.name,
    position = {x = agent.position.x, y = agent.position.y},
    radius = radius or 96,
    allow_machine_only = allow_machine_only == true,
    resource_only = resource_only == true,
    candidate_count = candidates and #candidates or 0,
    candidates = {}
  }
  if not candidates then store_resource_search(diagnostics, nil); return nil end
  local character_categories = agent.prototype.resource_categories or {}
  local best = nil
  local best_distance = nil
  local max_radius = radius or 96
  if resource_only then
    local result = find_resource_patch(agent, candidates, source, max_radius, allow_machine_only,
      exclusions, diagnostics, character_categories)
    store_resource_search(diagnostics, result)
    return result
  end
  local steps = {16, 32, 64, max_radius}
  local seen_step = {}
  local diagnostic_rows = {}
  for index, candidate in ipairs(candidates) do
    if index <= 32 then
      local row = {
        entity = candidate.entity,
        entity_type = candidate.entity_type,
        category = candidate.category,
        category_allowed = candidate.entity_type ~= "resource" or allow_machine_only
          or character_categories[candidate.category] == true,
        live = 0,
        blocked = 0,
        excluded = 0
      }
      diagnostics.candidates[#diagnostics.candidates + 1] = row
      diagnostic_rows[candidate.entity] = row
    end
  end
  for _, scan_radius in ipairs(steps) do
    scan_radius = math.min(scan_radius, max_radius)
    if scan_radius > 0 and not seen_step[scan_radius] then
      seen_step[scan_radius] = true
      for _, candidate in ipairs(candidates) do
        if (not resource_only or candidate.entity_type == "resource")
            and (candidate.entity_type ~= "resource" or allow_machine_only
            or character_categories[candidate.category]) then
          local entities = agent.surface.find_entities_filtered({
            position = agent.position,
            radius = scan_radius,
            type = candidate.entity_type,
            name = candidate.entity,
            limit = 64
          })
          local diagnostic = diagnostic_rows[candidate.entity]
          if diagnostic then
            diagnostic.scan_radius = scan_radius
            diagnostic.live = #entities
          end
          for _, entity in ipairs(entities) do
            local available = candidate.entity_type ~= "resource" or (entity.amount and entity.amount > 0)
            local excluded = entity.valid and resource_excluded(entity, exclusions)
            local blocked = false
            if entity.valid and available and not excluded then
              blocked = Conflict.is_blocked(entity.surface.index, entity.position, source)
            end
            if diagnostic and excluded then diagnostic.excluded = diagnostic.excluded + 1 end
            if diagnostic and blocked then diagnostic.blocked = diagnostic.blocked + 1 end
            if entity.valid and available and not excluded and not blocked then
              local dx = entity.position.x - agent.position.x
              local dy = entity.position.y - agent.position.y
              local distance = dx * dx + dy * dy
              if not best_distance or distance < best_distance then
                best = entity
                best_distance = distance
              end
            end
          end
        end
      end
      if best then store_resource_search(diagnostics, best); return best end
    end
  end
  store_resource_search(diagnostics, nil)
  return nil
end

return PrototypeIndex
