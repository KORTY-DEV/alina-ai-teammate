local State = require("scripts.core.state")
local Agent = require("scripts.agent.agent")
local EventBus = require("scripts.core.event_bus")
local Locale = require("scripts.core.locale")
local Identity = require("scripts.core.identity")
local ConstructionTransaction = require("scripts.construction.transaction")

local TaskManager = {}

local function autonomy_delay_ticks()
  -- Runtime autonomy is deterministic and light in playable mode, so she should
  -- look for the next job almost immediately instead of standing idle for minutes.
  return 180 -- 3 seconds
end

local function print_to_player(player_index, message)
  local player = game.get_player(player_index)
  if player and message and message ~= "" then
    Identity.print(player, Locale.message(message))
  end
end

local function finish_current(status, message)
  local root = State.ensure()
  local task = root.task.current
  if not task then return end
  if status == "completed" then
    ConstructionTransaction.commit(task)
  else
    local agent = root.agent and root.agent.entity or nil
    local rollback = ConstructionTransaction.rollback(task, agent, message)
    if rollback.preserved > 0 then
      message = (message or "Задача остановлена.") .. " Безопасно оставила "
        .. tostring(rollback.preserved) .. " уже изменённых или занятых объектов; существующую фабрику не трогала."
    end
  end
  for _, operation in ipairs(task.acquisition and task.acquisition.operations or {}) do
    if operation.temporary_recipe_set and operation.entity and operation.entity.valid
        and operation.entity.type == "assembling-machine" then
      local current = operation.entity.get_recipe()
      -- Respect a concurrent player edit: only undo the exact temporary recipe
      -- that Alina assigned herself.
      if current and current.name == operation.recipe then
        operation.entity.set_recipe(operation.original_recipe_name or nil)
      end
    end
    operation.temporary_recipe_set = nil
  end
  Agent.stop()
  Agent.park()
  task.status = status
  task.finished_tick = game.tick
  task.result = message
  EventBus.emit("task_finished", {
    task_id = task.id,
    task_type = task.type,
    status = status,
    result = message,
    resource = task.resource,
    product = task.product,
    gathered = task.gathered or 0
  })
  State.push_history(task)
  if status == "completed" and task.development_focus
      and (task.type == "expand_line" or task.type == "repair_power") then
    -- Development is a persistent operating mode. Completing one verified
    -- block means "choose the next useful block", not "stand still".
    root.autonomy.foundation_audit = nil
    root.autonomy.foundation_audit_tick = 0
    EventBus.emit("factory_development_change_verified", {
      task_id = task.id,
      task_type = task.type,
      result = message,
      development_continues = true
    })
  end
  if message and message ~= "" then
    root.autonomy.last_activity = message
  end
  if task.source == "autonomous" and task.type == "repair_power" and status ~= "completed" then
    -- A failed route must not monopolise autonomy on a large base with many
    -- stale or unreachable power warnings. Re-evaluate other work first.
    root.autonomy.power_retry_tick = game.tick + 36000
  end
  if task.source == "autonomous" and task.type == "expand_line" and status ~= "completed" then
    -- A collision or a player-owned object does not disappear three seconds
    -- later. Back off this product and let development choose another useful
    -- chain instead of submitting the identical all-or-nothing layout forever.
    local target_item = task.target_item or (task.expansion and task.expansion.target_item)
    if target_item then
      root.autonomy.item_cooldown[target_item] = math.max(
        root.autonomy.item_cooldown[target_item] or 0, game.tick + 18000)
    end
    local pending = root.autonomy.pending_development_candidate
    if pending and pending.candidate and pending.candidate.item == target_item then
      root.autonomy.pending_development_candidate = nil
    end
    EventBus.emit("autonomy_expansion_backoff_started", {
      task_id = task.id,
      target_item = target_item,
      retry_tick = target_item and root.autonomy.item_cooldown[target_item] or nil
    })
  end
  if task.source == "autonomous" and task.type == "maintain_loadout" and status ~= "completed" then
    -- Navigation, concurrent inventory edits and modded equipment rules may
    -- invalidate an otherwise affordable loadout choice after planning. Do
    -- not retry that exact choice every three seconds: move on to useful
    -- factory work and reconsider it after one in-game minute.
    root.autonomy.loadout_cooldown = root.autonomy.loadout_cooldown or {}
    local requirement = task.loadout or {}
    local cooldown_key = requirement.reserve_key or requirement.kind or requirement.item
    if cooldown_key then root.autonomy.loadout_cooldown[cooldown_key] = game.tick + 3600 end
    if requirement.kind == "construction_reserve" and requirement.reserve_key then
      root.autonomy.loadout_preferred = root.autonomy.loadout_preferred or {}
      root.autonomy.loadout_preferred[requirement.reserve_key] = nil
    end
  end
  root.task.current = nil
  if task.source == "autonomous" then
    if status == "completed" and task.target_item and not task.keep_autonomy_suppressed then
      root.autonomy.suppressed_items[task.target_item] = nil
    end
  end
  if root.autonomy.enabled ~= false and not root.paused then
    -- A rejected all-or-nothing development layout changed nothing, so it is
    -- safe to start selecting a different cooled candidate on the next pulse.
    -- Successful work and all other task types keep the normal quiet delay.
    local rapid_replan = task.source == "autonomous"
      and task.type == "expand_line" and status ~= "completed"
      and task.development_focus
    root.autonomy.next_tick = game.tick + (rapid_replan and 30 or autonomy_delay_ticks())
  end
  -- The panel already shows autonomous work. Chat is reserved for direct
  -- commands, safety questions and their final result.
  if task.source ~= "autonomous" or task.notify == true then
    print_to_player(task.player_index, message)
  end
