local Agent = require("scripts.agent.agent")
local Navigation = require("scripts.navigation.navigation")
local RecipeIndex = require("scripts.sensors.recipe_index")
local PrototypeIndex = require("scripts.sensors.prototype_index")
local WorldModel = require("scripts.sensors.world_model")
local EventBus = require("scripts.core.event_bus")
local TaskManager = require("scripts.tasks.manager")
local Conflict = require("scripts.conflict.manager")

local Acquisition = {}

local MAX_DEPTH = 8
local MAX_OPERATIONS = 48
local MAX_CRAFTS_PER_OPERATION = 100
local MAX_CONTAINER_SOURCES_EXAMINED = 1024
local MAX_MACHINE_SOURCES_EXAMINED = 512
local SOURCE_QUERY_LIMIT = 128
local CONTAINER_SOURCE_TYPES = {"container", "logistic-container", "linked-container"}
local MACHINE_SOURCE_TYPES = {"assembling-machine", "furnace"}

-- A chest can be filled after its build event (by a player, another mod or an
-- inserter), before the background World Model revisits that chunk. Preview
-- planning must still notice ordinary nearby stock. Cache one small live query
-- for the current simulation tick so prototype ranking never turns this into a
-- per-candidate surface scan on a megabase.
local preview_source_cache = nil

local function nearby_preview_sources(agent)
  local chunk_x = math.floor(agent.position.x / 32)
  local chunk_y = math.floor(agent.position.y / 32)
  if preview_source_cache and preview_source_cache.tick == game.tick
      and preview_source_cache.surface_index == agent.surface.index
      and preview_source_cache.force_index == agent.force.index
      and preview_source_cache.chunk_x == chunk_x and preview_source_cache.chunk_y == chunk_y then
    return preview_source_cache.entities
  end
  local entities = agent.surface.find_entities_filtered({
    position = agent.position,
    radius = 128,
    type = {"container", "logistic-container", "linked-container", "assembling-machine", "furnace"},
    force = agent.force,
    limit = 256
  })
  preview_source_cache = {
    tick = game.tick,
    surface_index = agent.surface.index,
    force_index = agent.force.index,
    chunk_x = chunk_x,
    chunk_y = chunk_y,
    entities = entities
  }
  return entities
end

local function inventory(agent)
  return agent.get_inventory(defines.inventory.character_main)
end

local function item_count(agent, item_name)
  local main = inventory(agent)
  return main and main.get_item_count(item_name) or 0
end

local function source_search_areas(position)
  local result = {}
  local previous = 0
  for _, radius in ipairs({32, 64, 128, 256, 512}) do
    if previous == 0 then
      result[#result + 1] = {{position.x - radius, position.y - radius},
        {position.x + radius, position.y + radius}}
    else
      -- Expanding square rings preserve proximity without asking Factorio for
      -- an arbitrary first 512 entities from an entire megabase.
      result[#result + 1] = {{position.x - radius, position.y - radius},
        {position.x + radius, position.y - previous}}
      result[#result + 1] = {{position.x - radius, position.y + previous},
        {position.x + radius, position.y + radius}}
      result[#result + 1] = {{position.x - radius, position.y - previous},
        {position.x - previous, position.y + previous}}
      result[#result + 1] = {{position.x + previous, position.y - previous},
        {position.x + radius, position.y + previous}}
    end
    previous = radius
  end
  return result
end

