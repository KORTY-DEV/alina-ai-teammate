local Conflict = require("scripts.conflict.manager")

local RoutePlanner = {}

local MAX_ROUTE_TILES = 640
local MAX_SEARCH_NODES = 30000
local GOAL_RADIUS = 8

local STEPS = {
  {dx = 1, dy = 0, direction = defines.direction.east},
  {dx = 0, dy = 1, direction = defines.direction.south},
  {dx = -1, dy = 0, direction = defines.direction.west},
  {dx = 0, dy = -1, direction = defines.direction.north}
}

local function key(x, y) return x .. ":" .. y end
local function position(x, y) return {x = x + 0.5, y = y + 0.5} end
local function manhattan(x, y, target)
  return math.abs(x + 0.5 - target.x) + math.abs(y + 0.5 - target.y)
end

local function opposite(direction)
  return (direction + defines.direction.south) % 16
end

local function heap_push(heap, node)
  heap[#heap + 1] = node
  local index = #heap
  while index > 1 do
    local parent = math.floor(index / 2)
    if heap[parent].f < node.f or (heap[parent].f == node.f and heap[parent].h <= node.h) then break end
    heap[index] = heap[parent]
    index = parent
  end
  heap[index] = node
end

local function heap_pop(heap)
  local root = heap[1]
  local tail = table.remove(heap)
  if #heap > 0 then
    local index = 1
    while true do
      local left = index * 2
      if left > #heap then break end
      local right = left + 1
      local child = left
      if right <= #heap and (heap[right].f < heap[left].f
          or (heap[right].f == heap[left].f and heap[right].h < heap[left].h)) then child = right end
      if heap[child].f > tail.f or (heap[child].f == tail.f and heap[child].h >= tail.h) then break end
      heap[index] = heap[child]
      index = child
    end
    heap[index] = tail
  end
  return root
end

local function reserved_cells(rows)
  local result = {}
  for _, row in ipairs(rows or {}) do
    result[key(math.floor(row.position.x), math.floor(row.position.y))] = true
  end
  return result
end

local function can_place(surface, force, name, x, y, direction, reserved)
  if reserved[key(x, y)] then return false end
  local blocked = Conflict.is_blocked(surface.index, position(x, y), "autonomous")
  if blocked then return false end
  return surface.can_place_entity({name = name, position = position(x, y), direction = direction, force = force})
end

local function finish_is_clear(surface, force, node, inserter, chest, reserved)
  if not node.direction then return false end
  local step = nil
  for _, candidate in ipairs(STEPS) do
    if candidate.direction == node.direction then step = candidate; break end
  end
  if not step then return false end
  local ix, iy = node.x + step.dx, node.y + step.dy
  local cx, cy = ix + step.dx, iy + step.dy
  return can_place(surface, force, inserter.entity, ix, iy,
      (node.direction + defines.direction.south) % 16, reserved)
    and can_place(surface, force, chest.entity, cx, cy, defines.direction.north, reserved)
end

local function reconstruct(goal, nodes)
  local path = {}
  local current = goal
  while current do
    table.insert(path, 1, current)
    current = current.parent and nodes[current.parent] or nil
  end
  return path
end

-- Deterministic A* is used only when a player explicitly requests a long belt.
-- It plans once, never per tick, and refuses overly long or crowded routes.
function RoutePlanner.plan(surface, force, start_position, target_position, belt, inserter, chest, rows)
  if not target_position then return nil, "route_endpoint_missing" end
  if math.abs(start_position.x - target_position.x) + math.abs(start_position.y - target_position.y)
      > MAX_ROUTE_TILES then return nil, "route_too_long" end

  local reserved = reserved_cells(rows)
  local sx, sy = math.floor(start_position.x), math.floor(start_position.y)
  if not can_place(surface, force, belt.entity, sx, sy, defines.direction.east, reserved) then
    return nil, "route_start_blocked"
  end
  local margin = 32
  local min_x = math.floor(math.min(start_position.x, target_position.x) - margin)
  local max_x = math.ceil(math.max(start_position.x, target_position.x) + margin)
  local min_y = math.floor(math.min(start_position.y, target_position.y) - margin)
  local max_y = math.ceil(math.max(start_position.y, target_position.y) + margin)
  local nodes, scores, closed, heap = {}, {}, {}, {}
  local start_key = key(sx, sy)
  local start = {x = sx, y = sy, g = 1, h = manhattan(sx, sy, target_position), direction = defines.direction.east}
  start.f = start.g + start.h
  nodes[start_key], scores[start_key] = start, start.g
  heap_push(heap, start)
  local examined, goal = 0, nil

  while #heap > 0 and examined < MAX_SEARCH_NODES do
    local node = heap_pop(heap)
    local node_key = key(node.x, node.y)
    if not closed[node_key] then
      closed[node_key] = true
      examined = examined + 1
      if node.h <= GOAL_RADIUS and finish_is_clear(surface, force, node, inserter, chest, reserved) then
        goal = node
        break
      end
      if node.g < MAX_ROUTE_TILES then
        for _, step in ipairs(STEPS) do
          local nx, ny = node.x + step.dx, node.y + step.dy
          -- A belt may turn left/right, but it cannot reverse flow into the
          -- tile it just came from. Without this guard A* chose the shorter
          -- geometric path back toward the base and created two belts facing
          -- each other at the production-line junction, so output never moved.
          if step.direction ~= opposite(node.direction)
              and nx >= min_x and nx <= max_x and ny >= min_y and ny <= max_y then
            local next_key = key(nx, ny)
            local turn_cost = node.direction == step.direction and 0 or 0.35
            local next_g = node.g + 1 + turn_cost
            if not closed[next_key] and (not scores[next_key] or next_g < scores[next_key])
                and can_place(surface, force, belt.entity, nx, ny, step.direction, reserved) then
              local next_node = {x = nx, y = ny, g = next_g,
                h = manhattan(nx, ny, target_position), direction = step.direction, parent = node_key}
              next_node.f = next_node.g + math.max(0, next_node.h - GOAL_RADIUS)
              nodes[next_key], scores[next_key] = next_node, next_g
              heap_push(heap, next_node)
            end
          end
        end
      end
    end
  end
  if not goal then return nil, "no_safe_route:" .. tostring(examined) end

  local path = reconstruct(goal, nodes)
  local result = {}
  for index, node in ipairs(path) do
    local direction = node.direction
    if path[index + 1] then direction = path[index + 1].direction end
    result[#result + 1] = {name = belt.entity, entity_type = belt.entity_type,
      position = position(node.x, node.y), direction = direction,
      route_segment = true, route_step = index, route_total = #path}
  end
  local last = path[#path]
  local step = nil
  for _, candidate in ipairs(STEPS) do if candidate.direction == last.direction then step = candidate; break end end
  local ix, iy = last.x + step.dx, last.y + step.dy
  local cx, cy = ix + step.dx, iy + step.dy
  result[#result + 1] = {name = inserter.entity, entity_type = inserter.entity_type,
    position = position(ix, iy), direction = (last.direction + defines.direction.south) % 16,
    route_terminal = true}
  local output = {name = chest.entity, entity_type = chest.entity_type,
    position = position(cx, cy), direction = defines.direction.north, route_terminal = true}
  result[#result + 1] = output
  return {entities = result, output_row = output, tiles = #path, endpoint = position(cx, cy)}
end

return RoutePlanner