end

function TaskManager.cancel(reason)
  finish_current("cancelled", reason or "Остановилась.")
end

function TaskManager.complete(message)
  finish_current("completed", message or "Готово.")
end

function TaskManager.fail(message)
  finish_current("failed", message or "Не получилось выполнить задачу.")
end

function TaskManager.pause()
  local root = State.ensure()
  root.paused = true
  Agent.stop()
  Agent.park()
end

function TaskManager.resume()
  local root = State.ensure()
  root.paused = false
  root.autonomy.enabled = true
  root.autonomy.next_tick = game.tick + 30
end

function TaskManager.current()
  return State.ensure().task.current
end

local function copy_position(position)
  return position and {x = position.x, y = position.y} or nil
end

local function compact_placement(row)
  if not row then return nil end
  return {
    name = row.name,
    entity_type = row.entity_type,
    position = copy_position(row.position),
    direction = row.direction
  }
end

-- Remote interfaces copy returned tables between mod script contexts. Returning
-- the live task used to copy hundreds of placement rows and path waypoints every
-- time a UI/test asked for status, causing a reproducible 0.8 s hitch on large
-- construction plans. Keep execution state private and expose a bounded snapshot.
function TaskManager.status_snapshot()
  local task = State.ensure().task.current
  if not task then return nil end
  local expansion = task.expansion
  local navigation = task.navigation
  local acquisition = task.acquisition
  local detour = navigation and navigation.belt_detour or nil
  local row = expansion and expansion.entities and expansion.entities[expansion.index or 1] or nil
  local operation = acquisition and acquisition.operations
    and acquisition.operations[acquisition.index or 1] or nil
  return {
    id = task.id,
    request_id = task.request_id,
    type = task.type,
    source = task.source,
    player_index = task.player_index,
    status = task.status,
    phase = task.phase,
    target_item = task.target_item,
    target_entity = task.target_entity,
    recipe = task.recipe,
    resource = task.resource,
    product = task.product,
    amount = task.amount,
    gathered = task.gathered,
    created_tick = task.created_tick,
    timeout_tick = task.timeout_tick,
    summary = task.summary,
    expansion = expansion and {
      physical_stage = expansion.physical_stage,
      index = expansion.index,
      physical_built = expansion.physical_built,
      entity_count = expansion.entities and #expansion.entities or 0,
      requirement_index = expansion.requirement_index,
      requirement_count = expansion.physical_requirements and #expansion.physical_requirements or 0,
      build_row = compact_placement(row),
      approach_position = copy_position(expansion.approach_position),
      source_position = copy_position(expansion.source_position),
      target_item = expansion.target_item,
      recipe = expansion.recipe
    } or nil,
    navigation = navigation and {
      state = navigation.state,
      purpose = navigation.purpose,
      goal = copy_position(navigation.goal),
      index = navigation.index,
      waypoint_count = navigation.waypoints and #navigation.waypoints or 0,
      waypoint = navigation.waypoints and copy_position(navigation.waypoints[navigation.index or 1]) or nil,
      next_waypoint = navigation.waypoints and copy_position(navigation.waypoints[(navigation.index or 1) + 1]) or nil,
      requested_tick = navigation.requested_tick,
      retries = navigation.retries,
      last_position = copy_position(navigation.last_position),
      last_movement_tick = navigation.last_movement_tick,
      waypoint_best_distance = navigation.waypoint_best_distance,
      waypoint_progress_tick = navigation.waypoint_progress_tick,
      belt_escape_was_active = navigation.belt_escape_was_active == true,
      belt_detour = detour and {
        phase = detour.phase,
        escape_direction = detour.escape_direction,
        started_tick = detour.started_tick,
        phase_started_tick = detour.phase_started_tick,
        escape_start_position = copy_position(detour.escape_start_position)
      } or nil
    } or nil,
    acquisition = acquisition and {
      item = acquisition.item,
      index = acquisition.index,
      operation_count = acquisition.operations and #acquisition.operations or 0,
      status = acquisition.status,
      operation = operation and {
        type = operation.type,
        item = operation.item,
        count = operation.count,
        recipe = operation.recipe,
        crafts = operation.crafts,
        position = copy_position(operation.position)
      } or nil
    } or nil
  }
