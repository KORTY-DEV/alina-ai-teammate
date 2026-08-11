local Conflict = require("scripts.conflict.manager")
local EventBus = require("scripts.core.event_bus")
local State = require("scripts.core.state")
local WorldModel = require("scripts.sensors.world_model")

local Transaction = {}

local function begin(task)
  if task.construction_transaction then return task.construction_transaction end
  task.construction_transaction = {
    status = "open",
    created = {},
    ghosts = {},
    replacements = {},
    started_tick = game.tick
  }
  EventBus.emit("construction_transaction_started", {task_id = task.id, task_type = task.type})
  return task.construction_transaction
end

local function same_position(a, b)
  return a and b and math.abs(a.x - b.x) < 0.1 and math.abs(a.y - b.y) < 0.1
end

local function resolve_record(row, expected_name)
  local entity = row.unit_number and game.get_entity_by_unit_number(row.unit_number) or nil
  if entity and entity.valid then return entity end
  local surface = game.surfaces[row.surface_index]
  if not surface then return nil end
  local force = row.force_index and game.forces[row.force_index] or nil
  local entities = surface.find_entities_filtered({
    position = row.position,
    radius = 0.22,
    name = expected_name or row.name,
    force = force,
    limit = 8
  })
  for _, candidate in ipairs(entities) do
    if candidate.valid and same_position(candidate.position, row.position) then return candidate end
  end
  return nil
end

function Transaction.begin(task)
  return begin(task)
end

function Transaction.record_created(task, entity)
  if not task or not entity or not entity.valid or not entity.unit_number then return end
  local transaction = begin(task)
  transaction.created[#transaction.created + 1] = {
    unit_number = entity.unit_number,
    name = entity.name,
    surface_index = entity.surface.index,
    force_index = entity.force.index,
    position = {x = entity.position.x, y = entity.position.y}
  }
end

function Transaction.record_ghost(task, ghost)
  if not task or not ghost or not ghost.valid or not ghost.unit_number then return end
  local transaction = begin(task)
  transaction.ghosts[#transaction.ghosts + 1] = {
    unit_number = ghost.unit_number,
    surface_index = ghost.surface.index,
    force_index = ghost.force.index,
    ghost_name = ghost.ghost_name,
    position = {x = ghost.position.x, y = ghost.position.y}
  }
end

function Transaction.record_replacement(task, old_row, new_entity)
  if not task or not old_row or not new_entity or not new_entity.valid or not new_entity.unit_number then return end
  local transaction = begin(task)
  transaction.replacements[#transaction.replacements + 1] = {
    old_name = old_row.name,
    old_item = old_row.item,
    new_name = new_entity.name,
    new_item = old_row.new_item,
    new_unit_number = new_entity.unit_number,
    surface_index = new_entity.surface.index,
    force_index = new_entity.force.index,
    position = {x = new_entity.position.x, y = new_entity.position.y},
    direction = new_entity.direction
  }
end

function Transaction.commit(task)
  local transaction = task and task.construction_transaction or nil
  if not transaction or transaction.status ~= "open" then return end
  local created_count = #transaction.created
  local ghost_count = #transaction.ghosts
  local replacement_count = #transaction.replacements
  task.construction_transaction = {
    status = "committed",
    created_count = created_count,
    ghost_count = ghost_count,
    replacement_count = replacement_count,
    started_tick = transaction.started_tick,
    finished_tick = game.tick
  }
  EventBus.emit("construction_transaction_committed", {
    task_id = task.id,
    task_type = task.type,
    created = created_count,
    ghosts = ghost_count,
    replacements = replacement_count
  })
end

