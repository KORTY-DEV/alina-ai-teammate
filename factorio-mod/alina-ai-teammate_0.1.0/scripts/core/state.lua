local State = {}

local function defaults()
  return {
    schema_version = 1,
    next_event_id = 1,
    next_task_id = 1,
    agent = {
      entity = nil,
      owner_player_index = nil,
      personal_vehicle_unit = nil,
      label = nil,
      map_tag = nil,
      respawn_tick = nil,
      death_count = 0
    },
    task = {
      current = nil,
      history = {}
    },
    bridge = {
      status = "waiting",
      last_request_tick = nil,
      last_response_tick = nil,
      last_heartbeat_tick = nil,
      udp_disabled = nil
    },
    pending_requests = {},
    confirmation = nil,
    paused = false,
    autonomy = {
      enabled = true,
      development_focus = true,
      development_focus_until = nil,
      foundation_audit = nil,
      foundation_audit_tick = 0,
      next_tick = 0,
      pending_request_id = nil,
      last_request_tick = nil,
      last_response_tick = nil,
      last_action_tick = nil,
      last_research_tick = nil,
      research_retry_tick = nil,
      research_override_until = nil,
      research_hold = false,
      selected_research = nil,
      research_hold_until = nil,
      research_priority = nil,
      player_research = nil,
      forbidden_items = {},
      marker_goal = nil,
      last_marker_by_player = {},
      suppressed_items = {},
      expansion_cooldown = {},
      item_cooldown = {},
      loadout_cooldown = {},
      power_cooldown = {},
      power_retry_tick = nil,
      priority_item = nil,
      priority_fluid = nil,
      fluid_upstream_stack = {},
      fluid_cooldown = {},
      priority_options = nil,
      status_text = "Проверяю базу",
      last_activity = nil,
      last_inspected_unit = nil,
      last_inspection_tick = nil,
      session_started_tick = nil
    },
    player_activity = {},
    protected_areas = {},
    owned_entities = {},
    social = {
      player_actions = {},
      last_praise_by_player = {}
    },
    advisor = {
      next_tick = nil,
      sequence = 0,
      recent_keys = {},
      last_advice_tick = nil,
      last_advice_key = nil
    },
    world_model = {version = 2, surfaces = {}},
    catalog_export = nil,
    recipe_index = nil,
    prototype_index = nil,
    metrics = {
      event_writes = 0,
      sensor_scans = 0,
      executor_active_ticks = 0,
      catalog_rows = 0,
      plans_accepted = 0,
      plans_rejected = 0,
      path_requests = 0,
      rail_safety_scans = 0,
      train_waits = 0,
      spider_routes = 0,
      spider_fallbacks = 0,
      factory_scans = 0,
      factory_entities_examined = 0,
      recipe_index_rows = 0,
      prototype_index_rows = 0,
      autonomy_requests = 0,
      autonomy_noops = 0,
      autonomy_actions = 0,
      autonomy_superseded = 0,
      world_model_chunks = 0,
      world_model_entities = 0,
      advisor_checks = 0,
      advisor_messages = 0
    }
  }
end

function State.ensure()
  if not storage.alina then
    storage.alina = defaults()
  end

  local root = storage.alina
  root.pending_requests = root.pending_requests or {}
  root.protected_areas = root.protected_areas or {}
  root.owned_entities = root.owned_entities or {}
  root.social = root.social or {player_actions = {}, last_praise_by_player = {}}
  root.social.player_actions = root.social.player_actions or {}
  root.social.last_praise_by_player = root.social.last_praise_by_player or {}
  root.advisor = root.advisor or defaults().advisor
  root.advisor.recent_keys = root.advisor.recent_keys or {}
  root.advisor.sequence = root.advisor.sequence or 0
  root.player_activity = root.player_activity or {}
  root.world_model = root.world_model or {version = 2, surfaces = {}}
  root.world_model.surfaces = root.world_model.surfaces or {}
  root.autonomy = root.autonomy or defaults().autonomy
  root.autonomy.suppressed_items = root.autonomy.suppressed_items or {}
  if root.autonomy.enabled == nil then root.autonomy.enabled = true end
  if root.autonomy.development_focus == nil and root.autonomy.development_focus_until == nil then
    root.autonomy.development_focus = true
  end
  root.autonomy.foundation_audit_tick = root.autonomy.foundation_audit_tick or 0
  root.autonomy.expansion_cooldown = root.autonomy.expansion_cooldown or {}
  root.autonomy.item_cooldown = root.autonomy.item_cooldown or {}
  root.autonomy.loadout_cooldown = root.autonomy.loadout_cooldown or {}
  root.autonomy.power_cooldown = root.autonomy.power_cooldown or {}
  root.autonomy.fluid_upstream_stack = root.autonomy.fluid_upstream_stack or {}
  root.autonomy.fluid_cooldown = root.autonomy.fluid_cooldown or {}
  root.autonomy.forbidden_items = root.autonomy.forbidden_items or {}
  root.autonomy.last_marker_by_player = root.autonomy.last_marker_by_player or {}
  if root.autonomy.research_hold == nil then root.autonomy.research_hold = false end
  if root.autonomy.status_text == nil then root.autonomy.status_text = "Проверяю базу" end
  root.metrics = root.metrics or defaults().metrics
  for name, value in pairs(defaults().metrics) do
    if root.metrics[name] == nil then root.metrics[name] = value end
  end
  root.task = root.task or {current = nil, history = {}}
  root.task.history = root.task.history or {}
  root.bridge = root.bridge or {status = "waiting"}
  if root.bridge.last_heartbeat_tick == nil then root.bridge.last_heartbeat_tick = nil end
  root.agent = root.agent or defaults().agent
  if root.agent.personal_vehicle_unit == nil then root.agent.personal_vehicle_unit = nil end
  if root.agent.map_tag == nil then root.agent.map_tag = nil end
  return root
end

function State.reset_transient()
  local root = State.ensure()
  root.bridge.status = "waiting"
  root.bridge.last_heartbeat_tick = nil
  root.bridge.udp_disabled = nil
  -- Requests and confirmations are transport-session state. Keeping them across a
  -- reload leaves the GUI stuck at waiting_response even though the old reply
  -- can no longer be trusted. Long-lived task/history state remains in the save.
  root.pending_requests = {}
  root.autonomy.pending_request_id = nil
  root.autonomy.session_started_tick = game.tick
  root.confirmation = nil
end

function State.push_history(task)
  local root = State.ensure()
  local history = root.task.history
  history[#history + 1] = task
  while #history > 50 do
    table.remove(history, 1)
  end
end

return State
