local Acquisition = require("scripts.executor.acquisition")
local EventBus = require("scripts.core.event_bus")
local TaskManager = require("scripts.tasks.manager")
local State = require("scripts.core.state")
local Identity = require("scripts.core.identity")
local Conflict = require("scripts.conflict.manager")

local Loadout = {}

local function main_count(agent, item)
  local main = agent.get_inventory(defines.inventory.character_main)
  return main and main.get_item_count(item) or 0
end

local function fuel_burner(agent, requirement)
  if requirement.fuel_owner == "vehicle" then
    local root = State.ensure()
    local unit = requirement.fuel_vehicle_unit
    local vehicle = unit and game.get_entity_by_unit_number(unit) or nil
    local ownership = unit and root.owned_entities[unit] or nil
    if vehicle and vehicle.valid and vehicle.burner and ownership and ownership.owner == "alina" then
      return vehicle.burner
    end
    return nil
  end
  if requirement.fuel_owner == "equipment" then
    local grid = agent.grid
    local position = requirement.fuel_equipment_position
    local equipment = grid and grid.valid and position and grid.get(position) or nil
    if equipment and equipment.valid and equipment.name == requirement.fuel_equipment_name then
      return equipment.burner
    end
  end
  return nil
end

local function equipped_count(agent, requirement)
  if requirement.kind == "construction_reserve" then return main_count(agent, requirement.item) end
  if requirement.kind == "fuel" then
    local burner = fuel_burner(agent, requirement)
    return burner and burner.valid and burner.inventory.get_item_count(requirement.item) or 0
  end
  if requirement.kind == "personal_vehicle" then
    local root = State.ensure()
    local entity = root.agent.personal_vehicle_unit
      and game.get_entity_by_unit_number(root.agent.personal_vehicle_unit) or nil
    return entity and entity.valid and entity.type == "spider-vehicle" and 1 or 0
  end
  if requirement.kind == "equipment" then
    local grid = agent.grid
    return grid and grid.count(requirement.equipment_name) or 0
  end
  local inventory_id = requirement.kind == "armor" and defines.inventory.character_armor
    or requirement.kind == "gun" and defines.inventory.character_guns
    or defines.inventory.character_ammo
  local inventory = agent.get_inventory(inventory_id)
  if not inventory then return 0 end
  if requirement.inventory_slot then
    local stack = inventory[requirement.inventory_slot]
    return stack.valid_for_read and stack.name == requirement.item and stack.count or 0
  end
  return inventory.get_item_count(requirement.item)
end

local function place_personal_vehicle(agent, requirement)
  local prototype = requirement.entity_name and prototypes.entity[requirement.entity_name] or nil
  if not prototype or prototype.type ~= "spider-vehicle" then
    return false, "Выданный транспорт больше не существует в текущем наборе модов."
  end
  local root = State.ensure()
  local position = agent.surface.find_non_colliding_position(
    prototype.name, {x = agent.position.x + 3, y = agent.position.y},
    math.max(4, math.min(12, agent.build_distance)), 0.5, true)
  if not position or Conflict.is_blocked(agent.surface.index, position, "autonomous")
      or not agent.surface.can_place_entity({
      name = prototype.name, position = position, force = agent.force}) then
    return false, "Рядом нет безопасного места для личного паукотрона; предмет оставила в инвентаре."
  end
  local removed = agent.remove_item({name = requirement.item, count = 1})
  if removed ~= 1 then return false, "Выданный паукотрон исчез из инвентаря." end
  local vehicle = agent.surface.create_entity({
    name = prototype.name,
    position = position,
    force = agent.force,
    raise_built = true,
    create_build_effect_smoke = true
  })
  if not vehicle then
    agent.insert({name = requirement.item, count = 1})
    return false, "Factorio не разрешила поставить личный паукотрон."
  end
  vehicle.name_tag = Identity.name()
  root.agent.personal_vehicle_unit = vehicle.unit_number
  root.owned_entities[vehicle.unit_number] = {
    task_id = root.task.current and root.task.current.id or nil,
    entity = vehicle.name,
    kind = "personal_vehicle",
    owner = "alina",
    surface_index = vehicle.surface.index,
    position = {x = vehicle.position.x, y = vehicle.position.y},
    built_tick = game.tick
  }
  if not vehicle.get_driver() then vehicle.set_driver(agent) end
  return true
end

local function target_inventory(agent, requirement)
  if requirement.kind == "armor" then return agent.get_inventory(defines.inventory.character_armor) end
  if requirement.kind == "gun" then return agent.get_inventory(defines.inventory.character_guns) end
  if requirement.kind == "ammo" then return agent.get_inventory(defines.inventory.character_ammo) end
  return nil
end

local function equip_armor(agent, requirement)
  local armor = agent.get_inventory(defines.inventory.character_armor)
  local main = agent.get_inventory(defines.inventory.character_main)
  local target = armor and armor[1] or nil
  if not target or not main then return false, "Нет инвентаря для безопасной замены брони." end
  local prepared = nil
  for index = 1, #main do
    if main[index].valid_for_read and main[index].name == requirement.item then prepared = main[index]; break end
  end
  if not prepared then return false, "Подготовленная броня исчезла из инвентаря." end
  if not target.valid_for_read then
    target.swap_stack(prepared)
    return target.valid_for_read and target.name == requirement.item,
      "Factorio не приняла подготовленную броню."
  end
  if target.name == requirement.item then return true end
  local safe_slot = nil
  for index = 1, #main do
    if not main[index].valid_for_read then safe_slot = main[index]; break end
  end
  if not safe_slot then return false, "Для замены брони нужен один свободный слот; старую броню не трогаю." end
  target.swap_stack(safe_slot)
  if target.valid_for_read then return false, "Не смогла безопасно снять старую броню." end
  target.swap_stack(prepared)
  if target.valid_for_read and target.name == requirement.item then return true end
  if not target.valid_for_read and safe_slot.valid_for_read then target.swap_stack(safe_slot) end
  return false, "Замена брони не прошла проверку; восстановила прежнюю."
