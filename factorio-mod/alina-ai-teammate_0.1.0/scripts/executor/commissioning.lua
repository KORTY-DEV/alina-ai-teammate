local Acquisition = require("scripts.executor.acquisition")
local PrototypeIndex = require("scripts.sensors.prototype_index")
local EventBus = require("scripts.core.event_bus")
local TaskManager = require("scripts.tasks.manager")

local Commissioning = {}

local TEST_BATCHES = 5

local function production_total(force, surface, item_name)
  local counts = force.get_item_production_statistics(surface).input_counts
  return counts[item_name] or 0
end

local function transfer(agent, destination, item_name, count)
  if not destination or not destination.valid then return false, 0 end
  local removed = agent.remove_item({name = item_name, count = count})
  local inserted = destination.insert({name = item_name, count = removed})
  local remainder = removed - inserted
  if remainder > 0 then agent.insert({name = item_name, count = remainder}) end
  return inserted == count, inserted
end

local function choose_fuel(task, agent, burner)
  local best = nil
  local best_score = nil
  for _, fuel in ipairs(PrototypeIndex.fuels_for(burner.fuel_categories) or {}) do
    local plan = Acquisition.make_plan(agent, fuel.name, TEST_BATCHES, task.source)
    if plan then
      local score = #plan.operations * 1000
      for _, operation in ipairs(plan.operations) do score = score + (operation.count or operation.crafts or 1) end
      if not best_score or score < best_score then best = fuel.name; best_score = score end
    end
  end
  return best
end

function Commissioning.start(task, entity, solution)
  if not entity or not entity.valid then return false, "Производственная машина недоступна." end
  if entity.type == "assembling-machine" or entity.type == "rocket-silo" then
    local current = entity.get_recipe()
    if not current or current.name ~= solution.recipe.name then
      entity.set_recipe(solution.recipe.name)
      current = entity.get_recipe()
      if not current or current.name ~= solution.recipe.name then
        return false, "Машина не приняла рецепт " .. solution.recipe.name .. "."
      end
    end
  end
  local input = entity.get_inventory(defines.inventory.crafter_input)
  local output = entity.get_inventory(defines.inventory.crafter_output)
  if not input or not output then
    return false, "У выбранной машины нет стандартных crafter-инвентарей."
  end
  task.commissioning = {
    state = "ingredients",
    ingredient_index = 1,
    entity = entity,
    recipe = solution.recipe,
    target_item = task.target_item,
    baseline_production = production_total(entity.force, entity.surface, task.target_item),
    baseline_output = output.get_item_count(task.target_item),
    started_tick = game.tick
  }
  task.phase = "commissioning"
  EventBus.emit("commissioning_started", {
    task_id = task.id,
    entity = entity.name,
    recipe = solution.recipe.name,
    target_item = task.target_item
  })
  return true
end

local function begin_acquisition(task, agent, item_name, count, kind)
  local ok, error_message = Acquisition.start(task, agent, item_name, count)
  if not ok then return false, error_message end
  task.commissioning.pending = {kind = kind, item = item_name, count = count}
  task.commissioning.state = "acquiring"
  return true
end

local function finish_pending(task, agent, commissioning)
  local pending = commissioning.pending
  local destination
  if pending.kind == "ingredient" then
    destination = commissioning.entity.get_inventory(defines.inventory.crafter_input)
  else
    destination = commissioning.entity.burner and commissioning.entity.burner.inventory or nil
  end
  local ok, inserted = transfer(agent, destination, pending.item, pending.count)
  if not ok then
    return false, "Машина приняла только " .. inserted .. " из " .. pending.count .. " × " .. pending.item .. "."
  end
  EventBus.emit("commissioning_material_loaded", {
    task_id = task.id,
    entity = commissioning.entity.name,
    kind = pending.kind,
    item = pending.item,
    count = inserted
  })
  task.acquisition = nil
  commissioning.pending = nil
  if pending.kind == "ingredient" then
    commissioning.ingredient_index = commissioning.ingredient_index + 1
    commissioning.state = "ingredients"
  else
    commissioning.state = "verifying"
    commissioning.verify_started_tick = game.tick
  end
  return true
end

function Commissioning.tick(task, agent)
  local commissioning = task.commissioning
  if not commissioning or not commissioning.entity or not commissioning.entity.valid then
    TaskManager.fail("Производственная машина исчезла до проверки.")
    return "failed"
  end
  if commissioning.state == "acquiring" then
    local status = Acquisition.tick(task, agent)
    if status == "failed" then return status end
    if status == "done" then
      local ok, error_message = finish_pending(task, agent, commissioning)
      if not ok then TaskManager.fail(error_message); return "failed" end
    end
    return "working"
  end

  if commissioning.state == "ingredients" then
    local ingredient = commissioning.recipe.ingredients[commissioning.ingredient_index]
    if ingredient then
      if ingredient.type ~= "item" or not ingredient.amount then
        TaskManager.fail("Первый строительный контур пока не подключает fluid-ингредиент " .. tostring(ingredient.name) .. ".")
        return "failed"
      end
      local ok, error_message = begin_acquisition(
        task, agent, ingredient.name, math.ceil(ingredient.amount * TEST_BATCHES), "ingredient")
      if not ok then TaskManager.fail(error_message); return "failed" end
      return "working"
    end
    if commissioning.entity.burner then
      local fuel = choose_fuel(task, agent, commissioning.entity.burner)
      if not fuel then
        TaskManager.fail("Не нашла доступное топливо для " .. commissioning.entity.name .. ".")
        return "failed"
      end
      local ok, error_message = begin_acquisition(task, agent, fuel, TEST_BATCHES, "fuel")
      if not ok then TaskManager.fail(error_message); return "failed" end
      return "working"
    end
    commissioning.state = "verifying"
    commissioning.verify_started_tick = game.tick
  end

  if commissioning.state == "verifying" then
    local output = commissioning.entity.get_inventory(defines.inventory.crafter_output)
    local output_count = output and output.get_item_count(commissioning.target_item) or 0
    local produced = production_total(
      commissioning.entity.force, commissioning.entity.surface, commissioning.target_item)
    if output_count > commissioning.baseline_output or produced > commissioning.baseline_production then
      local delta = math.max(
        output_count - commissioning.baseline_output,
        produced - commissioning.baseline_production)
      EventBus.emit("shortage_solution_verified", {
        task_id = task.id,
        target_item = commissioning.target_item,
        entity = commissioning.entity.name,
        recipe = commissioning.recipe.name,
        produced = delta,
        status = "working"
      })
      return "done"
    end
    if game.tick - commissioning.verify_started_tick > 1800 then
      TaskManager.fail("Новая машина не выпустила " .. commissioning.target_item .. " за 30 секунд; оставила её без разрушения для диагностики.")
      return "failed"
    end
  end
  return "working"
end

return Commissioning