local function inventory_sources(agent, item_name, source, reserved, desired_count, options, prefer_crafting)
  local result = {}
  local seen = {}
  local usable_total = 0
  local areas = source_search_areas(agent.position)

  local function consider(entity, inventory_index)
    if not entity or not entity.valid then return end
    local entity_key = entity.unit_number or tostring(entity)
    if seen[entity_key] then return end
    seen[entity_key] = true
    local logistic_mode = entity.type == "logistic-container" and entity.prototype.logistic_mode or nil
    local production_input = logistic_mode == "requester" or logistic_mode == "buffer"
    if production_input or Conflict.is_blocked(entity.surface.index, entity.position, source) then return end
    local target_inventory = entity.get_inventory(inventory_index)
    local available = target_inventory and target_inventory.get_item_count(item_name) or 0
    -- Keep a bounded buffer without making small/rare building stocks
    -- impossible to use. With 2 upgrade machines Alina may take one; with
    -- a bulk stack of 50 she leaves 10 for the running factory/player.
    local reserve = inventory_index == defines.inventory.chest
      and math.min(10, math.floor(available * 0.2)) or 0
    local reservation_key = tostring(entity.unit_number or entity.name) .. ":"
      .. tostring(inventory_index) .. ":" .. item_name
    local usable = math.max(0, available - reserve - (reserved[reservation_key] or 0))
    if usable <= 0 then return end
    local dx = entity.position.x - agent.position.x
    local dy = entity.position.y - agent.position.y
    result[#result + 1] = {
      entity = entity,
      inventory_index = inventory_index,
      available = usable,
      position = {x = entity.position.x, y = entity.position.y},
      distance = dx * dx + dy * dy,
      reservation_key = reservation_key
    }
    usable_total = usable_total + usable
  end

  -- The background World Model stores only sparse non-empty item sources. A
  -- live inventory check below keeps the cache advisory and safe when another
  -- player or machine changed the chest since its chunk was refreshed.
  for _, entity in ipairs(WorldModel.inventory_sources(agent, item_name, agent.position, 512)) do
    local inventory_index = (entity.type == "container" or entity.type == "logistic-container"
      or entity.type == "linked-container") and defines.inventory.chest
      or defines.inventory.crafter_output
    consider(entity, inventory_index)
    if usable_total >= (desired_count or 1) then break end
  end

  if usable_total < (desired_count or 1) and options and options.preview then
    for _, entity in ipairs(nearby_preview_sources(agent)) do
      local inventory_index = (entity.type == "container" or entity.type == "logistic-container"
        or entity.type == "linked-container") and defines.inventory.chest
        or defines.inventory.crafter_output
      consider(entity, inventory_index)
      if usable_total >= (desired_count or 1) then break end
    end
  end

  local function collect(types, inventory_index, maximum_examined, maximum_areas)
    local examined = 0
    local areas_examined = 0
    for _, area in ipairs(areas) do
      areas_examined = areas_examined + 1
      local entities = agent.surface.find_entities_filtered({
        area = area,
        type = types,
        force = agent.force,
        limit = SOURCE_QUERY_LIMIT
      })
      examined = examined + #entities
      for _, entity in ipairs(entities) do
        consider(entity, inventory_index)
      end
      if usable_total >= (desired_count or 1) or examined >= maximum_examined
          or (maximum_areas and areas_examined >= maximum_areas) then return end
    end
  end

  -- Storage is both the player's preferred source and dramatically cheaper to
  -- search on a mature factory. Mixing chests with thousands of assemblers in
  -- one limited query could exhaust the result budget before reaching the
  -- supply district and then inspect hundreds of irrelevant machine outputs.
  if usable_total < (desired_count or 1) and not (options and options.preview) then
    -- For a hand-craftable item, consult the complete indexed factory and a
    -- nearby live fallback first, then craft from stocked ingredients. Scanning
    -- every chest and machine across a megabase for an absent finished chest or
    -- pole caused 100-150 ms acquisition spikes. Non-craftable/rare items retain
    -- the full live search.
    collect(CONTAINER_SOURCE_TYPES, defines.inventory.chest,
      MAX_CONTAINER_SOURCES_EXAMINED, prefer_crafting and 5 or nil)
  end
  if usable_total < (desired_count or 1) and not (options and options.preview) and not prefer_crafting then
    collect(MACHINE_SOURCE_TYPES, defines.inventory.crafter_output, MAX_MACHINE_SOURCES_EXAMINED)
  end
  table.sort(result, function(a, b)
    if a.distance == b.distance then return a.reservation_key < b.reservation_key end
    return a.distance < b.distance
  end)
  return result
end

local function expected_product_amount(product)
  local amount = product.amount
  if not amount and product.amount_min and product.amount_max then
    amount = (product.amount_min + product.amount_max) / 2
  end
  return (amount or 1) * (product.probability or 1)
end

local function recipe_output(recipe, item_name)
  for _, product in ipairs(recipe.products or {}) do
    if product.type == "item" and product.name == item_name then
      return expected_product_amount(product)
    end
  end
  return 0
end

