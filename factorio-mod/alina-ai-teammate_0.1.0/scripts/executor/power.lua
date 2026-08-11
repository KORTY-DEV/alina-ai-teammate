local State = require("scripts.core.state")
local Agent = require("scripts.agent.agent")
local TaskManager = require("scripts.tasks.manager")
local Conflict = require("scripts.conflict.manager")
local EventBus = require("scripts.core.event_bus")
local Navigation = require("scripts.navigation.navigation")
local Acquisition = require("scripts.executor.acquisition")
local PrototypeIndex = require("scripts.sensors.prototype_index")
local RecipeIndex = require("scripts.sensors.recipe_index")
local WorldModel = require("scripts.sensors.world_model")

local Power = {}
local POLE_CARRY_RESERVE = 2

local function distance(a, b)
  local dx = a.x - b.x
  local dy = a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

local function covered(position, nodes)
  for _, node in ipairs(nodes) do
    local supply = node.supply or 0
    if math.abs(position.x - node.position.x) <= supply
        and math.abs(position.y - node.position.y) <= supply then
      return true
    end
  end
  return false
end

local function find_targets(task, player)
  if task.target_unit_number then
    local entity = game.get_entity_by_unit_number(task.target_unit_number)
    if (not entity or not entity.valid) and task.target_surface_index and task.target_position then
      local surface = game.surfaces[task.target_surface_index]
      local candidates = surface and surface.find_entities_filtered({
        position = task.target_position, radius = 0.22, name = task.target_entity, limit = 4}) or {}
      entity = candidates[1]
    end
    local blocked = entity and entity.valid
      and Conflict.is_blocked(entity.surface.index, entity.position, task.source)
    if entity and entity.valid and entity.surface.index == player.surface.index
        and entity.force.index == player.force.index
        and entity.name == task.target_entity
        and (entity.status == defines.entity_status.no_power
          or entity.status == defines.entity_status.low_power
          or entity.status == defines.entity_status.not_plugged_in_electric_network)
        and not blocked then
      return {entity}
    end
    return {}
  end
  local entities = WorldModel.entities_by_type(player, {"assembling-machine", "furnace", "mining-drill", "lab"}, 768)
  local targets = {}
  for _, entity in ipairs(entities) do
    local blocked = Conflict.is_blocked(entity.surface.index, entity.position, task.source)
    if entity.valid and entity.name == task.target_entity
        and (entity.status == defines.entity_status.no_power
          or entity.status == defines.entity_status.low_power
          or entity.status == defines.entity_status.not_plugged_in_electric_network)
        and not blocked then
      targets[#targets + 1] = entity
    end
  end
  table.sort(targets, function(a, b)
    if a.position.x == b.position.x then return a.position.y < b.position.y end
    return a.position.x < b.position.x
  end)
  return targets
end

local function existing_nodes(player, position)
  local result = {}
  local poles = WorldModel.entities_by_type_near(player, {"electric-pole"}, position, 96)
  for _, pole in ipairs(poles) do
    if pole.valid and pole.electric_network_id then
      result[#result + 1] = {
        position = {x = pole.position.x, y = pole.position.y},
        wire = pole.prototype.get_max_wire_distance(),
        supply = pole.prototype.get_supply_area_distance(),
        existing = true,
        entity = pole
      }
    end
  end
  return result
end

local function site_for(surface, pole_name, desired, source_position, max_wire, task, target_position)
  local best = nil
  local best_score = nil
  local base_x = math.floor(desired.x)
  local base_y = math.floor(desired.y)
  local function acceptable(candidate)
    return candidate
      and distance(candidate, source_position) <= max_wire
      and distance(candidate, target_position) < distance(source_position, target_position) - 0.5
      and not Conflict.is_blocked(surface.index, candidate, task.source)
      and surface.can_place_entity({
        name = pole_name, position = candidate, force = game.forces[task.force_name]
      })
  end
  -- The desired point is normally already free. Test its two legal centre grids
  -- before asking the engine for a wider collision search.
  for _, offset in ipairs({0, 0.5}) do
    local direct = {x = base_x + offset, y = base_y + offset}
    if acceptable(direct) then return direct end
  end
  local native = surface.find_non_colliding_position(pole_name, desired, 4, 0.5, true)
  if acceptable(native) then return native end
  -- Building centres are grid aligned (integer or half-tile depending on the
  -- footprint). find_non_colliding_position may return a collision-free but
  -- non-buildable fractional point, so test both grids deterministically.
  for radius = 1, 2 do
    for dx = -radius, radius do
      for dy = -radius, radius do
        if radius == 0 or math.abs(dx) == radius or math.abs(dy) == radius then
          for _, offset in ipairs({0, 0.5}) do
            local candidate = {x = base_x + dx + offset, y = base_y + dy + offset}
            if acceptable(candidate) then
              local score = distance(candidate, target_position)
              if not best_score or score < best_score then best = candidate; best_score = score end
            end
          end
        end
      end
    end
    if best then return best end
  end
  return nil, "no_grid_aligned_site_near:" .. desired.x .. "," .. desired.y
end

local function build_route(task, player, pole, existing)
  local nodes = {}
  for _, node in ipairs(existing or {}) do nodes[#nodes + 1] = node end
  if #nodes == 0 then return nil, "Рядом нет существующей электрической сети, от которой можно безопасно продолжить линию." end
  local positions = {}
  local supply = pole.supply_area_distance or 0
  local pole_wire = pole.max_wire_distance or 0
  if supply <= 0 or pole_wire <= 0 then return nil, "Прототип столба не имеет рабочей зоны питания." end

  local pending = {}
  for _, target in ipairs(task.power_targets) do pending[#pending + 1] = target end
  while true do
    -- Grow the network from its current frontier. Sorting targets by absolute
    -- X/Y made a two-row factory alternate top/bottom on every machine and
    -- produced the visible saw-tooth route reported by players.
    local selected_index, selected_target, selected_source, selected_distance = nil, nil, nil, nil
    for index, target in ipairs(pending) do
      if not covered(target.position, nodes) then
        for _, node in ipairs(nodes) do
          local candidate_distance = distance(node.position, target.position)
          local better_tie = selected_target and candidate_distance == selected_distance
            and (target.position.x < selected_target.position.x
              or (target.position.x == selected_target.position.x
                and target.position.y < selected_target.position.y))
          if not selected_distance or candidate_distance < selected_distance or better_tie then
            selected_index, selected_target = index, target
            selected_source, selected_distance = node, candidate_distance
          end
        end
      end
    end
    if not selected_target then break end
    table.remove(pending, selected_index)
    local current = selected_source
    local guard = 0
    while not covered(selected_target.position, {current}) do
      guard = guard + 1
      if guard > 24 then return nil, "Маршрут электросети превысил безопасный предел." end
      local wire_limit = math.min(current.wire or pole_wire, pole_wire)
      local remaining = distance(current.position, selected_target.position)
      -- Use most of the real prototype wire reach. A 14% safety margin still
      -- tolerates grid snapping while avoiding needlessly dense relay poles.
      local travel = math.min(wire_limit * 0.86, math.max(1, remaining - supply * 0.75))
      local ratio = travel / math.max(remaining, 0.001)
      local desired = {
        x = current.position.x + (selected_target.position.x - current.position.x) * ratio,
        y = current.position.y + (selected_target.position.y - current.position.y) * ratio
      }
      local site, site_error = site_for(
        player.surface, pole.entity, desired, current.position, wire_limit * 0.98, task,
        selected_target.position)
      if not site then return nil, "route_site:" .. (site_error or "unknown") end
      positions[#positions + 1] = site
      current = {position = site, wire = pole_wire, supply = supply, existing = false}
      nodes[#nodes + 1] = current
    end
  end
  return positions
end

local function cheap_obtainability(agent, item_name, count)
  local main = agent.get_inventory(defines.inventory.character_main)
  if main and main.get_item_count(item_name) >= count then return 0 end
  -- Prefer a suitable pole already produced by the factory. Without this
  -- distinction every enabled high-tier recipe looked equally cheap and the
  -- planner recursively expanded several unavailable modded/late-game poles
  -- before reaching the stocked tier.
  if #WorldModel.inventory_sources(agent, item_name, agent.position, 1) > 0 then return 0 end
  for _, recipe in ipairs(RecipeIndex.find_producers(item_name, agent.force, 16) or {}) do
    if recipe.enabled then return 1 end
  end
  return 2
end

local function plan(task, agent, player)
  task.force_name = player.force.name
  task.power_targets = find_targets(task, player)
  if #task.power_targets == 0 then return false, "Потребители без питания уже не найдены." end
  local best = nil
  local rejected = {}
  -- Resolving hundreds of indexed poles is independent of the candidate pole
  -- prototype. Do it once, then give each route calculation its own shallow
  -- working copy because it appends planned relay nodes.
  local existing = existing_nodes(player,
    task.power_targets[1] and task.power_targets[1].position or player.position)
  local candidates = {}
  for _, pole in ipairs(PrototypeIndex.entities_for_type("electric-pole") or {}) do
    for _, placement in ipairs(pole.items or {}) do
      candidates[#candidates + 1] = {
        pole = pole,
        item = placement.name,
        item_count = placement.count,
        obtainability = cheap_obtainability(
          agent, placement.name, placement.count + POLE_CARRY_RESERVE)
      }
    end
  end
  table.sort(candidates, function(a, b)
    if a.obtainability ~= b.obtainability then return a.obtainability < b.obtainability end
    local a_reach = (a.pole.max_wire_distance or 0) + (a.pole.supply_area_distance or 0)
    local b_reach = (b.pole.max_wire_distance or 0) + (b.pole.supply_area_distance or 0)
    if a_reach ~= b_reach then return a_reach > b_reach end
    if a.pole.entity ~= b.pole.entity then return a.pole.entity < b.pole.entity end
    return a.item < b.item
  end)
  -- Full recursive acquisition is the expensive part on a large factory.
  -- Rank all runtime prototypes cheaply, then validate only a bounded number;
  -- the first obtainable route is already the shortest in its availability tier.
  for index = 1, math.min(8, #candidates) do
    local candidate = candidates[index]
    local positions, route_error = build_route(task, player, candidate.pole, existing)
    if positions and #positions > 0 then
      candidate.positions = positions
      candidate.required = #positions * candidate.item_count
      local acquisition, acquisition_error = Acquisition.make_plan(
        agent, candidate.item, candidate.required, task.source)
      if acquisition then
        best = candidate
        break
      elseif #rejected < 12 then
        rejected[#rejected + 1] = {
          pole = candidate.pole.entity,
          item = candidate.item,
          reason = acquisition_error
        }
      end
    elseif #rejected < 12 then
      rejected[#rejected + 1] = {
        pole = candidate.pole.entity,
        item = candidate.item,
        reason = route_error or "empty_route"
      }
    end
  end
  if not best then
    EventBus.emit("power_repair_unavailable", {task_id = task.id, target_entity = task.target_entity, rejected = rejected})
    return false, "Не смогла получить подходящие столбы для продолжения существующей сети."
  end
  task.power = best
  task.power.index = 1
  task.power.state = "acquiring"
  local ok, error_message = Acquisition.start(
    task, agent, best.item, best.required)
  if not ok then return false, error_message end
  EventBus.emit("power_repair_planned", {
    task_id = task.id,
    target_entity = task.target_entity,
    affected = #task.power_targets,
    pole = best.pole.entity,
    pole_item = best.item,
    pole_count = #best.positions
  })
  return true
end

local function place(task, agent)
  local power = task.power
  local position = power.positions[power.index]
  if not position then
    power.state = "verifying"
    power.verify_tick = game.tick + 60
    return
  end
  if not power.navigation_started then
    Navigation.start(task, agent, position, math.max(1, agent.build_distance - 1), "power_pole")
    power.navigation_started = true
    return
  end
  if not Navigation.tick(task, agent) then return end
  if Conflict.is_blocked(agent.surface.index, position, task.source) then
    TaskManager.fail("Игрок занял участок маршрута электросети; уступаю.")
    return
  end
  if not agent.surface.can_place_entity({name = power.pole.entity, position = position, force = agent.force}) then
    TaskManager.fail("Точка электросети стала занята; ничего не перезаписываю.")
    return
  end
  local removed = agent.remove_item({name = power.item, count = power.item_count})
  if removed ~= power.item_count then
    if removed > 0 then agent.insert({name = power.item, count = removed}) end
    TaskManager.fail("Не хватает " .. power.item .. " для электросети.")
    return
  end
  local entity = agent.surface.create_entity({
    name = power.pole.entity,
    position = position,
    force = agent.force,
    raise_built = true,
    create_build_effect_smoke = true
  })
  if not entity then
    agent.insert({name = power.item, count = removed})
    TaskManager.fail("Factorio отклонила размещение " .. power.pole.entity .. ".")
    return
  end
  if entity.unit_number then
    State.ensure().owned_entities[entity.unit_number] = {
      task_id = task.id,
      entity = entity.name,
      surface_index = entity.surface.index,
      position = {x = entity.position.x, y = entity.position.y},
      built_tick = game.tick
    }
  end
  EventBus.emit("power_pole_built", {
    task_id = task.id,
    entity = entity.name,
    position = {x = entity.position.x, y = entity.position.y},
    electric_network_id = entity.electric_network_id
  })
  power.index = power.index + 1
  power.navigation_started = nil
  task.navigation = nil
end

function Power.tick(task, agent)
  if not PrototypeIndex.is_ready() or not RecipeIndex.is_ready() then return end
  local player = game.get_player(task.player_index)
  if not player then TaskManager.fail("Игрок недоступен для привязки электросети."); return end
  if not task.power then
    local ok, error_message = plan(task, agent, player)
    if not ok then TaskManager.fail(error_message) end
    return
  end
  if task.power.state == "acquiring" then
    local status = Acquisition.tick(task, agent)
    if status == "done" then
      task.acquisition = nil
      task.power.state = "building"
      task.phase = "building_power_route"
    end
    return
  end
  if task.power.state == "building" then place(task, agent); return end
  if task.power.state == "verifying" and game.tick >= task.power.verify_tick then
    local remaining = 0
    for _, entity in ipairs(task.power_targets) do
      if entity.valid and entity.status == defines.entity_status.no_power then remaining = remaining + 1 end
    end
    if remaining < #task.power_targets then
      EventBus.emit("power_repair_verified", {
        task_id = task.id,
        target_entity = task.target_entity,
        restored = #task.power_targets - remaining,
        remaining = remaining
      })
      TaskManager.complete("Продолжила существующую электросеть и вернула питание "
        .. (#task.power_targets - remaining) .. " × " .. task.target_entity .. ".")
    else
      TaskManager.fail("Столбы построены, но потребители не получили питание; оставила сеть без дальнейшей перестройки.")
    end
  end
end

return Power
