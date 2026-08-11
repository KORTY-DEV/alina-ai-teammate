local State = require("scripts.core.state")
local Names = require("scripts.core.names")
local EventBus = require("scripts.core.event_bus")
local World = require("scripts.sensors.world")
local WorldModel = require("scripts.sensors.world_model")
local TaskManager = require("scripts.tasks.manager")
local Conflict = require("scripts.conflict.manager")
local Gui = require("scripts.gui.panel")
local Autonomy = require("scripts.autonomy.coordinator")
local DirectRouter = require("scripts.chat.direct_router")
local ResearchControl = require("scripts.chat.research_control")
local Identity = require("scripts.core.identity")

local Chat = {}

local function contains_any(text, variants)
  for _, variant in ipairs(variants) do
    if string.find(text, variant, 1, true) then return true end
  end
  return false
end

local function trim(text)
  text = string.gsub(text or "", "^[%s,%.!%?:;%-]+", "")
  text = string.gsub(text, "[%s]+", " ")
  text = string.gsub(text, "[%s]+$", "")
  return text
end

local function lowercase_ru(text)
  local map = {
    ["А"]="а",["Б"]="б",["В"]="в",["Г"]="г",["Д"]="д",["Е"]="е",["Ё"]="ё",
    ["Ж"]="ж",["З"]="з",["И"]="и",["Й"]="й",["К"]="к",["Л"]="л",["М"]="м",
    ["Н"]="н",["О"]="о",["П"]="п",["Р"]="р",["С"]="с",["Т"]="т",["У"]="у",
    ["Ф"]="ф",["Х"]="х",["Ц"]="ц",["Ч"]="ч",["Ш"]="ш",["Щ"]="щ",["Ъ"]="ъ",
    ["Ы"]="ы",["Ь"]="ь",["Э"]="э",["Ю"]="ю",["Я"]="я"
  }
  for upper, lower in pairs(map) do text = string.gsub(text, upper, lower) end
  return string.lower(text)
end

local FACTORY_DEVELOPMENT_MARKERS = {
  "улучшай базу",
  "улучши базу",
  "продолжай улучшать базу",
  "продолжи улучшать базу",
  "развивай базу",
  "продолжай развивать базу",
  "продолжи развивать базу",
  "занимайся базой",
  "займись базой",
  "продолжай развитие базы",
  "продолжи развитие базы"
}

local function is_factory_development(command)
  local normalized = lowercase_ru(command)
  return contains_any(normalized, FACTORY_DEVELOPMENT_MARKERS)
end

local function cleanup_requests(root)
  for request_id, pending in pairs(root.pending_requests) do
    if game.tick - pending.created_tick > 3600 then
      root.pending_requests[request_id] = nil
    end
  end
end

local function supersede_direct_requests(root)
  for request_id, pending in pairs(root.pending_requests) do
    if pending and pending.source == "direct_player" then
      root.pending_requests[request_id] = nil
    end
  end
  if root.confirmation then root.confirmation = nil end
end

