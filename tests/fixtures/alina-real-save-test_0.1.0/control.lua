local RESULT_PATH = "alina/real-save-result.json"
local COMMAND_DELAY = 120
local TIMEOUT_TICKS = 60000

local function compact_snapshot(snapshot)
  local factory = snapshot and snapshot.factory or {}
  local known = snapshot and snapshot.known_factory or {}
  return {
    surface = snapshot and snapshot.surface or nil,
    machine_count = factory.machine_count or 0,
    infrastructure_count = factory.infrastructure_count or 0,
    indexed_entities = known.entities or 0,
    indexed_chunks = known.scanned_chunks or 0,
    queued_chunks = known.queued_chunks or 0
  }
end

local function write_result(state, ok, reason, status)
  if state.done then return end
  state.done = true
  local final_snapshot = remote.call("alina_ai", "snapshot", state.player_index)
  helpers.write_file(RESULT_PATH, helpers.table_to_json({
    ok = ok,
    reason = reason,
    command_result = state.command_result,
    observed_task_type = state.observed_task_type,
    first_task_type = state.first_task_type,
    first_task_delay = state.first_task_tick and (state.first_task_tick - state.command_tick) or nil,
    last_task = status and status.last_task or nil,
    before = state.before,
    after = final_snapshot.ok and compact_snapshot(final_snapshot.snapshot) or nil,
    tick = game.tick
  }), false)
end

local function initialize()
  storage.alina_real_save_test = {
    started_tick = game.tick,
    player_index = 1,
    command_sent = false,
    done = false
  }
end

script.on_init(initialize)
script.on_configuration_changed(function()
  if not storage.alina_real_save_test then initialize() end
end)

script.on_event(defines.events.on_tick, function(event)
  local state = storage.alina_real_save_test
  if not state or state.done or event.tick % 30 ~= 0 then return end
  local player = game.get_player(state.player_index)
  if not player or not player.valid then
    write_result(state, false, "player_missing")
    return
  end

  if not state.agent_ready then
    state.agent_ready = remote.call("alina_ai", "recall", player.index) == true
    if not state.agent_ready and event.tick - state.started_tick > 600 then
      write_result(state, false, "agent_missing")
    end
    return
  end

  if not state.command_sent and event.tick - state.started_tick >= COMMAND_DELAY then
    local before = remote.call("alina_ai", "snapshot", player.index)
    state.before = before.ok and compact_snapshot(before.snapshot) or nil
    local result = remote.call("alina_ai", "address", player.index, "Аля, продолжай развивать базу")
    state.command_result = result
    if not result or not result.ok or result.result ~= "local_control" then
      write_result(state, false, "command_rejected")
      return
    end
    state.command_sent = true
    state.command_tick = event.tick
    return
  end

  if not state.command_sent then return end
  local status = remote.call("alina_ai", "status")
  if status.task then
    if not state.first_task_type then
      state.first_task_type = status.task.type
      state.first_task_tick = event.tick
    end
    state.observed_task_type = status.task.type
    if status.task.type ~= "expand_line" and status.task.type ~= "repair_power" then
      write_result(state, false, "non_factory_task_took_priority", status)
      error("Alina selected a non-factory task after an explicit development command: "
        .. tostring(status.task.type))
    end
  elseif status.last_task and status.last_task.finished_tick
      and status.last_task.finished_tick >= state.command_tick then
    -- A short preflight rejection can start and finish between the fixture's
    -- 30-tick polls.  Count it as an observed factory attempt, then keep
    -- waiting for Alina's alternative plan and a verified useful change.
    if not state.first_task_type then
      state.first_task_type = status.last_task.type
      state.first_task_tick = status.last_task.created_tick or status.last_task.finished_tick
    end
    state.observed_task_type = status.last_task.type
    local useful = status.last_task.status == "completed"
      and (status.last_task.type == "expand_line" or status.last_task.type == "repair_power")
    if useful then
      write_result(state, true, "verified_factory_change", status)
      return
    end
  end

  if not state.first_task_type and event.tick - state.command_tick >= 3600 then
    write_result(state, false, "factory_task_start_timeout", status)
    error("Alina did not start a factory task within one game minute after the refresh budget.")
  end

  if event.tick - state.command_tick >= TIMEOUT_TICKS then
    write_result(state, false, "factory_change_timeout", status)
    error("Alina did not complete a verified factory change on the copied save: "
      .. helpers.table_to_json(status))
  end
end)
