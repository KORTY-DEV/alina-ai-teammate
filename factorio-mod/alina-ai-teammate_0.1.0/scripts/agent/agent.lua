local State = require("scripts.core.state")
local Identity = require("scripts.core.identity")

local Agent = {}

local UNSAFE_STAND_TYPES = {
  "transport-belt", "underground-belt", "splitter", "loader", "loader-1x1", "linked-belt",
  "straight-rail", "half-diagonal-rail", "curved-rail-a", "curved-rail-b",
  "legacy-straight-rail", "legacy-curved-rail"
}

local function valid(entity)
  return entity and entity.valid
end

local function destroy_label(root)
  if root.agent.label and root.agent.label.valid then
    root.agent.label.destroy()
  end
  root.agent.label = nil
end

local function destroy_map_tag(root)
  if root.agent.map_tag and root.agent.map_tag.valid then root.agent.map_tag.destroy() end
  root.agent.map_tag = nil
end

local function update_map_tag(root, entity)
  local tag = root.agent.map_tag
  if not tag or not tag.valid then
    root.agent.map_tag = entity.force.add_chart_tag(entity.surface, {
      position = entity.position,
      text = Identity.name()
    })
    return
  end
  tag.text = Identity.name()
  if tag.surface ~= entity.surface then tag.surface = entity.surface end
  tag.position = entity.position
end