local function handle_local_control(player, command)
  local normalized = lowercase_ru(command)
  local research_handled = ResearchControl.try_handle(player, normalized)
  if research_handled then Autonomy.schedule_soon(30); return true end

  local pending_confirmation = State.ensure().confirmation
  if pending_confirmation and contains_any(normalized, {
      "не подтверждаю", "не делай", "нет, не надо", "нет не надо",
      "отклоняю", "отмена действия"
    }) then
    local ok, result = TaskManager.reject_pending(player.index)
    if not ok and result == "wrong_player" then
      Identity.print(player, "Это действие должен отклонить игрок, который его запросил.")
    end
    return true
  end
  if pending_confirmation and contains_any(normalized, {
      "подтверждаю", "да, делай", "да делай", "выполняй это", "согласен", "согласна"
    }) then
    local ok, result = TaskManager.confirm_pending(player.index)
    if ok then
      Identity.print(player, "Подтверждение принято. Выполняю согласованное действие.")
    elseif result == "wrong_player" then
      Identity.print(player, "Это действие должен подтвердить игрок, который его запросил.")
    else
      Identity.print(player, "Подтверждение уже недействительно; ничего опасного не выполняю.")
    end
    return true
  end

  if contains_any(normalized, {"поставь на паузу", "остановись", "стой"}) then
    TaskManager.pause()
    Identity.print(player, "Хорошо, пауза.")
    return true
  end

  if normalized == "продолжай" or normalized == "возобнови" or normalized == "сними паузу" then
    TaskManager.resume()
    Identity.print(player, "Продолжаю.")
    return true
  end

  if contains_any(normalized, {"отмени задачу", "прекрати задачу"}) then
    TaskManager.cancel("Отменила текущую задачу.")
    return true
  end

  if contains_any(normalized, {
      "можешь снова трогать здесь", "можешь работать здесь", "сними запрет участка",
      "разрешаю строить здесь", "этот участок снова свободен"
    }) then
    local removed = Conflict.remove_protected_area(player, 32)
    if removed > 0 then
      Identity.print(player, "Сняла ваш запрет рядом с текущим местом. Снова могу учитывать этот участок.")
    else
      Identity.print(player, "Рядом нет вашего защищённого участка.")
    end
    return true
  end

  if contains_any(normalized, {"ничего не трогай", "это я сам сделаю"}) then
    Conflict.add_protected_area(player, 24)
    if TaskManager.has_active_task() then
      TaskManager.cancel("Уступаю этот участок вам.")
    end
    Identity.print(player, "Отметила участок вокруг вас как неприкосновенный.")
    return true
  end

  if contains_any(normalized, {
      "подготовь экипировку", "подготовь свою экипировку", "займись экипировкой",
      "экипируйся", "подготовь экипировку и паукотрон", "подготовь паукотрон"
    }) then
    local root = State.ensure()
    if TaskManager.has_active_task() then
      TaskManager.cancel("Переключаюсь на подготовку личной экипировки.")
    end
    root.paused = false
    root.autonomy.enabled = true
    -- Equipment is a temporary explicit priority. Autonomous factory
    -- development resumes as soon as the personal loadout is ready.
    root.autonomy.development_focus = true
    root.autonomy.development_focus_until = nil
    root.autonomy.foundation_audit = nil
    root.autonomy.foundation_audit_tick = 0
    root.autonomy.loadout_priority = true
    Autonomy.supersede_for_player()
    Autonomy.schedule_soon(1)
    EventBus.emit("loadout_priority_enabled", {player_index = player.index})
    Identity.print(player, "Поняла. Подготовлю экипировку и доступный личный транспорт.")
    return true
  end

  -- Самая частая команда развития базы не требует LLM: она лишь включает
  -- уже существующий безопасный автономный контур. Это убирает лишний GPU-рывок.
  if is_factory_development(normalized) then
    local root = State.ensure()
    if TaskManager.has_active_task() then
      TaskManager.cancel("Переключаюсь на новый приоритет игрока: развитие базы.")
    end
    root.paused = false
    root.autonomy.enabled = true
    root.autonomy.development_focus = true
    -- "Развивай базу" is a persistent operating mode, not a five-minute
    -- temporary hint. It ends only when the player pauses/stops Alina or gives
    -- her another explicit priority.
    root.autonomy.development_focus_until = nil
    root.autonomy.foundation_audit = nil
    root.autonomy.foundation_audit_tick = 0
    Autonomy.supersede_for_player()
    -- Only enqueue bounded deterministic work here; chunk contents are scanned
    -- later by the normal World Model budget, so pressing Enter stays instant.
    local refresh_chunks = WorldModel.request_factory_refresh(player, 6)
    Autonomy.schedule_soon(30)
    EventBus.emit("factory_development_enabled", {
      player_index = player.index,
      mode = "local_deterministic",
      refresh_chunks = refresh_chunks
    })
    Identity.print(player, "Поняла. Обновляю картину базы и займусь полезным расширением.")
    return true
  end

  return false
end

local function queue_command(player, message, command)
  if command == "" then
    Identity.print(player, "Я здесь. Я и так продолжаю базу сама; напиши только если хочешь изменить приоритет.")
    return true, "empty_command"
  end

  if handle_local_control(player, command) then
    Gui.refresh_all()
    return true, "local_control"
  end

  local handled, result = DirectRouter.try_handle(player, command)
  if handled then
    Gui.refresh_all()
    return true, result
  end

  -- Playable mode deliberately does NOT call the 4B model from ordinary chat.
  -- On this GTX 1070 an inference saturates the same GPU used by Factorio and
  -- made the game appear frozen. Unsupported instructions therefore fail fast
  -- while autonomous gameplay keeps running in the background.
  local root = State.ensure()
  root.paused = false
  root.autonomy.enabled = true
  root.autonomy.next_tick = math.min(root.autonomy.next_tick or game.tick + 120, game.tick + 120)
  Identity.print(player, "Команду услышала, но этот тип действия пока не выполняю безопасно. Продолжаю развивать базу сама.")
  Gui.refresh_all()
  return true, "unsupported_without_runtime_llm"
end

function Chat.address(player, message)
  if not player or not player.valid or type(message) ~= "string" then return false, "invalid_request" end
  local command = Names.extract_command(message)
  if not command then return false, "not_addressed" end
  return queue_command(player, message, command)
end

function Chat.on_console_chat(event)
  if not event.player_index or type(event.message) ~= "string" then return false, "invalid_event" end
  local player = game.get_player(event.player_index)
  if not player then return false, "player_not_found" end

  local command = Names.extract_command(event.message)
  if not command and not game.is_multiplayer() then
    -- В одиночной игре обычный чат фактически является диалогом с Алиной.
    -- Поэтому имя не обязательно: «улучшай базу» и «добудь железа» работают.
    command = trim(event.message)
  end
  if not command or command == "" then return false, "not_addressed" end
  return queue_command(player, event.message, command)
end

return Chat
