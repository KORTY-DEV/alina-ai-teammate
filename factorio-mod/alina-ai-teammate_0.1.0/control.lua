local State = require("scripts.core.state")
local Names = require("scripts.core.names")
local EventBus = require("scripts.core.event_bus")
local Agent = require("scripts.agent.agent")
local Chat = require("scripts.chat.chat")
local TaskManager = require("scripts.tasks.manager")
local Executor = require("scripts.executor.executor")
local Conflict = require("scripts.conflict.manager")
local Catalog = require("scripts.sensors.catalog")
local Gui = require("scripts.gui.panel")
local Navigation = require("scripts.navigation.navigation")
local RecipeIndex = require("scripts.sensors.recipe_index")
local PrototypeIndex = require("scripts.sensors.prototype_index")
local Autonomy = require("scripts.autonomy.coordinator")
local World = require("scripts.sensors.world")
local IncomingUdp = require("scripts.core.incoming_udp")
local LineExpander = require("scripts.executor.line_expander")
local WorldModel = require("scripts.sensors.world_model")
local ResearchControl = require("scripts.chat.research_control")
local MarkerControl = require("scripts.chat.marker_control")
local Identity = require("scripts.core.identity")
local Social = require("scripts.core.social")
local Advisor = require("scripts.autonomy.advisor")
local LocalPlanner = require("scripts.autonomy.local_planner")

local PLAYABLE_POLICY_VERSION = 8

local function migrate_playable_policy()
  local root = State.ensure()
  if (root.playable_policy_version or 0) >= PLAYABLE_POLICY_VERSION then return end
  -- Old playable builds could leave a remote-hand-feeding/ghost task serialized
  -- in the save. Do not continue that task under the v7 world-model policy.
  if root.task.current then TaskManager.cancel("") end
  root.autonomy.suppressed_items = {}
  root.autonomy.item_cooldown = {}
  root.autonomy.priority_item = nil
  root.autonomy.development_focus = true
  root.autonomy.development_focus_until = nil
  root.autonomy.status_text = "Строю модель известной фабрики"
  root.autonomy.next_tick = game.tick + 60
  root.paused = false
  root.autonomy.enabled = true
  root.playable_policy_version = PLAYABLE_POLICY_VERSION
end

local function auto_spawn_enabled()
  local value = settings.global["alina-auto-spawn"]
  return not value or value.value
end

local function setup_player(player_index)
  local player = game.get_player(player_index)
  if not player then return end
  if player.connected and player.controller_type == defines.controllers.editor then
    Agent.disable_editor(player.index)
  end
  Gui.ensure(player)
  if auto_spawn_enabled() then Agent.ensure(player_index) end
  WorldModel.seed_player(player)
  Gui.refresh(player)
end

local function initialize()
  local root = State.ensure()
  State.reset_transient()
  migrate_playable_policy()
  -- Playable policy: Alina always resumes autonomous work after loading a save.
  -- Pause/Stop are session controls, not a permanent "do nothing" state.
  root.paused = false
  root.autonomy.enabled = true
  RecipeIndex.start()
  PrototypeIndex.start()
  WorldModel.initialize()
  Autonomy.initialize()
  Advisor.initialize()
  EventBus.session_started()
  for _, player in pairs(game.connected_players) do
    setup_player(player.index)
  end
end

script.on_init(initialize)
script.on_configuration_changed(initialize)

script.on_event(defines.events.on_player_created, function(event)
  setup_player(event.player_index)
end)

script.on_event(defines.events.on_player_joined_game, function(event)
  setup_player(event.player_index)
end)

script.on_event({
  defines.events.on_player_controller_changed,
  defines.events.on_player_respawned,
  defines.events.on_cutscene_cancelled,
  defines.events.on_cutscene_finished
}, function(event)
  setup_player(event.player_index)
end)

script.on_event(defines.events.on_console_chat, Chat.on_console_chat)
script.on_event(defines.events.on_udp_packet_received, function(event)
  -- UDP delivery is deliberately local and therefore must never mutate a
  -- lockstep multiplayer simulation. Multiplayer plans enter through synced
  -- chat/command/RCON inputs instead.
  if not game.is_multiplayer() then IncomingUdp.on_packet(event) end
end)
script.on_event(defines.events.on_gui_click, Gui.on_click)
script.on_event(defines.events.on_script_path_request_finished, Navigation.on_path_finished)