end

function TaskManager.has_active_task()
  return State.ensure().task.current ~= nil
end

local function reject(root, message)
  root.metrics.plans_rejected = root.metrics.plans_rejected + 1
  root.bridge.status = "plan_rejected"
  return false, message
end

local function expected_product_amount(product)
  local amount = product.amount
  if not amount and product.amount_min and product.amount_max then
    amount = (product.amount_min + product.amount_max) / 2
  end
  return (amount or 1) * (product.probability or 1)
end

local function primary_item_product(prototype)
  local properties = prototype and prototype.mineable_properties or nil
  if not properties or not properties.minable or properties.required_fluid then return nil end

  local best = nil
  local best_amount = -1
  for _, product in ipairs(properties.products or {}) do
    if product.type == "item" and prototypes.item[product.name] then
      local amount = expected_product_amount(product)
      if amount > best_amount then
        best = product.name
        best_amount = amount
      end
    end
  end
  return best
end

local function validate_plan(plan)
  if type(plan) ~= "table" or plan.version ~= 1 then
    return false, "Неверная версия плана."
  end
  if type(plan.request_id) ~= "string" then
    return false, "У плана нет request_id."
  end
  if type(plan.actions) ~= "table" or #plan.actions > 1 then
    return false, "MVP принимает не более одного действия."
  end
  if type(plan.reply) ~= "string" or #plan.reply > 1000 then
    return false, "Некорректный ответ плана."
  end
  return true, nil
end

