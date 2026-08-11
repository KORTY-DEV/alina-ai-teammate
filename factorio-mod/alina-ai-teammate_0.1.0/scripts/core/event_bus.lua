local State = require("scripts.core.state")

local EventBus = {}

local function bridge_port()
  local value = settings.global["alina-bridge-udp-port"]
  return value and value.value or 34198
end

local function send_to_bridge(json, player_index)
  if not player_index or player_index <= 0 then return end
  -- With --enable-lua-udp, only the instance belonging to this player performs
  -- the localhost side effect. The game state itself is still changed only when
  -- the eventual reply is introduced by recv_udp as an input action.
  pcall(function()
    helpers.send_udp(bridge_port(), json, player_index)
  end)
end

function EventBus.emit(event_name, payload, player_index)
  local root = State.ensure()
  local envelope = {
    version = 1,
    event_id = root.next_event_id,
    tick = game.tick,
    event = event_name,
    payload = payload or {}
  }

  root.next_event_id = root.next_event_id + 1
  root.metrics.event_writes = root.metrics.event_writes + 1
  local json = helpers.table_to_json(envelope)

  -- Keep the journal as a debug/audit trace. It is no longer the live playable
  -- transport, so a filesystem hiccup cannot block planning.
  pcall(function()
    helpers.write_file("alina/events.jsonl", json .. "\n", true, player_index)
  end)
  send_to_bridge(json, player_index)
  return envelope.event_id
end

function EventBus.emit_debug(event_name, payload, player_index)
  local verbosity = settings.global["alina-ui-verbosity"]
  if not verbosity or verbosity.value ~= "debug" then return nil end
  return EventBus.emit(event_name, payload, player_index)
end

function EventBus.session_started()
  return EventBus.emit("session_started", {
    mod_version = script.active_mods["alina-ai-teammate"],
    factorio_version = script.active_mods.base,
    active_mods = script.active_mods
  })
end

return EventBus
