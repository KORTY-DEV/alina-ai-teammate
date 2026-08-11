local State = require("scripts.core.state")
local Agent = require("scripts.agent.agent")
local TaskManager = require("scripts.tasks.manager")
local Conflict = require("scripts.conflict.manager")
local EventBus = require("scripts.core.event_bus")
local Navigation = require("scripts.navigation.navigation")

local Mining = {}

local function distance_squared(a, b)
  local dx = a.x - b.x
  local dy = a.y - b.y
  return dx * dx + dy * dy
end

local function direction_to(from, to)
  local dx = to.x - from.x
  local dy = to.y - from.y
  local ax = math.abs(dx)
  local ay = math.abs(dy)

  if ax > ay * 2 then
    return dx > 0 and defines.direction.east or defines.direction.west
  elseif ay > ax * 2 then
    return dy > 0 and defines.direction.south or defines.direction.north
  elseif dx >= 0 and dy >= 0 then
    return defines.direction.southeast
  elseif dx >= 0 and dy < 0 then
    return defines.direction.northeast
  elseif dx < 0 and dy >= 0 then
    return defines.direction.southwest
  end
  return defines.direction.northwest
end

local function inventory_count(agent, product)
  local inventory = agent.get_inventory(defines.inventory.character_main)
  return inventory and inventory.get_item_count(product) or 0
end

local function acquire_target(task, agent)
  local setting_radius = settings.global["alina-sensor-radius"]
  local radius = math.max(setting_radius and setting_radius.value or 64, 96)
  local setting_limit = settings.global["alina-resource-scan-limit"]
  local limit = setting_limit and setting_limit.value or 256
  local candidates = agent.surface.find_entities_filtered({
    position = agent.position,
    radius = radius,
    type = "resource",
    name = task.resource,
    limit = limit
  })

  local best = nil
  local best_distance = nil
  for _, candidate in ipairs(candidates) do
    if candidate.valid and candidate.amount and candidate.amount > 0 then
      local blocked = Conflict.is_blocked(candidate.surface.index, candidate.position, task.source)
      if not blocked then
        local candidate_distance = distance_squared(agent.position, candidate.position)
        if not best_distance or candidate_distance < best_distance then
          best = candidate
          best_distance = candidate_distance
        end
      end
    end
  end

  if not best then return false end
  task.target = best
  task.phase = "pathing_to_resource"
  task.phase_started_tick = game.tick
  Navigation.start(task, agent, best.position, math.max(0.5, agent.resource_reach_distance - 0.5), "resource")
  EventBus.emit("task_phase", {task_id = task.id, phase = task.phase, resource = task.resource})
  return true
end

local function begin_return(task, agent)
  task.mining_done = true
  task.target = nil
  Agent.stop()
  if task.delivery == "keep" then
    EventBus.emit("task_completed", {
      task_id = task.id,
      resource = task.resource,
      product = task.product,
      amount = task.gathered,
      delivered = 0
    })
    TaskManager.complete("Добыла " .. task.gathered .. " × " .. task.product .. " и храню у себя.")
    return
  end
  local player = game.get_player(task.player_index)
  if not player or player.surface ~= agent.surface then
    EventBus.emit("task_completed", {
      task_id = task.id,
      resource = task.resource,
      product = task.product,
      amount = task.gathered,
      delivered = 0
    })
    TaskManager.complete("Добыла " .. task.gathered .. " × " .. task.product .. "; пока храню у себя.")
    return
  end

  task.phase = "returning_to_player"
  task.phase_started_tick = game.tick
  Navigation.start(task, agent, player.position, 3.5, "delivery")
  EventBus.emit("task_phase", {task_id = task.id, phase = task.phase, product = task.product})
end

local function update_progress(task, agent)
  local count = inventory_count(agent, task.product)
  if task.initial_count == nil then task.initial_count = count end
  task.gathered = math.max(0, count - task.initial_count)
  if not task.mining_done and task.gathered >= task.amount then
    begin_return(task, agent)
    return true
  end
  return false
end

local function deliver(task, agent)
  local player = game.get_player(task.player_index)
  if not player or player.surface ~= agent.surface then
    TaskManager.complete("Добыла " .. task.gathered .. " × " .. task.product .. "; пока храню у себя.")
    return
  end

  local requested = math.min(task.gathered, inventory_count(agent, task.product))
  local removed = agent.remove_item({name = task.product, count = requested})
  local delivered = player.insert({name = task.product, count = removed})
  local remainder = removed - delivered
  if remainder > 0 then
    agent.insert({name = task.product, count = remainder})
  end

  EventBus.emit("task_completed", {
    task_id = task.id,
    resource = task.resource,
    product = task.product,
    amount = task.gathered,
    delivered = delivered
  })
  if remainder > 0 then
    TaskManager.complete("Добыла " .. task.gathered .. " × " .. task.product
      .. "; передала " .. delivered .. ", остаток храню у себя — ваш инвентарь заполнен.")
  else
    TaskManager.complete("Готово: добыла и передала вам " .. delivered .. " × " .. task.product .. ".")
  end
end

function Mining.tick(task, agent)
  if update_progress(task, agent) then return end

  if task.phase == "seeking" then
    agent.walking_state = {walking = false, direction = defines.direction.north}
    agent.mining_state = {mining = false}
    agent.selected = nil
    if not acquire_target(task, agent) then
      TaskManager.fail("Не нашла доступное месторождение " .. task.resource .. " рядом.")
    end
    return
  end

  local target = task.target
  if not task.mining_done and (not target or not target.valid or target.amount <= 0) then
    agent.mining_state = {mining = false}
    agent.selected = nil
    Navigation.cancel(task)
    task.target = nil
    task.phase = "seeking"
    return
  end

  if task.phase == "returning_to_player" then
    local player = game.get_player(task.player_index)
    if not player or player.surface ~= agent.surface then
      deliver(task, agent)
      return
    end
    Navigation.update_goal(task, agent, player.position, 6)
    if Navigation.tick(task, agent) then
      task.phase = "delivering"
      EventBus.emit("task_phase", {task_id = task.id, phase = task.phase, product = task.product})
    end
    return
  end

  if task.phase == "delivering" then
    deliver(task, agent)
    return
  end

  if target.surface ~= agent.surface then
    TaskManager.fail("Цель оказалась на другой поверхности.")
    return
  end

  local reach = agent.resource_reach_distance
  local target_distance = distance_squared(agent.position, target.position)
  if task.phase == "pathing_to_resource" then
    if Navigation.tick(task, agent) then
      task.phase = "mining"
      task.phase_started_tick = game.tick
      task.last_progress_tick = game.tick
      task.last_gathered = task.gathered
      EventBus.emit("task_phase", {task_id = task.id, phase = task.phase, resource = task.resource})
    end
    return
  end

  if task.phase == "mining" then
    if target_distance > reach * reach then
      task.phase = "pathing_to_resource"
      Navigation.start(task, agent, target.position, math.max(0.5, reach - 0.5), "resource")
      return
    end

    agent.walking_state = {walking = false, direction = direction_to(agent.position, target.position)}
    agent.selected = target
    agent.mining_state = {mining = true, position = target.position}
    if task.gathered > (task.last_gathered or -1) then
      task.last_gathered = task.gathered
      task.last_progress_tick = game.tick
    elseif game.tick - (task.last_progress_tick or game.tick) > 900 then
      TaskManager.fail("Добыча не продвигается; остановилась, чтобы не зациклиться.")
    end
  end
end

return Mining