function TaskManager.submit_plan_json(json)
  local root = State.ensure()
  local plan = helpers.json_to_table(json)
  local ok, error_message = validate_plan(plan)
  if not ok then return reject(root, error_message) end

  local pending = root.pending_requests[plan.request_id]
  if not pending then
    return reject(root, "План не соответствует ожидающей команде.")
  end
  root.pending_requests[plan.request_id] = nil
  local source = pending.source or "direct_player"
  if source == "autonomous" and root.autonomy.pending_request_id == plan.request_id then
    root.autonomy.pending_request_id = nil
    root.autonomy.last_response_tick = game.tick
  end
  root.bridge.last_response_tick = game.tick
  root.bridge.status = "connected"

  if plan.requires_confirmation then
    root.confirmation = {
      plan = plan,
      pending = pending,
      player_index = pending.player_index,
      created_tick = game.tick
    }
    print_to_player(pending.player_index, plan.reply .. " Нужное действие ждёт подтверждения.")
    return true, "confirmation_required"
  end

  if #plan.actions == 0 then
    if source == "autonomous" then
      root.metrics.autonomy_noops = root.metrics.autonomy_noops + 1
      EventBus.emit("autonomy_noop", {request_id = plan.request_id, reply = plan.reply})
    else
      print_to_player(pending.player_index, plan.reply)
    end
    root.metrics.plans_accepted = root.metrics.plans_accepted + 1
    return true, "reply_only"
  end

  local action = plan.actions[1]
  if type(action) ~= "table" or type(action.args) ~= "table"
      or (action.type ~= "mine_resource" and action.type ~= "resolve_shortage"
        and action.type ~= "repair_power" and action.type ~= "continue_factory") then
    return reject(root, "Действие не входит в разрешённый набор MVP.")
  end

  if action.type == "continue_factory" then
    root.paused = false
    root.metrics.plans_accepted = root.metrics.plans_accepted + 1
    print_to_player(pending.player_index, plan.reply)
    root.autonomy.enabled = true
    root.autonomy.next_tick = game.tick + 30
    EventBus.emit("factory_development_enabled", {
      player_index = pending.player_index,
      autonomy_started = true,
      result = "scheduled"
    })
    return true, "autonomy_enabled"
  end


  if action.type == "repair_power" then
    local entity_name = action.args.entity
    local prototype = type(entity_name) == "string" and prototypes.entity[entity_name] or nil
    if not prototype or (prototype.type ~= "assembling-machine" and prototype.type ~= "furnace"
        and prototype.type ~= "mining-drill" and prototype.type ~= "lab") then
      return reject(root, "Целевой электрический потребитель отсутствует в активных прототипах.")
    end
    if root.task.current and source == "autonomous" then
      return reject(root, "Автономный план уступил уже активной задаче.")
    elseif root.task.current then
      TaskManager.cancel("Переключаюсь на вашу новую команду.")
    end
    local task_id = root.next_task_id
    root.next_task_id = task_id + 1
    root.task.current = {
      id = task_id,
      request_id = plan.request_id,
      type = "repair_power",
      source = source,
      player_index = pending.player_index,
      target_entity = entity_name,
      status = "active",
      phase = "planning_power_route",
      created_tick = game.tick,
      summary = "Продолжить питание к " .. entity_name
    }
    root.paused = false
    root.metrics.plans_accepted = root.metrics.plans_accepted + 1
    if source == "autonomous" then
      root.metrics.autonomy_actions = root.metrics.autonomy_actions + 1
      root.autonomy.last_action_tick = game.tick
    end
    print_to_player(pending.player_index, plan.reply)
    return true, "accepted"
  end

  if action.type == "resolve_shortage" then
    local item = action.args.item
    if type(item) ~= "string" or not prototypes.item[item] then
      return reject(root, "Материал отсутствует в активных прототипах игры.")
    end

    if root.task.current and source == "autonomous" then
      return reject(root, "Автономный план уступил уже активной задаче.")
    elseif root.task.current then
      TaskManager.cancel("Переключаюсь на вашу новую команду.")
    end
    local task_id = root.next_task_id
    root.next_task_id = task_id + 1
    root.task.current = {
      id = task_id,
      request_id = plan.request_id,
      type = "resolve_shortage",
      source = source,
      player_index = pending.player_index,
      status = "active",
      phase = "diagnosing",
      target_item = item,
      created_tick = game.tick,
      summary = "Разобраться с нехваткой " .. item
    }
    root.paused = false
    root.metrics.plans_accepted = root.metrics.plans_accepted + 1
    if source == "autonomous" then
      root.metrics.autonomy_actions = root.metrics.autonomy_actions + 1
      root.autonomy.last_action_tick = game.tick
    end
    print_to_player(pending.player_index, plan.reply)
    return true, "accepted"
  end

  local resource = action.args.resource
  local amount = action.args.amount
  local prototype = type(resource) == "string" and prototypes.entity[resource] or nil
  if not prototype or prototype.type ~= "resource" then
    return reject(root, "Ресурс отсутствует в активных прототипах игры.")
  end
  local product = primary_item_product(prototype)
  if not product then
    return reject(root, "Этот ресурс нельзя безопасно добыть персонажем в предметный инвентарь.")
  end
  if type(amount) ~= "number" or amount < 1 or amount > 100 then
    return reject(root, "Количество ресурса вне безопасного диапазона 1..100.")
  end

  if root.task.current and source == "autonomous" then
    return reject(root, "Автономный план уступил уже активной задаче.")
  elseif root.task.current then
    TaskManager.cancel("Переключаюсь на вашу новую команду.")
  end

  local task_id = root.next_task_id
  root.next_task_id = task_id + 1
  root.task.current = {
    id = task_id,
    request_id = plan.request_id,
    type = "mine_resource",
    source = source,
    player_index = pending.player_index,
    status = "active",
    phase = "seeking",
    resource = resource,
    product = product,
    delivery = source == "autonomous" and "keep" or "player",
    amount = math.floor(amount),
    gathered = 0,
    initial_count = nil,
    target = nil,
    created_tick = game.tick,
    summary = "Добыть " .. math.floor(amount) .. " × " .. resource
  }
  root.paused = false
  root.metrics.plans_accepted = root.metrics.plans_accepted + 1
  if source == "autonomous" then
    root.metrics.autonomy_actions = root.metrics.autonomy_actions + 1
    root.autonomy.last_action_tick = game.tick
  end
  print_to_player(pending.player_index, plan.reply)
  return true, "accepted"