-- Rollback is deliberately restricted to entities created by this exact task.
-- Existing factory objects are never candidates. If a player has started working
-- at a created object or it cannot be mined without loss, it is preserved and
-- reported instead of being destroyed.
function Transaction.rollback(task, agent, reason)
  local transaction = task and task.construction_transaction or nil
  if not transaction or transaction.status ~= "open" then
    return {removed = 0, ghosts_removed = 0, replacements_reverted = 0, preserved = 0}
  end

  local root = State.ensure()
  local main = agent and agent.valid and agent.get_inventory(defines.inventory.character_main) or nil
  local removed, ghosts_removed, replacements_reverted, preserved = 0, 0, 0, 0

  for index = #transaction.replacements, 1, -1 do
    local row = transaction.replacements[index]
    local entity = resolve_record({unit_number = row.new_unit_number, surface_index = row.surface_index,
      force_index = row.force_index, position = row.position, name = row.new_name}, row.new_name)
    local force = game.forces[row.force_index]
    if entity and entity.valid and main and force and entity.name == row.new_name
        and same_position(entity.position, row.position)
        and not Conflict.is_blocked(row.surface_index, row.position, task.source)
        and main.get_item_count(row.old_item) >= 1
        and entity.surface.can_fast_replace({name = row.old_name, position = row.position,
          direction = row.direction, force = force}) then
      local new_unit = entity.unit_number
      local old_count_before = main.get_item_count(row.old_item)
      local new_count_before = row.new_item and main.get_item_count(row.new_item) or 0
      local reverted = entity.surface.create_entity({
        name = row.old_name,
        position = row.position,
        direction = row.direction,
        force = force,
        fast_replace = true,
        character = agent,
        spill = true,
        raise_built = true,
        create_build_effect_smoke = true
      })
      if reverted and reverted.valid then
        if main.get_item_count(row.old_item) == old_count_before then
          agent.remove_item({name = row.old_item, count = 1})
        end
        if row.new_item and main.get_item_count(row.new_item) == new_count_before then
          agent.insert({name = row.new_item, count = 1})
        end
        root.owned_entities[new_unit] = nil
        WorldModel.forget_entity(new_unit, row.surface_index)
        WorldModel.observe_entity(reverted)
        replacements_reverted = replacements_reverted + 1
      else
        preserved = preserved + 1
      end
    elseif entity and entity.valid then
      preserved = preserved + 1
    end
  end

  for index = #transaction.ghosts, 1, -1 do
    local row = transaction.ghosts[index]
    local ghost = resolve_record(row, "entity-ghost")
    if ghost and ghost.valid and ghost.type == "entity-ghost" and same_position(ghost.position, row.position)
        and not Conflict.is_blocked(row.surface_index, row.position, task.source) then
      local unit = ghost.unit_number
      local ok, destroyed = pcall(function() return ghost.destroy({raise_destroy = true}) end)
      if ok and destroyed then
        WorldModel.forget_entity(unit, row.surface_index)
        ghosts_removed = ghosts_removed + 1
      else
        preserved = preserved + 1
      end
    elseif ghost and ghost.valid then
      preserved = preserved + 1
    end
  end

  for index = #transaction.created, 1, -1 do
    local row = transaction.created[index]
    local entity = resolve_record(row, row.name)
    local owned = root.owned_entities[row.unit_number]
    if entity and entity.valid and main and owned and owned.task_id == task.id
        and entity.name == row.name and same_position(entity.position, row.position)
        and not Conflict.is_blocked(row.surface_index, row.position, task.source) then
      local unit = entity.unit_number
      local ok, mined = pcall(function()
        return entity.mine({inventory = main, force = true, raise_destroyed = true})
      end)
      if ok and mined then
        root.owned_entities[unit] = nil
        WorldModel.forget_entity(unit, row.surface_index)
        removed = removed + 1
      else
        preserved = preserved + 1
      end
    elseif entity and entity.valid then
      preserved = preserved + 1
    end
  end

  task.construction_transaction = {
    status = preserved == 0 and "rolled_back" or "partially_rolled_back",
    created_count = #transaction.created,
    ghost_count = #transaction.ghosts,
    replacement_count = #transaction.replacements,
    removed = removed,
    ghosts_removed = ghosts_removed,
    replacements_reverted = replacements_reverted,
    preserved = preserved,
    started_tick = transaction.started_tick,
    finished_tick = game.tick,
    reason = reason
  }
  EventBus.emit("construction_transaction_rolled_back", {
    task_id = task.id,
    task_type = task.type,
    removed = removed,
    ghosts_removed = ghosts_removed,
    replacements_reverted = replacements_reverted,
    preserved = preserved,
    created_recorded = #transaction.created,
    ghosts_recorded = #transaction.ghosts,
    replacements_recorded = #transaction.replacements,
    reason = reason
  })
  return {removed = removed, ghosts_removed = ghosts_removed,
    replacements_reverted = replacements_reverted, preserved = preserved}
end

return Transaction
