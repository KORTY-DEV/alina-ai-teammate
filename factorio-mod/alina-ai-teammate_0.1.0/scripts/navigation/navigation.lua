local State = require("scripts.core.state")
local Agent = require("scripts.agent.agent")
local TaskManager = require("scripts.tasks.manager")
local EventBus = require("scripts.core.event_bus")

local Navigation = {}
local SPIDER_ROUTE_DISTANCE = 96
local SPIDER_SHORT_ROUTE_DISTANCE = 8
local RAIL_SCAN_INTERVAL = 6
local RAIL_PROBE_DISTANCE = 7
local TRAIN_SCAN_RADIUS = 192
local TRAIN_HORIZON_TICKS = 180
local TRAIN_PATH_MARGIN = 7

local BELT_TYPES = {"transport-belt", "underground-belt", "splitter", "loader", "loader-1x1", "linked-belt"}
local GROUND_RAIL_TYPES = {
  "straight-rail", "half-diagonal-rail", "curved-rail-a", "curved-rail-b",
  "legacy-straight-rail", "legacy-curved-rail"
}
local ROLLING_STOCK_TYPES = {"locomotive", "cargo-wagon", "fluid-wagon", "artillery-wagon"}
local MOVE_VECTORS = {
  [defines.direction.north] = {x = 0, y = -1},
  [defines.direction.northeast] = {x = 0.70710678, y = -0.70710678},
  [defines.direction.east] = {x = 1, y = 0},
  [defines.direction.southeast] = {x = 0.70710678, y = 0.70710678},
  [defines.direction.south] = {x = 0, y = 1},
  [defines.direction.southwest] = {x = -0.70710678, y = 0.70710678},
  [defines.direction.west] = {x = -1, y = 0},
  [defines.direction.northwest] = {x = -0.70710678, y = -0.70710678}
}
local MOVE_DIRECTIONS = {
  defines.direction.north, defines.direction.northeast, defines.direction.east,
  defines.direction.southeast, defines.direction.south, defines.direction.southwest,
  defines.direction.west, defines.direction.northwest
}

local function distance_squared(a, b)
  local dx = a.x - b.x
  local dy = a.y - b.y
  return dx * dx + dy * dy
end

local function direction_to(from, to)
  local dx = to.x - from.x
  local dy = to.y - from.y
  local ax = math.abs(dx)
  local ay = math.abs(dy)

  if ax > ay * 2 then
    return dx > 0 and defines.direction.east or defines.direction.west
  elseif ay > ax * 2 then
    return dy > 0 and defines.direction.south or defines.direction.north
  elseif dx >= 0 and dy >= 0 then
    return defines.direction.southeast
  elseif dx >= 0 and dy < 0 then
    return defines.direction.northeast
  elseif dx < 0 and dy >= 0 then
    return defines.direction.southwest
  end
  return defines.direction.northwest
end

local function copy_position(position)
  return {x = position.x, y = position.y}
end

local function owned_personal_spider(agent)
  local root = State.ensure()
  local unit = root.agent.personal_vehicle_unit
  local vehicle = unit and game.get_entity_by_unit_number(unit) or nil
  local ownership = unit and root.owned_entities[unit] or nil
  if not vehicle or not vehicle.valid or vehicle.type ~= "spider-vehicle"
      or not ownership or ownership.owner ~= "alina" then
    root.agent.personal_vehicle_unit = nil
    return nil
  end
  if vehicle.force ~= agent.force or vehicle.surface ~= agent.surface then return nil end
  return vehicle
end

local function release_personal_spider(agent, vehicle)
  if not vehicle or not vehicle.valid or vehicle.type ~= "spider-vehicle" then return end
  if vehicle.get_driver() ~= agent then return end
  vehicle.autopilot_destination = nil
  vehicle.stop_spider()
  vehicle.set_driver(nil)
end

local function stop_personal_spider(agent, vehicle)
  if not vehicle or not vehicle.valid or vehicle.type ~= "spider-vehicle" then return end
  if vehicle.get_driver() ~= agent then return end
  vehicle.autopilot_destination = nil
  vehicle.stop_spider()
end

local function try_start_personal_spider(task, agent, goal, radius, purpose)
  local vehicle = owned_personal_spider(agent)
  if not vehicle or distance_squared(agent.position, vehicle.position) > 36 then return false end
  local driver = vehicle.get_driver()
  local already_driving = driver == agent and agent.vehicle == vehicle
  local route_distance = distance_squared(agent.position, goal)
  if not already_driving and route_distance < SPIDER_ROUTE_DISTANCE * SPIDER_ROUTE_DISTANCE then return false end
  -- Once Alina owns and drives a Spidertron, keep using it for short routes as
  -- well. Falling through to character pathing while she was still seated made
  -- the pathfinder plan for the character collision box and could repeatedly
  -- leave the much larger Spidertron on top of the next build cell.
  if driver and driver ~= agent then return false end
  if not driver then vehicle.set_driver(agent) end
  if vehicle.get_driver() ~= agent or agent.vehicle ~= vehicle then return false end
  vehicle.autopilot_destination = nil
  vehicle.add_autopilot_destination(goal)
  local root = State.ensure()
  root.metrics.spider_routes = (root.metrics.spider_routes or 0) + 1
  task.navigation = {
    task_id = task.id,
    state = "spider",
    vehicle_unit = vehicle.unit_number,
    goal = copy_position(goal),
    radius = radius,
    purpose = purpose,
    requested_tick = game.tick,
    last_position = copy_position(vehicle.position),
    last_movement_tick = game.tick,
    retries = 0
  }
  EventBus.emit("navigation_spider_started", {
    task_id = task.id,
    vehicle = vehicle.name,
    purpose = purpose,
    goal = copy_position(goal)
  })
  return true
