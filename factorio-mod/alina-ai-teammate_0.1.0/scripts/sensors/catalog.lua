local State = require("scripts.core.state")

local Catalog = {}
local Identity = require("scripts.core.identity")

local phases = {"item", "recipe", "entity", "technology", "quality"}

local function collection(kind)
  if kind == "item" then return prototypes.item end
  if kind == "recipe" then return prototypes.recipe end
  if kind == "entity" then return prototypes.entity end
  if kind == "technology" then return prototypes.technology end
  if kind == "quality" then return prototypes.quality end
  return nil
end

local function sorted_names(items)
  local names = {}
  if items then
    for name in pairs(items) do
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

local function describe(kind, prototype)
  local row = {kind = kind, name = prototype.name}
  if kind == "item" then
    row.stack_size = prototype.stack_size
  elseif kind == "entity" then
    row.entity_type = prototype.type
  elseif kind == "recipe" then
    row.category = prototype.category
    row.energy = prototype.energy
  elseif kind == "quality" then
    row.level = prototype.level
  end
  return row
end

function Catalog.start(player_index)
  local root = State.ensure()
  root.catalog_export = {
    phase = 1,
    index = 1,
    names = sorted_names(collection(phases[1])),
    player_index = player_index
  }
  helpers.write_file("alina/catalog.jsonl", helpers.table_to_json({
    kind = "meta",
    schema_version = 1,
    tick = game.tick,
    active_mods = script.active_mods
  }) .. "\n", false, 0)
end

function Catalog.is_active()
  return State.ensure().catalog_export ~= nil
end

function Catalog.on_nth_tick()
  local root = State.ensure()
  local job = root.catalog_export
  if not job then return end

  local kind = phases[job.phase]
  local items = collection(kind)
  local output = {}
  local processed = 0

  while job.index <= #job.names and processed < 100 do
    local prototype = items and items[job.names[job.index]] or nil
    if prototype then
      output[#output + 1] = helpers.table_to_json(describe(kind, prototype))
      root.metrics.catalog_rows = root.metrics.catalog_rows + 1
    end
    job.index = job.index + 1
    processed = processed + 1
  end

  if #output > 0 then
    helpers.write_file("alina/catalog.jsonl", table.concat(output, "\n") .. "\n", true, 0)
  end

  if job.index > #job.names then
    job.phase = job.phase + 1
    if job.phase > #phases then
      local player = game.get_player(job.player_index)
      root.catalog_export = nil
      if player then Identity.print(player, "Каталог прототипов экспортирован по частям.") end
      return
    end
    job.index = 1
    job.names = sorted_names(collection(phases[job.phase]))
  end
end

return Catalog
