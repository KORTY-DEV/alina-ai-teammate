local State = require("scripts.core.state")
local TaskManager = require("scripts.tasks.manager")
local Autonomy = require("scripts.autonomy.coordinator")
local MarkerControl = require("scripts.chat.marker_control")
local Locale = require("scripts.core.locale")
local Identity = require("scripts.core.identity")
local RecipeIndex = require("scripts.sensors.recipe_index")

local DirectRouter = {}

local function lower_ru(text)
  local map = {
    ["А"]="а",["Б"]="б",["В"]="в",["Г"]="г",["Д"]="д",["Е"]="е",["Ё"]="ё",
    ["Ж"]="ж",["З"]="з",["И"]="и",["Й"]="й",["К"]="к",["Л"]="л",["М"]="м",
    ["Н"]="н",["О"]="о",["П"]="п",["Р"]="р",["С"]="с",["Т"]="т",["У"]="у",
    ["Ф"]="ф",["Х"]="х",["Ц"]="ц",["Ч"]="ч",["Ш"]="ш",["Щ"]="щ",["Ъ"]="ъ",
    ["Ы"]="ы",["Ь"]="ь",["Э"]="э",["Ю"]="ю",["Я"]="я"
  }
  text = text or ""
  for upper, lower in pairs(map) do text = string.gsub(text, upper, lower) end
  return string.lower(text)
end

local function contains_any(text, values)
  for _, value in ipairs(values) do
    if string.find(text, value, 1, true) then return true end
  end
  return false
end

local RESOURCE_ALIASES = {
  {stems = {"желез", "iron"}, candidates = {"iron-ore"}},
  {stems = {"мед", "copper"}, candidates = {"copper-ore"}},
  {stems = {"угол", "угля", "coal"}, candidates = {"coal"}},
  {stems = {"камен", "stone"}, candidates = {"stone"}},
  {stems = {"уран", "uran"}, candidates = {"uranium-ore"}},
  {stems = {"редк", "rare metal", "rare-metal"},
    candidates = {"kr-rare-metal-ore", "raw-rare-metals", "rare-metals"}},
  {stems = {"иммерс", "imersite"}, candidates = {"kr-imersite", "imersite"}}
}

local ITEM_ALIASES = {
  {stems = {"железн", "железо", "iron plate"}, candidates = {"iron-plate"}},
  {stems = {"медн", "медь", "copper plate"}, candidates = {"copper-plate"}},
  {stems = {"стал", "steel"}, candidates = {"steel-plate"}},
  {stems = {"шестер", "gear"}, candidates = {"iron-gear-wheel"}},
  {stems = {"зелен", "электронн", "electronic circuit"}, candidates = {"electronic-circuit"}},
  {stems = {"красн плат", "продвинут", "advanced circuit"}, candidates = {"advanced-circuit"}},
  {stems = {"син плат", "процессор", "processing unit"}, candidates = {"processing-unit"}},
  {stems = {"пластик", "plastic"}, candidates = {"plastic-bar"}},
  {stems = {"сер", "sulfur"}, candidates = {"sulfur"}},
  {stems = {"батар", "battery"}, candidates = {"battery"}},
  {stems = {"ракетн топлив", "rocket fuel"}, candidates = {"rocket-fuel"}},
  {stems = {"мал плотн", "low density"}, candidates = {"low-density-structure"}},
  {stems = {"красн наук", "красн пакет"}, candidates = {"automation-science-pack"}},
  {stems = {"зелен наук", "зелен пакет"}, candidates = {"logistic-science-pack"}},
  {stems = {"син наук", "син пакет", "хим наук"}, candidates = {"chemical-science-pack"}},
  {stems = {"фиолет наук", "производственн наук"}, candidates = {"production-science-pack"}},
  {stems = {"желт наук", "вспомогательн наук"}, candidates = {"utility-science-pack"}},
  {stems = {"космическ наук", "space science"}, candidates = {"space-science-pack"}},
  {stems = {"редк металл", "rare metal"}, candidates = {"rare-metals", "kr-rare-metals", "raw-rare-metals"}}
}

