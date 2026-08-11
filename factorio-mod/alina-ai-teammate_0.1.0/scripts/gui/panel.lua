local State = require("scripts.core.state")
local TaskManager = require("scripts.tasks.manager")
local WorldModel = require("scripts.sensors.world_model")
local Locale = require("scripts.core.locale")
local Identity = require("scripts.core.identity")
local Agent = require("scripts.agent.agent")

local Gui = {}

local PANEL = "alina_panel"
local STATUS = "alina_status"
local PLAN = "alina_plan"
local BRIDGE = "alina_bridge"
local CONFIRMATION = "alina_confirmation"
local WORLD = "alina_world_model"
local INVENTORY_FRAME = "alina_inventory_frame"
local INVENTORY_TITLE = "alina_inventory_title"
local INVENTORY_SUMMARY = "alina_inventory_summary"
local INVENTORY_SLOTS = "alina_inventory_slots"
local INVENTORY_EQUIPMENT = "alina_inventory_equipment"

local PANEL_WIDTH = 520
local PANEL_HEIGHT = 250
local PANEL_TEXT_WIDTH = 488
local INVENTORY_WIDTH = 520
local INVENTORY_HEIGHT = 480
local INVENTORY_COLUMNS = 10

local PHASE_LABELS = {
  seeking = "ищу цель",
  approaching = "иду к цели",
  observing = "проверяю",
  pathing_to_resource = "иду к месторождению",
  mining = "добываю",
  returning_to_player = "возвращаюсь",
  delivering = "передаю ресурсы",
  diagnosing = "ищу причину нехватки",
  waiting_for_recipe_index = "изучаю рецепты",
  planning_power_route = "планирую электросеть",
  acquiring_items = "собираю материалы",
  acquiring_module_items = "собираю комплект",
  preparing_physical_module = "проверяю место строительства",
  clearing_trees = "дроны расчищают место",
  building_module = "строю",
  verifying_module = "проверяю постройку",
  verifying_chain_output = "проверяю выпуск",
  placing_ghosts = "размечаю строительство",
  waiting_for_robots = "жду строительных дронов",
  commissioning = "запускаю производство",
  acquiring_loadout = "пополняю запас",
  planning_loadout = "планирую экипировку"
}

local function ui_verbosity()
  local configured = settings.global["alina-ui-verbosity"]
  return configured and configured.value or "compact"
end

local function fixed_label(parent, name, caption, height)
  local label = parent.add({type = "label", name = name, caption = caption})
  label.style.width = PANEL_TEXT_WIDTH
  label.style.height = height
  label.style.single_line = false
  return label
end

local function set_slot(slot, stack)
  if stack and stack.valid_for_read then
    slot.sprite = "item/" .. stack.name
    slot.number = stack.count
    slot.tooltip = {"", Locale.item(stack.name), " × ", tostring(stack.count)}
  else
    slot.sprite = nil
    slot.number = nil
    slot.tooltip = "Пусто"
  end
end

local function create_inventory(player)
  local old = player.gui.screen[INVENTORY_FRAME]
  if old then old.destroy() end

  local frame = player.gui.screen.add({
    type = "frame",
    name = INVENTORY_FRAME,
    caption = "Инвентарь " .. Identity.name() .. " — только просмотр",
    direction = "vertical"
  })
  frame.style.width = INVENTORY_WIDTH
  frame.style.height = INVENTORY_HEIGHT
  frame.auto_center = true
  player.opened = frame

  local title_flow = frame.add({type = "flow", name = INVENTORY_TITLE, direction = "horizontal"})
  local summary = title_flow.add({type = "label", name = INVENTORY_SUMMARY, caption = "Загружаю…"})
  summary.style.horizontally_stretchable = true
  title_flow.add({type = "button", name = "alina_inventory_close", caption = "Закрыть"})

  frame.add({type = "label", caption = "Основной запас"})
  local scroll = frame.add({type = "scroll-pane", name = "alina_inventory_scroll"})
  scroll.style.width = INVENTORY_WIDTH - 24
  scroll.style.height = 300
  scroll.style.horizontally_stretchable = true
  scroll.horizontal_scroll_policy = "never"
  local slots = scroll.add({type = "table", name = INVENTORY_SLOTS, column_count = INVENTORY_COLUMNS})
  slots.style.horizontal_spacing = 0
  slots.style.vertical_spacing = 0

  frame.add({type = "label", caption = "Экипировка"})
  local equipment = frame.add({type = "flow", name = INVENTORY_EQUIPMENT, direction = "horizontal"})
  equipment.style.height = 44
  for _, group in ipairs({
    {name = "armor", caption = "Броня"},
    {name = "guns", caption = "Оружие"},
    {name = "ammo", caption = "Боезапас"}
  }) do
    local flow = equipment.add({type = "flow", name = "alina_equipment_" .. group.name, direction = "horizontal"})
    flow.add({type = "label", caption = group.caption})
    local table_element = flow.add({
      type = "table",
      name = "alina_equipment_" .. group.name .. "_slots",
      column_count = 3
    })
    table_element.style.horizontal_spacing = 0
    table_element.style.vertical_spacing = 0
  end
  return frame