local function character_supports(agent, recipe)
  if not recipe.enabled or recipe.hidden_from_player_crafting then return false end
  local categories = agent.prototype.crafting_categories or {}
  local category_supported = false
  for _, category in ipairs(recipe.categories or {}) do
    if categories[category] then category_supported = true; break end
  end
  if not category_supported then return false end
  for _, ingredient in ipairs(recipe.ingredients or {}) do
    if ingredient.type ~= "item" or not ingredient.amount then return false end
  end
  return true
end

local function select_character_recipe(agent, item_name)
  local candidates = RecipeIndex.find_producers(item_name, agent.force, 64) or {}
  local best = nil
  local best_score = nil
  for _, recipe in ipairs(candidates) do
    local output = recipe_output(recipe, item_name)
    if output > 0 and character_supports(agent, recipe) then
      local ingredient_total = 0
      for _, ingredient in ipairs(recipe.ingredients or {}) do ingredient_total = ingredient_total + ingredient.amount end
      local score = (recipe.name == item_name and 0 or 100000)
        + ingredient_total * 100 + (recipe.energy or 0)
      if not best_score or score < best_score then best = recipe; best_score = score end
    end
  end
  return best
end

local function idle_machine_for(agent, recipe, source)
  local best = nil
  local best_distance = nil
  local diagnostics = {seen = 0, supported = 0, empty = 0, unassigned = 0, isolated = 0, covered = 0}
  local entities = agent.surface.find_entities_filtered({
    position = agent.position,
    radius = 512,
    type = {"assembling-machine", "furnace"},
    force = agent.force,
    limit = 512
  })
  -- Build the occupancy index once. The old implementation performed two
  -- spatial queries for every one of up to 512 machines and caused a 14-second
  -- update spike on a dense factory whenever a missing item needed automatic
  -- crafting. Inserters already expose their actual pickup/drop targets.
  local connected = {}
  for _, inserter in ipairs(agent.surface.find_entities_filtered({
      position = agent.position,
      radius = 520,
      type = "inserter",
      force = agent.force,
      limit = 4096
    })) do
    local pickup, drop = inserter.pickup_target, inserter.drop_target
    if pickup and pickup.valid and pickup.unit_number then connected[pickup.unit_number] = true end
    if drop and drop.valid and drop.unit_number then connected[drop.unit_number] = true end
  end
  for _, entity in ipairs(entities) do
    diagnostics.seen = diagnostics.seen + 1
    local categories = entity.prototype.crafting_categories or {}
    local supported = false
    for _, category in ipairs(recipe.categories or {}) do
      if categories[category] then supported = true; break end
    end
    local input = entity.get_inventory(defines.inventory.crafter_input)
    local output = entity.get_inventory(defines.inventory.crafter_output)
    local current = entity.get_recipe()
    local covered = entity.is_connected_to_electric_network()
    if supported then diagnostics.supported = diagnostics.supported + 1 end
    if input and output and input.is_empty() and output.is_empty() then diagnostics.empty = diagnostics.empty + 1 end
    local unassigned = not current
    local isolated = not connected[entity.unit_number]
    if unassigned then diagnostics.unassigned = diagnostics.unassigned + 1 end
    if isolated then diagnostics.isolated = diagnostics.isolated + 1 end
    if covered then diagnostics.covered = diagnostics.covered + 1 end
    if supported and input and output and input.is_empty() and output.is_empty()
        and unassigned and isolated and covered
        and not Conflict.is_blocked(entity.surface.index, entity.position, source) then
      local dx = entity.position.x - agent.position.x
      local dy = entity.position.y - agent.position.y
      local candidate_distance = dx * dx + dy * dy
      if not best_distance or candidate_distance < best_distance then
        best = entity
        best_distance = candidate_distance
      end
    end
  end
  return best, diagnostics
end