local function candidate_exists(kind, name)
  if kind == "resource" then
    local prototype = prototypes.entity[name]
    return prototype and prototype.type == "resource"
  end
  return prototypes.item[name] ~= nil
end

local function resolve_alias(text, rows, kind)
  for _, row in ipairs(rows) do
    if contains_any(text, row.stems) then
      for _, name in ipairs(row.candidates) do
        if candidate_exists(kind, name) then return name end
      end
    end
  end
  return nil
end

local function resolve_nearby_resource(player, text, marker)
  local alias = resolve_alias(text, RESOURCE_ALIASES, "resource")
  local surface = marker and game.get_surface(marker.surface_index) or player.surface
  local position = marker and marker.position or player.position
  if not surface then return nil end
  local function nearest_first(a, b)
    local adx, ady = a.position.x - position.x, a.position.y - position.y
    local bdx, bdy = b.position.x - position.x, b.position.y - position.y
    local a_distance, b_distance = adx * adx + ady * ady, bdx * bdx + bdy * bdy
    if a_distance ~= b_distance then return a_distance < b_distance end
    if a.name ~= b.name then return a.name < b.name end
    return (a.unit_number or 0) < (b.unit_number or 0)
  end
  if alias then
    local exact = surface.find_entities_filtered({position = position, radius = marker and 48 or 96,
      type = "resource", name = alias, limit = 64})
    table.sort(exact, nearest_first)
    if exact[1] then return alias, exact[1] end
    if not marker then return alias end
  end
  local entities = surface.find_entities_filtered({
    position = position,
    radius = marker and 48 or 96,
    type = "resource",
    limit = 64
  })
  table.sort(entities, nearest_first)
  for _, entity in ipairs(entities) do
    local normalized = string.gsub(string.lower(entity.name), "[-_]", " ")
    if string.find(text, normalized, 1, true) then return entity.name, entity end
  end
  if marker and entities[1] then return entities[1].name, entities[1] end
  return nil
end