end

local function belt_under(agent)
  local belts = agent.surface.find_entities_filtered({
    position = agent.position,
    -- A character can already be carried while its centre is between tile
    -- centres (up to sqrt(0.5^2 + 0.5^2) away from the belt entity centre).
    radius = 0.78,
    type = BELT_TYPES,
    limit = 6
  })
  local best, best_distance = nil, nil
  for _, belt in ipairs(belts) do
    if belt.valid then
      local distance = distance_squared(agent.position, belt.position)
      if not best_distance or distance < best_distance then
        best, best_distance = belt, distance
      end
    end
  end
  return best
end

local function has_belt_immunity(agent)
  if agent.prototype.has_belt_immunity then return true end
  local grid = agent.grid
  if not grid then return false end
  for _, stack in pairs(grid.get_contents()) do
    local prototype = stack.name and prototypes.equipment[stack.name] or nil
    if prototype and prototype.type == "belt-immunity-equipment" then return true end
  end
  return false
end

local function normalized_delta(from, to)
  local dx, dy = to.x - from.x, to.y - from.y
  local length = math.sqrt(dx * dx + dy * dy)
  if length < 0.0001 then return 0, 0 end
  return dx / length, dy / length
end

local function point_inside_expanded_box(position, box, margin)
  return box and position.x >= box.left_top.x - margin
    and position.x <= box.right_bottom.x + margin
    and position.y >= box.left_top.y - margin
    and position.y <= box.right_bottom.y + margin
end

local function rail_crossing_ahead(agent, waypoint)
  local dx, dy = normalized_delta(agent.position, waypoint)
  if dx == 0 and dy == 0 then return nil, false end
  local distance = math.sqrt(distance_squared(agent.position, waypoint))
  local probe = {
    x = agent.position.x + dx * math.min(RAIL_PROBE_DISTANCE, distance),
    y = agent.position.y + dy * math.min(RAIL_PROBE_DISTANCE, distance)
  }
  local margin = 2.25
  local area = {
    {math.min(agent.position.x, probe.x) - margin, math.min(agent.position.y, probe.y) - margin},
    {math.max(agent.position.x, probe.x) + margin, math.max(agent.position.y, probe.y) + margin}
  }
  local rails = agent.surface.find_entities_filtered({area = area, type = GROUND_RAIL_TYPES, limit = 24})
  local best, best_distance, on_track = nil, nil, false
  for _, rail in ipairs(rails) do
    if rail.valid then
      local candidate_distance = distance_squared(agent.position, rail.position)
      if not best_distance or candidate_distance < best_distance then
        best, best_distance = rail, candidate_distance
      end
      if point_inside_expanded_box(agent.position, rail.bounding_box, 0.85) then on_track = true end
    end
  end
  return best, on_track
end

local function rolling_stock_motion(stock)
  local speed_ok, speed = pcall(function() return stock.speed end)
  local orientation_ok, orientation = pcall(function() return stock.orientation end)
  if not speed_ok or not orientation_ok or type(speed) ~= "number" or type(orientation) ~= "number" then
    return nil
  end
  local magnitude = math.abs(speed)
  if magnitude < 0.003 then return nil end
  local sign = speed >= 0 and 1 or -1
  local angle = orientation * math.pi * 2
  return {x = math.sin(angle) * sign, y = -math.cos(angle) * sign, speed = magnitude}
end

local function approaching_train(agent, rail)
  local stocks = agent.surface.find_entities_filtered({
    position = rail.position, radius = TRAIN_SCAN_RADIUS, type = ROLLING_STOCK_TYPES, limit = 128
  })
  local best, best_eta = nil, nil
  for _, stock in ipairs(stocks) do
    if stock.valid then
      local motion = rolling_stock_motion(stock)
      if motion then
        local dx, dy = rail.position.x - stock.position.x, rail.position.y - stock.position.y
        local distance = math.sqrt(dx * dx + dy * dy)
        local along = dx * motion.x + dy * motion.y
        local lateral = math.abs(dx * motion.y - dy * motion.x)
        local horizon = math.min(TRAIN_SCAN_RADIUS,
          math.max(14, motion.speed * TRAIN_HORIZON_TICKS + 12))
        local dangerous = distance <= 11
          or (along >= -4 and along <= horizon and lateral <= TRAIN_PATH_MARGIN)
        if dangerous then
          local eta = math.max(0, along) / math.max(0.001, motion.speed)
          if not best_eta or eta < best_eta then
            best, best_eta = {
              entity = stock,
              speed = motion.speed,
              distance = distance,
              eta_ticks = eta
            }, eta
          end
        end
      end
    end
  end
  return best