local function select_machine_recipe(agent, item_name, source)
  local candidates = RecipeIndex.find_producers(item_name, agent.force, 64) or {}
  local best_recipe = nil
  local best_machine = nil
  local best_score = nil
  local diagnostic = {recipes = #candidates, eligible = 0, seen = 0, supported = 0, empty = 0,
    unassigned = 0, isolated = 0, covered = 0}
  for _, recipe in ipairs(candidates) do
    local output = recipe_output(recipe, item_name)
    local ingredients_supported = recipe.enabled and output > 0
    for _, ingredient in ipairs(recipe.ingredients or {}) do
      if ingredient.type ~= "item" or not ingredient.amount then ingredients_supported = false; break end
    end
    if ingredients_supported then
      diagnostic.eligible = diagnostic.eligible + 1
      local machine, machine_diagnostic = idle_machine_for(agent, recipe, source)
      for key, value in pairs(machine_diagnostic) do diagnostic[key] = math.max(diagnostic[key] or 0, value) end
      if machine then
        local ingredient_total = 0
        for _, ingredient in ipairs(recipe.ingredients) do ingredient_total = ingredient_total + ingredient.amount end
        local score = ingredient_total * 100 + (recipe.energy or 0)
        if not best_score or score < best_score then
          best_recipe = recipe
          best_machine = machine
          best_score = score
        end
      end
    end
  end
  local reason = "machine recipes=" .. diagnostic.recipes .. ",eligible=" .. diagnostic.eligible
    .. ",seen=" .. diagnostic.seen .. ",supported=" .. diagnostic.supported
    .. ",empty=" .. diagnostic.empty .. ",unassigned=" .. diagnostic.unassigned
    .. ",isolated=" .. diagnostic.isolated .. ",covered=" .. diagnostic.covered
  return best_recipe, best_machine, reason
end