local function resolve_item(text)
  local tagged = string.match(text, "%[item=([^%],]+)")
  if tagged and prototypes.item[tagged] then return tagged end
  local alias = resolve_alias(text, ITEM_ALIASES, "item")
  if alias then return alias end
  local best = nil
  for name in pairs(prototypes.item) do
    local normalized = string.gsub(string.lower(name), "[-_]", " ")
    if string.find(text, normalized, 1, true) and (not best or #name > #best) then best = name end
  end
  return best
end

local function resource_properties(resource)
  if type(resource) == "string" then
    local prototype = prototypes.entity[resource]
    return prototype and prototype.type == "resource" and prototype.mineable_properties or nil
  end
  return resource and resource.valid and resource.prototype.mineable_properties or nil
end

local function primary_resource_product(resource)
  local properties = resource_properties(resource)
  local best, amount = nil, -1
  for _, product in ipairs(properties and properties.products or {}) do
    if product.type == "item" and prototypes.item[product.name] then
      local expected = (product.amount or product.amount_max or product.amount_min or 1) * (product.probability or 1)
      if expected > amount then best, amount = product.name, expected end
    end
  end
  return best
end

local function processed_resource_target(force, resource)
  local input = primary_resource_product(resource)
  if not input then return nil end
  local candidates = RecipeIndex.resource_processing_candidates(force, input, 1)
  return candidates[1] and candidates[1].item or input
end

local function amount_from(text)
  local number = tonumber(string.match(text, "(%d+)") or "")
  if not number then return 25 end
  return math.max(1, math.min(100, math.floor(number)))
end

local function preempt_for_player()
  local root = State.ensure()
  root.paused = false
  root.autonomy.enabled = true
  root.autonomy.next_tick = game.tick + 120
  root.autonomy.foundation_audit = nil
  root.autonomy.foundation_audit_tick = 0
  if root.task.current and root.task.current.source == "autonomous" then
    TaskManager.cancel("Уступаю текущую работу вашей команде.")
  end
  Autonomy.supersede_for_player()
end

local function command_options(text)
  return {
    high_throughput = contains_any(text, {"масштаб", "с запас", "много", "быстро", "максим", "больш"}),
    cover_full_patch = contains_any(text, {"максим", "всю жил", "вся жил", "целиком", "полностью"})
  }
end

local function find_unpowered(player)
  local types = {"assembling-machine", "furnace", "mining-drill", "lab"}
  local entities = player.surface.find_entities_filtered({
    position = player.position,
    radius = 64,
    type = types,
    force = player.force,
    limit = 96
  })
  for _, entity in ipairs(entities) do
    if entity.valid and (entity.status == defines.entity_status.no_power
        or entity.status == defines.entity_status.not_plugged_in_electric_network) then
      return entity.name
    end
  end
  return nil
end

function DirectRouter.try_handle(player, command)
  local text = lower_ru(command)

  local mentions_marker = contains_any(text, {"метк", "[gps="})
  local marker = nil
  if mentions_marker then
    local marker_error
    marker, marker_error = MarkerControl.resolve(player, text)
    if not marker then
      Identity.print(player, "Не нашла указанную метку. Назови её в команде или вставь координаты Shift-кликом по карте.")
      return true, marker_error
    end
  end

  if contains_any(text, {"не строй", "не производи", "не делай", "запрещаю строить"}) then
    local item = resolve_item(text)
    if item then
      local root = State.ensure()
      root.autonomy.forbidden_items[item] = true
      if root.autonomy.priority_item == item then root.autonomy.priority_item = nil end
      local task = root.task.current
      local task_item = task and (task.target_item or (task.expansion and task.expansion.target_item))
      if task_item == item then TaskManager.cancel("Остановила работу с " .. item .. " по вашему запрету.") end
      Identity.print(player, {"", "Поняла: ", Locale.item(item), " не строю и не расширяю, пока вы не разрешите."})
      return true, "item_forbidden"
    end
  end

  if contains_any(text, {"можешь строить", "разрешаю строить", "снова строй", "можешь производить"}) then
    local item = resolve_item(text)
    if item then
      State.ensure().autonomy.forbidden_items[item] = nil
      Identity.print(player, {"", "Запрет на ", Locale.item(item), " снят."})
      return true, "item_allowed"
    end
  end

  if marker and contains_any(text, {"обустрой", "разработай жил", "наладь добыч", "доведи от жил", "ленту от жил"}) then
    local resource_name, resource = resolve_nearby_resource(player, text, marker)
    local target = resource and processed_resource_target(player.force, resource) or nil
    if not resource_name or not target then
      Identity.print(player, "Метку поняла, но рядом с ней не нашла подходящую добываемую жилу.")
      return true, "marker_resource_not_found"
    end
    preempt_for_player()
    local root = State.ensure()
    marker.mode = "resource_chain"
    marker.resource = resource_name
    marker.target_item = target
    marker.high_throughput = command_options(text).high_throughput
    if contains_any(text, {"доведи от жил", "ленту от жил", "до базы"}) then
      marker.route_to_base = true
      marker.route_end = {x = player.position.x, y = player.position.y}
    end
    MarkerControl.store(marker)
    root.autonomy.forbidden_items[target] = nil
    root.autonomy.priority_item = target
    Autonomy.schedule_soon(30)
    Identity.print(player, {"", "Метку приняла. Обустрою ", Locale.entity(resource_name),
      " и построю связанную цепочку до ", Locale.item(target), "."})
    return true, "marker_resource_chain_scheduled"
  end

  if contains_any(text, {"жил", "месторожд"})
      and contains_any(text, {"найди", "обустрой", "разработ", "налад", "добыч", "поставь бур"}) then
    local resource_name, resource = resolve_nearby_resource(player, text, nil)
    local target = processed_resource_target(player.force, resource or resource_name)
    if not resource_name or not target then
      Identity.print(player, "Поняла задачу по месторождению, но не смогла определить ресурс. Назови руду точнее.")
      return true, "resource_chain_not_resolved"
    end
    preempt_for_player()
    local root = State.ensure()
    root.autonomy.development_focus = true
    root.autonomy.development_focus_until = nil
    root.autonomy.forbidden_items[target] = nil
    root.autonomy.priority_item = target
    root.autonomy.priority_options = command_options(text)
    root.autonomy.priority_options.resource_request = true
    MarkerControl.clear()
    Autonomy.schedule_soon(30)
    Identity.print(player, {"", "Приняла. Найду ", Locale.entity(resource_name),
      ", максимально обустрою доступную площадь и сделаю связанную цепочку до ",
      Locale.item(target), ". Затем продолжу развитие базы."})
    return true, "resource_chain_scheduled"
  end

  if contains_any(text, {"добуд", "накопай", "копай", "собери руд", "принеси руд"}) then
    local resource = resolve_nearby_resource(player, text, marker)
    if not resource then
      Identity.print(player, "Не смогла однозначно понять, какой ресурс добывать. Я продолжу базу, а ресурс лучше назови конкретнее.")
      return true, "resource_not_resolved"
    end
    preempt_for_player()
    local ok, result = TaskManager.start_mining(player.index, resource, amount_from(text), "direct_player")
    if ok then Identity.print(player, {"", "Приняла. Добуду ", Locale.entity(resource), "."}) end
    return true, result
  end

  if contains_any(text, {"в приоритете", "приоритет", "построй", "наладь производ", "сделай производ"}) then
    local item = resolve_item(text)
    if item then
      preempt_for_player()
      local root = State.ensure()
      root.autonomy.forbidden_items[item] = nil
      root.autonomy.priority_item = item
      root.autonomy.priority_options = command_options(text)
      if marker then
        marker.mode = "production"
        marker.target_item = item
        marker.high_throughput = root.autonomy.priority_options.high_throughput
        MarkerControl.store(marker)
      else
        MarkerControl.clear()
      end
      Autonomy.schedule_soon(30)
      Identity.print(player, {"", "Приняла приоритет: ", Locale.item(item),
        marker and "; размещу безопасный производственный блок у выбранной метки." or "."})
      return true, "player_priority_scheduled"
    end
  end

  if contains_any(text, {"не хватает", "дефицит", "мало ", "займись", "разберись", "увеличь производ", "расширь производ"}) then
    local item = resolve_item(text)
    if item then
      preempt_for_player()
      local root = State.ensure()
      root.autonomy.forbidden_items[item] = nil
      root.autonomy.priority_options = command_options(text)
      if marker then
        marker.mode = "production"
        marker.target_item = item
        marker.high_throughput = root.autonomy.priority_options.high_throughput
        MarkerControl.store(marker)
      end
      local ok, result = TaskManager.start_resolve_shortage(player.index, item, "direct_player")
      if ok then Identity.print(player, {"", "Проверю производство ", Locale.item(item),
        " и исправлю безопасное узкое место."}) end
      return true, result
    end
  end

  if contains_any(text, {"электр", "питан", "без света", "нет энергии"}) then
    local entity = find_unpowered(player)
    if entity then
      preempt_for_player()
      local ok, result = TaskManager.start_repair_power(player.index, entity, "direct_player")
      if ok then Identity.print(player, "Вижу потребителя без питания. Продолжу к нему существующую сеть.") end
      return true, result
    end
    Identity.print(player, "Рядом не вижу потребителя без питания. Продолжаю автономную работу.")
    return true, "no_power_issue"
  end

  return false, "unsupported"
end

return DirectRouter
