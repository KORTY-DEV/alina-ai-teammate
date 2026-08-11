local Acquisition = require("scripts.executor.acquisition")
local Conflict = require("scripts.conflict.manager")
local PrototypeIndex = require("scripts.sensors.prototype_index")
local RecipeIndex = require("scripts.sensors.recipe_index")
local ModulePolicy = require("scripts.autonomy.module_policy")
local RoutePlanner = require("scripts.autonomy.route_planner")
local SitePolicy = require("scripts.construction.site_policy")
local State = require("scripts.core.state")

local ChainPlanner = {}

-- One transaction is a complete, throughput-balanced section. Large patches
-- are covered by several autonomous sections so the saved task graph and the
-- physical build stay bounded without falling back to tiny demonstrations.
-- Twelve top-tier overhaul drills are already a substantial production block;
-- the endurance fixture showed that doubling this value creates a visible
-- one-frame deterministic-state hitch on 50k-entity maps.
local MAX_DRILLS = 12
local MAX_FURNACES = 48
local MAX_ROUTE_BELTS = 640
local MAX_PLACEMENT_ACQUISITION_ATTEMPTS = 12

local function sorted_keys(values)
  local result = {}
  for key, value in pairs(values or {}) do
    if type(key) == "number" then
      result[#result + 1] = value
    elseif value then
      result[#result + 1] = key
    end
  end
  table.sort(result)
  return result
end

local function placement_choice(agent, rows, count, predicate, performance)
  local candidates = {}
  local inventory = agent.get_inventory(defines.inventory.character_main)
  for _, row in ipairs(rows or {}) do
    if not predicate or predicate(row) then
      for _, placement in ipairs(row.items or {}) do
        local required = count * (placement.count or 1)
        local unlock_rank = inventory and inventory.get_item_count(placement.name) >= required and 0 or 2
        if unlock_rank > 0 and RecipeIndex.has_enabled_producer(placement.name, agent.force) then
          unlock_rank = 1
        end
        candidates[#candidates + 1] = {
          row = row,
          placement = placement,
          required = required,
          unlock_rank = unlock_rank,
          capability = performance and performance(row) or 0,
          footprint = (row.tile_width or 1) * (row.tile_height or 1)
        }
      end
    end
  end
  table.sort(candidates, function(a, b)
    if a.unlock_rank ~= b.unlock_rank then return a.unlock_rank < b.unlock_rank end
    if a.capability ~= b.capability then return a.capability > b.capability end
    if a.footprint ~= b.footprint then return a.footprint < b.footprint end
    if a.row.entity ~= b.row.entity then return a.row.entity < b.row.entity end
    return a.placement.name < b.placement.name
  end)
  local last_error = nil
  -- Candidates are ordered strongest-first, so the first obtainable one is
  -- exactly the best usable tier. The old implementation fully planned every
  -- lower tier too, repeatedly scanning a 50k-entity base and causing a
  -- multi-second single-tick spike.
  for index = 1, math.min(#candidates, MAX_PLACEMENT_ACQUISITION_ATTEMPTS) do
    local candidate = candidates[index]
    local placement = candidate.placement
    local acquisition, acquisition_error = Acquisition.make_plan(
      agent, placement.name, candidate.required, "autonomous", {preview = true})
    if acquisition then
      return {row = candidate.row, item = placement.name, item_count = placement.count or 1}
    end
    last_error = placement.name .. ":" .. tostring(acquisition_error)
  end
  return nil, last_error
end

local function fuel_choice(agent, categories, count)
  local best, best_score = nil, nil
  for _, fuel in ipairs(PrototypeIndex.fuels_for(categories) or {}) do
    local acquisition = Acquisition.make_plan(agent, fuel.name, count, "autonomous")
    if acquisition then
      local score = #acquisition.operations * 100000 - math.min(50000, math.floor((fuel.fuel_value or 0) / 1000))
      if not best_score or score < best_score then best, best_score = fuel, score end
    end
  end
  return best
end

local function expected_product(product)
  local amount = product.amount
  if not amount and product.amount_min and product.amount_max then
    amount = (product.amount_min + product.amount_max) / 2
  end
  return (amount or 1) * (product.probability or 1)
end

local function recipe_for_resource_product(player, target_item)
  local best, best_input, best_score = nil, nil, nil
  for _, recipe in ipairs(RecipeIndex.find_producers(target_item, player.force, 16) or {}) do
    if recipe.enabled and #recipe.ingredients == 1 and recipe.ingredients[1].type == "item" then
      local input = recipe.ingredients[1].name
      local resources = PrototypeIndex.resources_for(input)
      local mineable = false
      for _, resource in ipairs(resources or {}) do
        if resource.entity_type == "resource" then mineable = true; break end
      end
      if mineable then
        local output = 0
        for _, product in ipairs(recipe.products or {}) do
          if product.type == "item" and product.name == target_item then output = output + expected_product(product) end
        end
        local score = (recipe.energy or 1) / math.max(output, 0.001)
        if not best_score or score < best_score then best, best_input, best_score = recipe, input, score end
      end
    end
  end
  return best, best_input
end

local function resource_yields(resource, item_name)
  local properties = resource.valid and resource.prototype.mineable_properties or nil
  for _, product in ipairs(properties and properties.products or {}) do
    if product.type == "item" and product.name == item_name then return true end
  end
  return false
end

local function existing_resource_exclusions(agent, item_name, supplied)
  local result = {}
  for _, exclusion in ipairs(supplied or {}) do
    result[#result + 1] = {
      x = exclusion.x,
      y = exclusion.y,
      radius = exclusion.radius or 48
    }
  end

  -- A new throughput block must not be laid over the mining field of an
  -- existing chain.  One bounded drill query is cheaper and more reliable than
  -- discovering the overlap after acquiring hundreds of buildings.  Grouping
  -- targets by 64-tile patch cells also keeps resource-search comparisons
  -- bounded on a megabase with hundreds of drills.
  local grouped = {}
  for _, entity in ipairs(agent.surface.find_entities_filtered({
      position = agent.position,
      radius = 768,
      type = "mining-drill",
      force = agent.force,
      limit = 256
  })) do
    local target = entity.valid and entity.mining_target or nil
    if target and target.valid and resource_yields(target, item_name) then
      local key = target.name .. ":" .. tostring(math.floor(target.position.x / 64))
        .. ":" .. tostring(math.floor(target.position.y / 64))
      local row = grouped[key]
      if not row then
        row = {x = 0, y = 0, count = 0}
        grouped[key] = row
      end
      row.x = row.x + target.position.x
      row.y = row.y + target.position.y
      row.count = row.count + 1
    end
  end
  local keys = {}
  for key in pairs(grouped) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local row = grouped[key]
    result[#result + 1] = {x = row.x / row.count, y = row.y / row.count, radius = 48}
  end
  return result
end

local function resource_exclusions(agent, item_name, options)
  local supplied = options and options.exclude_resource_centers or nil
  if options and options.avoid_existing_development then
    return existing_resource_exclusions(agent, item_name, supplied)
  end
  return supplied
end

local function snap_axis(value, size)
  if (size or 1) % 2 == 0 then return math.floor(value + 0.5) end
  return math.floor(value) + 0.5
end

local function half_tile(value)
  return math.floor(value) + 0.5
end

local function matching_resource_under(surface, drill, position, item_name, known_resources)
  local radius = drill.mining_radius or 0
  if known_resources then
    for x = math.floor(position.x - radius), math.ceil(position.x + radius) do
      for y = math.floor(position.y - radius), math.ceil(position.y + radius) do
        if known_resources[x .. ":" .. y] then return true end
      end
    end
    return false
  end
  local resources = surface.find_entities_filtered({
    area = {{position.x - radius, position.y - radius}, {position.x + radius, position.y + radius}},
    type = "resource",
    limit = 128
  })
  for _, resource in ipairs(resources) do
    if resource.valid and resource.amount and resource.amount > 0
        and drill.resource_categories and drill.resource_categories[resource.prototype.resource_category]
        and resource_yields(resource, item_name) then return true end
  end
  return false
end

local function patch_bounds(surface, seed)
  local resources = surface.find_entities_filtered({
    position = seed.position,
    radius = 32,
    name = seed.name,
    type = "resource",
    limit = 2048
  })
  local by_tile = {}
  for _, resource in ipairs(resources) do
    if resource.valid and resource.amount and resource.amount > 0 then
      local x = math.floor(resource.position.x + 0.5)
      local y = math.floor(resource.position.y + 0.5)
      by_tile[x .. ":" .. y] = resource
    end
  end
  local seed_x = math.floor(seed.position.x + 0.5)
  local seed_y = math.floor(seed.position.y + 0.5)
  local queue = {{x = seed_x, y = seed_y}}
  local visited = {[seed_x .. ":" .. seed_y] = true}
  local bounds = {min_x = seed.position.x, max_x = seed.position.x, min_y = seed.position.y, max_y = seed.position.y,
    resource_tiles = 0, resource_amount = 0}
  local index = 1
  while index <= #queue do
    local tile = queue[index]
    index = index + 1
    local resource = by_tile[tile.x .. ":" .. tile.y]
    if resource then
      bounds.resource_tiles = bounds.resource_tiles + 1
      bounds.resource_amount = bounds.resource_amount + (resource.amount or 0)
      bounds.min_x = math.min(bounds.min_x, resource.position.x)
      bounds.max_x = math.max(bounds.max_x, resource.position.x)
      bounds.min_y = math.min(bounds.min_y, resource.position.y)
      bounds.max_y = math.max(bounds.max_y, resource.position.y)
      for dx = -1, 1 do
        for dy = -1, 1 do
          local key = (tile.x + dx) .. ":" .. (tile.y + dy)
          if not visited[key] and by_tile[key] then
            visited[key] = true
            queue[#queue + 1] = {x = tile.x + dx, y = tile.y + dy}
          end
        end
      end
    end
  end
  -- Reuse the exact patch membership while evaluating drill positions. The old
  -- code repeated a live resource query for every candidate tile (hundreds of
  -- engine calls in one planner update), which produced visible 0.8 s hitches
  -- on dense overhaul maps.
  bounds.resource_by_tile = by_tile
  return bounds
end

local function existing_power_poles(surface, force, center)
  local result, seen = {}, {}
  for _, radius in ipairs({64, 128, 256, 512, 768}) do
    for _, pole in ipairs(surface.find_entities_filtered({
        position = center, radius = radius, type = "electric-pole", force = force, limit = 64})) do
      local key = pole.unit_number
      if pole.valid and pole.electric_network_id and key and not seen[key] then
        seen[key] = true
        result[#result + 1] = pole
      end
    end
    if #result >= 8 then break end
  end
  -- A large factory may have thousands of poles in range. Only the closest
  -- powered anchors can produce a short, readable feeder; keeping hundreds of
  -- remote nodes makes greedy coverage quadratic and was also responsible for
  -- visually erratic high-voltage routes across the test base.
  table.sort(result, function(a, b)
    local adx, ady = a.position.x - center.x, a.position.y - center.y
    local bdx, bdy = b.position.x - center.x, b.position.y - center.y
    local ad, bd = adx * adx + ady * ady, bdx * bdx + bdy * bdy
    if ad ~= bd then return ad < bd end
    return a.unit_number < b.unit_number
  end)
  while #result > 8 do table.remove(result) end
  return result
end

local function drill_lanes(surface, force, drill, bounds, item_name)
  local lanes = {}
  local width = drill.tile_width or 1
  local height = drill.tile_height or 1
  local y_start = math.floor(bounds.min_y - (drill.mining_radius or 0))
  local y_end = math.ceil(bounds.max_y + (drill.mining_radius or 0))
  local last_lane_y = nil
  local seen_y = {}
  for raw_y = y_start, y_end do
    local y = snap_axis(raw_y, height)
    local y_key = tostring(y)
    if not seen_y[y_key] and (not last_lane_y or y - last_lane_y >= height + 1) then
      seen_y[y_key] = true
      local candidates = {}
      local last_x = nil
      for raw_x = math.floor(bounds.min_x - (drill.mining_radius or 0)),
          math.ceil(bounds.max_x + (drill.mining_radius or 0)) do
        local x = snap_axis(raw_x, width)
        local position = {x = x, y = y}
        if (not last_x or x - last_x >= width + 1)
            and not Conflict.is_blocked(surface.index, position, "autonomous")
            and SitePolicy.can_plan(surface, force, drill.entity, position, defines.direction.south)
            and matching_resource_under(surface, drill, position, item_name, bounds.resource_by_tile) then
          candidates[#candidates + 1] = position
          last_x = x
        end
      end
      if #candidates > 0 then
        lanes[#lanes + 1] = candidates
        last_lane_y = y
      end
    end
  end
  local total = 0
  for _, lane in ipairs(lanes) do total = total + #lane end
  return total >= 2 and lanes or nil
end

local function flatten_drill_lanes(lanes, maximum)
  local result = {}
  for _, lane in ipairs(lanes or {}) do
    for _, position in ipairs(lane) do
      if #result >= maximum then return result end
      result[#result + 1] = position
    end
  end
  return result
end

local function trim_drill_lanes(lanes, maximum)
  local remaining = maximum
  local result = {}
  for _, lane in ipairs(lanes or {}) do
    if remaining <= 0 then break end
    local copy = {}
    for _, position in ipairs(lane) do
      if remaining <= 0 then break end
      copy[#copy + 1] = position
      remaining = remaining - 1
    end
    if #copy > 0 then result[#result + 1] = copy end
  end
  return result, flatten_drill_lanes(result, maximum)
end

local function add_row(rows, seen, row)
  local key = string.format("%.2f:%.2f", row.position.x, row.position.y)
  if seen[key] then return false end
  seen[key] = true
  row.bootstrap = true
  rows[#rows + 1] = row
  return true
end

local function add_belt_line(rows, seen, belt, x1, x2, y, direction, reverse_build, work_side)
  local first = math.floor(math.min(x1, x2))
  local last = math.floor(math.max(x1, x2))
  local start_x, end_x, step = first, last, 1
  if reverse_build then start_x, end_x, step = last, first, -1 end
  for x = start_x, end_x, step do
    add_row(rows, seen, {name = belt.entity, entity_type = belt.entity_type,
      position = {x = x + 0.5, y = half_tile(y)}, direction = direction,
      construction_work_side = work_side})
  end
end

local function box_for(name, position)
  local prototype = prototypes.entity[name]
  if not prototype then return nil end
  -- Reserve the complete tile footprint, not only the usually much smaller
  -- collision box. Factorio can reject a pole whose tiny collision box appears
  -- clear but whose placement tile belongs to a planned 2x2/3x3 machine.
  local width, height = prototype.tile_width, prototype.tile_height
  if width and height and width > 0 and height > 0 then
    return {
      left = position.x - width / 2,
      top = position.y - height / 2,
      right = position.x + width / 2,
      bottom = position.y + height / 2
    }
  end
  local box = prototype.collision_box
  if not box then return nil end
  return {
    left = position.x + box.left_top.x,
    top = position.y + box.left_top.y,
    right = position.x + box.right_bottom.x,
    bottom = position.y + box.right_bottom.y
  }
end

local function index_box(index, row)
  local box = box_for(row.name, row.position)
  if not box then return end
  local min_x, max_x = math.floor(box.left), math.ceil(box.right) - 1
  local min_y, max_y = math.floor(box.top), math.ceil(box.bottom) - 1
  for x = min_x, max_x do
    for y = min_y, max_y do
      local key = tostring(x) .. ":" .. tostring(y)
      local bucket = index[key]
      if not bucket then bucket = {}; index[key] = bucket end
      bucket[#bucket + 1] = row
    end
  end
end

local function planned_spatial_index(rows)
  local index = {}
  for _, row in ipairs(rows) do index_box(index, row) end
  return index
end

local function overlaps_planned(name, position, rows, spatial_index)
  local box = box_for(name, position)
  if not box then return false end
  if spatial_index then
    local checked = {}
    local min_x, max_x = math.floor(box.left), math.ceil(box.right) - 1
    local min_y, max_y = math.floor(box.top), math.ceil(box.bottom) - 1
    for x = min_x, max_x do
      for y = min_y, max_y do
        for _, row in ipairs(spatial_index[tostring(x) .. ":" .. tostring(y)] or {}) do
          if not checked[row] then
            checked[row] = true
            local other = box_for(row.name, row.position)
            if other and box.left < other.right and box.right > other.left
                and box.top < other.bottom and box.bottom > other.top then return true end
          end
        end
      end
    end
    return false
  end
  for _, row in ipairs(rows) do
    local other = box_for(row.name, row.position)
    if other and box.left < other.right and box.right > other.left
        and box.top < other.bottom and box.bottom > other.top then return true end
  end
  return false
end

local function distance(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

local function power_site(surface, force, pole, desired, source, target, rows, spatial_index)
  local base_x, base_y = math.floor(desired.x), math.floor(desired.y)
  local wire = math.min(source.wire, pole.max_wire_distance or 0) * 0.98
  local best, best_score = nil, nil
  -- Entity centres have one authoritative placement grid: even footprints use
  -- integer centres and odd footprints half-tile centres, independently per
  -- axis. Trying all four combinations let can_place accept a location which
  -- create_entity then snapped by half a tile; verification consequently
  -- looked at the planned coordinate and reported ten vanished K2 substations.
  local search_radius = math.max(8, math.min(24, math.floor(wire * 0.75)))
  local diagnostic = {
    tick = game.tick,
    pole = pole.entity,
    desired = {x = desired.x, y = desired.y},
    source = {x = source.position.x, y = source.position.y},
    target = {x = target.x, y = target.y},
    wire = wire,
    search_radius = search_radius,
    planned_entities = #rows,
    considered = 0,
    within_wire = 0,
    makes_progress = 0,
    conflicts = 0,
    overlaps = 0,
    placeable = 0
  }
  local checked = {}
  local function consider(raw_x, raw_y)
    local candidate = {
      x = snap_axis(raw_x, pole.tile_width or 1),
      y = snap_axis(raw_y, pole.tile_height or 1)
    }
    local key = tostring(candidate.x) .. ":" .. tostring(candidate.y)
    if checked[key] then return end
    checked[key] = true
    diagnostic.considered = diagnostic.considered + 1
    local within_wire = distance(candidate, source.position) <= wire
    local makes_progress = distance(candidate, target) < distance(source.position, target) - 0.25
    if within_wire then diagnostic.within_wire = diagnostic.within_wire + 1 end
    if within_wire and makes_progress then diagnostic.makes_progress = diagnostic.makes_progress + 1 end
    local blocked = within_wire and makes_progress
      and Conflict.is_blocked(surface.index, candidate, "autonomous") or false
    if blocked then diagnostic.conflicts = diagnostic.conflicts + 1 end
    local overlaps = within_wire and makes_progress and not blocked
      and overlaps_planned(pole.entity, candidate, rows, spatial_index) or false
    if overlaps then diagnostic.overlaps = diagnostic.overlaps + 1 end
    local placeable = within_wire and makes_progress and not blocked and not overlaps
      and SitePolicy.can_plan(surface, force, pole.entity, candidate, defines.direction.north) or false
    if not placeable then return end
    diagnostic.placeable = diagnostic.placeable + 1
    -- Progress dominates, but a small penalty for lateral deviation keeps
    -- successful routes visually straight instead of zigzagging.
    local ax, ay = target.x - source.position.x, target.y - source.position.y
    local bx, by = candidate.x - source.position.x, candidate.y - source.position.y
    local cross = math.abs(ax * by - ay * bx) / math.max(1, distance(source.position, target))
    local score = distance(candidate, target) + cross * 0.15
    if not best_score or score < best_score then best, best_score = candidate, score end
  end

  -- A belt or machine row normally blocks a straight feeder point. Search the
  -- perpendicular service corridor first: O(radius) candidates instead of the
  -- O(radius^2) square rings that produced both planning spikes and visibly
  -- wandering power lines. The exhaustive ring remains a bounded fallback for
  -- irregular modded footprints.
  local route_dx = target.x - source.position.x
  local route_dy = target.y - source.position.y
  local perpendicular_x, perpendicular_y = 1, 0
  if math.abs(route_dx) >= math.abs(route_dy) then perpendicular_x, perpendicular_y = 0, 1 end
  for offset = 0, search_radius do
    consider(base_x + perpendicular_x * offset, base_y + perpendicular_y * offset)
    if offset > 0 then
      consider(base_x - perpendicular_x * offset, base_y - perpendicular_y * offset)
    end
    if best then return best end
  end
  for radius = 1, search_radius do
    for dx = -radius, radius do
      consider(base_x + dx, base_y - radius)
      consider(base_x + dx, base_y + radius)
    end
    for dy = -radius + 1, radius - 1 do
      consider(base_x - radius, base_y + dy)
      consider(base_x + radius, base_y + dy)
    end
    if best then return best end
  end
  State.ensure().metrics.last_power_route = diagnostic
  return nil
end

local function add_power_rows(surface, force, rows, seen, pole_choice, existing, consumers)
  if #consumers == 0 then return true, 0 end
  if not pole_choice or #existing == 0 then return false, "electric_layout_has_no_source_grid" end
  local pole = pole_choice.row
  local spatial_index = planned_spatial_index(rows)
  local nodes = {}
  for _, entity in ipairs(existing) do
    nodes[#nodes + 1] = {
      position = {x = entity.position.x, y = entity.position.y},
      wire = entity.prototype.get_max_wire_distance(),
      supply = entity.prototype.get_supply_area_distance()
    }
  end
  local built = 0
  local pending = {}
  for _, target in ipairs(consumers) do pending[#pending + 1] = target end
  while true do
    local selected_index, selected, source, source_distance = nil, nil, nil, nil
    for index, target in ipairs(pending) do
      local target_covered = false
      for _, node in ipairs(nodes) do
        if math.abs(target.x - node.position.x) <= node.supply
            and math.abs(target.y - node.position.y) <= node.supply then
          target_covered = true
          break
        end
      end
      if not target_covered then
        for _, node in ipairs(nodes) do
          local candidate_distance = distance(node.position, target)
          local better_tie = selected and candidate_distance == source_distance
            and (target.x < selected.x or (target.x == selected.x and target.y < selected.y))
          if not source_distance or candidate_distance < source_distance or better_tie then
            selected_index, selected, source, source_distance = index, target, node, candidate_distance
          end
        end
      end
    end
    if not selected then break end
    table.remove(pending, selected_index)
    local guard = 0
    while source and (math.abs(selected.x - source.position.x) > source.supply
        or math.abs(selected.y - source.position.y) > source.supply) do
      guard = guard + 1
      if guard > 64 or built >= 96 then return false, "electric_route_too_long" end
      local remaining = distance(source.position, selected)
      local travel = math.min(math.min(source.wire, pole.max_wire_distance) * 0.86,
        math.max(1, remaining - pole.supply_area_distance * 0.70))
      local ratio = travel / math.max(remaining, 0.001)
      local desired = {
        x = source.position.x + (selected.x - source.position.x) * ratio,
        y = source.position.y + (selected.y - source.position.y) * ratio
      }
      local site = power_site(surface, force, pole, desired, source, selected, rows, spatial_index)
      if not site then return false, "electric_route_has_no_safe_site" end
      local row = {name = pole.entity, entity_type = "electric-pole", position = site,
        direction = defines.direction.north, construction_phase = 0}
      add_row(rows, seen, row)
      index_box(spatial_index, row)
      built = built + 1
      source = {position = site, wire = pole.max_wire_distance, supply = pole.supply_area_distance}
      nodes[#nodes + 1] = source
    end
  end
  return true, built
end

local function lane_construction_side(lanes, index)
  local current = lanes[index] and lanes[index][1]
  if not current then return {x = 0, y = 1} end
  local next_lane = lanes[index + 1] and lanes[index + 1][1]
  local previous_lane = lanes[index - 1] and lanes[index - 1][1]
  if not next_lane and not previous_lane then return {x = 0, y = 1} end
  -- The final lane must keep moving in the sweep's forward direction. Using
  -- previous-current here pointed its work side back into the finished drill
  -- rows and trapped Alina between two fast belts.
  local dx, dy
  if next_lane then
    dx, dy = next_lane.x - current.x, next_lane.y - current.y
  else
    dx, dy = current.x - previous_lane.x, current.y - previous_lane.y
  end
  if math.abs(dx) > math.abs(dy) then return {x = dx >= 0 and 1 or -1, y = 0} end
  return {x = 0, y = dy >= 0 and 1 or -1}
end

local function build_layout(player, agent, target_item, input_item, recipe, resource, drill_choice,
    machine_choice, belt_choice, inserter_choice, chest_choice, pole_choice, existing_poles, fuel, marker, options,
    known_bounds)
  local surface = player.surface
  local bounds = known_bounds or patch_bounds(surface, resource)
  local drill = drill_choice.row
  local machine = machine_choice.row
  local lanes = drill_lanes(surface, player.force, drill, bounds, input_item)
  if not lanes then return nil, "resource_patch_has_no_safe_drill_lanes" end
  local drills
  lanes, drills = trim_drill_lanes(lanes, MAX_DRILLS)
  local mineable = resource.prototype.mineable_properties
  local mining_time = math.max(0.001, (mineable and mineable.mining_time) or 1)
  local resource_output = 1
  for _, product in ipairs(mineable and mineable.products or {}) do
    if product.type == "item" and product.name == input_item then resource_output = expected_product(product); break end
  end
  local drill_rate = math.max(0.001, (drill.mining_speed or 0.25) * resource_output / mining_time)
  local belt_capacity = math.max(0.001, (belt_choice.row.belt_speed or 0.03125) * 480)
  local max_drills_for_belt = math.max(2, math.floor(belt_capacity * 0.90 / drill_rate))
  if #drills > max_drills_for_belt then
    lanes, drills = trim_drill_lanes(lanes, max_drills_for_belt)
  end
  local ingredient_amount = 1
  for _, ingredient in ipairs(recipe.ingredients or {}) do
    if ingredient.type == "item" and ingredient.name == input_item then ingredient_amount = ingredient.amount or 1; break end
  end
  local machine_rate = math.max(0.001,
    (machine.crafting_speed or 0.5) * ingredient_amount / math.max(0.001, recipe.energy or 0.5))
  local required_machines = math.ceil(#drills * drill_rate * 1.15 / machine_rate)
  local furnace_count = math.max(1, math.min(MAX_FURNACES, required_machines))
  local rows, seen = {}, {}
  local electric_consumers = {}
  local drill_fuel = drill.burner_categories and {name = fuel.name, count = 10} or nil
  local belt = belt_choice.row
  local inserter = inserter_choice.row
  local chest = chest_choice.row
  local turn_x = half_tile(bounds.max_x + (drill.tile_width or 1) + 3)
  local first_belt_y, last_belt_y = nil, nil
  for lane_index, lane in ipairs(lanes) do
    local work_side = lane_construction_side(lanes, lane_index)
    -- Finish each mining row where the next row starts: drill left-to-right,
    -- place the turn, then lay the belt right-to-left. Entity directions stay
    -- unchanged; only Alina's physical construction route becomes compact.
    for _, position in ipairs(lane) do
      add_row(rows, seen, {name = drill.entity, entity_type = "mining-drill", position = position,
        direction = defines.direction.south, fuel = drill_fuel,
        construction_work_side = work_side})
      if drill.electric then electric_consumers[#electric_consumers + 1] = position end
    end
    local belt_y = half_tile(lane[1].y + (drill.tile_height or 1) / 2 + 0.5)
    first_belt_y = first_belt_y and math.min(first_belt_y, belt_y) or belt_y
    last_belt_y = last_belt_y and math.max(last_belt_y, belt_y) or belt_y
    add_row(rows, seen, {name = belt.entity, entity_type = belt.entity_type,
      position = {x = turn_x, y = belt_y}, direction = defines.direction.south,
      construction_work_side = {x = 1, y = 0}})
    add_belt_line(rows, seen, belt, lane[1].x - (drill.tile_width or 1),
      turn_x - 1, belt_y, defines.direction.east, true, work_side)
  end

  local input_y = half_tile(math.max(bounds.max_y + 3, last_belt_y + 3))
  for y = math.floor(first_belt_y + 1), math.floor(input_y - 1) do
    add_row(rows, seen, {name = belt.entity, entity_type = belt.entity_type,
      position = {x = turn_x, y = y + 0.5}, direction = defines.direction.south,
      construction_work_side = {x = 1, y = 0}})
  end

  local machine_width = machine.tile_width or 1
  local machine_height = machine.tile_height or 1
  local machine_y = snap_axis(input_y + 1.5 + machine_height / 2, machine_height)
  local start_x = snap_axis(turn_x + 2.5 + machine_width / 2, machine_width)
  -- Inserters and the two belt rows are perpendicular to the machine row, so
  -- adjacent footprints need one service tile rather than two empty tiles.
  local spacing = machine_width + 1
  local furnaces = {}
  for i = 0, furnace_count - 1 do
    furnaces[#furnaces + 1] = {x = start_x + i * spacing, y = machine_y}
  end
  local input_end_x = half_tile(furnaces[#furnaces].x + machine_width / 2 + 1)
  add_belt_line(rows, seen, belt, turn_x, input_end_x, input_y, defines.direction.east)

  local inserter_fuel = inserter.burner_categories and {name = fuel.name, count = 3} or nil
  local machine_fuel = machine.burner_categories and {name = fuel.name, count = 10} or nil
  local high_throughput = (options and options.high_throughput)
    or (marker and marker.high_throughput) or false
  local module = ModulePolicy.choose(agent, machine, recipe, high_throughput, furnace_count)
  local first_machine_row = nil
  local output_y = half_tile(machine_y + machine_height / 2 + 1.5)
  local input_inserter_rows, machine_rows, output_inserter_rows = {}, {}, {}
  for _, position in ipairs(furnaces) do
    local input_inserter_row = {name = inserter.entity, entity_type = "inserter",
      position = {x = half_tile(position.x), y = half_tile(input_y + 1)},
      direction = defines.direction.north, fuel = inserter_fuel}
    input_inserter_rows[#input_inserter_rows + 1] = input_inserter_row
    if inserter.electric then electric_consumers[#electric_consumers + 1] = {x = half_tile(position.x), y = half_tile(input_y + 1)} end
    local machine_row = {name = machine.entity, entity_type = machine.entity_type,
      position = position, direction = defines.direction.north, fuel = machine_fuel,
      recipe = machine.entity_type == "assembling-machine" and recipe.name or nil,
      modules = module and {{name = module.name, count = module.count, quality = "normal"}} or nil}
    machine_rows[#machine_rows + 1] = machine_row
    if machine.electric then electric_consumers[#electric_consumers + 1] = position end
    first_machine_row = first_machine_row or machine_row
    output_inserter_rows[#output_inserter_rows + 1] = {name = inserter.entity, entity_type = "inserter",
      position = {x = half_tile(position.x), y = half_tile(output_y - 1)},
      direction = defines.direction.north, fuel = inserter_fuel}
    if inserter.electric then electric_consumers[#electric_consumers + 1] = {x = half_tile(position.x), y = half_tile(output_y - 1)} end
  end
  -- Build long rows in a boustrophedon sweep instead of bouncing vertically
  -- around every machine. This preserves every coordinate and dependency but
  -- substantially shortens the physical character's construction route.
  for index = 1, #input_inserter_rows do add_row(rows, seen, input_inserter_rows[index]) end
  for index = #machine_rows, 1, -1 do add_row(rows, seen, machine_rows[index]) end
  for index = 1, #output_inserter_rows do add_row(rows, seen, output_inserter_rows[index]) end

  local output_end_x = half_tile(furnaces[#furnaces].x + machine_width / 2 + 3)
  add_belt_line(rows, seen, belt, turn_x + 1, output_end_x, output_y, defines.direction.east)
  local output_row = nil
  local route_tiles = 0
  local route_endpoint = nil
  if marker and marker.route_to_base and marker.route_end then
    local route, route_error = RoutePlanner.plan(surface, player.force,
      {x = half_tile(output_end_x + 1), y = output_y}, marker.route_end, belt, inserter, chest, rows)
    if not route then return nil, route_error end
    for _, row in ipairs(route.entities) do
      if row.entity_type == "inserter" then
        row.fuel = inserter_fuel
        if inserter.electric then electric_consumers[#electric_consumers + 1] = row.position end
      end
      add_row(rows, seen, row)
    end
    output_row = route.output_row
    route_tiles = route.tiles
    route_endpoint = route.endpoint
  else
    local collector_inserter = {name = inserter.entity, entity_type = "inserter",
      position = {x = half_tile(output_end_x + 1), y = output_y},
      direction = defines.direction.west, fuel = inserter_fuel}
    add_row(rows, seen, collector_inserter)
    if inserter.electric then electric_consumers[#electric_consumers + 1] = collector_inserter.position end
    output_row = {name = chest.entity, entity_type = chest.entity_type,
      position = {x = half_tile(output_end_x + 2), y = output_y}, direction = defines.direction.north}
    add_row(rows, seen, output_row)
  end

  local power_ok, power_poles = add_power_rows(surface, player.force, rows, seen,
    pole_choice, existing_poles or {}, electric_consumers)
  if not power_ok then return nil, power_poles end

  -- The executor performs an authoritative all-or-nothing preflight immediately
  -- before acquisition. Repeating hundreds of can-place calls here doubled the
  -- same work in one planning tick and caused a visible frame hitch.
  return {
    bootstrap = true,
    recipe = recipe.name,
    input_item = input_item,
    target_item = target_item,
    entities = rows,
    construction_lane_sweep = true,
    producer_target = first_machine_row,
    output_row = output_row,
    approach_position = drills[1],
    source_position = {x = resource.position.x, y = resource.position.y},
    remote = false,
    drill_count = #drills,
    machine_count = furnace_count,
    route_tiles = route_tiles,
    route_endpoint = route_endpoint,
    module = module and module.name or nil,
    module_count = module and module.count * furnace_count or 0,
    power_poles = power_poles,
    resource_tiles = bounds.resource_tiles,
    resource_amount = bounds.resource_amount,
    expected_input_per_second = #drills * drill_rate,
    processing_capacity_per_second = furnace_count * machine_rate,
    belt_capacity_per_second = belt_capacity,
    belt_speed_tiles_per_tick = belt.belt_speed or 0.03125,
    capacity_headroom = furnace_count * machine_rate / math.max(0.001, #drills * drill_rate) - 1
  }
end

local function marked_resource(agent, item_name, marker)
  if not marker then return nil end
  if marker.surface_index ~= agent.surface.index then return nil end
  local best, best_distance = nil, nil
  for _, candidate in ipairs(PrototypeIndex.resources_for(item_name) or {}) do
    if candidate.entity_type == "resource" then
      local entities = agent.surface.find_entities_filtered({
        position = marker.position,
        radius = 48,
        type = "resource",
        name = candidate.entity,
        limit = 128
      })
      for _, entity in ipairs(entities) do
        if entity.valid and entity.amount and entity.amount > 0
            and not Conflict.is_blocked(entity.surface.index, entity.position, "direct_player") then
          local dx, dy = entity.position.x - marker.position.x, entity.position.y - marker.position.y
          local distance = dx * dx + dy * dy
          if not best_distance or distance < best_distance then best, best_distance = entity, distance end
        end
      end
    end
  end
  return best
end

local function direct_resource_available(item_name)
  for _, row in ipairs(PrototypeIndex.resources_for(item_name) or {}) do
    if row.entity_type == "resource" then return true end
  end
  return false
end

local function build_extraction_layout(player, agent, target_item, resource, drill_choice,
    belt_choice, inserter_choice, chest_choice, pole_choice, existing_poles, fuel, marker, known_bounds)
  local surface = player.surface
  local bounds = known_bounds or patch_bounds(surface, resource)
  local drill = drill_choice.row
  local lanes = drill_lanes(surface, player.force, drill, bounds, target_item)
  if not lanes then return nil, "resource_patch_has_no_safe_drill_lanes" end
  local drills
  lanes, drills = trim_drill_lanes(lanes, MAX_DRILLS)

  local mineable = resource.prototype.mineable_properties
  local mining_time = math.max(0.001, (mineable and mineable.mining_time) or 1)
  local resource_output = 1
  for _, product in ipairs(mineable and mineable.products or {}) do
    if product.type == "item" and product.name == target_item then
      resource_output = expected_product(product)
      break
    end
  end
  local drill_rate = math.max(0.001, (drill.mining_speed or 0.25) * resource_output / mining_time)
  local belt = belt_choice.row
  local belt_capacity = math.max(0.001, (belt.belt_speed or 0.03125) * 480)
  local max_drills_for_belt = math.max(2, math.floor(belt_capacity * 0.90 / drill_rate))
  if #drills > max_drills_for_belt then
    lanes, drills = trim_drill_lanes(lanes, max_drills_for_belt)
  end

  local rows, seen, electric_consumers = {}, {}, {}
  local drill_fuel = drill.burner_categories and {name = fuel.name, count = 10} or nil
  local first_drill_row = nil
  local turn_x = half_tile(bounds.max_x + (drill.tile_width or 1) + 3)
  local first_belt_y, last_belt_y = nil, nil
  for lane_index, lane in ipairs(lanes) do
    local work_side = lane_construction_side(lanes, lane_index)
    for _, position in ipairs(lane) do
      local row = {name = drill.entity, entity_type = "mining-drill", position = position,
        direction = defines.direction.south, fuel = drill_fuel,
        construction_work_side = work_side}
      add_row(rows, seen, row)
      first_drill_row = first_drill_row or row
      if drill.electric then electric_consumers[#electric_consumers + 1] = position end
    end
    local belt_y = half_tile(lane[1].y + (drill.tile_height or 1) / 2 + 0.5)
    first_belt_y = first_belt_y and math.min(first_belt_y, belt_y) or belt_y
    last_belt_y = last_belt_y and math.max(last_belt_y, belt_y) or belt_y
    add_row(rows, seen, {name = belt.entity, entity_type = belt.entity_type,
      position = {x = turn_x, y = belt_y}, direction = defines.direction.south,
      construction_work_side = {x = 1, y = 0}})
    add_belt_line(rows, seen, belt, lane[1].x - (drill.tile_width or 1),
      turn_x - 1, belt_y, defines.direction.east, true, work_side)
  end
  local output_y = half_tile(last_belt_y + 3)
  for y = math.floor(first_belt_y + 1), math.floor(output_y - 1) do
    add_row(rows, seen, {name = belt.entity, entity_type = belt.entity_type,
      position = {x = turn_x, y = y + 0.5}, direction = defines.direction.south,
      construction_work_side = {x = 1, y = 0}})
  end
  add_row(rows, seen, {name = belt.entity, entity_type = belt.entity_type,
    position = {x = turn_x, y = output_y}, direction = defines.direction.east,
    construction_work_side = {x = 0, y = 1}})

  local inserter = inserter_choice.row
  local inserter_fuel = inserter.burner_categories and {name = fuel.name, count = 3} or nil
  local output_row, route_tiles, route_endpoint = nil, 0, nil
  if marker and marker.route_to_base and marker.route_end then
    local route, route_error = RoutePlanner.plan(surface, player.force,
      {x = half_tile(turn_x + 1), y = output_y}, marker.route_end,
      belt, inserter, chest_choice.row, rows)
    if not route then return nil, route_error end
    for _, row in ipairs(route.entities) do
      if row.entity_type == "inserter" then
        row.fuel = inserter_fuel
        if inserter.electric then electric_consumers[#electric_consumers + 1] = row.position end
      end
      add_row(rows, seen, row)
    end
    output_row = route.output_row
    route_tiles = route.tiles
    route_endpoint = route.endpoint
  else
    local collector = {name = inserter.entity, entity_type = "inserter",
      position = {x = half_tile(turn_x + 1), y = output_y},
      direction = defines.direction.west, fuel = inserter_fuel}
    add_row(rows, seen, collector)
    if inserter.electric then electric_consumers[#electric_consumers + 1] = collector.position end
    local chest = chest_choice.row
    output_row = {name = chest.entity, entity_type = chest.entity_type,
      position = {x = half_tile(turn_x + 2), y = output_y}, direction = defines.direction.north}
    add_row(rows, seen, output_row)
  end

  local power_ok, power_poles = add_power_rows(surface, player.force, rows, seen,
    pole_choice, existing_poles or {}, electric_consumers)
  if not power_ok then return nil, power_poles end
  -- Full placement validation belongs to the physical executor, where player
  -- intent and transient obstacles are checked against the freshest state.
  return {
    bootstrap = true,
    extraction_bootstrap = true,
    input_item = target_item,
    target_item = target_item,
    entities = rows,
    construction_lane_sweep = true,
    producer_target = first_drill_row,
    output_row = output_row,
    approach_position = drills[1],
    source_position = {x = resource.position.x, y = resource.position.y},
    remote = false,
    drill_count = #drills,
    machine_count = 0,
    route_tiles = route_tiles,
    route_endpoint = route_endpoint,
    power_poles = power_poles,
    resource_tiles = bounds.resource_tiles,
    resource_amount = bounds.resource_amount,
    expected_input_per_second = #drills * drill_rate,
    processing_capacity_per_second = #drills * drill_rate,
    belt_capacity_per_second = belt_capacity,
    belt_speed_tiles_per_tick = belt.belt_speed or 0.03125,
    capacity_headroom = belt_capacity / math.max(0.001, #drills * drill_rate) - 1
  }
end

local function plan_direct_extraction(player, agent, target_item, marker, options)
  local resource = marker and marked_resource(agent, target_item, marker)
    -- Automated mining must include resource categories that the character
    -- cannot mine by hand (K2SO and many overhaul packs rely on these).
    or PrototypeIndex.find_resource(agent, target_item, "autonomous", 768, true,
      resource_exclusions(agent, target_item, options), true)
  if not resource or resource.type ~= "resource" then return nil, "resource_patch_not_found" end
  local bounds = patch_bounds(player.surface, resource)
  local center = {x = (bounds.min_x + bounds.max_x) / 2, y = (bounds.min_y + bounds.max_y) / 2}
  local existing_poles = existing_power_poles(player.surface, player.force, center)
  local pole_choice = nil
  if #existing_poles > 0 then
    pole_choice = placement_choice(agent, PrototypeIndex.entities_for_type("electric-pole"), 24, nil,
      function(row) return (row.supply_area_distance or 0) * 100 + (row.max_wire_distance or 0) end)
  end
  local can_extend_power = pole_choice ~= nil and #existing_poles > 0
  local drill_rows = PrototypeIndex.entities_for_type("mining-drill") or {}
  local drill_choice, drill_error = placement_choice(agent, drill_rows, math.min(8, MAX_DRILLS),
    function(row) return row.resource_categories and row.resource_categories[resource.prototype.resource_category]
      and (row.burner_categories ~= nil or (row.electric and can_extend_power)) end,
    function(row) return (row.mining_speed or 0) * 100 + (row.mining_radius or 0) end)
  local route_distance = marker and marker.route_to_base and marker.route_end
    and math.abs(resource.position.x - marker.route_end.x) + math.abs(resource.position.y - marker.route_end.y) or 0
  local belt_requirement = math.min(MAX_ROUTE_BELTS, math.max(128, math.ceil(route_distance + 96)))
  local belt_choice, belt_error = placement_choice(agent,
    PrototypeIndex.entities_for_type("transport-belt"), math.min(128, belt_requirement), nil,
    function(row) return row.belt_speed or 0 end)
  local inserter_choice, inserter_error = placement_choice(agent,
    PrototypeIndex.entities_for_type("inserter"), 2,
    function(row) return row.burner_categories ~= nil or (row.electric and can_extend_power) end,
    function(row) return (row.inserter_rotation_speed or 0) * 100 + (row.inserter_reach or 1) end)
  local chest_choice, chest_error = placement_choice(agent,
    PrototypeIndex.entities_for_type("container"), 1)
  if not chest_choice then
    chest_choice, chest_error = placement_choice(agent,
      PrototypeIndex.entities_for_type("logistic-container"), 1)
  end
  if not drill_choice or not belt_choice or not inserter_choice or not chest_choice then
    return nil, "extraction_components_not_obtainable:drill=" .. tostring(drill_choice ~= nil)
      .. ",belt=" .. tostring(belt_choice ~= nil)
      .. ",inserter=" .. tostring(inserter_choice ~= nil)
      .. ",chest=" .. tostring(chest_choice ~= nil)
      .. ",errors=" .. tostring(drill_error) .. "|" .. tostring(belt_error)
      .. "|" .. tostring(inserter_error) .. "|" .. tostring(chest_error)
  end
  local fuel_categories = {}
  for category in pairs(drill_choice.row.burner_categories or {}) do fuel_categories[category] = true end
  for category in pairs(inserter_choice.row.burner_categories or {}) do fuel_categories[category] = true end
  local fuel = next(fuel_categories) and fuel_choice(agent, fuel_categories, 400) or {name = nil}
  if next(fuel_categories) and not fuel then return nil, "extraction_fuel_not_obtainable" end
  return build_extraction_layout(player, agent, target_item, resource, drill_choice,
    belt_choice, inserter_choice, chest_choice, pole_choice, existing_poles, fuel, marker, bounds)
end

function ChainPlanner.plan(player, agent, target_item, marker, options)
  if not RecipeIndex.is_ready() or not PrototypeIndex.is_ready() then return nil, "indexes_not_ready" end
  -- Overhaul packs often add conversion/recycling recipes for raw resources
  -- (for example wood -> coal). If an actual deposit produces the requested
  -- item, mining it is the grounded industrial solution and must win before
  -- any incidental conversion recipe.
  if direct_resource_available(target_item) then
    local plan, error_message = plan_direct_extraction(player, agent, target_item, marker, options)
    if plan and marker then plan.marker_goal = marker end
    return plan, error_message
  end
  local recipe, input_item = recipe_for_resource_product(player, target_item)
  if not recipe then
    return nil, "no_simple_resource_recipe"
  end
  local resource = marker and marked_resource(agent, input_item, marker)
    or PrototypeIndex.find_resource(agent, input_item, "autonomous", 768, true,
      resource_exclusions(agent, input_item, options), true)
  if not resource or resource.type ~= "resource" then return nil, "resource_patch_not_found" end

  local drill_rows = PrototypeIndex.entities_for_type("mining-drill") or {}
  local matching_drills = 0
  for _, row in ipairs(drill_rows) do
    if row.resource_categories and row.resource_categories[resource.prototype.resource_category] then
      matching_drills = matching_drills + 1
    end
  end
  local bounds = patch_bounds(player.surface, resource)
  local center = {x = (bounds.min_x + bounds.max_x) / 2, y = (bounds.min_y + bounds.max_y) / 2}
  local existing_poles = existing_power_poles(player.surface, player.force, center)
  local pole_choice = nil
  if #existing_poles > 0 then
    pole_choice = placement_choice(agent, PrototypeIndex.entities_for_type("electric-pole"), 24, nil,
      function(row) return (row.supply_area_distance or 0) * 100 + (row.max_wire_distance or 0) end)
  end
  local can_extend_power = pole_choice ~= nil and #existing_poles > 0
  local drill_choice, drill_error = placement_choice(agent, drill_rows, math.min(8, MAX_DRILLS),
    function(row) return row.resource_categories and row.resource_categories[resource.prototype.resource_category]
      and (row.burner_categories ~= nil or (row.electric and can_extend_power)) end,
    function(row) return (row.mining_speed or 0) * 100 + (row.mining_radius or 0) end)
  if not drill_choice then
    return nil, "obtainable_mining_drill_not_found:category=" .. tostring(resource.prototype.resource_category)
      .. ",rows=" .. #drill_rows .. ",matching=" .. matching_drills
      .. ",error=" .. tostring(drill_error)
  end

  local machine_rows = {}
  local seen_machine = {}
  for _, category in ipairs(sorted_keys(recipe.categories)) do
    for _, row in ipairs(PrototypeIndex.machines_for(category) or {}) do
      if not seen_machine[row.entity] then seen_machine[row.entity] = true; machine_rows[#machine_rows + 1] = row end
    end
  end
  local machine_choice, machine_error = placement_choice(agent, machine_rows, math.min(8, MAX_FURNACES),
    function(row) return row.burner_categories ~= nil or (row.electric and can_extend_power) end,
    function(row) return (row.crafting_speed or 0) * 100 + (row.module_inventory_size or 0) end)
  local route_distance = marker and marker.route_to_base and marker.route_end
    and math.abs(resource.position.x - marker.route_end.x) + math.abs(resource.position.y - marker.route_end.y) or 0
  local belt_requirement = math.min(MAX_ROUTE_BELTS, math.max(128, math.ceil(route_distance + 160)))
  local belt_choice, belt_error = placement_choice(agent,
    PrototypeIndex.entities_for_type("transport-belt"), math.min(128, belt_requirement), nil,
    function(row) return row.belt_speed or 0 end)
  local inserter_choice, inserter_error = placement_choice(agent,
    PrototypeIndex.entities_for_type("inserter"), 32,
    function(row) return row.burner_categories ~= nil or (row.electric and can_extend_power) end,
    function(row) return (row.inserter_rotation_speed or 0) * 100 + (row.inserter_reach or 1) end)
  local chest_choice, chest_error = placement_choice(agent, PrototypeIndex.entities_for_type("container"), 1)
  if not chest_choice then
    local logistic_choice, logistic_error = placement_choice(agent, PrototypeIndex.entities_for_type("logistic-container"), 1)
    chest_choice = logistic_choice
    chest_error = chest_error or logistic_error
  end
  if not machine_choice or not belt_choice or not inserter_choice or not chest_choice then
    return nil, "bootstrap_components_not_obtainable:machine=" .. tostring(machine_choice ~= nil)
      .. ",belt=" .. tostring(belt_choice ~= nil)
      .. ",inserter=" .. tostring(inserter_choice ~= nil)
      .. ",chest=" .. tostring(chest_choice ~= nil)
      .. ",errors=" .. tostring(machine_error) .. "|" .. tostring(belt_error)
      .. "|" .. tostring(inserter_error) .. "|" .. tostring(chest_error)
  end

  local fuel_categories = {}
  for category in pairs(drill_choice.row.burner_categories or {}) do fuel_categories[category] = true end
  for category in pairs(machine_choice.row.burner_categories or {}) do fuel_categories[category] = true end
  for category in pairs(inserter_choice.row.burner_categories or {}) do fuel_categories[category] = true end
  local fuel = next(fuel_categories) and fuel_choice(agent, fuel_categories, 600) or {name = nil}
  if next(fuel_categories) and not fuel then return nil, "bootstrap_fuel_not_obtainable" end

  local layout, error_message = build_layout(player, agent, target_item, input_item, recipe, resource, drill_choice,
    machine_choice, belt_choice, inserter_choice, chest_choice, pole_choice, existing_poles, fuel, marker, options,
    bounds)
  if layout and marker then layout.marker_goal = marker end
  return layout, error_message
end

return ChainPlanner
