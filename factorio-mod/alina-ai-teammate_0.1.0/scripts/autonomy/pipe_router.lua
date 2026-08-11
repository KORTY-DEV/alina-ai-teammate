local SitePolicy = require("scripts.construction.site_policy")

local PipeRouter = {}

-- Routing runs only while a new plan is selected, but it still executes in a
-- simulation tick. Keep every individual search bounded; the fluid planner
-- separately caps how many scored sites it may try. Long natural-source routes
-- need this allowance for isolated refinery lanes around real obstacles.
local MAX_NODES = 6000
local ROUTE_MARGIN = 32
-- Keep only genuinely compact machine manifolds on the surface. A twelve-cell
-- straight run is already long enough for prototype-selected underground
-- pairs; converting it leaves walkable factory aisles and substantially cuts
-- entity/update cost without hiding the short branch taps beside machines.
local MIN_UNDERGROUND_ROUTE = 12

local CARDINAL = {
  {x = 0, y = -1},
  {x = 1, y = 0},
  {x = 0, y = 1},
  {x = -1, y = 0}
}

local function key(position)
  return tostring(math.floor(position.x * 2 + 0.5)) .. ":" .. tostring(math.floor(position.y * 2 + 0.5))
end

local function copy(position)
  return {x = position.x, y = position.y}
end

local function distance(a, b)
  return math.abs(a.x - b.x) + math.abs(a.y - b.y)
end

local function fluid_name(entity, index)
  local ok, fluid = pcall(function() return entity.get_fluid_segment_fluid(index) end)
  if ok and fluid and fluid.name and (fluid.amount or 0) > 0 then return fluid.name end
  local filter_ok, filter = pcall(function() return entity.get_fluid_filter(index) end)
  if filter_ok and filter then return filter.name or filter end
  return nil
end

-- Records only open runtime pipe connection points. A new route is not allowed
-- to touch an empty/unknown or differently filled network: that rule prevents
-- accidental cross-contamination of a player's existing fluid systems.
function PipeRouter.connection_map(surface, force, area)
  local result = {}
  local entities = surface.find_entities_filtered({area = area, force = force, limit = 4096})
  for _, entity in ipairs(entities) do
    local ok_count, count = pcall(function() return entity.fluids_count end)
    if entity.valid and ok_count and (count or 0) > 0 then
      for index = 1, count do
        local name = fluid_name(entity, index)
        local ok, connections = pcall(function() return entity.get_fluid_box_pipe_connections(index) end)
        if ok then
          for _, connection in ipairs(connections or {}) do
            if not connection.target and connection.target_position then
              local connection_key = key(connection.target_position)
              local values = result[connection_key]
              if not values then values = {}; result[connection_key] = values end
              values[#values + 1] = {
                fluid = name,
                entity = entity,
                fluidbox_index = index,
                flow_direction = connection.flow_direction
              }
            end
          end
        end
      end
    end
  end
  return result
end

