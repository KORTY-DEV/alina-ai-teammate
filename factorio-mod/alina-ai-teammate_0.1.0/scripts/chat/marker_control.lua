local State = require("scripts.core.state")

local MarkerControl = {}

local function lower_ru(text)
  local map = {
    ["А"]="а",["Б"]="б",["В"]="в",["Г"]="г",["Д"]="д",["Е"]="е",["Ё"]="ё",
    ["Ж"]="ж",["З"]="з",["И"]="и",["Й"]="й",["К"]="к",["Л"]="л",["М"]="м",
    ["Н"]="н",["О"]="о",["П"]="п",["Р"]="р",["С"]="с",["Т"]="т",["У"]="у",
    ["Ф"]="ф",["Х"]="х",["Ц"]="ц",["Ч"]="ч",["Ш"]="ш",["Щ"]="щ",["Ъ"]="ъ",
    ["Ы"]="ы",["Ь"]="ь",["Э"]="э",["Ю"]="ю",["Я"]="я"
  }
  text = text or ""
  for upper, lower in pairs(map) do text = string.gsub(text, upper, lower) end
  return string.lower(text)
end

local function distance_squared(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end

local function alina_tag_number(root)
  return root.agent.map_tag and root.agent.map_tag.valid and root.agent.map_tag.tag_number or nil
end

local function tag_goal(tag)
  return {
    surface_index = tag.surface.index,
    position = {x = tag.position.x, y = tag.position.y},
    tag_number = tag.tag_number,
    text = tag.text ~= "" and tag.text or nil,
    icon = tag.icon and {type = tag.icon.type, name = tag.icon.name} or nil,
    created_tick = game.tick
  }
end

local function gps_goal(player, text)
  local x, y, surface_name = string.match(text, "%[gps=([%-%.%d]+),([%-%.%d]+),?([^%]]*)%]")
  if not x or not y then return nil end
  local surface = surface_name ~= "" and game.get_surface(surface_name) or player.surface
  if not surface then return nil end
  return {
    surface_index = surface.index,
    position = {x = tonumber(x), y = tonumber(y)},
    text = "GPS",
    created_tick = game.tick
  }
end

function MarkerControl.resolve(player, text)
  local gps = gps_goal(player, text)
  if gps then return gps end
  local root = State.ensure()
  local tags = player.force.find_chart_tags(player.surface)
  local agent_tag = alina_tag_number(root)
  local candidates = {}
  for _, tag in ipairs(tags) do
    if tag.valid and tag.tag_number ~= agent_tag then candidates[#candidates + 1] = tag end
  end
  if #candidates == 0 then return nil, "marker_not_found" end

  local normalized = lower_ru(text)
  local named = {}
  for _, tag in ipairs(candidates) do
    local label = lower_ru(tag.text)
    if label ~= "" and string.find(normalized, label, 1, true) then named[#named + 1] = tag end
  end
  if #named == 1 then return tag_goal(named[1]) end
  if #named > 1 then candidates = named end

  local recent_number = root.autonomy.last_marker_by_player[player.index]
  if recent_number then
    for _, tag in ipairs(candidates) do
      if tag.tag_number == recent_number then return tag_goal(tag) end
    end
  end
  if #candidates == 1 then return tag_goal(candidates[1]) end

  table.sort(candidates, function(a, b)
    return distance_squared(a.position, player.position) < distance_squared(b.position, player.position)
  end)
  return tag_goal(candidates[1]), "nearest_marker"
end

function MarkerControl.store(goal)
  State.ensure().autonomy.marker_goal = goal
end

function MarkerControl.clear()
  State.ensure().autonomy.marker_goal = nil
end

function MarkerControl.on_added_or_modified(event)
  if not event.player_index or not event.tag or not event.tag.valid then return end
  State.ensure().autonomy.last_marker_by_player[event.player_index] = event.tag.tag_number
end

function MarkerControl.on_removed(event)
  local root = State.ensure()
  if event.tag and root.autonomy.marker_goal
      and root.autonomy.marker_goal.tag_number == event.tag.tag_number then
    root.autonomy.marker_goal = nil
  end
  for player_index, tag_number in pairs(root.autonomy.last_marker_by_player) do
    if event.tag and tag_number == event.tag.tag_number then
      root.autonomy.last_marker_by_player[player_index] = nil
    end
  end
end

return MarkerControl
