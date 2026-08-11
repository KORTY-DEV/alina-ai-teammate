local TaskManager = require("scripts.tasks.manager")
local Conflict = require("scripts.conflict.manager")
local EventBus = require("scripts.core.event_bus")
local Acquisition = require("scripts.executor.acquisition")
local Navigation = require("scripts.navigation.navigation")
local Agent = require("scripts.agent.agent")
local State = require("scripts.core.state")
local WorldModel = require("scripts.sensors.world_model")
local SitePolicy = require("scripts.construction.site_policy")
local ConstructionTransaction = require("scripts.construction.transaction")

local LineExpander = {}
local Identity = require("scripts.core.identity")

local GHOSTS_PER_TICK = 3
-- Dense rows can place dozens of belts/pipes while Alina is standing in reach.
-- Creating/configuring one entity every simulation tick caused visible frame
-- hitches on the target PC. Thirty physical placements per second remain much
-- faster than character travel while bounding the Lua/entity-creation spike.
local PHYSICAL_BUILD_INTERVAL = 2
local PHYSICAL_PREFLIGHT_ROWS_PER_TICK = 12
local MAX_PHYSICAL_TREE_CLEARANCE = 128

local function distance_squared(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end

local function collision_boxes_overlap(first_position, first_box, second_position, second_box)
  if not first_box or not second_box then return false end
  local first_left = first_position.x + first_box.left_top.x
  local first_right = first_position.x + first_box.right_bottom.x
  local first_top = first_position.y + first_box.left_top.y
  local first_bottom = first_position.y + first_box.right_bottom.y
  local second_left = second_position.x + second_box.left_top.x
  local second_right = second_position.x + second_box.right_bottom.x
  local second_top = second_position.y + second_box.left_top.y
  local second_bottom = second_position.y + second_box.right_bottom.y
  return first_left < second_right and first_right > second_left
    and first_top < second_bottom and first_bottom > second_top
end

local BUILD_PRIORITY = {
  ["transport-belt"] = 10,
  ["underground-belt"] = 11,
  splitter = 12,
  loader = 13,
  ["loader-1x1"] = 13,
  pipe = 20,
  ["pipe-to-ground"] = 21,
  pump = 22,
  ["electric-pole"] = 30,
  inserter = 40,
  container = 50,
  ["logistic-container"] = 50,
  ["linked-container"] = 50,
  ["storage-tank"] = 50,
  beacon = 60,
  ["mining-drill"] = 80,
  furnace = 90,
  ["assembling-machine"] = 90,
  ["rocket-silo"] = 90
}

-- Fluid blocks must not erect hundreds of colliding pipes before Alina has
-- placed the machines and tanks behind them. The final pipe pass can be built
-- from reach and, once complete, requires no later walk through the manifold.
local FLUID_BUILD_PRIORITY = {
  ["electric-pole"] = 10,
  ["mining-drill"] = 20,
  ["offshore-pump"] = 20,
  ["assembling-machine"] = 20,
  furnace = 20,
  ["rocket-silo"] = 20,
  ["storage-tank"] = 30,
  container = 40,
  ["logistic-container"] = 40,
  ["linked-container"] = 40,
  inserter = 50,
  pump = 80,
  pipe = 90,
  ["pipe-to-ground"] = 90
}

local function matching_present(surface, row, force)
  local entities = surface.find_entities_filtered({
    position = row.position,
    radius = 0.22,
    name = row.name,
    force = force,
    limit = 8
  })
  for _, entity in ipairs(entities) do
    if entity.valid and entity.direction == row.direction then return entity end
  end
  return nil
end

local function matching_ghost(surface, row, force)
  local ghosts = surface.find_entities_filtered({
    position = row.position,
    radius = 0.22,
    type = "entity-ghost",
    force = force,
    limit = 8
  })
  for _, ghost in ipairs(ghosts) do
    if ghost.valid and ghost.ghost_name == row.name and ghost.direction == row.direction then return ghost end
  end
  return nil
end

local function construction_network(surface, force, position)
  return SitePolicy.construction_network(surface, force, position)
end

local function row_collision_area(row)
  local prototype = prototypes.entity[row.name]
  local box = prototype and prototype.collision_box or nil
  if not box then return nil end
  return {
    {row.position.x + box.left_top.x, row.position.y + box.left_top.y},
    {row.position.x + box.right_bottom.x, row.position.y + box.right_bottom.y}
  }
end

local function tree_obstacles(surface, row)
  return SitePolicy.tree_obstacles(surface, row.name, row.position)
end

local function request_tree_clearance(task, agent, plan)
  local pending, seen, clearance_rows = {}, {}, {}
  local available_robots, all_robots = 0, 0
  for _, row in ipairs(plan.entities) do
    if Conflict.is_blocked(agent.surface.index, row.position, task.source) then
      return false, "player_conflict"
    end
    if not matching_present(agent.surface, row, agent.force)
        and not agent.surface.can_place_entity({name = row.name, position = row.position,
          direction = row.direction, force = agent.force}) then
      local trees = tree_obstacles(agent.surface, row)
      if #trees > 0 then
        local network = construction_network(agent.surface, agent.force, row.position)
        if not network then return false, "no_construction_network" end
        available_robots = math.max(available_robots, network.available_construction_robots or 0)
        all_robots = math.max(all_robots, network.all_construction_robots or 0)
        clearance_rows[#clearance_rows + 1] = {
          name = row.name,
          position = {x = row.position.x, y = row.position.y},
          direction = row.direction
        }
        for _, tree in ipairs(trees) do
          local key = tree.unit_number or (tree.name .. ":" .. tree.position.x .. ":" .. tree.position.y)
          if tree.valid and not seen[key] then
            seen[key] = true
            pending[#pending + 1] = tree
          end
        end
      end
    end
  end
  if #pending == 0 then return false, "no_trees" end

  local requested = 0
  for _, tree in ipairs(pending) do
    if tree.valid then
      local marked_ok, marked = pcall(function() return tree.to_be_deconstructed(agent.force) end)
      local ordered = marked_ok and marked == true
      if not ordered then
        local ok, result = pcall(function()
          return tree.order_deconstruction(agent.force, task.player_index)
        end)
        ordered = ok and result == true
      end
      if ordered then requested = requested + 1 end
    end
  end
  if requested == 0 then return false, "deconstruction_rejected" end

  plan.physical_stage = "clearing_trees"
  plan.tree_clearance_rows = clearance_rows
  task.phase = "clearing_trees"
  task.summary = "Строительные дроны расчищают место для " .. tostring(plan.target_item or plan.recipe)
  task.tree_clearance_check_tick = game.tick + 60
  task.tree_clearance_timeout_tick = game.tick + 7200
  EventBus.emit("construction_tree_clearance_requested", {
    task_id = task.id,
    trees = requested,
    sites = #clearance_rows,
    available_robots = available_robots,
    all_robots = all_robots
  })
  return true, "requested"
end

local function source_entity(row, surface, force)
  local source_id = tonumber(row.source_unit_number)
  local source = source_id and game.get_entity_by_unit_number(source_id) or nil
  if source and source.valid then return source end
  if not surface or not row.source_position then return nil end
  local candidates = surface.find_entities_filtered({
    position = row.source_position,
    radius = 0.22,
    name = row.name,
    force = force,
    limit = 8
  })
  for _, entity in ipairs(candidates) do
    if entity.valid and entity.direction == row.direction then return entity end
  end
  return nil
end

local function copy_source_settings(target, row)
  local source = source_entity(row, target and target.valid and target.surface or nil,
    target and target.valid and target.force or nil)
  if not source or not source.valid or not target or not target.valid then return false end
  local ok = pcall(function() target.copy_settings(source) end)
  return ok
end

local function place_ghost(task, row, surface, force)
  if Conflict.is_blocked(surface.index, row.position, task.source) then
    return false, "Игрок работает в точке расширения; уступаю этот участок."
  end
  if matching_present(surface, row, force) or matching_ghost(surface, row, force) then
    return true, "already_present"
  end
  if not construction_network(surface, force, row.position) then
    return false, "Точка расширения больше не покрывается строительными дронами."
  end
  if not surface.can_place_entity({
      name = row.name,
      position = row.position,
      direction = row.direction,
      force = force
    }) then
    return false, "Место для продолжения автоматизированного модуля уже занято."
  end

  local ghost = surface.create_entity({
    name = "entity-ghost",
    inner_name = row.name,
    position = row.position,
    direction = row.direction,
    force = force,
    tags = {
      alina_clone = true,
      source_unit_number = row.source_unit_number,
      source_position = row.source_position,
      source_name = row.name,
      source_direction = row.direction,
      task_id = task.id
    }
  })
  if not ghost then return false, "Factorio не создала призрак расширения." end
  ConstructionTransaction.record_ghost(task, ghost)
  copy_source_settings(ghost, row)
  return true, "ghost_created"
end

local function placement_item(row)
  local prototype = prototypes.entity[row.name]
  local placement = prototype and prototype.items_to_place_this or nil
  if not placement or #placement == 0 then return nil end
  local candidates = {}
  for _, item in ipairs(placement) do
    if prototypes.item[item.name] then
      candidates[#candidates + 1] = {name = item.name, count = item.count or 1}
    end
  end
  table.sort(candidates, function(a, b)
    if a.count == b.count then return a.name < b.name end
    return a.count < b.count
  end)
  return candidates[1]
end

local function row_less(a, b)
  local pa = BUILD_PRIORITY[a.entity_type] or 70
  local pb = BUILD_PRIORITY[b.entity_type] or 70
  if pa ~= pb then return pa < pb end
  if a.position.y ~= b.position.y then return a.position.y < b.position.y end
  if a.position.x ~= b.position.x then return a.position.x < b.position.x end
  return a.name < b.name
end

local function physical_order_less(origin, preserve_belt_order, preserve_plan_order, fluid_plan, a, b)
  -- Compact planners can provide a dependency-safe boustrophedon sequence.
  -- Re-sorting that sequence by prototype type recreates a chest/machine/pole
  -- saw-tooth and multiplies physical travel, so keep the explicit order.
  if preserve_plan_order then
    local aphase, bphase = a.construction_phase or 1, b.construction_phase or 1
    if aphase ~= bphase then return aphase < bphase end
    return (a.plan_order or 0) < (b.plan_order or 0)
  end
  local priorities = fluid_plan and FLUID_BUILD_PRIORITY or BUILD_PRIORITY
  local pa = priorities[a.entity_type] or 70
  local pb = priorities[b.entity_type] or 70
  if pa ~= pb then return pa < pb end
  if preserve_belt_order and pa == BUILD_PRIORITY["transport-belt"] then
    return (a.plan_order or 0) < (b.plan_order or 0)
  end
  if fluid_plan and pa >= (FLUID_BUILD_PRIORITY.pipe or 90) then
    local ar, br = a.fluid_route_id or math.huge, b.fluid_route_id or math.huge
    if ar ~= br then return ar < br end
    -- Input routes are built source -> machine so Alina follows material flow
    -- into the still-open production block. Output drains are built tank ->
    -- machine so she likewise finishes inside the open block. This avoids
    -- crossing a completed pipe wall merely to start the next segment.
    local as, bs = a.fluid_route_step or 0, b.fluid_route_step or 0
    if as ~= bs then
      if a.fluid_route_build_forward == true then return as < bs end
      return as > bs
    end
    return (a.plan_order or 0) < (b.plan_order or 0)
  end
  local adx, ady = a.position.x - origin.x, a.position.y - origin.y
  local bdx, bdy = b.position.x - origin.x, b.position.y - origin.y
  local ad = adx * adx + ady * ady
  local bd = bdx * bdx + bdy * bdy
  if ad ~= bd then return ad > bd end
  return row_less(a, b)
end

local function projected_inventory_slots(agent, requirements)
  local main = agent.get_inventory(defines.inventory.character_main)
  if not main then return nil, nil, nil end
  local used = #main - main.count_empty_stacks()
  local projected = used
  for name, required in pairs(requirements) do
    local prototype = prototypes.item[name]
    if prototype then
      local stack = math.max(1, prototype.stack_size or 1)
      local present = main.get_item_count(name)
      local present_slots = math.ceil(present / stack)
      local required_slots = math.ceil(math.max(present, required) / stack)
      projected = projected + math.max(0, required_slots - present_slots)
    end
  end
  return projected, math.max(1, math.floor(#main * 0.70)), #main
end

local function prepare_physical(task, agent, plan)
  local clearing = request_tree_clearance(task, agent, plan)
  if clearing then return true, "clearing_trees" end
  local rows = {}
  local requirements = {}
  for plan_order, row in ipairs(plan.entities) do
    row.plan_order = plan_order
    if not matching_present(agent.surface, row, agent.force) then
      if Conflict.is_blocked(agent.surface.index, row.position, task.source) then
        return false, "Игрок занял участок физического расширения; уступаю его."
      end
      if not agent.surface.can_place_entity({
           name = row.name,
           position = row.position,
           direction = row.direction,
           force = agent.force
         }) then
        local blockers = {}
        local foreign_blocker = false
        local area = row_collision_area(row)
        local vehicle = agent.vehicle and agent.vehicle.valid and agent.vehicle or nil
        local owned_legs = {}
        if vehicle and vehicle.type == "spider-vehicle" then
          local ok, legs = pcall(function() return vehicle.get_spider_legs() end)
          if ok then for _, leg in ipairs(legs or {}) do owned_legs[leg] = true end end
        end
        for _, blocker in ipairs(area and agent.surface.find_entities_filtered({area = area, limit = 16}) or {}) do
          if blocker.valid then
            blockers[#blockers + 1] = blocker.name .. "@"
              .. string.format("%.1f,%.1f", blocker.position.x, blocker.position.y)
            if blocker ~= agent and blocker ~= vehicle and not owned_legs[blocker] then
              foreign_blocker = true
            end
          end
        end
        -- Alina herself (or her owned Spidertron/legs) is a temporary blocker;
        -- build_next has a bounded reposition path for exactly this case. Any
        -- unrelated entity still invalidates the full module before acquisition.
        if foreign_blocker or #blockers == 0 then
          return false, "Точка полного модуля для " .. row.name .. " ("
            .. string.format("%.1f,%.1f", row.position.x, row.position.y) .. ") занята: "
            .. table.concat(blockers, ", ") .. "; частичное строительство не начинаю."
        end
      end
      local item = placement_item(row)
      if not item then return false, "Для " .. row.name .. " нет доступного предмета размещения." end
      if not row.bootstrap and not source_entity(row, agent.surface, agent.force) then
        return false, "Исходный элемент шаблона " .. row.name .. " исчез."
      end
      row.placement_item = item.name
      row.placement_count = item.count
      requirements[item.name] = (requirements[item.name] or 0) + item.count
      if row.fuel and row.fuel.name and (row.fuel.count or 0) > 0 then
        requirements[row.fuel.name] = (requirements[row.fuel.name] or 0) + row.fuel.count
      end
      for _, stack in ipairs(row.contents or {}) do
        if stack.name and (stack.count or 0) > 0 then
          requirements[stack.name] = (requirements[stack.name] or 0) + stack.count
        end
      end
      for _, stack in ipairs(row.modules or {}) do
        if stack.name and (stack.count or 0) > 0 then
          requirements[stack.name] = (requirements[stack.name] or 0) + stack.count
        end
      end
      rows[#rows + 1] = row
    end
  end

  if #rows == 0 then return true, "already_present" end
  local projected_slots, slot_limit, total_slots = projected_inventory_slots(agent, requirements)
  if not projected_slots then return false, "Основной инвентарь Алины недоступен." end
  if projected_slots > slot_limit then
    return false, "Полный комплект модуля занял бы " .. projected_slots .. " слотов из " .. total_slots
      .. "; безопасный предел 70% равен " .. slot_limit .. ". Сначала нужно разгрузить инвентарь."
  end
  local build_origin = {x = agent.position.x, y = agent.position.y}
  local preserve_belt_order = (plan.route_tiles or 0) > 0
  local preserve_plan_order = plan.construction_lane_sweep == true
  table.sort(rows, function(a, b)
    return physical_order_less(build_origin, preserve_belt_order, preserve_plan_order,
      plan.fluid_bootstrap == true, a, b)
  end)
  local requirement_rows = {}
  for name, count in pairs(requirements) do requirement_rows[#requirement_rows + 1] = {name = name, count = count} end
  table.sort(requirement_rows, function(a, b) return a.name < b.name end)
  plan.entities = rows
  plan.physical_requirements = requirement_rows
  plan.requirement_index = 1
  plan.index = 1
  plan.physical_built = 0
  plan.physical_stage = "acquiring"
  task.phase = "acquiring_module_items"
  task.summary = "Собираю всё для модуля " .. tostring(plan.target_item or plan.recipe)
  EventBus.emit("line_expansion_physical_prepared", {
    task_id = task.id,
    target_item = plan.target_item,
    entities = #rows,
    item_kinds = #requirement_rows,
    projected_inventory_slots = projected_slots,
    inventory_slot_limit = slot_limit
  })
  return true, "prepared"
end

local function preflight_physical(task, agent, plan)
  local state = plan.physical_preflight
  if not state then
    state = {
      index = 1,
      rows = {},
      requirements = {},
      trees = {},
      tree_seen = {},
      clearance_rows = {},
      available_robots = 0,
      all_robots = 0,
      requires_physical_tree_clearance = false
    }
    plan.physical_preflight = state
    task.phase = "preparing_physical_module"
    task.summary = "Проверяю весь модуль перед строительством "
      .. tostring(plan.target_item or plan.recipe)
  end

  local last = math.min(#plan.entities, state.index + PHYSICAL_PREFLIGHT_ROWS_PER_TICK - 1)
  for plan_order = state.index, last do
    local row = plan.entities[plan_order]
    row.plan_order = plan_order
    if not matching_present(agent.surface, row, agent.force) then
      if Conflict.is_blocked(agent.surface.index, row.position, task.source) then
        return false, "Игрок занял участок модуля; уступаю его."
      end
      if not agent.surface.can_place_entity({
          name = row.name,
          position = row.position,
          direction = row.direction,
          force = agent.force
        }) then
        local trees = tree_obstacles(agent.surface, row)
        if #trees > 0 then
          local network = construction_network(agent.surface, agent.force, row.position)
          if network then
            state.available_robots = math.max(state.available_robots,
              network.available_construction_robots or 0)
            state.all_robots = math.max(state.all_robots,
              network.all_construction_robots or 0)
          else
            state.requires_physical_tree_clearance = true
          end
          state.clearance_rows[#state.clearance_rows + 1] = {
            name = row.name,
            position = {x = row.position.x, y = row.position.y},
            direction = row.direction
          }
          for _, tree in ipairs(trees) do
            local key = tree.unit_number or (tree.name .. ":" .. tree.position.x .. ":" .. tree.position.y)
            if tree.valid and not state.tree_seen[key] then
              state.tree_seen[key] = true
              state.trees[#state.trees + 1] = tree
            end
          end
        else
          local blockers = {}
          local foreign_blocker = false
          local area = row_collision_area(row)
          local vehicle = agent.vehicle and agent.vehicle.valid and agent.vehicle or nil
          local owned_legs = {}
          if vehicle and vehicle.type == "spider-vehicle" then
            local ok, legs = pcall(function() return vehicle.get_spider_legs() end)
            if ok then for _, leg in ipairs(legs or {}) do owned_legs[leg] = true end end
          end
          for _, blocker in ipairs(area and agent.surface.find_entities_filtered({area = area, limit = 16}) or {}) do
            if blocker.valid then
              blockers[#blockers + 1] = blocker.name .. "@"
                .. string.format("%.1f,%.1f", blocker.position.x, blocker.position.y)
              if blocker ~= agent and blocker ~= vehicle and not owned_legs[blocker] then
                foreign_blocker = true
              end
            end
          end
          if foreign_blocker or #blockers == 0 then
            return false, "Точка полного модуля для " .. row.name .. " ("
              .. string.format("%.1f,%.1f", row.position.x, row.position.y) .. ") занята: "
              .. table.concat(blockers, ", ") .. "; частичное строительство не начинаю."
          end
        end
      end

      local item = placement_item(row)
      if not item then return false, "Для " .. row.name .. " нет доступного предмета размещения." end
      if not row.bootstrap and not source_entity(row, agent.surface, agent.force) then
        return false, "Исходный элемент шаблона " .. row.name .. " исчез."
      end
      row.placement_item = item.name
      row.placement_count = item.count
      state.requirements[item.name] = (state.requirements[item.name] or 0) + item.count
      if row.fuel and row.fuel.name and (row.fuel.count or 0) > 0 then
        state.requirements[row.fuel.name] = (state.requirements[row.fuel.name] or 0) + row.fuel.count
      end
      for _, stack in ipairs(row.contents or {}) do
        if stack.name and (stack.count or 0) > 0 then
          state.requirements[stack.name] = (state.requirements[stack.name] or 0) + stack.count
        end
      end
      for _, stack in ipairs(row.modules or {}) do
        if stack.name and (stack.count or 0) > 0 then
          state.requirements[stack.name] = (state.requirements[stack.name] or 0) + stack.count
        end
      end
      state.rows[#state.rows + 1] = row
    end
  end
  state.index = last + 1
  if state.index <= #plan.entities then return true, "working" end

  if #state.trees > 0 then
    if state.requires_physical_tree_clearance or state.all_robots <= 0 then
      -- A tree that does not overlap a planned entity can still seal the only
      -- walking approach to a directly blocking tree. Add one bounded ring of
      -- neighbours for physical clearance only; robots do not need this path.
      local directly_blocking = #state.trees
      for index = 1, directly_blocking do
        local tree = state.trees[index]
        if tree and tree.valid then
          for _, neighbour in ipairs(SitePolicy.natural_obstacles_near(
              agent.surface, tree.position, 3, 16)) do
            local key = neighbour.unit_number
              or (neighbour.name .. ":" .. neighbour.position.x .. ":" .. neighbour.position.y)
            if neighbour.valid and not state.tree_seen[key] then
              state.tree_seen[key] = true
              state.trees[#state.trees + 1] = neighbour
            end
          end
        end
      end
      if #state.trees > MAX_PHYSICAL_TREE_CLEARANCE then
        return false, "Для полного модуля нужно расчистить " .. tostring(#state.trees)
          .. " деревьев; без строительных дронов это слишком большая ручная расчистка."
      end
      local targets = {}
      for _, tree in ipairs(state.trees) do
        if tree.valid then
          targets[#targets + 1] = {
            unit_number = tree.unit_number,
            name = tree.name,
            surface_index = tree.surface.index,
            position = {x = tree.position.x, y = tree.position.y}
          }
        end
      end
      table.sort(targets, function(a, b)
        local da, db = distance_squared(agent.position, a.position), distance_squared(agent.position, b.position)
        if da ~= db then return da < db end
        if a.position.x ~= b.position.x then return a.position.x < b.position.x end
        return a.position.y < b.position.y
      end)
      plan.tree_clearance_targets = targets
      plan.tree_clearance_index = 1
      plan.physical_preflight = nil
      plan.physical_stage = "clearing_trees_physical"
      task.navigation = nil
      task.phase = "clearing_trees"
      task.summary = "Физически расчищаю точное место постройки"
      EventBus.emit("construction_tree_clearance_physical_started", {
        task_id = task.id,
        trees = #targets,
        sites = #state.clearance_rows
      })
      return true, "clearing_trees_physical"
    end
    local requested = 0
    for _, tree in ipairs(state.trees) do
      if tree.valid then
        local marked_ok, marked = pcall(function() return tree.to_be_deconstructed(agent.force) end)
        local ordered = marked_ok and marked == true
        if not ordered then
          local ok, result = pcall(function()
            return tree.order_deconstruction(agent.force, task.player_index)
          end)
          ordered = ok and result == true
        end
        if ordered then requested = requested + 1 end
      end
    end
    if requested == 0 then return false, "Строительные дроны не приняли деревья на расчистку." end
    plan.tree_clearance_rows = state.clearance_rows
    plan.physical_preflight = nil
    plan.physical_stage = "clearing_trees"
    task.phase = "clearing_trees"
    task.summary = "Строительные дроны расчищают место для "
      .. tostring(plan.target_item or plan.recipe)
    task.tree_clearance_check_tick = game.tick + 60
    task.tree_clearance_timeout_tick = game.tick + 7200
    EventBus.emit("construction_tree_clearance_requested", {
      task_id = task.id,
      trees = requested,
      sites = #state.clearance_rows,
      available_robots = state.available_robots,
      all_robots = state.all_robots
    })
    return true, "clearing_trees"
  end

  if #state.rows == 0 then
    plan.physical_preflight = nil
    return true, "already_present"
  end
  local projected_slots, slot_limit, total_slots = projected_inventory_slots(agent, state.requirements)
  if not projected_slots then return false, "Основной инвентарь Алины недоступен." end
  if projected_slots > slot_limit then
    return false, "Полный комплект модуля занял бы " .. projected_slots .. " слотов из "
      .. total_slots .. "; безопасный предел 70% равен " .. slot_limit
      .. ". Сначала нужно разгрузить инвентарь."
  end
  local build_origin = {x = agent.position.x, y = agent.position.y}
  local preserve_belt_order = (plan.route_tiles or 0) > 0
  local preserve_plan_order = plan.construction_lane_sweep == true
  table.sort(state.rows, function(a, b)
    return physical_order_less(build_origin, preserve_belt_order, preserve_plan_order,
      plan.fluid_bootstrap == true, a, b)
  end)
  local requirement_rows = {}
  for name, count in pairs(state.requirements) do
    requirement_rows[#requirement_rows + 1] = {name = name, count = count}
  end
  table.sort(requirement_rows, function(a, b) return a.name < b.name end)
  plan.entities = state.rows
  plan.physical_requirements = requirement_rows
  plan.physical_preflight = nil
  plan.requirement_index = 1
  plan.index = 1
  plan.physical_built = 0
  plan.physical_stage = "acquiring"
  task.phase = "acquiring_module_items"
  task.summary = "Собираю всё для модуля " .. tostring(plan.target_item or plan.recipe)
  EventBus.emit("line_expansion_physical_prepared", {
    task_id = task.id,
    target_item = plan.target_item,
    entities = #state.rows,
    item_kinds = #requirement_rows,
    projected_inventory_slots = projected_slots,
    inventory_slot_limit = slot_limit
  })
  return true, "prepared"
end

local function physical_tree_target(row)
  local entity = row.unit_number and game.get_entity_by_unit_number(row.unit_number) or nil
  if SitePolicy.is_natural_clearable(entity) then return entity end
  local surface = game.get_surface(row.surface_index)
  if not surface then return nil end
  for _, candidate in ipairs(surface.find_entities_filtered({
      position = row.position, radius = 0.35, name = row.name, limit = 4})) do
    if SitePolicy.is_natural_clearable(candidate) then return candidate end
  end
  return nil
end

local function start_route_obstacle_clearance(task, agent, plan, position)
  if not position then return false end
  local obstacles = SitePolicy.natural_obstacles_near(agent.surface, position, 3, 16)
  if #obstacles == 0 then return false end
  plan.route_clearance_count = (plan.route_clearance_count or 0) + #obstacles
  if plan.route_clearance_count > 32 then return false end
  local targets = {}
  for _, obstacle in ipairs(obstacles) do
    targets[#targets + 1] = {
      unit_number = obstacle.unit_number,
      name = obstacle.name,
      surface_index = obstacle.surface.index,
      position = {x = obstacle.position.x, y = obstacle.position.y}
    }
  end
  table.sort(targets, function(a, b)
    local da, db = distance_squared(agent.position, a.position), distance_squared(agent.position, b.position)
    if da ~= db then return da < db end
    if a.position.x ~= b.position.x then return a.position.x < b.position.x end
    return a.position.y < b.position.y
  end)
  plan.tree_clearance_targets = targets
  plan.tree_clearance_index = 1
  plan.physical_preflight = nil
  plan.physical_stage = "clearing_trees_physical"
  task.navigation = nil
  task.phase = "clearing_trees"
  task.summary = "Расчищаю природное препятствие на безопасном пути к площадке"
  EventBus.emit("construction_route_obstacle_clearance_started", {
    task_id = task.id,
    obstacles = #targets,
    position = position,
    total = plan.route_clearance_count
  })
  return true
end

local function clear_trees_physically(task, agent, plan)
  local targets = plan.tree_clearance_targets or {}
  local index = plan.tree_clearance_index or 1
  local row = targets[index]
  if not row then
    Agent.stop()
    task.navigation = nil
    plan.tree_clearance_targets = nil
    plan.tree_clearance_index = nil
    plan.physical_stage = nil
    task.phase = "preparing_physical_module"
    task.summary = "Проверяю расчищенное место для " .. tostring(plan.target_item or plan.recipe)
    EventBus.emit("construction_tree_clearance_completed", {
      task_id = task.id,
      mode = "physical",
      trees = #targets
    })
    return
  end
  local tree = physical_tree_target(row)
  if not tree then
    task.navigation = nil
    plan.tree_clearance_index = index + 1
    plan.tree_mining_started_tick = nil
    return
  end
  if Conflict.is_blocked(agent.surface.index, tree.position, task.source) then
    Agent.stop()
    TaskManager.fail("Игрок начал работать на участке расчистки; уступаю его.")
    return
  end
  -- Use Factorio's exact entity access check; centre-to-centre distance is
  -- wrong for large or modded tree collision boxes.
  local reach = math.max(1, agent.resource_reach_distance - 0.05)
  if not agent.can_reach_entity(tree) then
    if not task.navigation then
      Navigation.start(task, agent, tree.position, reach, "clear_construction_tree")
    end
    local arrived, failure = Navigation.tick(task, agent)
    if failure and agent.can_reach_entity(tree) then
      -- Path waypoints use the entity centre; the exact engine access test
      -- correctly accepts the reachable edge of a large modded tree.
      Navigation.cancel(task)
      failure, arrived = nil, true
    end
    if failure then
      Navigation.cancel(task)
      TaskManager.fail("Не смогла безопасно добраться до дерева на строительной площадке.")
    elseif arrived then
      task.navigation = nil
    end
    return
  end
  task.navigation = nil
  agent.walking_state = {walking = false, direction = defines.direction.north}
  agent.selected = tree
  agent.mining_state = {mining = true, position = tree.position}
  plan.tree_mining_started_tick = plan.tree_mining_started_tick or game.tick
  if game.tick - plan.tree_mining_started_tick > 1800 then
    Agent.stop()
    TaskManager.fail("Ручная расчистка дерева не продвигается.")
  end
end

local function acquire_requirements(task, agent, plan)
  local requirement = plan.physical_requirements[plan.requirement_index]
  if not requirement then
    task.acquisition = nil
    task.navigation = nil
    plan.physical_stage = "approaching"
    plan.last_build_progress_tick = game.tick
    task.phase = "approaching_module"
    task.summary = "Иду к подготовленной площадке " .. tostring(plan.target_item or plan.recipe)
    return
  end

  local inventory = agent.get_inventory(defines.inventory.character_main)
  if inventory and inventory.get_item_count(requirement.name) >= requirement.count then
    task.acquisition = nil
    plan.requirement_index = plan.requirement_index + 1
    task.phase = "acquiring_module_items"
    return
  end

  if not task.acquisition then
    local ok, result = Acquisition.start(task, agent, requirement.name, requirement.count)
    if not ok then
      TaskManager.fail("Не могу подготовить полный модуль без " .. requirement.name .. ": " .. tostring(result))
      return
    end
  end
  local status = Acquisition.tick(task, agent)
  if status == "done" then
    task.acquisition = nil
    task.navigation = nil
    plan.requirement_index = plan.requirement_index + 1
    task.phase = "acquiring_module_items"
  end
end

local function record_owned(task, entity)
  if not entity.unit_number then return end
  local root = State.ensure()
  root.owned_entities[entity.unit_number] = {
    task_id = task.id,
    entity = entity.name,
    surface_index = entity.surface.index,
    position = {x = entity.position.x, y = entity.position.y},
    built_tick = game.tick
  }
end

local function configure_built_entity(agent, entity, row)
  local moved = {}
  local function remember(target_inventory, stack)
    moved[#moved + 1] = {inventory = target_inventory, name = stack.name,
      count = stack.count, quality = stack.quality}
  end
  local function fail_configuration(message)
    for index = #moved, 1, -1 do
      local stack = moved[index]
      local removed = stack.inventory.remove({name = stack.name, count = stack.count, quality = stack.quality})
      if removed > 0 then agent.insert({name = stack.name, count = removed, quality = stack.quality}) end
    end
    return false, message
  end
  if row.recipe and (entity.type == "assembling-machine" or entity.type == "rocket-silo") then
    local ok = pcall(function() entity.set_recipe(row.recipe) end)
    local selected = ok and entity.get_recipe() or nil
    if not selected or selected.name ~= row.recipe then
      return fail_configuration("Новая машина не приняла рецепт " .. tostring(row.recipe) .. ".")
    end
  end
  if row.fuel and row.fuel.name and (row.fuel.count or 0) > 0 then
    local fuel_inventory = entity.get_fuel_inventory()
    if not fuel_inventory then return fail_configuration(entity.name .. " не имеет ожидаемого топливного инвентаря.") end
    local removed = agent.remove_item({name = row.fuel.name, count = row.fuel.count})
    if removed ~= row.fuel.count then
      if removed > 0 then agent.insert({name = row.fuel.name, count = removed}) end
      return fail_configuration("Перед запуском цепочки пропало топливо " .. row.fuel.name .. ".")
    end
    local inserted = fuel_inventory.insert({name = row.fuel.name, count = removed})
    if inserted ~= removed then
      if inserted > 0 then fuel_inventory.remove({name = row.fuel.name, count = inserted}) end
      agent.insert({name = row.fuel.name, count = removed})
      return fail_configuration("Не удалось заправить " .. entity.name .. ".")
    end
    remember(fuel_inventory, {name = row.fuel.name, count = inserted})
  end
  if row.contents and #row.contents > 0 then
    local target_inventory = entity.get_inventory(defines.inventory.chest)
    if not target_inventory then return fail_configuration(entity.name .. " не имеет ожидаемого буферного инвентаря.") end
    for _, stack in ipairs(row.contents) do
      local removed = agent.remove_item({name = stack.name, count = stack.count})
      if removed ~= stack.count then
        if removed > 0 then agent.insert({name = stack.name, count = removed}) end
        return fail_configuration("Перед загрузкой входного буфера пропал предмет " .. stack.name .. ".")
      end
      local inserted = target_inventory.insert({name = stack.name, count = removed})
      if inserted ~= removed then
        if inserted > 0 then target_inventory.remove({name = stack.name, count = inserted}) end
        agent.insert({name = stack.name, count = removed})
        return fail_configuration("Входной буфер " .. entity.name .. " не принял " .. stack.name .. ".")
      end
      remember(target_inventory, {name = stack.name, count = inserted})
    end
  end
  if row.modules and #row.modules > 0 then
    local module_inventory = entity.get_module_inventory()
    if not module_inventory then return fail_configuration(entity.name .. " не имеет ожидаемых ячеек модулей.") end
    for _, stack in ipairs(row.modules) do
      local request = {name = stack.name, count = stack.count, quality = stack.quality or "normal"}
      local removed = agent.remove_item(request)
      if removed ~= stack.count then
        if removed > 0 then agent.insert({name = stack.name, count = removed, quality = request.quality}) end
        return fail_configuration("Перед установкой пропал безопасный модуль " .. stack.name .. ".")
      end
      local inserted = module_inventory.insert({name = stack.name, count = removed, quality = request.quality})
      if inserted ~= removed then
        if inserted > 0 then module_inventory.remove({name = stack.name, count = inserted, quality = request.quality}) end
        agent.insert({name = stack.name, count = removed, quality = request.quality})
        return fail_configuration("Машина " .. entity.name .. " не приняла модуль " .. stack.name .. ".")
      end
      remember(module_inventory, {name = stack.name, count = inserted, quality = request.quality})
    end
  end
  if row.logistic_requests and #row.logistic_requests > 0 then
    local ok, error_message = pcall(function()
      local sections = entity.get_logistic_sections()
      if not sections then error("logistic_sections_unavailable") end
      local section = sections.add_section(Identity.name())
      if not section then error("logistic_section_not_created") end
      for index, stack in ipairs(row.logistic_requests) do
        section.set_slot(index, {
          value = {type = "item", name = stack.name, quality = stack.quality or "normal", comparator = "="},
          min = stack.count,
          max = math.max(stack.count, stack.count * 4)
        })
      end
    end)
    if not ok then return fail_configuration("Не удалось настроить постоянное снабжение " .. entity.name
      .. ": " .. tostring(error_message)) end
  end
  return true
end

local function place_physical(task, agent, row)
  if Conflict.is_blocked(agent.surface.index, row.position, task.source) then
    return false, "Игрок начал работать в точке расширения; останавливаю дальнейшее строительство."
  end
  local existing = matching_present(agent.surface, row, agent.force)
  if existing then return true, "already_present", existing end
  local placement_parameters = {
      name = row.name,
      position = row.position,
      direction = row.direction,
      force = agent.force
    }
  if not agent.surface.can_place_entity(placement_parameters) then
    local prototype = prototypes.entity[row.name]
    local box = prototype and prototype.collision_box or nil
    local agent_blocks = false
    local blockers = {}
    local colliders = {}
    if box then
      if collision_boxes_overlap(row.position, box, agent.position, agent.prototype.collision_box) then
        agent_blocks = true
      end
      local area = {
        {row.position.x + box.left_top.x, row.position.y + box.left_top.y},
        {row.position.x + box.right_bottom.x, row.position.y + box.right_bottom.y}
      }
      colliders = agent.surface.find_entities_filtered({area = area})
      local vehicle = agent.vehicle
      if vehicle and vehicle.valid
          and collision_boxes_overlap(row.position, box, vehicle.position, vehicle.prototype.collision_box) then
        agent_blocks = true
      end
      local owned_spider_legs = {}
      if vehicle and vehicle.valid and vehicle.type == "spider-vehicle" then
        for _, leg in pairs(vehicle.get_spider_legs() or {}) do
          owned_spider_legs[leg] = true
          if leg.unit_number then owned_spider_legs[leg.unit_number] = true end
        end
      end
      for _, collider in ipairs(colliders) do
        local owned_mobility = collider == agent or (vehicle and vehicle.valid and collider == vehicle)
        if not owned_mobility and collider.type == "spider-leg" then
          owned_mobility = owned_spider_legs[collider]
            or (collider.unit_number and owned_spider_legs[collider.unit_number]) or false
        end
        if owned_mobility then agent_blocks = true end
        if collider.valid and not owned_mobility and #blockers < 8 then
          blockers[#blockers + 1] = collider.name .. "@"
            .. string.format("%.1f,%.1f", collider.position.x, collider.position.y)
        end
      end
      -- can_place_entity uses the engine's full dynamic character/vehicle
      -- clearance, which is slightly wider than the prototype collision box
      -- exposed to Lua. If the only obstruction is immediately under Alina,
      -- treat it as a movable self-block, then re-check placement after moving.
      if not agent_blocks and #blockers == 0
          and distance_squared(agent.position, row.position) <= 1.25 * 1.25 then
        agent_blocks = true
      end
    end
    local cleared_ground = false
    for _, collider in ipairs(colliders) do
      if collider.valid and collider.type == "item-entity" and collider.stack.valid_for_read then
        local stack = collider.stack
        local quality = stack.quality and stack.quality.name or "normal"
        local count = stack.count
        local inserted = agent.insert({name = stack.name, count = count, quality = quality})
        if inserted == count then
          collider.destroy()
          cleared_ground = true
        elseif inserted > 0 and collider.valid then
          stack.count = count - inserted
        end
      end
    end
    if cleared_ground and agent.surface.can_place_entity(placement_parameters) then
      EventBus.emit("line_expansion_ground_items_collected", {
        task_id = task.id, entity = row.name, position = row.position
      })
    else
    if agent_blocks then return false, "agent_blocking_build_site" end
    EventBus.emit("line_expansion_site_blocked", {task_id = task.id, entity = row.name,
      position = row.position, blockers = blockers})
    return false, "Точка для " .. row.name .. " (" .. string.format("%.1f, %.1f", row.position.x, row.position.y)
      .. ") занята после проверки: " .. (#blockers > 0 and table.concat(blockers, ", ") or "непроходимая поверхность")
      .. "; ничего не перезаписываю."
    end
  end

  local removed = agent.remove_item({name = row.placement_item, count = row.placement_count})
  if removed ~= row.placement_count then
    if removed > 0 then agent.insert({name = row.placement_item, count = removed}) end
    return false, "Перед строительством пропал предмет " .. row.placement_item .. "."
  end
  local entity = agent.surface.create_entity({
    name = row.name,
    position = row.position,
    direction = row.direction,
    force = agent.force,
    raise_built = true,
    create_build_effect_smoke = true
  })
  if not entity then
    agent.insert({name = row.placement_item, count = removed})
    return false, "Factorio отклонила физическое размещение " .. row.name .. "."
  end
  if not row.bootstrap then copy_source_settings(entity, row) end
  local configured, configuration_error = configure_built_entity(agent, entity, row)
  if not configured then
    entity.destroy()
    agent.insert({name = row.placement_item, count = removed})
    return false, configuration_error
  end
  WorldModel.observe_entity(entity)
  record_owned(task, entity)
  ConstructionTransaction.record_created(task, entity)
  return true, "built", entity
end

-- Factorio's asynchronous pathfinder can spend a long time proving that a
-- point inside a just-built pipe pocket is unreachable. This small bounded
-- flood fill rejects such work spots before requesting a full path. It runs
-- only when a physical build target is outside normal hand reach.
local function filter_locally_reachable_sites(agent, candidates)
  -- A single candidate still needs the bounded reachability check. Returning
  -- it unchanged would hand a sealed point to Factorio's global pathfinder,
  -- which can spend a very long time proving that a tiny pipe pocket has no
  -- entrance. Only the empty set can bypass the flood fill safely.
  if #candidates == 0 then return candidates end
  local min_x, max_x = agent.position.x, agent.position.x
  local min_y, max_y = agent.position.y, agent.position.y
  for _, row in ipairs(candidates) do
    local position = row.position
    min_x, max_x = math.min(min_x, position.x), math.max(max_x, position.x)
    min_y, max_y = math.min(min_y, position.y), math.max(max_y, position.y)
  end
  min_x, max_x = math.floor(min_x - 6), math.ceil(max_x + 6)
  min_y, max_y = math.floor(min_y - 6), math.ceil(max_y + 6)
  if max_x - min_x > 96 or max_y - min_y > 96 then return candidates end

  local resolution = 2 -- half-tile nodes; enough for narrow character passages
  local step = 1 / resolution
  local origin = {x = agent.position.x, y = agent.position.y}
  local function grid_position(x, y)
    return {x = origin.x + x * step, y = origin.y + y * step}
  end
  local function grid_key(x, y) return tostring(x) .. ":" .. tostring(y) end
  local original_collision_box = agent.prototype.collision_box
  local collision_box = {
    left_top = {x = original_collision_box.left_top.x - 0.04,
      y = original_collision_box.left_top.y - 0.04},
    right_bottom = {x = original_collision_box.right_bottom.x + 0.04,
      y = original_collision_box.right_bottom.y + 0.04}
  }
  local collision_layers = {}
  for layer, present in pairs(agent.prototype.collision_mask or {}) do
    local layer_name = type(layer) == "number" and present or layer
    if type(layer_name) == "string" and prototypes.collision_layer[layer_name] then
      if not collision_layers[layer_name] then
        collision_layers[layer_name] = true
      end
    end
  end
  local grid_min_x = math.floor((min_x - origin.x) * resolution)
  local grid_max_x = math.ceil((max_x - origin.x) * resolution)
  local grid_min_y = math.floor((min_y - origin.y) * resolution)
  local grid_max_y = math.ceil((max_y - origin.y) * resolution)
  local blocked = {}
  local vehicle = agent.vehicle
  local ignored = {[agent] = true}
  if vehicle and vehicle.valid then
    ignored[vehicle] = true
    if vehicle.type == "spider-vehicle" then
      for _, leg in pairs(vehicle.get_spider_legs() or {}) do ignored[leg] = true end
    end
  end
  -- Do not use the collision_mask search filter here: with several character
  -- layers it has intersection semantics and can omit a tank that collides on
  -- only one relevant layer. The bounded area is small; exact AABB overlap
  -- below is both deterministic and authoritative for every modded entity.
  local colliders = agent.surface.find_entities_filtered({
    area = {{min_x, min_y}, {max_x + 1, max_y + 1}}
  })
  for _, entity in ipairs(colliders) do
    if entity.valid and not ignored[entity] then
      local box = entity.bounding_box
      local left = math.floor((box.left_top.x - collision_box.right_bottom.x - origin.x) * resolution) - 1
      local right = math.ceil((box.right_bottom.x - collision_box.left_top.x - origin.x) * resolution) + 1
      local top = math.floor((box.left_top.y - collision_box.right_bottom.y - origin.y) * resolution) - 1
      local bottom = math.ceil((box.right_bottom.y - collision_box.left_top.y - origin.y) * resolution) + 1
      for x = math.max(grid_min_x, left), math.min(grid_max_x, right) do
        for y = math.max(grid_min_y, top), math.min(grid_max_y, bottom) do
          local position = grid_position(x, y)
          if collision_boxes_overlap(position, collision_box, entity.position, entity.prototype.collision_box) then
            blocked[grid_key(x, y)] = true
          end
        end
      end
    end
  end
  for x = grid_min_x, grid_max_x do
    for y = grid_min_y, grid_max_y do
      local position = grid_position(x, y)
      local tile = agent.surface.get_tile(position.x, position.y)
      for layer_name in pairs(collision_layers) do
        if tile.collides_with(layer_name) then
          blocked[grid_key(x, y)] = true
          break
        end
      end
    end
  end

  local start_x, start_y = 0, 0
  local queue = {{x = start_x, y = start_y}}
  local head = 1
  local start_key = grid_key(start_x, start_y)
  local reachable = {[start_key] = true}
  local parents = {}
  local cells = {[start_key] = {x = start_x, y = start_y}}
  local directions = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
  while head <= #queue and #queue <= 40000 do
    local current = queue[head]; head = head + 1
    for _, direction in ipairs(directions) do
      local x, y = current.x + direction[1], current.y + direction[2]
      local key = grid_key(x, y)
      if x >= grid_min_x and x <= grid_max_x and y >= grid_min_y and y <= grid_max_y
          and not blocked[key] and not reachable[key] then
        reachable[key] = true
        parents[key] = grid_key(current.x, current.y)
        cells[key] = {x = x, y = y}
        queue[#queue + 1] = {x = x, y = y}
      end
    end
  end

  local result = {}
  for _, row in ipairs(candidates) do
    local x = math.floor((row.position.x - origin.x) * resolution + 0.5)
    local y = math.floor((row.position.y - origin.y) * resolution + 0.5)
    local connected_key, connected_distance = nil, nil
    for dx = -2, 2 do
      for dy = -2, 2 do
        local candidate_key = grid_key(x + dx, y + dy)
        if reachable[candidate_key] then
          local cell_distance = distance_squared(row.position,
            grid_position(x + dx, y + dy))
          if not connected_distance or cell_distance < connected_distance then
            connected_key, connected_distance = candidate_key, cell_distance
          end
        end
      end
    end
    if connected_key then
      local waypoints = {}
      local cursor = connected_key
      while cursor and cursor ~= start_key do
        local cell = cells[cursor]
        table.insert(waypoints, 1, grid_position(cell.x, cell.y))
        cursor = parents[cursor]
      end
      row.local_waypoints = waypoints
      row.local_goal = waypoints[#waypoints] or {x = agent.position.x, y = agent.position.y}
      result[#result + 1] = row
    end
  end
  -- An empty result is meaningful: every nearby work side is sealed by the
  -- module built so far. Let build_next open a bounded corridor in Alina's own
  -- pipes instead of feeding known-unreachable points to the global pathfinder.
  return result
end

local WORK_SITE_TRANSPORT_TYPES = {
  "transport-belt", "underground-belt", "splitter", "loader", "loader-1x1",
  "straight-rail", "curved-rail-a", "curved-rail-b", "half-diagonal-rail",
  "legacy-straight-rail", "legacy-curved-rail"
}

-- Belts do not collide with a character, therefore
-- find_non_colliding_position may return the centre of a very fast belt as a
-- seemingly perfect construction work spot.  Reaching an exact coordinate on
-- a faster opposing belt is impossible and produced the observed left/right
-- loop.  Keep such positions as a last-resort fallback, but always prefer a
-- genuinely stable piece of ground when one is inside build reach.
local function work_site_transport_hazard(surface, position)
  return #surface.find_entities_filtered({
    position = position,
    radius = 0.72,
    type = WORK_SITE_TRANSPORT_TYPES,
    limit = 1
  }) > 0
end

local function same_build_position(first, second)
  return first and second and math.abs(first.x - second.x) < 0.1
    and math.abs(first.y - second.y) < 0.1
end

local function open_owned_construction_corridor(task, agent, plan, target)
  -- A completed pipe route can form a wall around the builder.  Only move
  -- pipes created by this task: open a short corridor in one operation, keep
  -- every removed row in the same plan, and rebuild it after the rest of the
  -- module is reachable.  Player/mod entities are never touched here.
  local opened_total = plan.construction_corridor_entities_opened or 0
  -- Large multi-fluid blocks can contain several independent pipe walls. A
  -- fixed allowance of sixteen openings was enough for a small refinery, but
  -- could strand Alina while she was rebuilding the last routes of a larger
  -- verified plan. Keep the operation bounded and task-local, while scaling
  -- the allowance with the module that actually created those pipes.
  local corridor_limit = math.max(16, math.min(64,
    math.ceil(#(plan.entities or {}) * 0.25)))
  if opened_total >= corridor_limit then return false end
  local root = State.ensure()
  local dx, dy = target.x - agent.position.x, target.y - agent.position.y
  local length = math.max(0.001, math.sqrt(dx * dx + dy * dy))
  dx, dy = dx / length, dy / length
  local candidates = {}
  for _, entity in ipairs(agent.surface.find_entities_filtered({
      position = agent.position, radius = 7, type = {"pipe", "pipe-to-ground"}, force = agent.force})) do
    local owned = entity.unit_number and root.owned_entities[entity.unit_number] or nil
    if entity.valid and owned and owned.task_id == task.id
        and not Conflict.is_blocked(agent.surface.index, entity.position, task.source) then
      local ex, ey = entity.position.x - agent.position.x, entity.position.y - agent.position.y
      local projection = ex * dx + ey * dy
      local perpendicular = math.abs(ex * dy - ey * dx)
      if projection > -0.5 and projection <= 7.5 and perpendicular <= 1.35 then
        local deferred = nil
        for index = math.min(plan.index - 1, #plan.entities), 1, -1 do
          local row = plan.entities[index]
          if row.name == entity.name and same_build_position(row.position, entity.position)
              and (row.construction_corridor_deferrals or 0) < 2 then
            deferred = row
            break
          end
        end
        if deferred then
          candidates[#candidates + 1] = {entity = entity, deferred = deferred,
            projection = projection, perpendicular = perpendicular}
        end
      end
    end
  end
  table.sort(candidates, function(a, b)
    if a.perpendicular ~= b.perpendicular then return a.perpendicular < b.perpendicular end
    if a.projection ~= b.projection then return a.projection < b.projection end
    return (a.entity.unit_number or 0) < (b.entity.unit_number or 0)
  end)
  if #candidates == 0 then return false end
  local inventory = agent.get_inventory(defines.inventory.character_main)
  if not inventory then return false end
  local opened, positions = 0, {}
  local maximum = math.min(4, corridor_limit - opened_total)
  for _, candidate in ipairs(candidates) do
    if opened >= maximum then break end
    local gate, deferred = candidate.entity, candidate.deferred
    if gate.valid then
      local unit_number = gate.unit_number
      local gate_position = {x = gate.position.x, y = gate.position.y}
      local ok, mined = pcall(function()
        return gate.mine({inventory = inventory, force = true, raise_destroyed = true})
      end)
      if ok and mined then
        root.owned_entities[unit_number] = nil
        WorldModel.forget_entity(unit_number, agent.surface.index)
        local transaction = task.construction_transaction
        if transaction and transaction.status == "open" then
          for index = #transaction.created, 1, -1 do
            if transaction.created[index].unit_number == unit_number then
              table.remove(transaction.created, index)
              break
            end
          end
        end
        deferred.construction_corridor_deferrals = (deferred.construction_corridor_deferrals or 0) + 1
        -- Keep temporary gates open while the rest of the module is built.
        -- Re-appending a gate immediately can close the only passage before a
        -- deferred row behind that wall is reached, producing a build/mine
        -- loop. The final build stage closes every task-owned gate once.
        plan.construction_corridor_rows = plan.construction_corridor_rows or {}
        plan.construction_corridor_rows[#plan.construction_corridor_rows + 1] = deferred
        positions[#positions + 1] = gate_position
        opened = opened + 1
      end
    end
  end
  if opened == 0 then return false end
  plan.construction_corridors_opened = (plan.construction_corridors_opened or 0) + 1
  plan.construction_corridor_entities_opened = opened_total + opened
  EventBus.emit("line_expansion_construction_corridor_opened", {
    task_id = task.id,
    positions = positions,
    entity_count = opened,
    deferred_until = #plan.entities,
    corridors_opened = plan.construction_corridors_opened,
    entities_opened_total = plan.construction_corridor_entities_opened,
    entity_limit = corridor_limit
  })
  return true
end

local function defer_current_build_row(task, plan, row, reason)
  row.build_deferrals = (row.build_deferrals or 0) + 1
  if row.build_deferrals > 3 then return false end
  table.remove(plan.entities, plan.index)
  plan.entities[#plan.entities + 1] = row
  task.navigation = nil
  plan.build_site_attempt = nil
  plan.build_site_failures = nil
  EventBus.emit("line_expansion_build_row_deferred", {
    task_id = task.id,
    entity = row.name,
    position = row.position,
    deferral = row.build_deferrals,
    reason = reason
  })
  return true
end

local function build_next(task, agent, plan)
  if game.tick < (plan.next_physical_build_tick or 0) then return end
  local row = plan.entities[plan.index]
  if not row then
    if plan.construction_corridor_rows and #plan.construction_corridor_rows > 0 then
      local closing = plan.construction_corridor_rows
      plan.construction_corridor_rows = {}
      -- Construction gates can be nested. Close them as a stack so Alina
      -- retraces the passages she opened and never seals an outer gate before
      -- returning through an inner one.
      for index = #closing, 1, -1 do
        plan.entities[#plan.entities + 1] = closing[index]
      end
      plan.closing_construction_corridors = true
      EventBus.emit("line_expansion_construction_corridors_closing", {
        task_id = task.id,
        entity_count = #closing,
        first_index = plan.index
      })
      row = plan.entities[plan.index]
    end
  end
  if not row then
    task.navigation = nil
    plan.physical_stage = "verifying"
    task.phase = "verifying_module"
    task.verify_tick = game.tick + 60
    return
  end

  if plan.build_site_row_index ~= plan.index then
    plan.build_site_row_index = plan.index
    plan.build_site_attempt = 1
    plan.last_build_progress_tick = game.tick
  end

  if plan.repositioning then
    local arrived, navigation_failure = Navigation.tick(task, agent)
    if arrived then
      plan.repositioning = nil
      task.navigation = nil
    elseif navigation_failure then
      Navigation.cancel(task)
      plan.repositioning = nil
      task.navigation = nil
      if not plan.closing_construction_corridors
          and open_owned_construction_corridor(task, agent, plan, row.position) then
        plan.reposition_attempts = 0
        plan.last_build_progress_tick = game.tick
      end
    end
    return
  end

  if matching_present(agent.surface, row, agent.force) then
    plan.index = plan.index + 1
    task.navigation = nil
    plan.build_site_attempt = nil
    plan.build_site_failures = nil
    return
  end
  if not task.navigation then
    local reach = math.max(1, agent.build_distance - 0.75)
    local work_side = row.construction_work_side
    local on_preferred_work_side = true
    if work_side then
      local side_progress = (agent.position.x - row.position.x) * work_side.x
        + (agent.position.y - row.position.y) * work_side.y
      local prototype = prototypes.entity[row.name]
      local footprint = prototype and math.max(prototype.tile_width or 1,
        prototype.tile_height or 1) or 1
      on_preferred_work_side = side_progress >= math.min(reach - 0.75, footprint * 0.5 + 0.65)
    end
    if distance_squared(agent.position, row.position) <= reach * reach and on_preferred_work_side then
      task.navigation = {
        state = "arrived",
        goal = {x = row.position.x, y = row.position.y},
        radius = reach,
        purpose = "physical_module_build",
        retries = 0
      }
    else
      -- A building cell is normally colliding by definition. Asking Factorio's
      -- pathfinder for that exact cell becomes unreliable once a continuous
      -- pipe/belt line has already been placed. Pick a real walkable work spot
      -- around it, always inside the character's legitimate build reach.
      local mover_name = agent.vehicle and agent.vehicle.valid and agent.vehicle.name or agent.name
      local candidates = {}
      local max_ring = math.max(2.25, math.min(6, reach - 0.5))
      local previous = plan.entities[plan.index - 1]
      local preferred_offsets = {}
      if work_side then
        local prototype = prototypes.entity[row.name]
        local footprint = prototype and math.max(prototype.tile_width or 1,
          prototype.tile_height or 1) or 1
        local near = math.max(2.25, footprint * 0.5 + 1)
        local far = math.min(max_ring, math.max(near, footprint * 0.5 + 2.5))
        preferred_offsets = {
          {x = work_side.x * near, y = work_side.y * near},
          {x = work_side.x * far, y = work_side.y * far}
        }
      end
      if previous and previous.fluid_route_id and previous.fluid_route_id == row.fluid_route_id then
        local dx = previous.position.x - row.position.x
        local dy = previous.position.y - row.position.y
        if math.abs(dx) > math.abs(dy) then
          preferred_offsets = {{x = 0, y = -2.25}, {x = 0, y = 2.25},
            {x = 0, y = -4}, {x = 0, y = 4}}
        else
          preferred_offsets = {{x = -2.25, y = 0}, {x = 2.25, y = 0},
            {x = -4, y = 0}, {x = 4, y = 0}}
        end
      end
      for _, offset in ipairs(preferred_offsets) do
        local candidate = {x = row.position.x + offset.x, y = row.position.y + offset.y}
        local site = agent.surface.find_non_colliding_position(mover_name, candidate, 1, 0.25)
        if site and distance_squared(site, row.position) <= reach * reach then
          candidates[#candidates + 1] = {
            position = site,
            preferred = true,
            transport_hazard = work_site_transport_hazard(agent.surface, site)
          }
        end
      end
      for _, ring in ipairs({2.25, 4, max_ring}) do
        for step = 0, 15 do
          local angle = step * math.pi / 8
          local candidate = {
            x = row.position.x + math.cos(angle) * ring,
            y = row.position.y + math.sin(angle) * ring
          }
          local site = agent.surface.find_non_colliding_position(mover_name, candidate, 1.25, 0.25)
          if site and distance_squared(site, row.position) <= reach * reach then
            candidates[#candidates + 1] = {
              position = site,
              preferred = false,
              transport_hazard = work_site_transport_hazard(agent.surface, site)
            }
          end
        end
      end
      table.sort(candidates, function(a, b)
        if a.transport_hazard ~= b.transport_hazard then return not a.transport_hazard end
        if a.preferred ~= b.preferred then return a.preferred end
        local da, db = distance_squared(agent.position, a.position), distance_squared(agent.position, b.position)
        if da ~= db then return da < db end
        if a.position.x ~= b.position.x then return a.position.x < b.position.x end
        return a.position.y < b.position.y
      end)
      -- Engine paths are best for machines/tanks and other large footprints.
      -- The bounded half-tile route is reserved for dense pipe work, where an
      -- almost closed manifold can otherwise keep request_path busy for a long
      -- time while proving that a candidate is unreachable.
      if (row.entity_type == "pipe" or row.entity_type == "pipe-to-ground")
          and distance_squared(agent.position, row.position) <= 144 then
        candidates = filter_locally_reachable_sites(agent, candidates)
      end
      local site_row = candidates[plan.build_site_attempt or 1]
      local site = site_row and site_row.position or nil
      if not site then
        if not plan.closing_construction_corridors
            and open_owned_construction_corridor(task, agent, plan, row.position) then
          plan.build_site_attempt = 1
          plan.last_build_progress_tick = game.tick
          return
        end
        if defer_current_build_row(task, plan, row, "no_reachable_work_side") then return end
        TaskManager.fail("Не нашла доступную рабочую позицию рядом с точкой строительства.")
        return
      end
      if site_row.local_waypoints and #site_row.local_waypoints > 0 then
        task.navigation = {
          task_id = task.id,
          state = "following",
          goal = {x = site_row.local_goal.x, y = site_row.local_goal.y},
          radius = 0.75,
          purpose = "physical_module_build",
          retries = 0,
          requested_tick = game.tick,
          last_position = {x = agent.position.x, y = agent.position.y},
          last_movement_tick = game.tick,
          waypoints = site_row.local_waypoints,
          index = 1,
          waypoint_progress_tick = game.tick,
          local_deterministic = true
        }
      else
        Navigation.start(task, agent, site, 0.6, "physical_module_build")
      end
    end
    return
  end
  local arrived, navigation_failure = Navigation.tick(task, agent)
  if navigation_failure then
    Navigation.cancel(task)
    plan.build_site_attempt = (plan.build_site_attempt or 1) + 1
    plan.build_site_failures = (plan.build_site_failures or 0) + 1
    plan.last_build_progress_tick = game.tick
    EventBus.emit("line_expansion_build_site_retry", {
      task_id = task.id,
      entity = row.name,
      position = row.position,
      attempt = plan.build_site_attempt,
      reason = navigation_failure
    })
    if plan.build_site_failures > 3 then
      if defer_current_build_row(task, plan, row, navigation_failure) then return end
      TaskManager.fail("Не смогла безопасно добраться до точки строительства после трёх разных попыток.")
      return
    end
    if not plan.closing_construction_corridors and plan.build_site_attempt > 1
        and open_owned_construction_corridor(task, agent, plan, row.position) then
      plan.build_site_attempt = 1
    end
    return
  end
  if not arrived then return end
  task.navigation = nil
  local ok, result = place_physical(task, agent, row)
  if not ok and result == "agent_blocking_build_site" then
    plan.reposition_attempts = (plan.reposition_attempts or 0) + 1
    if plan.reposition_attempts > 4 then
      TaskManager.fail("Не смогла безопасно отвести себя или паукотрон от точки строительства после четырёх попыток.")
      return
    end
    local reach = math.max(2, math.min(6, agent.build_distance - 2))
    local vehicle = agent.vehicle
    local mover = vehicle and vehicle.valid and vehicle or agent
    local mover_box = mover.prototype.collision_box
    local row_prototype = prototypes.entity[row.name]
    local row_box = row_prototype and row_prototype.collision_box or nil
    local clearance_x = row_box and mover_box
      and math.max(reach, (row_box.right_bottom.x - row_box.left_top.x
        + mover_box.right_bottom.x - mover_box.left_top.x) / 2 + 1) or reach
    local clearance_y = row_box and mover_box
      and math.max(reach, (row_box.right_bottom.y - row_box.left_top.y
        + mover_box.right_bottom.y - mover_box.left_top.y) / 2 + 1) or reach
    local candidates = {
      -- Choose a point proven to clear both the entity and the actual mover.
      -- This matters for modded large Spidertrons: a fixed 2.5-tile nudge can
      -- move the character centre while the vehicle still overlaps the row.
      {x = row.position.x + clearance_x, y = row.position.y},
      {x = row.position.x - clearance_x, y = row.position.y},
      {x = row.position.x, y = row.position.y + clearance_y},
      {x = row.position.x, y = row.position.y - clearance_y},
      {x = row.position.x + clearance_x, y = row.position.y + clearance_y},
      {x = row.position.x - clearance_x, y = row.position.y + clearance_y},
      {x = row.position.x + clearance_x, y = row.position.y - clearance_y},
      {x = row.position.x - clearance_x, y = row.position.y - clearance_y}
    }
    local site = nil
    local mover_name = mover.name
    for _, candidate in ipairs(candidates) do
      local found = agent.surface.find_non_colliding_position(mover_name, candidate, 6, 0.5)
      if found and (not row_box or not mover_box
          or not collision_boxes_overlap(row.position, row_box, found, mover_box)) then
        site = found
        break
      end
    end
    if not site then TaskManager.fail("Не нашла свободное место, чтобы отойти от точки строительства."); return end
    Navigation.start(task, agent, site, 0.6, "clear_physical_build_site")
    plan.repositioning = true
    return
  end
  if not ok then TaskManager.fail(result); return end
  plan.reposition_attempts = nil
  if result == "built" then
    plan.physical_built = plan.physical_built + 1
    plan.next_physical_build_tick = game.tick + PHYSICAL_BUILD_INTERVAL
    -- Synchronously appending JSONL for every pipe made large blocks visibly
    -- stutter. Report bounded batches instead; failures and phase transitions
    -- stay immediate while normal construction writes at most every 32
    -- entities or ten game seconds.
    local total = #plan.entities
    local since = game.tick - (plan.last_progress_event_tick or -600)
    if plan.physical_built == 1 or plan.physical_built == total
        or plan.physical_built % 32 == 0 or since >= 600 then
      plan.last_progress_event_tick = game.tick
      EventBus.emit("line_expansion_build_progress", {
        task_id = task.id,
        built = plan.physical_built,
        total = total,
        last_entity = row.name
      })
    end
  end
  plan.index = plan.index + 1
  plan.build_site_row_index = nil
  plan.build_site_attempt = nil
  plan.build_site_failures = nil
  plan.last_build_progress_tick = game.tick
end

local function verify_built(plan, surface, force)
  local built, total, missing = 0, #plan.entities, {}
  for _, row in ipairs(plan.entities) do
    if matching_present(surface, row, force) then
      built = built + 1
    elseif #missing < 16 then
      local nearby = surface.find_entities_filtered({
        position = row.position,
        radius = 0.22,
        force = force,
        limit = 4
      })
      local actual = {}
      for _, entity in ipairs(nearby) do
        if entity.valid then
          actual[#actual + 1] = {name = entity.name, type = entity.type,
            direction = entity.direction}
        end
      end
      missing[#missing + 1] = {name = row.name, type = row.entity_type,
        position = row.position, expected_direction = row.direction, actual = actual}
    end
  end
  return built, total, missing
end

local function verified_fluid_outputs(plan, surface, force)
  local amounts = {}
  local complete = true
  for _, expected in ipairs(plan.fluid_output_rows or {}) do
    local entity = expected.row and matching_present(surface, expected.row, force) or nil
    local amount = 0
    if entity and entity.valid then
      local ok, value = pcall(function() return entity.get_fluid_count(expected.fluid) end)
      if ok then amount = value or 0 end
    end
    amounts[expected.fluid] = (amounts[expected.fluid] or 0) + amount
    if amount <= 0 then complete = false end
  end
  return complete, amounts
end

local function approach_physical_module(task, agent, plan)
  if not task.navigation then
    local desired = plan.approach_position or (plan.entities[1] and plan.entities[1].position)
    if not desired then
      TaskManager.fail("У производственного модуля отсутствует безопасная точка подхода.")
      return
    end
    local mover = agent.vehicle and agent.vehicle.valid and agent.vehicle.name or agent.name
    local site = agent.surface.find_non_colliding_position(mover, desired, 12, 0.5)
    if not site then
      TaskManager.fail("Не нашла свободный подход к подготовленной производственной площадке.")
      return
    end
    plan.approach_site = {x = site.x, y = site.y}
    Navigation.start(task, agent, site, 1.25, "physical_module_build")
    EventBus.emit("line_expansion_approach_started", {
      task_id = task.id,
      target_item = plan.target_item,
      position = plan.approach_site
    })
    return
  end
  local arrived, failure = Navigation.tick(task, agent)
  if failure then
    local obstruction_position = task.navigation and task.navigation.obstruction_position or nil
    Navigation.cancel(task)
    if failure == "destruction_required"
        and start_route_obstacle_clearance(task, agent, plan, obstruction_position) then
      return
    end
    TaskManager.fail("Не смогла безопасно дойти до подготовленной площадки: " .. tostring(failure) .. ".")
    return
  end
  if not arrived then return end
  task.navigation = nil
  plan.physical_stage = "building"
  plan.last_build_progress_tick = game.tick
  task.phase = "building_module"
  task.summary = "Физически достраиваю модуль " .. tostring(plan.target_item or plan.recipe)
  EventBus.emit("line_expansion_approach_completed", {
    task_id = task.id,
    target_item = plan.target_item,
    position = {x = agent.position.x, y = agent.position.y}
  })
end

local function tick_physical(task, agent, plan)
  if not plan.physical_stage then
    plan.physical_stage = "preflight"
  end
  if plan.physical_stage == "preflight" then
    local ok, result = preflight_physical(task, agent, plan)
    if not ok then TaskManager.fail(result); return end
    if result == "already_present" then
      TaskManager.complete("Повторяемый модуль уже построен; лишнего не добавляла.")
    end
    return
  end
  if plan.physical_stage == "clearing_trees" then
    if game.tick < (task.tree_clearance_check_tick or 0) then return end
    local rows = plan.tree_clearance_rows
    if not rows then
      plan.physical_stage = nil
      return
    end
    local trees_remaining = 0
    for _, row in ipairs(rows) do trees_remaining = trees_remaining + #tree_obstacles(agent.surface, row) end
    if trees_remaining == 0 then
      plan.physical_stage = nil
      plan.tree_clearance_rows = nil
      task.phase = "preparing_physical_module"
      task.summary = "Проверяю расчищенное место для " .. tostring(plan.target_item or plan.recipe)
      EventBus.emit("construction_tree_clearance_completed", {task_id = task.id, sites = #rows})
      return
    end
    if game.tick >= (task.tree_clearance_timeout_tick or 0) then
      TaskManager.fail("Строительные дроны не успели расчистить точное место постройки; остальное не трогаю.")
      return
    end
    task.tree_clearance_check_tick = game.tick + 60
    return
  end
  if plan.physical_stage == "clearing_trees_physical" then
    clear_trees_physically(task, agent, plan)
    return
  end
  if plan.physical_stage == "acquiring" then acquire_requirements(task, agent, plan); return end
  if plan.physical_stage == "approaching" then approach_physical_module(task, agent, plan); return end
  if plan.physical_stage == "building" then build_next(task, agent, plan); return end
  if plan.physical_stage == "verifying" and game.tick >= (task.verify_tick or 0) then
    local built, total, missing = verify_built(plan, agent.surface, agent.force)
    if built < total then
      EventBus.emit("line_expansion_verification_failed", {
        task_id = task.id,
        built = built,
        total = total,
        missing = missing
      })
      TaskManager.fail("Физическое расширение неполное: построено " .. built .. "/" .. total .. " объектов.")
      return
    end
    local producer = plan.producer_target and matching_present(agent.surface, plan.producer_target, agent.force) or nil
    if not producer then
      TaskManager.fail("Новая производственная машина не найдена после строительства модуля.")
      return
    end
    if producer.type == "assembling-machine" or producer.type == "rocket-silo" then
      local recipe = producer.get_recipe()
      if not recipe or recipe.name ~= plan.recipe then
        TaskManager.fail("Новая машина не получила рецепт " .. tostring(plan.recipe) .. ".")
        return
      end
    end
    if plan.bootstrap and (plan.output_row or #(plan.fluid_output_rows or {}) > 0) then
      plan.physical_stage = "verifying_output"
      task.phase = "verifying_chain_output"
      task.verify_tick = game.tick + 60
      -- A long belt may need several game minutes before the first produced
      -- item physically reaches its destination. Scale only the one-shot
      -- verification deadline; no extra polling or scanning is introduced.
      local transit_ticks = math.ceil((plan.route_tiles or 0)
        / math.max(0.001, plan.belt_speed_tiles_per_tick or 0.03125))
      task.timeout_tick = game.tick + 7200 + transit_ticks
      task.summary = "Проверяю реальный выпуск новой цепочки " .. tostring(plan.target_item)
      return
    end
    EventBus.emit("line_expansion_physical_completed", {
      task_id = task.id,
      recipe = plan.recipe,
      target_item = plan.target_item,
      entities = total,
      built = plan.physical_built or 0
    })
    TaskManager.complete("Физически достроила подключённый модуль "
      .. tostring(plan.target_item or plan.recipe) .. " (" .. total .. " объектов).")
  end
  if plan.physical_stage == "verifying_output" and game.tick >= (task.verify_tick or 0) then
    local output_rows = plan.output_rows or (plan.output_row and {plan.output_row} or {})
    local count = 0
    for _, output_row in ipairs(output_rows) do
      local output = output_row and matching_present(agent.surface, output_row, agent.force) or nil
      local inventory = output and output.valid and output.get_inventory(defines.inventory.chest) or nil
      count = count + (inventory and inventory.get_item_count(plan.target_item) or 0)
    end
    local fluids_complete, fluid_amounts = verified_fluid_outputs(plan, agent.surface, agent.force)
    local target_reached = plan.target_type == "fluid"
      and (fluid_amounts[plan.target_fluid or plan.target_item] or 0) > 0
      or count > 0
    if target_reached and fluids_complete then
      EventBus.emit(plan.assembly_bootstrap and "assembly_block_completed" or "bootstrap_chain_completed", {
        task_id = task.id,
        recipe = plan.recipe,
        input_item = plan.input_item,
        target_item = plan.target_item,
        drills = plan.drill_count,
        machines = plan.machine_count,
        output = count,
        entities = #plan.entities,
        fluid_plan = plan.fluid_bootstrap == true,
        pipes = plan.pipe_count or 0,
        fluid_outputs = fluid_amounts,
        fluid_sources = plan.fluid_sources
      })
      if plan.fluid_source_bootstrap then
        TaskManager.complete("Построила и проверила первичный источник жидкости "
          .. tostring(plan.target_fluid or plan.target_item) .. ": " .. tostring(plan.drill_count or 0)
          .. " добывающих установок, " .. tostring(plan.pipe_count or 0) .. " труб.")
      elseif plan.fluid_bootstrap then
        TaskManager.complete("Построила и проверила жидкостный производственный блок " .. tostring(plan.target_item)
          .. ": " .. tostring(plan.machine_count) .. " параллельные машины, "
          .. tostring(plan.pipe_count or 0) .. " труб; входные жидкости поступают, продукты выходят.")
      elseif plan.assembly_bootstrap then
        TaskManager.complete("Построила и проверила производственный блок " .. tostring(plan.target_item)
          .. ": " .. tostring(plan.machine_count) .. " параллельные машины с входными и выходными буферами.")
      elseif plan.extraction_bootstrap then
        TaskManager.complete("Построила и проверила добычу " .. tostring(plan.target_item)
          .. ": " .. tostring(plan.drill_count) .. " буров и работающий отвод в накопитель.")
      else
        TaskManager.complete("Построила и проверила новую цепочку " .. tostring(plan.input_item)
          .. " → " .. tostring(plan.target_item) .. ": " .. tostring(plan.drill_count)
          .. " буров, " .. tostring(plan.machine_count) .. " производственных машин.")
      end
      return
    end
    if game.tick >= (task.timeout_tick or 0) then
      local status_counts, samples = {}, {}
      local input_items, output_items, fuel_items = 0, 0, 0
      local machine_fluids = {}
      local inserter_samples, output_buffer_samples, pump_samples, route_samples = {}, {}, {}, {}
      local route_input_items, route_target_items = 0, 0
      local diagnostic_target_item = prototypes.item[plan.target_item] and plan.target_item or nil
      local diagnostic_input_names = {}
      for _, name in ipairs(plan.input_items or {}) do
        if prototypes.item[name] then diagnostic_input_names[#diagnostic_input_names + 1] = name end
      end
      if #diagnostic_input_names == 0 and plan.input_item and prototypes.item[plan.input_item] then
        diagnostic_input_names[1] = plan.input_item
      end
      local function diagnostic_item_count(inventory)
        if not inventory then return 0 end
        local amount = 0
        for _, name in ipairs(diagnostic_input_names) do amount = amount + inventory.get_item_count(name) end
        return amount
      end
      for _, row in ipairs(plan.entities or {}) do
        if row.entity_type == "mining-drill" or row.entity_type == "furnace"
            or row.entity_type == "assembling-machine" then
          local entity = matching_present(agent.surface, row, agent.force)
          if entity and entity.valid then
            local status = tostring(entity.status)
            status_counts[status] = (status_counts[status] or 0) + 1
            local input = entity.get_inventory(defines.inventory.crafter_input)
            local output = entity.get_inventory(defines.inventory.crafter_output)
            local fuel = entity.get_fuel_inventory()
            input_items = input_items + diagnostic_item_count(input)
            output_items = output_items
              + (output and diagnostic_target_item and output.get_item_count(diagnostic_target_item) or 0)
            fuel_items = fuel_items + (fuel and fuel.get_item_count() or 0)
            local ok_fluids, contents = pcall(function() return entity.get_fluid_contents() end)
            if ok_fluids then
              for name, amount in pairs(contents or {}) do
                machine_fluids[name] = (machine_fluids[name] or 0) + amount
              end
            end
            if #samples < 12 then
              local fluidbox_samples = {}
              local ok_count, fluidbox_count = pcall(function() return entity.fluids_count end)
              if ok_count then
                for fluidbox_index = 1, fluidbox_count or 0 do
                  local prototype_ok, fluidbox_prototype = pcall(function()
                    return entity.get_fluid_box_prototype(fluidbox_index)
                  end)
                  local neighbours_ok, neighbours = pcall(function()
                    return entity.get_fluid_box_neighbours(fluidbox_index)
                  end)
                  local segment_ok, segment_fluid = pcall(function()
                    return entity.get_fluid_segment_fluid(fluidbox_index)
                  end)
                  local filter_ok, filter = pcall(function()
                    return entity.get_fluid_filter(fluidbox_index)
                  end)
                  fluidbox_samples[#fluidbox_samples + 1] = {
                    index = fluidbox_index,
                    production_type = prototype_ok and fluidbox_prototype
                      and fluidbox_prototype.production_type or nil,
                    neighbours = neighbours_ok and #(neighbours or {}) or nil,
                    fluid = segment_ok and segment_fluid and segment_fluid.name or nil,
                    amount = segment_ok and segment_fluid and segment_fluid.amount or 0,
                    filter = filter_ok and filter and (filter.name or filter) or nil
                  }
                end
              end
              samples[#samples + 1] = {name = entity.name, status = status,
                position = {x = entity.position.x, y = entity.position.y},
                input = diagnostic_item_count(input),
                output = output and diagnostic_target_item
                  and output.get_item_count(diagnostic_target_item) or 0,
                fuel = fuel and fuel.get_item_count() or 0,
                fluids = ok_fluids and contents or nil,
                fluidboxes = fluidbox_samples}
            end
          end
        elseif row.entity_type == "transport-belt" and row.route_segment then
          local entity = matching_present(agent.surface, row, agent.force)
          if entity and entity.valid then
            local first, second = entity.get_transport_line(1), entity.get_transport_line(2)
            local route_input = diagnostic_item_count(first) + diagnostic_item_count(second)
            local route_target = diagnostic_target_item
              and (first.get_item_count(diagnostic_target_item) + second.get_item_count(diagnostic_target_item)) or 0
            route_input_items = route_input_items + route_input
            route_target_items = route_target_items + route_target
            if #route_samples < 16 and (row.route_step <= 8
                or row.route_step > math.max(8, (row.route_total or 0) - 8)) then
              route_samples[#route_samples + 1] = {
                position = {x = entity.position.x, y = entity.position.y},
                direction = entity.direction,
                step = row.route_step,
                total = row.route_total,
                input = route_input,
                target = route_target
              }
            end
          end
        elseif row.entity_type == "inserter" and #inserter_samples < 16 then
          local entity = matching_present(agent.surface, row, agent.force)
          if entity and entity.valid then
            local network_ok, network_id = pcall(function() return entity.electric_network_id end)
            inserter_samples[#inserter_samples + 1] = {
              name = entity.name,
              position = {x = entity.position.x, y = entity.position.y},
              direction = entity.direction,
              status = tostring(entity.status),
              energy = entity.energy,
              electric_network_id = network_ok and network_id or nil,
              pickup_position = entity.pickup_position and
                {x = entity.pickup_position.x, y = entity.pickup_position.y} or nil,
              drop_position = entity.drop_position and
                {x = entity.drop_position.x, y = entity.drop_position.y} or nil
            }
          end
        elseif row.entity_type == "pump" and #pump_samples < 24 then
          local entity = matching_present(agent.surface, row, agent.force)
          if entity and entity.valid then
            local network_ok, network_id = pcall(function() return entity.electric_network_id end)
            local contents_ok, contents = pcall(function() return entity.get_fluid_contents() end)
            pump_samples[#pump_samples + 1] = {
              name = entity.name,
              position = {x = entity.position.x, y = entity.position.y},
              direction = entity.direction,
              status = tostring(entity.status),
              energy = entity.energy,
              electric_network_id = network_ok and network_id or nil,
              fluids = contents_ok and contents or nil,
              expected_fluid = row.fluid_route,
              route_id = row.fluid_route_id,
              route_step = row.fluid_route_step
            }
          end
        elseif (row.entity_type == "container" or row.entity_type == "logistic-container"
            or row.entity_type == "linked-container") and #output_buffer_samples < 16 then
          local entity = matching_present(agent.surface, row, agent.force)
          local inventory = entity and entity.valid and entity.get_inventory(defines.inventory.chest) or nil
          if inventory then
            output_buffer_samples[#output_buffer_samples + 1] = {
              name = entity.name,
              position = {x = entity.position.x, y = entity.position.y},
              target_items = diagnostic_target_item and inventory.get_item_count(diagnostic_target_item) or 0
            }
          end
        end
      end
      EventBus.emit("bootstrap_chain_output_timeout", {
        task_id = task.id,
        target_item = plan.target_item,
        input_item = plan.input_item,
        status_counts = status_counts,
        input_items = input_items,
        output_items = output_items,
        fuel_items = fuel_items,
        output_position = plan.output_row and plan.output_row.position or nil,
        samples = samples,
        fluid_plan = plan.fluid_bootstrap == true,
        machine_fluids = machine_fluids,
        fluid_outputs = fluid_amounts,
        fluid_sources = plan.fluid_sources,
        inserters = inserter_samples,
        output_buffers = output_buffer_samples,
        route_input_items = route_input_items,
        route_target_items = route_target_items,
        route_samples = route_samples,
        pumps = pump_samples
      })
      TaskManager.fail("Новая цепочка построена, но контрольный выход " .. tostring(plan.target_item)
        .. " не появился в накопителе вовремя.")
      return
    end
    task.verify_tick = game.tick + 60
  end
end

local function tick_remote(task, agent, plan)
  if task.phase == "placing_ghosts" then
    plan.index = plan.index or 1
    local placed_this_tick = 0
    while placed_this_tick < GHOSTS_PER_TICK do
      local row = plan.entities[plan.index]
      if not row then
        if (plan.ghosts_created or 0) == 0 then
          TaskManager.complete("Повторяемый модуль уже оказался построен; лишнего не добавляла.")
          return
        end
        EventBus.emit("line_expansion_ghosts_created", {
          task_id = task.id,
          recipe = plan.recipe,
          target_item = plan.target_item,
          ghosts = plan.ghosts_created
        })
        task.phase = "waiting_for_robots"
        task.verify_tick = game.tick + 120
        task.timeout_tick = game.tick + 3600
        task.summary = "Жду строительных дронов: " .. tostring(plan.target_item or plan.recipe)
        return
      end

      local ok, result = place_ghost(task, row, agent.surface, agent.force)
      if not ok then TaskManager.fail(result); return end
      if result == "ghost_created" then plan.ghosts_created = (plan.ghosts_created or 0) + 1 end
      plan.index = plan.index + 1
      placed_this_tick = placed_this_tick + 1
    end
    task.summary = "Размечаю дронам " .. tostring(plan.target_item or plan.recipe)
    return
  end

  if task.phase == "waiting_for_robots" and game.tick >= (task.verify_tick or 0) then
    local built, total = verify_built(plan, agent.surface, agent.force)
    if built >= total then
      TaskManager.complete("Дроны достроили автоматизированный модуль " .. tostring(plan.target_item or plan.recipe)
        .. " (" .. built .. "/" .. total .. " объектов).")
      return
    end
    if game.tick >= (task.timeout_tick or 0) then
      TaskManager.complete("Разметила расширение " .. tostring(plan.target_item or plan.recipe)
        .. "; дроны построили " .. built .. "/" .. total .. " объектов. Остальное оставила в очереди строительства.")
      return
    end
    task.verify_tick = game.tick + 120
  end
end

function LineExpander.tick(task, agent)
  local plan = task.expansion
  if not plan or type(plan.entities) ~= "table" or #plan.entities == 0 then
    TaskManager.fail("План расширения линии повреждён.")
    return
  end
  if plan.remote then tick_remote(task, agent, plan) else tick_physical(task, agent, plan) end
end

function LineExpander.on_robot_built(event)
  local entity = event.entity
  local tags = event.tags
  if not entity or not entity.valid or type(tags) ~= "table" or not tags.alina_clone then return end
  local source_id = tonumber(tags.source_unit_number)
  local source = source_id and game.get_entity_by_unit_number(source_id) or nil
  if (not source or not source.valid) and tags.source_position and tags.source_name then
    local candidates = entity.surface.find_entities_filtered({
      position = tags.source_position,
      radius = 0.22,
      name = tags.source_name,
      force = entity.force,
      limit = 8
    })
    for _, candidate in ipairs(candidates) do
      if candidate.valid and candidate.direction == tags.source_direction then source = candidate; break end
    end
  end
  if source and source.valid then pcall(function() entity.copy_settings(source) end) end
  local task = State.ensure().task.current
  if task and tonumber(tags.task_id) == task.id then
    record_owned(task, entity)
    ConstructionTransaction.record_created(task, entity)
  end
  WorldModel.observe_entity(entity)
end

return LineExpander
