local Names = {}

local default_aliases = {
  "алиночка", "алечка", "алиной", "алинка", "алины",
  "алине", "алину", "алина", "алей", "алю", "але", "аля"
}

local uppercase = {
  ["А"] = "а", ["Б"] = "б", ["В"] = "в", ["Г"] = "г", ["Д"] = "д",
  ["Е"] = "е", ["Ё"] = "ё", ["Ж"] = "ж", ["З"] = "з", ["И"] = "и",
  ["Й"] = "й", ["К"] = "к", ["Л"] = "л", ["М"] = "м", ["Н"] = "н",
  ["О"] = "о", ["П"] = "п", ["Р"] = "р", ["С"] = "с", ["Т"] = "т",
  ["У"] = "у", ["Ф"] = "ф", ["Х"] = "х", ["Ц"] = "ц", ["Ч"] = "ч",
  ["Ш"] = "ш", ["Щ"] = "щ", ["Ъ"] = "ъ", ["Ы"] = "ы", ["Ь"] = "ь",
  ["Э"] = "э", ["Ю"] = "ю", ["Я"] = "я"
}

local function lowercase(text)
  for upper, lower in pairs(uppercase) do
    text = string.gsub(text, upper, lower)
  end
  return string.lower(text)
end

local function is_boundary(message, first, last)
  local before = first == 1 or string.match(string.sub(message, first - 1, first - 1), "[%s%p]") ~= nil
  local after = last == #message or string.match(string.sub(message, last + 1, last + 1), "[%s%p]") ~= nil
  return before and after
end

function Names.extract_command(message)
  local normalized = lowercase(message)
  local aliases, seen = {}, {}
  local function add(value)
    value = lowercase(string.gsub(tostring(value or ""), "^%s*(.-)%s*$", "%1"))
    if value ~= "" and not seen[value] then seen[value] = true; aliases[#aliases + 1] = value end
  end
  for _, alias in ipairs(default_aliases) do add(alias) end
  local display = settings.global["alina-display-name"]
  add(display and display.value or "Алина")
  local custom = settings.global["alina-address-aliases"]
  for alias in string.gmatch(custom and custom.value or "", "[^,;]+") do add(alias) end
  table.sort(aliases, function(a, b)
    if #a == #b then return a < b end
    return #a > #b
  end)
  for _, alias in ipairs(aliases) do
    local first, last = string.find(normalized, alias, 1, true)
    if first and is_boundary(normalized, first, last) then
      local before = string.sub(message, 1, first - 1)
      local after = string.sub(message, last + 1)
      local command = before .. " " .. after
      command = string.gsub(command, "^[%s,%.!%?:;%-]+", "")
      command = string.gsub(command, "[%s]+", " ")
      command = string.gsub(command, "[%s]+$", "")
      return command
    end
  end

  return nil
end

return Names
