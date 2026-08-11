local Acquisition = require("scripts.executor.acquisition")
local Conflict = require("scripts.conflict.manager")
local ConstructionTransaction = require("scripts.construction.transaction")
local EventBus = require("scripts.core.event_bus")
local Navigation = require("scripts.navigation.navigation")
local State = require("scripts.core.state")
local TaskManager = require("scripts.tasks.manager")
local WorldModel = require("scripts.sensors.world_model")

local Upgrader = {}

local SAMPLE_TICKS = 900

local function resolve_named(upgrade, expected_name, unit_number)
  local entity = unit_number and game.get_entity_by_unit_number(unit_number) or nil
  if entity and entity.valid then return entity end
  local surface = game.surfaces[upgrade.surface_index]
  if not surface then return nil end
  local force = upgrade.force_index and game.forces[upgrade.force_index] or nil
  local entities = surface.find_entities_filtered({
    position = upgrade.position,
    radius = 0.22,
    name = expected_name,
    force = force,
    limit = 4
  })
  for _, candidate in ipairs(entities) do
    if candidate.valid and math.abs(candidate.position.x - upgrade.position.x) < 0.1
        and math.abs(candidate.position.y - upgrade.position.y) < 0.1 then return candidate end
  end
  return nil
end

local function resolve(upgrade)
  return resolve_named(upgrade, upgrade.old_name, upgrade.entity_unit_number)
end

local function product_counter(entity)
  local ok, value = pcall(function() return entity.products_finished end)
  return ok and type(value) == "number" and value or nil
end

local function flow_counter(entity, item)
  local stats = entity.force.get_item_production_statistics(entity.surface)
  return stats.get_input_count(item) or 0
end

local function start_sample(task, entity, prefix)
  local upgrade = task.upgrade
  upgrade[prefix .. "_tick"] = game.tick
  upgrade[prefix .. "_products"] = product_counter(entity)
  upgrade[prefix .. "_flow"] = flow_counter(entity, upgrade.target_item)
end

local function sample_delta(task, entity, prefix)
  local upgrade = task.upgrade
  local products_start = upgrade[prefix .. "_products"]
  local products_now = product_counter(entity)
  local cycles = products_start and products_now and math.max(0, products_now - products_start) or nil
  local flow = math.max(0, flow_counter(entity, upgrade.target_item) - (upgrade[prefix .. "_flow"] or 0))
  return cycles, flow
end

local function collect_ground_item(agent, item_name, position)
  local needed = 1
  for _, drop in ipairs(agent.surface.find_entities_filtered({
      position = position, radius = 2, type = "item-entity", limit = 16})) do
    if needed <= 0 then break end
    local stack = drop.valid and drop.stack or nil
    if stack and stack.valid_for_read and stack.name == item_name then
      local take = math.min(needed, stack.count)
      local inserted = agent.insert({name = item_name, count = take, quality = stack.quality})
      if inserted > 0 then
        needed = needed - inserted
        if inserted >= stack.count then drop.destroy() else stack.count = stack.count - inserted end
      end
    end
  end
end

local function perform_replacement(task, agent, source)
  local upgrade = task.upgrade
  if Conflict.is_blocked(source.surface.index, source.position, task.source) then
    return nil, "Игрок работает у выбранной машины; уступаю этот участок."
  end
  if not source.surface.can_fast_replace({name = upgrade.new_name, position = source.position,
      direction = source.direction, force = source.force}) then
    return nil, "Выбранную машину больше нельзя безопасно заменить на месте."
  end
  local main = agent.get_inventory(defines.inventory.character_main)
  if not main or main.get_item_count(upgrade.new_item) < 1 then
    return nil, "Перед заменой пропала новая машина " .. upgrade.new_item .. "."
  end
  local old_unit = source.unit_number
  local old_owned = State.ensure().owned_entities[old_unit]
  local old_item_before = main.get_item_count(upgrade.old_item)
  local new_item_before = main.get_item_count(upgrade.new_item)
  local replacement = source.surface.create_entity({
    name = upgrade.new_name,
    position = source.position,
    direction = source.direction,
    force = source.force,
    fast_replace = true,
    character = agent,
    spill = true,
    raise_built = true,
    create_build_effect_smoke = true
  })
  if not replacement or not replacement.valid then return nil, "Factorio отклонила атомарную замену машины." end

  if main.get_item_count(upgrade.new_item) == new_item_before then
    local removed = agent.remove_item({name = upgrade.new_item, count = 1})
    if removed ~= 1 then return nil, "Не удалось корректно учесть новую машину после замены." end
  end
  if main.get_item_count(upgrade.old_item) == old_item_before then
    collect_ground_item(agent, upgrade.old_item, replacement.position)
  end

  local root = State.ensure()
  root.owned_entities[old_unit] = nil
  if replacement.unit_number then
    root.owned_entities[replacement.unit_number] = {
      task_id = task.id,
      entity = replacement.name,
      surface_index = replacement.surface.index,
      position = {x = replacement.position.x, y = replacement.position.y},
      built_tick = game.tick,
      upgraded_from = upgrade.old_name,
      previous_owner_task_id = old_owned and old_owned.task_id or nil
    }
  end
  WorldModel.forget_entity(old_unit, replacement.surface.index)
  WorldModel.observe_entity(replacement)
  ConstructionTransaction.record_replacement(task, {
    name = upgrade.old_name,
    item = upgrade.old_item,
    new_item = upgrade.new_item
  }, replacement)
  if main.get_item_count(upgrade.old_item) <= old_item_before then
    return nil, "Старая машина не вернулась в инвентарь после замены; остановилась без удаления новой машины."
  end
  if upgrade.recipe and (replacement.type == "assembling-machine" or replacement.type == "furnace"
      or replacement.type == "rocket-silo") then
    local recipe = replacement.get_recipe()
    if not recipe or recipe.name ~= upgrade.recipe then
      return nil, "После замены не сохранился рецепт " .. upgrade.recipe .. "; возвращаю прежнюю машину."
    end
  end
  EventBus.emit("machine_upgrade_replaced", {
    task_id = task.id,
    from = upgrade.old_name,
    to = upgrade.new_name,
    target_item = upgrade.target_item,
    expected_gain = upgrade.expected_gain,
    position = upgrade.position
  })
  return replacement
