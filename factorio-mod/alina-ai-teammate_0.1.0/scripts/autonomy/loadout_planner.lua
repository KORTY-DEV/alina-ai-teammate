local Acquisition = require("scripts.executor.acquisition")
local PrototypeIndex = require("scripts.sensors.prototype_index")
local RecipeIndex = require("scripts.sensors.recipe_index")
local WorldModel = require("scripts.sensors.world_model")

local LoadoutPlanner = {}

local MAIN_SLOT_LIMIT = 0.65
local AMMO_RESERVE = 50
local FUEL_TARGET_COUNT = 10
local FUEL_REFILL_RATIO = 0.40
local BUILD_RESERVES = {
  {key = "electric-pole", entity_type = "electric-pole", count = 10},
  {key = "transport-belt", entity_type = "transport-belt", count = 50},
  {key = "inserter", entity_type = "inserter", count = 20},
  {key = "mining-drill", entity_type = "mining-drill", count = 5},
  {key = "furnace", entity_type = "furnace", count = 5},
  {key = "assembling-machine", entity_type = "assembling-machine", count = 5}
}

local function used_slots(inventory)
  local used = 0
  for index = 1, #inventory do
    if inventory[index].valid_for_read then used = used + 1 end
  end
  return used
end

local function plan_score(plan, prototype)
  local score = #(plan.operations or {}) * 100000
  for _, operation in ipairs(plan.operations or {}) do
    score = score + (operation.count or operation.crafts or operation.output_count or 1)
    if operation.type == "mine" then score = score + 20000 end
    if operation.type == "machine" then score = score + 10000 end
  end
  return score, (prototype.order or "") .. ":" .. prototype.name
end

local function construction_utility(row)
  local utility = 0
  if row.entity_type == "electric-pole" then
    utility = (row.supply_area_distance or 0) * 100 + (row.max_wire_distance or 0)
  elseif row.entity_type == "transport-belt" or row.entity_type == "underground-belt"
      or row.entity_type == "splitter" then
    utility = (row.belt_speed or 0) * 10000
  elseif row.entity_type == "inserter" then
    utility = (row.inserter_rotation_speed or 0) * 10000 + (row.inserter_reach or 0)
  elseif row.entity_type == "mining-drill" then
    utility = (row.mining_speed or 0) * 1000 + (row.mining_radius or 0) * 10
  elseif row.entity_type == "assembling-machine" or row.entity_type == "furnace" then
    utility = (row.crafting_speed or 0) * 1000 + (row.module_inventory_size or 0) * 10
  end
  if row.electric then utility = utility + 1 end
  return utility
end