script.on_event(defines.events.on_entity_died, function(event)
  local death_position = event.entity and {
    x = event.entity.position.x,
    y = event.entity.position.y
  } or nil
  local cause = event.cause
  if event.entity and event.entity.valid then
    WorldModel.forget_entity(event.entity, event.entity.surface.index)
  end
  if Agent.on_died(event.entity) then
    local root = State.ensure()
    local task = root.task.current
    if task then
      task.status = "recovering"
      task.navigation = nil
      if task.acquisition then
        local operation = task.acquisition.operations
          and task.acquisition.operations[task.acquisition.index or 1] or nil
        if operation and operation.state == "pathing" then operation.state = nil end
      end
      if task.power then task.power.navigation_started = nil end
      if task.expansion then task.expansion.repositioning = nil end
    end
    EventBus.emit("agent_died", {
      task_id = task and task.id or nil,
      position = death_position,
      cause = cause and cause.valid and cause.name or nil,
      cause_force = cause and cause.valid and cause.force and cause.force.name or nil,
      respawn_tick = root.agent.respawn_tick
    })
    game.print(Identity.message("Меня задело. Вернусь через несколько секунд; задачу помню."))
    Gui.refresh_all()
  end
end)

local function mark_activity(event, action)
  if not event.player_index then return end
  local player = game.get_player(event.player_index)
  if not player then return end
  local entity = event.entity
  local position = entity and entity.valid and entity.position or player.position
  Conflict.mark_player_activity(player, position, action)
  EventBus.emit("player_activity_marked", {
    player_index = player.index,
    action = action,
    entity = entity and entity.valid and entity.name or nil,
    position = {x = position.x, y = position.y}
  })
  Social.on_player_activity(player)
end

script.on_event(defines.events.on_built_entity, function(event)
  mark_activity(event, "built_entity")
  WorldModel.observe_entity(event.entity)
end)

script.on_event(defines.events.on_robot_built_entity, function(event)
  LineExpander.on_robot_built(event)
  WorldModel.observe_entity(event.entity)
end)

script.on_event(defines.events.script_raised_built, function(event)
  WorldModel.observe_entity(event.entity)
end)

script.on_event(defines.events.on_player_mined_entity, function(event)
  mark_activity(event, "mined_entity")
  if event.entity then WorldModel.forget_entity(event.entity, event.entity.surface.index) end
end)

script.on_event(defines.events.on_robot_mined_entity, function(event)
  if event.entity then WorldModel.forget_entity(event.entity, event.entity.surface.index) end
end)

script.on_event(defines.events.on_player_rotated_entity, function(event)
  mark_activity(event, "rotated_entity")
  WorldModel.observe_entity(event.entity)
end)

script.on_event(defines.events.on_entity_settings_pasted, function(event)
  if event.destination then WorldModel.observe_entity(event.destination) end
end)

script.on_event(defines.events.on_entity_cloned, function(event)
  if event.destination then WorldModel.observe_entity(event.destination) end
end)

script.on_event(defines.events.on_chunk_charted, WorldModel.on_chunk_charted)

script.on_event(defines.events.on_chart_tag_added, MarkerControl.on_added_or_modified)
script.on_event(defines.events.on_chart_tag_modified, MarkerControl.on_added_or_modified)
script.on_event(defines.events.on_chart_tag_removed, MarkerControl.on_removed)

script.on_event(defines.events.on_research_cancelled, ResearchControl.on_cancelled)
script.on_event(defines.events.on_research_started, ResearchControl.on_started)

script.on_event(defines.events.on_research_finished, function(event)
  ResearchControl.on_finished(event)
  State.ensure().autonomy.loadout_preferred = {}
  Autonomy.schedule_soon(30)
end)

script.on_event(defines.events.on_tick, function()
  Executor.on_tick()
end)

script.on_nth_tick(6, function()
  IncomingUdp.poll()
  -- One chunk at a time keeps indexing invisible to UPS. Running the small
  -- slice more often finishes the same refresh quickly without a burst.
  WorldModel.on_nth_tick()
end)

script.on_nth_tick(30, function()
  RecipeIndex.on_nth_tick()
  PrototypeIndex.on_nth_tick()
  if Catalog.is_active() then Catalog.on_nth_tick() end
end)

