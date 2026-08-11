local State = require("scripts.core.state")
local TaskManager = require("scripts.tasks.manager")
local Conflict = require("scripts.conflict.manager")
local WorldModel = require("scripts.sensors.world_model")
local EventBus = require("scripts.core.event_bus")
local ChainPlanner = require("scripts.autonomy.chain_planner")
local LoadoutPlanner = require("scripts.autonomy.loadout_planner")
local AssemblyPlanner = require("scripts.autonomy.assembly_planner")
local FluidPlanner = require("scripts.autonomy.fluid_planner")
local ResearchControl = require("scripts.chat.research_control")
local SitePolicy = require("scripts.construction.site_policy")
local RecipeIndex = require("scripts.sensors.recipe_index")
local PrototypeIndex = require("scripts.sensors.prototype_index")
local UpgradePlanner = require("scripts.autonomy.upgrade_planner")

local LocalPlanner = {}

local CRAFTING_TYPES = { ["assembling-machine"] = true, furnace = true, ["rocket-silo"] = true }
local CLONE_TYPES = {
  ["assembling-machine"] = true,
  furnace = true,
  ["mining-drill"] = true,
  inserter = true,
  ["transport-belt"] = true,
  ["underground-belt"] = true,
  splitter = true,
  ["electric-pole"] = true,
  pipe = true,
  ["pipe-to-ground"] = true,
  loader = true,
  ["loader-1x1"] = true,
  container = true,
  ["logistic-container"] = true,
  ["linked-container"] = true,
  ["storage-tank"] = true,
  pump = true,
  beacon = true,
  ["heat-pipe"] = true,
  ["linked-belt"] = true
}

local INPUT_SHORTAGE_STATUS = {}
local OUTPUT_BLOCKED_STATUS = {}
for _, name in ipairs({"no_ingredients", "item_ingredient_shortage", "fluid_ingredient_shortage"}) do
  local value = defines.entity_status[name]
  if value then INPUT_SHORTAGE_STATUS[value] = true end
end
for _, name in ipairs({"full_output", "not_enough_space_in_output", "waiting_for_space_in_destination"}) do
  local value = defines.entity_status[name]
  if value then OUTPUT_BLOCKED_STATUS[value] = true end
end

local function player_for(root, requested_player_index)
  local requested = requested_player_index and game.get_player(requested_player_index) or nil
  if requested and requested.valid then return requested end
  local owner = root.agent.owner_player_index and game.get_player(root.agent.owner_player_index) or nil
  if owner and owner.connected then return owner end
  return game.connected_players[1]
end

local function distance_squared(a, b)
  local dx = a.x - b.x
  local dy = a.y - b.y
  return dx * dx + dy * dy
end

local function flow_counts(player, value_type, name)
  local statistics = value_type == "fluid"
    and player.force.get_fluid_production_statistics(player.surface)
    or player.force.get_item_production_statistics(player.surface)
  local minute = defines.flow_precision_index.one_minute
  return statistics.get_flow_count({name = name, category = "input", precision_index = minute}) or 0,
    statistics.get_flow_count({name = name, category = "output", precision_index = minute}) or 0
end

local function ingredient_available(entity, ingredient)
  if ingredient.type == "fluid" then
    local ok, count = pcall(function() return entity.get_fluid_count(ingredient.name) end)
    return ok and count or 0
  end
  local inventory = entity.get_inventory(defines.inventory.crafter_input)
  return inventory and inventory.get_item_count(ingredient.name) or 0
end

