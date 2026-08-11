local EventBus = require("scripts.core.event_bus")
local Identity = require("scripts.core.identity")
local LocalPlanner = require("scripts.autonomy.local_planner")
local Locale = require("scripts.core.locale")
local State = require("scripts.core.state")
local WorldModel = require("scripts.sensors.world_model")

local Advisor = {}

local TICKS_PER_MINUTE = 60 * 60
local MIN_MINUTES = 40
local INTERVAL_CHOICES = 51 -- inclusive 40..90 minutes
local RECENT_LIMIT = 3

local function enabled()
  local value = settings.global["alina-periodic-advice-enabled"]
  return not value or value.value
end

local function owner(root, requested_index)
  local requested = requested_index and game.get_player(requested_index) or nil
  if requested and requested.valid then return requested end
  local assigned = root.agent.owner_player_index and game.get_player(root.agent.owner_player_index) or nil
  if assigned and assigned.valid and assigned.connected then return assigned end
  return game.connected_players[1]
end

local function schedule(root, player)
  local state = root.advisor
  state.sequence = (state.sequence or 0) + 1
  -- Deterministic pseudo-jitter is multiplayer-safe and avoids every save
  -- producing advice at the same round hour. Only whole game minutes matter.
  local minute = MIN_MINUTES
    + ((state.sequence * 17 + (player and player.index or 0) * 7
      + math.floor(game.tick / TICKS_PER_MINUTE)) % INTERVAL_CHOICES)
  state.next_tick = game.tick + minute * TICKS_PER_MINUTE
  state.next_interval_minutes = minute
  return minute
end

local function recently_used(state, key)
  for _, recent in ipairs(state.recent_keys or {}) do
    if recent == key then return true end
  end
  return false
end

local function remember(state, key)
  state.recent_keys[#state.recent_keys + 1] = key
  while #state.recent_keys > RECENT_LIMIT do table.remove(state.recent_keys, 1) end
  state.last_advice_key = key
  state.last_advice_tick = game.tick
end

local function rounded(value)
  return math.floor((tonumber(value) or 0) + 0.5)
end

local function choose_advice(player, scan, state, ignore_recent)
  if scan.power and scan.power.valid then
    local key = "power:" .. tostring(scan.power.unit_number or scan.power.name)
    if ignore_recent or not recently_used(state, key) then
      return key, {"", "Совет: проверьте питание у ", Locale.entity_at(scan.power),
        ". Машина уже показывает проблему с энергией; лучше устранить её до расширения линии."}
    end
  end

  local deficits, activity = LocalPlanner.production_diagnostics(player, scan)
  for _, row in ipairs(deficits or {}) do
    local key = "deficit:" .. row.item
    if ignore_recent or not recently_used(state, key) then
      return key, {"", "Совет: сейчас узкое место — ", Locale.item(row.item),
        ". Выпуск около ", tostring(rounded(row.produced)), "/мин, расход ",
        tostring(rounded(row.consumed)), "/мин. Стоит расширить цепочку с запасом 15–25%."}
    end
  end

  for _, row in ipairs(activity or {}) do
    local key = "watch:" .. row.item
    if ignore_recent or not recently_used(state, key) then
      return key, {"", "Совет: самая нагруженная из известных цепочек — ", Locale.item(row.item),
        " (выпуск ", tostring(rounded(row.produced)), "/мин, расход ",
        tostring(rounded(row.consumed)), "/мин). При следующем расширении оставьте 15–25% резерва."}
    end
  end

  local key = "indexed:" .. tostring(math.floor((scan.indexed or 0) / 100))
  if (scan.indexed or 0) > 0 and (ignore_recent or not recently_used(state, key)) then
    return key, {"", "Совет: по текущей статистике явного дефицита не видно. Не сносите старые линии без замера замены; ",
      tostring(scan.indexed), " производственных объектов уже учтены в модели базы."}
  end
  return nil, nil
end

local function broadcast(player, message)
  for _, connected in pairs(game.connected_players) do
    if connected.valid and connected.force == player.force then Identity.print(connected, message) end
  end
end

function Advisor.initialize()
  local root = State.ensure()
  if not root.advisor.next_tick then schedule(root, owner(root)) end
end

function Advisor.give_now(player_index, ignore_recent)
  local root = State.ensure()
  local player = owner(root, player_index)
  if not player then return {ok = false, result = "player_missing"} end
  root.metrics.advisor_checks = (root.metrics.advisor_checks or 0) + 1
  local scan = WorldModel.machine_snapshot(player, 768)
  local key, message = choose_advice(player, scan, root.advisor, ignore_recent == true)
  local interval = schedule(root, player)
  if not key then
    EventBus.emit("advisor_no_change", {indexed = scan.indexed or 0, next_minutes = interval})
    return {ok = false, result = "no_new_advice", next_minutes = interval}
  end
  remember(root.advisor, key)
  root.metrics.advisor_messages = (root.metrics.advisor_messages or 0) + 1
  broadcast(player, message)
  EventBus.emit("player_advice_given", {
    advice_key = key,
    indexed = scan.indexed or 0,
    next_minutes = interval
  })
  return {ok = true, advice_key = key, next_minutes = interval}
end

function Advisor.on_nth_tick()
  local root = State.ensure()
  if not enabled() then
    if not root.advisor.next_tick or root.advisor.next_tick <= game.tick then schedule(root, owner(root)) end
    return
  end
  if not root.advisor.next_tick then schedule(root, owner(root)); return end
  if game.tick < root.advisor.next_tick then return end
  Advisor.give_now(nil, false)
end

return Advisor
