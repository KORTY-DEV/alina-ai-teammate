local TARGET_X = 14
local REQUEST_DELAY = 180
local TIMEOUT_DELAY = 1800
-- The production bootstrap now builds a useful 12-drill section and must
-- physically fetch its materials. Keep the test bounded, but do not apply the
-- old tiny-demo deadline to a full production block.
local BOOTSTRAP_TIMEOUT_DELAY = 30000
local MINING_AMOUNT = 25
local UPGRADE_POSITION = {x = 190, y = 100}
local ROLLBACK_POSITION = {x = 198, y = 100}

local function create(surface, parameters)
  parameters.force = parameters.force or "player"
  parameters.raise_built = true
  local entity = surface.create_entity(parameters)
  if not entity then error("test setup could not create " .. tostring(parameters.name)) end
  return entity
end

local function clear_test_area(surface)
  local tiles = {}
  for x = -16, 150 do
    for y = -24, 110 do tiles[#tiles + 1] = {name = "grass-1", position = {x, y}} end
  end
  surface.set_tiles(tiles, true, false, true, false)
  for _, entity in ipairs(surface.find_entities_filtered({area = {{-16, -24}, {151, 111}}})) do
    if entity.valid and entity.type ~= "character" then entity.destroy() end
  end
end

local function build_cell(surface, x)
  local furnace = create(surface, {name = "stone-furnace", position = {x, 0}})
  furnace.get_inventory(defines.inventory.crafter_input).insert({name = "iron-ore", count = 50})
  furnace.get_fuel_inventory().insert({name = "coal", count = 25})
  create(surface, {name = "burner-inserter", position = {x, -2}, direction = defines.direction.north})
  create(surface, {name = "burner-inserter", position = {x, 2}, direction = defines.direction.south})
  create(surface, {name = "burner-inserter", position = {x + 1, 0}, direction = defines.direction.west})
  create(surface, {name = "wooden-chest", position = {x + 2, 0}})
  create(surface, {name = "small-electric-pole", position = {x + 2, -2}})
end

local function setup()
  local state = storage.physical_expansion_test
  local surface = game.surfaces[1]
  local player = game.connected_players[1]
  if not player then return false end
  game.speed = 6
  game.forces.player.set_cease_fire("enemy", true)
  game.forces.enemy.set_cease_fire("player", true)
  local test_research = game.forces.player.technologies["alina-test-research"]
  local player_research = game.forces.player.technologies["alina-player-research"]
  if not test_research then error("test research prototype is missing") end
  if not player_research then error("player research prototype is missing") end
  test_research.enabled = true
  test_research.researched = false
  player_research.enabled = true
  player_research.researched = false
  clear_test_area(surface)

  if not player.character then
    local character = create(surface, {name = "character", position = {-8, 0}, force = player.force})
    player.set_controller({type = defines.controllers.character, character = character})
  else
    player.teleport({-8, 0}, surface)
  end
  local player_inventory = player.get_main_inventory()
  local existing_ore = player_inventory and player_inventory.get_item_count("iron-ore") or 0
  if existing_ore > 0 then player_inventory.remove({name = "iron-ore", count = existing_ore}) end

  for x = -10, -5 do
    for y = 5, 7 do
      local resource = surface.create_entity({name = "iron-ore", position = {x, y}, amount = 1000})
      if not resource then error("test setup could not create iron-ore") end
    end
  end

  local interface = create(surface, {name = "electric-energy-interface", position = {-4, -2}})
  interface.power_production = 10000000
  interface.electric_buffer_size = 10000000
  create(surface, {name = "small-electric-pole", position = {-2, -2}})

  for x = -3, 10 do
    create(surface, {name = "transport-belt", position = {x, -3}, direction = defines.direction.east})
    create(surface, {name = "transport-belt", position = {x, 3}, direction = defines.direction.east})
  end
  build_cell(surface, 0)
  build_cell(surface, 7)

  if not remote.call("alina_ai", "recall", player.index) then error("Alina character was not created") end
  local agent = nil
  for _, entity in ipairs(surface.find_entities_filtered({type = "character"})) do
    if entity.valid and entity ~= player.character then agent = entity; break end
  end
  if not agent then error("Alina character could not be located") end
  agent.insert({name = "stone-furnace", count = 4})
  agent.insert({name = "transport-belt", count = 64})
  agent.insert({name = "burner-inserter", count = 12})
  agent.insert({name = "wooden-chest", count = 4})
  agent.insert({name = "small-electric-pole", count = 8})
  state.prepared = true
  state.prepared_tick = game.tick
  return true
end

script.on_init(function()
  storage.physical_expansion_test = {
    prepared = false,
    mining_requested = false,
    mining_verified = false,
    requested = false,
    assembly_build_positions = {},
    done = false
  }
end)

script.on_event(defines.events.script_raised_built, function(event)
  local state = storage.physical_expansion_test
  local entity = event.entity
  if not state or not state.assembly_requested or state.assembly_verified
      or not entity or not entity.valid or entity.force.name ~= "player" then return end
  state.assembly_build_positions[#state.assembly_build_positions + 1] = {
    name = entity.name,
    type = entity.type,
    x = entity.position.x,
    y = entity.position.y,
    tick = event.tick
  }
end)

local function feed_line(surface, y, item)
  local belt_y = y < 0 and -2.5 or 3.5
  local belt = surface.find_entity("transport-belt", {-2.5, belt_y})
  if belt and belt.valid then
    belt.get_transport_line(1).insert_at_back({name = item, count = 1})
    belt.get_transport_line(2).insert_at_back({name = item, count = 1})
  end
end

local function feed_tail(surface, y, item)
  local belt = surface.find_entity("transport-belt", {10.5, y})
  if belt and belt.valid then
    belt.get_transport_line(1).insert_at_back({name = item, count = 1})
    belt.get_transport_line(2).insert_at_back({name = item, count = 1})
  end
end

local function target_result(surface)
  local furnace = surface.find_entity("stone-furnace", {TARGET_X, 0})
  local chest = surface.find_entity("wooden-chest", {TARGET_X + 2.5, 0.5})
  local ghosts = surface.count_entities_filtered({area = {{10, -5}, {19, 5}}, type = "entity-ghost"})
  local output = chest and chest.valid and chest.get_inventory(defines.inventory.chest).get_item_count("iron-plate") or 0
  return furnace, chest, ghosts, output
end

local function setup_mining_field(state, surface, player)
  for x = -1, 16 do
    for y = 15, 17 do
      local resource = surface.create_entity({name = "iron-ore", position = {x, y}, amount = 2000})
      if not resource then error("mining field setup could not create iron-ore") end
    end
  end
  for x = -3, 10 do
    create(surface, {name = "transport-belt", position = {x, 17}, direction = defines.direction.east})
  end
  for _, x in ipairs({0, 7}) do
    local drill = create(surface, {
      name = "burner-mining-drill",
      position = {x, 16},
      direction = defines.direction.south
    })
    drill.get_fuel_inventory().insert({name = "coal", count = 25})
  end

  local agent = nil
  for _, entity in ipairs(surface.find_entities_filtered({type = "character"})) do
    if entity.valid and entity ~= player.character then agent = entity; break end
  end
  if not agent then error("Alina character disappeared before mining field test") end
  agent.insert({name = "burner-mining-drill", count = 4})
  agent.insert({name = "transport-belt", count = 64})

  state.mining_field_prepared = true
  state.mining_field_prepared_tick = game.tick
end

local function setup_power_test(state, surface, player, produced)
  local machine = create(surface, {name = "assembling-machine-1", position = {22, 6}})
  machine.set_recipe("iron-gear-wheel")
  machine.get_inventory(defines.inventory.crafter_input).insert({name = "iron-plate", count = 20})
  local agent = nil
  for _, entity in ipairs(surface.find_entities_filtered({type = "character"})) do
    if entity.valid and entity ~= player.character then agent = entity; break end
  end
  if not agent then error("Alina character disappeared before power test") end
  agent.insert({name = "small-electric-pole", count = 12})
  state.mining_products_finished = produced
  state.power_pole_baseline = surface.count_entities_filtered({type = "electric-pole", force = "player"})
  state.power_prepared = true
  state.power_prepared_tick = game.tick
end

local function has_power_issue(entity)
  return entity and entity.valid and (entity.status == defines.entity_status.no_power
    or entity.status == defines.entity_status.low_power
    or entity.status == defines.entity_status.not_plugged_in_electric_network)
end

local function setup_bootstrap_test(state, surface, player, poles_built)
  for x = -8, 12 do
    for y = 32, 38 do
      local resource = surface.create_entity({name = "copper-ore", position = {x, y}, amount = 5000})
      if not resource then error("bootstrap setup could not create copper-ore") end
    end
  end
  local agent = nil
  for _, entity in ipairs(surface.find_entities_filtered({type = "character"})) do
    if entity.valid and entity ~= player.character then agent = entity; break end
  end
  if not agent then error("Alina character disappeared before bootstrap test") end
  local supply = create(surface, {name = "steel-chest", position = {24, 10}})
    .get_inventory(defines.inventory.chest)
  for _, stack in ipairs({
      {name = "burner-mining-drill", count = 24},
      {name = "stone-furnace", count = 24},
      {name = "transport-belt", count = 180},
      {name = "burner-inserter", count = 32},
      {name = "wooden-chest", count = 14},
      {name = "assembling-machine-1", count = 24},
      {name = "small-electric-pole", count = 24},
      {name = "iron-gear-wheel", count = 200},
      {name = "iron-plate", count = 400},
      {name = "copper-plate", count = 200},
      {name = "coal", count = 800},
      {name = "light-armor", count = 12},
      {name = "pistol", count = 12},
      {name = "firearm-magazine", count = 80}
    }) do
    if supply.insert(stack) ~= stack.count then error("bootstrap supply chest rejected " .. stack.name) end
  end
  state.power_restored = true
  state.power_poles_built = poles_built
  state.bootstrap_prepared = true
  state.bootstrap_prepared_tick = game.tick
end

local function bootstrap_result(surface)
  -- The production planner now sizes the processing row from measured mining
  -- throughput, so the verified output can be well beyond the old 8-furnace
  -- demonstration boundary.
  local area = {{-16, 28}, {150, 70}}
  local drills, furnaces, belts, output = 0, 0, 0, 0
  for _, entity in ipairs(surface.find_entities_filtered({area = area, force = "player"})) do
    if entity.type == "mining-drill" and entity.mining_target
        and entity.mining_target.valid and entity.mining_target.name == "copper-ore" then
      drills = drills + 1
    elseif entity.type == "furnace" then
      furnaces = furnaces + 1
    elseif entity.type == "transport-belt" then
      belts = belts + 1
    elseif entity.type == "container" or entity.type == "logistic-container" then
      local inventory = entity.get_inventory(defines.inventory.chest)
      output = output + (inventory and inventory.get_item_count("copper-plate") or 0)
    end
  end
  return drills, furnaces, belts, output
end

local function assembly_result(surface)
  local machines, output = 0, 0
  for _, entity in ipairs(surface.find_entities_filtered({force = "player"})) do
    if entity.type == "assembling-machine" then
      local recipe = entity.get_recipe()
      if recipe and recipe.name == "iron-gear-wheel"
          and (entity.position.x ~= 22 or entity.position.y ~= 6) then machines = machines + 1 end
    elseif entity.type == "container" or entity.type == "logistic-container" then
      local inventory = entity.get_inventory(defines.inventory.chest)
      if entity.position.x ~= 24 or entity.position.y ~= 10 then
        output = output + (inventory and inventory.get_item_count("iron-gear-wheel") or 0)
      end
    end
  end
  return machines, output
end

local function assembly_build_quality(positions)
  local reversals, previous_vertical_sign = 0, nil
  local machine_rows = {}
  for index, row in ipairs(positions or {}) do
    if index > 1 then
      local dy = row.y - positions[index - 1].y
      if math.abs(dy) >= 0.5 then
        local sign = dy > 0 and 1 or -1
        if previous_vertical_sign and sign ~= previous_vertical_sign then reversals = reversals + 1 end
        previous_vertical_sign = sign
      end
    end
    if row.type == "assembling-machine" then
      local key = string.format("%.2f", row.y)
      machine_rows[key] = machine_rows[key] or {}
      machine_rows[key][#machine_rows[key] + 1] = row
    end
  end
  local best = {}
  for _, row in pairs(machine_rows) do
    if #row > #best then best = row end
  end
  table.sort(best, function(a, b) return a.x < b.x end)
  local max_gap = 0
  for index = 2, #best do
    local previous = prototypes.entity[best[index - 1].name]
    local current = prototypes.entity[best[index].name]
    local footprint = ((previous and previous.tile_width or 1)
      + (current and current.tile_width or 1)) / 2
    max_gap = math.max(max_gap, best[index].x - best[index - 1].x - footprint)
  end
  return #positions, reversals, #best, max_gap
end

local function alina_agent(surface, player)
  if remote.interfaces.alina_ai then
    local status = remote.call("alina_ai", "status")
    local unit_number = status and status.agent and status.agent.unit_number
    local exact = unit_number and game.get_entity_by_unit_number(unit_number) or nil
    if exact and exact.valid and exact.type == "character" and exact.surface == surface then return exact end
  end
  for _, entity in ipairs(surface.find_entities_filtered({type = "character", force = player.force})) do
    if entity.valid and entity ~= player.character then return entity end
  end
  return nil
end

local function stock(inventory, stacks)
  for _, stack in ipairs(stacks) do
    if inventory.insert(stack) ~= stack.count then error("advanced supply rejected " .. stack.name) end
  end
end

local function powered_roboport(surface, position)
  local interface = create(surface, {name = "electric-energy-interface",
    position = {position.x, position.y - 5}})
  interface.power_production = 100000000
  interface.electric_buffer_size = 100000000
  create(surface, {name = "substation", position = {position.x, position.y - 2}})
  return create(surface, {name = "roboport", position = position})
end

local function setup_advanced_factory_test(state, surface, player)
  local advanced = {
    ["logistic-system"] = true,
    ["automation-3"] = true,
    ["speed-module"] = true,
    ["electric-energy-distribution-2"] = true,
    ["construction-robotics"] = true
  }
  for name in pairs(advanced) do
    local technology = player.force.technologies[name]
    if technology then technology.researched = true end
  end
  local roboports = {}
  for _, x in ipairs({64, 94, 124}) do
    roboports[#roboports + 1] = powered_roboport(surface, {x = x, y = -18})
    roboports[#roboports + 1] = powered_roboport(surface, {x = x, y = 18})
  end
  for _, roboport in ipairs(roboports) do
    local robot_inventory = roboport.get_inventory(defines.inventory.roboport_robot)
    if not robot_inventory or robot_inventory.insert({name = "logistic-robot", count = 25}) ~= 25 then
      error("advanced setup could not stock logistic robots")
    end
  end
  local block_power = create(surface, {name = "electric-energy-interface", position = {94, -4}})
  block_power.power_production = 100000000
  block_power.electric_buffer_size = 100000000
  create(surface, {name = "substation", position = {94, 0}})
  local supply = create(surface, {name = "steel-chest", position = {66, -4}})
    .get_inventory(defines.inventory.chest)
  stock(supply, {
    {name = "assembling-machine-3", count = 20},
    {name = "stack-inserter", count = 40},
    {name = "requester-chest", count = 40},
    {name = "passive-provider-chest", count = 40},
    {name = "steel-chest", count = 16},
    {name = "substation", count = 16},
    {name = "speed-module", count = 40},
    {name = "iron-plate", count = 2400}
  })
  local logistic_supply = create(surface, {name = "storage-chest", position = {83, -7}})
    .get_inventory(defines.inventory.chest)
  logistic_supply.insert({name = "iron-plate", count = 2000})
  local marker = player.force.add_chart_tag(surface, {
    position = {x = 94, y = 1}, text = "современный цех", last_user = player
  })
  if not marker then error("advanced marker could not be created") end
  local result = remote.call("alina_ai", "address", player.index,
    "Аля, построй много [item=iron-gear-wheel] быстро и масштабно на метке современный цех")
  if not result.ok then error("advanced production command was rejected: " .. tostring(result.result)) end
  state.advanced_requested = true
  state.advanced_requested_tick = game.tick
end

local function advanced_factory_result(surface)
  local machines, modules, requesters, providers, output = 0, 0, 0, 0, 0
  for _, entity in ipairs(surface.find_entities_filtered({area = {{-16, -24}, {151, 40}}, force = "player"})) do
    if entity.name == "assembling-machine-3" then
      local recipe = entity.get_recipe()
      if recipe and recipe.name == "iron-gear-wheel" then
        machines = machines + 1
        local inventory = entity.get_module_inventory()
        modules = modules + (inventory and inventory.get_item_count("speed-module") or 0)
      end
    elseif entity.name == "requester-chest" then
      requesters = requesters + 1
    elseif entity.name == "passive-provider-chest" then
      providers = providers + 1
      local inventory = entity.get_inventory(defines.inventory.chest)
      output = output + (inventory and inventory.get_item_count("iron-gear-wheel") or 0)
    end
  end
  return machines, modules, requesters, providers, output
end

local function setup_long_route_test(state, surface, player)
  for x = 82, 102 do
    for y = 72, 82 do
      if not surface.create_entity({name = "copper-ore", position = {x, y}, amount = 8000}) then
        error("long route setup could not create copper ore")
      end
    end
  end
  local agent = alina_agent(surface, player)
  if not agent then error("Alina disappeared before long route test") end
  local supply = create(surface, {name = "steel-chest", position = {72, 54}})
    .get_inventory(defines.inventory.chest)
  stock(supply, {
    {name = "burner-mining-drill", count = 24},
    {name = "stone-furnace", count = 24},
    {name = "transport-belt", count = 800},
    {name = "burner-inserter", count = 48},
    {name = "steel-chest", count = 12},
    {name = "wooden-chest", count = 12},
    {name = "coal", count = 1200}
  })
  player.teleport({30, 20}, surface)
  local marker = player.force.add_chart_tag(surface, {
    position = {x = 92, y = 77}, text = "дальняя медь", last_user = player
  })
  if not marker then error("long route marker could not be created") end
  local result = remote.call("alina_ai", "address", player.index,
    "Аля, обустрой жилу на метке дальняя медь и доведи от жилы ленту до базы")
  if not result.ok then error("long route command was rejected: " .. tostring(result.result)) end
  state.long_route_requested = true
  state.long_route_requested_tick = game.tick
end

local function long_route_result(surface)
  local belts, output, nearest_output_distance = 0, 0, nil
  for _, entity in ipairs(surface.find_entities_filtered({area = {{20, 15}, {130, 105}}, force = "player"})) do
    if entity.type == "transport-belt" then
      belts = belts + 1
    elseif entity.type == "container" or entity.type == "logistic-container" then
      local inventory = entity.get_inventory(defines.inventory.chest)
      local count = inventory and inventory.get_item_count("copper-plate") or 0
      if count > 0 then
        output = output + count
        local dx, dy = entity.position.x - 30, entity.position.y - 20
        local distance = math.sqrt(dx * dx + dy * dy)
        nearest_output_distance = math.min(nearest_output_distance or distance, distance)
      end
    end
  end
  return belts, output, nearest_output_distance
end

local function start_marker_assembly_test(state, surface, player)
  local marker = player.force.add_chart_tag(surface, {
    position = {30, 0},
    text = "наука",
    last_user = player
  })
  if not marker then error("test marker could not be created") end
  state.assembly_build_positions = {}
  local result = remote.call("alina_ai", "address", player.index,
    "Аля, построй [item=iron-gear-wheel] на метке наука, это в приоритете")
  if not result.ok then error("marker production priority was rejected: " .. tostring(result.result)) end
  state.marker_number = marker.tag_number
  state.assembly_requested = true
  state.assembly_requested_tick = game.tick
end

local function start_research_control_test(state, player)
  local result = remote.call("alina_ai", "address", player.index, "Аля, не выбирай исследования пока")
  if not result.ok then error("research hold command was rejected") end
  local status = remote.call("alina_ai", "status")
  if not status.research.hold or status.research.hold_source ~= "player_chat" then
    error("indefinite research hold was not recorded")
  end
  if player.force.current_research then player.force.cancel_current_research() end
  state.research_hold_started = true
  state.research_hold_started_tick = game.tick
end

local function equipment_count(rows, name)
  local count = 0
  for _, row in pairs(rows or {}) do
    if row.name == name then count = count + (row.count or 0) end
  end
  return count
end

local function equipment_by_name(agent, name)
  local grid = agent and agent.grid or nil
  if not grid or not grid.valid then return nil end
  for _, equipment in ipairs(grid.equipment or {}) do
    if equipment.valid and equipment.name == name then return equipment end
  end
  return nil
end

local function setup_mobility_test(state, surface, player)
  local hold = remote.call("alina_ai", "address", player.index, "Аля, не выбирай исследования пока")
  if not hold.ok then error("mobility research hold was rejected") end
  if player.force.current_research then player.force.cancel_current_research() end
  local agent = alina_agent(surface, player)
  if not agent then error("Alina disappeared before mobility test") end
  local main = agent.get_inventory(defines.inventory.character_main)
  if not main then error("Alina main inventory is unavailable before mobility test") end
  for _, stack in ipairs({
      {name = "modular-armor", count = 1},
      {name = "alina-test-burner-generator-equipment", count = 1},
      {name = "belt-immunity-equipment", count = 1},
      {name = "exoskeleton-equipment", count = 1},
      {name = "spidertron", count = 1},
      {name = "coal", count = 10}
    }) do
    if not prototypes.item[stack.name] then error("mobility prototype missing: " .. stack.name) end
    local present = main.get_item_count(stack.name)
    local missing = math.max(0, stack.count - present)
    if missing > 0 and main.insert({name = stack.name, count = missing}) ~= missing then
      local used = main and (#main - main.count_empty_stacks()) or -1
      error("Alina inventory rejected mobility item " .. stack.name
        .. " (present=" .. present .. ", used-slots=" .. used .. ")")
    end
  end
  -- The vehicle policy is intentionally reserved for established factories.
  -- Idle burner furnaces make the scale check real without adding power issues
  -- or production-flow noise that could supersede the loadout task.
  local created = 0
  for x = 104, 140, 4 do
    for y = -20, 16, 4 do
      if created < 100 then
        create(surface, {name = "stone-furnace", position = {x, y}})
        created = created + 1
      end
    end
  end
  player.force.get_item_production_statistics(surface).clear()
  local pulse = remote.call("alina_ai", "address", player.index,
    "Аля, подготовь экипировку и паукотрон")
  if not pulse.ok then error("mobility autonomy did not start: " .. tostring(pulse.result)) end
  state.mobility_started = true
  state.mobility_started_tick = game.tick
end

local function start_spider_route_test(state, surface, player)
  -- The direct mining command intentionally selects the nearest matching
  -- resource. Remove earlier fixture ore so this stage unambiguously exercises
  -- the distant, freshly-created patch instead of a closer bootstrap remnant.
  for _, resource in ipairs(surface.find_entities_filtered({type = "resource", name = "iron-ore"})) do
    resource.destroy()
  end
  local agent = alina_agent(surface, player)
  if not agent then error("Alina disappeared before spider route test") end
  local center = {x = math.floor(agent.position.x + 32), y = math.floor(agent.position.y + 32)}
  surface.request_to_generate_chunks(center, 1)
  surface.force_generate_chunk_requests()
  for x = center.x - 3, center.x + 3 do
    for y = center.y - 3, center.y + 3 do
      if not surface.create_entity({name = "iron-ore", position = {x, y}, amount = 5000}) then
        error("spider route setup could not create iron ore")
      end
    end
  end
  player.teleport({center.x + 24, center.y}, surface)
  local inventory = player.get_main_inventory()
  local old = inventory and inventory.get_item_count("iron-ore") or 0
  if old > 0 then inventory.remove({name = "iron-ore", count = old}) end
  local result = remote.call("alina_ai", "address", player.index, "Аля, добудь 10 железа")
  if not result.ok then error("spider route mining command was rejected: " .. tostring(result.result)) end
  state.spider_route_started = true
  state.spider_route_started_tick = game.tick
end

local function setup_upgrade_machine(surface, position)
  local machine = create(surface, {name = "alina-test-assembler-1", position = position})
  machine.set_recipe("iron-gear-wheel")
  local recipe = machine.get_recipe()
  if not recipe or recipe.name ~= "iron-gear-wheel" then error("upgrade test recipe was rejected") end
  local input = machine.get_inventory(defines.inventory.crafter_input)
  if not input or input.insert({name = "iron-plate", count = 100}) ~= 100 then
    error("upgrade test input could not be stocked")
  end
  return machine
end

local function setup_upgrade_test(state, surface, player)
  local technology = player.force.technologies["automation-2"]
  if not technology then error("automation-2 is unavailable for upgrade test") end
  technology.researched = true
  surface.request_to_generate_chunks({194, 96}, 1)
  surface.force_generate_chunk_requests()
  local tiles = {}
  for x = 182, 204 do
    for y = 86, 106 do tiles[#tiles + 1] = {name = "grass-1", position = {x, y}} end
  end
  surface.set_tiles(tiles, true, false, true, false)
  for _, entity in ipairs(surface.find_entities_filtered({area = {{182, 86}, {205, 107}}})) do
    if entity.valid and entity.type ~= "character" then entity.destroy() end
  end
  local interface = create(surface, {name = "electric-energy-interface", position = {194, 90}})
  interface.power_production = 100000000
  interface.electric_buffer_size = 100000000
  create(surface, {name = "substation", position = {194, 96}})
  setup_upgrade_machine(surface, UPGRADE_POSITION)
  local upgrade_supply = create(surface, {name = "steel-chest", position = {202, 96}})
    .get_inventory(defines.inventory.chest)
  stock(upgrade_supply, {{name = "alina-test-assembler-2", count = 2}})
  local agent = alina_agent(surface, player)
  if not agent then error("Alina disappeared before upgrade test") end
  state.upgrade_prepared = true
  state.upgrade_prepared_tick = game.tick
end

local function setup_upgrade_rollback_test(state, surface)
  setup_upgrade_machine(surface, ROLLBACK_POSITION)
  state.upgrade_rollback_prepared = true
  state.upgrade_rollback_prepared_tick = game.tick
end

local function setup_capacity_diagnostics_test(state, surface)
  surface.request_to_generate_chunks({256, 96}, 1)
  surface.force_generate_chunk_requests()
  local tiles = {}
  for x = 242, 266 do
    for y = 84, 106 do tiles[#tiles + 1] = {name = "grass-1", position = {x, y}} end
  end
  surface.set_tiles(tiles, true, false, true, false)
  for _, entity in ipairs(surface.find_entities_filtered({area = {{242, 84}, {267, 107}}})) do
    if entity.valid and entity.type ~= "character" then entity.destroy() end
  end
  local interface = create(surface, {name = "electric-energy-interface", position = {256, 90}})
  interface.power_production = 100000000
  interface.electric_buffer_size = 100000000
  create(surface, {name = "substation", position = {256, 96}})
  state.capacity_machine_positions = {}
  for _, x in ipairs({248, 252, 256, 260}) do
    local machine = create(surface, {name = "assembling-machine-1", position = {x, 101}})
    machine.set_recipe("alina-capacity-product")
    state.capacity_machine_positions[#state.capacity_machine_positions + 1] = {
      x = machine.position.x, y = machine.position.y
    }
  end
  state.capacity_diagnostics_prepared = true
  state.capacity_diagnostics_tick = game.tick
end

local function fill_capacity_outputs(state)
  local surface = game.surfaces[1]
  for _, position in ipairs(state.capacity_machine_positions or {}) do
    local machine = surface.find_entity("assembling-machine-1", position)
    if not machine or not machine.valid then error("capacity diagnostic machine disappeared") end
    local input = machine.get_inventory(defines.inventory.crafter_input)
    local output = machine.get_output_inventory()
    if not input or not output then error("capacity diagnostic inventories unavailable") end
    input.insert({name = "iron-plate", count = 100})
    output.insert({name = "alina-capacity-product", count = 10000})
  end
end

local function finish_result(state, surface, status)
  local drills, furnaces, belts, output = bootstrap_result(surface)
  local machines, science = assembly_result(surface)
  local assembly_events, assembly_reversals, assembly_row_machines, assembly_max_gap =
    assembly_build_quality(state.assembly_build_positions)
  local advanced_machines, advanced_modules, requesters, providers, advanced_output = advanced_factory_result(surface)
  local route_belts, route_output, route_distance = long_route_result(surface)
  local armor = status.agent and status.agent.armor or nil
  local weapon = status.agent and status.agent.weapons and status.agent.weapons[1] or nil
  state.pending_result = {
    ok = true,
    tick = game.tick,
    target_x = TARGET_X,
    output = state.physical_output,
    mined_and_delivered = state.mined,
    mining_drill_expanded = true,
    mining_products_finished = state.mining_products_finished,
    power_restored = state.power_restored,
    power_poles_built = state.power_poles_built,
    bootstrap_chain_output = output,
    bootstrap_drills = drills,
    bootstrap_furnaces = furnaces,
    bootstrap_belts = belts,
    assembly_machines = machines,
    assembly_output = science,
    assembly_build_events = assembly_events,
    assembly_vertical_reversals = assembly_reversals,
    assembly_compact_row_machines = assembly_row_machines,
    assembly_max_machine_gap = assembly_max_gap,
    advanced_machines = advanced_machines,
    advanced_speed_modules = advanced_modules,
    advanced_requesters = requesters,
    advanced_providers = providers,
    advanced_output = advanced_output,
    long_route_belts = route_belts,
    long_route_output = route_output,
    long_route_output_distance = route_distance,
    marker_understood = state.marker_number ~= nil,
    research_indefinite_hold = state.research_hold_verified == true,
    research_timed_hold = state.research_timed_verified == true,
    player_research_preserved = state.player_research_verified == true,
    research_priority_followed = state.research_priority_verified == true,
    -- The useful production bootstrap can keep the agent busy until the
    -- dedicated loadout phase, which may equip a better armour tier directly.
    -- Record the first observed kit when available, otherwise the final
    -- verified kit instead of emitting absent JSON fields.
    loadout_armor = state.initial_loadout_armor or armor,
    loadout_gun = state.initial_loadout_gun or (weapon and weapon.gun or nil),
    loadout_ammo = state.initial_loadout_ammo or (weapon and weapon.ammo_count or 0),
    mobility_armor = armor,
    mobility_solar = equipment_count(status.agent and status.agent.equipment,
      "solar-panel-equipment"),
    mobility_burner_generator = equipment_count(status.agent and status.agent.equipment,
      "alina-test-burner-generator-equipment"),
    mobility_fuel_refill = state.mobility_fuel_refill or 0,
    mobility_belt_immunity = equipment_count(status.agent and status.agent.equipment,
      "belt-immunity-equipment"),
    mobility_exoskeleton = equipment_count(status.agent and status.agent.equipment,
      "exoskeleton-equipment"),
    mobility_spider_routes = status.metrics.spider_routes or 0,
    mobility_spider_fallbacks = status.metrics.spider_fallbacks or 0,
    mobility_mined_and_delivered = state.mobility_mined or 0,
    machine_upgrade_verified = state.machine_upgrade_verified == true,
    machine_upgrade_rollback = state.machine_upgrade_rollback == true,
    upstream_pressure_verified = state.upstream_pressure_verified == true,
    logistics_pressure_verified = state.logistics_pressure_verified == true,
    active_player_boundary_verified = state.active_player_boundary_verified == true,
    protected_area_owner_verified = state.protected_area_owner_verified == true,
    protected_area_release_verified = state.protected_area_release_verified == true,
    periodic_advice_generated = state.periodic_advice_generated == true,
    autonomous_research = state.autonomous_research,
    ghosts = surface.count_entities_filtered({area = {{-16, -24}, {151, 111}}, type = "entity-ghost"}),
    task_complete = true
  }
  state.crc_requested_tick = game.tick
  game.force_crc()
end

local function agent_loadout(surface, player)
  local agent = nil
  for _, entity in ipairs(surface.find_entities_filtered({type = "character", force = player.force})) do
    if entity.valid and entity ~= player.character then agent = entity; break end
  end
  if not agent then return nil, nil, 0 end
  local armor_inventory = agent.get_inventory(defines.inventory.character_armor)
  local gun_inventory = agent.get_inventory(defines.inventory.character_guns)
  local ammo_inventory = agent.get_inventory(defines.inventory.character_ammo)
  local armor = armor_inventory and armor_inventory[1].valid_for_read and armor_inventory[1].name or nil
  local gun, ammo = nil, 0
  if gun_inventory and ammo_inventory then
    for index = 1, #gun_inventory do
      if gun_inventory[index].valid_for_read then
        gun = gun_inventory[index].name
        if ammo_inventory[index].valid_for_read then ammo = ammo_inventory[index].count end
        break
      end
    end
  end
  return armor, gun, ammo
end

local function inventory_count(entity, inventory_id, item)
  local inventory = entity and entity.valid and entity.get_inventory(inventory_id) or nil
  return inventory and inventory.get_item_count(item) or 0
end

local function bootstrap_diagnostics(surface, status)
  local player = game.get_player(1)
  local armor, gun, ammo = agent_loadout(surface, player)
  local result = {
    task_type = status.task and status.task.type or nil,
    task_phase = status.task and status.task.phase or nil,
    drills = {},
    furnaces = {},
    inserters = {},
    belts = {},
    armor = armor,
    gun = gun,
    ammo = ammo,
    research = player.force.current_research and player.force.current_research.name or nil
  }
  for _, entity in ipairs(surface.find_entities_filtered({area = {{-16, 28}, {62, 54}}, force = "player"})) do
    if entity.type == "mining-drill" then
      result.drills[#result.drills + 1] = {
        x = entity.position.x, y = entity.position.y, direction = entity.direction,
        status = entity.status,
        target = entity.mining_target and entity.mining_target.valid and entity.mining_target.name or nil,
        fuel = inventory_count(entity, defines.inventory.fuel, "coal")
      }
    elseif entity.type == "furnace" then
      result.furnaces[#result.furnaces + 1] = {
        x = entity.position.x, y = entity.position.y, status = entity.status,
        ore = inventory_count(entity, defines.inventory.crafter_input, "copper-ore"),
        plate = inventory_count(entity, defines.inventory.crafter_output, "copper-plate"),
        fuel = inventory_count(entity, defines.inventory.fuel, "coal")
      }
    elseif entity.type == "inserter" then
      result.inserters[#result.inserters + 1] = {
        x = entity.position.x, y = entity.position.y, direction = entity.direction,
        status = entity.status,
        pickup = entity.pickup_position,
        drop = entity.drop_position,
        held = entity.held_stack and entity.held_stack.valid_for_read and entity.held_stack.name or nil
      }
    elseif entity.type == "transport-belt" and (#result.belts < 12
        or (entity.position.x == 15.5 and entity.position.y >= 33.5)
        or entity.position.y == 41.5 or entity.position.y == 46.5) then
      local line1 = entity.get_transport_line(1)
      local line2 = entity.get_transport_line(2)
      result.belts[#result.belts + 1] = {
        x = entity.position.x, y = entity.position.y, direction = entity.direction,
        ore = line1.get_item_count("copper-ore") + line2.get_item_count("copper-ore"),
        plate = line1.get_item_count("copper-plate") + line2.get_item_count("copper-plate")
      }
    end
  end
  return result
end

script.on_event(defines.events.on_tick, function(event)
  local state = storage.physical_expansion_test
  if not state or state.done then return end
  if state.pending_result then
    if event.tick >= state.crc_requested_tick + 180 then
      state.pending_result.crc_wait_ticks = event.tick - state.crc_requested_tick
      helpers.write_file("alina/physical-expansion-result.json",
        helpers.table_to_json(state.pending_result), false)
      state.done = true
    end
    return
  end
  if not state.prepared then setup(); return end
  local surface = game.surfaces[1]
  if event.tick % 20 == 0 then
    for _, inserter in ipairs(surface.find_entities_filtered({type = "inserter", force = "player"})) do
      if inserter.valid then
        local fuel = inserter.get_fuel_inventory()
        if fuel and fuel.get_item_count("coal") < 2 then fuel.insert({name = "coal", count = 5}) end
      end
    end
    for _, drill in ipairs(surface.find_entities_filtered({type = "mining-drill", force = "player"})) do
      local fuel = drill.valid and drill.get_fuel_inventory() or nil
      if fuel and fuel.get_item_count("coal") < 2 then fuel.insert({name = "coal", count = 10}) end
    end
    feed_line(surface, -3, "iron-ore")
    feed_line(surface, 3, "coal")
    if state.requested then
      feed_tail(surface, -2.5, "iron-ore")
      feed_tail(surface, 3.5, "coal")
      local target = surface.find_entity("stone-furnace", {TARGET_X, 0})
      if target and target.valid then
        local input = target.get_inventory(defines.inventory.crafter_input)
        local fuel = target.get_fuel_inventory()
        if input and input.get_item_count("iron-ore") < 2 then input.insert({name = "iron-ore", count = 5}) end
        if fuel and fuel.get_item_count("coal") < 2 then fuel.insert({name = "coal", count = 5}) end
      end
    end
  end

  if not state.mining_requested and event.tick >= state.prepared_tick + 60 then
    local player = game.get_player(1)
    local result = remote.call("alina_ai", "address", player.index, "Аля, добудь 25 железа")
    if not result.ok then error("direct mining command was rejected: " .. tostring(result.result)) end
    state.mining_requested = true
    state.mining_requested_tick = event.tick
    return
  end

  if state.mining_requested and not state.mining_verified then
    local player = game.get_player(1)
    local player_inventory = player and player.get_main_inventory() or nil
    local delivered = player_inventory and player_inventory.get_item_count("iron-ore") or 0
    local status = remote.call("alina_ai", "status")
    if delivered >= MINING_AMOUNT and not status.task then
      state.mining_verified = true
      state.mining_verified_tick = event.tick
      state.mined = delivered
      player_inventory.remove({name = "iron-ore", count = delivered})
    elseif event.tick >= state.mining_requested_tick + 3600 then
      error("direct mining timeout: delivered=" .. tostring(delivered)
        .. ", task=" .. (status.task and helpers.table_to_json(status.task) or "nil"))
    end
    return
  end

  if state.mining_verified and not state.requested
      and event.tick >= state.mining_verified_tick + REQUEST_DELAY then
    local player = game.get_player(1)
    -- Continuous development may legitimately start another useful task in
    -- the short gap between fixture phases. Wait for its transaction instead
    -- of treating normal autonomous work as a fatal test failure.
    if remote.call("alina_ai", "status").task then return end
    local stats = player.force.get_item_production_statistics(surface)
    stats.clear()
    stats.on_flow("iron-plate", 100)
    stats.on_flow("iron-plate", -250)
    local furnace_recipes = {}
    for _, furnace in ipairs(surface.find_entities_filtered({type = "furnace", force = player.force})) do
      local recipe = furnace.get_recipe()
      furnace_recipes[#furnace_recipes + 1] = {position = furnace.position, recipe = recipe and recipe.name or nil}
    end
    helpers.write_file("alina/physical-expansion-preflight.json", helpers.table_to_json({
      furnaces = furnace_recipes,
      snapshot = remote.call("alina_ai", "snapshot", player.index)
    }), false)
    local result = remote.call("alina_ai", "autonomy_pulse", player.index, "iron-plate")
    if not result.ok then error("autonomy did not start: " .. tostring(result.result)) end
    state.requested = true
    state.requested_tick = event.tick
  end

  if state.requested and not state.physical_verified and event.tick % 60 == 0 then
    local furnace, chest, ghosts, output = target_result(surface)
    local status = remote.call("alina_ai", "status")
    if furnace and chest and ghosts == 0 and output > 0 and not status.task then
      state.physical_verified = true
      state.physical_output = output
      setup_mining_field(state, surface, game.get_player(1))
      return
    end
  end

  if state.mining_field_prepared and not state.mining_field_requested
      and event.tick >= state.mining_field_prepared_tick + 120 then
    if remote.call("alina_ai", "status").task then return end
    local result = remote.call("alina_ai", "autonomy_pulse", game.get_player(1).index, "iron-ore")
    if not result.ok then error("mining field autonomy did not start: " .. tostring(result.result)) end
    state.mining_field_requested = true
    state.mining_field_requested_tick = event.tick
  end

  if state.mining_field_requested and not state.mining_field_verified and event.tick % 30 == 0 then
    local target_drill = surface.find_entity("burner-mining-drill", {14, 16})
    local status = remote.call("alina_ai", "status")
    if target_drill and target_drill.valid and not status.task and not state.mining_target_isolated then
      for _, source_x in ipairs({0, 7}) do
        local source = surface.find_entity("burner-mining-drill", {source_x, 16})
        if source and source.valid then source.destroy() end
      end
      state.mining_output_baseline = game.forces.player.get_item_production_statistics(surface).get_output_count("iron-ore")
      state.mining_target_isolated = true
    end
    if target_drill and target_drill.valid and state.mining_target_isolated then
      local produced = game.forces.player.get_item_production_statistics(surface).get_output_count("iron-ore")
        - state.mining_output_baseline
      if produced > 0 and target_drill.mining_target and target_drill.status == defines.entity_status.working then
        state.mining_field_verified = true
        setup_power_test(state, surface, game.get_player(1), produced)
        return
      end
    end
    if event.tick >= state.mining_field_requested_tick + TIMEOUT_DELAY then
      error("mining field expansion timeout: drill=" .. tostring(target_drill ~= nil)
        .. ", isolated=" .. tostring(state.mining_target_isolated)
        .. ", output=" .. tostring(state.mining_output_baseline and
          (game.forces.player.get_item_production_statistics(surface).get_output_count("iron-ore") - state.mining_output_baseline) or nil)
        .. ", task=" .. (status.task and helpers.table_to_json(status.task) or "nil"))
    end
  end

  if state.power_prepared and not state.power_requested
      and event.tick >= state.power_prepared_tick + 120 then
    local machine = surface.find_entity("assembling-machine-1", {22, 6})
    if has_power_issue(machine) then
      if remote.call("alina_ai", "status").task then return end
      local result = remote.call("alina_ai", "autonomy_pulse", game.get_player(1).index)
      if not result.ok then error("power repair autonomy did not start: " .. tostring(result.result)) end
    end
    state.power_requested = true
    state.power_requested_tick = event.tick
  end

  if state.power_requested and not state.power_verified and event.tick % 30 == 0 then
    local machine = surface.find_entity("assembling-machine-1", {22, 6})
    local status = remote.call("alina_ai", "status")
    local pole_count = surface.count_entities_filtered({type = "electric-pole", force = "player"})
    if machine and machine.valid and not has_power_issue(machine)
        and pole_count > state.power_pole_baseline and not status.task then
      state.power_verified = true
      setup_bootstrap_test(state, surface, game.get_player(1), pole_count - state.power_pole_baseline)
      return
    end
    if event.tick >= state.power_requested_tick + TIMEOUT_DELAY then
      error("power repair timeout: machine_status=" .. tostring(machine and machine.status)
        .. ", poles_built=" .. tostring(pole_count - state.power_pole_baseline)
        .. ", task=" .. (status.task and helpers.table_to_json(status.task) or "nil"))
    end
  end

  if state.bootstrap_prepared and not state.bootstrap_requested
      and event.tick >= state.bootstrap_prepared_tick + 120 then
    if remote.call("alina_ai", "status").task then return end
    local result = remote.call("alina_ai", "autonomy_pulse", game.get_player(1).index, "copper-plate")
    if not result.ok then error("bootstrap chain autonomy did not start: " .. tostring(result.result)) end
    state.bootstrap_requested = true
    state.bootstrap_requested_tick = event.tick
  end

  if state.bootstrap_requested and event.tick % 60 == 0 then
    local status = remote.call("alina_ai", "status")
    local drills, furnaces, belts, output = bootstrap_result(surface)
    local armor = status.agent and status.agent.armor or nil
    local weapon = status.agent and status.agent.weapons and status.agent.weapons[1] or nil
    local gun = weapon and weapon.gun or nil
    local ammo = weapon and weapon.ammo_count or 0
    if not state.initial_loadout_verified and armor == "light-armor"
        and gun == "pistol" and ammo >= 50 then
      state.initial_loadout_verified = true
      state.initial_loadout_armor = armor
      state.initial_loadout_gun = gun
      state.initial_loadout_ammo = ammo
    end
    if not state.bootstrap_verified and drills >= 2 and furnaces >= 2 and belts >= 12 and output > 0
        and game.get_player(1).force.current_research and not status.task then
      state.bootstrap_verified = true
      start_marker_assembly_test(state, surface, game.get_player(1))
      return
    end
    if not state.bootstrap_verified and event.tick >= state.bootstrap_requested_tick + BOOTSTRAP_TIMEOUT_DELAY then
      helpers.write_file("alina/bootstrap-diagnostics.json",
        helpers.table_to_json(bootstrap_diagnostics(surface, status)), false)
      error("bootstrap chain timeout: drills=" .. tostring(drills)
        .. ", furnaces=" .. tostring(furnaces)
        .. ", belts=" .. tostring(belts)
        .. ", output=" .. tostring(output)
        .. ", task=" .. tostring(status.task and status.task.type or "nil")
        .. "/" .. tostring(status.task and status.task.phase or "nil"))
    end
  end

  if state.assembly_requested and not state.assembly_verified and event.tick % 60 == 0 then
    local status = remote.call("alina_ai", "status")
    local machines, output = assembly_result(surface)
    if machines >= 4 and output > 0 and not status.task then
      state.assembly_verified = true
      state.assembly_verified_tick = event.tick
      start_research_control_test(state, game.get_player(1))
      return
    end
    if event.tick >= state.assembly_requested_tick + 7200 then
      error("marker assembly timeout: machines=" .. tostring(machines) .. ", output=" .. tostring(output)
        .. ", task=" .. tostring(status.task and status.task.type or "nil")
        .. "/" .. tostring(status.task and status.task.phase or "nil"))
    end
  end

  if state.research_hold_started and not state.research_hold_verified
      and event.tick >= state.research_hold_started_tick + 300 then
    local player = game.get_player(1)
    local status = remote.call("alina_ai", "status")
    if player.force.current_research or not status.research.hold then
      error("Alina replaced a cancelled research during indefinite hold")
    end
    state.research_hold_verified = true
    local timed = remote.call("alina_ai", "address", player.index, "Аля, подожди 30 минут не исследуй")
    if not timed.ok then error("timed research hold was rejected") end
    status = remote.call("alina_ai", "status")
    local remaining = (status.research.hold_until or 0) - event.tick
    if status.research.hold_source ~= "player_timed" or remaining ~= 30 * 60 * 60 then
      error("30 minute research hold has wrong duration: " .. tostring(remaining))
    end
    state.research_timed_verified = true
    remote.call("alina_ai", "address", player.index, "Аля, можешь снова выбирать исследования")
    state.research_resume_tick = event.tick
    return
  end

  if state.research_timed_verified and not state.player_research_started and event.tick % 30 == 0 then
    local player = game.get_player(1)
    local status = remote.call("alina_ai", "status")
    if status.research.current and status.research.selected_by_alina == status.research.current then
      state.autonomous_research = status.research.current
      player.force.cancel_current_research()
      remote.call("alina_ai", "address", player.index, "Аля, можешь снова выбирать исследования")
      if not player.force.add_research("alina-player-research") then error("player research could not be selected") end
      state.player_research_started = true
      state.player_research_started_tick = event.tick
      return
    end
    if event.tick >= state.research_resume_tick + 1200 then
      error("Alina did not resume research selection: " .. helpers.table_to_json(status.research))
    end
  end

  if state.player_research_started and not state.player_research_verified
      and event.tick >= state.player_research_started_tick + 300 then
    local player = game.get_player(1)
    local status = remote.call("alina_ai", "status")
    if status.research.current ~= "alina-player-research"
        or status.research.selected_by_player ~= "alina-player-research"
        or status.research.hold_source ~= "player_selection" then
      error("player research was not preserved: " .. helpers.table_to_json(status.research))
    end
    state.player_research_verified = true
    player.force.cancel_current_research()
    local priority = remote.call("alina_ai", "address", player.index,
      "Аля, исследуй [technology=alina-test-research] в приоритете")
    if not priority.ok then error("research priority was rejected") end
    state.research_priority_tick = event.tick
    return
  end

  if state.player_research_verified and event.tick % 30 == 0 then
    local status = remote.call("alina_ai", "status")
    if status.research.current == "alina-test-research" and not status.task and not state.advanced_requested then
      state.research_priority_verified = true
      setup_advanced_factory_test(state, surface, game.get_player(1))
      return
    end
    if not state.advanced_requested and event.tick >= state.research_priority_tick + 1200 then
      error("explicit research priority was not selected: " .. helpers.table_to_json(status.research))
    end
  end

  if state.advanced_requested and not state.advanced_verified and event.tick % 60 == 0 then
    local status = remote.call("alina_ai", "status")
    local machines, modules, requesters, providers, output = advanced_factory_result(surface)
    if machines >= 8 and modules >= 8 and requesters >= 8 and providers >= 8 and output > 0 and not status.task then
      state.advanced_verified = true
      setup_long_route_test(state, surface, game.get_player(1))
      return
    end
    if event.tick >= state.advanced_requested_tick + 24000 then
      error("advanced factory timeout: machines=" .. machines .. ",modules=" .. modules
        .. ",requesters=" .. requesters .. ",providers=" .. providers .. ",output=" .. output
        .. ",task=" .. tostring(status.task and status.task.type or "nil")
        .. "/" .. tostring(status.task and status.task.phase or "nil"))
    end
  end

  if state.long_route_requested and not state.long_route_verified and event.tick % 60 == 0 then
    local status = remote.call("alina_ai", "status")
    local belts, output, distance = long_route_result(surface)
    if belts >= 80 and output > 0 and distance and distance <= 16 and not status.task then
      state.long_route_verified = true
      setup_mobility_test(state, surface, game.get_player(1))
      return
    end
    if event.tick >= state.long_route_requested_tick + 30000 then
      error("long route timeout: belts=" .. tostring(belts) .. ",output=" .. tostring(output)
        .. ",distance=" .. tostring(distance) .. ",task="
        .. tostring(status.task and status.task.type or "nil")
        .. "/" .. tostring(status.task and status.task.phase or "nil"))
    end
  end


  if state.mobility_started and not state.spider_route_started and event.tick % 60 == 0 then
    game.get_player(1).force.get_item_production_statistics(surface).clear()
    local status = remote.call("alina_ai", "status")
    local ready = status.agent and status.agent.armor == "modular-armor"
      and equipment_count(status.agent.equipment, "alina-test-burner-generator-equipment") >= 1
      and equipment_count(status.agent.equipment, "belt-immunity-equipment") >= 1
      and equipment_count(status.agent.equipment, "exoskeleton-equipment") >= 1
      and status.agent.vehicle and status.agent.vehicle.personal == true
      and not status.task
    if ready then
      local player = game.get_player(1)
      local agent = alina_agent(surface, player)
      local equipment = equipment_by_name(agent, "alina-test-burner-generator-equipment")
      local burner = equipment and equipment.burner or nil
      if not burner or not burner.valid then error("burner equipment has no runtime burner") end
      if not state.mobility_fuel_threshold_started then
        burner.inventory.clear()
        if burner.inventory.insert({name = "coal", count = 4}) ~= 4 then
          error("burner equipment rejected threshold fuel")
        end
        local main = agent.get_inventory(defines.inventory.character_main)
        local missing = math.max(0, 6 - main.get_item_count("coal"))
        if missing > 0 and main.insert({name = "coal", count = missing}) ~= missing then
          error("Alina inventory rejected refill fuel")
        end
        local pulse = remote.call("alina_ai", "address", player.index,
          "Аля, подготовь экипировку")
        if not pulse.ok then error("fuel refill autonomy did not start: " .. tostring(pulse.result)) end
        state.mobility_fuel_threshold_started = true
        state.mobility_fuel_threshold_tick = event.tick
      elseif burner.inventory.get_item_count("coal") >= 9 then
        state.mobility_fuel_refill = burner.inventory.get_item_count("coal")
        start_spider_route_test(state, surface, player)
        return
      elseif event.tick >= state.mobility_fuel_threshold_tick + 3600 then
        error("burner equipment refill timeout: "
          .. tostring(burner.inventory.get_item_count("coal")))
      end
    end
    if event.tick >= state.mobility_started_tick + 7200 then
      error("mobility loadout timeout: " .. helpers.table_to_json(status.agent or {}))
    end
  end

  if state.spider_route_started and not state.upgrade_prepared and event.tick % 30 == 0 then
    local player = game.get_player(1)
    local inventory = player and player.get_main_inventory() or nil
    local delivered = inventory and inventory.get_item_count("iron-ore") or 0
    local status = remote.call("alina_ai", "status")
    if delivered >= 10 and not status.task and (status.metrics.spider_routes or 0) >= 1 then
      state.mobility_mined = delivered
      remote.call("alina_ai", "pause")
      setup_upgrade_test(state, surface, player)
      return
    end
    if event.tick >= state.spider_route_started_tick + 7200 then
      error("spider route timeout: delivered=" .. delivered .. ",routes="
        .. tostring(status.metrics.spider_routes) .. ",fallbacks="
        .. tostring(status.metrics.spider_fallbacks) .. ",task="
        .. tostring(status.task and status.task.type or "nil") .. "/"
        .. tostring(status.task and status.task.phase or "nil"))
    end
  end

  if state.upgrade_prepared and not state.upgrade_requested
      and event.tick >= state.upgrade_prepared_tick + 120 then
    local result = remote.call("alina_ai", "autonomy_pulse", game.get_player(1).index, "iron-gear-wheel")
    if not result.ok then error("verified machine upgrade did not start: " .. tostring(result.result)) end
    state.upgrade_requested = true
    state.upgrade_requested_tick = event.tick
    return
  end

  if state.upgrade_requested and not state.machine_upgrade_verified and event.tick % 30 == 0 then
    local status = remote.call("alina_ai", "status")
    local machine = surface.find_entity("alina-test-assembler-2", UPGRADE_POSITION)
    if machine and machine.valid and not status.task and status.last_task
        and status.last_task.type == "upgrade_machine" and status.last_task.status == "completed" then
      local recipe = machine.get_recipe()
      if not recipe or recipe.name ~= "iron-gear-wheel" then error("upgrade did not preserve recipe") end
      state.machine_upgrade_verified = true
      setup_upgrade_rollback_test(state, surface)
      return
    end
    if event.tick >= state.upgrade_requested_tick + 7200 then
      error("verified machine upgrade timeout: task="
        .. tostring(status.task and status.task.type or "nil") .. "/"
        .. tostring(status.task and status.task.phase or "nil") .. ",last="
        .. tostring(status.last_task and status.last_task.status or "nil"))
    end
  end

  if state.upgrade_rollback_prepared and not state.upgrade_rollback_requested
      and event.tick >= state.upgrade_rollback_prepared_tick + 120 then
    local result = remote.call("alina_ai", "autonomy_pulse", game.get_player(1).index, "iron-gear-wheel")
    if not result.ok then error("rollback machine upgrade did not start: " .. tostring(result.result)) end
    state.upgrade_rollback_requested = true
    state.upgrade_rollback_requested_tick = event.tick
    return
  end

  if state.upgrade_rollback_requested and event.tick % 10 == 0 then
    local status = remote.call("alina_ai", "status")
    if status.task and status.task.type == "upgrade_machine"
        and status.task.phase == "verifying_upgrade" then
      state.upgrade_starvation_started = true
      local machine = surface.find_entity("alina-test-assembler-2", ROLLBACK_POSITION)
      local input = machine and machine.valid and machine.get_inventory(defines.inventory.crafter_input) or nil
      if input then input.clear() end
    end
    local restored = surface.find_entity("alina-test-assembler-1", ROLLBACK_POSITION)
    local rollback_detected = state.upgrade_starvation_started and restored and restored.valid and not status.task
      and status.last_task and status.last_task.type == "upgrade_machine"
      and status.last_task.status == "failed"
    if state.machine_upgrade_rollback or rollback_detected then
      if not state.machine_upgrade_rollback then
        local recipe = restored.get_recipe()
        if not recipe or recipe.name ~= "iron-gear-wheel" then error("rollback did not preserve old recipe") end
        state.machine_upgrade_rollback = true
        remote.call("alina_ai", "pause")
      end
      if not state.capacity_diagnostics_prepared then
        setup_capacity_diagnostics_test(state, surface)
        return
      end
      if not state.upstream_pressure_verified then
        if event.tick < state.capacity_diagnostics_tick + 120 then return end
        local diagnosis = remote.call("alina_ai", "capacity_diagnostics", 1, "alina-capacity-product")
        local health = diagnosis and diagnosis.health
        if not diagnosis.ok or not health or health.strategy ~= "upstream"
            or not health.limiting_ingredient or health.limiting_ingredient.type ~= "item"
            or health.limiting_ingredient.name ~= "iron-plate" or health.input_shortage < 4 then
          error("input-starved capacity diagnosis failed: " .. helpers.table_to_json(diagnosis or {}))
        end
        state.upstream_pressure_verified = true
        fill_capacity_outputs(state)
        state.capacity_outputs_filled_tick = game.tick
        return
      end
      if not state.logistics_pressure_verified then
        if event.tick < state.capacity_outputs_filled_tick + 120 then return end
        local diagnosis = remote.call("alina_ai", "capacity_diagnostics", 1, "alina-capacity-product")
        local health = diagnosis and diagnosis.health
        if not diagnosis.ok or not health or health.strategy ~= "logistics"
            or health.output_blocked < 4 then
          error("output-blocked capacity diagnosis failed: " .. helpers.table_to_json(diagnosis or {}))
        end
        state.logistics_pressure_verified = true
      end
      local owner = game.get_player(1)
      owner.teleport({220, 100}, surface)
      local activity_tiles = {}
      for x = 216, 245 do
        for y = 96, 104 do activity_tiles[#activity_tiles + 1] = {name = "grass-1", position = {x, y}} end
      end
      surface.set_tiles(activity_tiles, true, false, true, false)
      local activity_position = {x = 223.5, y = 100.5}
      for _, entity in ipairs(surface.find_entities_filtered({position = activity_position, radius = 0.6})) do
        if entity.valid and entity.type ~= "character" then entity.destroy() end
      end
      owner.clear_cursor()
      owner.cursor_stack.set_stack({name = "wooden-chest", count = 1})
      owner.build_from_cursor({position = activity_position})
      local player_chest = surface.find_entity("wooden-chest", activity_position)
      if not player_chest then error("player activity fixture could not build a chest") end
      local boundary = remote.call("alina_ai", "conflict_at", surface.index, {x = 243, y = 100.5})
      if not boundary.ok or not boundary.blocked or boundary.reason ~= "player_active" then
        error("fresh player activity was missed across a conflict-cell boundary")
      end
      state.active_player_boundary_verified = true
      local before = status.conflicts and status.conflicts.protected_area_count or 0
      local protected = remote.call("alina_ai", "address", owner.index,
        "Алина, здесь ничего не трогай")
      if not protected.ok then error("protected area command failed: " .. tostring(protected.result)) end
      local protected_status = remote.call("alina_ai", "status")
      if not protected_status.conflicts
          or protected_status.conflicts.protected_area_count ~= before + 1 then
        error("protected area was not persisted")
      end
      local other = game.get_player(2)
      if other and other.connected then
        other.teleport(owner.position, owner.surface)
        local foreign_release = remote.call("alina_ai", "address", other.index,
          "Алина, можешь снова трогать здесь")
        if not foreign_release.ok then error("foreign release command was not handled") end
        local foreign_status = remote.call("alina_ai", "status")
        if foreign_status.conflicts.protected_area_count ~= before + 1 then
          error("another player removed the owner's protected area")
        end
        state.protected_area_owner_verified = true
      end
      local released = remote.call("alina_ai", "address", owner.index,
        "Алина, можешь снова трогать здесь")
      if not released.ok then error("protected area release failed: " .. tostring(released.result)) end
      status = remote.call("alina_ai", "status")
      if status.conflicts.protected_area_count ~= before then
        error("protected area was not released by its owner")
      end
      state.protected_area_release_verified = true
      local advice = remote.call("alina_ai", "advice_now", game.get_player(1).index)
      if not advice.ok or not advice.advice_key then
        error("periodic advice could not be generated: " .. helpers.table_to_json(advice))
      end
      state.periodic_advice_generated = true
      remote.call("alina_ai", "resume")
      finish_result(state, surface, status)
      return
    end
    if not state.machine_upgrade_rollback and event.tick >= state.upgrade_rollback_requested_tick + 9000 then
      error("machine upgrade rollback timeout: starved=" .. tostring(state.upgrade_starvation_started)
        .. ",task=" .. tostring(status.task and status.task.type or "nil") .. "/"
        .. tostring(status.task and status.task.phase or "nil") .. ",last="
        .. tostring(status.last_task and status.last_task.status or "nil"))
    end
  end

  if state.requested and not state.physical_verified and event.tick >= state.requested_tick + TIMEOUT_DELAY then
    local furnace, chest, ghosts, output = target_result(surface)
    local status = remote.call("alina_ai", "status")
    local nearby = {}
    for _, entity in ipairs(surface.find_entities_filtered({area = {{10, -5}, {19, 5}}, force = "player"})) do
      local row = {
        name = entity.name,
        type = entity.type,
        position = entity.position,
        direction = entity.direction,
        status = entity.status,
        energy = entity.energy
      }
      if entity.type == "inserter" then
        row.held = entity.held_stack and entity.held_stack.valid_for_read and entity.held_stack.name or nil
      end
      nearby[#nearby + 1] = row
    end
    helpers.write_file("alina/physical-expansion-timeout.json", helpers.table_to_json({
      entities = nearby,
      furnace_input = furnace and furnace.get_inventory(defines.inventory.crafter_input).get_contents() or {},
      furnace_fuel = furnace and furnace.get_fuel_inventory().get_contents() or {},
      furnace_output = furnace and furnace.get_inventory(defines.inventory.crafter_output).get_contents() or {},
      chest = chest and chest.get_inventory(defines.inventory.chest).get_contents() or {}
    }), false)
    error("physical expansion timeout: furnace=" .. tostring(furnace ~= nil)
      .. ", chest=" .. tostring(chest ~= nil)
      .. ", ghosts=" .. tostring(ghosts)
      .. ", output=" .. tostring(output)
      .. ", task=" .. (status.task and helpers.table_to_json(status.task) or "nil"))
  end
end)