script.on_nth_tick(60, function()
  Agent.update_markers()
  Gui.refresh_all()
end)

script.on_nth_tick(120, function()
  Conflict.cleanup()
  ResearchControl.on_nth_tick()
  Autonomy.on_nth_tick()
  Advisor.on_nth_tick()
end)

commands.add_command("alina-spawn", "Создать или восстановить персонажа Алины.", function(command)
  local player = command.player_index and game.get_player(command.player_index) or nil
  if not player then return end
  if Agent.ensure(player.index) then
    Identity.print(player, "Я здесь.")
  else
    Identity.print(player, "Не нашла безопасное место для появления.")
  end
  Gui.refresh_all()
end)

commands.add_command("alina-status", "Показать состояние и счётчики Алины.", function(command)
  local player = command.player_index and game.get_player(command.player_index) or nil
  if not player then return end
  local root = State.ensure()
  local task = root.task.current
  Identity.print(player, "bridge=" .. tostring(root.bridge.status)
    .. ", task=" .. (task and task.summary or "none")
    .. ", scans=" .. root.metrics.sensor_scans
    .. ", active_ticks=" .. root.metrics.executor_active_ticks)
end)

commands.add_command("alina-inventory", "Открыть или закрыть инвентарь Алины для просмотра.", function(command)
  local player = command.player_index and game.get_player(command.player_index) or nil
  if player then Gui.toggle_inventory(player) end
end)

commands.add_command("alina-export-catalog", "Экспортировать активные прототипы порциями.", function(command)
  if not command.player_index then return end
  Catalog.start(command.player_index)
  local player = game.get_player(command.player_index)
  if player then Identity.print(player, "Начала порционный экспорт активных прототипов.") end
end)

if remote.interfaces["alina_ai"] then
  remote.remove_interface("alina_ai")
end

