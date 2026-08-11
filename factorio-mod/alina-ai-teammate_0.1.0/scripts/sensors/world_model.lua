local State = require("scripts.core.state")

local WorldModel = {}
local RESOURCE_SAMPLE_LIMIT_PER_CHUNK = 96

-- The world model is deliberately data-oriented.  It does not use screenshots
-- and it does not make Alina walk somewhere just to "look" at a machine.
-- Player-owned entities are known directly; resources are indexed only in
-- charted chunks so unexplored territory is not revealed by the mod.

-- Only entities that autonomy may address individually are retained by unit
-- number. High-cardinality infrastructure is summarized per chunk below; a
-- megabase can contain hundreds of thousands of belts and pipes, and keeping a
-- Lua table for every one of them creates large deterministic GC stalls.
local DETAILED_TYPES = {
  ["assembling-machine"] = true,
  furnace = true,
  ["mining-drill"] = true,
  lab = true,
  beacon = true,
  boiler = true,
  generator = true,
  reactor = true,
  ["rocket-silo"] = true,
  ["agricultural-tower"] = true,
  ["asteroid-collector"] = true,
  thruster = true,
  ["storage-tank"] = true,
  pump = true,
  ["electric-pole"] = true,
  container = true,
  ["logistic-container"] = true,
  ["linked-container"] = true
}

local DETAILED_TYPE_LIST = {
  "assembling-machine", "furnace", "mining-drill", "lab", "beacon",
  "boiler", "generator", "reactor", "rocket-silo", "agricultural-tower",
  "asteroid-collector", "thruster", "storage-tank", "pump", "electric-pole",
  "container", "logistic-container", "linked-container"
}

local AGGREGATE_TYPES = {
  inserter = true,
  ["transport-belt"] = true,
  ["underground-belt"] = true,
  splitter = true,
  pipe = true,
  ["pipe-to-ground"] = true,
  roboport = true,
  accumulator = true,
  ["solar-panel"] = true
}

local MACHINE_TYPES = {
  ["assembling-machine"] = true,
  furnace = true,
  ["mining-drill"] = true,
  lab = true,
  ["rocket-silo"] = true
}

local CRAFTING_TYPES = {
  ["assembling-machine"] = true,
  furnace = true,
  ["rocket-silo"] = true
}

local POWER_ISSUE = {
  [defines.entity_status.no_power] = true,
  [defines.entity_status.low_power] = true,
  [defines.entity_status.not_plugged_in_electric_network] = true
}

local function setting(name, fallback)
  local value = settings.global[name]
  return value and value.value or fallback
end

local function chunk_key(x, y)
  return tostring(x) .. ":" .. tostring(y)
end

local function chunk_of(position)
  return {x = math.floor(position.x / 32), y = math.floor(position.y / 32)}
end

local function surface_state(root, surface_index)
  root.world_model = root.world_model or {version = 2, surfaces = {}}
  root.world_model.surfaces = root.world_model.surfaces or {}
  local row = root.world_model.surfaces[surface_index]
  if not row then
    row = {
      entities = {},
      type_units = {},
      recipe_units = {},
      selection_version = 0,
      chunk_units = {},
      chunk_aggregates = {},
      aggregate_type_totals = {},
      aggregate_entity_count = 0,
      resources = {},
      resource_totals = {},
      queue = {},
      queue_head = 1,
      priority_queue = {},
      priority_head = 1,
      priority_queued = {},
      queued = {},
      queued_count = 0,
      scanned_chunks = {},
      scanned_chunk_count = 0,
      entity_count = 0,
      item_sources = {},
      last_scan_tick = 0,
      bootstrap_center = nil,
      bootstrap_radius_chunks = 0
    }
    root.world_model.surfaces[surface_index] = row
  end
  row.entities = row.entities or {}
  row.type_units = row.type_units or {}
  if not row.recipe_units then
    row.recipe_units = {}
    for unit, record in pairs(row.entities) do
      if record.recipe then
        row.recipe_units[record.recipe] = row.recipe_units[record.recipe] or {}
        row.recipe_units[record.recipe][unit] = true
      end
    end
  end
  row.selection_version = row.selection_version or 0
  row.chunk_units = row.chunk_units or {}
  row.chunk_aggregates = row.chunk_aggregates or {}
  row.aggregate_type_totals = row.aggregate_type_totals or {}
  row.aggregate_entity_count = row.aggregate_entity_count or 0
  row.resources = row.resources or {}
  if not row.resource_totals then
    row.resource_totals = {}
    for _, resources in pairs(row.resources) do
      for name, resource in pairs(resources or {}) do
        local total = row.resource_totals[name]
        if not total then total = {name = name, amount = 0, entities = 0}; row.resource_totals[name] = total end
        total.amount = total.amount + (resource.amount or 0)
        total.entities = total.entities + (resource.entities or 0)
      end
    end
  end
  row.queue = row.queue or {}
  row.queue_head = row.queue_head or 1
  row.priority_queue = row.priority_queue or {}
  row.priority_head = row.priority_head or 1
  row.priority_queued = row.priority_queued or {}
  row.queued = row.queued or {}
  if row.queued_count == nil then
    row.queued_count = 0
    for _ in pairs(row.queued) do row.queued_count = row.queued_count + 1 end
  end
  row.scanned_chunks = row.scanned_chunks or {}
  if row.scanned_chunk_count == nil then
    row.scanned_chunk_count = 0
    for _ in pairs(row.scanned_chunks) do row.scanned_chunk_count = row.scanned_chunk_count + 1 end
  end
  if row.entity_count == nil then
    row.entity_count = 0
    for _ in pairs(row.entities) do row.entity_count = row.entity_count + 1 end
  end
  if not row.item_sources then
    row.item_sources = {}
    for unit, record in pairs(row.entities) do
      for item_name, count in pairs(record.contents or {}) do
        row.item_sources[item_name] = row.item_sources[item_name] or {}
        row.item_sources[item_name][unit] = count
      end
    end
  end
  return row