end

local function clear_rail_safety(navigation)
  if navigation.rail_safety_mode then
    EventBus.emit("navigation_train_guard_cleared", {
      task_id = navigation.task_id,
      purpose = navigation.purpose,
      waited_ticks = navigation.rail_wait_started_tick
        and game.tick - navigation.rail_wait_started_tick or 0
    })
  end
  navigation.rail_safety_mode = nil
  navigation.rail_safety_direction = nil
  navigation.rail_wait_started_tick = nil
  navigation.rail_safety_train = nil
end

local function rail_safety(agent, waypoint, navigation)
  if game.tick < (navigation.rail_safety_next_tick or 0) then
    return navigation.rail_safety_mode, navigation.rail_safety_direction
  end
  navigation.rail_safety_next_tick = game.tick + RAIL_SCAN_INTERVAL
  local rail, on_track = rail_crossing_ahead(agent, waypoint)
  if not rail then clear_rail_safety(navigation); return nil end
  local root = State.ensure()
  root.metrics.rail_safety_scans = (root.metrics.rail_safety_scans or 0) + 1
  local train = approaching_train(agent, rail)
  if not train then clear_rail_safety(navigation); return nil end

  local mode, escape_direction = "wait", nil
  if on_track then
    local away = {
      x = agent.position.x + (agent.position.x - rail.position.x) * 4,
      y = agent.position.y + (agent.position.y - rail.position.y) * 4
    }
    if distance_squared(agent.position, away) < 0.16 then away = waypoint end
    mode = "escape"
    escape_direction = direction_to(agent.position, away)
  end
  if navigation.rail_safety_mode ~= mode then
    if mode == "wait" then
      root.metrics.train_waits = (root.metrics.train_waits or 0) + 1
      navigation.rail_wait_started_tick = game.tick
    end
    EventBus.emit(mode == "wait" and "navigation_train_wait_started"
      or "navigation_train_escape_started", {
        task_id = navigation.task_id,
        purpose = navigation.purpose,
        crossing = copy_position(rail.position),
        train = train.entity.name,
        train_speed = train.speed,
        train_distance = train.distance,
        eta_ticks = train.eta_ticks
      })
  end
  navigation.rail_safety_mode = mode
  navigation.rail_safety_direction = escape_direction
  navigation.rail_safety_train = train.entity.unit_number
  return mode, escape_direction
end

local function belt_escape_direction(belt, agent, desired_x, desired_y)
  local belt_direction = MOVE_VECTORS[belt.direction]
  local horizontal = math.abs(belt_direction.x) >= math.abs(belt_direction.y)
  if horizontal then
    if math.abs(desired_y) > 0.05 then
      return desired_y > 0 and defines.direction.south or defines.direction.north
    end
    -- With no vertical preference use a stable side derived from the belt
    -- centre. This keeps multiplayer peers deterministic.
    return agent.position.y >= belt.position.y
      and defines.direction.south or defines.direction.north
  end
  if math.abs(desired_x) > 0.05 then
    return desired_x > 0 and defines.direction.east or defines.direction.west
  end
  return agent.position.x >= belt.position.x
    and defines.direction.east or defines.direction.west
end

local function belt_detour(agent, belt, navigation, desired_x, desired_y)
  local escape_direction = belt_escape_direction(belt, agent, desired_x, desired_y)
  local vector = MOVE_VECTORS[belt.direction] or {x = 0, y = 0}
  local horizontal = math.abs(vector.x) >= math.abs(vector.y)
  local bounds = {
    horizontal = horizontal,
    min_x = belt.position.x,
    max_x = belt.position.x,
    min_y = belt.position.y,
    max_y = belt.position.y
  }
  navigation.belt_detour = {
    phase = "escape",
    escape_direction = escape_direction,
    escape_start_position = copy_position(agent.position),
    phase_started_tick = game.tick,
    started_tick = game.tick,
    source_belt_direction = belt.direction,
    line_bounds = bounds
  }
  -- The original path is temporarily suspended while the deterministic belt
  -- manoeuvre runs.  Do not let its age trigger a needless re-path every 1800
  -- ticks in the middle of that manoeuvre.
  navigation.requested_tick = game.tick
  EventBus.emit_debug("navigation_belt_detour_started", {
    task_id = navigation.task_id,
    belt = belt.name,
    belt_speed = belt.prototype.belt_speed or 0,
    walking_speed = agent.character_running_speed or agent.prototype.running_speed or 0.15,
    purpose = navigation.purpose,
    position = copy_position(agent.position),
    goal = copy_position(navigation.goal),
    escape_direction = escape_direction
  })
end