local function character_name(root, player)
  if player.character and player.character.valid then return player.character.name end
  local remembered = root.agent.character_name
  if remembered and prototypes.entity[remembered] and prototypes.entity[remembered].type == "character" then
    return remembered
  end
  local names = {}
  for name, prototype in pairs(prototypes.entity) do
    if prototype.type == "character" then names[#names + 1] = name end
  end
  table.sort(names)
  root.agent.character_name = names[1]
  return names[1]
end

local function physical_location(player)
  if player.character and player.character.valid then
    return player.character.surface, player.character.position
  end
  return player.physical_surface or player.surface, player.physical_position or player.position
end

local function unsafe_stand_position(surface, position)
  return surface.find_entities_filtered({
    position = position,
    radius = 0.8,
    type = UNSAFE_STAND_TYPES,
    limit = 1
  })[1] ~= nil
end

-- Characters do not collide with belts, so find_non_colliding_position may
-- legally put an idle Alina on a fast line and let it carry her across the
-- factory. Search a small deterministic ring for a genuinely stable standing
-- tile; the ordinary collision finder remains the final authority.
local function stable_stand_position(surface, prototype_name, anchor, radius)
  radius = radius or 12
  for ring = 0, math.floor(radius) do
    for dx = -ring, ring do
      for _, dy in ipairs(ring == 0 and {0} or {-ring, ring}) do
        local desired = {x = anchor.x + dx, y = anchor.y + dy}
        local candidate = surface.find_non_colliding_position(prototype_name, desired, 0.25, 0.25)
        if candidate and not unsafe_stand_position(surface, candidate) then return candidate end
      end
    end
    if ring > 0 then
      for dy = -ring + 1, ring - 1 do
        for _, dx in ipairs({-ring, ring}) do
          local desired = {x = anchor.x + dx, y = anchor.y + dy}
          local candidate = surface.find_non_colliding_position(prototype_name, desired, 0.25, 0.25)
          if candidate and not unsafe_stand_position(surface, candidate) then return candidate end
        end
      end
    end
  end
  return nil
end

function Agent.get()
  local root = State.ensure()
  if valid(root.agent.entity) then return root.agent.entity end
  return nil
end

function Agent.update_markers()
  local root = State.ensure()
  local entity = valid(root.agent.entity) and root.agent.entity or nil
  if not entity then return false end
  if root.agent.label and root.agent.label.valid then root.agent.label.text = Identity.name() end
  update_map_tag(root, entity)
  return true
end

function Agent.ensure(player_index)
  local root = State.ensure()
  if valid(root.agent.entity) then return root.agent.entity end

  local player = game.get_player(player_index or root.agent.owner_player_index or 1)
  if not player or not player.valid then return nil end

  local prototype_name = character_name(root, player)
  if not prototype_name then return nil end
  local surface, player_position = physical_location(player)
  local position = stable_stand_position(surface, prototype_name,
    {x = player_position.x + 3, y = player_position.y}, 12)
  if not position then return nil end

  local entity = surface.create_entity({
    name = prototype_name,
    position = position,
    force = player.force,
    create_build_effect_smoke = false
  })
  if not entity then return nil end

  entity.color = {r = 0.65, g = 0.25, b = 0.85, a = 1}
  root.agent.entity = entity
  root.agent.owner_player_index = player.index
  root.agent.respawn_tick = nil
  destroy_label(root)
  root.agent.label = rendering.draw_text({
    text = Identity.name(),
    surface = entity.surface,
    target = {entity = entity, offset = {0, -2.6}},
    color = {r = 0.9, g = 0.55, b = 1.0, a = 1},
    alignment = "center",
    scale_with_zoom = false
  })
  update_map_tag(root, entity)
  return entity
end

function Agent.stop()
  local entity = Agent.get()
  if not entity then return end
  local vehicle = entity.vehicle
  if vehicle and vehicle.valid and vehicle.type == "spider-vehicle" and vehicle.get_driver() == entity then
    vehicle.autopilot_destination = nil
    vehicle.stop_spider()
  end
  entity.walking_state = {walking = false, direction = defines.direction.north}
  entity.mining_state = {mining = false}
  entity.selected = nil
end

function Agent.park()
  local entity = Agent.get()
  if not entity or entity.vehicle or not unsafe_stand_position(entity.surface, entity.position) then return false end
  local position = stable_stand_position(entity.surface, entity.name, entity.position, 6)
  if not position then return false end
  local moved = entity.teleport(position, entity.surface)
  if moved then update_map_tag(State.ensure(), entity) end
  return moved
end

function Agent.recall(player_index)
  local player = game.get_player(player_index)
  if not player or not player.valid then return false end
  local entity = Agent.ensure(player.index)
  if not entity then return false end

  local surface, player_position = physical_location(player)
  local position = stable_stand_position(surface, entity.name,
    {x = player_position.x + 3, y = player_position.y}, 12)
  if not position then return false end
  Agent.stop()
  local vehicle = entity.vehicle
  if vehicle and vehicle.valid and vehicle.get_driver() == entity then vehicle.set_driver(nil) end
  local teleported = entity.teleport(position, surface)
  if teleported then update_map_tag(State.ensure(), entity) end
  return teleported
end

function Agent.disable_editor(player_index)
  local player = game.get_player(player_index)
  if not player or not player.valid or not player.connected then return false, "player_unavailable" end
  if player.controller_type ~= defines.controllers.editor then
    return player.character ~= nil, "not_editor"
  end

  local root = State.ensure()
  local prototype_name = character_name(root, player)
  local surface, current_position = physical_location(player)
  if not prototype_name or not surface then return false, "character_prototype_missing" end
  local position = surface.find_non_colliding_position(prototype_name, current_position, 16, 0.5)
  if not position then return false, "spawn_position_missing" end
  local character = surface.create_entity({
    name = prototype_name,
    position = position,
    force = player.force,
    create_build_effect_smoke = false
  })
  if not character then return false, "character_creation_failed" end
  player.set_controller({type = defines.controllers.character, character = character})
  if player.character ~= character then
    if character.valid then character.destroy() end
    return false, "controller_switch_failed"
  end
  return true, "editor_disabled"
end

function Agent.on_died(entity)
  local root = State.ensure()
  if not root.agent.entity or root.agent.entity ~= entity then return false end

  destroy_label(root)
  destroy_map_tag(root)
  root.agent.entity = nil
  root.agent.death_count = root.agent.death_count + 1
  root.agent.respawn_tick = game.tick + 600
  return true
end

function Agent.try_respawn()
  local root = State.ensure()
  if root.agent.respawn_tick and game.tick >= root.agent.respawn_tick then
    return Agent.ensure(root.agent.owner_player_index)
  end
  return Agent.get()
end

function Agent.needs_tick()
  local root = State.ensure()
  return root.agent.respawn_tick ~= nil
end

return Agent
