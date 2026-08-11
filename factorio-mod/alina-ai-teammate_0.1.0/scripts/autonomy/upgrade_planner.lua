local Conflict = require("scripts.conflict.manager")
local EventBus = require("scripts.core.event_bus")

local UpgradePlanner = {}

local SUPPORTED_TYPES = {
  ["assembling-machine"] = true,
  furnace = true,
  ["mining-drill"] = true
}

local function safe_property(object, name, fallback)
  local ok, value = pcall(function() return object[name] end)
  if ok and value ~= nil then return value end
  return fallback
end

local function placement_item(prototype)
  local candidates = {}
  for _, item in ipairs(prototype and prototype.items_to_place_this or {}) do
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

local function product_of_drill(entity, item_name)
  local target = entity.mining_target
  local properties = target and target.valid and target.prototype.mineable_properties or nil
  for _, product in ipairs(properties and properties.products or {}) do
    if product.type == "item" and product.name == item_name then return true end
  end
  return false
end

local function makes_item(entity, item_name)
  if entity.type == "mining-drill" then return product_of_drill(entity, item_name) end
  local recipe = entity.get_recipe()
  for _, product in ipairs(recipe and recipe.products or {}) do
    if product.type == "item" and product.name == item_name then return true end
  end
  return false
end

local function has_input_headroom(entity)
  if entity.type == "mining-drill" then
    return entity.mining_target and entity.mining_target.valid and entity.status == defines.entity_status.working
  end
  if entity.status ~= defines.entity_status.working then return false end
  local recipe = entity.get_recipe()
  local input = entity.get_inventory(defines.inventory.crafter_input)
  if not recipe or not input then return false end
  for _, ingredient in ipairs(recipe.ingredients or {}) do
    if ingredient.type == "item" and input.get_item_count(ingredient.name) < math.max(1, ingredient.amount or 1) then
      return false
    end
  end
  return true
end

local function speed(prototype, entity_type, quality)
  if entity_type == "mining-drill" then return safe_property(prototype, "mining_speed", 0) or 0 end
  local ok, value = pcall(function() return prototype.get_crafting_speed(quality or "normal") end)
  if ok and type(value) == "number" then return value end
  return safe_property(prototype, "crafting_speed", 0) or 0
end

local function supports_work(target, source)
  if source.type == "mining-drill" then
    local mining_target = source.mining_target
    local category = mining_target and mining_target.valid and mining_target.prototype.resource_category or nil
    return category and target.resource_categories and target.resource_categories[category] == true
  end
  local recipe = source.get_recipe()
  if not recipe or not target.crafting_categories then return false end
  for _, category in ipairs(recipe.categories or recipe.prototype.categories or {}) do
    if target.crafting_categories[category] then return true end
  end
  return false
end

