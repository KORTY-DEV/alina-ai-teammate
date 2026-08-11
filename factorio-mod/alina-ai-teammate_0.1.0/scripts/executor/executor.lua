local State = require("scripts.core.state")
local Agent = require("scripts.agent.agent")
local TaskManager = require("scripts.tasks.manager")
local Mining = require("scripts.executor.mining")
local Shortage = require("scripts.executor.shortage")
local Power = require("scripts.executor.power")
local LineExpander = require("scripts.executor.line_expander")
local Loadout = require("scripts.executor.loadout")
local Upgrader = require("scripts.executor.upgrader")

local Executor = {}

function Executor.needs_tick()
  return TaskManager.has_active_task() or Agent.needs_tick()
end

function Executor.on_tick()
  if not Executor.needs_tick() then return end

  local root = State.ensure()
  root.metrics.executor_active_ticks = root.metrics.executor_active_ticks + 1
  local agent = Agent.try_respawn()
  if not agent then return end

  local task = root.task.current
  if not task then return end
  if root.paused then
    Agent.stop()
    return
  end

  if task.type == "mine_resource" then
    Mining.tick(task, agent)
  elseif task.type == "resolve_shortage" then
    Shortage.tick(task, agent)
  elseif task.type == "repair_power" then
    Power.tick(task, agent)
  elseif task.type == "expand_line" then
    LineExpander.tick(task, agent)
  elseif task.type == "maintain_loadout" then
    Loadout.tick(task, agent)
  elseif task.type == "upgrade_machine" then
    Upgrader.tick(task, agent)
  else
    TaskManager.fail("Исполнитель не поддерживает тип задачи " .. tostring(task.type) .. ".")
  end
end

return Executor
