local Acquisition = require("scripts.executor.acquisition")
local RecipeIndex = require("scripts.sensors.recipe_index")
local WorldModel = require("scripts.sensors.world_model")

local ModulePolicy = {}

local MAX_AUTONOMOUS_TIER = 1
local MAX_MODULES_PER_MACHINE = 2
local MAX_ACQUISITION_OPERATIONS = 4

local function numeric_effect(value)
  if type(value) == "number" then return value end
  if type(value) == "table" then return value.bonus or value.value or 0 end
  return 0
end

local function allows(values, name)
  if not values then return true end
  if values[name] == true then return true end
  for key, value in pairs(values) do
    if key == name and value then return true end
    if value == name then return true end
  end
  return false
end

local function candidate_less(a, b)
  if a.obtainability ~= b.obtainability then return a.obtainability < b.obtainability end
  if a.present ~= b.present then return a.present > b.present end
  if a.operations ~= b.operations then return a.operations < b.operations end
  if a.tier ~= b.tier then return a.tier < b.tier end
  if a.speed ~= b.speed then return a.speed > b.speed end
  return a.name < b.name
end

local function cheap_obtainability(agent, name, count)
  local inventory = agent.get_inventory(defines.inventory.character_main)
  if inventory and inventory.get_item_count(name) >= count then return 0 end
  if #WorldModel.inventory_sources(agent, name, agent.position, 1) > 0 then return 0 end
  if RecipeIndex.has_enabled_producer(name, agent.force) then return 1 end
  return 2
end

-- Modules are an optimisation, never a prerequisite for a safe build.  The
-- autonomous policy deliberately stays on normal quality and tier 1 so a mod's
-- rare late-game modules cannot silently disappear into routine production.
function ModulePolicy.choose(agent, machine_row, recipe, high_throughput, machine_count)
  if not high_throughput or (machine_row.module_inventory_size or 0) <= 0 then return nil end
  if machine_row.allowed_effects and not allows(machine_row.allowed_effects, "speed") then return nil end
  if recipe.allowed_effects and not allows(recipe.allowed_effects, "speed") then return nil end

  local inventory = agent.get_inventory(defines.inventory.character_main)
  local candidates = {}
  for name, prototype in pairs(prototypes.item) do
    local effects = prototype.type == "module" and prototype.module_effects or nil
    local speed = effects and numeric_effect(effects.speed) or 0
    local tier = effects and (prototype.tier or 0) or 0
    local category = effects and prototype.category or nil
    if speed > 0 and tier <= MAX_AUTONOMOUS_TIER
        and allows(machine_row.allowed_module_categories, category)
        and allows(recipe.allowed_module_categories, category) then
      local desired_per_machine = math.min(machine_row.module_inventory_size, MAX_MODULES_PER_MACHINE)
      local desired = desired_per_machine * machine_count
      candidates[#candidates + 1] = {
        name = name,
        desired = desired,
        count = desired_per_machine,
        tier = tier,
        speed = speed,
        present = inventory and inventory.get_item_count(name) or 0,
        obtainability = cheap_obtainability(agent, name, desired),
        operations = 0
      }
    end
  end
  table.sort(candidates, candidate_less)
  -- Hundreds of modded modules must not trigger hundreds of recursive
  -- acquisition searches during one planning update. Validate only the best
  -- few normal-quality tier-1 choices; modules remain optional if none qualify.
  for index = 1, math.min(1, #candidates) do
    local candidate = candidates[index]
    -- Modules are optional throughput polish.  Do not hold an otherwise ready
    -- construction project still for minutes while Alina hand-crafts them (or
    -- temporarily commandeers a machine).  Install modules only when the
    -- finished items already exist in her inventory or an indexed output/store;
    -- dedicated module production can be planned as its own useful factory goal.
    if candidate.obtainability > 0 then break end
    -- This is speculative layout selection; construction performs the full
    -- authoritative source scan. Reusing the indexed factory here prevents an
    -- optional module choice from scanning an entire megabase several times in
    -- one tick.
    local acquisition = Acquisition.make_plan(
      agent, candidate.name, candidate.desired, "autonomous", {preview = true})
    if acquisition and #acquisition.operations <= MAX_ACQUISITION_OPERATIONS then
      candidate.operations = #acquisition.operations
      candidate.desired = nil
      candidate.obtainability = nil
      return candidate
    end
  end
  return nil
end

return ModulePolicy