local function heap_push(heap, row)
  heap[#heap + 1] = row
  local index = #heap
  while index > 1 do
    local parent = math.floor(index / 2)
    local a, b = heap[parent], heap[index]
    if a.f < b.f or (a.f == b.f and (a.h < b.h or (a.h == b.h and a.key < b.key))) then break end
    heap[parent], heap[index] = heap[index], heap[parent]
    index = parent
  end
end

local function heap_pop(heap)
  local first = heap[1]
  local last = table.remove(heap)
  if #heap == 0 then return first end
  heap[1] = last
  local index = 1
  while true do
    local left, right = index * 2, index * 2 + 1
    if left > #heap then break end
    local smallest = left
    if right <= #heap then
      local a, b = heap[left], heap[right]
      if b.f < a.f or (b.f == a.f and (b.h < a.h or (b.h == a.h and b.key < a.key))) then
        smallest = right
      end
    end
    local a, b = heap[index], heap[smallest]
    if a.f < b.f or (a.f == b.f and (a.h < b.h or (a.h == b.h and a.key < b.key))) then break end
    heap[index], heap[smallest] = heap[smallest], heap[index]
    index = smallest
  end
  return first
end

local function reconstruct(nodes, final_key)
  local result = {}
  local current = nodes[final_key]
  while current do
    table.insert(result, 1, copy(current.position))
    current = current.parent and nodes[current.parent] or nil
  end
  return result
end

function PipeRouter.route(surface, force, pipe_name, start_position, end_position, fluid, context)
  context = context or {}
  local starts = context.start_positions or {start_position}
  local start_keys = {}
  local end_key = key(end_position)
  local min_x, max_x = end_position.x, end_position.x
  local min_y, max_y = end_position.y, end_position.y
  for _, position in ipairs(starts) do
    start_keys[key(position)] = true
    min_x, max_x = math.min(min_x, position.x), math.max(max_x, position.x)
    min_y, max_y = math.min(min_y, position.y), math.max(max_y, position.y)
  end
  min_x, max_x = min_x - ROUTE_MARGIN, max_x + ROUTE_MARGIN
  min_y, max_y = min_y - ROUTE_MARGIN, max_y + ROUTE_MARGIN
  local reserved = context.reserved or {}
  local occupied = context.occupied or {}
  local connections = context.connections or {}
  local directional_route_cells = context.directional_route_cells or {}
  local route_cells = context.route_cells or {}
  local endpoint_only = context.endpoint_only or {}
  local active_route_id = context.active_route_id
  local keep_route_gap = context.keep_route_gap == true
  local separate_same_fluid_routes = context.separate_same_fluid_routes == true
  local search_budget = context.search_budget
  local node_limit = math.min(MAX_NODES,
    search_budget and math.max(0, search_budget.remaining or 0) or MAX_NODES)
  if node_limit <= 0 then return nil, "fluid_route_planning_budget_exhausted" end
  context.placeability_cache = context.placeability_cache or {}
  local placeability_cache = context.placeability_cache
  local rejected = {}

  local function reject(reason)
    rejected[reason or "unknown"] = (rejected[reason or "unknown"] or 0) + 1
    return false, reason
  end

  local function near_shared_endpoint(position)
    if distance(position, end_position) <= 2 then return true end
    for _, start in ipairs(starts) do
      if distance(position, start) <= 2 then return true end
    end
    return false
  end

  local function allowed(position)
    local position_key = key(position)
    if position.x < min_x or position.x > max_x or position.y < min_y or position.y > max_y then
      return reject("outside_route_bounds")
    end
    if occupied[position_key] and not start_keys[position_key] and position_key ~= end_key then
      return reject("planned_entity_footprint")
    end
    -- A pipe-to-ground has only one surface-side connection. Treating its cell
    -- as an ordinary reusable pipe lets a later same-fluid route enter from a
    -- closed side and creates a plan that looks connected but is not. Routes
    -- can still merge at the ordinary pipes immediately before/after it.
    if directional_route_cells[position_key]
        and not start_keys[position_key] and position_key ~= end_key then
      return reject("planned_directional_fluid_connection")
    end
    local planned = reserved[position_key]
    if planned and planned ~= fluid then return reject("different_planned_fluid:" .. tostring(planned)) end
    if separate_same_fluid_routes and planned == fluid and active_route_id and route_cells[position_key]
        and route_cells[position_key] ~= active_route_id
        and not start_keys[position_key] and position_key ~= end_key then
      return reject("different_same_fluid_route")
    end
    for _, offset in ipairs(CARDINAL) do
      local neighbour_key = key({x = position.x + offset.x, y = position.y + offset.y})
      local neighbour = reserved[neighbour_key]
      if neighbour and neighbour ~= fluid and not endpoint_only[neighbour_key] then
        return reject("adjacent_planned_fluid:" .. tostring(neighbour))
      end
      -- Parallel high-throughput lanes must remain separate segments between
      -- their common source and destination. Without this one-cell gap two
      -- same-fluid rows reconnect sideways and silently bypass their pump
      -- stations. A short fan-out/fan-in zone at each shared endpoint is the
      -- only intentional exception.
      local neighbour_route = route_cells[neighbour_key]
      if keep_route_gap and active_route_id and neighbour_route
          and neighbour_route ~= active_route_id and not near_shared_endpoint(position) then
        return reject("adjacent_parallel_fluid_route")
      end
    end
    for _, existing in ipairs(connections[position_key] or {}) do
      if not existing.fluid then return reject("unknown_existing_fluid") end
      if existing.fluid ~= fluid then return reject("different_existing_fluid:" .. tostring(existing.fluid)) end
    end
    if planned == fluid then return true end
    local can_plan = placeability_cache[position_key]
    if can_plan == nil then
      can_plan = SitePolicy.can_plan(surface, force, pipe_name, position, defines.direction.north)
      placeability_cache[position_key] = can_plan
    end
    if not can_plan then return reject("pipe_not_placeable") end
    return true
  end

  local end_allowed, end_reason = allowed(end_position)
  if not end_allowed then return nil, "fluid_destination_connection_blocked:" .. tostring(end_reason) end

  local heap = {}
  local nodes = {}
  local valid_starts, first_start_reason = 0, nil
  for _, position in ipairs(starts) do
    local start_allowed, start_reason = allowed(position)
    local start_key = key(position)
    if start_allowed and not nodes[start_key] then
      local start_h = distance(position, end_position)
      nodes[start_key] = {position = copy(position), g = 0, h = start_h, f = start_h}
      heap_push(heap, {key = start_key, g = 0, h = start_h, f = start_h})
      valid_starts = valid_starts + 1
    else
      first_start_reason = first_start_reason or start_reason
    end
  end
  if valid_starts == 0 then
    return nil, "fluid_source_connection_blocked:" .. tostring(first_start_reason)
  end
  local visited = 0

  while #heap > 0 and visited < node_limit do
    local current_row = heap_pop(heap)
    local current = nodes[current_row.key]
    if current and current.g == current_row.g and not current.closed then
      current.closed = true
      visited = visited + 1
      if current_row.key == end_key then
        if search_budget then search_budget.remaining = math.max(0, search_budget.remaining - visited) end
        return reconstruct(nodes, end_key)
      end
      for _, offset in ipairs(CARDINAL) do
        local position = {x = current.position.x + offset.x, y = current.position.y + offset.y}
        local position_key = key(position)
        if allowed(position) then
          local next_g = current.g + 1
          local previous = nodes[position_key]
          if not previous or next_g < previous.g then
            local h = distance(position, end_position)
            nodes[position_key] = {position = position, parent = current_row.key,
              g = next_g, h = h, f = next_g + h}
            heap_push(heap, {key = position_key, g = next_g, h = h, f = next_g + h})
          end
        end
      end
    end
  end
  local rejection_rows = {}
  for reason, count in pairs(rejected) do rejection_rows[#rejection_rows + 1] = {reason = reason, count = count} end
  table.sort(rejection_rows, function(a, b)
    if a.count == b.count then return a.reason < b.reason end
    return a.count > b.count
  end)
  local rejection_summary = {}
  for index = 1, math.min(4, #rejection_rows) do
    rejection_summary[#rejection_summary + 1] = rejection_rows[index].reason .. "=" .. rejection_rows[index].count
  end
  local suffix = ":nodes=" .. tostring(visited) .. ":blocked=" .. table.concat(rejection_summary, ",") .. ":start="
    .. string.format("%.1f,%.1f", start_position.x, start_position.y) .. ":end="
    .. string.format("%.1f,%.1f", end_position.x, end_position.y)
  if search_budget then search_budget.remaining = math.max(0, search_budget.remaining - visited) end
  local exhausted = visited >= node_limit
  local reason = exhausted and search_budget and search_budget.remaining <= 0
    and "fluid_route_planning_budget_exhausted"
    or (exhausted and "fluid_route_node_limit" or "fluid_route_not_found")
  return nil, reason .. suffix
end

local function path_direction(first, second)
  local dx, dy = second.x - first.x, second.y - first.y
  if dx > 0 then return defines.direction.east end
  if dx < 0 then return defines.direction.west end
  if dy > 0 then return defines.direction.south end
  if dy < 0 then return defines.direction.north end
  return nil
end

local function max_underground_distance(row)
  local result = 0
  for _, fluidbox in ipairs(row and row.fluidboxes or {}) do
    for _, connection in ipairs(fluidbox.pipe_connections or {}) do
      if connection.connection_type == "underground" then
        result = math.max(result, connection.max_underground_distance or 0)
      end
    end
  end
  return result
end

-- Replaces interiors of long straight runs with prototype-selected underground
-- pipe pairs. Corners remain ordinary pipes, so every turn stays connected.
-- Besides using fewer entities, the open gaps keep dense modded fluid blocks
-- physically walkable before construction robots become available.
local function find_pump_stations(path, transport)
  local result, protected = {}, {}
  local maximum = transport and transport.max_segment_tiles or nil
  if not maximum or #path - 1 <= maximum then return result, protected end
  if not transport.pump_row then return nil, nil, "pipeline_extent_requires_pump" end
  local capacity = (transport.pump_row.pumping_speed or 0) * 60
  local required = transport.required_flow_per_second or 0
  local safe_capacity = capacity * 0.85
  if safe_capacity <= 0 then return nil, nil, "selected_pump_has_no_runtime_capacity" end
  if required > safe_capacity then
    return nil, nil, "parallel_pump_lanes_required:" .. tostring(math.ceil(required / safe_capacity))
  end

  local segment_start = 1
  while #path - segment_start > maximum do
    local desired = math.min(#path - 2, segment_start + maximum)
    local selected = nil
    local function consider(index)
      if index < segment_start + 2 or index + 2 > #path then return false end
      local direction = path_direction(path[index], path[index + 1])
      if not direction or path_direction(path[index - 1], path[index]) ~= direction
          or path_direction(path[index + 1], path[index + 2]) ~= direction then return false end
      local position = {x = (path[index].x + path[index + 1].x) / 2,
        y = (path[index].y + path[index + 1].y) / 2}
      if not SitePolicy.can_plan(transport.surface, transport.force,
          transport.pump_row.entity, position, direction) then return false end
      selected = {first = index, second = index + 1, position = position,
        direction = direction, route_step = index + 0.5}
      return true
    end
    for index = desired, math.max(segment_start + 2, desired - 48), -1 do
      if consider(index) then break end
    end
    if not selected then
      for index = desired + 1, math.min(#path - 2, desired + 48) do
        if consider(index) then break end
      end
    end
    if not selected then return nil, nil, "no_placeable_pump_station_before_pipeline_extent" end
    result[#result + 1] = selected
    for index = selected.first - 1, selected.second + 1 do protected[index] = true end
    segment_start = selected.second
  end
  return result, protected
end

local function optimized_placements(path, pipe_row, underground_row, transport)
  local result = {}
  for index, position in ipairs(path or {}) do
    result[index] = {position = position, row = pipe_row,
      direction = defines.direction.north, route_step = index}
  end
  local stations, protected, station_error = find_pump_stations(path, transport)
  if not stations then return nil, station_error end
  local maximum = max_underground_distance(underground_row)
  -- Keep compact factory manifolds explicit. They need plentiful branch taps
  -- for several modded machine fluidboxes; underground pairs are primarily a
  -- long-distance optimisation and are unsafe as implicit junctions.
  -- Pump cells and their immediate neighbours are protected below, so the
  -- remaining straight portions may still use underground pairs. Keeping an
  -- entire 100+ tile pumped route on the surface creates needless pipe walls.
  if maximum >= 3 and #(path or {}) >= MIN_UNDERGROUND_ROUTE then
  local run_start = 1
  while run_start < #path do
    local direction = path_direction(path[run_start], path[run_start + 1])
    local run_end = run_start + 1
    while run_end < #path and path_direction(path[run_end], path[run_end + 1]) == direction do
      run_end = run_end + 1
    end
    local section_start = run_start
    local function optimize_section(section_end)
      local first = section_start + 1
      while first + 2 <= section_end - 1 do
        local second = math.min(section_end - 1, first + maximum)
        if second - first >= 2 then
          local opposite = (direction + 8) % 16
          -- A pipe-to-ground's normal connection points in its entity direction,
          -- while its buried connection points the opposite way. Therefore the
          -- first endpoint faces out of the span and the second faces forward.
          -- This is prototype geometry, not a vanilla name assumption.
          result[first] = {position = path[first], row = underground_row,
            direction = opposite, route_step = first}
          result[second] = {position = path[second], row = underground_row,
            direction = direction, route_step = second}
          for index = first + 1, second - 1 do result[index] = false end
        end
        first = second + 1
      end
    end
    for index = run_start, run_end + 1 do
      if index > run_end or protected[index] then
        optimize_section(index - 1)
        section_start = index + 1
      end
    end
    run_start = run_end
  end
  end
  for _, station in ipairs(stations) do
    result[station.first] = {
      position = station.position,
      row = transport.pump_row,
      direction = station.direction,
      route_step = station.route_step,
      footprint_positions = {copy(path[station.first]), copy(path[station.second])}
    }
    result[station.second] = false
  end
  return result, nil, stations
end

function PipeRouter.reserve_path(rows, seen, reserved, path, pipe_row, fluid, route_id, underground_row,
    context, transport)
  context = context or {}
  context.directional_route_cells = context.directional_route_cells or {}
  context.route_cells = context.route_cells or {}
  context.occupied = context.occupied or {}
  local taps, pump_rows = {}, {}
  local placements, placement_error = optimized_placements(path, pipe_row, underground_row, transport)
  if not placements then return nil, placement_error end
  for _, placement in ipairs(placements) do
    if placement then
    local position = placement.position
    local position_key = key(position)
    local claimed = reserved[position_key]
    if not claimed then
      reserved[position_key] = fluid
      claimed = fluid
    end
    if claimed == fluid and not seen[position_key] then
      seen[position_key] = true
      context.route_cells[position_key] = route_id
      if placement.row.entity_type == "pipe-to-ground" then
        context.directional_route_cells[position_key] = {
          fluid = fluid,
          direction = placement.direction,
          route_id = route_id
        }
      end
      rows[#rows + 1] = {
        name = placement.row.entity,
        entity_type = placement.row.entity_type,
        position = copy(position),
        direction = placement.direction,
        bootstrap = true,
        fluid_route = fluid,
        fluid_route_id = route_id,
        fluid_route_step = placement.route_step,
        tile_width = placement.row.tile_width,
        tile_height = placement.row.tile_height
      }
      if placement.row.entity_type == "pump" then
        pump_rows[#pump_rows + 1] = rows[#rows]
      end
    end
    for _, footprint_position in ipairs(placement.footprint_positions or {}) do
      local footprint_key = key(footprint_position)
      reserved[footprint_key] = fluid
      context.route_cells[footprint_key] = route_id
      context.occupied[footprint_key] = true
    end
    if placement.row.entity_type == "pump" then context.occupied[position_key] = true end
    if claimed == fluid and placement.row.entity_type == "pipe" then
      taps[#taps + 1] = copy(position)
    end
    end
  end
  return taps, nil, pump_rows
end

function PipeRouter.key(position)
  return key(position)
end

return PipeRouter
