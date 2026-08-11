local Acquisition = require("scripts.executor.acquisition")
local Conflict = require("scripts.conflict.manager")
local ModulePolicy = require("scripts.autonomy.module_policy")
local PipeRouter = require("scripts.autonomy.pipe_router")
local PrototypeIndex = require("scripts.sensors.prototype_index")
local RecipeIndex = require("scripts.sensors.recipe_index")
local SitePolicy = require("scripts.construction.site_policy")

local FluidPlanner = {}

local DEFAULT_MACHINE_COUNT = 4
local MAX_SCORED_SITE_POLES = 48
local MAX_LAYOUT_SITE_POLES = 3
local HIGH_THROUGHPUT_MACHINE_COUNT = 8
local BUFFER_CRAFTS = 12
local SOURCE_RADIUS = 384
local MAX_EXTERNAL_SOURCE_ROUTE_ATTEMPTS = 8
local PIPELINE_EXTENT_SAFETY = 0.90
local PUMP_CAPACITY_SAFETY = 0.85
local FLUID_CONNECTION_CAPACITY_PER_SECOND = 6000

local DIRECTION_VECTOR = {
  [defines.direction.north] = {x = 0, y = -1},
  [defines.direction.east] = {x = 1, y = 0},
  [defines.direction.south] = {x = 0, y = 1},
  [defines.direction.west] = {x = -1, y = 0}
}