end

local function force_id(force)
  return force and force.index or nil
end

local function recipe_name(entity)
  if not CRAFTING_TYPES[entity.type] then return nil end
  local recipe = entity.get_recipe()
  return recipe and recipe.name or nil
end

local function source_inventory(entity)
  if entity.type == "container" or entity.type == "logistic-container"
      or entity.type == "linked-container" then
    return defines.inventory.chest
  end
  if entity.type == "assembling-machine" or entity.type == "furnace" then
    return defines.inventory.crafter_output
  end
  return nil
end

local function inventory_contents(entity)
  local inventory_index = source_inventory(entity)
  if not inventory_index then return nil end
  local inventory = entity.get_inventory(inventory_index)
  if not inventory then return nil end
  local contents = {}
  local rows = inventory.get_contents()
  local recorded = 0
  for key, value in pairs(rows or {}) do
    local name, count, quality = nil, nil, "normal"
    if type(value) == "table" then
      name, count, quality = value.name, value.count, value.quality or "normal"
    elseif type(key) == "string" and type(value) == "number" then
      name, count = key, value
    end
    -- Autonomous work deliberately consumes normal-quality stock only.  A
    -- string item id in Factorio 2.1 also means normal quality, so excluding
    -- rarer stacks here keeps the cache consistent with the eventual
    -- get_item_count/remove calls and prevents valuable modded items from
    -- being treated as routine construction supplies.
    if name and count and count > 0 and quality == "normal" then
      contents[name] = (contents[name] or 0) + count
      recorded = recorded + 1
      if recorded >= 128 then break end
    end
  end
  return contents
end

local function remove_item_sources(surface, record)
  if not record then return end
  for item_name in pairs(record.contents or {}) do
    local units = surface.item_sources[item_name]
    if units then
      units[record.unit_number] = nil
      if next(units) == nil then surface.item_sources[item_name] = nil end
    end
  end
end

local function forget_unit_from_surface(surface, unit)
  local row = surface.entities[unit]
  if not row then return end
  remove_item_sources(surface, row)
  if row.chunk_key and surface.chunk_units[row.chunk_key] then surface.chunk_units[row.chunk_key][unit] = nil end
  if row.entity_type and surface.type_units[row.entity_type] then surface.type_units[row.entity_type][unit] = nil end
  if row.recipe and surface.recipe_units[row.recipe] then
    surface.recipe_units[row.recipe][unit] = nil
    if next(surface.recipe_units[row.recipe]) == nil then surface.recipe_units[row.recipe] = nil end
  end
  surface.entities[unit] = nil
  surface.entity_count = math.max(0, (surface.entity_count or 1) - 1)
  surface.selection_version = (surface.selection_version or 0) + 1
  surface.snapshot_selection = nil
end