end

local function prepare_direct_or_autonomous(source)
  local root = State.ensure()
  if root.task.current then
    if source == "autonomous" then return nil, "task_active" end
    TaskManager.cancel("Переключаюсь на вашу новую команду.")
  end
  root.paused = false
  root.autonomy.enabled = true
  return root
end

function TaskManager.start_repair_power(player_index, entity_or_name, source)
  local root, err = prepare_direct_or_autonomous(source or "autonomous")
  if not root then return false, err end
  local target = type(entity_or_name) ~= "string" and entity_or_name or nil
  local entity_name = target and target.valid and target.name or entity_or_name
  local prototype = type(entity_name) == "string" and prototypes.entity[entity_name] or nil
  if not prototype then return false, "entity_missing" end
  local task_id = root.next_task_id
  root.next_task_id = task_id + 1
  root.task.current = {
    id = task_id, request_id = "local-" .. task_id, type = "repair_power",
    source = source or "autonomous", player_index = player_index, target_entity = entity_name,
    target_unit_number = target and target.valid and target.unit_number or nil,
    target_surface_index = target and target.valid and target.surface.index or nil,
    target_position = target and target.valid and {x = target.position.x, y = target.position.y} or nil,
    development_focus = root.autonomy.development_focus == true,
    status = "active", phase = "planning_power_route", created_tick = game.tick,
    summary = "Восстановить питание " .. entity_name
  }
  root.metrics.autonomy_actions = root.metrics.autonomy_actions + ((source == "autonomous") and 1 or 0)
  root.autonomy.last_action_tick = game.tick
  return true, "accepted"
