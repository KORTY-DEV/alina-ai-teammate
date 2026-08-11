local function create_large_factory()
  local surface = game.surfaces[1]
  surface.request_to_generate_chunks({0, 0}, 18)
  surface.force_generate_chunk_requests()
  game.forces.player.chart(surface, {{-576, -576}, {576, 576}})

  local created = 0
  for x = -510, 510, 6 do
    for y = -510, 510, 6 do
      local selector = (math.floor((x + 510) / 6) + math.floor((y + 510) / 6)) % 4
      local name = selector == 0 and "stone-furnace"
        or selector == 1 and "steel-chest"
        or "transport-belt"
      local entity = surface.create_entity({
        name = name,
        position = {x, y},
        force = game.forces.player,
        create_build_effect_smoke = false
      })
      if entity then
        created = created + 1
        if name == "steel-chest" and created % 16 == 0 then
          entity.insert({name = "iron-plate", count = 100})
        end
      end
    end
  end
  storage.alina_performance_test = {entity_count = created, requested = false}
  helpers.write_file("alina/performance-fixture.json",
    helpers.table_to_json({entity_count = created}), false)
end

script.on_init(create_large_factory)

script.on_nth_tick(60, function()
  local state = storage.alina_performance_test
  if not state or state.requested or not remote.interfaces["alina_ai"] then return end
  local player = game.get_player(1)
  if not player then return end
  remote.call("alina_ai", "recall", player.index)
  local result = remote.call("alina_ai", "address", player.index, "Аля, продолжай развивать базу")
  state.requested = result and result.ok == true
end)
