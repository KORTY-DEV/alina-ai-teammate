local function create(surface, parameters)
  local entity = surface.create_entity(parameters)
  if not entity then error("rail safety fixture could not create " .. tostring(parameters.name)) end
  return entity
end

local function prepare(state)
  local surface = game.surfaces[1]
  local player = game.players[1]
  if not player then return false end
  game.speed = 6
  local tiles = {}
  for x = -42, 42 do
    for y = -22, 22 do tiles[#tiles + 1] = {name = "grass-1", position = {x, y}} end
  end
  surface.set_tiles(tiles, true, false, true, false)
  for _, entity in ipairs(surface.find_entities_filtered({area = {{-42, -22}, {43, 23}}})) do
    if entity.valid and entity.type ~= "character" then entity.destroy() end
  end
  for _, resource in ipairs(surface.find_entities_filtered({position = {0, -14}, radius = 96,
      type = "resource", name = "iron-ore"})) do
    if resource.valid then resource.destroy() end
  end
  if not player.character then
    local character = create(surface, {name = "character", position = {0, -14}, force = player.force})
    player.set_controller({type = defines.controllers.character, character = character})
  else
    player.teleport({0, -14}, surface)
  end
  for x = -34, 34, 2 do
    create(surface, {name = "straight-rail", position = {x, 0}, direction = defines.direction.east,
      force = player.force})
  end
  local locomotive = create(surface, {name = "locomotive", position = {-30, 0},
    direction = defines.direction.east, force = player.force})
  locomotive.destructible = false
  local fuel = locomotive.get_fuel_inventory()
  if fuel then fuel.insert({name = "rocket-fuel", count = 10}) end
  locomotive.train.manual_mode = true
  locomotive.train.speed = 0
  local resource = create(surface, {name = "iron-ore", position = {0, 14}, amount = 10000})
  if not resource.valid then error("rail safety resource missing") end
  if not remote.call("alina_ai", "recall", player.index) then error("rail safety could not recall Alina") end
  state.player_index = player.index
  state.locomotive_unit = locomotive.unit_number
  state.prepared = true
  state.prepared_tick = game.tick
  state.minimum_distance = 999
  state.initial_health = remote.call("alina_ai", "status").agent.present and 250 or 0
  return true
end

local function train_entity(state)
  return state.locomotive_unit and game.get_entity_by_unit_number(state.locomotive_unit) or nil
end

script.on_init(function()
  storage.rail_safety_test = {prepared = false, requested = false, done = false}
end)

script.on_event(defines.events.on_tick, function(event)
  local state = storage.rail_safety_test
  if not state or state.done then return end
  if not state.prepared then prepare(state); return end
  local player = game.get_player(state.player_index)
  local status = remote.call("alina_ai", "status")
  local agent = status.agent.present and game.get_entity_by_unit_number(status.agent.unit_number) or nil
  local locomotive = train_entity(state)
  if state.train_started and locomotive and locomotive.valid then
    if locomotive.position.x < 22 then
      locomotive.train.speed = 0.20
    else
      locomotive.destroy()
      locomotive = nil
      state.train_cleared_tick = event.tick
    end
  end
  if agent and agent.valid and locomotive and locomotive.valid then
    local dx, dy = agent.position.x - locomotive.position.x, agent.position.y - locomotive.position.y
    state.minimum_distance = math.min(state.minimum_distance, math.sqrt(dx * dx + dy * dy))
  end
  if not state.requested and event.tick >= state.prepared_tick + 180 then
    local accepted = remote.call("alina_ai", "address", player.index, "Аля, добудь 5 железа")
    if not accepted.ok then error("rail safety command rejected: " .. tostring(accepted.result)) end
    state.requested = true
    state.requested_tick = event.tick
  end
  if state.requested and not state.train_started and status.task
      and status.task.type == "mine_resource" then
    state.train_started = true
    state.train_started_tick = event.tick
  end
  if state.requested and event.tick % 30 == 0 then
    status = remote.call("alina_ai", "status")
    agent = status.agent.present and game.get_entity_by_unit_number(status.agent.unit_number) or nil
    local mined = 0
    if agent and agent.valid then
      local inventory = agent.get_inventory(defines.inventory.character_main)
      mined = player.get_item_count("iron-ore")
    end
    local completed = status.last_task and status.last_task.type == "mine_resource"
      and status.last_task.status == "completed"
      and (status.last_task.finished_tick or 0) >= state.requested_tick
    if completed and (status.metrics.train_waits or 0) >= 1 and not status.task then
      helpers.write_file("alina/rail-safety-result.json", helpers.table_to_json({
        ok = true,
        train_waits = status.metrics.train_waits,
        rail_safety_scans = status.metrics.rail_safety_scans,
        minimum_train_distance = state.minimum_distance,
        mined = mined,
        agent_health = agent and agent.valid and agent.health or 0,
        train_cleared = state.train_cleared_tick ~= nil,
        tick = event.tick
      }), false)
      state.done = true
    elseif status.last_task and status.last_task.type == "mine_resource"
        and status.last_task.status == "failed"
        and (status.last_task.finished_tick or 0) >= state.requested_tick then
      error("rail safety mining failed: " .. tostring(status.last_task.result))
    elseif state.train_cleared_tick and event.tick >= state.train_cleared_tick + 600
        and status.last_task and status.last_task.type == "mine_resource"
        and status.last_task.status == "completed" and (status.metrics.train_waits or 0) < 1 then
      error("rail safety guard was not exercised before the train cleared")
    elseif event.tick >= state.requested_tick + 12000 then
      error("rail safety timeout: waits=" .. tostring(status.metrics.train_waits)
        .. ",scans=" .. tostring(status.metrics.rail_safety_scans)
        .. ",min-distance=" .. tostring(state.minimum_distance)
        .. ",train=" .. tostring(locomotive and locomotive.position.x or "cleared")
        .. ",task=" .. tostring(status.task and status.task.type or "nil"))
    end
  end
end)