end

function Upgrader.tick(task, agent)
  local upgrade = task.upgrade
  if not upgrade then TaskManager.fail("План улучшения машины повреждён."); return end

  if upgrade.stage == "acquiring" then
    local main = agent.get_inventory(defines.inventory.character_main)
    if main and main.get_item_count(upgrade.new_item) >= 1 then
      task.acquisition = nil
      upgrade.stage = "sampling_before"
      task.phase = "sampling_before_upgrade"
      task.summary = "Проверяю реальную загрузку " .. upgrade.old_name
      return
    end
    if not task.acquisition then
      local ok, result = Acquisition.start(task, agent, upgrade.new_item, 1)
      if not ok then TaskManager.fail("Не могу подготовить улучшение " .. upgrade.new_item .. ": " .. tostring(result)); return end
    end
    if Acquisition.tick(task, agent) == "done" then
      task.acquisition = nil
      task.navigation = nil
      upgrade.stage = "sampling_before"
      task.phase = "sampling_before_upgrade"
    end
    return
  end

  if upgrade.stage == "sampling_before" then
    local entity = resolve(upgrade)
    if not entity or not entity.valid then TaskManager.fail("Исходная машина исчезла до улучшения."); return end
    if not upgrade.baseline_tick then
      start_sample(task, entity, "baseline")
      task.summary = "Измеряю фактическую производительность перед улучшением"
      return
    end
    if game.tick < upgrade.baseline_tick + SAMPLE_TICKS then return end
    upgrade.baseline_cycles, upgrade.baseline_flow = sample_delta(task, entity, "baseline")
    local evidence = upgrade.baseline_cycles or upgrade.baseline_flow
    if (evidence or 0) <= 0 then
      TaskManager.fail("Машина не выпускала продукцию в контрольном окне; апгрейд не оправдан, ищу другое решение.")
      return
    end
    upgrade.stage = "approaching"
    task.phase = "approaching_upgrade"
    task.summary = "Иду к машине для безопасной замены на месте"
    return
  end

  if upgrade.stage == "approaching" then
    local entity = resolve(upgrade)
    if not entity or not entity.valid then TaskManager.fail("Исходная машина исчезла до улучшения."); return end
    if not task.navigation then
      Navigation.start(task, agent, entity.position, math.max(1, agent.build_distance - 1), "machine_upgrade")
      return
    end
    if not Navigation.tick(task, agent) then return end
    task.navigation = nil
    local replacement, error_message = perform_replacement(task, agent, entity)
    if not replacement then TaskManager.fail(error_message); return end
    upgrade.new_unit_number = replacement.unit_number
    start_sample(task, replacement, "after")
    upgrade.stage = "verifying"
    task.phase = "verifying_upgrade"
    task.summary = "Проверяю реальный результат улучшения " .. upgrade.new_name
    return
  end

  if upgrade.stage == "verifying" then
    -- A fast replacement receives a new unit number. Some runtime paths do not
    -- resolve it through the global lookup until later, so use the same exact
    -- surface/name/position fallback as construction rollback.
    local entity = resolve_named(upgrade, upgrade.new_name, upgrade.new_unit_number)
    if not entity or not entity.valid then TaskManager.fail("Новая машина исчезла во время проверки."); return end
    if Conflict.is_blocked(entity.surface.index, entity.position, task.source) then
      TaskManager.fail("Игрок начал работать у улучшенной машины; прекращаю проверку и больше её не трогаю.")
      return
    end
    if game.tick < upgrade.after_tick + SAMPLE_TICKS then return end
    local cycles, flow = sample_delta(task, entity, "after")
    upgrade.after_cycles, upgrade.after_flow = cycles, flow
    local before = upgrade.baseline_cycles or upgrade.baseline_flow or 0
    local after = cycles or flow or 0
    local actual_gain = after / math.max(1, before)
    upgrade.actual_gain = actual_gain
    if after < before * 1.02 then
      TaskManager.fail("Фактический выпуск после улучшения не вырос (" .. tostring(before) .. " → "
        .. tostring(after) .. "); возвращаю прежнюю машину.")
      return
    end
    EventBus.emit("machine_upgrade_verified", {
      task_id = task.id,
      from = upgrade.old_name,
      to = upgrade.new_name,
      target_item = upgrade.target_item,
      before = before,
      after = after,
      actual_gain = actual_gain
    })
    TaskManager.complete("Проверила улучшение " .. upgrade.old_name .. " → " .. upgrade.new_name
      .. ": фактический выпуск вырос с " .. tostring(before) .. " до " .. tostring(after) .. ".")
  end
end

return Upgrader
