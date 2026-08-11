local State = require("scripts.core.state")
local Navigation = require("scripts.navigation.navigation")
local TaskManager = require("scripts.tasks.manager")

local Inspection = {}

local function resolve_target(task)
  local entity = task.inspect_entity
  if entity and entity.valid then return entity end
  if task.inspect_unit_number then
    entity = game.get_entity_by_unit_number(task.inspect_unit_number)
    if entity and entity.valid then
      task.inspect_entity = entity
      return entity
    end
  end
  return nil
end

function Inspection.tick(task, agent)
  local target = resolve_target(task)
  if not target then
    TaskManager.complete("")
    return
  end
  if target.surface ~= agent.surface then
    TaskManager.complete("")
    return
  end

  if task.phase == "approaching" then
    if not task.navigation then
      Navigation.start(task, agent, target.position, math.max(1.5, agent.reach_distance - 0.5), "inspect_factory")
      task.summary = "Иду проверять " .. target.name
      return
    end
    if not Navigation.tick(task, agent) then return end
    task.phase = "observing"
    task.observe_until = game.tick + 45
    task.summary = "Проверяю " .. target.name
    return
  end

  if task.phase == "observing" then
    if game.tick < (task.observe_until or game.tick) then return end
    local root = State.ensure()
    root.autonomy.last_inspected_unit = target.unit_number
    root.autonomy.last_inspection_tick = game.tick
    root.autonomy.last_activity = "Осмотрела участок " .. target.name
    TaskManager.complete("")
  end
end

return Inspection
