local Identity = {}

local function setting(name, fallback)
  local row = settings.global[name]
  return row and row.value or fallback
end

function Identity.name()
  local value = tostring(setting("alina-display-name", "Алина") or "Алина")
  value = string.gsub(value, "^%s+", "")
  value = string.gsub(value, "%s+$", "")
  if value == "" then return "Алина" end
  return value
end

function Identity.message(content)
  return {"", "[", Identity.name(), "] ", content}
end

function Identity.print(player, content)
  if player and player.valid then player.print(Identity.message(content)) end
end

return Identity