local function upgrade_chain(source)
  local result, seen = {}, {}
  local current = source.prototype.next_upgrade
  while current and not seen[current.name] and #result < 6 do
    seen[current.name] = true
    result[#result + 1] = current
    current = current.next_upgrade
  end
  return result
end

local function candidate_for(agent, entity, source)
  local quality = entity.quality and entity.quality.name or "normal"
  -- Never replace a quality machine autonomously.  Fast replacement without
  -- an explicit quality would downgrade it, while acquiring an equivalent
  -- rare-quality upgrade may consume resources the player is reserving.
  if quality ~= "normal" then return nil end
  local old_speed = speed(entity.prototype, entity.type, quality)
  local best = nil
  for _, target in ipairs(upgrade_chain(entity)) do
    local target_speed = speed(target, entity.type, quality)
    if target.type == entity.type and target_speed >= old_speed * 1.10
        and supports_work(target, entity)
        and entity.surface.can_fast_replace({name = target.name, position = entity.position,
          direction = entity.direction, force = entity.force}) then
      local item = placement_item(target)
      local old_item = placement_item(entity.prototype)
      if item and item.count == 1 and old_item and old_item.count == 1 then
        -- Availability is resolved once by the transactional upgrade executor
        -- before the old machine is removed. Running the recursive acquisition
        -- planner while merely ranking candidates caused visible megabase
        -- stalls and duplicated exactly the same safety check.
        local row = {
          entity_unit_number = entity.unit_number,
          old_name = entity.name,
          old_item = old_item.name,
          new_name = target.name,
          new_item = item.name,
          position = {x = entity.position.x, y = entity.position.y},
          direction = entity.direction,
          surface_index = entity.surface.index,
          force_index = entity.force.index,
          quality = quality,
          old_speed = old_speed,
          new_speed = target_speed,
          expected_gain = target_speed / math.max(0.001, old_speed)
        }
        local recipe = entity.type ~= "mining-drill" and entity.get_recipe() or nil
        row.recipe = recipe and recipe.name or nil
        if not best or row.new_speed > best.new_speed then best = row end
      end
    end
  end
  return best
end

-- An upgrade is proposed only for a producer that is currently working and has
-- its immediate inputs. If the line is starved by ore/logistics, the caller falls
-- through to patch/chain expansion instead of wasting an expensive machine.
function UpgradePlanner.plan(player, agent, scan_result, target_item, root, force_scan)
  root.autonomy.upgrade_cooldown = root.autonomy.upgrade_cooldown or {}
  root.autonomy.upgrade_scan_cooldown = root.autonomy.upgrade_scan_cooldown or {}
  -- The throttle protects autonomous large-base scans only. A named player
  -- priority must be evaluated immediately, even if the same item was sampled
  -- moments earlier before a newly-built machine entered the World Model.
  if not force_scan and (root.autonomy.upgrade_scan_cooldown[target_item] or 0) > game.tick then return nil end
  root.autonomy.upgrade_scan_cooldown[target_item] = game.tick + 600
  local entities = {}
  local seen_prototype = {}
  local matching_producers, producers_with_headroom = 0, 0
  for _, entity in ipairs(scan_result.entities or {}) do
    if entity.valid and entity.unit_number and SUPPORTED_TYPES[entity.type]
        and makes_item(entity, target_item) then
      matching_producers = matching_producers + 1
      if has_input_headroom(entity) then
        producers_with_headroom = producers_with_headroom + 1
        if not Conflict.is_blocked(entity.surface.index, entity.position, "autonomous")
            and (root.autonomy.upgrade_cooldown[entity.unit_number] or 0) <= game.tick
            and not seen_prototype[entity.name] then
          seen_prototype[entity.name] = true
          entities[#entities + 1] = entity
        end
      end
    end
  end
  table.sort(entities, function(a, b) return a.unit_number < b.unit_number end)
  local best_candidate = nil
  for index = 1, math.min(8, #entities) do
    local candidate = candidate_for(agent, entities[index], "autonomous")
    if candidate and (not best_candidate
        or candidate.expected_gain > best_candidate.expected_gain
        or (candidate.expected_gain == best_candidate.expected_gain
          and candidate.entity_unit_number < best_candidate.entity_unit_number)) then
      best_candidate = candidate
    end
  end
  if best_candidate then
    root.autonomy.upgrade_cooldown[best_candidate.entity_unit_number] = game.tick + 36000
    best_candidate.target_item = target_item
    if force_scan then
      EventBus.emit("machine_upgrade_selected_for_priority", {
        target_item = target_item,
        old_name = best_candidate.old_name,
        new_name = best_candidate.new_name,
        expected_gain = best_candidate.expected_gain,
        matching_producers = matching_producers,
        producers_with_headroom = producers_with_headroom
      })
    end
    return best_candidate
  end
  if force_scan then
    EventBus.emit("machine_upgrade_unavailable_for_priority", {
      target_item = target_item,
      indexed_machines = #(scan_result.entities or {}),
      matching_producers = matching_producers,
      producers_with_headroom = producers_with_headroom,
      eligible_prototypes = #entities
    })
  end
  return nil
end

return UpgradePlanner
