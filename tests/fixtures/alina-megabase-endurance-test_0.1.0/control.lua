-- Replace one compact evidence file every ten seconds. This is test-only and
-- lets short diagnostic runs capture the state immediately after a planner
-- transition without adding chat or JSONL spam to the actual mod.
local OUTPUT_INTERVAL = 600
local COMMAND_TICK = 120
local TEST_SPEED = 1

local function remove_obstacles(surface, area)
  for _, entity_type in ipairs({"tree", "cliff", "simple-entity"}) do
    for _, entity in ipairs(surface.find_entities_filtered({area = area, type = entity_type})) do
      if entity.valid then entity.destroy({raise_destroy = false}) end
    end
  end
end

local function pave_factory_area(surface, area)
  local left, top = math.floor(area[1][1]), math.floor(area[1][2])
  local right, bottom = math.ceil(area[2][1]), math.ceil(area[2][2])
  for start_x = left, right, 16 do
    local tiles = {}
    for x = start_x, math.min(right, start_x + 15) do
      for y = top, bottom do tiles[#tiles + 1] = {name = "grass-1", position = {x, y}} end
    end
    surface.set_tiles(tiles, true, false, true, false)
  end
end

local function create(surface, parameters)
  parameters.force = parameters.force or game.forces.player
  parameters.create_build_effect_smoke = false
  return surface.create_entity(parameters)
end

local function safe_value(callback, fallback)
  local ok, value = pcall(callback)
  return ok and value ~= nil and value or fallback
end

local function placement_item(prototype)
  local best = nil
  for _, placement in ipairs(prototype.items_to_place_this or {}) do
    local item = prototypes.item[placement.name]
    local hidden = item and safe_value(function() return item.hidden end, false)
    if item and not hidden and (not best or placement.name < best) then best = placement.name end
  end
  return best
end

local function strongest_entity(entity_type, predicate, score)
  local best, best_score, best_item = nil, nil, nil
  for name, prototype in pairs(prototypes.entity) do
    if prototype.type == entity_type and (not predicate or predicate(prototype)) then
      local item = placement_item(prototype)
      if item then
        local value = score(prototype)
        if not best_score or value > best_score or (value == best_score and name < best.name) then
          best, best_score, best_item = prototype, value, item
        end
      end
    end
  end
  if not best then error("no usable prototype for " .. entity_type) end
  return {name = best.name, item = best_item, prototype = best, score = best_score}
end

local function preferred_or_strongest(preferred_name, entity_type, predicate, score)
  local preferred = preferred_name and prototypes.entity[preferred_name] or nil
  if preferred and preferred.type == entity_type and (not predicate or predicate(preferred)) then
    local item = placement_item(preferred)
    if item then
      return {name = preferred.name, item = item, prototype = preferred, score = score(preferred)}
    end
  end
  return strongest_entity(entity_type, predicate, score)
end

local function recipe_supported(machine, recipe)
  for key, value in pairs(recipe.categories or {}) do
    local category = type(key) == "number" and value or key
    if machine.crafting_categories and machine.crafting_categories[category] then return true end
  end
  return false
end

local function choose_tiers(force)
  force.research_all_technologies()
  local recipes = {}
  for _, name in ipairs({
    "iron-gear-wheel", "copper-cable", "electronic-circuit", "advanced-circuit",
    "engine-unit", "transport-belt", "inserter", "automation-science-pack",
    "logistic-science-pack", "military-science-pack"
  }) do
    local recipe = prototypes.recipe[name]
    local runtime = force.recipes[name]
    local item_only = recipe and #recipe.ingredients > 0
    for _, ingredient in ipairs(recipe and recipe.ingredients or {}) do
      if ingredient.type ~= "item" then item_only = false end
    end
    if recipe and runtime and runtime.enabled and item_only then recipes[#recipes + 1] = recipe end
  end
  if #recipes == 0 then error("no item-only production recipes for endurance fixture") end

  local machine = preferred_or_strongest("kr-advanced-assembling-machine", "assembling-machine",
    function(prototype)
      for _, recipe in ipairs(recipes) do if recipe_supported(prototype, recipe) then return true end end
      return false
    end,
    function(prototype) return safe_value(function() return prototype.get_crafting_speed("normal") end, 0) end)
  local compatible = {}
  for _, recipe in ipairs(recipes) do
    if recipe_supported(machine.prototype, recipe) then compatible[#compatible + 1] = recipe end
  end
  local belt = preferred_or_strongest("kr-superior-transport-belt", "transport-belt", nil,
    function(prototype) return safe_value(function() return prototype.belt_speed end, 0) end)
  local inserter = preferred_or_strongest("kr-superior-inserter", "inserter", nil,
    function(prototype)
      return safe_value(function() return prototype.get_inserter_rotation_speed("normal") end, 0) * 100
        + safe_value(function() return prototype.inserter_extension_speed end, 0)
    end)
  local pole = preferred_or_strongest("kr-superior-substation", "electric-pole", nil,
    function(prototype)
      return safe_value(function() return prototype.get_supply_area_distance() end, 0) * 100
        + safe_value(function() return prototype.get_max_wire_distance() end, 0)
    end)
  local drill = preferred_or_strongest("kr-electric-mining-drill-mk2", "mining-drill", nil,
    function(prototype) return safe_value(function() return prototype.mining_speed end, 0) * 100
      + safe_value(function() return prototype.get_mining_drill_radius() end, 0) end)
  local smelting = nil
  if prototypes.recipe["iron-plate"] then
    -- Some K2SO revisions move the plate recipe out of the `furnace` entity
    -- type entirely. The endurance fixture must describe the installed pack,
    -- not fail because a vanilla-shaped furnace is absent.
    local ok, selected = pcall(function()
      return preferred_or_strongest("kr-advanced-furnace", "furnace",
        function(prototype) return recipe_supported(prototype, prototypes.recipe["iron-plate"]) end,
        function(prototype) return safe_value(function() return prototype.get_crafting_speed("normal") end, 0) end)
    end)
    if ok then smelting = selected end
  end
  return {machine = machine, belt = belt, inserter = inserter, pole = pole,
    drill = drill, smelting = smelting, recipes = compatible}
end

local function add_count(counts, name, amount)
  counts[name] = (counts[name] or 0) + (amount or 1)
end

local function fill_recipe_input(chest, recipe)
  if not chest then return end
  local inventory = chest.get_inventory(defines.inventory.chest)
  if not inventory then return end
  for _, ingredient in ipairs(recipe.ingredients or {}) do
    if ingredient.type == "item" then
      local target = math.max(400, math.floor(6000 / #recipe.ingredients))
      local missing = target - inventory.get_item_count(ingredient.name)
      if missing > 0 then inventory.insert({name = ingredient.name, count = missing}) end
    end
  end
end

local function place_production_cell(surface, x, y, cell_width, tiers, recipe, buffers, counts, machine_positions)
  local machine_width = tiers.machine.prototype.tile_width or 3
  local spacing = machine_width + 1
  local machine_start_x = x + 8.5
  local input_y, machine_y, output_y = y + 4.5, y + 8.5, y + 12.5
  local belt_end_x = x + cell_width - 5.5
  -- Inserter direction points at its pickup side in Factorio: west therefore
  -- moves chest -> belt here and north moves belt/machine -> machine/belt.
  local input = create(surface, {name = "steel-chest", position = {x + 3.5, input_y}})
  local feeder = create(surface, {name = tiers.inserter.name,
    position = {x + 4.5, input_y}, direction = defines.direction.west})
  local output_feeder = create(surface, {name = tiers.inserter.name,
    position = {belt_end_x + 1, output_y}, direction = defines.direction.west})
  local output = create(surface, {name = "steel-chest", position = {belt_end_x + 2, output_y}})
  for _, entity in ipairs({input, feeder, output_feeder, output}) do
    if entity then add_count(counts, entity.type) end
  end
  fill_recipe_input(input, recipe)
  buffers[#buffers + 1] = {
    input = {x = x + 3.5, y = input_y},
    output = {x = belt_end_x + 2, y = output_y},
    recipe = recipe.name
  }

  for belt_x = x + 5.5, belt_end_x do
    if create(surface, {name = tiers.belt.name, position = {belt_x, input_y},
        direction = defines.direction.east}) then add_count(counts, "transport-belt") end
    if create(surface, {name = tiers.belt.name, position = {belt_x, output_y},
        direction = defines.direction.east}) then add_count(counts, "transport-belt") end
  end
  for index = 0, 5 do
    local machine_x = machine_start_x + index * spacing
    local machine = create(surface, {name = tiers.machine.name, position = {machine_x, machine_y}})
    if machine then
      machine.set_recipe(recipe.name)
      add_count(counts, machine.type)
      machine_positions[#machine_positions + 1] = {x = machine.position.x, y = machine.position.y}
    end
    if create(surface, {name = tiers.inserter.name, position = {machine_x, y + 5.5},
        direction = defines.direction.north}) then add_count(counts, "inserter") end
    if create(surface, {name = tiers.inserter.name, position = {machine_x, y + 11.5},
        direction = defines.direction.north}) then add_count(counts, "inserter") end
  end
end

local function place_power_grid(surface, tiers, cell_width, columns, rows, x_origin, y_origin, counts)
  local machine_width = tiers.machine.prototype.tile_width or 3
  local spacing = machine_width + 1
  local first_offset = 8.5 + spacing / 2
  local second_offset = 8.5 + 4 * spacing + spacing / 2
  for column = 0, columns - 1 do
    local x = x_origin + column * cell_width
    for row = 0, rows - 1 do
      local y = y_origin + row * 16 + 0.5
      for _, pole_x in ipairs({x + first_offset, x + second_offset}) do
        if create(surface, {name = tiers.pole.name, position = {pole_x, y}}) then
          add_count(counts, "electric-pole")
        end
      end
    end
  end
  local source = create(surface, {name = "electric-energy-interface", position = {0.5, 0.5}})
  if source then
    source.power_production = 1000000000000
    source.electric_buffer_size = 1000000000000
    add_count(counts, "electric-energy-interface")
  end
end

local function place_resource_patch(surface, name, center, half_size)
  if not prototypes.entity[name] or prototypes.entity[name].type ~= "resource" then return 0 end
  for _, entity in ipairs(surface.find_entities_filtered({position = center, radius = half_size + 3,
      type = "resource"})) do entity.destroy() end
  local count = 0
  for dx = -half_size, half_size do
    for dy = -half_size, half_size do
      local resource = surface.create_entity({name = name,
        position = {center.x + dx, center.y + dy}, amount = 250000})
      if resource then count = count + 1 end
    end
  end
  return count
end

local function place_supply(surface, tiers)
  local supply = create(surface, {name = "steel-chest", position = {0.5, 5.5}})
  if not supply then return 0 end
  local items = {
    [tiers.machine.item] = 128,
    [tiers.belt.item] = 2000,
    [tiers.inserter.item] = 512,
    [tiers.pole.item] = 256,
    [tiers.drill.item] = 128,
    ["steel-chest"] = 128
  }
  if tiers.smelting then items[tiers.smelting.item] = 256 end
  for name, count in pairs(items) do supply.insert({name = name, count = count}) end
  return 1
end

local function create_active_megabase()
  game.speed = TEST_SPEED
  local surface = game.surfaces[1]
  surface.request_to_generate_chunks({0, 0}, 22)
  surface.force_generate_chunk_requests()
  game.forces.player.chart(surface, {{-704, -704}, {704, 704}})
  pave_factory_area(surface, {{-620, -350}, {620, 350}})
  remove_obstacles(surface, {{-620, -350}, {620, 350}})
  for _, resource in ipairs(surface.find_entities_filtered({area = {{-440, -300}, {440, 300}}, type = "resource"})) do
    resource.destroy()
  end

  local tiers = choose_tiers(game.forces.player)
  local machine_width = tiers.machine.prototype.tile_width or 3
  local cell_width = math.max(40, 6 * (machine_width + 1) + 12)
  local columns, rows = 17, 33
  local x_origin, y_origin = -math.floor(columns / 2) * cell_width, -math.floor(rows / 2) * 16
  local counts, buffers, machine_positions = {}, {}, {}
  place_power_grid(surface, tiers, cell_width, columns, rows, x_origin, y_origin, counts)
  local production_cells = 0
  local recipe_counts = {}
  for column = 0, columns - 1 do
    for row = 0, rows - 1 do
      local plaza = column >= 7 and column <= 9 and row >= 11 and row <= 21
      if not plaza then
        local recipe = tiers.recipes[(column * rows + row) % #tiers.recipes + 1]
        place_production_cell(surface, x_origin + column * cell_width,
          y_origin + row * 16, cell_width, tiers, recipe, buffers, counts, machine_positions)
        production_cells = production_cells + 1
        recipe_counts[recipe.name] = (recipe_counts[recipe.name] or 0) + 1
      end
    end
  end

  local resource_patches = {
    ["iron-ore"] = place_resource_patch(surface, "iron-ore", {x = -500, y = -180}, 7),
    ["copper-ore"] = place_resource_patch(surface, "copper-ore", {x = -500, y = 0}, 7),
    ["coal"] = place_resource_patch(surface, "coal", {x = -500, y = 180}, 7),
    ["stone"] = place_resource_patch(surface, "stone", {x = 500, y = -180}, 7),
    ["kr-rare-metal-ore"] = place_resource_patch(surface, "kr-rare-metal-ore", {x = 500, y = 40}, 7)
  }
  local support_entities = place_supply(surface, tiers)
  local player = game.get_player(1)
  if player then player.teleport({24, 8}, surface) end

  local production_entities = (counts["assembling-machine"] or 0) + (counts.furnace or 0)
    + (counts.inserter or 0) + (counts.container or 0)
  local belt_entities = counts["transport-belt"] or 0
  local power_entities = (counts["electric-pole"] or 0) + (counts["electric-energy-interface"] or 0)
  local entity_count = surface.count_entities_filtered({force = game.forces.player})

  storage.alina_megabase_endurance = {
    requested = false,
    request_result = nil,
    production_cells = production_cells,
    production_entities = production_entities,
    belt_entities = belt_entities,
    power_entities = power_entities,
    support_entities = support_entities,
    entity_count = entity_count,
    buffers = buffers,
    buffer_cursor = 1,
    machine_positions = machine_positions,
    recipe_counts = recipe_counts,
    resource_patches = resource_patches,
    selected_tiers = {
      machine = tiers.machine.name,
      belt = tiers.belt.name,
      inserter = tiers.inserter.name,
      pole = tiers.pole.name,
      drill = tiers.drill.name,
      smelting = tiers.smelting and tiers.smelting.name or nil
    },
    max_working_machines = 0,
    current_working_machines = 0,
    language_checks = {},
    gui_checks = {},
    task_results = {},
    completed_tasks = 0,
    useful_completed_tasks = 0,
    failed_tasks = 0,
    cancelled_tasks = 0,
    max_task_age_ticks = 0,
    max_indexed_entities = 0,
    max_scanned_chunks = 0,
    agent_missing_samples = 0,
    samples = 0
  }
end

local function service_factory(state)
  local surface = game.surfaces[1]
  local count = #state.buffers
  if count == 0 then return end
  for _ = 1, math.min(16, count) do
    local index = state.buffer_cursor
    state.buffer_cursor = index % count + 1
    local row = state.buffers[index]
    local input = surface.find_entity("steel-chest", row.input)
    local recipe = prototypes.recipe[row.recipe]
    if input and recipe then fill_recipe_input(input, recipe) end
    local output = surface.find_entity("steel-chest", row.output)
    local inventory = output and output.get_inventory(defines.inventory.chest) or nil
    if inventory and not inventory.is_empty() then inventory.clear() end
  end
end

local function count_working_machines(state)
  local working = 0
  local surface = game.surfaces[1]
  for _, position in ipairs(state.machine_positions or {}) do
    local entity = surface.find_entity(state.selected_tiers.machine, position)
    if entity and entity.valid and entity.status == defines.entity_status.working then
      working = working + 1
    end
  end
  state.current_working_machines = working
  state.max_working_machines = math.max(state.max_working_machines or 0, working)
end

local function activate_test_player(event)
  local player = event.player_index and game.get_player(event.player_index)
    or game.connected_players[1] or game.get_player(1)
  if player then
    player.teleport({0, 8}, game.surfaces[1])
    game.tick_paused = false
    local state = storage.alina_megabase_endurance
    if state and not state.enemy_cleanup_done then
      -- Combat is deliberately outside this endurance test. Random map-gen
      -- nests otherwise kill the physical agent midway through a navigation
      -- measurement and turn a UPS/building test into a combat test.
      game.forces.player.set_cease_fire(game.forces.enemy, true)
      game.forces.enemy.set_cease_fire(game.forces.player, true)
      state.enemy_cleanup_done = true
    end
    if game.is_multiplayer() and state and not state.player_save_requested then
      state.player_save_requested = true
      game.server_save("alina-endurance-player")
    elseif state then
      state.active_start_tick = game.tick
      state.next_output_tick = game.tick + OUTPUT_INTERVAL
    end
  end
end

script.on_event(defines.events.on_player_joined_game, activate_test_player)
script.on_event(defines.events.on_singleplayer_init, activate_test_player)

local useful_task_types = {
  repair_power = true,
  expand_line = true,
  upgrade_machine = true,
  supply_shortage = true,
  acquire_items = true,
  build_production = true
}

local function observe_status(state, status)
  state.samples = state.samples + 1
  if not status.agent or not status.agent.present then
    state.agent_missing_samples = state.agent_missing_samples + 1
  end

  local current = status.task
  if not current and state.recall_agent_position and status.agent and status.agent.position
      and state.completed_tasks == 0 then
    local dx = status.agent.position.x - state.recall_agent_position.x
    local dy = status.agent.position.y - state.recall_agent_position.y
    state.max_idle_agent_drift = math.max(state.max_idle_agent_drift or 0, math.sqrt(dx * dx + dy * dy))
  end
  if current and current.created_tick then
    state.max_task_age_ticks = math.max(state.max_task_age_ticks, game.tick - current.created_tick)
  end

  local last = status.last_task
  if last and last.id and not state.task_results[last.id] then
    state.task_results[last.id] = {
      id = last.id,
      type = last.type,
      status = last.status,
      result = last.result,
      finished_tick = last.finished_tick
    }
    if last.status == "completed" then
      state.completed_tasks = state.completed_tasks + 1
      if useful_task_types[last.type] then
        state.useful_completed_tasks = state.useful_completed_tasks + 1
      end
    elseif last.status == "failed" then
      state.failed_tasks = state.failed_tasks + 1
    elseif last.status == "cancelled" then
      state.cancelled_tasks = state.cancelled_tasks + 1
    end
  end
  state.last_status = status
end

local function observe_world(state)
  local result = remote.call("alina_ai", "snapshot", 1)
  local known = result and result.ok and result.snapshot and result.snapshot.known_factory
  if known then
    state.max_indexed_entities = math.max(state.max_indexed_entities, known.entities or 0)
    state.max_scanned_chunks = math.max(state.max_scanned_chunks, known.scanned_chunks or 0)
    state.queued_chunks = known.queued_chunks or 0
  end
end

local function compact_tasks(task_results)
  local rows = {}
  for _, row in pairs(task_results) do rows[#rows + 1] = row end
  table.sort(rows, function(a, b) return a.id < b.id end)
  return rows
end

local function write_result(state, enabled)
  count_working_machines(state)
  local status = state.last_status or {}
  local current = status.task
  local current_age = current and current.created_tick and (game.tick - current.created_tick) or 0
  local metrics = status.metrics or {}
  local expansion = current and current.expansion or nil
  local navigation = current and current.navigation or nil
  local acquisition = current and current.acquisition or nil
  local build_row = expansion and expansion.build_row or nil
  local detour = navigation and navigation.belt_detour or nil
  local agent_entity = status.agent and status.agent.unit_number
    and game.get_entity_by_unit_number(status.agent.unit_number) or nil
  local navigation_nearby = {}
  if agent_entity and agent_entity.valid and navigation then
    for _, entity in ipairs(agent_entity.surface.find_entities_filtered({
        position = agent_entity.position, radius = 2.25, limit = 32})) do
      if entity.valid and entity ~= agent_entity then
        navigation_nearby[#navigation_nearby + 1] = {
          name = entity.name,
          type = entity.type,
          position = {x = entity.position.x, y = entity.position.y},
          direction = entity.direction
        }
      end
    end
  end
  local result = {
    enabled = enabled,
    tick = game.tick,
    elapsed_ticks = game.tick - (state.active_start_tick or 0),
    entity_count = state.entity_count,
    production_cells = state.production_cells,
    production_entities = state.production_entities,
    belt_entities = state.belt_entities,
    power_entities = state.power_entities,
    selected_tiers = state.selected_tiers,
    recipe_counts = state.recipe_counts,
    resource_patches = state.resource_patches,
    current_working_machines = state.current_working_machines,
    max_working_machines = state.max_working_machines,
    language_checks = state.language_checks,
    gui_checks = state.gui_checks,
    request_sent = state.requested,
    request_result = state.request_result,
    completed_tasks = state.completed_tasks,
    useful_completed_tasks = state.useful_completed_tasks,
    failed_tasks = state.failed_tasks,
    cancelled_tasks = state.cancelled_tasks,
    tasks = compact_tasks(state.task_results),
    current_task = current and {
      id = current.id,
      type = current.type,
      phase = current.phase,
      physical_stage = expansion and expansion.physical_stage or nil,
      expansion_index = expansion and expansion.index or nil,
      physical_built = expansion and expansion.physical_built or nil,
      entity_count = expansion and expansion.entity_count or nil,
      requirement_index = expansion and expansion.requirement_index or nil,
      requirement_count = expansion and expansion.requirement_count or nil,
      acquisition_item = acquisition and acquisition.item or nil,
      acquisition_index = acquisition and acquisition.index or nil,
      navigation_state = navigation and navigation.state or nil,
      navigation_goal = navigation and navigation.goal or nil,
      navigation_waypoint_index = navigation and navigation.index or nil,
      navigation_waypoint_count = navigation and navigation.waypoint_count or nil,
      navigation_waypoint = navigation and navigation.waypoint or nil,
      navigation_next_waypoint = navigation and navigation.next_waypoint or nil,
      navigation_requested_tick = navigation and navigation.requested_tick or nil,
      navigation_retries = navigation and navigation.retries or nil,
      navigation_last_position = navigation and navigation.last_position or nil,
      navigation_last_movement_tick = navigation and navigation.last_movement_tick or nil,
      navigation_best_distance = navigation and navigation.waypoint_best_distance or nil,
      navigation_progress_tick = navigation and navigation.waypoint_progress_tick or nil,
      navigation_belt_escape_active = navigation and navigation.belt_escape_was_active == true or false,
      navigation_nearby = navigation_nearby,
      build_entity = build_row and build_row.name or nil,
      build_position = build_row and build_row.position or nil,
      belt_detour_phase = detour and detour.phase or nil,
      belt_detour_direction = detour and detour.escape_direction or nil,
      belt_detour_started_tick = detour and detour.started_tick or nil,
      belt_detour_phase_tick = detour and detour.phase_started_tick or nil,
      belt_detour_start = detour and detour.escape_start_position or nil
    } or nil,
    current_task_age_ticks = current_age,
    max_task_age_ticks = state.max_task_age_ticks,
    max_indexed_entities = state.max_indexed_entities,
    max_scanned_chunks = state.max_scanned_chunks,
    queued_chunks = state.queued_chunks or 0,
    agent_present = status.agent and status.agent.present == true or false,
    agent_deaths = status.agent and status.agent.deaths or 0,
    agent_position = status.agent and status.agent.position or nil,
    player_position = game.get_player(1) and game.get_player(1).position or nil,
    recall_agent_position = state.recall_agent_position,
    recall_player_position = state.recall_player_position,
    max_idle_agent_drift = state.max_idle_agent_drift or 0,
    agent_missing_samples = state.agent_missing_samples,
    development_focus = status.development_focus == true,
    samples = state.samples,
    autonomy_actions = metrics.autonomy_actions or 0,
    autonomy_noops = metrics.autonomy_noops or 0,
    executor_active_ticks = metrics.executor_active_ticks or 0,
    rail_safety_scans = metrics.rail_safety_scans or 0,
    last_resource_search = metrics.last_resource_search,
    last_chain_plan = metrics.last_chain_plan
  }
  local name = enabled and "megabase-endurance-alina.json" or "megabase-endurance-baseline.json"
  helpers.write_file("alina/" .. name, helpers.table_to_json(result), false)
end

script.on_init(create_active_megabase)

script.on_nth_tick(60, function()
  local state = storage.alina_megabase_endurance
  if not state then return end
  if not state.enemy_cleanup_done then
    game.forces.player.set_cease_fire(game.forces.enemy, true)
    game.forces.enemy.set_cease_fire(game.forces.player, true)
    state.enemy_cleanup_done = true
  end
  local enabled = remote.interfaces["alina_ai"] ~= nil
  service_factory(state)
  if enabled then
    local player = game.get_player(1)
    if player and not game.is_multiplayer() and not state.active_start_tick then
      state.active_start_tick = game.tick
      state.next_output_tick = game.tick + OUTPUT_INTERVAL
    end
    if player and not state.requested
        and game.tick >= (state.active_start_tick or 0) + COMMAND_TICK then
      remote.call("alina_ai", "recall", player.index)
      local recalled = remote.call("alina_ai", "status")
      state.recall_agent_position = recalled and recalled.agent and recalled.agent.position or nil
      state.recall_player_position = {x = player.position.x, y = player.position.y}
      local iron = remote.call("alina_ai", "address", player.index,
        "Алина, найди жилу железа и сделай ТАМ добычу по максимуму")
      local coal = remote.call("alina_ai", "address", player.index,
        "Аля, окей, найди жилу угля")
      state.language_checks = {
        iron = iron and {ok = iron.ok, result = iron.result} or {ok = false, result = "no_response"},
        coal = coal and {ok = coal.ok, result = coal.result} or {ok = false, result = "no_response"}
      }
      local panel = player.gui.left.alina_panel
      local panel_width = panel and safe_value(function() return panel.style.minimal_width end, 0) or 0
      local panel_max_width = panel and safe_value(function() return panel.style.maximal_width end, 0) or 0
      local panel_height = panel and safe_value(function() return panel.style.minimal_height end, 0) or 0
      local panel_max_height = panel and safe_value(function() return panel.style.maximal_height end, 0) or 0
      local inventory_response = remote.call("alina_ai", "toggle_inventory", player.index)
      local inventory_frame = player.gui.screen.alina_inventory_frame
      local slots = inventory_frame and inventory_frame.alina_inventory_scroll
        and inventory_frame.alina_inventory_scroll.alina_inventory_slots or nil
      state.gui_checks = {
        panel_exists = panel ~= nil,
        panel_width = panel_width,
        panel_max_width = panel_max_width,
        panel_height = panel_height,
        panel_max_height = panel_max_height,
        inventory_opened = inventory_response and inventory_response.opened == true or false,
        inventory_slots = slots and #slots.children or 0
      }
      if inventory_frame then remote.call("alina_ai", "toggle_inventory", player.index) end
      local response = remote.call("alina_ai", "address", player.index,
        "Аля, продолжай развивать базу")
      state.requested = response and response.ok == true
      state.request_result = response and response.result or "no_response"
    end
    if state.requested then
      observe_status(state, remote.call("alina_ai", "status"))
      if game.tick % 600 == 0 then observe_world(state) end
    end
  end
  state.next_output_tick = state.next_output_tick or OUTPUT_INTERVAL
  if game.tick >= state.next_output_tick then
    write_result(state, enabled)
    state.next_output_tick = game.tick + OUTPUT_INTERVAL
  end
end)
