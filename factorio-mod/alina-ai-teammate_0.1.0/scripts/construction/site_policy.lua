local SitePolicy = {}

local NATURAL_CLEARABLE_TYPES = {
  tree = true,
  ["simple-entity"] = true,
  ["simple-entity-with-force"] = true
}

function SitePolicy.is_natural_clearable(entity)
  if not entity or not entity.valid or not NATURAL_CLEARABLE_TYPES[entity.type] then return false end
  if entity.type ~= "tree" and entity.force and entity.force.name ~= "neutral" then return false end
  return entity.minable and entity.prototype and entity.prototype.mineable_properties ~= nil
end

local function collision_area(name, position)
  local prototype = prototypes.entity[name]
  local box = prototype and prototype.collision_box or nil
  if not box then return nil end
  return {
    {position.x + box.left_top.x, position.y + box.left_top.y},
    {position.x + box.right_bottom.x, position.y + box.right_bottom.y}
  }
end

function SitePolicy.construction_network(surface, force, position)
  for _, network in ipairs(surface.find_logistic_networks_by_construction_area(position, force) or {}) do
    if network.valid and network.all_construction_robots > 0 then return network end
  end
  return nil
end

function SitePolicy.tree_obstacles(surface, name, position)
  local area = collision_area(name, position)
  if not area then return {} end
  local result = {}
  for _, entity in ipairs(surface.find_entities_filtered({
      area = area,
      type = {"tree", "simple-entity", "simple-entity-with-force"},
      limit = 64
    })) do
    if SitePolicy.is_natural_clearable(entity) then result[#result + 1] = entity end
  end
  return result
end

function SitePolicy.natural_obstacles_near(surface, position, radius, limit)
  local result = {}
  for _, entity in ipairs(surface.find_entities_filtered({
      position = position,
      radius = radius or 3,
      type = {"tree", "simple-entity", "simple-entity-with-force"},
      limit = limit or 16
    })) do
    if SitePolicy.is_natural_clearable(entity) then result[#result + 1] = entity end
  end
  return result
end

-- A planner may reserve a naturally obstructed site only when the exact footprint is
-- inside an active construction network. The executor still revalidates the
-- site after the robots finish and never overwrites a player-owned obstruction.
function SitePolicy.can_plan(surface, force, name, position, direction)
  if surface.can_place_entity({name = name, position = position, direction = direction, force = force}) then
    return true, false
  end
  local trees = SitePolicy.tree_obstacles(surface, name, position)
  if #trees > 0 and SitePolicy.construction_network(surface, force, position) then return true, true end
  return false, false
end

return SitePolicy