local function belt_aware_direction(agent, waypoint, navigation)
  local detour = navigation.belt_detour
  if detour then
    local function clearance_goal()
      local bounds = detour.line_bounds
      local direction = detour.escape_direction
      if bounds and bounds.horizontal then
        local south = direction == defines.direction.south
          or direction == defines.direction.southeast or direction == defines.direction.southwest
        return {x = agent.position.x, y = (bounds.min_y + bounds.max_y) * 0.5
          + (south and 1.8 or -1.8)}
      end
      local east = direction == defines.direction.east
        or direction == defines.direction.northeast or direction == defines.direction.southeast
      local line_x = bounds and (bounds.min_x + bounds.max_x) * 0.5 or agent.position.x
      return {x = line_x + (east and 1.8 or -1.8), y = agent.position.y}
    end
    local function begin_clearance()
      detour.phase = "clearance"
      detour.clearance_start_position = copy_position(agent.position)
      detour.clearance_goal = clearance_goal()
      detour.phase_started_tick = game.tick
      return direction_to(agent.position, detour.clearance_goal), true
    end
    if detour.phase == "escape" then
      -- A fast belt changes the along-belt coordinate faster than walking can
      -- correct it, so an exact diagonal escape point may be mathematically
      -- unreachable. Walk purely across the belt until the character is off
      -- every belt, then ask the pathfinder for a route from that safe side.
      local current_belt = belt_under(agent)
      if current_belt and not has_belt_immunity(agent) then
        local current_vector = MOVE_VECTORS[current_belt.direction] or {x = 0, y = 0}
        local escape_vector = MOVE_VECTORS[detour.escape_direction] or {x = 0, y = 0}
        if math.abs(current_vector.x * escape_vector.x + current_vector.y * escape_vector.y) > 0.5 then
          local desired_x, desired_y = normalized_delta(agent.position, waypoint)
          detour.escape_direction = belt_escape_direction(current_belt, agent, desired_x, desired_y)
          detour.escape_start_position = copy_position(agent.position)
          detour.phase_started_tick = game.tick
        end
        local start = detour.escape_start_position or agent.position
        local perpendicular_progress = math.abs((agent.position.x - start.x) * current_vector.y
          - (agent.position.y - start.y) * current_vector.x)
        if game.tick - (detour.phase_started_tick or detour.started_tick) >= 90
            and perpendicular_progress < 0.55 then
          -- A drill, machine or pipe can occupy the only side exit.  Riding a
          -- faster belt downstream is always physically achievable; a short
          -- ride exposes another side cell without crossing the whole bus.
          -- Remember the opposite side as well: in compact production rows the
          -- goal-facing side is often occupied by an inserter and a machine.
          -- Retrying that same side forever caused the east/west shuttle seen
          -- on the K2 megabase fixture.
          detour.next_escape_direction = (detour.escape_direction + 8) % 16
          detour.phase = "ride"
          detour.phase_started_tick = game.tick
          return current_belt.direction, true
        end
        return detour.escape_direction, true
      end
      return begin_clearance()
    end
    if detour.phase == "ride" then
      local current_belt = belt_under(agent)
      if current_belt and not has_belt_immunity(agent) then
        -- Do not ride a huge modded bus to its remote endpoint. Move only far
        -- enough to clear a blocked side cell, then retry the perpendicular
        -- escape from the new local position.
        if game.tick - (detour.phase_started_tick or game.tick) >= 90 then
          local desired_x, desired_y = normalized_delta(agent.position, waypoint)
          detour.phase = "escape"
          detour.escape_direction = detour.next_escape_direction
            or belt_escape_direction(current_belt, agent, desired_x, desired_y)
          detour.next_escape_direction = nil
          detour.escape_start_position = copy_position(agent.position)
          detour.phase_started_tick = game.tick
          return detour.escape_direction, true
        end
        return current_belt.direction, true
      end
      return begin_clearance()
    end
    if detour.phase == "clearance" then
      local start = detour.clearance_start_position or agent.position
      local goal = detour.clearance_goal or clearance_goal()
      local moved = math.sqrt(distance_squared(agent.position, start))
      local remaining = distance_squared(agent.position, goal)
      local age = game.tick - (detour.phase_started_tick or game.tick)
      if remaining <= 0.36 then
        -- Follow the already computed path beside the belt, never scan the
        -- whole bus for a remote endpoint. Up to 64 collinear waypoints gives
        -- useful progress on a long overhaul belt while bounding the state and
        -- keeping the next turn/crossing under the pathfinder's control.
        local bounds = detour.line_bounds
        local waypoints = navigation.waypoints or {}
        local first = navigation.index or 1
        local last = first
        local target = waypoints[first] or waypoint
        local limit = math.min(#waypoints, first + 63)
        for index = first + 1, limit do
          local candidate = waypoints[index]
          local collinear = bounds and bounds.horizontal
            and math.abs(candidate.y - bounds.min_y) <= 0.8
            or bounds and not bounds.horizontal
            and math.abs(candidate.x - bounds.min_x) <= 0.8
          if not collinear then break end
          last, target = index, candidate
        end
        if target then
          detour.phase = "corridor"
          detour.corridor_waypoint_index = last
          detour.corridor_goal = bounds and bounds.horizontal
            and {x = target.x, y = goal.y}
            or {x = goal.x, y = target.y}
          detour.corridor_best_distance = distance_squared(agent.position, detour.corridor_goal)
          detour.corridor_progress_tick = game.tick
          detour.phase_started_tick = game.tick
          return direction_to(agent.position, detour.corridor_goal), true
        end
        navigation.belt_detour = nil
        return direction_to(agent.position, waypoint), false
      end
      if age >= 120 then
        navigation.belt_detour = nil
        return direction_to(agent.position, waypoint), false
      end
      if age >= 45 and moved < 0.35 and not detour.clearance_flipped then
        detour.escape_direction = (detour.escape_direction + 8) % 16
        detour.clearance_start_position = copy_position(agent.position)
        detour.clearance_goal = clearance_goal()
        detour.phase_started_tick = game.tick
        detour.clearance_flipped = true
      end
      return direction_to(agent.position, detour.clearance_goal), true
    end
    if detour.phase == "corridor" then
      local goal = detour.corridor_goal
      local remaining = goal and distance_squared(agent.position, goal) or 0
      if remaining <= 0.64 then
        navigation.index = math.max(navigation.index or 1,
          (detour.corridor_waypoint_index or navigation.index or 1) + 1)
        navigation.waypoint_best_distance = nil
        navigation.waypoint_progress_tick = game.tick
        navigation.belt_detour = nil
        local next_waypoint = navigation.waypoints and navigation.waypoints[navigation.index]
        return direction_to(agent.position, next_waypoint or navigation.goal), false
      end
      if not detour.corridor_best_distance
          or remaining < detour.corridor_best_distance - 0.04 then
        detour.corridor_best_distance = remaining
        detour.corridor_progress_tick = game.tick
      elseif game.tick - (detour.corridor_progress_tick or game.tick) >= 180 then
        navigation.belt_detour = nil
        return direction_to(agent.position, waypoint), false
      end
      return direction_to(agent.position, goal), true
    end
    navigation.belt_detour = nil
    return direction_to(agent.position, waypoint), false
  end
  local belt = belt_under(agent)
  if not belt or has_belt_immunity(agent) then
    return direction_to(agent.position, waypoint), false
  end

  local belt_direction = MOVE_VECTORS[belt.direction]
  local belt_speed = belt.prototype.belt_speed or 0
  if not belt_direction or belt_speed <= 0 then return direction_to(agent.position, waypoint), false end
  local desired_x, desired_y = normalized_delta(agent.position, waypoint)
  local walk_speed = agent.character_running_speed or agent.prototype.running_speed or 0.15
  local opposing = (belt_direction.x * desired_x + belt_direction.y * desired_y) < -0.35

  -- A modded belt can be faster than the character. Walking against such a belt
  -- can never make progress, so leave it sideways before asking for a new path.
  if opposing and belt_speed >= walk_speed * 0.95 then
    belt_detour(agent, belt, navigation, desired_x, desired_y)
    return belt_aware_direction(agent, waypoint, navigation)
  end

  -- Select the walking direction by the resulting vector, not by legs alone.
  -- This naturally uses a belt that helps and compensates lateral belt drift.
  local best_direction, best_score = nil, nil
  for _, direction in ipairs(MOVE_DIRECTIONS) do
    local walk = MOVE_VECTORS[direction]
    local vx = walk.x * walk_speed + belt_direction.x * belt_speed
    local vy = walk.y * walk_speed + belt_direction.y * belt_speed
    local progress = vx * desired_x + vy * desired_y
    local lateral = math.abs(vx * desired_y - vy * desired_x)
    local score = progress - lateral * 0.45
    if not best_score or score > best_score then best_direction, best_score = direction, score end
  end
  return best_direction or direction_to(agent.position, waypoint), false
end

local function issue_request(task, agent, goal, radius, purpose, retries)
  Agent.stop()
  local construction_route = purpose == "physical_module_build"
    or purpose == "clear_physical_build_site"
    or purpose == "clear_construction_tree"
  local detour_route = construction_route or (retries or 0) > 0
  local request_id = agent.surface.request_path({
    bounding_box = agent.prototype.collision_box,
    collision_mask = agent.prototype.collision_mask,
    start = agent.position,
    goal = goal,
    force = agent.force,
    entity_to_ignore = agent,
    radius = radius,
    can_open_gates = true,
    pathfind_flags = {
      allow_destroy_friendly_entities = false,
      allow_paths_through_own_entities = false,
      -- Construction often starts inside a dense working factory. Cached,
      -- straight-biased paths repeatedly chose a short route through a neutral
      -- obstacle and returned `needs_destroy_to_reach` for every work site.
      -- Prefer a non-destructive detour and do not reuse that rejected route.
      -- A retry must not reuse the exact cached path on which manual walking
      -- just got stuck (typically a dense, fast overhaul belt grid). Ask the
      -- deterministic pathfinder for a fresh non-straight detour instead.
      cache = not detour_route,
      prefer_straight_paths = not detour_route,
      low_priority = false
    }
  })

  task.navigation = {
    task_id = task.id,
    request_id = request_id,
    state = "waiting",
    goal = copy_position(goal),
    radius = radius,
    purpose = purpose,
    retries = retries or 0,
    requested_tick = game.tick,
    last_position = copy_position(agent.position),
    last_movement_tick = game.tick
  }
  local root = State.ensure()
  root.metrics.path_requests = (root.metrics.path_requests or 0) + 1
  local emit = (purpose == "physical_module_build" or purpose == "clear_physical_build_site")
    and EventBus.emit_debug or EventBus.emit
  emit("navigation_requested", {
    task_id = task.id,
    request_id = request_id,
    purpose = purpose,
    start = copy_position(agent.position),
    goal = copy_position(goal),
    retry = retries or 0
  })
end

local function recoverable_build_navigation(navigation)
  return navigation and (navigation.purpose == "physical_module_build"
    or navigation.purpose == "clear_physical_build_site"
    or navigation.purpose == "clear_construction_tree")
end

function Navigation.start(task, agent, goal, radius, purpose)
  radius = radius or 1
  if distance_squared(agent.position, goal) <= radius * radius then
    Agent.stop()
    task.navigation = {
      state = "arrived",
      goal = copy_position(goal),
      radius = radius,
      purpose = purpose,
      retries = 0
    }
    return
  end
  if try_start_personal_spider(task, agent, goal, radius, purpose) then return end
  issue_request(task, agent, goal, radius, purpose, 0)
end

function Navigation.cancel(task)
  local agent = Agent.get()
  local navigation = task.navigation
  if agent and navigation and navigation.state == "spider" then
    local vehicle = game.get_entity_by_unit_number(navigation.vehicle_unit)
    stop_personal_spider(agent, vehicle)
  end
  task.navigation = nil
end

function Navigation.on_path_finished(event)
  local task = TaskManager.current()
  local navigation = task and task.navigation or nil
  if not navigation or navigation.request_id ~= event.id then return end
  local agent = Agent.get()

  if event.try_again_later then
    navigation.state = "retry_wait"
    navigation.retry_tick = game.tick + 30
    return
  end

  if not event.path or #event.path == 0 then
    local acceptable_radius = navigation.radius + 0.75
    if agent and navigation.purpose == "physical_module_build" then
      -- The pathfinder cannot enter a completed pipe manifold, but Factorio
      -- still lets a character place the target from her normal build reach.
      -- Treat that as arrival; this is not remote construction or teleporting.
      acceptable_radius = math.max(acceptable_radius, math.max(1, agent.build_distance - 0.05))
    end
    if agent and distance_squared(agent.position, navigation.goal) <= acceptable_radius ^ 2 then
      navigation.state = "arrived"
      return
    end
    EventBus.emit("navigation_failed", {task_id = task.id, purpose = navigation.purpose,
      reason = "no_path", position = agent and copy_position(agent.position) or nil, goal = navigation.goal})
    if recoverable_build_navigation(navigation) then
      navigation.state = "failed"
      navigation.failure_reason = "no_path"
      return
    end
    TaskManager.fail("Не нашла безопасный путь; препятствия не ломаю без разрешения.")
    return
  end

  local waypoints = {}
  local tree_approach_trimmed = false
  local previous_position = nil
  local previous_step = nil
  local function append_waypoint(position)
    local last = waypoints[#waypoints]
    if not last or math.abs(last.x - position.x) > 0.001
        or math.abs(last.y - position.y) > 0.001 then
      waypoints[#waypoints + 1] = copy_position(position)
    end
  end
  local function step_between(a, b)
    local dx, dy = b.x - a.x, b.y - a.y
    return {
      x = math.abs(dx) < 0.001 and 0 or (dx > 0 and 1 or -1),
      y = math.abs(dy) < 0.001 and 0 or (dy > 0 and 1 or -1)
    }
  end
  for _, waypoint in ipairs(event.path) do
    if waypoint.needs_destroy_to_reach then
      if navigation.purpose == "clear_construction_tree" then
        -- The final obstruction is normally the tree this task intends to
        -- mine. Preserve the safe approach; no other route gains permission
        -- to destroy an entity.
        tree_approach_trimmed = true
        break
      end
      EventBus.emit("navigation_failed", {task_id = task.id, purpose = navigation.purpose,
        reason = "destruction_required", position = agent and copy_position(agent.position) or nil,
        goal = navigation.goal})
      if recoverable_build_navigation(navigation) then
        navigation.obstruction_position = copy_position(waypoint.position)
        navigation.state = "failed"
        navigation.failure_reason = "destruction_required"
        return
      end
      TaskManager.fail("Путь требует разрушения препятствий; остановилась без вмешательства в базу.")
      return
    end
    local position = waypoint.position
    if not previous_position then
      append_waypoint(position)
    else
      local step = step_between(previous_position, position)
      if previous_step and (step.x ~= previous_step.x or step.y ~= previous_step.y) then
        append_waypoint(previous_position)
      end
      if step.x ~= 0 or step.y ~= 0 then previous_step = step end
    end
    previous_position = copy_position(position)
  end
  if previous_position then append_waypoint(previous_position) end

  if tree_approach_trimmed and #waypoints == 0 then
    navigation.state = "arrived"
    return
  end

  navigation.state = "following"
  navigation.waypoints = waypoints
  navigation.index = 1
  navigation.last_movement_tick = game.tick
  navigation.waypoint_best_distance = nil
  navigation.waypoint_progress_tick = game.tick
  local emit = recoverable_build_navigation(navigation) and EventBus.emit_debug or EventBus.emit
  emit("navigation_ready", {
    task_id = task.id,
    purpose = navigation.purpose,
    waypoints = #waypoints
  })
end

local function replan(task, agent, navigation)
  if navigation.local_deterministic then
    navigation.state = "failed"
    navigation.failure_reason = "local_path_stuck"
    EventBus.emit("navigation_failed", {task_id = task.id, purpose = navigation.purpose,
      reason = navigation.failure_reason, position = copy_position(agent.position), goal = navigation.goal})
    return false
  end
  local retries = (navigation.retries or 0) + 1
  if retries > 2 then
    local escape_count = task.navigation_escape_count or 0
    if recoverable_build_navigation(navigation) and escape_count < 4 then
      -- A valid long path can still leave a character wedged between the last
      -- machine and belt of a dense module. Make one short, deterministic move
      -- into free space, then let the caller request the original goal again.
      -- This never teleports, mines or crosses a reserved player area.
      local offsets = {
        {x = -6, y = 0}, {x = 6, y = 0}, {x = 0, y = -6}, {x = 0, y = 6}
      }
      for attempt = 1, #offsets do
        local index = (escape_count + attempt - 1) % #offsets + 1
        local offset = offsets[index]
        local desired = {x = agent.position.x + offset.x, y = agent.position.y + offset.y}
        local candidate = agent.surface.find_non_colliding_position(
          agent.name, desired, 2, 0.5, true)
        if candidate and distance_squared(candidate, agent.position) >= 4 then
          task.navigation_escape_count = escape_count + 1
          EventBus.emit("navigation_local_escape_started", {
            task_id = task.id,
            purpose = navigation.purpose,
            attempt = task.navigation_escape_count,
            from = copy_position(agent.position),
            to = copy_position(candidate)
          })
          issue_request(task, agent, candidate, 0.75, navigation.purpose, 0)
          return true
        end
      end
    end
    EventBus.emit("navigation_failed", {task_id = task.id, purpose = navigation.purpose,
      reason = "stuck", position = copy_position(agent.position), goal = navigation.goal})
    if recoverable_build_navigation(navigation) then
      navigation.state = "failed"
      navigation.failure_reason = "stuck"
      return false
    end
    TaskManager.fail("Не смогла обойти препятствие после двух попыток; ничего не ломаю.")
    return false
  end
  issue_request(task, agent, navigation.goal, navigation.radius, navigation.purpose, retries)
  return true
end

function Navigation.update_goal(task, agent, goal, replan_distance)
  local navigation = task.navigation
  if not navigation then return end
  local threshold = replan_distance or 6
  if distance_squared(navigation.goal, goal) > threshold * threshold then
    if navigation.state == "spider" then
      local vehicle = game.get_entity_by_unit_number(navigation.vehicle_unit)
      if vehicle and vehicle.valid and vehicle.get_driver() == agent then
        vehicle.autopilot_destination = nil
        vehicle.add_autopilot_destination(goal)
        navigation.goal = copy_position(goal)
        navigation.requested_tick = game.tick
        return
      end
    end
    issue_request(task, agent, goal, navigation.radius, navigation.purpose, navigation.retries or 0)
  end
end

local function tick_personal_spider(task, agent, navigation)
  local vehicle = game.get_entity_by_unit_number(navigation.vehicle_unit)
  if not vehicle or not vehicle.valid or vehicle.type ~= "spider-vehicle"
      or vehicle.get_driver() ~= agent then
    issue_request(task, agent, navigation.goal, navigation.radius, navigation.purpose, 0)
    return false
  end
  local arrival_radius = navigation.purpose == "clear_physical_build_site"
    and math.max(0.75, navigation.radius)
    or math.max(2.5, navigation.radius + 1)
  if distance_squared(vehicle.position, navigation.goal) <= arrival_radius * arrival_radius then
    stop_personal_spider(agent, vehicle)
    EventBus.emit("navigation_spider_finished", {
      task_id = task.id,
      vehicle = vehicle.name,
      purpose = navigation.purpose
    })
    task.navigation = nil
    return true
  end
  local rail_mode = rail_safety(agent, navigation.goal, navigation)
  if rail_mode == "wait" then
    stop_personal_spider(agent, vehicle)
    navigation.spider_train_paused = true
    navigation.last_movement_tick = game.tick
    navigation.requested_tick = game.tick
    return false
  elseif navigation.spider_train_paused then
    vehicle.autopilot_destination = nil
    vehicle.add_autopilot_destination(navigation.goal)
    navigation.spider_train_paused = nil
    navigation.last_position = copy_position(vehicle.position)
    navigation.last_movement_tick = game.tick
    navigation.requested_tick = game.tick
  end
  if distance_squared(vehicle.position, navigation.last_position) > 0.25 then
    navigation.last_position = copy_position(vehicle.position)
    navigation.last_movement_tick = game.tick
  elseif game.tick - (navigation.last_movement_tick or game.tick) > 600
      or game.tick - (navigation.requested_tick or game.tick) > 7200 then
    release_personal_spider(agent, vehicle)
    EventBus.emit("navigation_spider_fallback", {
      task_id = task.id,
      vehicle = vehicle.name,
      purpose = navigation.purpose,
      reason = "no_progress"
    })
    local root = State.ensure()
    root.metrics.spider_fallbacks = (root.metrics.spider_fallbacks or 0) + 1
    issue_request(task, agent, navigation.goal, navigation.radius, navigation.purpose, 0)
  end
  return false
end

function Navigation.tick(task, agent)
  local navigation = task.navigation
  if not navigation then return false end

  if navigation.state == "spider" then
    return tick_personal_spider(task, agent, navigation)
  end

  if navigation.state == "failed" then
    Agent.stop()
    return false, navigation.failure_reason or "navigation_failed"
  end

  if distance_squared(agent.position, navigation.goal) <= navigation.radius * navigation.radius then
    Agent.stop()
    task.navigation = nil
    return true
  end

  if navigation.state == "retry_wait" then
    if game.tick >= (navigation.retry_tick or game.tick) then
      replan(task, agent, navigation)
    end
    return false
  end

  if navigation.state == "waiting" then
    Agent.stop()
    if game.tick - navigation.requested_tick > 600 then
      if recoverable_build_navigation(navigation) then
        navigation.state = "failed"
        navigation.failure_reason = "path_timeout"
        EventBus.emit("navigation_failed", {task_id = task.id, purpose = navigation.purpose,
          reason = "path_timeout", position = copy_position(agent.position), goal = navigation.goal})
        return false, navigation.failure_reason
      end
      replan(task, agent, navigation)
    end
    return false
  end

  if navigation.state ~= "following" then return false end

  local waypoint = navigation.waypoints[navigation.index]
  while waypoint do
    local next_waypoint = navigation.waypoints[navigation.index + 1]
    local reached = distance_squared(agent.position, waypoint) <= 0.25
    local passed = next_waypoint
      and distance_squared(agent.position, next_waypoint) + 0.08 < distance_squared(agent.position, waypoint)
    if not reached and not passed then break end
    navigation.index = navigation.index + 1
    waypoint = navigation.waypoints[navigation.index]
    navigation.waypoint_best_distance = nil
    navigation.waypoint_progress_tick = game.tick
  end

  if not waypoint then
    if distance_squared(agent.position, navigation.goal) <= (navigation.radius + 0.75) ^ 2 then
      Agent.stop()
      task.navigation = nil
      return true
    end
    replan(task, agent, navigation)
    return false
  end

  local rail_mode, rail_direction = rail_safety(agent, waypoint, navigation)
  if rail_mode == "wait" then
    Agent.stop()
    navigation.waypoint_progress_tick = game.tick
    navigation.last_movement_tick = game.tick
    navigation.requested_tick = game.tick
    return false
  end
  local waypoint_distance = distance_squared(agent.position, waypoint)
  if not navigation.waypoint_best_distance or waypoint_distance < navigation.waypoint_best_distance - 0.04 then
    navigation.waypoint_best_distance = waypoint_distance
    navigation.waypoint_progress_tick = game.tick
  elseif game.tick - (navigation.waypoint_progress_tick or game.tick)
      > (navigation.local_deterministic and 75 or 240) then
    replan(task, agent, navigation)
    return false
  end
  if game.tick - (navigation.requested_tick or game.tick) > 1800 then
    replan(task, agent, navigation)
    return false
  end

  local walking_direction, escaping_belt
  if rail_mode == "escape" then
    walking_direction, escaping_belt = rail_direction, false
    navigation.waypoint_progress_tick = game.tick
    navigation.last_movement_tick = game.tick
    navigation.requested_tick = game.tick
  else
    walking_direction, escaping_belt = belt_aware_direction(agent, waypoint, navigation)
  end
  if navigation.belt_detour and game.tick - navigation.belt_detour.started_tick > 1800 then
    navigation.belt_detour = nil
    replan(task, agent, navigation)
    return false
  end
  if escaping_belt then
    navigation.waypoint_progress_tick = game.tick
    navigation.requested_tick = game.tick
  end
  if not escaping_belt and navigation.belt_escape_was_active then
    navigation.belt_escape_was_active = nil
    -- The engine path remains valid after a one-tile lateral belt escape.
    -- Re-requesting it after every parallel belt made a dense bus take minutes
    -- to cross; the ordinary progress watchdog will still re-plan if needed.
  end
  navigation.belt_escape_was_active = escaping_belt or nil

  agent.mining_state = {mining = false}
  agent.selected = nil
  agent.walking_state = {walking = true, direction = walking_direction}

  if distance_squared(agent.position, navigation.last_position) > 0.04 then
    navigation.last_position = copy_position(agent.position)
    navigation.last_movement_tick = game.tick
  elseif game.tick - navigation.last_movement_tick > 300 then
    replan(task, agent, navigation)
  end
  return false
end

return Navigation
