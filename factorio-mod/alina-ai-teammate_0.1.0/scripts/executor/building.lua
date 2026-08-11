local State = require("scripts.core.state")
local Agent = require("scripts.agent.agent")
local Navigation = require("scripts.navigation.navigation")
local Conflict = require("scripts.conflict.manager")
local EventBus = require("scripts.core.event_bus")
local TaskManager = require("scripts.tasks.manager")

local Building = {}

local function distance_squared(a, b)
  local dx = a.x - b.x
  local dy = a.y - b.y
  return dx * dx + dy * dy
end

local function candidate_positions(center)
  local result = {}
  for radius = 8, 20, 2 do
    local offsets = {
      {radius, 0}, {0, radius}, {-radius, 0}, {0, -radius},
      {radius, radius}, {-radius, radius}, {-radius, -radius}, {radius, -radius}
    }
    for _, offset in ipairs(offsets) do
      result[#result + 1] = {x = center.x + offset[1], y = center.y + offset[2]}
    end
  end
  return result
end

local function find_position(task, agent, player, entity_name)
  local surface = player.surface
  local seen = {}
  for _, desired in ipairs(candidate_positions(player.position)) do
    local position = surface.find_non_colliding_position(entity_name, desired, 3, 0.5, true)
    if position then
      local key = tostring(position.x) .. ":" .. tostring(position.y)
      local blocked = Conflict.is_blocked(surface.index, position, task.source)
      if not seen[key] and not blocked
          and distance_squared(position, player.position) >= 36
          and surface.can_place_entity({name = entity_name, position = position, force = agent.force}) then
        return {x = position.x, y = position.y}
      end
      seen[key] = true
    end
  end
  return nil
end

function Building.start(task, agent, solution, player)
  local position = find_position(task, agent, player, solution.machine)
  if not position then return false, "Не нашла свободное безопасное место для " .. solution.machine .. "." end
  task.building = {
    state = "pathing",
    entity_name = solution.machine,
    item_name = solution.placement_item,
    item_count = solution.placement_count,
    position = position
  }
  task.phase = "moving_to_build_site"
  Navigation.start(task, agent, position, math.max(1, agent.build_distance - 1), "build_site")
  EventBus.emit("build_site_selected", {
    task_id = task.id,
    entity = solution.machine,
    item = solution.placement_item,
    position = position
  })
  return true
end

local function place(task, agent, building)
  local blocked = Conflict.is_blocked(agent.surface.index, building.position, task.source)
  if blocked then return false, "Выбранное место стало защищённой зоной игрока." end
  if not agent.surface.can_place_entity({
      name = building.entity_name,
      position = building.position,
      force = agent.force
    }) then
    return false, "Выбранное место заняли до строительства; ничего не перезаписываю." end

  local removed = agent.remove_item({name = building.item_name, count = building.item_count})
  if removed ~= building.item_count then
    if removed > 0 then agent.insert({name = building.item_name, count = removed}) end
    return false, "В инвентаре нет предмета для строительства " .. building.item_name .. "." end
  local entity = agent.surface.create_entity({
    name = building.entity_name,
    position = building.position,
    force = agent.force,
    raise_built = true,
    create_build_effect_smoke = true
  })
  if not entity then
    agent.insert({name = building.item_name, count = removed})
    return false, "Factorio отклонила размещение " .. building.entity_name .. "." end

  local root = State.ensure()
  if entity.unit_number then
    root.owned_entities[entity.unit_number] = {
      task_id = task.id,
      entity = entity.name,
      surface_index = entity.surface.index,
      position = {x = entity.position.x, y = entity.position.y},
      built_tick = game.tick
    }
  end
  building.state = "placed"
  building.entity = entity
  task.built_entity = entity
  EventBus.emit("entity_built", {
    task_id = task.id,
    entity = entity.name,
    item = building.item_name,
    position = {x = entity.position.x, y = entity.position.y}
  })
  return true
end

function Building.tick(task, agent)
  local building = task.building
  if not building then return "failed" end
  if building.state == "placed" then return "done", building.entity end
  if building.state == "pathing" then
    if not Navigation.tick(task, agent) then return "working" end
    building.state = "placing"
  end
  if building.state == "placing" then
    local ok, error_message = place(task, agent, building)
    if not ok then
      TaskManager.fail(error_message)
      return "failed"
    end
    return "done", building.entity
  end
  return "working"
end

return Building
