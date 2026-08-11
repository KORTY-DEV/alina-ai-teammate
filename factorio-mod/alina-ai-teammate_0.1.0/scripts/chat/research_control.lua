local State = require("scripts.core.state")
local Locale = require("scripts.core.locale")
local Identity = require("scripts.core.identity")

local ResearchControl = {}

local HOLD_MARKERS = {
  "не выбирай исслед", "не ставь исслед", "не трогай исслед", "не исследуй",
  "пока без исслед", "не занимайся исслед", "отключи выбор исслед"
}
local RESUME_MARKERS = {
  "можешь выбирать исслед", "снова выбирай исслед", "выбирай исслед",
  "можешь снова выбирать исслед", "снова можешь выбирать исслед",
  "занимайся исслед", "продолжай исслед", "вернись к исслед", "разрешаю исслед"
}
local PRIORITY_MARKERS = {
  "исследуй ", "исследование в приоритете", "приоритет исследования",
  "приоритет в исследованиях", "поставь исследование", "выбери исследование"
}
local TECHNOLOGY_ALIASES = {
  {stems = {"автомат"}, names = {"automation", "automation-2", "automation-3"}},
  {stems = {"логист"}, names = {"logistics", "logistics-2", "logistics-3"}},
  {stems = {"военн", "оруж"}, names = {"military", "military-2", "military-3", "military-4"}},
  {stems = {"электрон"}, names = {"electronics", "advanced-electronics", "advanced-electronics-2"}},
  {stems = {"нефт"}, names = {"oil-processing", "advanced-oil-processing"}},
  {stems = {"робот"}, names = {"robotics", "construction-robotics", "logistic-robotics"}},
  {stems = {"брон"}, names = {"modular-armor", "power-armor", "power-armor-mk2"}},
  {stems = {"солнеч"}, names = {"solar-energy"}},
  {stems = {"атом", "ядер"}, names = {"nuclear-power"}},
  {stems = {"железнод", "поезд"}, names = {"railway"}}
}

local function contains_any(text, values)
  for _, value in ipairs(values) do
    if string.find(text, value, 1, true) then return true end
  end
  return false
end

local function normalized_name(name)
  return string.gsub(string.lower(name or ""), "[-_]", " ")
end

local function duration_ticks(text)
  if string.find(text, "полчас", 1, true) then return 30 * 60 * 60 end
  local amount = tonumber(string.match(text, "(%d+)") or "")
  if not amount then return nil end
  local ticks = nil
  if string.find(text, "час", 1, true) then ticks = amount * 60 * 60 * 60 end
  if string.find(text, "мин", 1, true) then ticks = amount * 60 * 60 end
  if string.find(text, "сек", 1, true) then ticks = amount * 60 end
  return ticks and math.max(60, math.min(ticks, 24 * 60 * 60 * 60)) or nil
end

local function prerequisites_ready(technology)
  for _, prerequisite in pairs(technology.prerequisites or {}) do
    if not prerequisite.researched then return false end
  end
  return true
end

local function technology_score(technology)
  local ready_penalty = prerequisites_ready(technology) and 0 or 1000000
  return ready_penalty + (technology.research_unit_count or 100000)
end

