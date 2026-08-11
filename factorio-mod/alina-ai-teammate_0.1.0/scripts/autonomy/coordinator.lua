local State = require("scripts.core.state")
local LocalPlanner = require("scripts.autonomy.local_planner")

local Coordinator = {}

local START_DELAY_TICKS = 120       -- 2 seconds after load/resume
local IDLE_RECHECK_TICKS = 300      -- 5 seconds while idle; world model updates continuously
local STAGED_RECHECK_TICKS = 60     -- 1 second between bounded fallback planner stages

local function configured_idle_ticks()
  local configured = settings.global["alina-autonomy-interval-seconds"]
  return math.max(1800, (configured and configured.value or 180) * 60)
end

local function next_delay(root, reason)
  if reason == "resource_chain_pending" then return 1800 end
  -- After a safe preflight rejection, the failed product is already on
  -- cooldown.  Advance the bounded Upgrade -> Expansion -> Chain -> Fluid ->
  -- Assembly fallback quickly so another product starts instead of making the
  -- character appear idle.  This path runs only while a staged candidate is
  -- pending; normal observation remains at the low-frequency interval below.
  if root.autonomy.pending_development_candidate
      and type(reason) == "string"
      and string.find(reason, "development_candidate_", 1, true) == 1 then
    return STAGED_RECHECK_TICKS
  end
  if root.autonomy.development_focus or reason == "factory_refresh_pending"
      or reason == "fluid_upstream_pending" then
    return IDLE_RECHECK_TICKS
  end
  return configured_idle_ticks()
end

local function clear_legacy_pending(root)
  for request_id, pending in pairs(root.pending_requests or {}) do
    if pending and pending.source == "autonomous" then
      root.pending_requests[request_id] = nil
    end
  end
  root.autonomy.pending_request_id = nil
end

function Coordinator.initialize()
  local root = State.ensure()
  root.autonomy.enabled = root.autonomy.enabled ~= false
  root.autonomy.next_tick = game.tick + START_DELAY_TICKS
  clear_legacy_pending(root)
end

function Coordinator.schedule_soon(delay_ticks)
  local root = State.ensure()
  root.autonomy.enabled = true
  root.autonomy.next_tick = game.tick + (delay_ticks or START_DELAY_TICKS)
end

function Coordinator.request(player_index, manual)
  local root = State.ensure()
  root.paused = false
  root.autonomy.enabled = true
  root.autonomy.next_tick = game.tick
  local ok, result = LocalPlanner.run(player_index)
  if not ok then root.autonomy.next_tick = game.tick + next_delay(root, result) end
  return ok, result
end

function Coordinator.on_nth_tick()
  local root = State.ensure()
  if root.paused or root.autonomy.enabled == false or root.task.current then return end
  if game.tick < (root.autonomy.next_tick or 0) then return end
  local ok, reason = LocalPlanner.run()
  root.autonomy.last_request_tick = game.tick
  root.autonomy.next_tick = game.tick + (ok and IDLE_RECHECK_TICKS or next_delay(root, reason))
end

function Coordinator.supersede_for_player()
  local root = State.ensure()
  clear_legacy_pending(root)
  root.autonomy.next_tick = game.tick + IDLE_RECHECK_TICKS
end

return Coordinator
