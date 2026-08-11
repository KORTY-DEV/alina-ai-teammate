local Factory = require("scripts.sensors.factory")
local RecipeIndex = require("scripts.sensors.recipe_index")
local EventBus = require("scripts.core.event_bus")
local TaskManager = require("scripts.tasks.manager")
local State = require("scripts.core.state")

local Shortage = {}

local INPUT_SHORTAGE = {
  no_ingredients = true,
  item_ingredient_shortage = true,
  fluid_ingredient_shortage = true,
  no_input_fluid = true,
  low_input_fluid = true,
  missing_required_fluid = true
}
local POWER_SHORTAGE = {no_power = true, low_power = true, not_plugged_in_electric_network = true}
local OUTPUT_BLOCKED = {full_output = true, waiting_for_space_in_destination = true, not_enough_space_in_output = true}

local function find_flow(snapshot, value_type, name)
  local rows = value_type == "fluid" and snapshot.fluid_flows or snapshot.item_flows
  for _, row in ipairs(rows or {}) do
    if row.name == name then return row end
  end
  return {name = name, type = value_type, produced_per_minute = 0, consumed_per_minute = 0}
end

local function produces(recipe, item_name)
  for _, product in ipairs(recipe.products or {}) do
    if product.type == "item" and product.name == item_name then return true end
  end
  return false
end

local function count_statuses(recipes)
  local result = {}
  for _, recipe in ipairs(recipes) do
    for _, status in ipairs(recipe.statuses or {}) do
      result[status.status] = (result[status.status] or 0) + status.count
    end
  end
  return result
end

local function any_status(statuses, category)
  for name, count in pairs(statuses) do
    if count > 0 and category[name] then return true end
  end
  return false
end

local function limiting_ingredient(active_producers, snapshot)
  local candidate, best_ratio = nil, nil
  for _, recipe in ipairs(active_producers) do
    for _, ingredient in ipairs(recipe.ingredients or {}) do
      if ingredient.type == "item" or ingredient.type == "fluid" then
        local flow = find_flow(snapshot, ingredient.type, ingredient.name)
        local available = flow.produced_per_minute or 0
        local demand = flow.consumed_per_minute or 0
        local ratio = available / math.max(ingredient.amount or 1, demand, 0.001)
        if not best_ratio or ratio < best_ratio then
          best_ratio, candidate = ratio, {name = ingredient.name, type = ingredient.type}
        end
      end
    end
  end
  return candidate
end

local function suppress(root, item, ticks)
  root.autonomy.suppressed_items[item] = game.tick + ticks
end

function Shortage.tick(task, agent)
  if not RecipeIndex.is_ready() then
    task.phase = "waiting_for_recipe_index"
    task.summary = "Жду индекс рецептов для " .. task.target_item
    return
  end

  local player = game.get_player(task.player_index)
  if not player then
    TaskManager.fail("Игрок недоступен для диагностики производства.")
    return
  end

  task.phase = "diagnosing"
  task.summary = "Проверяю линию " .. task.target_item
  local snapshot = Factory.target_snapshot(player, task.target_item)
  local flow = find_flow(snapshot, "item", task.target_item)
  local active_producers = {}
  for _, recipe in ipairs(snapshot.active_recipes or {}) do
    if produces(recipe, task.target_item) then active_producers[#active_producers + 1] = recipe end
  end
  local candidates = RecipeIndex.find_producers(task.target_item, player.force, 8) or {}
  local statuses = count_statuses(active_producers)
  local enabled_candidate = false
  for _, candidate in ipairs(candidates) do if candidate.enabled then enabled_candidate = true; break end end

  local reason
  if #active_producers == 0 then
    reason = enabled_candidate and "no_local_producer" or "recipe_locked"
  elseif any_status(statuses, POWER_SHORTAGE) then
    reason = "power_shortage"
  elseif any_status(statuses, INPUT_SHORTAGE) then
    reason = "ingredient_shortage"
  elseif any_status(statuses, OUTPUT_BLOCKED) then
    reason = "output_blocked"
  elseif (flow.produced_per_minute or 0) <= 0 then
    reason = "stalled"
  elseif (flow.consumed_per_minute or 0) > (flow.produced_per_minute or 0) * 1.05 then
    reason = "demand_exceeds_supply"
  else
    reason = "insufficient_evidence"
  end

  local limiting = limiting_ingredient(active_producers, snapshot)
  EventBus.emit("shortage_diagnosed", {
    task_id = task.id,
    target_item = task.target_item,
    reason = reason,
    produced_per_minute = flow.produced_per_minute or 0,
    consumed_per_minute = flow.consumed_per_minute or 0,
    limiting_ingredient = limiting and limiting.name or nil,
    limiting_type = limiting and limiting.type or nil,
    local_producer_count = #active_producers
  })

  local root = State.ensure()
  if reason == "ingredient_shortage" or reason == "stalled" then
    if limiting and limiting.type == "item" and prototypes.item[limiting.name] then
      root.autonomy.priority_item = limiting.name
      suppress(root, task.target_item, 3600)
      TaskManager.complete("У линии " .. task.target_item .. " не хватает " .. limiting.name
        .. "; переключаюсь на усиление upstream-производства вместо ручного докладывания предметов.")
      return
    elseif limiting and limiting.type == "fluid" and prototypes.fluid[limiting.name] then
      root.autonomy.priority_fluid = limiting.name
      suppress(root, task.target_item, 1800)
      TaskManager.complete("У линии " .. task.target_item .. " не хватает жидкости " .. limiting.name
        .. "; конечные машины не клонирую, сначала строю или усиливаю её безопасный upstream-контур.")
      return
    end
  end

  if reason == "output_blocked" then
    -- A full output is a logistics/layout problem, not permission to teleport
    -- items into Alina's inventory. Leave the line intact and wait for a safe
    -- repeated-cell/logistics expansion rather than performing remote hand-feeding.
    suppress(root, task.target_item, 7200)
    TaskManager.complete("Выход линии " .. task.target_item
      .. " заполнен. Вручную и дистанционно предметы не забираю; линию оставляю нетронутой до безопасного расширения логистики.")
    return
  end

  if reason == "power_shortage" then
    suppress(root, task.target_item, 900)
    TaskManager.complete("У производителей " .. task.target_item .. " проблема с питанием; автономный планировщик займётся электросетью.")
    return
  end

  if reason == "demand_exceeds_supply" then
    suppress(root, task.target_item, 3600)
    TaskManager.complete("Расход " .. task.target_item
      .. " выше выпуска, но безопасный повторяемый модуль линии не найден. Одиночные машины без автоматизации не ставлю.")
    return
  end

  if reason == "no_local_producer" then
    if (root.autonomy.item_cooldown[task.target_item] or 0) <= game.tick then
      root.autonomy.priority_item = task.target_item
    end
    suppress(root, task.target_item, 1800)
    TaskManager.complete("Для " .. task.target_item
      .. " рядом нет готовой линии. Планирую полную связанную цепочку от доступного сырья до проверяемого выхода.")
    return
  end

  if reason == "recipe_locked" then
    suppress(root, task.target_item, 18000)
    TaskManager.complete("Рецепт для " .. task.target_item .. " пока недоступен; продолжу исследования и другие задачи.")
    return
  end

  suppress(root, task.target_item, 1800)
  TaskManager.complete("По " .. task.target_item .. " сейчас нет доказанного безопасного улучшения; ничего не ломаю и продолжаю обход базы.")
end

return Shortage