local function observe_entity_internal(root, entity)
  if not entity or not entity.valid or not entity.unit_number or not DETAILED_TYPES[entity.type] then return false end
  local surface = surface_state(root, entity.surface.index)
  local chunk = chunk_of(entity.position)
  local key = chunk_key(chunk.x, chunk.y)
  local previous = surface.entities[entity.unit_number]
  if previous then remove_item_sources(surface, previous) end
  if previous and previous.chunk_key and previous.chunk_key ~= key then
    local old = surface.chunk_units[previous.chunk_key]
    if old then old[entity.unit_number] = nil end
  end
  if previous and previous.entity_type and previous.entity_type ~= entity.type
      and surface.type_units[previous.entity_type] then
    surface.type_units[previous.entity_type][entity.unit_number] = nil
  end
  local contents = inventory_contents(entity)
  local current_recipe = recipe_name(entity)
  if previous and previous.recipe and previous.recipe ~= current_recipe
      and surface.recipe_units[previous.recipe] then
    surface.recipe_units[previous.recipe][entity.unit_number] = nil
    if next(surface.recipe_units[previous.recipe]) == nil then surface.recipe_units[previous.recipe] = nil end
  end
  surface.entities[entity.unit_number] = {
    unit_number = entity.unit_number,
    name = entity.name,
    entity_type = entity.type,
    surface_index = entity.surface.index,
    force_index = force_id(entity.force),
    position = {x = entity.position.x, y = entity.position.y},
    direction = entity.direction,
    recipe = current_recipe,
    chunk_key = key,
    last_seen_tick = game.tick,
    contents = contents
  }
  if not previous then surface.entity_count = (surface.entity_count or 0) + 1 end
  surface.chunk_units[key] = surface.chunk_units[key] or {}
  surface.chunk_units[key][entity.unit_number] = true
  surface.type_units[entity.type] = surface.type_units[entity.type] or {}
  surface.type_units[entity.type][entity.unit_number] = true
  if current_recipe then
    surface.recipe_units[current_recipe] = surface.recipe_units[current_recipe] or {}
    surface.recipe_units[current_recipe][entity.unit_number] = true
  end
  if not previous or previous.entity_type ~= entity.type or previous.recipe ~= current_recipe then
    surface.selection_version = (surface.selection_version or 0) + 1
    surface.snapshot_selection = nil
  end
  for item_name, count in pairs(contents or {}) do
    surface.item_sources[item_name] = surface.item_sources[item_name] or {}
    surface.item_sources[item_name][entity.unit_number] = count
  end
  return true
end

local queue_chunk

function WorldModel.observe_entity(entity)
  if not entity or not entity.valid then return false end
  if DETAILED_TYPES[entity.type] then return observe_entity_internal(State.ensure(), entity) end
  -- Belts, pipes, inserters and containers are deliberately not persisted per
  -- unit. Their live layout is queried only by the bounded planner that needs
  -- it; build events for them must not cause a factory-chunk rescan.
  if AGGREGATE_TYPES[entity.type] then return true end
  return false
end

function WorldModel.forget_entity(entity_or_unit, surface_index)
  local root = State.ensure()
  if type(entity_or_unit) ~= "number" and entity_or_unit and entity_or_unit.valid
      and AGGREGATE_TYPES[entity_or_unit.type] then return end
  local unit = type(entity_or_unit) == "number" and entity_or_unit
    or (entity_or_unit and entity_or_unit.unit_number)
  if not unit then return end
  if surface_index then
    local surface = root.world_model and root.world_model.surfaces and root.world_model.surfaces[surface_index]
    if not surface then return end
    forget_unit_from_surface(surface, unit)
    return
  end
  for _, surface in pairs(root.world_model and root.world_model.surfaces or {}) do
    local row = surface.entities and surface.entities[unit]
    if row then
      forget_unit_from_surface(surface, unit)
      return
    end
  end
end

