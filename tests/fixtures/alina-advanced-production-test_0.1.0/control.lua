local function create(surface, parameters)
  parameters.force = parameters.force or "player"
  parameters.raise_built = true
  local entity = surface.create_entity(parameters)
  if not entity then error("advanced test could not create " .. tostring(parameters.name)) end
  return entity
end

local function stock(inventory, stacks)
  for _, stack in ipairs(stacks) do
    if inventory.insert(stack) ~= stack.count then error("advanced supply rejected " .. stack.name) end
  end
end

local function powered_roboport(surface, x, y)
  local interface = create(surface, {name = "electric-energy-interface", position = {x, y - 5}})
  interface.power_production = 100000000
  interface.electric_buffer_size = 100000000
  create(surface, {name = "substation", position = {x, y - 2}})
  local roboport = create(surface, {name = "roboport", position = {x, y}})
  local inventory = roboport.get_inventory(defines.inventory.roboport_robot)
  if not inventory or inventory.insert({name = "logistic-robot", count = 25}) ~= 25 then
    error("advanced test could not stock robots")
  end
  if inventory.insert({name = "construction-robot", count = 25}) ~= 25 then
    error("advanced test could not stock construction robots")
  end
end

local function prepare(state)
  local surface = game.surfaces[1]
  local player = game.players[1]
  if not player then return false end
  game.speed = 8
  local tiles = {}
  for x = -20, 100 do for y = -35, 40 do tiles[#tiles + 1] = {name = "grass-1", position = {x, y}} end end
  surface.set_tiles(tiles, true, false, true, false)
  for _, entity in ipairs(surface.find_entities_filtered({area = {{-20, -35}, {101, 41}}})) do
    if entity.valid and entity.type ~= "character" then entity.destroy() end
  end
  if not player.character then
    local character = create(surface, {name = "character", position = {-8, 0}})
    player.set_controller({type = defines.controllers.character, character = character})
  else
    player.teleport({-8, 0}, surface)
  end
  for _, name in ipairs({"logistic-system", "automation-3", "speed-module",
      "electric-energy-distribution-2", "construction-robotics"}) do
    local technology = player.force.technologies[name]
    if technology then technology.researched = true end
  end
  for _, x in ipairs({20, 50, 80}) do
    powered_roboport(surface, x, -20)
    powered_roboport(surface, x, 20)
  end
  local interface = create(surface, {name = "electric-energy-interface", position = {50, -4}})
  interface.power_production = 100000000
  interface.electric_buffer_size = 100000000
  create(surface, {name = "substation", position = {50, 0}})
  local supply = create(surface, {name = "steel-chest", position = {0, -5}})
    .get_inventory(defines.inventory.chest)
  stock(supply, {
    {name = "assembling-machine-3", count = 30}, {name = "inserter", count = 50},
    {name = "stack-inserter", count = 50}, {name = "requester-chest", count = 50},
    {name = "passive-provider-chest", count = 50}, {name = "steel-chest", count = 30},
    {name = "small-electric-pole", count = 50}, {name = "speed-module", count = 50},
    {name = "iron-plate", count = 3000}, {name = "iron-gear-wheel", count = 300}
  })
  create(surface, {name = "storage-chest", position = {45, -8}})
    .get_inventory(defines.inventory.chest).insert({name = "iron-plate", count = 2000})
  -- A deliberately faster-than-character reverse belt floor exercises the
  -- deterministic escape policy. The planned first workshop also overlaps two
  -- trees, which must be removed by construction robots before any item is spent.
  for x = 5, 40 do
    for y = -1, 1 do
      create(surface, {name = "alina-test-fast-belt", position = {x + 0.5, y + 0.5},
        direction = defines.direction.west})
    end
  end
  create(surface, {name = "tree-01", position = {52, 5}})
  create(surface, {name = "tree-01", position = {57, 5}})
  if not remote.call("alina_ai", "recall", player.index) then error("advanced test could not recall Alina") end
  state.player_index = player.index
  state.prepared = true
  state.prepared_tick = game.tick
  return true
end

local function result(surface)
  local machines, modules, requesters, providers, output = 0, 0, 0, 0, 0
  for _, entity in ipairs(surface.find_entities_filtered({force = "player"})) do
    if entity.name == "assembling-machine-3" then
      local recipe = entity.get_recipe()
      if recipe and recipe.name == "iron-gear-wheel" then
        machines = machines + 1
        local inventory = entity.get_module_inventory()
        modules = modules + (inventory and inventory.get_item_count("speed-module") or 0)
      end
    elseif entity.name == "requester-chest" then requesters = requesters + 1
    elseif entity.name == "passive-provider-chest" then
      providers = providers + 1
      local inventory = entity.get_inventory(defines.inventory.chest)
      output = output + (inventory and inventory.get_item_count("iron-gear-wheel") or 0)
    end
  end
  local trees = surface.count_entities_filtered({name = "tree-01", area = {{50, 3}, {59, 7}}})
  return machines, modules, requesters, providers, output, trees
end

script.on_init(function() storage.advanced_test = {prepared = false, requested = false, done = false} end)

script.on_event(defines.events.on_tick, function(event)
  local state = storage.advanced_test
  if not state or state.done then return end
  if not state.prepared then prepare(state); return end
  local player = game.get_player(state.player_index)
  if not state.requested and event.tick >= state.prepared_tick + 1200 then
    local marker = player.force.add_chart_tag(player.surface, {
      position = {50, 1}, text = "современный цех", last_user = player
    })
    if not marker then error("advanced test marker failed") end
    local accepted = remote.call("alina_ai", "address", player.index,
      "Аля, построй много [item=iron-gear-wheel] быстро и масштабно на метке современный цех")
    if not accepted.ok then error("advanced command rejected: " .. tostring(accepted.result)) end
    state.requested = true
    state.requested_tick = event.tick
  end
  if state.requested and event.tick % 60 == 0 then
    local status = remote.call("alina_ai", "status")
    local machines, modules, requesters, providers, output, trees = result(player.surface)
    if machines >= 8 and modules >= 8 and requesters >= 8 and providers >= 8
        and output > 0 and trees == 0 and not status.task then
      helpers.write_file("alina/advanced-production-result.json", helpers.table_to_json({
        ok = true, machines = machines, modules = modules, requesters = requesters,
        providers = providers, output = output, trees_cleared = 2, fast_belt_escape = true, tick = event.tick
      }), false)
      state.done = true
    elseif event.tick >= state.requested_tick + 48000 then
      error("advanced targeted timeout: machines=" .. machines .. ",modules=" .. modules
        .. ",requesters=" .. requesters .. ",providers=" .. providers .. ",output=" .. output
        .. ",trees=" .. trees
        .. ",task=" .. tostring(status.task and status.task.type or "nil")
        .. "/" .. tostring(status.task and status.task.phase or "nil"))
    end
  end
end)
