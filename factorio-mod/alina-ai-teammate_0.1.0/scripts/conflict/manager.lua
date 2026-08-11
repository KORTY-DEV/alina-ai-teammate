local State = require("scripts.core.state")

local Conflict = {}
local CELL_SIZE = 16
local ACTIVE_RADIUS = 20

local function cell_key(surface_index, position)
  local x = math.floor(position.x / CELL_SIZE)
  local y = math.floor(position.y / CELL_SIZE)
  return surface_index .. ":" .. x .. ":" .. y
end

local function distance_squared(a, b)
  local dx = a.x - b.x
  local dy = a.y - b.y
  return dx * dx + dy * dy
end

function Conflict.mark_player_activity(player, position, action)
  local root = State.ensure()
  local setting = settings.global["alina-player-active-seconds"]
  local seconds = setting and setting.value or 30
  root.player_activity[cell_key(player.surface.index, position)] = {
    expires_tick = game.tick + seconds * 60,
    player_index = player.index,
    action = action,
    position = {x = position.x, y = position.y}
  }
end

function Conflict.snapshot(surface_index, center, radius)
  local root = State.ensure()
  local protected = {}
  for _, area in ipairs(root.protected_areas) do
    if area.surface_index == surface_index
        and distance_squared(area.center, center) <= (radius + area.radius) * (radius + area.radius) then
      protected[#protected + 1] = {
        center = area.center,
        radius = area.radius,
        owner_player_index = area.owner_player_index
      }
    end
  end
  local active = {}
  for _, activity in pairs(root.player_activity) do
    if activity.expires_tick >= game.tick and activity.position
        and distance_squared(activity.position, center) <= radius * radius then
      active[#active + 1] = {
        position = activity.position,
        player_index = activity.player_index,
        action = activity.action,
        seconds_remaining = math.ceil((activity.expires_tick - game.tick) / 60)
      }
    end
  end
  return {protected_areas = protected, player_active_zones = active}
end

function Conflict.add_protected_area(player, radius)
  local root = State.ensure()
  root.protected_areas[#root.protected_areas + 1] = {
    surface_index = player.surface.index,
    center = {x = player.position.x, y = player.position.y},
    radius = radius,
    owner_player_index = player.index,
    created_tick = game.tick
  }
end

function Conflict.remove_protected_area(player, radius)
  local root = State.ensure()
  local kept, removed = {}, 0
  local maximum = radius or 32
  for _, area in ipairs(root.protected_areas) do
    local owned = area.owner_player_index == player.index
    local nearby = area.surface_index == player.surface.index
      and distance_squared(area.center, player.position) <= maximum * maximum
    if owned and nearby then
      removed = removed + 1
    else
      kept[#kept + 1] = area
    end
  end
  root.protected_areas = kept
  return removed
end

function Conflict.counts()
  local root = State.ensure()
  local active = 0
  for _, activity in pairs(root.player_activity) do
    if activity.expires_tick >= game.tick then active = active + 1 end
  end
  return {
    protected_area_count = #root.protected_areas,
    active_player_zone_count = active
  }
end

local function nearby_player_activity(root, surface_index, position)
  local center_x = math.floor(position.x / CELL_SIZE)
  local center_y = math.floor(position.y / CELL_SIZE)
  for dx = -2, 2 do
    for dy = -2, 2 do
      local activity = root.player_activity[surface_index .. ":" .. (center_x + dx) .. ":" .. (center_y + dy)]
      if activity and activity.expires_tick >= game.tick and activity.position
          and distance_squared(activity.position, position) <= ACTIVE_RADIUS * ACTIVE_RADIUS then
        return activity
      end
    end
  end
  return nil
end

function Conflict.is_blocked(surface_index, position, source)
  local root = State.ensure()
  for _, area in ipairs(root.protected_areas) do
    if area.surface_index == surface_index
      and distance_squared(area.center, position) <= area.radius * area.radius then
      return true, "protected_area"
    end
  end

  -- A direct order can change Alina's goal, but it never grants permission to
  -- build over any human's fresh work. Check neighbouring cells as well so a
  -- cell boundary cannot make her miss a player working on the same section.
  local activity = nearby_player_activity(root, surface_index, position)
  if activity then
    return true, "player_active"
  end
  return false, nil
end

function Conflict.cleanup()
  local root = State.ensure()
  for key, activity in pairs(root.player_activity) do
    if activity.expires_tick < game.tick then
      root.player_activity[key] = nil
    end
  end
end

return Conflict