end

local function equip_grid_item(agent, requirement)
  local grid = agent.grid
  if not grid or not grid.valid or grid.prototype.locked then
    return false, "У текущей брони нет доступной сетки экипировки."
  end
  if not requirement.equipment_name or not prototypes.equipment[requirement.equipment_name] then
    return false, "Прототип модуля экипировки больше недоступен."
  end
  if grid.count(requirement.equipment_name) >= requirement.count then return true end
  local removed = agent.remove_item({name = requirement.item, count = 1})
  if removed ~= 1 then return false, "Подготовленный модуль экипировки исчез из инвентаря." end
  local equipment = grid.put({name = requirement.equipment_name})
  if not equipment then
    agent.insert({name = requirement.item, count = 1})
    return false, "Модуль не помещается в сетку; сохранила его в инвентаре."
  end
  return true
end

local function refuel(agent, requirement)
  local burner = fuel_burner(agent, requirement)
  if not burner or not burner.valid or not burner.inventory or not burner.inventory.valid then
    return false, "Источник энергии изменился; подготовленное топливо сохранила в инвентаре."
  end
  local present = burner.inventory.get_item_count(requirement.item)
  local missing = math.max(0, requirement.count - present)
  if missing == 0 then return true end
  local removed = agent.remove_item({name = requirement.item, count = missing})
  if removed ~= missing then
    if removed > 0 then agent.insert({name = requirement.item, count = removed}) end
    return false, "Подготовленное топливо исчезло из инвентаря; источник энергии не изменяю."
  end
  local inserted = burner.inventory.insert({name = requirement.item, count = removed})
  if inserted < removed then agent.insert({name = requirement.item, count = removed - inserted}) end
  if inserted == 0 then
    return false, "Источник энергии не принял совместимое топливо; сохранила его в инвентаре."
  end
  return burner.inventory.get_item_count(requirement.item) >= math.max(1, requirement.count - 1),
    "Не удалось пополнить запас топлива до безопасного уровня."
end

local function equip(agent, requirement)
  if requirement.kind == "construction_reserve" then return true end
  if requirement.kind == "fuel" then return refuel(agent, requirement) end
  if requirement.kind == "personal_vehicle" then return place_personal_vehicle(agent, requirement) end
  if requirement.kind == "armor" then return equip_armor(agent, requirement) end
  if requirement.kind == "equipment" then return equip_grid_item(agent, requirement) end
  local inventory = target_inventory(agent, requirement)
  local slot = inventory and inventory[requirement.inventory_slot or 1] or nil
  if not slot then return false, "Нет подходящего слота экипировки." end
  if slot.valid_for_read and slot.name ~= requirement.item then
    return false, "Слот экипировки уже занят другим предметом; ничего не заменяю." 
  end
  local present = slot.valid_for_read and slot.count or 0
  local missing = math.max(0, requirement.count - present)
  if missing == 0 then return true end
  local removed = agent.remove_item({name = requirement.item, count = missing})
  if removed ~= missing then
    if removed > 0 then agent.insert({name = requirement.item, count = removed}) end
    return false, "Подготовленный предмет экипировки исчез из инвентаря."
  end
  if not slot.valid_for_read then
    slot.set_stack({name = requirement.item, count = removed})
  else
    slot.count = slot.count + removed
  end
  if not slot.valid_for_read or slot.name ~= requirement.item or slot.count < requirement.count then
    agent.insert({name = requirement.item, count = removed})
    return false, "Factorio не приняла предмет в слот экипировки."
  end
  return true
end

function Loadout.tick(task, agent)
  local requirement = task.loadout
  if not requirement or not prototypes.item[requirement.item] then
    TaskManager.fail("План личного запаса устарел после изменения модов.")
    return
  end
  if equipped_count(agent, requirement) >= requirement.count then
    EventBus.emit("loadout_requirement_completed", {
      task_id = task.id,
      kind = requirement.kind,
      item = requirement.item,
      count = requirement.count
    })
    local message = requirement.kind == "fuel"
      and ("Пополнила топливо: " .. requirement.count .. " × " .. requirement.item .. ".")
      or ("Подготовила личный запас: " .. requirement.count .. " × " .. requirement.item .. ".")
    TaskManager.complete(message)
    return
  end
  if not task.acquisition then
    local required_in_main = requirement.kind == "construction_reserve"
      and requirement.count or math.max(0, requirement.count - equipped_count(agent, requirement))
    local ok, message = Acquisition.start(task, agent, requirement.item, required_in_main)
    if not ok then TaskManager.fail(message); return end
    task.phase = "acquiring_loadout"
    return
  end
  local status = Acquisition.tick(task, agent)
  if status ~= "done" then return end
  task.acquisition = nil
  local ok, message = equip(agent, requirement)
  if not ok then TaskManager.fail(message); return end
  EventBus.emit("loadout_requirement_completed", {
    task_id = task.id,
    kind = requirement.kind,
    item = requirement.item,
    count = requirement.count
  })
  local message = requirement.kind == "fuel"
    and ("Пополнила топливо: " .. requirement.count .. " × " .. requirement.item .. ".")
    or ("Подготовила личный запас: " .. requirement.count .. " × " .. requirement.item .. ".")
  TaskManager.complete(message)
end

return Loadout