local function resolve_technology(force, text)
  local tagged = string.match(text, "%[technology=([^%]]+)%]")
  if tagged and force.technologies[tagged] and not force.technologies[tagged].researched then return tagged end

  local candidates = {}
  for name, technology in pairs(force.technologies) do
    if technology.enabled and not technology.researched then
      local normalized = normalized_name(name)
      if string.find(text, normalized, 1, true) then
        candidates[#candidates + 1] = {name = name, score = technology_score(technology)}
      end
    end
  end
  for _, alias in ipairs(TECHNOLOGY_ALIASES) do
    if contains_any(text, alias.stems) then
      for _, name in ipairs(alias.names) do
        local technology = force.technologies[name]
        if technology and technology.enabled and not technology.researched then
          candidates[#candidates + 1] = {name = name, score = technology_score(technology)}
        end
      end
    end
  end
  table.sort(candidates, function(a, b)
    if a.score == b.score then return a.name < b.name end
    return a.score < b.score
  end)
  return candidates[1] and candidates[1].name or nil
end

local function set_hold(player, root, text)
  local ticks = duration_ticks(text)
  root.autonomy.research_hold = true
  root.autonomy.research_hold_source = ticks and "player_timed" or "player_chat"
  root.autonomy.research_hold_until = ticks and (game.tick + ticks) or nil
  root.autonomy.research_retry_tick = nil
  if ticks then
    local minutes = math.floor(ticks / 3600 + 0.5)
    Identity.print(player, "Хорошо. Новые исследования не выбираю " .. minutes
      .. " мин.; уже выбранное вами не меняю.")
  else
    Identity.print(player, "Хорошо. Текущее исследование не меняю, а новые не выбираю до вашего разрешения.")
  end
end

function ResearchControl.try_handle(player, text)
  local root = State.ensure()
  if contains_any(text, HOLD_MARKERS) then
    set_hold(player, root, text)
    return true, "research_hold"
  end
  if contains_any(text, RESUME_MARKERS) then
    root.autonomy.research_hold = false
    root.autonomy.research_hold_source = nil
    root.autonomy.research_hold_until = nil
    root.autonomy.research_override_until = nil
    root.autonomy.research_retry_tick = nil
    Identity.print(player, "Поняла. Если вы сами ничего не выбрали, снова занимаюсь исследованиями.")
    return true, "research_resumed"
  end
  if contains_any(text, PRIORITY_MARKERS) or string.find(text, "[technology=", 1, true) then
    local technology = resolve_technology(player.force, text)
    if not technology then
      Identity.print(player, "Не смогла однозначно определить технологию. Можно вставить её в чат Shift-кликом.")
      return true, "research_not_resolved"
    end
    root.autonomy.research_priority = technology
    root.autonomy.research_hold = false
    root.autonomy.research_hold_source = nil
    root.autonomy.research_hold_until = nil
    root.autonomy.research_override_until = nil
    root.autonomy.research_retry_tick = nil
    if player.force.current_research and root.autonomy.selected_research == player.force.current_research.name then
      root.autonomy.research_command_switching = true
      player.force.cancel_current_research()
      root.autonomy.research_command_switching = nil
      root.autonomy.selected_research = nil
    end
    Identity.print(player, {"", "Приняла приоритет исследования: ", Locale.technology(technology),
      ". Ваше собственное текущее исследование не заменяю."})
    return true, "research_priority"
  end
  return false, "not_research_control"
end

function ResearchControl.is_held(root)
  if root.autonomy.research_hold and root.autonomy.research_hold_source == "player_timed"
      and (root.autonomy.research_hold_until or math.huge) <= game.tick then
    root.autonomy.research_hold = false
    root.autonomy.research_hold_source = nil
    root.autonomy.research_hold_until = nil
    root.autonomy.research_retry_tick = nil
  end
  return root.autonomy.research_hold == true
end

local function next_prerequisite(technology, visiting)
  if technology.researched then return nil end
  visiting = visiting or {}
  if visiting[technology.name] then return nil end
  visiting[technology.name] = true
  local names = {}
  for name in pairs(technology.prerequisites or {}) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local prerequisite = technology.prerequisites[name]
    if not prerequisite.researched then
      local nested = next_prerequisite(prerequisite, visiting)
      if nested then return nested end
    end
  end
  if technology.enabled and prerequisites_ready(technology) and #technology.research_unit_ingredients > 0 then
    return technology
  end
  return nil
end

function ResearchControl.priority_candidate(force, root)
  local name = root.autonomy.research_priority
  if not name then return nil end
  local technology = force.technologies[name]
  if not technology or technology.researched then
    root.autonomy.research_priority = nil
    return nil
  end
  return next_prerequisite(technology)
end

local function science_flow(player, item_name)
  local stats = player.force.get_item_production_statistics(player.surface)
  return stats.get_flow_count({
    name = item_name,
    category = "input",
    precision_index = defines.flow_precision_index.one_minute
  }) or 0
end

local function autonomous_score(player, technology)
  local missing, ingredients = 0, 0
  for _, ingredient in ipairs(technology.research_unit_ingredients or {}) do
    ingredients = ingredients + 1
    if science_flow(player, ingredient.name) <= 0.01 then missing = missing + 1 end
  end
  local name = string.lower(technology.name)
  local strategic = 0
  if string.find(name, "planet%-discovery") then strategic = strategic + 300000 end
  if string.find(name, "prometh") then strategic = strategic + 500000 end
  if technology.upgrade then strategic = strategic + 100000 end
  if string.find(name, "artillery") or string.find(name, "weapon") or string.find(name, "damage") then
    strategic = strategic + 50000
  end
  local essential = technology.prototype.essential and -200000 or 0
  return missing * 1000000 + ingredients * 10000
    + (technology.research_unit_count or 100000) + strategic + essential
end

function ResearchControl.select_next(player)
  local root = State.ensure()
  if not player or not player.valid or ResearchControl.is_held(root) then return false end
  if player.force.current_research then return false end
  if (root.autonomy.research_retry_tick or 0) > game.tick then return false end
  if root.autonomy.last_research_tick and game.tick - root.autonomy.last_research_tick < 600 then return false end

  local candidates = {}
  for name, technology in pairs(player.force.technologies) do
    if technology.enabled and not technology.researched
        and #technology.research_unit_ingredients > 0 and prerequisites_ready(technology) then
      candidates[#candidates + 1] = {name = name, score = autonomous_score(player, technology)}
    end
  end
  table.sort(candidates, function(a, b)
    if a.score == b.score then return a.name < b.name end
    return a.score < b.score
  end)
  local priority = ResearchControl.priority_candidate(player.force, root)
  local selected = priority and {name = priority.name} or candidates[1]
  if not selected then
    root.autonomy.research_retry_tick = game.tick + 3600
    return false
  end

  root.autonomy.research_requesting = selected.name
  local added = player.force.add_research(selected.name)
  if not added then
    root.autonomy.research_requesting = nil
    root.autonomy.research_retry_tick = game.tick + 600
    return false
  end
  root.autonomy.last_research_tick = game.tick
  root.autonomy.research_retry_tick = nil
  root.autonomy.selected_research = selected.name
  root.autonomy.last_activity = "Выбрала исследование " .. selected.name
  return true
end

function ResearchControl.on_nth_tick()
  local root = State.ensure()
  local player = root.agent.owner_player_index and game.get_player(root.agent.owner_player_index)
    or game.connected_players[1]
  if player and player.connected then ResearchControl.select_next(player) end
end

function ResearchControl.on_cancelled(event)
  local root = State.ensure()
  if root.autonomy.research_command_switching then return end
  if event.research and root.autonomy.selected_research == event.research.name then
    root.autonomy.selected_research = nil
  end
  if root.autonomy.research_hold_source == "player_chat"
      or root.autonomy.research_hold_source == "player_timed" then return end
  root.autonomy.research_hold = true
  root.autonomy.research_hold_source = "player_cancelled"
  root.autonomy.research_hold_until = nil
end

function ResearchControl.on_started(event)
  local root = State.ensure()
  if not event.research then return end
  if root.autonomy.research_requesting == event.research.name then
    root.autonomy.selected_research = event.research.name
    root.autonomy.research_requesting = nil
    return
  end
  if root.autonomy.research_hold_source == "player_chat"
      or root.autonomy.research_hold_source == "player_timed" then return end
  root.autonomy.selected_research = nil
  root.autonomy.research_hold = true
  root.autonomy.research_hold_source = "player_selection"
  root.autonomy.player_research = event.research.name
end

function ResearchControl.on_finished(event)
  local root = State.ensure()
  if event.research and root.autonomy.selected_research == event.research.name then
    root.autonomy.selected_research = nil
  end
  if event.research and root.autonomy.player_research == event.research.name
      and root.autonomy.research_hold_source == "player_selection" then
    root.autonomy.player_research = nil
    root.autonomy.research_hold = false
    root.autonomy.research_hold_source = nil
  end
  if event.research and root.autonomy.research_priority == event.research.name then
    root.autonomy.research_priority = nil
  end
end

return ResearchControl