local function sorted_values(values)
  local result = {}
  for key, value in pairs(values or {}) do result[#result + 1] = type(key) == "number" and value or key end
  table.sort(result)
  return result
end

local function expected_product(product)
  local amount = product.amount
  if not amount and product.amount_min and product.amount_max then
    amount = (product.amount_min + product.amount_max) / 2
  end
  return (amount or 1) * (product.probability or 1)
end

local function temperature_matches(fluid, ingredient)
  local temperature = fluid.temperature or (prototypes.fluid[fluid.name] and prototypes.fluid[fluid.name].default_temperature)
  if ingredient.temperature and temperature ~= ingredient.temperature then return false end
  if ingredient.minimum_temperature and temperature < ingredient.minimum_temperature then return false end
  if ingredient.maximum_temperature and temperature > ingredient.maximum_temperature then return false end
  return true
end

local function item_repackages_fluid(player, item_name, fluid_name)
  for _, producer in ipairs(RecipeIndex.find_producers(item_name, player.force, 32) or {}) do
    if producer.enabled then
      for _, ingredient in ipairs(producer.ingredients or {}) do
        if ingredient.type == "fluid" and ingredient.name == fluid_name then return true end
      end
    end
  end
  return false
end

local function recipe_choice(player, target_name, target_type)
  local best, best_score = nil, nil
  for _, recipe in ipairs(RecipeIndex.find_producers(target_name, player.force, 64) or {}) do
    local valid = recipe.enabled and #recipe.ingredients >= 1 and #recipe.ingredients <= 8
    local fluid_inputs, item_inputs, output = 0, 0, 0
    for _, ingredient in ipairs(recipe.ingredients or {}) do
      if not ingredient.amount then valid = false; break end
      if ingredient.type == "fluid" then fluid_inputs = fluid_inputs + 1
      elseif ingredient.type == "item" then item_inputs = item_inputs + 1
      else valid = false; break end
    end
    for _, product in ipairs(recipe.products or {}) do
      if product.type == target_type and product.name == target_name then
        output = output + expected_product(product)
      end
    end
    if valid and target_type == "fluid" and fluid_inputs == 0 and item_inputs > 0 then
      for _, ingredient in ipairs(recipe.ingredients or {}) do
        if ingredient.type == "item" and item_repackages_fluid(player, ingredient.name, target_name) then
          valid = false
          break
        end
      end
    end
    if valid and output > 0 and (target_type == "fluid" or fluid_inputs > 0) then
      local score = (fluid_inputs * 120 + item_inputs * 20 + (recipe.energy or 1)) / output
      if not best_score or score < best_score then best, best_score = recipe, score end
    end
  end
  return best
end

local function acquisition_score(plan)
  local score = #(plan.operations or {}) * 10000
  for _, operation in ipairs(plan.operations or {}) do
    score = score + (operation.count or operation.crafts or operation.output_count or 1)
  end
  return score
end

local function placement_choice(agent, rows, count, predicate, preference)
  local best, best_score, last_error = nil, nil, nil
  for _, row in ipairs(rows or {}) do
    if not predicate or predicate(row) then
      for _, item in ipairs(row.items or {}) do
        local plan, err = Acquisition.make_plan(agent, item.name, count * (item.count or 1), "autonomous")
        if plan then
          local score = acquisition_score(plan) + (row.tile_width or 1) * (row.tile_height or 1)
            + (preference and preference(row) or 0)
          if not best_score or score < best_score then
            best_score = score
            best = {row = row, item = item.name, item_count = item.count or 1}
          end
        else
          last_error = item.name .. ":" .. tostring(err)
        end
      end
    end
  end
  return best, last_error
end

local function machine_rows(recipe)
  local rows, seen = {}, {}
  for _, category in ipairs(sorted_values(recipe.categories)) do
    for _, row in ipairs(PrototypeIndex.machines_for(category) or {}) do
      if row.entity_type == "assembling-machine" and not seen[row.entity] then
        seen[row.entity] = true
        rows[#rows + 1] = row
      end
    end
  end
  return rows
end

local function container_rows()
  local rows = {}
  for _, entity_type in ipairs({"container", "linked-container", "logistic-container"}) do
    for _, row in ipairs(PrototypeIndex.entities_for_type(entity_type) or {}) do rows[#rows + 1] = row end
  end
  return rows
end

local function input_fluidboxes(machine)
  local result = {}
  for _, fluidbox in ipairs(machine.fluidboxes or {}) do
    if fluidbox.production_type == "input" or fluidbox.production_type == "input-output" then
      result[#result + 1] = fluidbox
    end
  end
  table.sort(result, function(a, b) return (a.index or 0) < (b.index or 0) end)
  return result
end

local function output_fluidboxes(machine)
  local result = {}
  for _, fluidbox in ipairs(machine.fluidboxes or {}) do
    if fluidbox.production_type == "output" or fluidbox.production_type == "input-output" then
      result[#result + 1] = fluidbox
    end
  end
  table.sort(result, function(a, b) return (a.index or 0) < (b.index or 0) end)
  return result
end

local function fluid_rows(recipe, wanted_type)
  local result = {}
  local source = wanted_type == "ingredient" and recipe.ingredients or recipe.products
  for _, row in ipairs(source or {}) do
    if row.type == "fluid" then result[#result + 1] = row end
  end
  return result
end

local function has_ports(machine, recipe)
  return #input_fluidboxes(machine) >= #fluid_rows(recipe, "ingredient")
    and #output_fluidboxes(machine) >= #fluid_rows(recipe, "product")
end

local function snap_axis(value, size)
  if (size or 1) % 2 == 0 then return math.floor(value + 0.5) end
  return math.floor(value) + 0.5
end

local function half_tile(value)
  return math.floor(value) + 0.5
end

local function distance(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

local function pipeline_extent_limit()
  local ok, value = pcall(function() return prototypes.utility_constants.default_pipeline_extent end)
  if not ok or type(value) ~= "number" or value <= 0 then value = 320 end
  return math.max(16, math.floor(value * PIPELINE_EXTENT_SAFETY))
end

local function fluid_rate_per_second(recipe, machine, module, row, product)
  local speed = math.max(0.001, machine.crafting_speed or 1)
  if module then speed = speed * math.max(0.05, 1 + (module.speed or 0) * (module.count or 0)) end
  local crafts_per_second = speed / math.max(0.001, recipe.energy or 0.5)
  local amount = product and expected_product(row) or (row.amount or 0)
  return math.max(0, amount * crafts_per_second)
end

local function transport_lanes(path, pump, required_flow)
  local maximum = pipeline_extent_limit()
  -- Factorio 2.1 does not lose throughput merely because a pipe segment is
  -- long, but every machine connection is still capped at one 100-fluid flow
  -- operation per tick. Extra parallel pipes cannot bypass a single machine
  -- port, so reject an impossible design before considering route length.
  if required_flow > FLUID_CONNECTION_CAPACITY_PER_SECOND then
    return nil, maximum, "machine_fluid_connection_capacity_exceeded:"
      .. string.format("%.1f", required_flow)
  end
  if #path - 1 <= maximum then return 1, maximum end
  if not pump or (pump.pumping_speed or 0) <= 0 then
    return nil, maximum, "pipeline_extent_requires_obtainable_pump"
  end
  local safe_capacity = pump.pumping_speed * 60 * PUMP_CAPACITY_SAFETY
  return math.max(1, math.ceil(required_flow / math.max(0.001, safe_capacity))), maximum
end

local function powered_poles(agent, marker, origin_override)
  local origin = origin_override
    or (marker and marker.surface_index == agent.surface.index and marker.position)
    or agent.position
  local poles = agent.surface.find_entities_filtered({position = origin, radius = marker and 128 or 512,
    type = "electric-pole", force = agent.force, limit = 256})
  local result = {}
  for _, pole in ipairs(poles) do
    if pole.valid and pole.electric_network_id then result[#result + 1] = pole end
  end
  table.sort(result, function(a, b) return distance(a.position, origin) < distance(b.position, origin) end)
  return result
end

local function obtainable_fuel(agent, categories, count)
  local fuels = PrototypeIndex.fuels_for(categories) or {}
  for index = #fuels, 1, -1 do
    local fuel = fuels[index]
    local plan = Acquisition.make_plan(agent, fuel.name, count, "autonomous")
    if plan then return fuel.name end
  end
  return nil
end

local function footprint_available(occupied, row)
  local width, height = row.tile_width or 1, row.tile_height or 1
  local start_x = row.position.x - (width - 1) / 2
  local start_y = row.position.y - (height - 1) / 2
  for x_index = 0, width - 1 do
    for y_index = 0, height - 1 do
      if occupied[PipeRouter.key({x = start_x + x_index, y = start_y + y_index})] then return false end
    end
  end
  return true
end

local function collides_with_planned(rows, name, position)
  local prototype = prototypes.entity[name]
  local box = prototype and prototype.collision_box or nil
  if not box then return false end
  local left = position.x + box.left_top.x
  local right = position.x + box.right_bottom.x
  local top = position.y + box.left_top.y
  local bottom = position.y + box.right_bottom.y
  for _, row in ipairs(rows or {}) do
    local other = prototypes.entity[row.name]
    local other_box = other and other.collision_box or nil
    if other_box then
      local other_left = row.position.x + other_box.left_top.x
      local other_right = row.position.x + other_box.right_bottom.x
      local other_top = row.position.y + other_box.left_top.y
      local other_bottom = row.position.y + other_box.right_bottom.y
      if left < other_right and right > other_left and top < other_bottom and bottom > other_top then
        return true
      end
    end
  end
  return false
end

local function fluidbox_for(rows, recipe_row, ordinal)
  -- Recipe fluidbox_index is ordinal within the compatible input/output group,
  -- not the absolute machine fluidbox index. Basic oil processing demonstrates
  -- both cases: its only crude input selects input 2, while petroleum selects
  -- output 3 (absolute refinery boxes 2 and 5 respectively).
  if recipe_row and recipe_row.fluidbox_index and rows[recipe_row.fluidbox_index] then
    return rows[recipe_row.fluidbox_index]
  end
  return rows[ordinal]
end

local function connection_target(machine_position, fluidbox)
  if not fluidbox then return nil end
  for _, connection in ipairs(fluidbox.pipe_connections or {}) do
    if connection.connection_type == "normal" or connection.connection_type == nil then
      local position = connection.positions and connection.positions[1] or nil
      local vector = DIRECTION_VECTOR[connection.direction]
      if position and vector then
        return {x = machine_position.x + position.x + vector.x,
          y = machine_position.y + position.y + vector.y}
      end
    end
  end
  return nil
end

local function connection_vector(fluidbox)
  for _, connection in ipairs(fluidbox and fluidbox.pipe_connections or {}) do
    if connection.connection_type == "normal" or connection.connection_type == nil then
      local position = connection.positions and connection.positions[1] or nil
      local vector = DIRECTION_VECTOR[connection.direction]
      if position and vector then return vector end
    end
  end
  return nil
end

local function connection_targets(entity_position, fluidboxes)
  local result, seen = {}, {}
  for _, fluidbox in ipairs(fluidboxes or {}) do
    for _, connection in ipairs(fluidbox.pipe_connections or {}) do
      if connection.connection_type == "normal" or connection.connection_type == nil then
        local position = connection.positions and connection.positions[1] or nil
        local vector = DIRECTION_VECTOR[connection.direction]
        if position and vector then
          local target = {x = entity_position.x + position.x + vector.x,
            y = entity_position.y + position.y + vector.y}
          local target_key = PipeRouter.key(target)
          if not seen[target_key] then
            seen[target_key] = true
            result[#result + 1] = target
          end
        end
      end
    end
  end
  return result
end

local function fluid_in_segment(entity, index)
  local ok, fluid = pcall(function() return entity.get_fluid_segment_fluid(index) end)
  if ok and fluid and fluid.name and (fluid.amount or 0) > 0 then return fluid end
  return nil
end

local SOURCE_TYPES = {
  "pipe", "storage-tank", "pump", "pipe-to-ground", "offshore-pump",
  "mining-drill", "assembling-machine", "furnace", "boiler", "generator"
}

local SOURCE_TYPE_SCORE = {
  pipe = 0, ["storage-tank"] = 10, pump = 20, ["pipe-to-ground"] = 30,
  ["offshore-pump"] = 40, ["mining-drill"] = 50, ["assembling-machine"] = 60,
  furnace = 60, boiler = 70, generator = 80
}

local function fluid_sources(agent, ingredient, origin)
  local entities = agent.surface.find_entities_filtered({position = origin, radius = SOURCE_RADIUS,
    type = SOURCE_TYPES, force = agent.force, limit = 2048})
  local result = {}
  for _, entity in ipairs(entities) do
    local ok_count, count = pcall(function() return entity.fluids_count end)
    if entity.valid and ok_count then
      for index = 1, count or 0 do
        local fluid = fluid_in_segment(entity, index)
        if fluid and fluid.name == ingredient.name and temperature_matches(fluid, ingredient) then
          local segment_ok, segment_id = pcall(function() return entity.get_fluid_segment_id(index) end)
          local segment_key = segment_ok and segment_id and ("segment:" .. tostring(segment_id))
            or ("entity:" .. tostring(entity.unit_number or entity.name) .. ":" .. tostring(index))
          local ok, connections = pcall(function() return entity.get_fluid_box_pipe_connections(index) end)
          if ok then
            for _, connection in ipairs(connections or {}) do
              if not connection.target and connection.target_position
                  and connection.flow_direction ~= "input" then
                local dx = connection.target_position.x - origin.x
                local dy = connection.target_position.y - origin.y
                result[#result + 1] = {
                  entity = entity,
                  unit_number = entity.unit_number,
                  fluidbox_index = index,
                  segment_key = segment_key,
                  fluid = fluid,
                  position = {x = connection.target_position.x, y = connection.target_position.y},
                  score = dx * dx + dy * dy + (SOURCE_TYPE_SCORE[entity.type] or 100) * 100
                }
              end
            end
          end
        end
      end
    end
  end
  table.sort(result, function(a, b)
    if a.score == b.score then
      if (a.unit_number or 0) == (b.unit_number or 0) then
        if a.position.y == b.position.y then return a.position.x < b.position.x end
        return a.position.y < b.position.y
      end
      return (a.unit_number or 0) < (b.unit_number or 0)
    end
    return a.score < b.score
  end)
  return result
end

local function add_row(rows, seen, row)
  local row_key = PipeRouter.key(row.position)
  if seen[row_key] then return false end
  seen[row_key] = true
  row.bootstrap = true
  rows[#rows + 1] = row
  return true
end

local function occupy(occupied, row)
  local width, height = row.tile_width or 1, row.tile_height or 1
  local start_x = row.position.x - (width - 1) / 2
  local start_y = row.position.y - (height - 1) / 2
  for x_index = 0, width - 1 do
    for y_index = 0, height - 1 do
      occupied[PipeRouter.key({x = start_x + x_index, y = start_y + y_index})] = true
    end
  end
end

local function validate_non_pipe(surface, force, rows)
  for _, row in ipairs(rows) do
    if row.entity_type ~= "pipe" then
      if Conflict.is_blocked(surface.index, row.position, "autonomous") then return false end
      if not SitePolicy.can_plan(surface, force, row.name, row.position, row.direction) then return false end
    end
  end
  return true
end

local function add_pump_power(agent, rows, seen, occupied, pump_rows, pole, existing_pole)
  if #pump_rows == 0 then return true end
  local anchors = {{position = {x = existing_pole.position.x, y = existing_pole.position.y},
    wire = existing_pole.prototype.get_max_wire_distance()}}
  for _, row in ipairs(rows) do
    if row.entity_type == "electric-pole" then
      anchors[#anchors + 1] = {position = row.position, wire = pole.max_wire_distance or 0}
    end
  end
  local supply = math.max(1.5, pole.supply_area_distance or 0)
  local wire = math.max(2, pole.max_wire_distance or 0)
  local offset = math.min(2, supply - 0.25)
  local offsets = {
    {x = 0, y = 0},
    {x = 0, y = 1}, {x = 0, y = -1}, {x = 1, y = 0}, {x = -1, y = 0},
    {x = 0, y = offset}, {x = 0, y = -offset},
    {x = offset, y = 0}, {x = -offset, y = 0},
    {x = offset, y = offset}, {x = offset, y = -offset},
    {x = -offset, y = offset}, {x = -offset, y = -offset}
  }
  local function place_pole_near(position)
    for _, offset in ipairs(offsets) do
      local candidate = {x = half_tile(position.x + offset.x), y = half_tile(position.y + offset.y)}
      local candidate_key = PipeRouter.key(candidate)
      if not seen[candidate_key] and not occupied[candidate_key]
          and not collides_with_planned(rows, pole.entity, candidate)
          and SitePolicy.can_plan(agent.surface, agent.force, pole.entity, candidate, defines.direction.north) then
        local row = {name = pole.entity, entity_type = pole.entity_type, position = candidate,
          direction = defines.direction.north, tile_width = pole.tile_width or 1,
          tile_height = pole.tile_height or 1, bootstrap = true, pump_power = true}
        if add_row(rows, seen, row) then
          occupy(occupied, row)
          return candidate
        end
      end
    end
    return nil
  end
  table.sort(pump_rows, function(a, b)
    return distance(a.position, existing_pole.position) < distance(b.position, existing_pole.position)
  end)
  for _, pump_row in ipairs(pump_rows) do
    local service = place_pole_near(pump_row.position)
    if not service then return false, "no_safe_power_position_for_pump" end
    local best_anchor, best_distance = nil, nil
    for _, anchor in ipairs(anchors) do
      local candidate_distance = distance(anchor.position, service)
      if not best_distance or candidate_distance < best_distance then
        best_anchor, best_distance = anchor, candidate_distance
      end
    end
    if not best_anchor then return false, "no_power_anchor_for_pump" end
    local maximum_span = math.max(2, math.min(best_anchor.wire or wire, wire) * 0.72)
    local segments = math.max(1, math.ceil(best_distance / maximum_span))
    local previous = best_anchor.position
    for segment = 1, segments - 1 do
      local ratio = segment / segments
      local desired = {x = best_anchor.position.x + (service.x - best_anchor.position.x) * ratio,
        y = best_anchor.position.y + (service.y - best_anchor.position.y) * ratio}
      local relay = place_pole_near(desired)
      if not relay or distance(previous, relay) > wire * 0.95 then
        return false, "no_safe_relay_path_for_pump"
      end
      previous = relay
      anchors[#anchors + 1] = {position = relay, wire = wire}
    end
    if distance(previous, service) > wire * 0.95 then return false, "pump_power_wire_gap" end
    -- Only proven-connected poles become anchors for the next pump. Otherwise
    -- a later service pole could silently chain from an earlier orphan pole.
    anchors[#anchors + 1] = {position = service, wire = wire}
  end
  return true
end

local function item_buffer(recipe, machine_count)
  local result = {}
  for _, ingredient in ipairs(recipe.ingredients or {}) do
    if ingredient.type == "item" then
      result[#result + 1] = {name = ingredient.name,
        count = math.max(1, math.ceil(ingredient.amount * BUFFER_CRAFTS * machine_count))}
    end
  end
  return result
end

local function choose_tank_port(tank, position, desired_position)
  local best, best_distance = nil, nil
  for _, fluidbox in ipairs(tank.fluidboxes or {}) do
    for _, connection in ipairs(fluidbox.pipe_connections or {}) do
      if connection.connection_type == "normal" or connection.connection_type == nil then
        local local_position = connection.positions and connection.positions[1] or nil
        local vector = DIRECTION_VECTOR[connection.direction]
        if local_position and vector then
          local target = {x = position.x + local_position.x + vector.x,
            y = position.y + local_position.y + vector.y}
          local target_distance = desired_position and distance(target, desired_position) or 0
          if not best_distance or target_distance < best_distance then
            best, best_distance = target, target_distance
          end
        end
      end
    end
  end
  return best
end

local function layout_at(agent, recipe, target_item, target_type, existing_pole, choices, machine_count, x_sign, y_sign)
  local machine, inserter, chest, pole, pipe, tank = choices.machine, choices.inserter,
    choices.chest, choices.pole, choices.pipe, choices.tank
  local width, height = machine.tile_width or 3, machine.tile_height or 3
  local input_fluids = fluid_rows(recipe, "ingredient")
  local output_fluids = fluid_rows(recipe, "product")
  local has_item_products = false
  local has_item_ingredients = false
  for _, ingredient in ipairs(recipe.ingredients or {}) do
    if ingredient.type == "item" then has_item_ingredients = true; break end
  end
  for _, product in ipairs(recipe.products or {}) do
    if product.type == "item" then has_item_products = true; break end
  end
  -- Pack the machine row around its actual side services. Fluid products share
  -- one isolated tank/manifold per fluid below, so multi-output recipes no
  -- longer need a twelve-tile gap between every pair of machines.
  local side_service = (has_item_ingredients and 1 or 0) + (has_item_products and 1 or 0)
  local spacing = width + (side_service == 2 and 4 or (side_service == 1 and 2 or 1))
  local tank_spread = math.max(tank.tile_width or 3, tank.tile_height or 3) + 3
  if #output_fluids > 1 then
    -- Incompatible output manifolds may not cross. Keep one compact isolated
    -- tank cluster per machine and derive its width from the real tank size.
    spacing = math.max(spacing,
      (#output_fluids - 1) * tank_spread + (tank.tile_width or 3))
  end
  -- Leave a small approach from the proven grid, not a second empty factory
  -- block. Relay poles still bridge the real prototype wire distance.
  local site_offset = #output_fluids > 1
    and math.max(12, math.ceil(width / 2) + 6)
    or math.max(5, math.ceil(width / 2) + 3)
  local start = {x = snap_axis(existing_pole.position.x + x_sign * site_offset, width),
    y = snap_axis(existing_pole.position.y + y_sign * site_offset, height)}
  local rows, seen, occupied, reserved = {}, {}, {}, {}
  local machine_rows_built, output_rows, fluid_output_rows = {}, {}, {}
  local input_boxes, output_boxes = input_fluidboxes(machine), output_fluidboxes(machine)
  local item_contents = item_buffer(recipe, machine_count)
  local previous_pole = existing_pole

  for index = 0, machine_count - 1 do
    local machine_position = {x = start.x + x_sign * index * spacing, y = start.y}
    local machine_row = {name = machine.entity, entity_type = machine.entity_type,
      position = machine_position, direction = defines.direction.north, recipe = recipe.name,
      tile_width = width, tile_height = height,
      modules = choices.module and {{name = choices.module.name, count = choices.module.count,
        quality = "normal"}} or nil}
    add_row(rows, seen, machine_row); occupy(occupied, machine_row)
    machine_rows_built[#machine_rows_built + 1] = machine_row

    if #item_contents > 0 then
      local chest_position = {x = half_tile(machine_position.x - width / 2 - 1.5), y = half_tile(machine_position.y)}
      local inserter_position = {x = half_tile(chest_position.x + 1), y = half_tile(machine_position.y)}
      local chest_row = {name = chest.entity, entity_type = chest.entity_type, position = chest_position,
        direction = defines.direction.north, contents = item_contents, tile_width = 1, tile_height = 1}
      local inserter_row = {name = inserter.entity, entity_type = inserter.entity_type,
        position = inserter_position, direction = defines.direction.west, tile_width = 1, tile_height = 1}
      add_row(rows, seen, chest_row); occupy(occupied, chest_row)
      add_row(rows, seen, inserter_row); occupy(occupied, inserter_row)
    end

    if has_item_products then
      local output_position = {x = half_tile(machine_position.x + width / 2 + 1.5), y = half_tile(machine_position.y)}
      local output_inserter = {x = half_tile(output_position.x - 1), y = half_tile(machine_position.y)}
      local output_row = {name = chest.entity, entity_type = chest.entity_type, position = output_position,
        direction = defines.direction.north, tile_width = 1, tile_height = 1}
      local output_inserter_row = {name = inserter.entity, entity_type = inserter.entity_type,
        position = output_inserter, direction = defines.direction.west, tile_width = 1, tile_height = 1}
      add_row(rows, seen, output_inserter_row); occupy(occupied, output_inserter_row)
      add_row(rows, seen, output_row); occupy(occupied, output_row)
      output_rows[#output_rows + 1] = output_row
    end

    local pole_position = {x = half_tile(machine_position.x), y = half_tile(machine_position.y + height / 2 + 0.5)}
    local pole_row = {name = pole.entity, entity_type = pole.entity_type, position = pole_position,
      direction = defines.direction.north, tile_width = pole.tile_width or 1, tile_height = pole.tile_height or 1}
    local wire_limit = math.min(previous_pole.prototype.get_max_wire_distance(), pole.max_wire_distance or 0)
    local supply = pole.supply_area_distance or 0
    local supply_gap_x = math.max(0, math.abs(pole_position.x - machine_position.x) - width / 2)
    local supply_gap_y = math.max(0, math.abs(pole_position.y - machine_position.y) - height / 2)
    if wire_limit <= 0 or supply_gap_x > supply or supply_gap_y > supply then return nil end
    local wire_distance = distance(previous_pole.position, pole_position)
    local segments = math.max(1, math.ceil(wire_distance / (wire_limit * 0.90)))
    for segment = 1, segments - 1 do
      local ratio = segment / segments
      local relay_position = {
        x = half_tile(previous_pole.position.x + (pole_position.x - previous_pole.position.x) * ratio),
        y = half_tile(previous_pole.position.y + (pole_position.y - previous_pole.position.y) * ratio)
      }
      local relay = {name = pole.entity, entity_type = pole.entity_type, position = relay_position,
        direction = defines.direction.north, tile_width = pole.tile_width or 1, tile_height = pole.tile_height or 1}
      if collides_with_planned(rows, relay.name, relay.position)
          or not add_row(rows, seen, relay) then return nil end
      occupy(occupied, relay)
    end
    if collides_with_planned(rows, pole_row.name, pole_row.position)
        or not add_row(rows, seen, pole_row) then return nil end
    occupy(occupied, pole_row)
    previous_pole = {position = pole_position, prototype = prototypes.entity[pole.entity]}
  end

  local output_tank_ports = {}
  -- A single-output block shares one isolated tank/manifold for that product.
  -- Multi-output machines keep compact per-machine tank clusters because two
  -- incompatible drain manifolds may otherwise cross before they can merge.
  local output_lateral_sign = 1
  if #output_fluids > 1 then
    local first_box = fluidbox_for(output_boxes, output_fluids[1], 1)
    local second_box = fluidbox_for(output_boxes, output_fluids[2], 2)
    local first_vector, second_vector = connection_vector(first_box), connection_vector(second_box)
    local representative = machine_rows_built[1]
    local first_source = representative and connection_target(representative.position, first_box) or nil
    local second_source = representative and connection_target(representative.position, second_box) or nil
    if first_vector and second_vector and first_source and second_source
        and first_vector.x == second_vector.x and first_vector.y == second_vector.y then
      local lateral = {x = -first_vector.y, y = first_vector.x}
      local projection = (second_source.x - first_source.x) * lateral.x
        + (second_source.y - first_source.y) * lateral.y
      if projection < 0 then output_lateral_sign = -1 end
    end
  end
  local first_machine = machine_rows_built[1]
  local last_machine = machine_rows_built[#machine_rows_built]
  local block_center = {
    x = ((first_machine and first_machine.position.x or start.x)
      + (last_machine and last_machine.position.x or start.x)) / 2,
    y = ((first_machine and first_machine.position.y or start.y)
      + (last_machine and last_machine.position.y or start.y)) / 2
  }
  for output_index, product in ipairs(output_fluids) do
    local product_box = fluidbox_for(output_boxes, product, output_index)
    local first_connection = product_box and product_box.pipe_connections and product_box.pipe_connections[1] or nil
    local output_vector = first_connection and DIRECTION_VECTOR[first_connection.direction] or {x = 0, y = 1}
    local perpendicular = {x = -output_vector.y * output_lateral_sign,
      y = output_vector.x * output_lateral_sign}
    -- Two prototype-oriented service pipes leave each machine output before
    -- the shared manifold. Keep tank ports beyond that throat, otherwise a
    -- neighbouring product tank can claim the same cell as another output.
    local outward = height / 2 + (tank.tile_height or 3) / 2 + 5
    -- Storage-tank connection targets extend beyond the tile footprint. A
    -- one-tile service gap can make opposing ports coincide; two tiles keep
    -- different products physically distinct while the machine row stays dense.
    local spread = tank_spread
    local centered = (output_index - (#output_fluids + 1) / 2) * spread
    local anchors = {}
    if #output_fluids > 1 then
      output_tank_ports[output_index] = {}
      for machine_index, machine_row in ipairs(machine_rows_built) do
        anchors[#anchors + 1] = {position = machine_row.position, machine = machine_index,
          source_machine = machine_row}
      end
    else
      anchors[1] = {position = block_center, source_machine = first_machine}
    end
    for _, anchor in ipairs(anchors) do
      local tank_position = {
        x = snap_axis(anchor.position.x + output_vector.x * outward
          + perpendicular.x * centered, tank.tile_width),
        y = snap_axis(anchor.position.y + output_vector.y * outward
          + perpendicular.y * centered, tank.tile_height)
      }
      local tank_row = {name = tank.entity, entity_type = tank.entity_type, position = tank_position,
        direction = defines.direction.north, tile_width = tank.tile_width, tile_height = tank.tile_height,
        expected_fluid = product.name}
      if not add_row(rows, seen, tank_row) then return nil end
      occupy(occupied, tank_row)
      local representative_source = anchor.source_machine
        and connection_target(anchor.source_machine.position, product_box) or nil
      local port = choose_tank_port(tank, tank_position, representative_source)
      if not port then return nil end
      if anchor.machine then output_tank_ports[output_index][anchor.machine] = port
      else output_tank_ports[output_index] = port end
      fluid_output_rows[#fluid_output_rows + 1] = {row = tank_row, fluid = product.name,
        port = port, product = product, machine = anchor.machine}
    end
  end

  if not validate_non_pipe(agent.surface, agent.force, rows) then return nil end
  local area = {{start.x - SOURCE_RADIUS - 48, start.y - SOURCE_RADIUS - 48},
    {start.x + SOURCE_RADIUS + 48, start.y + SOURCE_RADIUS + 48}}
  local connections = PipeRouter.connection_map(agent.surface, agent.force, area)
  local endpoint_only = {}
  local route_context = {reserved = reserved, occupied = occupied, connections = connections,
    endpoint_only = endpoint_only,
    search_budget = choices.route_budget, placeability_cache = choices.pipe_placeability_cache}
  local source_evidence = {}
  local input_endpoints, input_route_destinations, input_service_rows = {}, {}, {}
  local output_endpoints, output_service_rows = {}, {}
  local input_source_uses = {}
  local input_segment_uses = {}
  local input_manifold_taps = {}
  local input_manifold_sources = {}
  local input_connected_segments = {}
  local planned_pump_rows = {}
  local next_route_id = 0

  local function reserve_transport(first_path, source, destination, fluid, required_flow, first_route_id,
      build_forward)
    local lanes, maximum, lane_error = transport_lanes(first_path, choices.pump, required_flow)
    if not lanes then return false, lane_error end
    local per_lane_flow = required_flow / lanes
    local path = first_path
    local all_taps = {}
    for lane = 1, lanes do
      local route_id = lane == 1 and first_route_id or (next_route_id + 1)
      if lane > 1 then
        route_context.active_route_id = route_id
        route_context.keep_route_gap = true
        route_context.separate_same_fluid_routes = true
        local route_error
        path, route_error = PipeRouter.route(agent.surface, agent.force, pipe.entity,
          source, destination, fluid, route_context)
        route_context.active_route_id = nil
        route_context.keep_route_gap = nil
        route_context.separate_same_fluid_routes = nil
        if not path then return false, "parallel_lane_unavailable:" .. tostring(route_error) end
      end
      local first_added = #rows + 1
      local taps, reserve_error, pumps = PipeRouter.reserve_path(rows, seen, reserved, path, pipe, fluid,
        route_id, choices.underground, route_context, {
          max_segment_tiles = maximum,
          pump_row = choices.pump,
          required_flow_per_second = per_lane_flow,
          surface = agent.surface,
          force = agent.force
      })
      if reserve_error then return false, reserve_error end
      for _, tap in ipairs(taps or {}) do all_taps[#all_taps + 1] = tap end
      for row_index = first_added, #rows do
        if rows[row_index].fluid_route_id == route_id then
          rows[row_index].fluid_route_build_forward = build_forward == true
        end
      end
      for _, pump_row in ipairs(pumps or {}) do planned_pump_rows[#planned_pump_rows + 1] = pump_row end
      next_route_id = route_id
    end
    return true, lanes, all_taps
  end

  local function reserve_endpoint(position, fluid, block_cell_only)
    local endpoint_key = PipeRouter.key(position)
    if reserved[endpoint_key] and reserved[endpoint_key] ~= fluid then
      return false, reserved[endpoint_key]
    end
    reserved[endpoint_key] = fluid
    if block_cell_only then endpoint_only[endpoint_key] = true else endpoint_only[endpoint_key] = nil end
    return true
  end

  -- Claim every recipe port before routing the first network. Otherwise A*
  -- could use another still-empty port as a shortcut and reserve it for the
  -- wrong fluid in a multi-input/multi-output modded recipe.
  local input_order = {}
  for input_index, ingredient in ipairs(input_fluids) do
    local nearest = fluid_sources(agent, ingredient, start)[1]
    input_order[#input_order + 1] = {index = input_index, ingredient = ingredient,
      score = nearest and nearest.score or math.huge}
  end
  table.sort(input_order, function(a, b)
    if a.score == b.score then return a.ingredient.name < b.ingredient.name end
    -- Build the compact inner manifold first. Long feeds now branch from one
    -- proven pumped trunk, so they can approach the completed block from the
    -- outside; drawing the long network first can instead fence the last port
    -- of a nearby fluid behind several machine branches.
    if choices.reverse_input_order then return a.score > b.score end
    return a.score < b.score
  end)
  for _, input_plan in ipairs(input_order) do
    local input_index, ingredient = input_plan.index, input_plan.ingredient
    local box = fluidbox_for(input_boxes, ingredient, input_index)
    if not box then return nil end
    local outward = connection_vector(box)
    if not outward then return nil, "fluid_input_direction_unavailable:" .. ingredient.name end
    input_endpoints[input_index] = {}
    input_route_destinations[input_index] = {}
    input_service_rows[input_index] = {}
    for machine_index, machine_row in ipairs(machine_rows_built) do
      local destination = connection_target(machine_row.position, box)
      if not destination or not reserve_endpoint(destination, ingredient.name) then
        return nil, "fluid_input_port_conflict:" .. ingredient.name
      end
      -- Preserve a two-cell service throat in front of every machine port.
      -- Adjacent fluidboxes can otherwise be individually valid yet the first
      -- routed fluid may surround the only approach to the second one.
      local service_rows = {}
      for step = 1, 2 do
        local throat = {x = destination.x + outward.x * step,
          y = destination.y + outward.y * step}
        if not reserve_endpoint(throat, ingredient.name) then
          return nil, "fluid_input_service_throat_conflict:" .. ingredient.name
        end
        service_rows[#service_rows + 1] = throat
      end
      input_endpoints[input_index][machine_index] = destination
      input_route_destinations[input_index][machine_index] = service_rows[#service_rows]
      input_service_rows[input_index][machine_index] = {service_rows[1], destination}
    end
  end
  for output_index, product in ipairs(output_fluids) do
    local box = fluidbox_for(output_boxes, product, output_index)
    if not box then return nil end
    output_endpoints[output_index] = {}
    output_service_rows[output_index] = {}
    local outward = connection_vector(box)
    if not outward then return nil, "fluid_output_direction_unavailable:" .. product.name end
    for machine_index, machine_row in ipairs(machine_rows_built) do
      local source = connection_target(machine_row.position, box)
      local tank_row_index = #output_fluids > 1
        and ((output_index - 1) * #machine_rows_built + machine_index) or output_index
      local tank_row = fluid_output_rows[tank_row_index]
      tank_row = tank_row and tank_row.row or nil
      local tank_port = #output_fluids > 1
        and output_tank_ports[output_index][machine_index] or output_tank_ports[output_index]
      if not tank_row or not tank_port then return nil end
      -- A storage tank exposes several open ports. Reserving only the selected
      -- one lets a later, unrelated route touch another side and silently mix
      -- fluids. Claim every runtime prototype port before any route is built.
      local selected_port_key = PipeRouter.key(tank_port)
      for _, open_port in ipairs(connection_targets(tank_row.position, tank.fluidboxes)) do
        local reserved_ok, conflicting_fluid = reserve_endpoint(open_port, product.name,
          PipeRouter.key(open_port) ~= selected_port_key)
        if not reserved_ok then
          return nil, "fluid_tank_open_port_conflict:" .. product.name .. ":with="
            .. tostring(conflicting_fluid) .. ":at="
            .. string.format("%.1f,%.1f", open_port.x, open_port.y)
        end
      end
      if not reserve_endpoint(tank_port, product.name) then
        return nil, "fluid_tank_port_conflict:" .. product.name
      end
      if not source or not reserve_endpoint(source, product.name) then
        return nil, "fluid_output_port_conflict:" .. product.name
      end
      -- Claim a short straight drain throat before any input is routed. A
      -- nearby water/oil manifold may otherwise be valid on its own yet fence
      -- a modded machine's output port behind a different fluid.
      local service_rows = {}
      for step = 1, 2 do
        local throat = {x = source.x + outward.x * step, y = source.y + outward.y * step}
        if not reserve_endpoint(throat, product.name) then
          return nil, "fluid_output_service_throat_conflict:" .. product.name
        end
        service_rows[#service_rows + 1] = throat
      end
      output_endpoints[output_index][machine_index] = service_rows[#service_rows]
      output_service_rows[output_index][machine_index] = {source, service_rows[1]}
    end
  end

  -- Multi-output machines route their short isolated drains before the long
  -- input manifolds. A single-output block keeps the proven input-first order,
  -- which leaves a walkable construction approach for long dedicated feeds.
  local function route_outputs()
    for output_index, product in ipairs(output_fluids) do
    local box = fluidbox_for(output_boxes, product, output_index)
    if not box then return nil end
      for machine_index, _ in ipairs(machine_rows_built) do
        local source = output_endpoints[output_index][machine_index]
        local destination = #output_fluids > 1
          and output_tank_ports[output_index][machine_index] or output_tank_ports[output_index]
        local candidate_route_id = next_route_id + 1
        route_context.active_route_id = candidate_route_id
        local path, err = PipeRouter.route(agent.surface, agent.force, pipe.entity,
          source, destination, product.name, route_context)
        route_context.active_route_id = nil
        if not path then
          return nil, "fluid_output_route_unavailable:" .. product.name .. ":machine="
            .. tostring(machine_index) .. ":" .. tostring(err)
        end
        local required_flow = fluid_rate_per_second(recipe, machine, choices.module, product, true)
        local reserved_ok, transport_result = reserve_transport(path, source, destination,
          product.name, required_flow, candidate_route_id, false)
        if not reserved_ok then
          return nil, "fluid_output_transport_unavailable:" .. product.name .. ":machine="
            .. tostring(machine_index) .. ":" .. tostring(transport_result)
        end
        -- The routed path starts at the outer throat cell. Add the two inner
        -- cells with earlier steps so reverse construction proceeds tank ->
        -- machine and leaves a physically continuous prototype-oriented drain.
        for service_index, service_position in ipairs(output_service_rows[output_index][machine_index]) do
          local service_key = PipeRouter.key(service_position)
          if not seen[service_key] then
            seen[service_key] = true
            route_context.route_cells = route_context.route_cells or {}
            route_context.route_cells[service_key] = candidate_route_id
            rows[#rows + 1] = {name = pipe.entity, entity_type = pipe.entity_type,
              position = {x = service_position.x, y = service_position.y},
              direction = defines.direction.north, bootstrap = true,
              fluid_route = product.name, fluid_route_id = candidate_route_id,
              fluid_route_step = service_index - 2, fluid_route_build_forward = false,
              tile_width = pipe.tile_width, tile_height = pipe.tile_height}
          end
        end
      end
    end
    return true
  end
  if #output_fluids > 1 then
    local outputs_ok, outputs_error = route_outputs()
    if not outputs_ok then return nil, outputs_error end
  end

  for _, input_plan in ipairs(input_order) do
    local input_index, ingredient = input_plan.index, input_plan.ingredient
    local box = fluidbox_for(input_boxes, ingredient, input_index)
    if not box then return nil end
    input_source_uses[input_index] = input_source_uses[input_index] or {}
    input_segment_uses[input_index] = input_segment_uses[input_index] or {}
    input_manifold_taps[input_index] = input_manifold_taps[input_index] or {}
    input_connected_segments[input_index] = input_connected_segments[input_index] or {}
    -- Prefer one independently routed connection per machine whenever the live
    -- network exposes enough safe ports. This prevents the closest branch from
    -- repeatedly winning a common manifold. A shared trunk remains the bounded
    -- fallback for sources that physically expose fewer ports than consumers.
    local initial_sources = fluid_sources(agent, ingredient, machine_rows_built[1].position)
    local shared_manifold = #initial_sources < machine_count
    for machine_index, machine_row in ipairs(machine_rows_built) do
      local destination = input_route_destinations[input_index][machine_index]
      local routed, route_error = false, nil
      local fatal_transport_error = nil
      local sources = fluid_sources(agent, ingredient, machine_row.position)
      table.sort(sources, function(a, b)
        local segment_uses = input_segment_uses[input_index]
        local a_uses = segment_uses[a.segment_key] or 0
        local b_uses = segment_uses[b.segment_key] or 0
        if a_uses ~= b_uses then return a_uses < b_uses end
        local a_position_uses = input_source_uses[input_index][PipeRouter.key(a.position)] or 0
        local b_position_uses = input_source_uses[input_index][PipeRouter.key(b.position)] or 0
        if a_position_uses ~= b_position_uses then return a_position_uses < b_position_uses end
        if a.score ~= b.score then return a.score < b.score end
        if a.position.y ~= b.position.y then return a.position.y < b.position.y end
        return a.position.x < b.position.x
      end)

      local function remember_taps(taps)
        local manifold = input_manifold_taps[input_index]
        local known = {}
        for _, tap in ipairs(manifold) do known[PipeRouter.key(tap)] = true end
        for _, tap in ipairs(taps or {}) do
          local tap_key = PipeRouter.key(tap)
          if not known[tap_key] and #manifold < 512 then
            known[tap_key] = true
            manifold[#manifold + 1] = tap
          end
        end
      end

      local function try_source(source, start_positions)
        local candidate_route_id = next_route_id + 1
        route_context.active_route_id = candidate_route_id
        route_context.start_positions = start_positions
        if not shared_manifold then
          route_context.keep_route_gap = true
          route_context.separate_same_fluid_routes = true
        end
        local path, err = PipeRouter.route(agent.surface, agent.force, pipe.entity,
          source.position, destination, ingredient.name, route_context)
        route_context.start_positions = nil
        route_context.active_route_id = nil
        route_context.keep_route_gap = nil
        route_context.separate_same_fluid_routes = nil
        if path then
          local required_flow = fluid_rate_per_second(recipe, machine, choices.module, ingredient, false)
          local reserved_ok, transport_result, taps = reserve_transport(path, path[1], destination,
            ingredient.name, required_flow, candidate_route_id, true)
          if not reserved_ok then
            fatal_transport_error = "fluid_input_transport_unavailable:" .. ingredient.name .. ":machine="
              .. tostring(machine_index) .. ":" .. tostring(transport_result)
          else
            -- Finish the reserved service throat explicitly. The A* route ends
            -- at its outer cell; these final cells are the deterministic,
            -- prototype-oriented connection into the machine fluidbox.
            local service_step = #path
            for service_index, service_position in ipairs(input_service_rows[input_index][machine_index]) do
              local service_key = PipeRouter.key(service_position)
              if not seen[service_key] then
                seen[service_key] = true
                route_context.route_cells = route_context.route_cells or {}
                route_context.route_cells[service_key] = candidate_route_id
                rows[#rows + 1] = {name = pipe.entity, entity_type = pipe.entity_type,
                  position = {x = service_position.x, y = service_position.y},
                  direction = defines.direction.north, bootstrap = true,
                  fluid_route = ingredient.name, fluid_route_id = candidate_route_id,
                  fluid_route_step = service_step + service_index,
                  fluid_route_build_forward = true,
                  tile_width = pipe.tile_width, tile_height = pipe.tile_height}
              end
            end
            local source_key = PipeRouter.key(source.position)
            input_source_uses[input_index][source_key] = (input_source_uses[input_index][source_key] or 0) + 1
            if source.segment_key then
              input_segment_uses[input_index][source.segment_key]
                = (input_segment_uses[input_index][source.segment_key] or 0) + 1
            end
            remember_taps(taps)
            source_evidence[#source_evidence + 1] = {fluid = ingredient.name,
              source_unit_number = source.unit_number,
              source_position = path[1],
              upstream_source_position = source.upstream_source_position,
              source_amount = source.fluid and source.fluid.amount or 0,
              manifold_tap = source.manifold_tap == true,
              source_connection_use = input_source_uses[input_index][source_key],
              dedicated_segment = not shared_manifold,
              machine = machine_index}
            if shared_manifold then
              input_manifold_sources[input_index] = input_manifold_sources[input_index] or source
            end
            if not source.manifold_tap and source.segment_key then
              input_connected_segments[input_index][source.segment_key] = source.fluid and source.fluid.amount or 0
            end
            routed = true
          end
        else
          route_error = err
        end
      end

      -- Only the first consumer needs a long source route and pump chain.
      -- Later consumers branch from the nearest ordinary pipe tap of that
      -- proven manifold, avoiding redundant pumps that can isolate parallel
      -- branches in Factorio's directional fluid system.
      local manifold = input_manifold_taps[input_index]
      local upstream = input_manifold_sources[input_index]
      if shared_manifold and #manifold > 0 and upstream then
        try_source({position = manifold[1], unit_number = upstream.unit_number,
          fluid = upstream.fluid, upstream_source_position = upstream.position,
          manifold_tap = true}, manifold)
        if fatal_transport_error then return nil, fatal_transport_error end
      else
        for source_index = 1, math.min(#sources, MAX_EXTERNAL_SOURCE_ROUTE_ATTEMPTS) do
          local source = sources[source_index]
          try_source(source, nil)
          if fatal_transport_error then return nil, fatal_transport_error end
          if routed then break end
        end
      end
      if not routed then
        return nil, "fluid_source_or_route_unavailable:" .. ingredient.name .. ":input=" .. tostring(input_index)
          .. ":box=" .. tostring(box.index) .. ":machine=" .. tostring(machine_index)
          .. ":destination=" .. string.format("%.1f,%.1f", destination.x, destination.y)
          .. ":sources=" .. tostring(#sources) .. ":" .. tostring(route_error)
      end
    end

    -- A forced shared manifold still needs enough independent upstream
    -- inventory. Attach extra segments until their live stock covers the
    -- construction buffer, or until one segment per machine is present.
    local connected = input_connected_segments[input_index]
    local connected_amount, connected_count = 0, 0
    for _, amount in pairs(connected) do
      connected_amount = connected_amount + amount
      connected_count = connected_count + 1
    end
    local desired_amount = math.max(1, ingredient.amount * BUFFER_CRAFTS * machine_count)
    if shared_manifold and connected_amount < desired_amount and connected_count < machine_count then
      local candidates = fluid_sources(agent, ingredient, machine_rows_built[1].position)
      local examined_segments = {}
      for _, source in ipairs(candidates) do
        local segment_key = source.segment_key or PipeRouter.key(source.position)
        if not examined_segments[segment_key] and not connected[segment_key]
            and connected_amount < desired_amount and connected_count < machine_count then
          examined_segments[segment_key] = true
          local manifold = input_manifold_taps[input_index]
          local destination = nil
          local best_distance = nil
          for _, tap in ipairs(manifold) do
            local candidate_distance = distance(source.position, tap)
            if not best_distance or candidate_distance < best_distance then
              destination, best_distance = tap, candidate_distance
            end
          end
          if destination then
            local candidate_route_id = next_route_id + 1
            route_context.active_route_id = candidate_route_id
            local path = PipeRouter.route(agent.surface, agent.force, pipe.entity,
              source.position, destination, ingredient.name, route_context)
            route_context.active_route_id = nil
            if path then
              local required_flow = fluid_rate_per_second(recipe, machine, choices.module, ingredient, false)
              local reserved_ok, transport_result, taps = reserve_transport(path, source.position, destination,
                ingredient.name, required_flow, candidate_route_id, true)
              if not reserved_ok then
                return nil, "fluid_manifold_source_transport_unavailable:" .. ingredient.name
                  .. ":" .. tostring(transport_result)
              end
              local known = {}
              for _, tap in ipairs(manifold) do known[PipeRouter.key(tap)] = true end
              for _, tap in ipairs(taps or {}) do
                local tap_key = PipeRouter.key(tap)
                if not known[tap_key] and #manifold < 512 then
                  known[tap_key] = true
                  manifold[#manifold + 1] = tap
                end
              end
              local amount = source.fluid and source.fluid.amount or 0
              connected[segment_key] = amount
              connected_amount = connected_amount + amount
              connected_count = connected_count + 1
              source_evidence[#source_evidence + 1] = {fluid = ingredient.name,
                source_unit_number = source.unit_number, source_position = source.position,
                source_amount = amount, manifold_supply = true}
            end
          end
        end
      end
    end
  end

  if #output_fluids <= 1 then
    local outputs_ok, outputs_error = route_outputs()
    if not outputs_ok then return nil, outputs_error end
  end

  local power_ok, power_error = add_pump_power(agent, rows, seen, occupied,
    planned_pump_rows, pole, existing_pole)
  if not power_ok then return nil, "fluid_pump_power_unavailable:" .. tostring(power_error) end

  if not validate_non_pipe(agent.surface, agent.force, rows) then return nil end
  return {
    bootstrap = true,
    assembly_bootstrap = true,
    fluid_bootstrap = true,
    recipe = recipe.name,
    input_item = table.concat((function()
      local names = {}; for _, ingredient in ipairs(recipe.ingredients) do names[#names + 1] = ingredient.name end
      return names
    end)(), "+"),
    input_items = (function()
      local names = {}
      for _, ingredient in ipairs(recipe.ingredients) do
        if ingredient.type == "item" then names[#names + 1] = ingredient.name end
      end
      return names
    end)(),
    target_item = target_item,
    target_type = target_type,
    target_fluid = target_type == "fluid" and target_item or nil,
    entities = rows,
    producer_target = machine_rows_built[1],
    producer_rows = machine_rows_built,
    output_row = output_rows[1],
    output_rows = output_rows,
    fluid_output_rows = fluid_output_rows,
    fluid_sources = source_evidence,
    approach_position = start,
    source_position = {x = existing_pole.position.x, y = existing_pole.position.y},
    remote = false,
    drill_count = 0,
    machine_count = machine_count,
    pipe_count = (function() local n = 0; for _ in pairs(reserved) do n = n + 1 end; return n end)(),
    continuous = false,
    module = choices.module and choices.module.name or nil,
    module_count = choices.module and choices.module.count * machine_count or 0,
    pump_count = #planned_pump_rows,
    pipeline_extent_limit = pipeline_extent_limit()
  }
end

local function resource_entities_for_fluid(agent, fluid_name)
  local seed = PrototypeIndex.find_resource(agent, fluid_name, "autonomous", 768, true, nil, true)
  if not seed or seed.type ~= "resource" then return {}, nil end
  local result = agent.surface.find_entities_filtered({
    position = seed.position,
    radius = 96,
    type = "resource",
    name = seed.name,
    limit = 256
  })
  local filtered = {}
  for _, resource in ipairs(result) do
    if resource.valid and (resource.amount or 0) > 0
        and not Conflict.is_blocked(resource.surface.index, resource.position, "autonomous") then
      for _, product in ipairs(resource.prototype.mineable_properties.products or {}) do
        if product.type == "fluid" and product.name == fluid_name then
          filtered[#filtered + 1] = resource
          break
        end
      end
    end
  end
  table.sort(filtered, function(a, b)
    local ad = distance(a.position, agent.position)
    local bd = distance(b.position, agent.position)
    if ad == bd then return (a.unit_number or 0) < (b.unit_number or 0) end
    return ad < bd
  end)
  return filtered, seed
end

local function natural_source_plan(player, agent, fluid_name, options)
  local resources, seed = resource_entities_for_fluid(agent, fluid_name)
  if #resources == 0 then return nil, "natural_fluid_resource_not_found:" .. fluid_name end
  local high_throughput = options and options.high_throughput == true
  local desired_count = math.min(#resources,
    high_throughput and HIGH_THROUGHPUT_MACHINE_COUNT or DEFAULT_MACHINE_COUNT)
  local center = seed.position
  local existing_poles = powered_poles(agent, nil, center)
  local drill_rows = PrototypeIndex.entities_for_type("mining-drill") or {}
  local drill_choice, drill_count, drill_error = nil, nil, nil
  for count = desired_count, 1, -1 do
    local choice, err = placement_choice(agent, drill_rows, count, function(row)
      if not row.resource_categories
          or not row.resource_categories[seed.prototype.resource_category] then return false end
      local output = output_fluidboxes(row)[1]
      if not output or (output.filter and output.filter ~= fluid_name) then return false end
      return row.burner_categories ~= nil or (row.electric and #existing_poles > 0)
    end, function(row)
      return -math.min(10000, math.floor((row.mining_speed or 0) * 2500
        + (row.module_inventory_size or 0) * 200))
    end)
    if choice then drill_choice, drill_count = choice, count; break end
    drill_error = err or drill_error
  end
  if not drill_choice then return nil, "natural_fluid_drill_unobtainable:" .. tostring(drill_error) end

  local tank, tank_error = placement_choice(agent, PrototypeIndex.entities_for_type("storage-tank"), drill_count,
    function(row) return #(row.fluidboxes or {}) > 0 end,
    function(row) return -math.min(3000, math.floor(((row.fluidboxes or {})[1]
      and (row.fluidboxes or {})[1].volume or 0) / 10)) end)
  local pipe, pipe_error = placement_choice(agent, PrototypeIndex.entities_for_type("pipe"), 192,
    function(row) return (row.tile_width or 1) == 1 and (row.tile_height or 1) == 1 end)
  local underground = placement_choice(agent, PrototypeIndex.entities_for_type("pipe-to-ground"), 32,
    function(row) return #(row.fluidboxes or {}) > 0 end)
  local pole, pole_error = nil, nil
  if drill_choice.row.electric then
    pole, pole_error = placement_choice(agent, PrototypeIndex.entities_for_type("electric-pole"), drill_count * 4,
      function(row) return (row.tile_width or 1) == 1 and (row.tile_height or 1) == 1 end,
      function(row) return -math.min(3000, math.floor((row.supply_area_distance or 0) * 300
        + (row.max_wire_distance or 0) * 40)) end)
  end
  if not tank or not pipe or (drill_choice.row.electric and not pole) then
    return nil, "natural_fluid_components_unobtainable:" .. table.concat({
      tostring(tank_error), tostring(pipe_error), tostring(pole_error)}, "|")
  end

  local fuel_name = nil
  if drill_choice.row.burner_categories then
    fuel_name = obtainable_fuel(agent, drill_choice.row.burner_categories, drill_count * 10)
    if not fuel_name then return nil, "natural_fluid_fuel_unobtainable" end
  end

  local rows, seen, occupied, reserved = {}, {}, {}, {}
  local producer_rows, fluid_output_rows, powered_consumers = {}, {}, {}
  local route_context = {reserved = reserved, occupied = occupied, connections = {}}
  local source_evidence = {}
  local route_id = 0
  local selected = 0
  for _, resource in ipairs(resources) do
    if selected >= drill_count then break end
    local position = {
      x = snap_axis(resource.position.x, drill_choice.row.tile_width),
      y = snap_axis(resource.position.y, drill_choice.row.tile_height)
    }
    local drill_row = {name = drill_choice.row.entity, entity_type = "mining-drill",
      position = position, direction = defines.direction.north,
      tile_width = drill_choice.row.tile_width, tile_height = drill_choice.row.tile_height,
      fuel = fuel_name and {name = fuel_name, count = 10} or nil}
    local output_box = output_fluidboxes(drill_choice.row)[1]
    local source = connection_target(position, output_box)
    if source and footprint_available(occupied, drill_row)
        and SitePolicy.can_plan(agent.surface, agent.force, drill_row.name, position, drill_row.direction) then
      local tank_row = nil
      local spans = {8, 12, 16, 20}
      local vectors = {{x = 1, y = 0}, {x = -1, y = 0}, {x = 0, y = 1}, {x = 0, y = -1}}
      for _, span in ipairs(spans) do
        for _, vector in ipairs(vectors) do
          local candidate = {name = tank.row.entity, entity_type = "storage-tank",
            position = {
              x = snap_axis(position.x + vector.x * span, tank.row.tile_width),
              y = snap_axis(position.y + vector.y * span, tank.row.tile_height)
            },
            direction = defines.direction.north, tile_width = tank.row.tile_width,
            tile_height = tank.row.tile_height, expected_fluid = fluid_name}
          if footprint_available(occupied, candidate)
              and not Conflict.is_blocked(agent.surface.index, candidate.position, "autonomous")
              and SitePolicy.can_plan(agent.surface, agent.force, candidate.name,
                candidate.position, candidate.direction) then
            tank_row = candidate
            break
          end
        end
        if tank_row then break end
      end
      if tank_row then
        add_row(rows, seen, drill_row); occupy(occupied, drill_row)
        add_row(rows, seen, tank_row); occupy(occupied, tank_row)
        local destination = choose_tank_port(tank.row, tank_row.position, source)
        if destination then
          for _, port in ipairs(connection_targets(tank_row.position, tank.row.fluidboxes)) do
            reserved[PipeRouter.key(port)] = fluid_name
          end
          reserved[PipeRouter.key(source)] = fluid_name
          reserved[PipeRouter.key(destination)] = fluid_name
          route_context.connections = PipeRouter.connection_map(agent.surface, agent.force, {
            {math.min(source.x, destination.x) - 24, math.min(source.y, destination.y) - 24},
            {math.max(source.x, destination.x) + 24, math.max(source.y, destination.y) + 24}
          })
          route_id = route_id + 1
          route_context.active_route_id = route_id
          local path, route_error = PipeRouter.route(agent.surface, agent.force, pipe.row.entity,
            source, destination, fluid_name, route_context)
          route_context.active_route_id = nil
          if not path then return nil, "natural_fluid_route_unavailable:" .. tostring(route_error) end
          local _, reserve_error = PipeRouter.reserve_path(rows, seen, reserved, path, pipe.row,
            fluid_name, route_id, underground and underground.row or nil, route_context)
          if reserve_error then return nil, "natural_fluid_route_reserve_failed:" .. tostring(reserve_error) end
          selected = selected + 1
          producer_rows[#producer_rows + 1] = drill_row
          fluid_output_rows[#fluid_output_rows + 1] = {row = tank_row, fluid = fluid_name,
            port = destination, source_resource = resource.name}
          source_evidence[#source_evidence + 1] = {fluid = fluid_name,
            natural_resource = resource.name, resource_position = resource.position,
            source_position = source, tank_position = tank_row.position}
          if drill_choice.row.electric then powered_consumers[#powered_consumers + 1] = drill_row end
        end
      end
    end
  end
  if selected == 0 then return nil, "natural_fluid_no_safe_well_site" end
  if drill_choice.row.electric then
    local power_ok, power_error = add_pump_power(agent, rows, seen, occupied,
      powered_consumers, pole.row, existing_poles[1])
    if not power_ok then return nil, "natural_fluid_power_unavailable:" .. tostring(power_error) end
  end
  if not validate_non_pipe(agent.surface, agent.force, rows) then
    return nil, "natural_fluid_layout_invalidated"
  end
  local pipe_count = 0
  for _, row in ipairs(rows) do
    if row.entity_type == "pipe" or row.entity_type == "pipe-to-ground" then pipe_count = pipe_count + 1 end
  end
  return {
    bootstrap = true,
    fluid_bootstrap = true,
    fluid_source_bootstrap = true,
    target_item = fluid_name,
    target_type = "fluid",
    target_fluid = fluid_name,
    input_item = fluid_name,
    input_items = {},
    entities = rows,
    producer_target = producer_rows[1],
    producer_rows = producer_rows,
    output_rows = {},
    fluid_output_rows = fluid_output_rows,
    fluid_sources = source_evidence,
    approach_position = producer_rows[1].position,
    source_position = existing_poles[1] and existing_poles[1].position or producer_rows[1].position,
    remote = false,
    drill_count = selected,
    machine_count = 0,
    pipe_count = pipe_count,
    continuous = true,
    natural_fluid_source = true
  }
end

function FluidPlanner.plan(player, agent, target_item, marker, options)
  if not PrototypeIndex.is_ready() or not RecipeIndex.is_ready() then return nil, "indexes_not_ready" end
  local target_type = options and options.target_type
    or (prototypes.item[target_item] and "item" or (prototypes.fluid[target_item] and "fluid" or nil))
  if not target_type then return nil, "unknown_fluid_plan_target" end
  local recipe = recipe_choice(player, target_item, target_type)
  if not recipe then return nil, "no_enabled_fluid_recipe" end
  -- Dependency discovery must not depend on which pipe happens to be routed
  -- first. Probe every fluid ingredient before doing any geometric work; the
  -- autonomy stack can then build a missing processed or natural fluid and
  -- return to this exact recipe afterwards.
  local source_probe = marker and marker.position or agent.position
  for input_index, ingredient in ipairs(fluid_rows(recipe, "ingredient")) do
    if #fluid_sources(agent, ingredient, source_probe) == 0 then
      return nil, "fluid_source_or_route_unavailable:" .. ingredient.name
        .. ":input=" .. tostring(input_index) .. ":sources=0:fluid_source_preflight"
    end
  end
  local high_throughput = (options and options.high_throughput) or (marker and marker.high_throughput) or false
  local machine_count = high_throughput and HIGH_THROUGHPUT_MACHINE_COUNT or DEFAULT_MACHINE_COUNT
  local machine, machine_error = placement_choice(agent, machine_rows(recipe), machine_count,
    function(row) return row.electric == true and has_ports(row, recipe) end,
    function(row) return -math.min(10000, math.floor((row.crafting_speed or 0) * 1500
      + (row.module_inventory_size or 0) * 250)) end)
  local pipe, pipe_error = placement_choice(agent, PrototypeIndex.entities_for_type("pipe"), 256,
    function(row) return (row.tile_width or 1) == 1 and (row.tile_height or 1) == 1 end)
  local underground = placement_choice(agent, PrototypeIndex.entities_for_type("pipe-to-ground"), 64,
    function(row)
      for _, fluidbox in ipairs(row.fluidboxes or {}) do
        for _, connection in ipairs(fluidbox.pipe_connections or {}) do
          if connection.connection_type == "underground"
              and (connection.max_underground_distance or 0) >= 3 then return true end
        end
      end
      return false
    end,
    function(row)
      local maximum = 0
      for _, fluidbox in ipairs(row.fluidboxes or {}) do
        for _, connection in ipairs(fluidbox.pipe_connections or {}) do
          maximum = math.max(maximum, connection.max_underground_distance or 0)
        end
      end
      return -math.min(3000, maximum * 200)
    end)
  local pump = placement_choice(agent, PrototypeIndex.entities_for_type("pump"), 1,
    function(row)
      return (row.pumping_speed or 0) > 0 and #(row.fluidboxes or {}) > 0
        and (row.tile_width or 1) <= 2 and (row.tile_height or 1) <= 2
    end,
    function(row) return -math.min(10000, math.floor((row.pumping_speed or 0) * 500)) end)
  local tanks_needed = #fluid_rows(recipe, "product") * machine_count
  local tank, tank_error = nil, nil
  if tanks_needed > 0 then
    tank, tank_error = placement_choice(agent, PrototypeIndex.entities_for_type("storage-tank"), tanks_needed,
      function(row) return #(row.fluidboxes or {}) > 0 end,
      function(row) return -math.min(2000, math.floor(((row.fluidboxes or {})[1]
        and (row.fluidboxes or {})[1].volume or 0) / 10)) end)
  end
  local needs_item_io = false
  for _, ingredient in ipairs(recipe.ingredients or {}) do
    if ingredient.type == "item" then needs_item_io = true; break end
  end
  if not needs_item_io then
    for _, product in ipairs(recipe.products or {}) do
      if product.type == "item" then needs_item_io = true; break end
    end
  end
  local inserter, inserter_error, chest, chest_error = nil, nil, nil, nil
  if needs_item_io then
    inserter, inserter_error = placement_choice(agent, PrototypeIndex.entities_for_type("inserter"),
      machine_count * 2, function(row) return not row.burner_categories end,
      function(row) return -math.min(3000, math.floor((row.inserter_rotation_speed or 0) * 12000)) end)
    chest, chest_error = placement_choice(agent, container_rows(), machine_count * 2,
      function(row) return (row.tile_width or 1) == 1 and (row.tile_height or 1) == 1 end)
  end
  local pole, pole_error = placement_choice(agent, PrototypeIndex.entities_for_type("electric-pole"), machine_count * 3,
    function(row) return (row.tile_width or 1) == 1 and (row.tile_height or 1) == 1 end,
    function(row) return -math.min(3000, math.floor((row.supply_area_distance or 0) * 300
      + (row.max_wire_distance or 0) * 40)) end)
  if not machine or not pipe or (tanks_needed > 0 and not tank)
      or (needs_item_io and (not inserter or not chest)) or not pole then
    return nil, "fluid_components_not_obtainable:recipe=" .. recipe.name
      .. ":machine=" .. tostring(machine ~= nil)
      .. ":pipe=" .. tostring(pipe ~= nil)
      .. ":tank=" .. tostring(tank ~= nil)
      .. ":item_io=" .. tostring(needs_item_io)
      .. ":inserter=" .. tostring(inserter ~= nil)
      .. ":chest=" .. tostring(chest ~= nil)
      .. ":pole=" .. tostring(pole ~= nil)
      .. ":errors=" .. table.concat({tostring(machine_error), tostring(pipe_error),
        tostring(tank_error), tostring(inserter_error), tostring(chest_error), tostring(pole_error)}, "|")
  end
  for _, ingredient in ipairs(recipe.ingredients or {}) do
    if ingredient.type == "item" then
      local plan, err = Acquisition.make_plan(agent, ingredient.name,
        math.max(1, math.ceil(ingredient.amount * BUFFER_CRAFTS * machine_count)), "autonomous")
      if not plan then return nil, "fluid_item_input_unavailable:" .. ingredient.name .. ":" .. tostring(err) end
    end
  end
  local module = ModulePolicy.choose(agent, machine.row, recipe, high_throughput, machine_count)
  local choices = {machine = machine.row, pipe = pipe.row, tank = tank and tank.row or nil,
    inserter = inserter and inserter.row or nil, chest = chest and chest.row or nil,
    pole = pole.row, underground = underground and underground.row or nil,
    pump = pump and pump.row or nil, module = module,
    -- All route attempts for one planner decision share a hard budget. This
    -- prevents a dense or impossible modded site from monopolising a Factorio
    -- update while still allowing a complete multi-fluid block on open ground.
    route_budget = {remaining = 120000}, pipe_placeability_cache = {}}
  local last_layout_error = nil
  local site_poles = powered_poles(agent, marker)
  local site_scores = {}
  for pole_index = 1, math.min(#site_poles, MAX_SCORED_SITE_POLES) do
    local existing_pole = site_poles[pole_index]
    local score = distance(existing_pole.position, agent.position) * 0.02
    for _, ingredient in ipairs(fluid_rows(recipe, "ingredient")) do
      local source = fluid_sources(agent, ingredient, existing_pole.position)[1]
      if not source then
        score = math.huge
        break
      end
      -- Keep the block close to a scarce/processed feed and transport the
      -- abundant bulk fluid farther. This avoids spending the only small
      -- petroleum buffer on a long priming pipeline while still allowing a
      -- large water/crude reservoir to use the pump backbone.
      local source_amount = source.fluid and source.fluid.amount or 0
      local scarcity_weight = 1 + math.min(4, 1000 / math.max(1, source_amount))
      score = score + distance(existing_pole.position, source.position) * scarcity_weight
    end
    -- A pole beside the right fluid can still sit inside a dense manifold.
    -- Penalise actual force-owned congestion so the small layout-attempt
    -- budget favours buildable ground instead of repeatedly testing the same
    -- crowded refinery edge.
    local congestion = 0
    for _, entity in ipairs(agent.surface.find_entities_filtered({
        position = existing_pole.position, radius = 20, force = agent.force, limit = 192})) do
      if entity.valid and entity.type ~= "electric-pole" and entity.type ~= "character" then
        congestion = congestion + 1
      end
    end
    score = score + congestion
    site_scores[existing_pole.unit_number] = score
  end
  table.sort(site_poles, function(a, b)
    local as = site_scores[a.unit_number] or math.huge
    local bs = site_scores[b.unit_number] or math.huge
    if as == bs then return (a.unit_number or 0) < (b.unit_number or 0) end
    return as < bs
  end)
  local layout_poles = {}
  for _, candidate in ipairs(site_poles) do
    local separated = true
    for _, selected in ipairs(layout_poles) do
      if distance(candidate.position, selected.position) < 16 then separated = false; break end
    end
    if separated then layout_poles[#layout_poles + 1] = candidate end
    if #layout_poles >= MAX_LAYOUT_SITE_POLES then break end
  end
  if #layout_poles < MAX_LAYOUT_SITE_POLES then
    for _, candidate in ipairs(site_poles) do
      local present = false
      for _, selected in ipairs(layout_poles) do
        if selected.unit_number == candidate.unit_number then present = true; break end
      end
      if not present then layout_poles[#layout_poles + 1] = candidate end
      if #layout_poles >= MAX_LAYOUT_SITE_POLES then break end
    end
  end
  for _, existing_pole in ipairs(layout_poles) do
    for _, direction in ipairs({{1, 1}, {1, -1}, {-1, 1}, {-1, -1}}) do
      for _, reverse_inputs in ipairs({false, true}) do
        choices.reverse_input_order = reverse_inputs
        local layout, err = layout_at(agent, recipe, target_item, target_type, existing_pole, choices,
          machine_count, direction[1], direction[2])
        if layout then
          choices.reverse_input_order = nil
          if marker then layout.marker_goal = marker end
          return layout
        end
        last_layout_error = err or last_layout_error
        if choices.route_budget.remaining <= 0 then
          choices.reverse_input_order = nil
          return nil, last_layout_error or "fluid_route_planning_budget_exhausted"
        end
      end
    end
  end
  choices.reverse_input_order = nil
  return nil, last_layout_error or "no_powered_safe_fluid_site"
end

function FluidPlanner.missing_input(error_message)
  if type(error_message) ~= "string" then return nil end
  local name, count = error_message:match(
    "fluid_source_or_route_unavailable:([^:]+).*:sources=(%d+):")
  if name and tonumber(count) == 0 and prototypes.fluid[name] then return name end
  return nil
end

function FluidPlanner.plan_source(player, agent, fluid_name, options)
  if not prototypes.fluid[fluid_name] then return nil, "unknown_fluid:" .. tostring(fluid_name) end
  local natural, natural_error = natural_source_plan(player, agent, fluid_name, options)
  if natural then return natural end
  local recipe_options = {}
  for key, value in pairs(options or {}) do recipe_options[key] = value end
  recipe_options.target_type = "fluid"
  local processed, processed_error = FluidPlanner.plan(player, agent, fluid_name, nil, recipe_options)
  if processed then return processed end
  return nil, processed_error or natural_error
end

return FluidPlanner
