local function create(surface, parameters)
  parameters.force = parameters.force or "player"
  parameters.raise_built = true
  local entity = surface.create_entity(parameters)
  if not entity then error("fluid test could not create " .. tostring(parameters.name)) end
  return entity
end

local function stock(inventory, stacks)
  for _, stack in ipairs(stacks) do
    if inventory.insert(stack) ~= stack.count then error("fluid test supply rejected " .. stack.name) end
  end
end

local function prototype_fluid_geometry(name)
  local prototype = prototypes.entity[name]
  local result = {name = name, width = prototype.tile_width, height = prototype.tile_height, fluidboxes = {}}
  for _, box in ipairs(prototype.fluidbox_prototypes or {}) do
    local row = {index = box.index, production_type = box.production_type, connections = {}}
    for _, connection in ipairs(box.pipe_connections or {}) do
      local positions = {}
      for _, position in ipairs(connection.positions or {}) do
        positions[#positions + 1] = {x = position.x, y = position.y}
      end
      row.connections[#row.connections + 1] = {direction = connection.direction,
        flow_direction = connection.flow_direction, positions = positions}
    end
    result.fluidboxes[#result.fluidboxes + 1] = row
  end
  return result
end

local function recipe_fluids(name)
  local recipe = prototypes.recipe[name]
  local result = {name = name, ingredients = {}, products = {}}
  if not recipe then return result end
  for _, ingredient in ipairs(recipe.ingredients or {}) do
    result.ingredients[#result.ingredients + 1] = {type = ingredient.type, name = ingredient.name,
      amount = ingredient.amount, fluidbox_index = ingredient.fluidbox_index}
  end
  for _, product in ipairs(recipe.products or {}) do
    result.products[#result.products + 1] = {type = product.type, name = product.name,
      amount = product.amount, fluidbox_index = product.fluidbox_index}
  end
  return result
end

local function prepare(state)
  local surface = game.surfaces[1]
  local player = game.players[1]
  if not player then return false end
  game.speed = 8
  local tiles = {}
  for x = -30, 100 do for y = -45, 45 do tiles[#tiles + 1] = {name = "grass-1", position = {x, y}} end end
  surface.set_tiles(tiles, true, false, true, false)
  for _, entity in ipairs(surface.find_entities_filtered({area = {{-30, -45}, {101, 46}}})) do
    if entity.valid and entity.type ~= "character" then entity.destroy() end
  end
  if not player.character then
    local character = create(surface, {name = "character", position = {-8, 0}})
    player.set_controller({type = defines.controllers.character, character = character})
  else
    player.teleport({-8, 0}, surface)
  end
  for _, name in ipairs({"oil-processing", "plastics", "fluid-handling", "automation-2"}) do
    local technology = player.force.technologies[name]
    if technology then technology.researched = true end
  end
  local interface = create(surface, {name = "electric-energy-interface", position = {0, -4}})
  interface.power_production = 100000000
  interface.electric_buffer_size = 100000000
  create(surface, {name = "substation", position = {0, 0}})

  local initial_crude = 0
  for _, position in ipairs({{54, -18}, {66, -18}, {54, 18}, {66, 18}}) do
    local well = surface.create_entity({name = "crude-oil", position = position, amount = 300000})
    if not well then error("fluid test could not create crude-oil resource") end
    initial_crude = initial_crude + (well.amount or 0)
  end
  local water = create(surface, {name = "storage-tank", position = {12, 16}})
  local inserted = water.insert_fluid({name = "water", amount = 20000})
  if inserted < 19000 then error("fluid test could not fill water source") end

  local supply = create(surface, {name = "steel-chest", position = {-2, 7}})
    .get_inventory(defines.inventory.chest)
  stock(supply, {
    {name = "chemical-plant", count = 24}, {name = "pipe", count = 1200},
    {name = "pumpjack", count = 12}, {name = "oil-refinery", count = 24},
    {name = "pipe-to-ground", count = 600},
    {name = "pump", count = 80},
    {name = "storage-tank", count = 48}, {name = "inserter", count = 100},
    {name = "steel-chest", count = 100}
  })
  local reserve_supply = create(surface, {name = "steel-chest", position = {-4, 7}})
    .get_inventory(defines.inventory.chest)
  stock(reserve_supply, {
    {name = "small-electric-pole", count = 300}, {name = "coal", count = 500}
  })
  if not remote.call("alina_ai", "recall", player.index) then error("fluid test could not recall Alina") end
  helpers.write_file("alina/fluid-prototype-geometry.json", helpers.table_to_json({
    machine = prototype_fluid_geometry("chemical-plant"),
    refinery = prototype_fluid_geometry("oil-refinery"),
    tank = prototype_fluid_geometry("storage-tank"),
    basic_oil = recipe_fluids("basic-oil-processing"),
    advanced_oil = recipe_fluids("advanced-oil-processing"),
    test_recipe = recipe_fluids("alina-fluid-test-product")
  }), false)
  state.player_index = player.index
  state.initial_crude = initial_crude
  state.prepared = true
  state.prepared_tick = game.tick
  return true
end

local function result(surface, initial_crude)
  local machines, refineries, source_drills, pipes, pumps, powered_pumps, product = 0, 0, 0, 0, 0, 0, 0
  local petroleum_ok, water_ok = false, false
  local heavy_oil, light_oil = 0, 0
  for _, entity in ipairs(surface.find_entities_filtered({force = "player"})) do
    if entity.type == "assembling-machine" then
      local recipe = entity.get_recipe()
      if recipe and recipe.name == "alina-fluid-test-product" then machines = machines + 1 end
      if recipe and recipe.name ~= "alina-fluid-test-product" then
        for _, fluid in ipairs(recipe.products or {}) do
          if fluid.type == "fluid" and fluid.name == "petroleum-gas" then
            refineries = refineries + 1
            break
          end
        end
      end
    elseif entity.type == "mining-drill" and entity.name == "pumpjack" then
      source_drills = source_drills + 1
    elseif entity.type == "pipe" then
      pipes = pipes + 1
    elseif entity.type == "pump" then
      pumps = pumps + 1
      local ok, network_id = pcall(function() return entity.electric_network_id end)
      if (not entity.prototype.electric_energy_source_prototype)
          or (ok and network_id and (entity.energy or 0) > 0) then
        powered_pumps = powered_pumps + 1
      end
    elseif entity.type == "container" or entity.type == "logistic-container" then
      local inventory = entity.get_inventory(defines.inventory.chest)
      product = product + (inventory and inventory.get_item_count("alina-fluid-test-product") or 0)
    elseif entity.type == "storage-tank" then
      petroleum_ok = petroleum_ok or entity.get_fluid_count("petroleum-gas") > 0
      water_ok = water_ok or entity.get_fluid_count("water") > 0
      heavy_oil = heavy_oil + entity.get_fluid_count("heavy-oil")
      light_oil = light_oil + entity.get_fluid_count("light-oil")
    end
  end
  local remaining_crude = 0
  for _, resource in ipairs(surface.find_entities_filtered({name = "crude-oil", type = "resource"})) do
    remaining_crude = remaining_crude + (resource.amount or 0)
  end
  return machines, refineries, source_drills, pipes, pumps, powered_pumps, product,
    petroleum_ok, water_ok, heavy_oil, light_oil, remaining_crude < (initial_crude or 0)
end

script.on_init(function()
  storage.fluid_test = {prepared = false, requested = false, done = false}
end)

script.on_event(defines.events.on_tick, function(event)
  local state = storage.fluid_test
  if not state or state.done then return end
  if not state.prepared then prepare(state); return end
  local player = game.get_player(state.player_index)
  if not state.requested and event.tick >= state.prepared_tick + 1200 then
    local accepted = remote.call("alina_ai", "address", player.index,
      "Аля, построй производство [item=alina-fluid-test-product]")
    if not accepted.ok then error("fluid command rejected: " .. tostring(accepted.result)) end
    state.requested = true
    state.requested_tick = event.tick
  end
  if state.requested and event.tick % 60 == 0 then
    local status = remote.call("alina_ai", "status")
    local machines, refineries, source_drills, pipes, pumps, powered_pumps, product,
      petroleum_ok, water_ok, heavy_oil, light_oil, crude_extracted = result(player.surface, state.initial_crude)
    if machines >= 4 and refineries >= 4 and source_drills >= 1
        and pipes > 0 and pumps > 0 and powered_pumps == pumps
        and product > 0 and petroleum_ok and water_ok
        and heavy_oil > 0 and light_oil > 0 and crude_extracted and not status.task then
      helpers.write_file("alina/fluid-production-result.json", helpers.table_to_json({
        ok = true, machines = machines, pipes = pipes, pumps = pumps,
        powered_pumps = powered_pumps, pipeline_extent = 100, product = product,
        refineries = refineries, source_drills = source_drills, crude_extracted = crude_extracted,
        petroleum_upstream_working = petroleum_ok, water_source_preserved = water_ok,
        heavy_oil = heavy_oil, light_oil = light_oil, tick = event.tick,
        connected_players = #game.connected_players
      }), false)
      state.done = true
    elseif refineries >= 4 and machines == 0 and not status.task
        and status.last_task and status.last_task.type == "resolve_shortage"
        and status.last_task.status == "completed"
        and (status.last_task.finished_tick or 0) >= state.requested_tick then
      -- The recursive upstream task deliberately completes before the
      -- downstream planner runs. If that planner leaves no active expansion,
      -- fail immediately with useful evidence instead of letting unrelated
      -- loadout maintenance keep the external watchdog alive for minutes.
      helpers.write_file("alina/fluid-production-result.json", helpers.table_to_json({
        ok = false, reason = "downstream_fluid_plan_not_started",
        machines = machines, pipes = pipes, pumps = pumps, powered_pumps = powered_pumps,
        product = product, refineries = refineries, source_drills = source_drills,
        crude_extracted = crude_extracted, petroleum_upstream_working = petroleum_ok,
        water_source_preserved = water_ok, heavy_oil = heavy_oil, light_oil = light_oil,
        tick = event.tick, last_activity = status.last_activity
      }), false)
      state.done = true
    elseif status.last_task and status.last_task.type == "expand_line"
        and status.last_task.status == "failed"
        and (status.last_task.finished_tick or 0) >= state.requested_tick then
      helpers.write_file("alina/fluid-production-result.json", helpers.table_to_json({
        ok = false, reason = "fluid_expansion_failed", result = status.last_task.result,
        machines = machines, pipes = pipes, pumps = pumps, powered_pumps = powered_pumps,
        product = product, refineries = refineries, source_drills = source_drills,
        crude_extracted = crude_extracted, petroleum_upstream_working = petroleum_ok,
        water_source_preserved = water_ok, heavy_oil = heavy_oil, light_oil = light_oil,
        tick = event.tick, connected_players = #game.connected_players
      }), false)
      state.done = true
    elseif event.tick >= state.requested_tick + 120000 then
      helpers.write_file("alina/fluid-production-result.json", helpers.table_to_json({
        ok = false, reason = "fluid_production_timeout", machines = machines, pipes = pipes,
        refineries = refineries, source_drills = source_drills, pumps = pumps,
        powered_pumps = powered_pumps, product = product, petroleum_upstream_working = petroleum_ok,
        water_source_preserved = water_ok, crude_extracted = crude_extracted,
        heavy_oil = heavy_oil, light_oil = light_oil,
        task_type = status.task and status.task.type or nil,
        task_phase = status.task and status.task.phase or nil,
        last_activity = status.last_activity, tick = event.tick,
        connected_players = #game.connected_players
      }), false)
      state.done = true
    end
  end
end)
