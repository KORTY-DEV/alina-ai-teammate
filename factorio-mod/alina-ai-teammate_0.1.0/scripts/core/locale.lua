local Locale = {}

local ENTITY_TYPES_RU = {
  ["assembling-machine"] = "сборочная машина",
  ["mining-drill"] = "бур",
  furnace = "печь",
  inserter = "манипулятор",
  ["transport-belt"] = "конвейер",
  ["electric-pole"] = "электрический столб",
  container = "сундук",
  ["logistic-container"] = "логистический сундук",
  lab = "лаборатория",
  resource = "месторождение"
}

local function fallback_name(name)
  return string.gsub(name or "неизвестный объект", "[-_]", " ")
end

local function pack_localised(parts)
  if #parts <= 18 then
    local result = {""}
    for _, part in ipairs(parts) do result[#result + 1] = part end
    return result
  end
  local groups = {}
  local index = 1
  while index <= #parts do
    local chunk = {}
    for offset = 0, 17 do
      if parts[index + offset] == nil then break end
      chunk[#chunk + 1] = parts[index + offset]
    end
    groups[#groups + 1] = pack_localised(chunk)
    index = index + 18
  end
  return pack_localised(groups)
end

function Locale.item(name)
  local prototype = name and prototypes.item[name] or nil
  return prototype and prototype.localised_name or fallback_name(name)
end

function Locale.technology(name)
  local prototype = name and prototypes.technology[name] or nil
  return prototype and prototype.localised_name or {"", "технология «", fallback_name(name), "»"}
end

function Locale.entity(name)
  local prototype = name and prototypes.entity[name] or nil
  if prototype and prototype.localised_name then return prototype.localised_name end
  local kind = prototype and ENTITY_TYPES_RU[prototype.type] or nil
  return kind or fallback_name(name)
end

function Locale.entity_at(entity, ordinal)
  if not entity or not entity.valid then return "неизвестный объект" end
  local prefix = ordinal and {"", tostring(ordinal), "-й "} or ""
  return {"", prefix, Locale.entity(entity.name), " у ",
    math.floor(entity.position.x + 0.5), ", ", math.floor(entity.position.y + 0.5)}
end

-- Convert technical prototype identifiers embedded in executor messages into
-- the active locale without maintaining a vanilla-only translation table.
-- Unknown mod identifiers remain readable words instead of causing an error.
function Locale.message(value)
  if type(value) ~= "string" then return value end
  local parts = {}
  local cursor = 1
  while cursor <= #value do
    local first, last = string.find(value, "[A-Za-z0-9_%-]+", cursor)
    if not first then
      parts[#parts + 1] = string.sub(value, cursor)
      break
    end
    if first > cursor then parts[#parts + 1] = string.sub(value, cursor, first - 1) end
    local token = string.sub(value, first, last)
    if prototypes.item[token] then
      parts[#parts + 1] = Locale.item(token)
    elseif prototypes.entity[token] then
      parts[#parts + 1] = Locale.entity(token)
    elseif prototypes.technology[token] then
      parts[#parts + 1] = Locale.technology(token)
    else
      parts[#parts + 1] = fallback_name(token)
    end
    cursor = last + 1
  end
  return pack_localised(parts)
end

return Locale