remote.add_interface("alina_ai", {
  parse_address = function(message)
    if type(message) ~= "string" or #message > 1000 then
      return {addressed = false}
    end
    local command = Names.extract_command(message)
    return {addressed = command ~= nil, command = command}
  end,
  submit_plan = function(value)
    local json = type(value) == "table" and helpers.table_to_json(value) or value
    if type(json) ~= "string" then return {ok = false, result = "invalid_plan_payload"} end
    local ok, result = TaskManager.submit_plan_json(json)
    if not ok then game.print(Identity.message("План отклонён: " .. tostring(result))) end
    Gui.refresh_all()
    return {ok = ok, result = result}
  end,
  status = function()
    local root = State.ensure()
    local history = root.task.history or {}
    local last_task = history[#history]
    local agent = Agent.get()
    local agent_inventory = agent and agent.get_inventory(defines.inventory.character_main) or nil
    local armor_inventory = agent and agent.get_inventory(defines.inventory.character_armor) or nil
    local gun_inventory = agent and agent.get_inventory(defines.inventory.character_guns) or nil
    local ammo_inventory = agent and agent.get_inventory(defines.inventory.character_ammo) or nil
    local equipment_grid = agent and agent.grid or nil
    local research_force = agent and agent.force or game.forces.player
    local armor = armor_inventory and armor_inventory[1].valid_for_read and armor_inventory[1].name or nil
    local weapons = {}
    local equipment = equipment_grid and equipment_grid.valid and equipment_grid.get_contents() or {}
    if gun_inventory and ammo_inventory then
      for index = 1, #gun_inventory do
        if gun_inventory[index].valid_for_read then
          weapons[#weapons + 1] = {
            slot = index,
            gun = gun_inventory[index].name,
            ammo = ammo_inventory[index].valid_for_read and ammo_inventory[index].name or nil,
            ammo_count = ammo_inventory[index].valid_for_read and ammo_inventory[index].count or 0
          }
        end
      end
    end
    return {
      schema_version = root.schema_version,
      bridge = root.bridge,
      paused = root.paused,
      development_focus = root.autonomy.development_focus == true,
      research = {
        hold = root.autonomy.research_hold == true,
        hold_source = root.autonomy.research_hold_source,
        hold_until = root.autonomy.research_hold_until,
        current = research_force and research_force.current_research and research_force.current_research.name or nil,
        selected_by_alina = root.autonomy.selected_research,
        priority = root.autonomy.research_priority,
        selected_by_player = root.autonomy.player_research
      },
      marker_goal = root.autonomy.marker_goal,
      forbidden_items = root.autonomy.forbidden_items,
      conflicts = Conflict.counts(),
      task = TaskManager.status_snapshot(),
      last_task = last_task and {
        id = last_task.id,
        type = last_task.type,
        status = last_task.status,
        result = last_task.result,
        source = last_task.source,
        created_tick = last_task.created_tick,
        finished_tick = last_task.finished_tick
      } or nil,
      agent = agent and {
        present = true,
        unit_number = agent.unit_number,
        surface = agent.surface.name,
        position = {x = agent.position.x, y = agent.position.y},
        inventory = agent_inventory and agent_inventory.get_contents() or {},
        armor = armor,
        weapons = weapons,
        equipment = equipment,
        is_flying = agent.is_flying,
        vehicle = agent.vehicle and agent.vehicle.valid and {
          name = agent.vehicle.name,
          type = agent.vehicle.type,
          unit_number = agent.vehicle.unit_number,
          personal = root.agent.personal_vehicle_unit == agent.vehicle.unit_number
        } or nil,
        map_visible = root.agent.map_tag and root.agent.map_tag.valid or false,
        deaths = root.agent.death_count or 0
      } or {present = false},
      metrics = root.metrics
    }
  end,
  recall = function(player_index)
    local ok = Agent.recall(player_index)
    Gui.refresh_all()
    return ok
  end,
  address = function(player_index, message)
    if type(player_index) ~= "number" or type(message) ~= "string" or #message > 1000 then
      return false
    end
    local player = game.get_player(player_index)
    if not player then return false end
    local ok, result = Chat.address(player, message)
    return {ok = ok, result = result}
  end,
  pause = function()
    TaskManager.pause()
    Gui.refresh_all()
    return true
  end,
  resume = function()
    TaskManager.resume()
    Gui.refresh_all()
    return true
  end,
  stop = function()
    TaskManager.cancel("Остановилась по внешней команде.")
    Gui.refresh_all()
    return true
  end,
  autonomy_pulse = function(player_index, priority_item)
    if priority_item ~= nil then
      if type(priority_item) ~= "string" or not prototypes.item[priority_item] then
        return {ok = false, result = "invalid_priority_item"}
      end
      State.ensure().autonomy.priority_item = priority_item
    end
    local ok, result = Autonomy.request(player_index, true)
    return {ok = ok, result = result}
  end,
  advice_now = function(player_index)
    return Advisor.give_now(player_index, true)
  end,
  conflict_at = function(surface_index, position)
    if type(surface_index) ~= "number" or not game.surfaces[surface_index]
        or type(position) ~= "table" or type(position.x) ~= "number" or type(position.y) ~= "number"
        or position.x ~= position.x or position.y ~= position.y
        or math.abs(position.x) > 10000000 or math.abs(position.y) > 10000000 then
      return {ok = false, error = "invalid_position"}
    end
    local blocked, reason = Conflict.is_blocked(surface_index, position, "diagnostic")
    return {ok = true, blocked = blocked, reason = reason}
  end,
  capacity_diagnostics = function(player_index, target_item)
    local player = type(player_index) == "number" and game.get_player(player_index) or nil
    if not player or type(target_item) ~= "string" or not prototypes.item[target_item] then
      return {ok = false, error = "invalid_target"}
    end
    local scan = WorldModel.machine_snapshot(player, 768)
    return {ok = true, health = LocalPlanner.producer_diagnostics(player, scan, target_item)}
  end,
  snapshot = function(player_index)
    local player = type(player_index) == "number" and game.get_player(player_index) or game.connected_players[1]
    if not player then return {ok = false, error = "player_missing"} end
    return {ok = true, snapshot = World.snapshot(player)}
  end,
  disable_editor = function(player_index)
    local ok, result = Agent.disable_editor(player_index)
    return {ok = ok, result = result}
  end,
  toggle_inventory = function(player_index)
    local player = type(player_index) == "number" and game.get_player(player_index) or nil
    if not player then return {ok = false, result = "player_missing"} end
    local opened = Gui.toggle_inventory(player)
    return {ok = true, opened = opened}
  end
})