end

local function ensure_inventory_slots(table_element, count, prefix)
  for index = #table_element.children + 1, count do
    local slot = table_element.add({
      type = "sprite-button",
      name = prefix .. tostring(index),
      style = "slot_button"
    })
    slot.ignored_by_interaction = true
  end
  while #table_element.children > count do
    table_element.children[#table_element.children].destroy()
  end
end

local function refresh_inventory(player)
  local frame = player.gui.screen[INVENTORY_FRAME]
  if not frame then return end
  local agent = Agent.get()
  if not agent then
    frame[INVENTORY_TITLE][INVENTORY_SUMMARY].caption = Identity.name() .. " сейчас недоступна"
    return
  end

  local inventory = agent.get_inventory(defines.inventory.character_main)
  local slots = frame.alina_inventory_scroll[INVENTORY_SLOTS]
  local slot_count = inventory and #inventory or 0
  ensure_inventory_slots(slots, slot_count, "alina_inventory_slot_")
  local occupied = 0
  for index = 1, slot_count do
    local stack = inventory[index]
    if stack.valid_for_read then occupied = occupied + 1 end
    set_slot(slots.children[index], stack)
  end
  frame[INVENTORY_TITLE][INVENTORY_SUMMARY].caption = "Занято " .. tostring(occupied) .. " из "
    .. tostring(slot_count) .. " ячеек"

  local equipment = frame[INVENTORY_EQUIPMENT]
  local equipment_rows = {
    {inventory = agent.get_inventory(defines.inventory.character_armor), name = "armor"},
    {inventory = agent.get_inventory(defines.inventory.character_guns), name = "guns"},
    {inventory = agent.get_inventory(defines.inventory.character_ammo), name = "ammo"}
  }
  for _, row in ipairs(equipment_rows) do
    local flow = equipment["alina_equipment_" .. row.name]
    local table_element = flow["alina_equipment_" .. row.name .. "_slots"]
    local count = row.inventory and #row.inventory or 0
    ensure_inventory_slots(table_element, count, "alina_equipment_" .. row.name .. "_slot_")
    for index = 1, count do
      set_slot(table_element.children[index], row.inventory[index])
    end
  end
end

local function create(player)
  local old = player.gui.left[PANEL]
  if old then old.destroy() end

  local frame = player.gui.left.add({type = "frame", name = PANEL, caption = Identity.name(), direction = "vertical"})
  frame.style.width = PANEL_WIDTH
  frame.style.height = PANEL_HEIGHT
  fixed_label(frame, STATUS, "Автономна", 42)
  fixed_label(frame, PLAN, "Плана пока нет", 42)
  fixed_label(frame, CONFIRMATION, "", 22)
  fixed_label(frame, WORLD, "Модель: индексирую важные объекты фабрики", 22)
  fixed_label(frame, BRIDGE, "Режим: локальный", 22)
  local buttons = frame.add({type = "flow", name = "alina_buttons", direction = "horizontal"})
  buttons.add({type = "button", name = "alina_pause", caption = "Пауза"})
  buttons.add({type = "button", name = "alina_resume", caption = "Продолжить"})
  buttons.add({type = "button", name = "alina_stop", caption = "Стоп"})
  buttons.add({type = "button", name = "alina_inventory", caption = "Инвентарь"})
  local confirmation_buttons = frame.add({type = "flow", name = "alina_confirmation_buttons", direction = "horizontal"})
  confirmation_buttons.add({type = "button", name = "alina_confirm", caption = "Подтвердить"})
  confirmation_buttons.add({type = "button", name = "alina_reject", caption = "Отклонить"})
end

function Gui.ensure(player)
  local frame = player.gui.left[PANEL]
  if not frame or not frame[WORLD] then create(player) end
  if player.gui.left[PANEL] then player.gui.left[PANEL].caption = Identity.name() end
end

function Gui.refresh(player)
  if not player or not player.valid then return end
  Gui.ensure(player)
  local frame = player.gui.left[PANEL]
  local root = State.ensure()
  local task = root.task.current

  local waiting = root.bridge.status == "waiting_response" and not task
  local autonomy_on = root.autonomy and root.autonomy.enabled ~= false
  frame[STATUS].caption = root.paused and "Пауза"
    or (task and Locale.message(task.summary))
    or (waiting and "Думаю над командой…"
      or (autonomy_on and Locale.message(root.autonomy.status_text or "Проверяю базу") or "Свободна"))
  if task then
    local gathered = task.gathered and (", собрано: " .. task.gathered) or ""
    frame[PLAN].caption = Locale.message("Сейчас: " .. (PHASE_LABELS[task.phase] or "работаю") .. gathered)
  elseif waiting then
    frame[PLAN].caption = "Жду план"
  elseif autonomy_on then
    frame[PLAN].caption = root.autonomy.last_activity
      and Locale.message("Готово: " .. root.autonomy.last_activity)
      or (root.autonomy.development_focus and "Ищу следующую полезную задачу" or "Работаю автономно")
  else
    frame[PLAN].caption = "Плана пока нет"
  end
  frame[CONFIRMATION].caption = root.confirmation and "Ожидается подтверждение важного действия" or ""
  local model = WorldModel.summary(player)
  frame[WORLD].caption = "Модель: " .. tostring(model.entities) .. " важных объектов, "
    .. tostring(model.scanned_chunks) .. " чанков"
    .. ((model.queued_chunks or 0) > 0 and (", индексирую ещё " .. tostring(model.queued_chunks)) or "")
  local verbosity = ui_verbosity()
  if verbosity == "debug" then
    frame[WORLD].caption = frame[WORLD].caption .. ", активных тиков: "
      .. tostring(root.metrics.executor_active_ticks or 0)
  end
  frame[WORLD].visible = verbosity ~= "compact" or (model.queued_chunks or 0) > 0
  local confirmation_buttons = frame.alina_confirmation_buttons
  if confirmation_buttons then
    confirmation_buttons.visible = root.confirmation ~= nil
  end
  local bridge_status = root.bridge.status or "unknown"
  local bridge_labels = {
    connected = "подключён",
    waiting = "ожидание",
    waiting_response = "получаю план",
    autonomy_timeout = "таймаут автономии",
    plan_rejected = "план отклонён",
    udp_disabled = "UDP выключен",
    multiplayer_safe = "мультиплеер: синхронные команды"
  }
  if root.bridge.last_heartbeat_tick and game.tick - root.bridge.last_heartbeat_tick > 300 then
    bridge_status = "no_heartbeat"
  end
  if bridge_status == "multiplayer_safe" then
    frame[BRIDGE].caption = "Режим: безопасный мультиплеер"
  elseif bridge_status == "waiting" or bridge_status == "no_heartbeat" or bridge_status == "udp_disabled" then
    frame[BRIDGE].caption = "Режим: автономный"
  elseif bridge_status == "connected" then
    frame[BRIDGE].caption = "Режим: локальный AI подключён"
  else
    frame[BRIDGE].caption = "Режим: " .. (bridge_labels[bridge_status] or "автономный")
  end
  frame[BRIDGE].visible = verbosity ~= "compact"
    or bridge_status == "multiplayer_safe"
    or bridge_status == "autonomy_timeout"
    or bridge_status == "plan_rejected"
  refresh_inventory(player)
end

function Gui.refresh_all()
  for _, player in pairs(game.connected_players) do
    Gui.refresh(player)
  end
end

function Gui.on_click(event)
  local element = event.element
  if not element or not element.valid then return end
  local player = game.get_player(event.player_index)
  if not player then return end

  if element.name == "alina_pause" then
    TaskManager.pause()
    Identity.print(player, "Поставила задачу на паузу.")
  elseif element.name == "alina_resume" then
    TaskManager.resume()
    Identity.print(player, "Продолжаю.")
  elseif element.name == "alina_stop" then
    TaskManager.cancel("Остановилась по вашей команде.")
    local root = State.ensure()
    root.paused = true
  elseif element.name == "alina_confirm" then
    local ok = TaskManager.confirm_pending(player.index)
    if not ok then Identity.print(player, "Сейчас нечего подтверждать.") end
  elseif element.name == "alina_reject" then
    local ok = TaskManager.reject_pending(player.index)
    if not ok then Identity.print(player, "Сейчас нечего отклонять.") end
  elseif element.name == "alina_inventory" then
    if player.gui.screen[INVENTORY_FRAME] then
      player.gui.screen[INVENTORY_FRAME].destroy()
    else
      create_inventory(player)
      refresh_inventory(player)
    end
  elseif element.name == "alina_inventory_close" then
    local frame = player.gui.screen[INVENTORY_FRAME]
    if frame then frame.destroy() end
  else
    return
  end
  Gui.refresh_all()
end

function Gui.toggle_inventory(player)
  if not player or not player.valid then return false end
  if player.gui.screen[INVENTORY_FRAME] then
    player.gui.screen[INVENTORY_FRAME].destroy()
    return false
  end
  create_inventory(player)
  refresh_inventory(player)
  return true
end

return Gui
