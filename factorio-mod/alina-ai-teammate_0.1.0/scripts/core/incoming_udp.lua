local State = require("scripts.core.state")
local TaskManager = require("scripts.tasks.manager")
local Gui = require("scripts.gui.panel")
local Identity = require("scripts.core.identity")

local IncomingUdp = {}
local MAX_PACKET_BYTES = 60 * 1024

function IncomingUdp.poll()
  local root = State.ensure()
  if game.is_multiplayer() then
    root.bridge.status = "multiplayer_safe"
    root.bridge.udp_disabled = true
    return
  end
  if root.bridge.udp_disabled then return end
  local ok = pcall(function() helpers.recv_udp() end)
  if not ok then
    -- Normal launch without --enable-lua-udp: fail closed and stop polling until reload.
    root.bridge.udp_disabled = true
    if root.bridge.status == "waiting" then root.bridge.status = "udp_disabled" end
  end
end

function IncomingUdp.on_packet(event)
  if game.is_multiplayer() then return end
  local port_setting = settings.global["alina-bridge-udp-port"]
  local expected_source_port = port_setting and port_setting.value or 34198
  if event.source_port ~= expected_source_port then return end
  if type(event.payload) ~= "string" or #event.payload == 0 or #event.payload > MAX_PACKET_BYTES then return end
  local packet = helpers.json_to_table(event.payload)
  if type(packet) ~= "table" or packet.version ~= 1 then return end

  local root = State.ensure()
  root.bridge.udp_disabled = nil
  if packet.kind == "heartbeat" then
    if root.bridge.status ~= "waiting_response" then root.bridge.status = "connected" end
    root.bridge.last_heartbeat_tick = game.tick
    Gui.refresh_all()
    return
  end

  if packet.kind ~= "plan" or type(packet.plan) ~= "table" then return end
  local request_id = packet.plan.request_id
  if type(request_id) ~= "string" then return end

  -- UDP transport deliberately retries a tiny localhost plan a few times.
  -- Only the first datagram may consume a pending request; later copies are stale
  -- and must be ignored instead of turning the GUI into plan_rejected.
  if not root.pending_requests[request_id] then return end

  local json = helpers.table_to_json(packet.plan)
  local ok, result = TaskManager.submit_plan_json(json)
  if not ok then
    local player_index = event.player_index and event.player_index > 0 and event.player_index or nil
    local player = player_index and game.get_player(player_index) or nil
    if player then Identity.print(player, "План отклонён: " .. tostring(result)) end
  end
  Gui.refresh_all()
end

return IncomingUdp
