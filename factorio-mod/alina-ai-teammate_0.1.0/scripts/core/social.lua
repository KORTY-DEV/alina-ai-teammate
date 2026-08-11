local State = require("scripts.core.state")
local Identity = require("scripts.core.identity")

local Social = {}

local MESSAGES = {
  "Хорошо развиваете фабрику. Я возьму следующую часть.",
  "Отличный темп. Продолжу там, где сейчас полезнее всего.",
  "Вижу вашу работу. Хорошо получается — не буду мешать этому участку."
}

function Social.on_player_activity(player)
  if not player or not player.valid or not player.connected then return end
  local configured = settings.global["alina-praise-frequency"]
  local frequency = configured and configured.value or "rare"
  if frequency == "off" then return end
  local interval = frequency == "normal" and 80 or 200
  local cooldown = frequency == "normal" and 36000 or 108000
  local root = State.ensure()
  local count = (root.social.player_actions[player.index] or 0) + 1
  root.social.player_actions[player.index] = count
  if count % interval ~= 0 then return end
  if game.tick - (root.social.last_praise_by_player[player.index] or -cooldown) < cooldown then return end
  root.social.last_praise_by_player[player.index] = game.tick
  local message_index = (math.floor(count / interval) - 1) % #MESSAGES + 1
  Identity.print(player, MESSAGES[message_index])
end

return Social