local function producer_health(player, scan_result, target_item)
  local health = {total = 0, working = 0, input_shortage = 0, output_blocked = 0,
    other = 0, missing_ingredients = {}}
  local missing = {}
  for _, group in pairs(scan_result.recipes or {}) do
    local makes_target = false
    for _, product in ipairs(group.products or {}) do
      if product == target_item then makes_target = true; break end
    end
    if makes_target then
      for _, entity in ipairs(group.entities or {}) do
        if entity.valid then
          health.total = health.total + 1
          if entity.status == defines.entity_status.working then
            health.working = health.working + 1
          elseif INPUT_SHORTAGE_STATUS[entity.status] then
            health.input_shortage = health.input_shortage + 1
            for _, ingredient in ipairs(group.recipe.ingredients or {}) do
              if (ingredient.type == "item" or ingredient.type == "fluid")
                  and ingredient_available(entity, ingredient) + 0.0001 < (ingredient.amount or 1) then
                local key = ingredient.type .. ":" .. ingredient.name
                local row = missing[key]
                if not row then
                  local produced, consumed = flow_counts(player, ingredient.type, ingredient.name)
                  row = {type = ingredient.type, name = ingredient.name, machines = 0,
                    produced = produced, consumed = consumed,
                    supply_ratio = produced / math.max(0.001, consumed)}
                  missing[key] = row
                end
                row.machines = row.machines + 1
              end
            end
          elseif OUTPUT_BLOCKED_STATUS[entity.status] then
            health.output_blocked = health.output_blocked + 1
          else
            health.other = health.other + 1
          end
        end
      end
    end
  end
  for _, row in pairs(missing) do health.missing_ingredients[#health.missing_ingredients + 1] = row end
  table.sort(health.missing_ingredients, function(a, b)
    if a.machines ~= b.machines then return a.machines > b.machines end
    if a.supply_ratio ~= b.supply_ratio then return a.supply_ratio < b.supply_ratio end
    if a.type ~= b.type then return a.type < b.type end
    return a.name < b.name
  end)
  health.input_shortage_ratio = health.input_shortage / math.max(1, health.total)
  health.output_blocked_ratio = health.output_blocked / math.max(1, health.total)
  health.working_ratio = health.working / math.max(1, health.total)
  health.limiting_ingredient = health.missing_ingredients[1]
  if health.total > 0 and health.input_shortage_ratio >= 0.5 then
    health.strategy = "upstream"
  elseif health.total > 0 and health.output_blocked_ratio >= 0.5 then
    health.strategy = "logistics"
  else
    health.strategy = "capacity"
  end
  return health
end

local function production_candidates(player, scan_result)
  local stats = player.force.get_item_production_statistics(player.surface)
  local minute = defines.flow_precision_index.one_minute
  local ten_minutes = defines.flow_precision_index.ten_minutes
  local target_headroom = 0.15
  local deficits, activity, seen = {}, {}, {}
  local session_age = game.tick - (State.ensure().autonomy.session_started_tick or game.tick)
  local examined = 0
  for _, group in pairs(scan_result.recipes) do
    for _, item in ipairs(group.products) do
      if not seen[item] and examined < 256 then
        seen[item] = true
        examined = examined + 1
        local produced = stats.get_flow_count({name = item, category = "input", precision_index = minute}) or 0
        local consumed = stats.get_flow_count({name = item, category = "output", precision_index = minute}) or 0
        local produced_sustained = stats.get_flow_count({name = item, category = "input", precision_index = ten_minutes}) or 0
        local consumed_sustained = stats.get_flow_count({name = item, category = "output", precision_index = ten_minutes}) or 0
        local desired = consumed * (1 + target_headroom)
        local gap = desired - produced
        local sustained_pressure = consumed_sustained > 0.05
          and produced_sustained < consumed_sustained * 1.08
        local warmed_recent_pressure = consumed_sustained <= 0.05 and session_age >= 1800
        if consumed > 0.05 and gap > math.max(0.05, desired * 0.03)
            and (sustained_pressure or warmed_recent_pressure) then
          local consumers = RecipeIndex.consumer_count(item, player.force)
          local ratio = gap / math.max(0.05, desired)
          local impact = 1 + math.min(12, consumers) * 0.20
          local health = producer_health(player, scan_result, item)
          deficits[#deficits + 1] = {item = item, gap = gap, produced = produced, consumed = consumed,
            produced_sustained = produced_sustained, consumed_sustained = consumed_sustained,
            desired = desired, headroom = (produced - consumed) / math.max(0.05, consumed),
            consumers = consumers, ratio = ratio, score = gap * impact * math.min(4, 1 + ratio),
            health = health, recent_pressure = warmed_recent_pressure}
        end
        if produced > 0.05 or consumed > 0.05 then
          activity[#activity + 1] = {item = item, consumed = consumed, produced = produced}
        end
      end
    end
  end
  table.sort(deficits, function(a, b)
    if a.score == b.score then return a.item < b.item end
    return a.score > b.score
  end)
  table.sort(activity, function(a, b)
    local sa = math.max(a.produced, a.consumed)
    local sb = math.max(b.produced, b.consumed)
    if sa == sb then return a.item < b.item end
    return sa > sb
  end)
  return deficits, activity
end

local function development_candidates(player, scan_result, activity)
  local by_item = {}
  for _, row in ipairs(activity or {}) do
    by_item[row.item] = {
      item = row.item,
      produced = row.produced or 0,
      consumed = row.consumed or 0,
      machine_count = 0
    }
  end
  for _, group in pairs(scan_result.recipes or {}) do
    for _, item in ipairs(group.products or {}) do
      local row = by_item[item]
      if not row then row = {item = item, produced = 0, consumed = 0, machine_count = 0}; by_item[item] = row end
      row.machine_count = row.machine_count + #group.entities
    end
  end
  for _, entity in ipairs(scan_result.entities or {}) do
    if entity.valid and entity.type == "mining-drill" then
      local target = entity.mining_target
      local properties = target and target.valid and target.prototype.mineable_properties or nil
      for _, product in ipairs(properties and properties.products or {}) do
        if product.type == "item" and prototypes.item[product.name] then
          local row = by_item[product.name]
          if not row then
            row = {item = product.name, produced = 0, consumed = 0, machine_count = 0}
            by_item[product.name] = row
          end
          row.machine_count = row.machine_count + 1
        end
      end
    end
  end

  local result = {}
  for _, row in pairs(by_item) do
    row.consumers = RecipeIndex.consumer_count(row.item, player.force)
    local pressure = math.max(0, row.consumed * 1.15 - row.produced)
    local flow = math.max(row.produced, row.consumed)
    -- Runtime recipe connectivity replaces hard-coded vanilla priorities. An
    -- item feeding many unlocked recipes remains useful even when the recent
    -- production window is empty immediately after loading an existing save.
    row.score = pressure * 1000000 + flow * 10000
      + math.min(64, row.consumers) * 100 + math.min(64, row.machine_count)
    result[#result + 1] = row
  end
  table.sort(result, function(a, b)
    if a.score == b.score then return a.item < b.item end
    return a.score > b.score
  end)
  return result
end

local function foundation_candidates(player, agent, scan_result)
  if not PrototypeIndex.is_ready() or not RecipeIndex.is_ready() then return {} end
  local root = State.ensure()
  local cached = root.autonomy.foundation_audit
  if cached and cached.surface_index == player.surface.index
      and cached.force_index == player.force.index
      and game.tick < (root.autonomy.foundation_audit_tick or 0) then
    return cached.candidates or {}
  end

  local mined, produced_by_machine = {}, {}
  local patch_health, seen_patches, inspected_patches = {}, {}, 0
  local function health_for(item_name)
    local health = patch_health[item_name]
    if not health then
      health = {
        developed = 0,
        underdeveloped = 0,
        depleted = 0,
        developed_centers = {},
        underdeveloped_centers = {},
        depleted_centers = {}
      }
      patch_health[item_name] = health
    end
    return health
  end

  for _, entity in ipairs(scan_result.entities or {}) do
    if entity.valid and entity.type == "mining-drill" then
      local target = entity.mining_target
      local properties = target and target.valid and target.prototype.mineable_properties or nil
      local product_names = {}
      for _, product in ipairs(properties and properties.products or {}) do
        if product.type == "item" and prototypes.item[product.name] then
          mined[product.name] = (mined[product.name] or 0) + 1
          product_names[#product_names + 1] = product.name
        end
      end

      local key = target and (target.name .. ":" .. tostring(math.floor(target.position.x / 64))
        .. ":" .. tostring(math.floor(target.position.y / 64))) or nil
      if key and #product_names > 0 and not seen_patches[key] and inspected_patches < 32 then
        seen_patches[key] = true
        inspected_patches = inspected_patches + 1
        local resources = target.surface.find_entities_filtered({
          position = target.position, radius = 32, type = "resource", name = target.name, limit = 2048
        })
        local current, initial, center_x, center_y, resource_tiles = 0, 0, 0, 0, 0
        for _, resource in ipairs(resources) do
          if resource.valid and resource.amount and resource.amount > 0 then
            current = current + resource.amount
            local ok, value = pcall(function() return resource.initial_amount end)
            initial = initial + (ok and value and value > 0 and value or resource.amount)
            center_x = center_x + resource.position.x
            center_y = center_y + resource.position.y
            resource_tiles = resource_tiles + 1
          end
        end
        local center = resource_tiles > 0 and {
          x = center_x / resource_tiles,
          y = center_y / resource_tiles,
          radius = 48
        } or {x = target.position.x, y = target.position.y, radius = 48}
        local drill_count, estimated_coverage = 0, 0
        for _, drill_entity in ipairs(target.surface.find_entities_filtered({
            position = {x = center.x, y = center.y}, radius = 40,
            type = "mining-drill", force = player.force, limit = 256})) do
          local drill_target = drill_entity.valid and drill_entity.mining_target or nil
          if drill_target and drill_target.valid and drill_target.name == target.name then
            drill_count = drill_count + 1
            local ok, radius = pcall(function() return drill_entity.prototype.get_mining_drill_radius() end)
            radius = ok and radius or 1
            estimated_coverage = estimated_coverage + (radius * 2 + 1) ^ 2
          end
        end
        local depleted = initial > 0 and current / initial <= 0.50
        -- Two token drills are not a developed patch. Approximate the useful
        -- covered area from the live unlocked drill prototypes and require most
        -- of the ore footprint to be served before accepting this foundation.
        local developed = not depleted and drill_count >= 2
          and estimated_coverage >= math.max(2, resource_tiles * 0.75)
        for _, item_name in ipairs(product_names) do
          local health = health_for(item_name)
          if depleted then
            health.depleted = health.depleted + 1
            health.depleted_centers[#health.depleted_centers + 1] = center
          elseif developed then
            health.developed = health.developed + 1
            health.developed_centers[#health.developed_centers + 1] = center
          else
            health.underdeveloped = health.underdeveloped + 1
            health.underdeveloped_centers[#health.underdeveloped_centers + 1] = center
          end
        end
      end
    end
  end
  for _, group in pairs(scan_result.recipes or {}) do
    for _, item_name in ipairs(group.products or {}) do
      produced_by_machine[item_name] = (produced_by_machine[item_name] or 0) + #group.entities
    end
  end

  local ranked = {}
  for _, raw in ipairs(PrototypeIndex.resource_products()) do
    local processed = RecipeIndex.resource_processing_candidates(player.force, raw.item, 1)[1]
    local target = processed and processed.item or raw.item
    local raw_produced = select(1, flow_counts(player, "item", raw.item))
    local target_produced = target == raw.item and raw_produced
      or select(1, flow_counts(player, "item", target))
    local health = patch_health[raw.item] or {
      developed = 0, underdeveloped = 0, depleted = 0,
      developed_centers = {}, underdeveloped_centers = {}, depleted_centers = {}
    }
    local has_mining = health.developed > 0
    local depleted_requires_alternate = health.depleted > 0 and health.developed == 0
    local partial_requires_development = health.underdeveloped > 0 and health.developed == 0
    local new_patch_required = depleted_requires_alternate or partial_requires_development
    local has_processing = target == raw.item
      or (produced_by_machine[target] or 0) > 0 or target_produced > 0.05
    if not has_mining or not has_processing or new_patch_required then
      local raw_consumers = RecipeIndex.consumer_count(raw.item, player.force)
      local target_consumers = RecipeIndex.consumer_count(target, player.force)
      ranked[#ranked + 1] = {
        raw_item = raw.item,
        item = target,
        mining_missing = not has_mining,
        processing_missing = not has_processing,
        new_patch_required = new_patch_required,
        depleted_requires_alternate = depleted_requires_alternate,
        partial_requires_development = partial_requires_development,
        exclusion_centers = {},
        consumers = raw_consumers + target_consumers,
        score = target_consumers * 10000 + raw_consumers * 1000
          + (processed and 100 or 0)
          + (depleted_requires_alternate and 100000000 or 0)
          + (partial_requires_development and 50000000 or 0)
      }
      local row = ranked[#ranked]
      for _, center in ipairs(health.depleted_centers) do row.exclusion_centers[#row.exclusion_centers + 1] = center end
      -- An underdeveloped, healthy patch must receive another bounded section.
      -- Only depleted patches are excluded; otherwise a partial first section
      -- incorrectly forced Alina to abandon usable ore and search for a new vein.
      if not partial_requires_development and has_mining and not has_processing then
        for _, center in ipairs(health.developed_centers) do row.exclusion_centers[#row.exclusion_centers + 1] = center end
      end
    end
  end
  table.sort(ranked, function(a, b)
    if a.score == b.score then
      if a.raw_item == b.raw_item then return a.item < b.item end
      return a.raw_item < b.raw_item
    end
    return a.score > b.score
  end)

  -- A Space Age overhaul can expose many planet-specific resource prototypes.
  -- Proving all of them absent on the current surface in one update caused an
  -- 8-second planning hitch. Probe at most one uncached resource per autonomy
  -- pass; absent products receive a surface-local ten-minute negative cache,
  -- so subsequent passes advance through the modded set without repeating the
  -- expensive world query or losing eventual mod awareness.
  local result = {}
  root.autonomy.absent_resource_until = root.autonomy.absent_resource_until or {}
  local surface_absent = root.autonomy.absent_resource_until[player.surface.index]
  if not surface_absent then
    surface_absent = {}
    root.autonomy.absent_resource_until[player.surface.index] = surface_absent
  end
  local lookups = 0
  for index = 1, #ranked do
    local candidate = ranked[index]
    if (surface_absent[candidate.raw_item] or 0) <= game.tick then
      lookups = lookups + 1
      local exclusions = #candidate.exclusion_centers > 0 and candidate.exclusion_centers or nil
      local resource = PrototypeIndex.find_resource(agent, candidate.raw_item, "autonomous", 768, true, exclusions, true)
      if not resource and candidate.partial_requires_development
          and not candidate.depleted_requires_alternate then
        -- If no second patch exists, safely fill the free part of the starter
        -- patch instead of giving up. SitePolicy still protects every player cell.
        candidate.exclusion_centers = {}
        candidate.new_patch_required = false
        resource = PrototypeIndex.find_resource(agent, candidate.raw_item, "autonomous", 768, true, nil, true)
      end
      if resource then
        surface_absent[candidate.raw_item] = nil
        candidate.resource = {name = resource.name,
          position = {x = resource.position.x, y = resource.position.y}}
        result[#result + 1] = candidate
        break
      end
      surface_absent[candidate.raw_item] = game.tick + 36000
      if lookups >= 1 then break end
    end
  end
  root.autonomy.foundation_audit = {
    surface_index = player.surface.index,
    force_index = player.force.index,
    candidates = result
  }
  root.autonomy.foundation_audit_tick = game.tick + (#result > 0 and 900 or 600)
  return result
end

local function canonical_vector(dx, dy)
  if dx < 0 or (math.abs(dx) < 0.05 and dy < 0) then dx, dy = -dx, -dy end
  return dx, dy
end

local function vector_key(dx, dy)
  return string.format("%.2f:%.2f", dx, dy)
end

local function near_position(a, b, tolerance)
  return distance_squared(a, b) <= (tolerance or 0.2) ^ 2
end

local function position_key(position)
  return string.format("%.3f:%.3f", position.x, position.y)
end

local function producer_at(group, position)
  if not group._position_index then
    group._position_index = {}
    for _, entity in ipairs(group.entities) do
      if entity.valid then group._position_index[position_key(entity.position)] = entity end
    end
  end
  local indexed = group._position_index[position_key(position)]
  if indexed and indexed.valid then return indexed end
  -- Exact entity centres and repeated vectors share the same millitile key.
  -- A tolerance fallback is useful for a small irregular modded layout, but on
  -- a 3k-machine grid every missing edge otherwise triggered another complete
  -- linear scan (tens of millions of comparisons in one autonomy pulse).
  if #group.entities <= 64 then
    for _, entity in ipairs(group.entities) do
      if entity.valid and near_position(entity.position, position, 0.25) then return entity end
    end
  end
  return nil
end

local function repeated_step(group)
  if #group.entities < 2 then return nil end
  local ordered = {}
  for _, entity in ipairs(group.entities) do if entity.valid then ordered[#ordered + 1] = entity end end
  table.sort(ordered, function(a, b)
    if a.position.x ~= b.position.x then return a.position.x < b.position.x end
    if a.position.y ~= b.position.y then return a.position.y < b.position.y end
    return (a.unit_number or 0) < (b.unit_number or 0)
  end)
  -- Pairwise vector voting is quadratic. Thirty-two evenly distributed
  -- representatives still cover the full footprint of a huge repeated block
  -- while bounding the comparison set to 496 pairs instead of 8k+.
  local sample = ordered
  if #ordered > 32 then
    sample = {}
    for index = 1, 32 do
      local source_index = math.floor((index - 1) * (#ordered - 1) / 31) + 1
      sample[#sample + 1] = ordered[source_index]
    end
  end
  local candidates = {}
  for i = 1, #sample do
    for j = i + 1, #sample do
      local dx = sample[j].position.x - sample[i].position.x
      local dy = sample[j].position.y - sample[i].position.y
      local d2v = dx * dx + dy * dy
      if d2v >= 4 and d2v <= 400 then
        dx, dy = canonical_vector(dx, dy)
        local key = vector_key(dx, dy)
        local candidate = candidates[key]
        if not candidate then
          candidate = {x = dx, y = dy, distance2 = d2v, links = 0, key = key}
          candidates[key] = candidate
        end
        candidate.links = candidate.links + 1
      end
    end
  end

  local best, best_links, best_distance = nil, 0, nil
  for _, vector in pairs(candidates) do
    if vector.links > best_links
        or (vector.links == best_links and vector.links > 0
          and (not best_distance or vector.distance2 < best_distance
            or (vector.distance2 == best_distance and vector.key < best.key))) then
      best, best_links, best_distance = vector, vector.links, vector.distance2
    end
  end
  if not best or best_links < 1 then return nil end
  return best, best_links
end

local function construction_network(surface, force, position)
  local networks = surface.find_logistic_networks_by_construction_area(position, force)
  for _, network in ipairs(networks or {}) do
    if network.valid and network.all_construction_robots > 0 then return network end
  end
  return nil
end

local function resource_yields_item(resource, item_name)
  local properties = resource.valid and resource.prototype.mineable_properties or nil
  for _, product in ipairs(properties and properties.products or {}) do
    if product.type == "item" and product.name == item_name then return true end
  end
  return false
end

local function drill_covers_product(surface, drill_name, position, item_name)
  local prototype = prototypes.entity[drill_name]
  if not prototype or prototype.type ~= "mining-drill" then return false end
  local radius = prototype.get_mining_drill_radius()
  local categories = prototype.resource_categories or {}
  local resources = surface.find_entities_filtered({
    area = {
      {position.x - radius, position.y - radius},
      {position.x + radius, position.y + radius}
    },
    type = "resource",
    limit = 128
  })
  for _, resource in ipairs(resources) do
    if resource.valid and resource.amount and resource.amount > 0
        and categories[resource.prototype.resource_category]
        and resource_yields_item(resource, item_name) then return true end
  end
  return false
end

local function cell_template(layout_source, layout_previous, outward, producer_source, target_item)
  local step = math.sqrt(outward.x * outward.x + outward.y * outward.y)
  if step < 1 then return nil, nil, nil, nil, "invalid_step" end
  local ux, uy = outward.x / step, outward.y / step
  local px, py = -uy, ux
  -- Entity centres snap differently by footprint (for example a 2x2 furnace
  -- is integer-centred while its 1x1 output chest is half-tile-centred). Keep
  -- a small tile margin so the final output container belongs to the cell.
  local half_along = math.max(1.1, step * 0.5 + 0.6)
  local half_perp = math.min(14, math.max(5.5, step * 2.0))
  local around = layout_source.surface.find_entities_filtered({
    position = layout_source.position,
    radius = half_along + half_perp + step + 2,
    force = layout_source.force
  })
  local nearby_index = {}
  for _, entity in ipairs(around) do
    if entity.valid and CLONE_TYPES[entity.type] then
      local key = entity.name .. "|" .. tostring(entity.direction) .. "|" .. position_key(entity.position)
      nearby_index[key] = entity
    end
  end
  local function matching(source, position)
    local key = source.name .. "|" .. tostring(source.direction) .. "|" .. position_key(position)
    local entity = nearby_index[key]
    return entity and entity.valid and entity or nil
  end
  local rows, producer_row, support = {}, nil, 0
  local remote = true
  for _, entity in ipairs(around) do
    if entity.valid and entity.unit_number and CLONE_TYPES[entity.type] then
      local rx = entity.position.x - layout_source.position.x
      local ry = entity.position.y - layout_source.position.y
      local along = rx * ux + ry * uy
      local perp = rx * px + ry * py
      if math.abs(along) <= half_along and math.abs(perp) <= half_perp then
        local previous_position = {x = entity.position.x - outward.x, y = entity.position.y - outward.y}
        local repeated = matching(entity, previous_position)
        if repeated then
          local target = {x = entity.position.x + outward.x, y = entity.position.y + outward.y}
          local existing = matching(entity, target)
          if not existing then
            if Conflict.is_blocked(layout_source.surface.index, target, "autonomous") then
              return nil, nil, nil, nil, "player_conflict"
            end
            local placeable, needs_tree_clearance = SitePolicy.can_plan(
              layout_source.surface, layout_source.force, entity.name, target, entity.direction)
            if not placeable then
              return nil, nil, nil, nil, "target_occupied"
            end
            local target_name = entity == layout_source and producer_source.name or entity.name
            if entity.type == "mining-drill"
                and not drill_covers_product(layout_source.surface, target_name, target, target_item) then
              return nil, nil, nil, nil, "target_has_no_matching_resource"
            end
            if needs_tree_clearance
                or not construction_network(layout_source.surface, layout_source.force, target) then remote = false end
            local row = {
              name = entity.name,
              entity_type = entity.type,
              position = target,
              direction = entity.direction,
              source_unit_number = entity.unit_number,
              source_position = {x = entity.position.x, y = entity.position.y}
            }
            if entity == layout_source then
              -- The free edge cell provides geometry, but the producer settings
              -- come from the actual target recipe cell. This lets Alina extend
              -- a modular mall where each product has only one assembler.
              row.source_unit_number = producer_source.unit_number
              row.source_position = {x = producer_source.position.x, y = producer_source.position.y}
              row.name = producer_source.name
              row.direction = producer_source.direction
              producer_row = row
            else
              support = support + 1
            end
            rows[#rows + 1] = row
            if #rows > 32 then return nil, nil, nil, nil, "module_too_large" end
          end
        end
      end
    end
  end
  if not producer_row then return nil, nil, nil, nil, "producer_not_repeated" end
  if support < 2 then return nil, nil, nil, nil, "insufficient_repeated_support" end
  return rows, producer_row, support, remote
end

local function edge_candidates(group, vector)
  local result = {}
  for _, entity in ipairs(group.entities) do
    local plus = {x = entity.position.x + vector.x, y = entity.position.y + vector.y}
    local minus = {x = entity.position.x - vector.x, y = entity.position.y - vector.y}
    local has_plus = producer_at(group, plus) ~= nil
    local has_minus = producer_at(group, minus) ~= nil
    if has_minus and not has_plus then
      result[#result + 1] = {source = entity, previous = producer_at(group, minus), outward = {x = vector.x, y = vector.y}}
    elseif has_plus and not has_minus then
      result[#result + 1] = {source = entity, previous = producer_at(group, plus), outward = {x = -vector.x, y = -vector.y}}
    end
  end
  return result
end

local function mining_product(entity, item_name)
  if not entity.valid or entity.type ~= "mining-drill" then return false end
  local target = entity.mining_target
  local properties = target and target.valid and target.prototype.mineable_properties or nil
  for _, product in ipairs(properties and properties.products or {}) do
    if product.type == "item" and product.name == item_name then return true end
  end
  return false
end

local function target_production_groups(scan_result, target_item, cooldown)
  local result = {}
  for _, group in pairs(scan_result.recipes) do
    local makes_target = false
    for _, item in ipairs(group.products) do if item == target_item then makes_target = true; break end end
    local key = "recipe:" .. group.recipe.name
    if makes_target and #group.entities >= 1 and (cooldown[key] or 0) <= game.tick then
      group.expansion_key = key
      group.expansion_recipe = group.recipe.name
      result[#result + 1] = group
    end
  end

  local mining = {}
  for _, entity in ipairs(scan_result.entities or {}) do
    if mining_product(entity, target_item) then
      local target = entity.mining_target
      local key = entity.name .. ":" .. target.name
      local group = mining[key]
      if not group then
        group = {
          entities = {},
          products = {target_item},
          expansion_key = "mining:" .. key,
          expansion_recipe = nil
        }
        mining[key] = group
      end
      group.entities[#group.entities + 1] = entity
    end
  end
  for _, group in pairs(mining) do
    if (cooldown[group.expansion_key] or 0) <= game.tick then result[#result + 1] = group end
  end
  return result
end

local function placement_item(entity)
  local candidates = {}
  for _, item in ipairs(entity and entity.prototype.items_to_place_this or {}) do
    if prototypes.item[item.name] then
      candidates[#candidates + 1] = {name = item.name, count = item.count or 1}
    end
  end
  table.sort(candidates, function(a, b)
    if a.count ~= b.count then return a.count < b.count end
    return a.name < b.name
  end)
  return candidates[1]
end

local function producer_rate(entity)
  if entity.type == "mining-drill" then return entity.prototype.mining_speed or 0 end
  local quality = entity.quality and entity.quality.name or "normal"
  local ok, value = pcall(function() return entity.prototype.get_crafting_speed(quality) end)
  return ok and value or 0
end

local function expandable_producer(agent, entities)
  local best, best_rate, best_obtainability = nil, -1, math.huge
  local representatives = {}
  for _, entity in ipairs(entities or {}) do
    if entity.valid then
      local item = placement_item(entity)
      if item then
        local quality = entity.quality and entity.quality.name or "normal"
        local key = entity.name .. "|" .. quality .. "|" .. item.name .. "|" .. tostring(item.count)
        local previous = representatives[key]
        if not previous or producer_rate(entity) > previous.rate
            or (producer_rate(entity) == previous.rate
              and (entity.unit_number or math.huge) < (previous.entity.unit_number or math.huge)) then
          representatives[key] = {entity = entity, item = item, rate = producer_rate(entity), key = key}
        end
      end
    end
  end

  local ordered = {}
  for _, row in pairs(representatives) do ordered[#ordered + 1] = row end
  table.sort(ordered, function(a, b) return a.key < b.key end)
  for _, row in ipairs(ordered) do
    local main = agent.get_inventory(defines.inventory.character_main)
    local obtainability = main and main.get_item_count(row.item.name) >= row.item.count and 0 or 2
    if obtainability > 0 then
      for _, recipe in ipairs(RecipeIndex.find_producers(row.item.name, agent.force, 16) or {}) do
        if recipe.enabled then obtainability = 1; break end
      end
    end
    -- Do not run a recursive storage/crafting acquisition plan merely to rank
    -- an existing layout. The line executor performs that exact check once for
    -- the selected module before it builds anything, so a missing obsolete
    -- machine fails safely without turning every planner pass into a base scan.
    if not best or row.rate > best_rate
        or (row.rate == best_rate and obtainability < best_obtainability)
        or (row.rate == best_rate and obtainability == best_obtainability
          and (row.entity.unit_number or math.huge) < (best.unit_number or math.huge)) then
      best, best_rate, best_obtainability = row.entity, row.rate, obtainability
    end
  end
  return best
end

local function plan_expansion(player, agent, scan_result, target_item, root)
  local cooldown = root.autonomy.expansion_cooldown or {}
  root.autonomy.expansion_cooldown = cooldown

  local target_groups = target_production_groups(scan_result, target_item, cooldown)
  table.sort(target_groups, function(a, b)
    if #a.entities ~= #b.entities then return #a.entities > #b.entities end
    return tostring(a.expansion_recipe or a.expansion_key) < tostring(b.expansion_recipe or b.expansion_key)
  end)
  if #target_groups == 0 then return nil, "target_recipe_not_active" end

  -- Layout groups are intentionally independent of recipe.  A modular mall may
  -- contain one assembler per product but still repeat exactly the same physical
  -- cell.  The old v6 code required two machines with the same recipe, so this
  -- perfectly valid pattern was never expandable.
  local layout_by_name = {}
  for _, entity in ipairs(scan_result.entities or {}) do
    local is_layout_machine = entity.valid and (
      (CRAFTING_TYPES[entity.type] and entity.get_recipe())
      or (entity.type == "mining-drill" and entity.mining_target))
    if is_layout_machine then
      local group = layout_by_name[entity.name]
      if not group then group = {entities = {}}; layout_by_name[entity.name] = group end
      group.entities[#group.entities + 1] = entity
    end
  end

  local rejection = "layout_not_repeated"
  for _, target_group in ipairs(target_groups) do
    -- A recipe group can contain several machine tiers. Cloning the first row
    -- is both nondeterministic and can request an obsolete building that is no
    -- longer stocked or craftable. Select the fastest compatible producer Alina
    -- can actually obtain, then copy geometry only from that prototype's cells.
    local producer_source = expandable_producer(agent, target_group.entities)
    if producer_source and producer_source.valid then
      local layout_group = layout_by_name[producer_source.name]
      if layout_group and #layout_group.entities >= 2 then
        local vector, confidence = repeated_step(layout_group)
        if vector and confidence >= 1 then
          local edges = edge_candidates(layout_group, vector)
          table.sort(edges, function(a, b)
            local da = distance_squared(a.source.position, agent.position)
            local db = distance_squared(b.source.position, agent.position)
            if da == db then return (a.source.unit_number or math.huge) < (b.source.unit_number or math.huge) end
            return da < db
          end)
          -- A giant repeated block can have hundreds of geometrical edges.
          -- Testing every edge repeats collision/logistic queries without
          -- improving the decision. Nearby deterministic candidates give the
          -- executor enough alternatives while keeping one planner pass bounded.
          local edge_limit = math.min(4, #edges)
          for edge_index = 1, edge_limit do
            local edge = edges[edge_index]
            local rows, producer_row, support, remote, reason = cell_template(
              edge.source, edge.previous, edge.outward, producer_source, target_item)
            if rows then
              cooldown[target_group.expansion_key] = game.tick + 18000
              return {
                recipe = target_group.expansion_recipe,
                target_item = target_item,
                vector = edge.outward,
                entities = rows,
                producer_target = producer_row,
                source_position = {x = producer_source.position.x, y = producer_source.position.y},
                approach_position = {x = producer_row.position.x, y = producer_row.position.y},
                index = 1,
                ghosts_created = 0,
                support_count = support,
                layout_machine = edge.source.name,
                remote = remote
              }
            end
            rejection = reason or rejection
          end
        end
      end
    else
      rejection = "producer_building_unavailable"
    end
  end
  -- A layout that was fully inspected and rejected cannot become placeable a
  -- few seconds later unless the factory changes. Back off for 30 game seconds
  -- instead of repeating the same bounded but non-trivial geometry search on
  -- every idle autonomy pass.
  for _, group in ipairs(target_groups) do
    cooldown[group.expansion_key] = math.max(cooldown[group.expansion_key] or 0, game.tick + 1800)
  end
  return nil, rejection
end

local function science_flow(player, item_name)
  local stats = player.force.get_item_production_statistics(player.surface)
  return stats.get_flow_count({
    name = item_name,
    category = "input",
    precision_index = defines.flow_precision_index.one_minute
  }) or 0
end

local function technology_score(player, tech)
  local missing = 0
  local ingredient_count = 0
  for _, ingredient in ipairs(tech.research_unit_ingredients or {}) do
    ingredient_count = ingredient_count + 1
    if science_flow(player, ingredient.name) <= 0.01 then missing = missing + 1 end
  end
  local name = string.lower(tech.name)
  local strategic_penalty = 0
  if string.find(name, "planet%-discovery") then strategic_penalty = strategic_penalty + 300000 end
  if string.find(name, "prometh") then strategic_penalty = strategic_penalty + 500000 end
  if tech.upgrade then strategic_penalty = strategic_penalty + 100000 end
  if string.find(name, "artillery") or string.find(name, "weapon") or string.find(name, "damage") then
    strategic_penalty = strategic_penalty + 50000
  end
  local essential_bonus = tech.prototype.essential and -200000 or 0
  return missing * 1000000 + ingredient_count * 10000 + (tech.research_unit_count or 100000) + strategic_penalty + essential_bonus
end

local function queue_research(player, root)
  return ResearchControl.select_next(player)
end

local function set_status(root, text)
  root.autonomy.status_text = text
end

local function recipe_evidence(scan_result)
  local rows = {}
  for name, group in pairs(scan_result.recipes or {}) do
    rows[#rows + 1] = {name = name, products = group.products, machines = #group.entities}
  end
  table.sort(rows, function(a, b) return a.name < b.name end)
  return rows
end

local function push_fluid_resume(root, kind, name, options, marker)
  local stack = root.autonomy.fluid_upstream_stack
  if #stack >= 8 then return false end
  stack[#stack + 1] = {kind = kind, name = name, options = options, marker = marker}
  return true
end

local function restore_fluid_resume(root)
  local stack = root.autonomy.fluid_upstream_stack
  local resume = table.remove(stack)
  if not resume then return end
  if resume.kind == "fluid" then
    root.autonomy.priority_fluid = resume.name
  elseif resume.kind == "item" then
    root.autonomy.priority_item = resume.name
    root.autonomy.priority_options = resume.options
    root.autonomy.marker_goal = resume.marker
  end
end

local function fluid_goal_in_stack(root, fluid_name)
  if root.autonomy.priority_fluid == fluid_name then return true end
  for _, row in ipairs(root.autonomy.fluid_upstream_stack or {}) do
    if row.kind == "fluid" and row.name == fluid_name then return true end
  end
  return false
end

local function start_fluid_upstream(player, agent, root, fluid_name, options, depth)
  depth = depth or 0
  if depth >= 8 then return false, "fluid_upstream_depth_limit" end
  if (root.autonomy.fluid_cooldown[fluid_name] or 0) > game.tick then
    return false, "fluid_upstream_cooldown"
  end
  local plan, error_message = FluidPlanner.plan_source(player, agent, fluid_name, options)
  if plan then
    root.autonomy.priority_fluid = nil
    restore_fluid_resume(root)
    EventBus.emit("fluid_upstream_planned", {
      fluid = fluid_name,
      natural_source = plan.natural_fluid_source == true,
      recipe = plan.recipe,
      drills = plan.drill_count,
      machines = plan.machine_count,
      entities = #plan.entities
    })
    set_status(root, plan.natural_fluid_source
      and ("Обустраиваю первичный источник жидкости " .. fluid_name)
      or ("Строю upstream-производство жидкости " .. fluid_name))
    return TaskManager.start_line_expansion(player.index, plan, "autonomous")
  end
  local missing = FluidPlanner.missing_input(error_message)
  if missing and missing ~= fluid_name and not fluid_goal_in_stack(root, missing)
      and push_fluid_resume(root, "fluid", fluid_name, options, nil) then
    root.autonomy.priority_fluid = missing
    EventBus.emit("fluid_upstream_dependency", {
      fluid = fluid_name, limiting_fluid = missing, depth = depth + 1
    })
    return start_fluid_upstream(player, agent, root, missing, options, depth + 1)
  end
  root.autonomy.fluid_cooldown[fluid_name] = game.tick + 36000
  root.autonomy.priority_fluid = nil
  restore_fluid_resume(root)
  EventBus.emit("fluid_upstream_rejected", {fluid = fluid_name, reason = error_message})
  return false, error_message or "fluid_upstream_unavailable"
end

function LocalPlanner.run(requested_player_index)
  local root = State.ensure()
  if root.paused or root.autonomy.enabled == false or root.task.current then return false, "busy" end
  local player = player_for(root, requested_player_index)
  local agent = root.agent.entity
  if not player or not player.valid or not agent or not agent.valid then return false, "missing_actor" end
  if player.surface ~= agent.surface then
    set_status(root, "Жду возвращения на одну поверхность с игроком")
    return false, "different_surface"
  end

  if root.autonomy.development_focus then
    local pending = WorldModel.factory_refresh_pending(player)
    if pending > 0 then
      set_status(root, "Обновляю карту базы: осталось " .. tostring(pending) .. " участков")
      return false, "factory_refresh_pending"
    end
  end

  set_status(root, "Анализирую известную фабрику")
  queue_research(player, root)
  -- A new overhaul save can expose tens of thousands of prototypes. Keep an
  -- explicit player priority intact until both persistent indexes are ready;
  -- otherwise the first planner pass consumes the command, rejects every
  -- prototype-driven builder and falls back to a useless diagnosis task.
  if not PrototypeIndex.is_ready() or not RecipeIndex.is_ready() then
    set_status(root, "Изучаю реальные рецепты и постройки этой сборки")
    return false, "indexes_not_ready"
  end
  local scan_result = WorldModel.machine_snapshot(player, 768)

  if root.autonomy.priority_fluid and prototypes.fluid[root.autonomy.priority_fluid] then
    local fluid_name = root.autonomy.priority_fluid
    local started, result = start_fluid_upstream(player, agent, root, fluid_name, nil, 0)
    if started then return started, result end
    set_status(root, "Безопасный upstream жидкости " .. fluid_name .. " пока недоступен")
    return false, "fluid_upstream_pending"
  end

  if scan_result.power and not root.autonomy.priority_item and not root.autonomy.priority_fluid
      and not root.autonomy.loadout_priority then
    local power_unit = scan_result.power.unit_number
    root.autonomy.power_cooldown = root.autonomy.power_cooldown or {}
    if (root.autonomy.power_retry_tick or 0) <= game.tick
        and (not power_unit or (root.autonomy.power_cooldown[power_unit] or 0) <= game.tick) then
      if power_unit then root.autonomy.power_cooldown[power_unit] = game.tick + 36000 end
      root.autonomy.power_retry_tick = game.tick + 3600
      set_status(root, "Нашла проблему с электропитанием")
      return TaskManager.start_repair_power(player.index, scan_result.power, "autonomous")
    end
  end

  if root.autonomy.loadout_priority then
    local equipment = LoadoutPlanner.next_equipment(agent, root)
    if equipment then
      set_status(root, "Подготавливаю личную экипировку " .. equipment.item)
      return TaskManager.start_maintain_loadout(player.index, equipment, "autonomous")
    end
    local personal_vehicle = LoadoutPlanner.next_personal_vehicle(agent, root, scan_result.indexed)
    if personal_vehicle then
      set_status(root, "Подготавливаю личный паукотрон")
      return TaskManager.start_maintain_loadout(player.index, personal_vehicle, "autonomous")
    end
    root.autonomy.loadout_priority = nil
    EventBus.emit("loadout_priority_completed", {player_index = player.index})
  end

  local priority = root.autonomy.priority_item
  if priority and prototypes.item[priority] then
    if root.autonomy.forbidden_items[priority] then
      root.autonomy.priority_item = nil
      root.autonomy.marker_goal = nil
      set_status(root, "Соблюдаю запрет игрока на " .. priority)
      return false, "player_forbidden_item"
    end
    local marker = root.autonomy.marker_goal
    if marker and marker.surface_index ~= player.surface.index then marker = nil end
    local priority_options = root.autonomy.priority_options
    root.autonomy.priority_item = nil
    root.autonomy.priority_options = nil
    local expansion, rejection = nil, "marker_requires_new_layout"
    -- An explicit "find/develop this vein" command already selected a new
    -- resource block.  Looking for an in-place machine upgrade and an existing
    -- production clone first both delays that order and causes a large one-off
    -- scan on mod-heavy factories.  Go straight to the prototype-aware patch
    -- planner for this intent.
    if not marker and not (priority_options and priority_options.resource_request) then
      local upgrade = UpgradePlanner.plan(player, agent, scan_result, priority, root, true)
      if upgrade then
        set_status(root, "Рационально улучшаю действующую машину для " .. priority)
        return TaskManager.start_machine_upgrade(player.index, upgrade, "autonomous")
      end
      expansion, rejection = plan_expansion(player, agent, scan_result, priority, root)
    end
    if expansion then
      set_status(root, "Расширяю производство " .. priority)
      return TaskManager.start_line_expansion(player.index, expansion, "autonomous")
    end
    local bootstrap, bootstrap_rejection = ChainPlanner.plan(player, agent, priority, marker, priority_options)
    if bootstrap then
      set_status(root, "Строю новую связанную цепочку " .. priority)
      if marker then root.autonomy.marker_goal = nil end
      return TaskManager.start_line_expansion(player.index, bootstrap, "autonomous")
    end
    root.metrics.last_chain_plan = {
      tick = game.tick,
      target_item = priority,
      rejection = bootstrap_rejection,
      resource_request = priority_options and priority_options.resource_request == true or false,
      power = root.metrics.last_power_route
    }
    EventBus.emit("autonomy_chain_rejected", root.metrics.last_chain_plan)
    -- A resource-based request must never fall through into unrelated fluid or
    -- assembly recipes merely because no suitable patch is currently visible.
    -- Keep the player's goal and retry after the bounded world refresh instead
    -- of doing expensive speculative scans on a large factory.
    if bootstrap_rejection == "resource_patch_not_found"
        or (priority_options and priority_options.resource_request) then
      root.autonomy.priority_item = priority
      root.autonomy.priority_options = priority_options
      root.autonomy.next_tick = game.tick + 1800
      EventBus.emit("autonomy_resource_patch_pending", {
        target_item = priority,
        retry_tick = root.autonomy.next_tick,
        search = root.metrics.last_resource_search
      })
      set_status(root, "Готовлю безопасную добычу " .. priority)
      return false, "resource_chain_pending"
    end
    local fluid, fluid_rejection = FluidPlanner.plan(player, agent, priority, marker, priority_options)
    if fluid then
      set_status(root, "Строю жидкостный производственный блок " .. priority)
      if marker then root.autonomy.marker_goal = nil end
      return TaskManager.start_line_expansion(player.index, fluid, "autonomous")
    end
    local missing_fluid = FluidPlanner.missing_input(fluid_rejection)
    if missing_fluid and (root.autonomy.fluid_cooldown[missing_fluid] or 0) <= game.tick
        and push_fluid_resume(root, "item", priority, priority_options, marker) then
      root.autonomy.priority_fluid = missing_fluid
      local started, result = start_fluid_upstream(player, agent, root, missing_fluid,
        priority_options, 0)
      if started then return started, result end
      set_status(root, "Сначала нужен upstream жидкости " .. missing_fluid)
      return false, "fluid_upstream_pending"
    end
    local assembly, assembly_rejection = AssemblyPlanner.plan(player, agent, priority, marker, priority_options)
    if assembly then
      set_status(root, "Строю производственный блок " .. priority)
      if marker then root.autonomy.marker_goal = nil end
      return TaskManager.start_line_expansion(player.index, assembly, "autonomous")
    end
    EventBus.emit("autonomy_expansion_rejected", {
      target_item = priority,
      reason = rejection,
      bootstrap_reason = bootstrap_rejection,
      fluid_reason = fluid_rejection,
      assembly_reason = assembly_rejection,
      indexed_machines = scan_result.indexed,
      recipes = recipe_evidence(scan_result)
    })
    -- The diagnostic task below must not immediately requeue the same rejected
    -- build every few seconds. A new explicit player command can still retry
    -- at once, while autonomous work waits for the factory to change.
    root.autonomy.item_cooldown[priority] = game.tick + 36000
    if marker then root.autonomy.marker_goal = nil end
    set_status(root, "Проверяю узкое место " .. priority)
    return TaskManager.start_resolve_shortage(player.index, priority, "autonomous")
  end

  local deficits, activity = production_candidates(player, scan_result)
  for _, deficit in ipairs(deficits) do
    if (root.autonomy.item_cooldown[deficit.item] or 0) <= game.tick
        and (root.autonomy.suppressed_items[deficit.item] or 0) <= game.tick
        and not root.autonomy.forbidden_items[deficit.item] then
      local health = deficit.health or producer_health(player, scan_result, deficit.item)
      if health.strategy == "logistics" then
        EventBus.emit("production_pressure_classified", {
          target_item = deficit.item,
          strategy = "logistics",
          producer_count = health.total,
          output_blocked = health.output_blocked,
          headroom = deficit.headroom
        })
        set_status(root, "Проверяю заблокированный выход линии " .. deficit.item)
        return TaskManager.start_resolve_shortage(player.index, deficit.item, "autonomous")
      end

      local action_item = deficit.item
      local limiting = health.limiting_ingredient
      if health.strategy == "upstream" then
        if limiting and limiting.type == "item" and prototypes.item[limiting.name]
            and not root.autonomy.forbidden_items[limiting.name]
            and (root.autonomy.item_cooldown[limiting.name] or 0) <= game.tick
            and (root.autonomy.suppressed_items[limiting.name] or 0) <= game.tick then
          action_item = limiting.name
          EventBus.emit("production_pressure_classified", {
            target_item = deficit.item,
            strategy = "upstream",
            limiting_ingredient = limiting.name,
            limiting_type = limiting.type,
            producer_count = health.total,
            input_shortage = health.input_shortage,
            headroom = deficit.headroom
          })
        else
          EventBus.emit("production_pressure_classified", {
            target_item = deficit.item,
            strategy = "upstream_diagnosis",
            limiting_ingredient = limiting and limiting.name or nil,
            limiting_type = limiting and limiting.type or nil,
            producer_count = health.total,
            input_shortage = health.input_shortage,
            headroom = deficit.headroom
          })
          set_status(root, "Проверяю входы дефицитной линии " .. deficit.item)
          return TaskManager.start_resolve_shortage(player.index, deficit.item, "autonomous")
        end
      end

      local upgrade = UpgradePlanner.plan(player, agent, scan_result, action_item, root)
      if upgrade then
        set_status(root, action_item == deficit.item
          and ("Проверяю улучшение узкого места " .. deficit.item)
          or ("Усиливаю вход " .. action_item .. " для " .. deficit.item))
        return TaskManager.start_machine_upgrade(player.index, upgrade, "autonomous")
      end
      local expansion = plan_expansion(player, agent, scan_result, action_item, root)
      if expansion then
        set_status(root, action_item == deficit.item
          and ("Расширяю дефицитную линию " .. deficit.item)
          or ("Расширяю вход " .. action_item .. " для " .. deficit.item))
        return TaskManager.start_line_expansion(player.index, expansion, "autonomous")
      end
      local scale = {high_throughput = deficit.ratio >= 0.5 and deficit.consumed >= 1}
      local bootstrap = ChainPlanner.plan(player, agent, action_item, nil, scale)
      if bootstrap then
        set_status(root, "Создаю новую цепочку дефицитного материала " .. action_item)
        return TaskManager.start_line_expansion(player.index, bootstrap, "autonomous")
      end
      local fluid = FluidPlanner.plan(player, agent, action_item, nil, scale)
      if fluid then
        set_status(root, "Создаю жидкостный блок дефицитного материала " .. action_item)
        return TaskManager.start_line_expansion(player.index, fluid, "autonomous")
      end
      local assembly = AssemblyPlanner.plan(player, agent, action_item, nil, scale)
      if assembly then
        set_status(root, "Создаю производственный блок дефицитного материала " .. action_item)
        return TaskManager.start_line_expansion(player.index, assembly, "autonomous")
      end
      set_status(root, "Разбираюсь с дефицитом " .. deficit.item)
      return TaskManager.start_resolve_shortage(player.index, deficit.item, "autonomous")
    end
  end

  local current = player.force.current_research
  if current then
    for _, ingredient in ipairs(current.research_unit_ingredients or {}) do
      if not root.autonomy.forbidden_items[ingredient.name]
          and (root.autonomy.item_cooldown[ingredient.name] or 0) <= game.tick then
      local upgrade = UpgradePlanner.plan(player, agent, scan_result, ingredient.name, root)
      if upgrade then
        set_status(root, "Улучшаю загруженную научную линию " .. ingredient.name)
        return TaskManager.start_machine_upgrade(player.index, upgrade, "autonomous")
      end
      local expansion = plan_expansion(player, agent, scan_result, ingredient.name, root)
      if expansion then
        set_status(root, "Усиливаю науку: " .. ingredient.name)
        return TaskManager.start_line_expansion(player.index, expansion, "autonomous")
      end
      local bootstrap = ChainPlanner.plan(player, agent, ingredient.name)
      if bootstrap then
        set_status(root, "Строю сырьевую цепочку для науки: " .. ingredient.name)
        return TaskManager.start_line_expansion(player.index, bootstrap, "autonomous")
      end
      local fluid = FluidPlanner.plan(player, agent, ingredient.name)
      if fluid then
        set_status(root, "Строю жидкостное производство для науки: " .. ingredient.name)
        return TaskManager.start_line_expansion(player.index, fluid, "autonomous")
      end
      local assembly = AssemblyPlanner.plan(player, agent, ingredient.name)
      if assembly then
        set_status(root, "Строю производственный блок для науки: " .. ingredient.name)
        return TaskManager.start_line_expansion(player.index, assembly, "autonomous")
      end
      -- Retry an unavailable modded science pack later instead of running five
      -- planners for it every autonomy pulse. Research, stock or surface access
      -- may change, so this is a cooldown rather than a permanent rejection.
      root.autonomy.item_cooldown[ingredient.name] = game.tick + 3600
      return false, "research_input_unavailable"
      end
    end
  end

  -- When the player explicitly asks to develop the factory, personal armour and
  -- reserve restocking must not masquerade as progress. Keep observing until a
  -- safe production/power change is found, then continue with the next one.
  if root.autonomy.development_focus then
    local foundations = foundation_candidates(player, agent, scan_result)
    local foundation_attempts = 0
    for _, candidate in ipairs(foundations) do
      if foundation_attempts >= 1 then break end
      if not root.autonomy.forbidden_items[candidate.item]
          and not root.autonomy.forbidden_items[candidate.raw_item]
          and (root.autonomy.item_cooldown[candidate.item] or 0) <= game.tick then
        foundation_attempts = foundation_attempts + 1
        local scale = {
          high_throughput = candidate.consumers >= 8,
          cover_full_patch = true,
          exclude_resource_centers = #candidate.exclusion_centers > 0 and candidate.exclusion_centers or nil
        }
        local bootstrap, rejection = ChainPlanner.plan(player, agent, candidate.item, nil, scale)
        if bootstrap then
          EventBus.emit("autonomy_foundation_selected", {
            raw_item = candidate.raw_item,
            target_item = candidate.item,
            resource = candidate.resource,
            mining_missing = candidate.mining_missing,
            processing_missing = candidate.processing_missing,
            new_patch_required = candidate.new_patch_required,
            consumers = candidate.consumers
          })
          set_status(root, candidate.item == candidate.raw_item
            and ("Обустраиваю отсутствующую добычу " .. candidate.raw_item)
            or ("Создаю базовую цепочку " .. candidate.raw_item .. " → " .. candidate.item))
          return TaskManager.start_line_expansion(player.index, bootstrap, "autonomous")
        end
        root.autonomy.item_cooldown[candidate.item] = game.tick + 3600
        EventBus.emit_debug("autonomy_foundation_rejected", {
          raw_item = candidate.raw_item,
          target_item = candidate.item,
          reason = rejection
        })
      end
    end

    -- Expensive specialised planners are deliberately staged across autonomy
    -- pulses. This keeps UPS smooth on a 50k+ entity overhaul factory while
    -- preserving the exact same deterministic candidate order and eventual
    -- Chain -> Fluid -> Assembly coverage.
    local pending = root.autonomy.pending_development_candidate
    if pending then
      local candidate = pending.candidate
      if not candidate or game.tick > (pending.expires_tick or 0)
          or root.autonomy.forbidden_items[candidate.item] then
        root.autonomy.pending_development_candidate = nil
      else
        local scale = {
          high_throughput = candidate.consumed >= 1 or candidate.machine_count >= 4,
          avoid_existing_development = true
        }
        if pending.stage == "upgrade" then
          local upgrade = UpgradePlanner.plan(player, agent, scan_result, candidate.item, root)
          pending.stage = "expansion"
          if upgrade then
            root.autonomy.pending_development_candidate = nil
            set_status(root, "Рационально обновляю загруженную линию " .. candidate.item)
            return TaskManager.start_machine_upgrade(player.index, upgrade, "autonomous")
          end
          return false, "development_candidate_upgrade_rejected"
        end
        if pending.stage == "expansion" then
          local expansion = plan_expansion(player, agent, scan_result, candidate.item, root)
          pending.stage = "chain"
          if expansion then
            root.autonomy.pending_development_candidate = nil
            EventBus.emit("autonomy_development_fallback_selected", {
              target_item = candidate.item,
              strategy = "repeat_existing_cell",
              score = candidate.score,
              consumers = candidate.consumers,
              machine_count = candidate.machine_count
            })
            set_status(root, "Расширяю полезную опорную линию " .. candidate.item)
            return TaskManager.start_line_expansion(player.index, expansion, "autonomous")
          end
          return false, "development_candidate_expansion_rejected"
        end
        if pending.stage == "chain" then
          local bootstrap = ChainPlanner.plan(player, agent, candidate.item, nil, scale)
          pending.stage = "fluid"
          if bootstrap then
            root.autonomy.pending_development_candidate = nil
            EventBus.emit("autonomy_development_fallback_selected", {
              target_item = candidate.item,
              strategy = "connected_chain",
              score = candidate.score,
              consumers = candidate.consumers,
              machine_count = candidate.machine_count
            })
            set_status(root, "Строю новый связанный блок " .. candidate.item)
            return TaskManager.start_line_expansion(player.index, bootstrap, "autonomous")
          end
          set_status(root, "Проверяю жидкостную схему для " .. candidate.item)
          return false, "development_candidate_chain_rejected"
        end
        if pending.stage == "fluid" then
          local fluid = FluidPlanner.plan(player, agent, candidate.item, nil, scale)
          pending.stage = "assembly"
          if fluid then
            root.autonomy.pending_development_candidate = nil
            EventBus.emit("autonomy_development_fallback_selected", {
              target_item = candidate.item,
              strategy = "fluid_block",
              score = candidate.score,
              consumers = candidate.consumers,
              machine_count = candidate.machine_count
            })
            set_status(root, "Строю новый жидкостный блок " .. candidate.item)
            return TaskManager.start_line_expansion(player.index, fluid, "autonomous")
          end
          set_status(root, "Проверяю сборочный блок для " .. candidate.item)
          return false, "development_candidate_fluid_rejected"
        end
        local assembly = AssemblyPlanner.plan(player, agent, candidate.item, nil, scale)
        root.autonomy.pending_development_candidate = nil
        if assembly then
          EventBus.emit("autonomy_development_fallback_selected", {
            target_item = candidate.item,
            strategy = "assembly_block",
            score = candidate.score,
            consumers = candidate.consumers,
            machine_count = candidate.machine_count
          })
          set_status(root, "Строю новый производственный блок " .. candidate.item)
          return TaskManager.start_line_expansion(player.index, assembly, "autonomous")
        end
        root.autonomy.item_cooldown[candidate.item] = game.tick + 3600
        return false, "development_candidate_rejected"
      end
    end

    local attempted = 0
    local considered = {}
    for _, candidate in ipairs(development_candidates(player, scan_result, activity)) do
      if attempted >= 1 then break end
      if not root.autonomy.forbidden_items[candidate.item]
          and (root.autonomy.item_cooldown[candidate.item] or 0) <= game.tick
          and (root.autonomy.suppressed_items[candidate.item] or 0) <= game.tick then
        attempted = attempted + 1
        considered[#considered + 1] = candidate
        do
          root.autonomy.pending_development_candidate = {
            candidate = candidate,
            stage = "upgrade",
            expires_tick = game.tick + 2400
          }
          set_status(root, "Оцениваю безопасное улучшение " .. candidate.item)
          return false, "development_candidate_staged"
        end
        local upgrade = UpgradePlanner.plan(player, agent, scan_result, candidate.item, root)
        if upgrade then
          set_status(root, "Рационально обновляю загруженную линию " .. candidate.item)
          return TaskManager.start_machine_upgrade(player.index, upgrade, "autonomous")
        end
        local expansion = plan_expansion(player, agent, scan_result, candidate.item, root)
        if expansion then
          EventBus.emit("autonomy_development_fallback_selected", {
            target_item = candidate.item,
            score = candidate.score,
            consumers = candidate.consumers,
            machine_count = candidate.machine_count
          })
          set_status(root, "Расширяю полезную опорную линию " .. candidate.item)
          return TaskManager.start_line_expansion(player.index, expansion, "autonomous")
        end
      end
    end

    if considered[1] then
      root.autonomy.pending_development_candidate = {
        candidate = considered[1],
        stage = "chain",
        expires_tick = game.tick + 1800
      }
      set_status(root, "Продумываю связанный блок " .. considered[1].item)
      return false, "development_candidate_staged"
    end

    -- An existing starter base does not always contain a repeated cell that can
    -- be cloned. In that case "continue developing" must still result in useful
    -- factory work, not an endless observation loop. Try a small bounded set of
    -- the highest-value products already present in the live factory and let the
    -- specialised prototype-driven planners create a complete connected block.
    -- This happens only after every safe in-place upgrade/extension above failed.
    for index = 1, math.min(3, #considered) do
      local candidate = considered[index]
      local scale = {
        high_throughput = candidate.consumed >= 1
          or candidate.machine_count >= 4,
        avoid_existing_development = true
      }
      local bootstrap = ChainPlanner.plan(player, agent, candidate.item, nil, scale)
      if bootstrap then
        EventBus.emit("autonomy_development_fallback_selected", {
          target_item = candidate.item,
          strategy = "connected_chain",
          score = candidate.score,
          consumers = candidate.consumers,
          machine_count = candidate.machine_count
        })
        set_status(root, "Строю новый связанный блок " .. candidate.item)
        return TaskManager.start_line_expansion(player.index, bootstrap, "autonomous")
      end
      local fluid = FluidPlanner.plan(player, agent, candidate.item, nil, scale)
      if fluid then
        EventBus.emit("autonomy_development_fallback_selected", {
          target_item = candidate.item,
          strategy = "fluid_block",
          score = candidate.score,
          consumers = candidate.consumers,
          machine_count = candidate.machine_count
        })
        set_status(root, "Строю новый жидкостный блок " .. candidate.item)
        return TaskManager.start_line_expansion(player.index, fluid, "autonomous")
      end
      local assembly = AssemblyPlanner.plan(player, agent, candidate.item, nil, scale)
      if assembly then
        EventBus.emit("autonomy_development_fallback_selected", {
          target_item = candidate.item,
          strategy = "assembly_block",
          score = candidate.score,
          consumers = candidate.consumers,
          machine_count = candidate.machine_count
        })
        set_status(root, "Строю новый производственный блок " .. candidate.item)
        return TaskManager.start_line_expansion(player.index, assembly, "autonomous")
      end
    end
    set_status(root, "Ищу безопасное улучшение существующей фабрики")
    return false, "development_focus_no_safe_change"
  end

  local personal_vehicle = LoadoutPlanner.next_personal_vehicle(agent, root, scan_result.indexed)
  if personal_vehicle then
    set_status(root, "Подготавливаю личный паукотрон")
    return TaskManager.start_maintain_loadout(player.index, personal_vehicle, "autonomous")
  end

  local equipment = LoadoutPlanner.next_equipment(agent, root)
  if equipment then
    set_status(root, "Подготавливаю личную экипировку " .. equipment.item)
    return TaskManager.start_maintain_loadout(player.index, equipment, "autonomous")
  end


  local reserve = LoadoutPlanner.next_construction_reserve(agent, root)
  if reserve then
    set_status(root, "Пополняю строительный запас " .. reserve.item)
    return TaskManager.start_maintain_loadout(player.index, reserve, "autonomous")
  end

  -- Analysis is script-level.  Alina never walks around merely to "look" at
  -- machines; the world model already contains the known factory state.  If no
  -- safe build is available she simply monitors events and re-evaluates later.
  local model = WorldModel.summary(player)
  set_status(root, "Наблюдаю фабрику: " .. tostring(model.entities) .. " объектов в модели")
  return false, "nothing_safe"
end

-- Read-only, bounded production diagnosis shared with the rare player adviser.
-- Keeping the scoring in one place prevents advice from disagreeing with the
-- autonomous planner about the factory's actual bottleneck.
function LocalPlanner.production_diagnostics(player, scan_result)
  return production_candidates(player, scan_result)
end

function LocalPlanner.producer_diagnostics(player, scan_result, target_item)
  return producer_health(player, scan_result, target_item)
end

return LocalPlanner
