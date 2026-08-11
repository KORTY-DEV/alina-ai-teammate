local fast_belt = table.deepcopy(data.raw["transport-belt"]["express-transport-belt"])
fast_belt.name = "alina-test-fast-belt"
fast_belt.speed = 0.25
fast_belt.minable = nil
fast_belt.next_upgrade = nil
fast_belt.hidden = true
data:extend({fast_belt})