local function make_plan(agent, item_name, count, source, options)
  if not RecipeIndex.is_ready() or not PrototypeIndex.is_ready() then
    return nil, "Индекс прототипов ещё строится."
  end
  local main = inventory(agent)
  if not main then return nil, "У Алины нет основного инвентаря." end
  local operations = {}
  local virtual = {}
  local visiting = {}
  local reserved_sources = {}

  local function stock(name)
    if virtual[name] == nil then virtual[name] = main.get_item_count(name) end
    return virtual[name]
  end

  local function add_operation(operation)
    if #operations >= MAX_OPERATIONS then return false, "Цепочка получения слишком длинная." end
    operations[#operations + 1] = operation
    return true
  end

  local function plan_item(name, required, depth)
    if stock(name) >= required then return true end
    if depth > MAX_DEPTH then return false, "Цепочка рецептов глубже безопасного предела." end
    if visiting[name] then return false, "В рецептах обнаружен цикл через " .. name .. "." end
    visiting[name] = true

    local missing = required - stock(name)
    local character_recipe = select_character_recipe(agent, name)
    for _, source_inventory in ipairs(
        inventory_sources(agent, name, source, reserved_sources, missing, options, character_recipe ~= nil)) do
      if missing <= 0 then break end
      local take_count = math.min(math.ceil(missing), source_inventory.available)
      local ok, error_message = add_operation({
        type = "take",
        item = name,
        count = take_count,
        entity = source_inventory.entity,
        inventory_index = source_inventory.inventory_index,
        position = source_inventory.position
      })
      if not ok then visiting[name] = nil; return false, error_message end
      reserved_sources[source_inventory.reservation_key] =
        (reserved_sources[source_inventory.reservation_key] or 0) + take_count
      virtual[name] = stock(name) + take_count
      if virtual[name] >= required then visiting[name] = nil; return true end
      missing = required - virtual[name]
    end

    -- Speculative layout selection runs inside one simulation tick. It may use
    -- the already indexed factory and deterministic recipe graph, but must not
    -- rescan a 1024x1024 live surface or inspect hundreds of idle machines for
    -- every rejected mod prototype. Execution performs the authoritative full
    -- acquisition search again before placing anything.
    local mineable = not (options and options.preview)
      and PrototypeIndex.find_resource(agent, name, source, 512) or nil
    if mineable then
      local ok, error_message = add_operation({type = "mine", item = name, count = math.ceil(missing)})
      if not ok then visiting[name] = nil; return false, error_message end
      virtual[name] = stock(name) + math.ceil(missing)
      visiting[name] = nil
      return true
    end

    local recipe = character_recipe
    local machine = nil
    local machine_error = nil
    if recipe then
      local output = recipe_output(recipe, name)
      local estimated_crafts = math.ceil(missing / math.max(output, 0.001))
      -- Small hand crafts must not scan a megabase for an idle assembler. Only
      -- pay for machine selection when automation would materially save time.
      if not (options and options.preview)
          and (estimated_crafts >= 20 or estimated_crafts * (recipe.energy or 0.5) >= 30) then
        local machine_recipe, available_machine, selection_error =
          select_machine_recipe(agent, name, source)
        machine_error = selection_error
        if available_machine and machine_recipe and machine_recipe.name == recipe.name then
          recipe = machine_recipe
          machine = available_machine
        end
      end
    elseif not (options and options.preview) then
      local machine_recipe, available_machine, selection_error =
        select_machine_recipe(agent, name, source)
      machine_error = selection_error
      if machine_recipe then
        recipe = machine_recipe
        machine = available_machine
      end
    end
    if not recipe then
      visiting[name] = nil
      return false, "Нет доступного ручного рецепта или месторождения для " .. name .. ". " .. (machine_error or "")
    end
    local output = recipe_output(recipe, name)
    local crafts = math.ceil(missing / output)
    if crafts < 1 or crafts > MAX_CRAFTS_PER_OPERATION then
      visiting[name] = nil
      return false, "Количество крафтов для " .. name .. " вне безопасного предела."
    end

    for _, ingredient in ipairs(recipe.ingredients) do
      local needed = ingredient.amount * crafts
      local ok, error_message = plan_item(ingredient.name, needed, depth + 1)
      if not ok then visiting[name] = nil; return false, error_message end
      virtual[ingredient.name] = stock(ingredient.name) - needed
    end
    local ok, error_message = add_operation({
      type = machine and "machine" or "craft",
      recipe = recipe.name,
      crafts = crafts,
      item = name,
      output_count = math.floor(output * crafts + 0.5),
      energy = recipe.energy or 0.5,
      ingredients = recipe.ingredients,
      entity = machine,
      position = machine and {x = machine.position.x, y = machine.position.y} or nil
    })
    if not ok then visiting[name] = nil; return false, error_message end
    virtual[name] = stock(name) + output * crafts
    visiting[name] = nil
    return true
  end

  local ok, error_message = plan_item(item_name, count, 0)
  if not ok then return nil, error_message end
  return {item = item_name, count = count, operations = operations, index = 1, status = "working"}
end

function Acquisition.make_plan(agent, item_name, count, source, options)
  return make_plan(agent, item_name, count, source, options)
end

function Acquisition.start(task, agent, item_name, count)
  local plan, error_message = make_plan(agent, item_name, count, task.source)
  if not plan then return false, error_message end
  task.acquisition = plan
  task.phase = "acquiring_items"
  EventBus.emit("acquisition_planned", {
    task_id = task.id,
    item = item_name,
    count = count,
    operations = #plan.operations
  })
  return true
end

local function advance(task, operation, agent)
  local acquisition = task.acquisition
  EventBus.emit("acquisition_operation_finished", {
    task_id = task.id,
    operation = operation.type,
    item = operation.item,
    count = operation.count or operation.output_count,
    held_after = agent and item_count(agent, operation.item) or nil
  })
  acquisition.index = acquisition.index + 1
  task.navigation = nil
end

local function fail(message)
  Agent.stop()
  TaskManager.fail(message)
  return "failed"
end

local function start_mining(task, agent, operation)
  local target = PrototypeIndex.find_resource(agent, operation.item, task.source, 512)
  if not target then return false, "Не нашла доступный ресурс для " .. operation.item .. "." end
  operation.target = target
  local current_count = item_count(agent, operation.item)
  -- A mine operation may need several finite entities (trees, rocks or tiny
  -- modded resource nodes). Keep one absolute target across retargets. Resetting
  -- it to current + requested on every depleted entity makes the goal recede
  -- forever and sends the character from tree to tree indefinitely.
  if operation.start_count == nil then
    operation.start_count = math.max(0, (operation.target_count or current_count + operation.count) - operation.count)
  end
  operation.target_count = operation.start_count + operation.count
  operation.last_count = current_count
  operation.last_progress_tick = game.tick
  operation.state = "pathing"
  Navigation.start(task, agent, target.position, math.max(0.5, agent.resource_reach_distance - 0.5), "acquire_resource")
  EventBus.emit("acquisition_operation_started", {
    task_id = task.id,
    operation = "mine",
    item = operation.item,
    count = operation.count,
    resource = target.name
  })
  return true
end

local function tick_take(task, agent, operation)
  local entity = operation.entity
  if not entity or not entity.valid then return fail("Источник " .. operation.item .. " исчез.") end
  if not operation.state then
    operation.state = "pathing"
    Navigation.start(task, agent, entity.position, math.max(1, agent.reach_distance - 0.5), "acquire_inventory")
    EventBus.emit("acquisition_operation_started", {
      task_id = task.id,
      operation = "take",
      item = operation.item,
      count = operation.count,
      source_entity = entity.name
    })
    return "working"
  end
  if operation.state == "pathing" and not Navigation.tick(task, agent) then return "working" end
  local inventory = entity.get_inventory(operation.inventory_index)
  if not inventory then return fail("Инвентарь источника " .. entity.name .. " недоступен.") end
  local removed = inventory.remove({name = operation.item, count = operation.count})
  local inserted = agent.insert({name = operation.item, count = removed})
  if inserted < removed then inventory.insert({name = operation.item, count = removed - inserted}) end
  if inserted ~= operation.count then return fail("Источник отдал только " .. inserted .. " × " .. operation.item .. ".") end
  advance(task, operation, agent)
  return "working"
end

local function tick_mining(task, agent, operation)
  if not operation.state then
    local ok, error_message = start_mining(task, agent, operation)
    if not ok then return fail(error_message) end
  end
  if item_count(agent, operation.item) >= operation.target_count then
    Agent.stop()
    advance(task, operation, agent)
    return "working"
  end
  if not operation.target or not operation.target.valid
      or (operation.target.type == "resource" and (not operation.target.amount or operation.target.amount <= 0)) then
    task.navigation = nil
    operation.state = nil
    return "working"
  end
  if operation.state == "pathing" then
    if Navigation.tick(task, agent) then
      operation.state = "mining"
      operation.last_progress_tick = game.tick
    end
    return "working"
  end

  local dx = operation.target.position.x - agent.position.x
  local dy = operation.target.position.y - agent.position.y
  if dx * dx + dy * dy > agent.resource_reach_distance * agent.resource_reach_distance then
    operation.state = "pathing"
    Navigation.start(task, agent, operation.target.position,
      math.max(0.5, agent.resource_reach_distance - 0.5), "acquire_resource")
    return "working"
  end
  agent.walking_state = {walking = false, direction = defines.direction.north}
  agent.selected = operation.target
  agent.mining_state = {mining = true, position = operation.target.position}
  local count = item_count(agent, operation.item)
  if count > operation.last_count then
    operation.last_count = count
    operation.last_progress_tick = game.tick
  elseif game.tick - operation.last_progress_tick > 900 then
    return fail("Получение " .. operation.item .. " не продвигается.")
  end
  return "working"
end

local function tick_crafting(task, agent, operation)
  if not operation.state then
    Agent.stop()
    operation.target_count = item_count(agent, operation.item) + operation.output_count
    local started = agent.begin_crafting({count = operation.crafts, recipe = operation.recipe, silent = true})
    if started ~= operation.crafts then
      return fail("Не удалось начать нужное количество крафтов " .. operation.recipe .. ".")
    end
    operation.state = "crafting"
    operation.started_tick = game.tick
    EventBus.emit("acquisition_operation_started", {
      task_id = task.id,
      operation = "craft",
      item = operation.item,
      recipe = operation.recipe,
      crafts = operation.crafts
    })
    return "working"
  end
  if item_count(agent, operation.item) >= operation.target_count then
    advance(task, operation, agent)
    return "working"
  end
  local timeout = math.max(600, math.ceil(operation.energy * operation.crafts * 180 + 600))
  if game.tick - operation.started_tick > timeout then
    return fail("Ручной крафт " .. operation.recipe .. " не завершился вовремя.")
  end
  local queue = agent.crafting_queue
  if game.tick > operation.started_tick + 1 and (not queue or #queue == 0) then
    return fail("Ручной крафт " .. operation.recipe .. " завершился без ожидаемого предмета.")
  end
  return "working"
end

local function tick_machine(task, agent, operation)
  local entity = operation.entity
  if not entity or not entity.valid then return fail("Свободная производственная машина исчезла.") end
  if not operation.state then
    operation.state = "pathing"
    Navigation.start(task, agent, entity.position, math.max(1, agent.reach_distance - 0.5), "acquire_machine")
    EventBus.emit("acquisition_operation_started", {
      task_id = task.id,
      operation = "machine",
      item = operation.item,
      recipe = operation.recipe,
      crafts = operation.crafts,
      source_entity = entity.name
    })
    return "working"
  end
  if operation.state == "pathing" then
    if not Navigation.tick(task, agent) then return "working" end
    local input = entity.get_inventory(defines.inventory.crafter_input)
    local output = entity.get_inventory(defines.inventory.crafter_output)
    if not input or not output or not input.is_empty() or not output.is_empty() then
      return fail("Свободная машина была занята до начала производства.")
    end
    -- Never hijack an operating production cell. LuaEntity.active is read-only
    -- for inserters in Factorio 2.1, and changing their circuit conditions would
    -- also overwrite player intent. Machine-assisted crafting is therefore only
    -- allowed in a still-empty, unassigned machine with no connected inserters.
    if has_connected_inserter(entity) then
      return fail("Свободную машину успели подключить к линии; существующее производство не трогаю.")
    end
    if entity.type == "assembling-machine" then
      local selected = entity.get_recipe()
      if selected then return fail("Свободной машине уже назначили рецепт; существующее производство не трогаю.") end
      operation.original_recipe_name = false
      entity.set_recipe(operation.recipe)
      operation.temporary_recipe_set = true
      selected = entity.get_recipe()
      if not selected or selected.name ~= operation.recipe then
        return fail("Машина не приняла рецепт " .. operation.recipe .. ".")
      end
    end
    for _, ingredient in ipairs(operation.ingredients or {}) do
      local required = math.ceil(ingredient.amount * operation.crafts)
      local removed = agent.remove_item({name = ingredient.name, count = required})
      local inserted = input.insert({name = ingredient.name, count = removed})
      if inserted < removed then agent.insert({name = ingredient.name, count = removed - inserted}) end
      if inserted ~= required then return fail("Не удалось загрузить " .. ingredient.name .. " в " .. entity.name .. ".") end
    end
    operation.baseline_output = output.get_item_count(operation.item)
    operation.state = "producing"
    operation.started_tick = game.tick
    task.navigation = nil
    return "working"
  end
  local output = entity.get_inventory(defines.inventory.crafter_output)
  local available = output and output.get_item_count(operation.item) or 0
  if available >= operation.baseline_output + operation.output_count then
    local removed = output.remove({name = operation.item, count = operation.output_count})
    local inserted = agent.insert({name = operation.item, count = removed})
    if inserted < removed then output.insert({name = operation.item, count = removed - inserted}) end
    if inserted ~= operation.output_count then return fail("Не смогла забрать выпуск " .. operation.item .. ".") end
    if operation.temporary_recipe_set and entity.type == "assembling-machine" then
      local current = entity.get_recipe()
      if current and current.name == operation.recipe then entity.set_recipe(nil) end
    end
    operation.temporary_recipe_set = nil
    advance(task, operation, agent)
    return "working"
  end
  local timeout = math.max(1800, math.ceil(operation.energy * operation.crafts * 600 + 1800))
  if game.tick - operation.started_tick > timeout then
    return fail("Существующая машина не выпустила " .. operation.item .. " вовремя.")
  end
  return "working"
end

function Acquisition.tick(task, agent)
  local acquisition = task.acquisition
  if not acquisition then return "failed" end
  if acquisition.index > #acquisition.operations then
    if item_count(agent, acquisition.item) < acquisition.count then
      return fail("После получения не хватает " .. acquisition.item .. ".")
    end
    acquisition.status = "completed"
    return "done"
  end
  local operation = acquisition.operations[acquisition.index]
  if operation.type == "take" then return tick_take(task, agent, operation) end
  if operation.type == "mine" then return tick_mining(task, agent, operation) end
  if operation.type == "craft" then return tick_crafting(task, agent, operation) end
  if operation.type == "machine" then return tick_machine(task, agent, operation) end
  return fail("Неизвестная операция получения предметов.")
end

return Acquisition