local function affordable(agent, name, count)
  local plan = Acquisition.make_plan(agent, name, count, "autonomous")
  if not plan then return nil end
  local main = agent.get_inventory(defines.inventory.character_main)
  if not main then return nil end
  local extra = {}
  for _, operation in ipairs(plan.operations or {}) do
    if operation.item then extra[operation.item] = true end
    for _, ingredient in ipairs(operation.ingredients or {}) do extra[ingredient.name] = true end
  end
  local projected = used_slots(main)
  for name_to_add in pairs(extra) do
    if main.get_item_count(name_to_add) == 0 then projected = projected + 1 end
  end
  if projected > math.max(1, math.floor(#main * MAIN_SLOT_LIMIT)) then return nil end
  return plan
end

local function cheap_obtainability(agent, name, count)
  local main = agent.get_inventory(defines.inventory.character_main)
  if main and main.get_item_count(name) >= count then return 0 end
  if #WorldModel.inventory_sources(agent, name, agent.position, 1) > 0 then return 0 end
  for _, recipe in ipairs(RecipeIndex.find_producers(name, agent.force, 16) or {}) do
    if recipe.enabled then return 1 end
  end
  return 2
end

local bounded_personal_plan

local function combat_utility(prototype)
  if prototype.type == "gun" then
    local parameters = prototype.attack_parameters or {}
    local cooldown = math.max(1, parameters.cooldown or 60)
    return (parameters.range or 0) * 10000 + 60000 / cooldown
  end
  if prototype.type == "ammo" then
    return (prototype.magazine_size or 1) * 100
  end
  return 0
end

local function best_item(agent, item_type, count, predicate)
  local candidates = {}
  for name, prototype in pairs(prototypes.item) do
    if prototype.type == item_type and not prototype.hidden and (not predicate or predicate(prototype)) then
      candidates[#candidates + 1] = {
        item = name,
        prototype = prototype,
        utility = combat_utility(prototype),
        order = (prototype.order or "") .. ":" .. name,
        obtainability = cheap_obtainability(agent, name, count)
      }
    end
  end
  table.sort(candidates, function(a, b)
    if a.obtainability ~= b.obtainability then return a.obtainability < b.obtainability end
    if a.utility ~= b.utility then return a.utility > b.utility end
    return a.order < b.order
  end)
  -- A large mod pack may expose hundreds of weapons. Ranking is cheap and
  -- deterministic; full recursive acquisition is deliberately bounded so one
  -- optional loadout decision cannot stall a simulation update.
  for index = 1, math.min(6, #candidates) do
    local candidate = candidates[index]
    if candidate.obtainability >= 2 then break end
    local plan = affordable(agent, candidate.item, count)
    if bounded_personal_plan(plan) then
      local score, order = plan_score(plan, candidate.prototype)
      return {item = candidate.item, count = count, utility = candidate.utility,
        score = score, order = order}
    end
  end
  return nil
end

bounded_personal_plan = function(plan)
  if not plan or #(plan.operations or {}) > 8 then return false end
  local machine_operations = 0
  for _, operation in ipairs(plan.operations or {}) do
    if operation.type == "mine" and (operation.count or 0) > 100 then return false end
    if operation.type == "machine" then machine_operations = machine_operations + 1 end
  end
  return machine_operations <= 2
end

local function compatible_fuel(prototype, burner)
  return prototype and prototype.fuel_category
    and burner and burner.valid and burner.fuel_categories[prototype.fuel_category] == true
end

local function select_fuel(agent, burner)
  if not burner or not burner.valid or not burner.inventory or not burner.inventory.valid then return nil, false end
  local inventory = burner.inventory
  local existing = {}
  for _, stack in pairs(inventory.get_contents()) do
    if compatible_fuel(prototypes.item[stack.name], burner) then
      existing[#existing + 1] = {name = stack.name, count = stack.count}
    end
  end
  table.sort(existing, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.name < b.name
  end)
  local burning = burner.currently_burning
  local preferred = existing[1] and existing[1].name or (burning and burning.name or nil)

  local function build(name)
    local prototype = prototypes.item[name]
    if not compatible_fuel(prototype, burner) then return nil end
    local current = inventory.get_item_count(name)
    local target = math.max(1, math.min(FUEL_TARGET_COUNT, prototype.stack_size or FUEL_TARGET_COUNT))
    if current > math.floor(target * FUEL_REFILL_RATIO) then return false end
    local missing = math.max(1, target - current)
    local plan = affordable(agent, name, missing)
    if not bounded_personal_plan(plan) then return nil end
    local score, order = plan_score(plan, prototype)
    return {
      kind = "fuel", item = name, count = target, current = current,
      fuel_value = prototype.fuel_value or 0, score = score, order = order
    }
  end

  if preferred then
    local choice = build(preferred)
    if choice == false then return nil, false end
    if choice then return choice, true end
  end

  local candidates = {}
  for _, fuel in ipairs(PrototypeIndex.fuels_for(burner.fuel_categories) or {}) do
    local prototype = prototypes.item[fuel.name]
    if compatible_fuel(prototype, burner) then
      candidates[#candidates + 1] = {
        name = fuel.name,
        fuel_value = fuel.fuel_value or prototype.fuel_value or 0,
        obtainability = cheap_obtainability(agent, fuel.name, FUEL_TARGET_COUNT),
        order = (prototype.order or "") .. ":" .. fuel.name
      }
    end
  end
  table.sort(candidates, function(a, b)
    if a.obtainability ~= b.obtainability then return a.obtainability < b.obtainability end
    -- Routine movement should consume the least valuable compatible stocked
    -- fuel first. High-density/rare modded fuels remain a fallback, not the
    -- default merely because their recipe exists.
    if a.fuel_value ~= b.fuel_value then return a.fuel_value < b.fuel_value end
    return a.order < b.order
  end)
  for index = 1, math.min(6, #candidates) do
    local candidate = candidates[index]
    if candidate.obtainability >= 2 then break end
    local choice = build(candidate.name)
    if choice == false then return nil, false end
    if choice then return choice, true end
  end
  return nil, true
end

local function fuel_requirement(agent, root)
  local unit = root.agent.personal_vehicle_unit
  local vehicle = unit and game.get_entity_by_unit_number(unit) or nil
  if vehicle and vehicle.valid and vehicle.force == agent.force and vehicle.surface == agent.surface
      and vehicle.burner and (root.autonomy.loadout_cooldown["fuel-vehicle"] or 0) <= game.tick then
    local choice, low = select_fuel(agent, vehicle.burner)
    if choice then
      choice.fuel_owner = "vehicle"
      choice.fuel_vehicle_unit = vehicle.unit_number
      return choice
    end
    if low then root.autonomy.loadout_cooldown["fuel-vehicle"] = game.tick + 3600 end
  end

  local grid = agent.grid
  if not grid or not grid.valid then return nil end
  for _, equipment in ipairs(grid.equipment or {}) do
    local key = "fuel-equipment:" .. equipment.name .. ":" .. equipment.position.x .. ":" .. equipment.position.y
    if equipment.burner and (root.autonomy.loadout_cooldown[key] or 0) <= game.tick then
      local choice, low = select_fuel(agent, equipment.burner)
      if choice then
        choice.fuel_owner = "equipment"
        choice.fuel_equipment_name = equipment.name
        choice.fuel_equipment_position = {x = equipment.position.x, y = equipment.position.y}
        return choice
      end
      if low then root.autonomy.loadout_cooldown[key] = game.tick + 3600 end
    end
  end
  return nil
end

local function armor_utility(prototype)
  if not prototype or prototype.type ~= "armor" then return 0 end
  local grid = prototype.equipment_grid
  local grid_area = grid and grid.width * grid.height or 0
  local inventory_bonus = prototype.get_inventory_size_bonus() or 0
  local protection = 0
  for _, resistance in pairs(prototype.resistances or {}) do
    protection = protection + (resistance.decrease or 0) * 10 + (resistance.percent or 0)
  end
  return 1 + grid_area * 1000 + inventory_bonus * 10 + protection
    + (prototype.provides_flight and 1000000 or 0)
end

local function best_armor(agent, current_utility)
  local candidates = {}
  for name, prototype in pairs(prototypes.item) do
    if prototype.type == "armor" and not prototype.hidden then
      local utility = armor_utility(prototype)
      if utility > (current_utility or -1) then
        candidates[#candidates + 1] = {
          item = name,
          prototype = prototype,
          utility = utility,
          order = (prototype.order or "") .. ":" .. name,
          obtainability = cheap_obtainability(agent, name, 1)
        }
      end
    end
  end
  table.sort(candidates, function(a, b)
    if a.obtainability ~= b.obtainability then return a.obtainability < b.obtainability end
    if a.utility ~= b.utility then return a.utility > b.utility end
    return a.order < b.order
  end)
  for index = 1, math.min(4, #candidates) do
    local candidate = candidates[index]
    if candidate.obtainability >= 2 then break end
    local plan = affordable(agent, candidate.item, 1)
    if bounded_personal_plan(plan) then
      local cost, order = plan_score(plan, candidate.prototype)
      return {item = candidate.item, count = 1, utility = candidate.utility, score = cost, order = order}
    end
  end
  return nil
end

local function grid_accepts(grid, equipment)
  if not grid or not grid.valid or grid.prototype.locked then return false end
  local allowed = {}
  for _, category in ipairs(grid.prototype.equipment_categories or {}) do allowed[category] = true end
  for _, category in ipairs(equipment.equipment_categories or {}) do
    if allowed[category] then return true end
  end
  return false
end

local function grid_free_area(grid)
  local used = 0
  for _, installed in ipairs(grid.equipment or {}) do
    local shape = installed.prototype.shape
    used = used + (shape.width or 1) * (shape.height or 1)
  end
  return grid.width * grid.height - used
end

local function equipment_installed(grid, equipment_type)
  for _, installed in ipairs(grid.equipment or {}) do
    if installed.prototype.type == equipment_type then return true end
  end
  return false
end

local function best_equipment_item(agent, grid, equipment_type, reserved_area)
  local free_area = grid_free_area(grid) - (reserved_area or 0)
  local candidates = {}
  for name, item in pairs(prototypes.item) do
    local equipment = item.place_as_equipment_result
    local shape = equipment and equipment.shape or nil
    local area = shape and (shape.width or 1) * (shape.height or 1) or math.huge
    if equipment and equipment.type == equipment_type and not item.hidden
        and area <= free_area and grid_accepts(grid, equipment) then
      candidates[#candidates + 1] = {
        item = name,
        prototype = item,
        equipment = equipment,
        area = area,
        utility = equipment_type == "generator-equipment" and (equipment.energy_production or 0)
          or equipment_type == "movement-bonus-equipment" and (equipment.get_movement_bonus() or 0)
          or 1,
        order = (item.order or "") .. ":" .. name,
        obtainability = cheap_obtainability(agent, name, 1)
      }
    end
  end
  table.sort(candidates, function(a, b)
    if a.obtainability ~= b.obtainability then return a.obtainability < b.obtainability end
    if a.utility ~= b.utility then return a.utility > b.utility end
    return a.order < b.order
  end)
  for index = 1, math.min(6, #candidates) do
    local candidate = candidates[index]
    if candidate.obtainability >= 2 then break end
    local plan = affordable(agent, candidate.item, 1)
    if bounded_personal_plan(plan) then
      local cost, order = plan_score(plan, candidate.prototype)
      return {item = candidate.item, count = 1, kind = "equipment",
        equipment_type = equipment_type, equipment_name = candidate.equipment.name,
        equipment_area = candidate.area, utility = candidate.utility, score = cost, order = order}
    end
  end
  return nil
end

local function first_empty_or_matching(inventory, item)
  for index = 1, #inventory do
    local stack = inventory[index]
    if stack.valid_for_read and stack.name == item then return index end
  end
  for index = 1, #inventory do
    if not inventory[index].valid_for_read then return index end
  end
  return nil
end

local function equipped_gun(agent)
  local guns = agent.get_inventory(defines.inventory.character_guns)
  if not guns then return nil end
  for index = 1, #guns do
    local stack = guns[index]
    if stack.valid_for_read and stack.prototype.type == "gun" then return stack.prototype, index end
  end
  return nil
end

local function gun_categories(gun)
  local result = {}
  local parameters = gun and gun.attack_parameters or nil
  for _, name in ipairs(parameters and parameters.ammo_categories or {}) do result[name] = true end
  return result
end

local function equipment_requirement(agent, root)
  local fuel = fuel_requirement(agent, root)
  if fuel then return fuel end
  local armor = agent.get_inventory(defines.inventory.character_armor)
  local armor_stack = armor and armor[1] or nil
  local current_armor = armor_stack and armor_stack.valid_for_read and armor_stack.prototype or nil
  if armor and (root.autonomy.loadout_cooldown.armor or 0) <= game.tick then
    local choice = best_armor(agent, armor_utility(current_armor))
    if choice then
      choice.kind = "armor"
      choice.inventory_slot = 1
      choice.replace_existing = current_armor ~= nil
      root.autonomy.loadout_cooldown.armor = game.tick + 3600
      return choice
    end
    -- No suitable upgrade can become affordable a few seconds later without a
    -- meaningful inventory/research change. Avoid rescanning every armour tier
    -- before each construction-reserve decision.
    root.autonomy.loadout_cooldown.armor = game.tick + 3600
  end

  local grid = agent.grid
  if grid and grid.valid and not grid.prototype.locked then
    local has_generator = equipment_installed(grid, "generator-equipment")
      or equipment_installed(grid, "solar-panel-equipment")
    local needs_belt_immunity = not equipment_installed(grid, "belt-immunity-equipment")
    local needs_movement = not equipment_installed(grid, "movement-bonus-equipment")
    local belt_choice = needs_belt_immunity and best_equipment_item(agent, grid, "belt-immunity-equipment") or nil
    local movement_choice = needs_movement and best_equipment_item(agent, grid, "movement-bonus-equipment") or nil
    if not has_generator and (belt_choice or movement_choice) then
      local desired = belt_choice or movement_choice
      local generator = best_equipment_item(agent, grid, "generator-equipment", desired.equipment_area)
        or best_equipment_item(agent, grid, "solar-panel-equipment", desired.equipment_area)
      if generator then return generator end
    end
    if has_generator and belt_choice then return belt_choice end
    if has_generator and movement_choice then return movement_choice end
  end

  local guns = agent.get_inventory(defines.inventory.character_guns)
  local gun, gun_slot = equipped_gun(agent)
  if guns and not gun and (root.autonomy.loadout_cooldown.gun or 0) <= game.tick then
    local choice = best_item(agent, "gun", 1)
    if choice then
      choice.kind = "gun"
      choice.inventory_slot = first_empty_or_matching(guns, choice.item)
      return choice
    end
    root.autonomy.loadout_cooldown.gun = game.tick + 3600
  end

  if gun and gun_slot and (root.autonomy.loadout_cooldown.ammo or 0) <= game.tick then
    local categories = gun_categories(gun)
    local ammo_inventory = agent.get_inventory(defines.inventory.character_ammo)
    local stack = ammo_inventory and ammo_inventory[gun_slot] or nil
    local equipped = stack and stack.valid_for_read and stack.count or 0
    if equipped < AMMO_RESERVE then
      local choice = best_item(agent, "ammo", AMMO_RESERVE, function(prototype)
        return prototype.ammo_category and categories[prototype.ammo_category.name] == true
      end)
      if choice then
        choice.count = math.min(choice.count, prototypes.item[choice.item].stack_size)
        choice.kind = "ammo"
        choice.inventory_slot = gun_slot
        return choice
      end
      root.autonomy.loadout_cooldown.ammo = game.tick + 3600
    end
  end
  return nil
end

local function construction_requirement(agent, root)
  local main = agent.get_inventory(defines.inventory.character_main)
  if not main or used_slots(main) >= math.max(1, math.floor(#main * MAIN_SLOT_LIMIT)) then return nil end
  root.autonomy.loadout_preferred = root.autonomy.loadout_preferred or {}
  for _, target in ipairs(BUILD_RESERVES) do
    if (root.autonomy.loadout_cooldown[target.key] or 0) <= game.tick then
      local best = nil
      local cached_item = root.autonomy.loadout_preferred[target.key]
      if cached_item and prototypes.item[cached_item] then
        if main.get_item_count(cached_item) >= target.count then
          best = {
            kind = "construction_reserve",
            reserve_key = target.key,
            reserve_type = target.entity_type,
            item = cached_item,
            count = target.count
          }
        else
          local plan = affordable(agent, cached_item, target.count)
          if plan then
            best = {
              kind = "construction_reserve",
              reserve_key = target.key,
              reserve_type = target.entity_type,
              item = cached_item,
              count = target.count
            }
          end
        end
      else
        root.autonomy.loadout_preferred[target.key] = nil
      end

      local candidates = {}
      if not best then
        for _, entity in ipairs(PrototypeIndex.entities_for_type(target.entity_type) or {}) do
          for _, placement in ipairs(entity.items or {}) do
            local prototype = prototypes.item[placement.name]
            if prototype then
              candidates[#candidates + 1] = {
                entity = entity,
                placement = placement,
                utility = construction_utility(entity),
                order = (prototype.order or "") .. ":" .. prototype.name,
                obtainability = cheap_obtainability(agent, placement.name, target.count)
              }
            end
          end
        end
        table.sort(candidates, function(a, b)
          if a.obtainability ~= b.obtainability then return a.obtainability < b.obtainability end
          if a.utility ~= b.utility then return a.utility > b.utility end
          return a.order < b.order
        end)
      end

      -- Candidates are already ordered by capability. Stop at the first tier
      -- that is actually obtainable and keep that decision until research (or
      -- a failed acquisition) invalidates it; do not rescan every obsolete tier
      -- every minute on a megabase.
      for index = 1, math.min(6, #candidates) do
        if best then break end
        local candidate = candidates[index]
        local entity, placement = candidate.entity, candidate.placement
        local plan = main.get_item_count(placement.name) >= target.count
          and {operations = {}} or affordable(agent, placement.name, target.count)
        if plan then
          local prototype = prototypes.item[placement.name]
          local score, order = plan_score(plan, prototype)
          best = {
            kind = "construction_reserve",
            reserve_key = target.key,
            reserve_type = target.entity_type,
            item = placement.name,
            count = target.count,
            score = score,
            order = order,
            utility = construction_utility(entity)
          }
          root.autonomy.loadout_preferred[target.key] = placement.name
        end
      end
      if best then
        if main.get_item_count(best.item) < target.count then
          return best
        else
          -- The best currently obtainable tier already satisfies this role.
          -- Do not fill the inventory with every obsolete lower-tier variant.
          root.autonomy.loadout_cooldown[target.key] = game.tick + 3600
        end
      else
        root.autonomy.loadout_preferred[target.key] = nil
        root.autonomy.loadout_cooldown[target.key] = game.tick + 3600
      end
    end
  end
  return nil
end

function LoadoutPlanner.next_equipment(agent, root)
  root.autonomy.loadout_cooldown = root.autonomy.loadout_cooldown or {}
  return equipment_requirement(agent, root)
end

function LoadoutPlanner.next_personal_vehicle(agent, root, factory_size)
  root.autonomy.loadout_cooldown = root.autonomy.loadout_cooldown or {}
  if (factory_size or 0) < 96 or (root.autonomy.loadout_cooldown.personal_vehicle or 0) > game.tick then
    return nil
  end
  local unit = root.agent.personal_vehicle_unit
  local existing = unit and game.get_entity_by_unit_number(unit) or nil
  if existing and existing.valid and existing.type == "spider-vehicle" then return nil end
  root.agent.personal_vehicle_unit = nil

  -- A Spidertron is a valuable item. Autonomous mode may use one explicitly
  -- placed in Alina's own inventory, but never crafts one or takes a player's
  -- only vehicle from storage without a direct instruction/confirmation.
  local main = agent.get_inventory(defines.inventory.character_main)
  local best = nil
  for name, item in pairs(prototypes.item) do
    local entity = item.place_result
    if main and main.get_item_count(name) > 0 and entity and entity.type == "spider-vehicle" then
      local capacity = entity.get_inventory_size(defines.inventory.spider_trunk) or 0
      local order = (item.order or "") .. ":" .. name
      if not best or capacity > best.capacity or (capacity == best.capacity and order < best.order) then
        best = {
          kind = "personal_vehicle",
          item = name,
          count = 1,
          entity_name = entity.name,
          capacity = capacity,
          order = order
        }
      end
    end
  end
  if not best then root.autonomy.loadout_cooldown.personal_vehicle = game.tick + 3600 end
  return best
end

function LoadoutPlanner.next_construction_reserve(agent, root)
  root.autonomy.loadout_cooldown = root.autonomy.loadout_cooldown or {}
  return construction_requirement(agent, root)
end

return LoadoutPlanner