queue_chunk = function(root, surface, force, chunk, priority)
  if not surface or not force or not chunk then return false end
  if not surface.is_chunk_generated(chunk) then return false end
  local state = surface_state(root, surface.index)
  local key = chunk_key(chunk.x, chunk.y)
  if state.queued[key] then
    if priority and not state.priority_queued[key] then
      state.priority_queue[#state.priority_queue + 1] = {
        surface_index = surface.index, force_index = force.index,
        x = chunk.x, y = chunk.y, key = key
      }
      state.priority_queued[key] = true
    end
    return false
  end
  state.queued[key] = true
  state.queued_count = state.queued_count + 1
  local row = {surface_index = surface.index, force_index = force.index, x = chunk.x, y = chunk.y, key = key}
  if priority then
    state.priority_queue[#state.priority_queue + 1] = row
    state.priority_queued[key] = true
  else
    state.queue[#state.queue + 1] = row
  end
  return true
end

function WorldModel.queue_chunk(surface, force, chunk, priority)
  queue_chunk(State.ensure(), surface, force, chunk, priority)
end

local function enqueue_ring(root, surface, force, center, radius_chunks, priority_radius)
  local center_chunk = chunk_of(center)
  for r = 0, radius_chunks do
    local priority = r <= (priority_radius or 0)
    if r == 0 then
      queue_chunk(root, surface, force, center_chunk, priority)
    else
      for dx = -r, r do
        queue_chunk(root, surface, force, {x = center_chunk.x + dx, y = center_chunk.y - r}, priority)
        queue_chunk(root, surface, force, {x = center_chunk.x + dx, y = center_chunk.y + r}, priority)
      end
      for dy = -r + 1, r - 1 do
        queue_chunk(root, surface, force, {x = center_chunk.x - r, y = center_chunk.y + dy}, priority)
        queue_chunk(root, surface, force, {x = center_chunk.x + r, y = center_chunk.y + dy}, priority)
      end
    end
  end
end

function WorldModel.seed_player(player)
  if not player or not player.valid then return end
  local root = State.ensure()
  local radius_tiles = setting("alina-world-model-radius", 384)
  local radius_chunks = math.max(4, math.ceil(radius_tiles / 32))
  local state = surface_state(root, player.surface.index)
  state.bootstrap_center = {x = player.position.x, y = player.position.y}
  state.bootstrap_radius_chunks = radius_chunks
  local first_bootstrap = next(state.scanned_chunks) == nil and next(state.entities) == nil
  -- The inner ~160 tiles are indexed first so an existing micro-base becomes
  -- useful within a few seconds.  A persisted model does not rescan hundreds of
  -- chunks on every load; future changes are tracked by Factorio events.
  enqueue_ring(root, player.surface, player.force, player.position, first_bootstrap and radius_chunks or 5, 5)
end

-- A direct development request must reason from the current saved factory, not
-- from a possibly incomplete model persisted while the player was elsewhere.
-- Refreshing generated chunks is deterministic and bounded; it does not walk
-- the character around, read screenshots, or dump the whole world every tick.
function WorldModel.request_factory_refresh(player, radius_chunks)
  if not player or not player.valid then return 0 end
  local root = State.ensure()
  radius_chunks = math.max(2, math.min(8, math.floor(tonumber(radius_chunks) or 6)))
  local state = surface_state(root, player.surface.index)
  local center = chunk_of(player.position)
  local refresh = {requested_tick = game.tick, remaining = {}, remaining_count = 0}
  local count = 0
  local function mark(dx, dy)
    local chunk = {x = center.x + dx, y = center.y + dy}
    if player.surface.is_chunk_generated(chunk) then
      local key = chunk_key(chunk.x, chunk.y)
      if not refresh.remaining[key] then count = count + 1 end
      refresh.remaining[key] = true
      queue_chunk(root, player.surface, player.force, chunk, true)
    end
  end
  -- The dedicated priority FIFO is consumed from the front, so enqueue the
  -- player's current district first and expand outward deterministically.
  for radius = 0, radius_chunks do
    if radius == 0 then
      mark(0, 0)
    else
      for dx = -radius, radius do
        mark(dx, -radius)
        mark(dx, radius)
      end
      for dy = -radius + 1, radius - 1 do
        mark(-radius, dy)
        mark(radius, dy)
      end
    end
  end
  refresh.remaining_count = count
  state.development_refresh = refresh
  return count
end

function WorldModel.factory_refresh_pending(player)
  if not player or not player.valid then return 0 end
  local state = surface_state(State.ensure(), player.surface.index)
  local refresh = state.development_refresh
  if not refresh or not refresh.remaining then return 0 end
  if refresh.remaining_count == nil then
    refresh.remaining_count = 0
    for _ in pairs(refresh.remaining) do refresh.remaining_count = refresh.remaining_count + 1 end
  end
  return refresh.remaining_count
end

function WorldModel.initialize()
  local root = State.ensure()
  if not root.world_model or root.world_model.version ~= 2 then
    root.world_model = {version = 2, surfaces = {}}
  end
  for _, player in pairs(game.connected_players) do WorldModel.seed_player(player) end
end

local function resource_summary(surface, force, chunk, area)
  if not force.is_chunk_charted(surface, chunk) then return nil end
  local grouped = {}
  -- Resource entities are one-per-tile and a rich modded ore chunk may contain
  -- thousands. The World Model needs presence and a bounded amount sample for
  -- diagnosis; mine construction performs its own exact local patch scan.
  local resources = surface.find_entities_filtered({
    area = area, type = "resource", limit = RESOURCE_SAMPLE_LIMIT_PER_CHUNK
  })
  for _, entity in ipairs(resources) do
    if entity.valid and entity.amount and entity.amount > 0 then
      local row = grouped[entity.name]
      if not row then
        row = {name = entity.name, amount = 0, entities = 0, position_x_total = 0, position_y_total = 0}
        grouped[entity.name] = row
      end
      row.amount = row.amount + entity.amount
      row.entities = row.entities + 1
      row.position_x_total = row.position_x_total + entity.position.x
      row.position_y_total = row.position_y_total + entity.position.y
    end
  end
  for _, row in pairs(grouped) do
    row.position = {
      x = row.position_x_total / math.max(1, row.entities),
      y = row.position_y_total / math.max(1, row.entities)
    }
    row.position_x_total = nil
    row.position_y_total = nil
  end
  return grouped
end

local function scan_chunk(root, queued)
  local surface = game.surfaces[queued.surface_index]
  local force = game.forces[queued.force_index]
  local state = surface_state(root, queued.surface_index)
  if not surface or not force then
    if state.queued[queued.key] then
      state.queued[queued.key] = nil
      state.queued_count = math.max(0, state.queued_count - 1)
    end
    if state.development_refresh and state.development_refresh.remaining
        and state.development_refresh.remaining[queued.key] then
      state.development_refresh.remaining[queued.key] = nil
      state.development_refresh.remaining_count = math.max(0,
        (state.development_refresh.remaining_count or 1) - 1)
    end
    return
  end
  local x0, y0 = queued.x * 32, queued.y * 32
  local area = {{x0, y0}, {x0 + 32, y0 + 32}}
  local seen = {}
  -- Ask the engine only for the relatively sparse entities that autonomy may
  -- address individually. Returning every belt and pipe as a LuaEntity made a
  -- 34k-entity factory spend hundreds of seconds on its initial bootstrap.
  local entities = surface.find_entities_filtered({
    area = area, force = force, type = DETAILED_TYPE_LIST
  })
  for _, entity in ipairs(entities) do
    if entity.valid and entity.unit_number then
      observe_entity_internal(root, entity)
      seen[entity.unit_number] = true
    end
  end

  local previous = state.chunk_units[queued.key] or {}
  for unit in pairs(previous) do
    if not seen[unit] then
      local entity = game.get_entity_by_unit_number(unit)
      if not entity or not entity.valid or entity.surface.index ~= surface.index
          or chunk_key(chunk_of(entity.position).x, chunk_of(entity.position).y) ~= queued.key then
        forget_unit_from_surface(state, unit)
        previous[unit] = nil
      end
    end
  end
  state.chunk_units[queued.key] = seen
  -- High-cardinality transport infrastructure is intentionally not counted
  -- here. A count query per chunk still walks large force indexes and produced
  -- reproducible multi-second stalls on a belt-heavy megabase. Consumers use
  -- scanned chunk coverage plus individually indexed production/power entities;
  -- route planners query nearby live transport only when a task needs it.
  local previous_resources = state.resources[queued.key]
  for name, resource in pairs(previous_resources or {}) do
    local total = state.resource_totals[name]
    if total then
      total.amount = math.max(0, total.amount - (resource.amount or 0))
      total.entities = math.max(0, total.entities - (resource.entities or 0))
      if total.amount == 0 and total.entities == 0 then state.resource_totals[name] = nil end
    end
  end
  local current_resources = resource_summary(surface, force, {x = queued.x, y = queued.y}, area)
  state.resources[queued.key] = current_resources
  for name, resource in pairs(current_resources or {}) do
    local total = state.resource_totals[name]
    if not total then total = {name = name, amount = 0, entities = 0}; state.resource_totals[name] = total end
    total.amount = total.amount + (resource.amount or 0)
    total.entities = total.entities + (resource.entities or 0)
  end
  if not state.scanned_chunks[queued.key] then
    state.scanned_chunk_count = state.scanned_chunk_count + 1
  end
  state.scanned_chunks[queued.key] = game.tick
  state.last_scan_tick = game.tick
  if state.queued[queued.key] then
    state.queued[queued.key] = nil
    state.queued_count = math.max(0, state.queued_count - 1)
  end
  if state.development_refresh and state.development_refresh.remaining
      and state.development_refresh.remaining[queued.key] then
    state.development_refresh.remaining[queued.key] = nil
    state.development_refresh.remaining_count = math.max(0,
      (state.development_refresh.remaining_count or 1) - 1)
  end
  root.metrics.world_model_chunks = (root.metrics.world_model_chunks or 0) + 1
  root.metrics.world_model_entities = 0
end

local function pop_queue(state, priority)
  local rows = priority and state.priority_queue or state.queue
  local head_name = priority and "priority_head" or "queue_head"
  local head = state[head_name] or 1
  while head <= #rows do
    local queued = rows[head]
    head = head + 1
    state[head_name] = head
    if priority and queued then state.priority_queued[queued.key] = nil end
    if queued and state.queued[queued.key] then return queued end
  end
  if head > #rows then
    if priority then state.priority_queue = {} else state.queue = {} end
    state[head_name] = 1
  end
  return nil
end

function WorldModel.on_nth_tick()
  local root = State.ensure()
  -- Never batch several entity-heavy chunks into one update. Six chunks were
  -- individually cheap but crossed Factorio's Lua allocation/GC cliff on a
  -- 34k-entity test factory and produced a reproducible 11-14 second stall.
  -- control.lua invokes this slice every 6 ticks, so throughput remains about
  -- ten chunks per second while the worst update stays bounded.
  local remaining = 1
  for _, state in pairs(root.world_model and root.world_model.surfaces or {}) do
    while remaining > 0 and (state.queued_count or 0) > 0 do
      local queued = pop_queue(state, true) or pop_queue(state, false)
      if not queued then break end
      scan_chunk(root, queued)
      remaining = remaining - 1
    end
    if remaining <= 0 then break end
  end

  -- Moving through the world naturally extends the model around the player.
  -- Radar/chart events independently add remote chunks, so no screenshots or
  -- artificial character "inspection walks" are required.
  for _, player in pairs(game.connected_players) do
    local state = surface_state(root, player.surface.index)
    local center = state.bootstrap_center
    if not center then
      WorldModel.seed_player(player)
    else
      local dx, dy = player.position.x - center.x, player.position.y - center.y
      if dx * dx + dy * dy > 160 * 160 then WorldModel.seed_player(player) end
    end
  end
end

function WorldModel.on_chunk_charted(event)
  if not event or not event.force then return end
  local surface = game.surfaces[event.surface_index]
  if not surface then return end
  local root = State.ensure()
  local state = surface_state(root, surface.index)
  local key = chunk_key(event.position.x, event.position.y)
  local last = state.scanned_chunks[key] or 0
  -- Radar can re-chart the same chunk repeatedly.  Refreshing every such event
  -- would turn the map into a background scanner, so cap it to once per 30 s.
  if game.tick - last >= 1800 then queue_chunk(root, surface, event.force, event.position, true) end
end

local function resolve_record(record)
  if not record or not record.unit_number then return nil end
  local entity = game.get_entity_by_unit_number(record.unit_number)
  if entity and entity.valid then return entity end
  local surface = record.surface_index and game.surfaces[record.surface_index] or nil
  if not surface or not record.position or not record.name then return nil end
  local force = record.force_index and game.forces[record.force_index] or nil
  local candidates = surface.find_entities_filtered({
    position = record.position,
    radius = 0.22,
    name = record.name,
    force = force,
    limit = 8
  })
  for _, candidate in ipairs(candidates) do
    if candidate.valid and candidate.type == record.entity_type then return candidate end
  end
  return nil
end

function WorldModel.machine_snapshot(player, limit)
  local root = State.ensure()
  local state = surface_state(root, player.surface.index)
  if next(state.entities) == nil then
    -- First-load safety: seed the immediate factory without waiting for the full
    -- background queue. This runs only when the model is empty, never per chat.
    local local_entities = player.surface.find_entities_filtered({
      position = player.position,
      radius = math.min(128, setting("alina-world-model-radius", 384)),
      force = player.force,
      limit = 512
    })
    for _, entity in ipairs(local_entities) do observe_entity_internal(root, entity) end
  end

  local max_rows = limit or 768
  local cache = state.snapshot_selection
  if not cache or cache.version ~= (state.selection_version or 0)
      or cache.max_rows ~= max_rows or game.tick >= (cache.valid_until or 0) then
    local selected, seen = {}, {}
    local function sorted_units(units)
      local result = {}
      for unit in pairs(units or {}) do result[#result + 1] = unit end
      table.sort(result)
      return result
    end
    local window = math.floor(game.tick / 900)
    local function append_rotating(units, quota)
      local ordered = sorted_units(units)
      if #ordered == 0 then return end
      local take = math.min(quota, #ordered, max_rows - #selected)
      local start = window % #ordered + 1
      local added = 0
      for offset = 0, #ordered - 1 do
        local unit = ordered[(start + offset - 1) % #ordered + 1]
        if not seen[unit] then
          seen[unit] = true
          selected[#selected + 1] = unit
          added = added + 1
          if added >= take or #selected >= max_rows then break end
        end
      end
    end

    -- Mining and research never disappear behind thousands of assemblers.
    append_rotating(state.type_units["mining-drill"], math.min(192, math.floor(max_rows / 4)))
    append_rotating(state.type_units.lab, math.min(48, math.floor(max_rows / 12)))

    local recipe_names = {}
    local recipe_lists = {}
    for name, units in pairs(state.recipe_units or {}) do
      recipe_names[#recipe_names + 1] = name
      recipe_lists[name] = sorted_units(units)
    end
    table.sort(recipe_names)
    local depth = 0
    local added = true
    while #selected < max_rows and added do
      added = false
      for _, name in ipairs(recipe_names) do
        local units = recipe_lists[name]
        if #units > depth then
          local start = window % #units + 1
          local unit = units[(start + depth - 1) % #units + 1]
          if not seen[unit] then
            seen[unit] = true
            selected[#selected + 1] = unit
            added = true
            if #selected >= max_rows then break end
          end
        end
      end
      depth = depth + 1
    end

    -- Fill spare capacity with any remaining actionable machines. This keeps
    -- health ratios representative when a factory has only a few recipes.
    for _, entity_type in ipairs({"mining-drill", "assembling-machine", "furnace", "lab", "rocket-silo"}) do
      if #selected >= max_rows then break end
      append_rotating(state.type_units[entity_type], max_rows - #selected)
    end
    cache = {
      version = state.selection_version or 0,
      max_rows = max_rows,
      valid_until = game.tick + 900,
      units = selected
    }
    state.snapshot_selection = cache
  end

  local entities, stale = {}, {}
  for _, unit in ipairs(cache.units or {}) do
    local entity = resolve_record(state.entities[unit])
    if entity and entity.surface.index == player.surface.index
        and entity.force.index == player.force.index then
      entities[#entities + 1] = entity
    else
      stale[#stale + 1] = unit
    end
  end
  for _, unit in ipairs(stale) do forget_unit_from_surface(state, unit) end
  if #entities == 0 then
    -- Saved games can contain an entity table created by an older schema while
    -- its secondary type index is absent or stale. A bounded nearby repair is
    -- preferable to treating a visible starter factory as empty. This path is
    -- reached only when the indexed query returned nothing; normal autonomy
    -- never performs a full surface scan.
    local nearby = player.surface.find_entities_filtered({
      position = player.position,
      radius = math.min(128, setting("alina-world-model-radius", 384)),
      force = player.force,
      type = {"assembling-machine", "furnace", "mining-drill", "lab", "rocket-silo"},
      limit = math.min(limit or 768, 512)
    })
    for _, entity in ipairs(nearby) do
      if entity.valid and MACHINE_TYPES[entity.type] then
        observe_entity_internal(root, entity)
        entities[#entities + 1] = entity
      end
    end
  end
  local recipes, power = {}, nil
  for _, entity in ipairs(entities) do
    local record = state.entities[entity.unit_number]
    if record then
      local live_recipe = recipe_name(entity)
      if record.recipe ~= live_recipe then
        if record.recipe and state.recipe_units[record.recipe] then
          state.recipe_units[record.recipe][entity.unit_number] = nil
          if next(state.recipe_units[record.recipe]) == nil then state.recipe_units[record.recipe] = nil end
        end
        if live_recipe then
          state.recipe_units[live_recipe] = state.recipe_units[live_recipe] or {}
          state.recipe_units[live_recipe][entity.unit_number] = true
        end
        state.selection_version = (state.selection_version or 0) + 1
        state.snapshot_selection = nil
      end
      record.position = {x = entity.position.x, y = entity.position.y}
      record.direction = entity.direction
      record.recipe = live_recipe
      record.last_seen_tick = game.tick
    end
    if not power and POWER_ISSUE[entity.status] then power = entity end
    if CRAFTING_TYPES[entity.type] then
      local recipe = entity.get_recipe()
      if recipe then
        local group = recipes[recipe.name]
        if not group then
          local products = {}
          for _, product in ipairs(recipe.products or {}) do
            if product.type == "item" and prototypes.item[product.name] then products[#products + 1] = product.name end
          end
          group = {recipe = recipe, entities = {}, products = products}
          recipes[recipe.name] = group
        end
        group.entities[#group.entities + 1] = entity
      end
    end
  end
  root.metrics.world_model_entities = #entities
  return {entities = entities, recipes = recipes, power = power, indexed = #entities}
end

function WorldModel.entities_by_type(player, types, limit)
  if not player or not player.valid then return {} end
  local wanted = {}
  if type(types) == "string" then wanted[types] = true else
    for _, name in ipairs(types or {}) do wanted[name] = true end
  end
  local root = State.ensure()
  local state = surface_state(root, player.surface.index)
  local result, stale = {}, {}
  local max_rows = limit or 1024
  for entity_type in pairs(wanted) do
    for unit in pairs(state.type_units[entity_type] or {}) do
      local record = state.entities[unit]
      if record and record.force_index == player.force.index then
        local entity = resolve_record(record)
        if entity and entity.surface.index == player.surface.index then
          result[#result + 1] = entity
          if #result >= max_rows then break end
        else
          stale[#stale + 1] = unit
        end
      end
    end
    if #result >= max_rows then break end
  end
  for _, unit in ipairs(stale) do forget_unit_from_surface(state, unit) end
  return result
end

function WorldModel.entities_by_type_near(actor, types, position, limit)
  if not actor or not actor.valid then return {} end
  local wanted = {}
  if type(types) == "string" then wanted[types] = true else
    for _, name in ipairs(types or {}) do wanted[name] = true end
  end
  local root = State.ensure()
  local state = surface_state(root, actor.surface.index)
  local origin = position or actor.position
  local candidates, stale = {}, {}
  for entity_type in pairs(wanted) do
    for unit in pairs(state.type_units[entity_type] or {}) do
      local record = state.entities[unit]
      if record and record.force_index == actor.force.index then
        local dx = record.position.x - origin.x
        local dy = record.position.y - origin.y
        candidates[#candidates + 1] = {record = record, distance = dx * dx + dy * dy}
      else
        stale[#stale + 1] = unit
      end
    end
  end
  table.sort(candidates, function(a, b)
    if a.distance == b.distance then return a.record.unit_number < b.record.unit_number end
    return a.distance < b.distance
  end)
  local result = {}
  for index = 1, math.min(limit or 128, #candidates) do
    local record = candidates[index].record
    local entity = resolve_record(record)
    if entity and entity.surface.index == actor.surface.index then
      result[#result + 1] = entity
    else
      stale[#stale + 1] = record.unit_number
    end
  end
  for _, unit in ipairs(stale) do forget_unit_from_surface(state, unit) end
  return result
end

function WorldModel.inventory_sources(actor, item_name, position, limit)
  if not actor or not actor.valid or not item_name then return {} end
  local root = State.ensure()
  local state = surface_state(root, actor.surface.index)
  local candidates, stale = {}, {}
  local origin = position or actor.position
  for unit in pairs(state.item_sources[item_name] or {}) do
    local record = state.entities[unit]
    if record and record.force_index == actor.force.index then
      local dx = record.position.x - origin.x
      local dy = record.position.y - origin.y
      candidates[#candidates + 1] = {record = record, distance = dx * dx + dy * dy}
    else
      stale[#stale + 1] = unit
    end
  end
  table.sort(candidates, function(a, b)
    if a.distance == b.distance then return a.record.unit_number < b.record.unit_number end
    return a.distance < b.distance
  end)
  local result = {}
  for index = 1, math.min(limit or 512, #candidates) do
    local record = candidates[index].record
    local entity = resolve_record(record)
    if entity and entity.surface.index == actor.surface.index then
      result[#result + 1] = entity
    else
      stale[#stale + 1] = record.unit_number
    end
  end
  for _, unit in ipairs(stale) do forget_unit_from_surface(state, unit) end
  return result
end

-- Return lightweight, already indexed resource chunks in nearest-first order.
-- Exact resource entities are resolved only by the caller for the few closest
-- chunks. This avoids tens of large expanding surface queries in one autonomy
-- planning tick on a megabase while preserving exact, live placement checks.
function WorldModel.resource_chunk_candidates(actor, resource_names, position, max_radius, limit)
  if not actor or not actor.valid then return {} end
  local wanted = {}
  if type(resource_names) == "string" then wanted[resource_names] = true else
    for _, name in ipairs(resource_names or {}) do wanted[name] = true end
  end
  if next(wanted) == nil then return {} end

  local root = State.ensure()
  local state = surface_state(root, actor.surface.index)
  local origin = position or actor.position
  local radius = max_radius or 96
  local radius_squared = radius * radius
  local rows = {}
  for key, resources in pairs(state.resources or {}) do
    local chunk_x, chunk_y = string.match(key, "^(-?%d+):(-?%d+)$")
    chunk_x, chunk_y = tonumber(chunk_x), tonumber(chunk_y)
    if chunk_x and chunk_y then
      local area = {{chunk_x * 32, chunk_y * 32}, {(chunk_x + 1) * 32, (chunk_y + 1) * 32}}
      local nearest_x = math.max(area[1][1], math.min(origin.x, area[2][1]))
      local nearest_y = math.max(area[1][2], math.min(origin.y, area[2][2]))
      local dx, dy = nearest_x - origin.x, nearest_y - origin.y
      local minimum_distance = dx * dx + dy * dy
      if minimum_distance <= radius_squared then
        for name, summary in pairs(resources or {}) do
          if wanted[name] and (summary.entities or 0) > 0 and (summary.amount or 0) > 0 then
            local sample = summary.position or {x = chunk_x * 32 + 16, y = chunk_y * 32 + 16}
            rows[#rows + 1] = {
              key = key,
              name = name,
              area = area,
              position = {x = sample.x, y = sample.y},
              minimum_distance = minimum_distance
            }
          end
        end
      end
    end
  end
  table.sort(rows, function(a, b)
    if a.minimum_distance ~= b.minimum_distance then return a.minimum_distance < b.minimum_distance end
    if a.key ~= b.key then return a.key < b.key end
    return a.name < b.name
  end)
  while #rows > (limit or 64) do table.remove(rows) end
  return rows
end

function WorldModel.known_resources(player, max_rows)
  local root = State.ensure()
  local state = surface_state(root, player.surface.index)
  local result = {}
  for _, row in pairs(state.resource_totals or {}) do
    result[#result + 1] = {name = row.name, amount = row.amount, entities = row.entities}
  end
  table.sort(result, function(a, b)
    if a.amount == b.amount then return a.name < b.name end
    return a.amount > b.amount
  end)
  while #result > (max_rows or 24) do table.remove(result) end
  return result
end

function WorldModel.summary(player)
  if not player or not player.valid then return {entities = 0, scanned_chunks = 0, queued_chunks = 0} end
  local root = State.ensure()
  local state = surface_state(root, player.surface.index)
  return {
    entities = state.entity_count or 0,
    scanned_chunks = state.scanned_chunk_count or 0,
    queued_chunks = state.queued_count or 0,
    factory_refresh_pending = WorldModel.factory_refresh_pending(player)
  }
end

return WorldModel