end

function TaskManager.start_resolve_shortage(player_index, item, source)
  local root, err = prepare_direct_or_autonomous(source or "autonomous")
  if not root then return false, err end
  if type(item) ~= "string" or not prototypes.item[item] then return false, "item_missing" end
  local task_id = root.next_task_id
  root.next_task_id = task_id + 1
  root.task.current = {
    id = task_id, request_id = "local-" .. task_id, type = "resolve_shortage",
    source = source or "autonomous", player_index = player_index, status = "active",
    phase = "diagnosing", target_item = item, created_tick = game.tick,
    summary = "Разобраться с " .. item
  }
  root.metrics.autonomy_actions = root.metrics.autonomy_actions + ((source == "autonomous") and 1 or 0)
  root.autonomy.last_action_tick = game.tick
  if source == "autonomous" then
    root.autonomy.item_cooldown[item] = game.tick + 3600 -- do not hand-feed same bottleneck every few seconds
  end
  return true, "accepted"
end

function TaskManager.start_mining(player_index, resource, amount, source)
  local root, err = prepare_direct_or_autonomous(source or "direct_player")
  if not root then return false, err end
  local prototype = type(resource) == "string" and prototypes.entity[resource] or nil
  if not prototype or prototype.type ~= "resource" then return false, "resource_missing" end
  local product = primary_item_product(prototype)
  if not product then return false, "resource_not_hand_mineable" end
  amount = math.max(1, math.min(100, math.floor(tonumber(amount) or 25)))
  local task_id = root.next_task_id
  root.next_task_id = task_id + 1
  root.task.current = {
    id = task_id, request_id = "local-" .. task_id, type = "mine_resource",
    source = source or "direct_player", player_index = player_index, status = "active",
    phase = "seeking", resource = resource, product = product,
    delivery = (source == "autonomous") and "keep" or "player",
    amount = amount, gathered = 0, created_tick = game.tick,
    summary = "Добыть " .. amount .. " × " .. resource
  }
  return true, "accepted"
end

function TaskManager.start_line_expansion(player_index, expansion, source)
  local root, err = prepare_direct_or_autonomous(source or "autonomous")
  if not root then return false, err end
  if type(expansion) ~= "table" or type(expansion.entities) ~= "table" or #expansion.entities == 0 then
    return false, "invalid_expansion"
  end
  local task_id = root.next_task_id
  root.next_task_id = task_id + 1
  expansion.index = 1
  expansion.physical_stage = nil
  local remote = expansion.remote == true
  root.task.current = {
    id = task_id, request_id = "local-" .. task_id, type = "expand_line",
    source = source or "autonomous", player_index = player_index, status = "active",
    development_focus = root.autonomy.development_focus == true,
    target_item = expansion.target_item,
    recipe = expansion.recipe,
    phase = remote and "placing_ghosts" or "preparing_physical_module",
    expansion = expansion, created_tick = game.tick,
    summary = (remote and "Удалённо размечаю линию " or "Готовлю физическое расширение ")
      .. tostring(expansion.target_item or expansion.recipe),
    notify = (source or "autonomous") ~= "autonomous"
  }
  root.metrics.autonomy_actions = root.metrics.autonomy_actions + 1
  root.autonomy.last_action_tick = game.tick
  local player = game.get_player(player_index)
  if player and (source or "autonomous") ~= "autonomous" then
    if remote then
      Identity.print(player, {"", "Вижу повторяющийся автоматизированный модуль ",
        Locale.item(expansion.target_item or expansion.recipe),
        ". Добавляю его продолжение через строительную сеть."})
    else
      Identity.print(player, {"", "Вижу повторяющийся автоматизированный модуль ",
        Locale.item(expansion.target_item or expansion.recipe),
        ". Сначала соберу все детали, затем физически дострою подключённую секцию."})
    end
  end
  return true, "accepted"
end

function TaskManager.start_machine_upgrade(player_index, upgrade, source)
  local root, err = prepare_direct_or_autonomous(source or "autonomous")
  if not root then return false, err end
  if type(upgrade) ~= "table" or type(upgrade.entity_unit_number) ~= "number"
      or type(upgrade.old_name) ~= "string" or type(upgrade.new_name) ~= "string"
      or type(upgrade.old_item) ~= "string" or type(upgrade.new_item) ~= "string"
      or not prototypes.entity[upgrade.old_name] or not prototypes.entity[upgrade.new_name]
      or not prototypes.item[upgrade.old_item] or not prototypes.item[upgrade.new_item] then
    return false, "invalid_machine_upgrade"
  end
  local task_id = root.next_task_id
  root.next_task_id = task_id + 1
  upgrade.stage = "acquiring"
  root.task.current = {
    id = task_id,
    request_id = "local-" .. task_id,
    type = "upgrade_machine",
    source = source or "autonomous",
    player_index = player_index,
    status = "active",
    phase = "acquiring_upgrade",
    upgrade = upgrade,
    target_item = upgrade.target_item,
    created_tick = game.tick,
    summary = "Подготовить рациональное улучшение " .. upgrade.old_name
  }
  root.metrics.autonomy_actions = root.metrics.autonomy_actions + ((source == "autonomous") and 1 or 0)
  root.autonomy.last_action_tick = game.tick
  EventBus.emit("machine_upgrade_started", {
    task_id = task_id,
    from = upgrade.old_name,
    to = upgrade.new_name,
    target_item = upgrade.target_item,
    expected_gain = upgrade.expected_gain
  })
  return true, "accepted"
end

function TaskManager.start_maintain_loadout(player_index, requirement, source)
  local root, err = prepare_direct_or_autonomous(source or "autonomous")
  if not root then return false, err end
  if type(requirement) ~= "table" or type(requirement.item) ~= "string"
      or not prototypes.item[requirement.item] or type(requirement.count) ~= "number"
      or requirement.count < 1 or requirement.count > 200 then
    return false, "invalid_loadout_requirement"
  end
  local task_id = root.next_task_id
  root.next_task_id = task_id + 1
  root.task.current = {
    id = task_id,
    request_id = "local-" .. task_id,
    type = "maintain_loadout",
    source = source or "autonomous",
    player_index = player_index,
    status = "active",
    phase = "planning_loadout",
    loadout = requirement,
    created_tick = game.tick,
    summary = "Подготовить личный запас " .. requirement.item
  }
  root.metrics.autonomy_actions = root.metrics.autonomy_actions + ((source == "autonomous") and 1 or 0)
  root.autonomy.last_action_tick = game.tick
  return true, "accepted"
end

function TaskManager.confirm_pending(player_index)
  local root = State.ensure()
  local confirmation = root.confirmation
  if not confirmation then return false, "nothing_to_confirm" end
  if player_index and confirmation.player_index and player_index ~= confirmation.player_index then
    return false, "wrong_player"
  end

  local plan = confirmation.plan
  local pending = confirmation.pending or {
    player_index = confirmation.player_index,
    created_tick = game.tick,
    command = "confirmed action",
    source = "direct_player"
  }
  root.confirmation = nil
  plan.requires_confirmation = false
  root.pending_requests[plan.request_id] = pending
  return TaskManager.submit_plan_json(helpers.table_to_json(plan))
end

function TaskManager.reject_pending(player_index)
  local root = State.ensure()
  local confirmation = root.confirmation
  if not confirmation then return false, "nothing_to_reject" end
  if player_index and confirmation.player_index and player_index ~= confirmation.player_index then
    return false, "wrong_player"
  end
  local owner = confirmation.player_index
  root.confirmation = nil
  root.bridge.status = "connected"
  print_to_player(owner, "Хорошо, это действие не выполняю.")
  return true, "rejected"
end

return TaskManager
