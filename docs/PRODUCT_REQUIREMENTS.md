# Alina AI Teammate — product requirements

This is the single source of truth for the requested playable MVP and later public release. Implementation status belongs in `CURRENT_STATUS.md`; this file describes required behaviour.

## Product goal and scope order

Alina is a real second Factorio player who joins an existing save and continuously develops the factory alongside human players. The first release target is the user's existing Factorio 2.1.12 + Space Age + K2SO/Cerys/Moshine save, always tested through a byte-identical copy. A new-game demo, trains, planets and advanced combat never take priority over this existing-save loop.

The playable loop is:

`understand the existing factory -> find the highest-value bottleneck -> plan the complete change -> acquire a bounded kit -> build/upgrade -> commission and measure -> continue with the next useful goal`.

## Non-negotiable safety and player intent

- `PLAYER INTENT > AI INTENT` for every human player. Alina yields when a player works on the same goal or area, does not duplicate/rebuild their work and asks only when intent is genuinely ambiguous.
- Direct Russian instructions override autonomous intent. Explicit priorities, prohibitions, pauses and durations are persistent game state and are obeyed exactly.
- Mass deconstruction, radical redesign, critical rail/power changes, rare-resource spending and large attacks require confirmation.
- Never change an original save during development. No personal paths, secrets or credentials in release artifacts.
- A change is complete only after real output/energy/logistics are verified. Failure leaves no half-demolished production.

## Performance architecture

- No screenshots are required for factory understanding.
- Factorio Lua APIs, prototypes, recipes, technologies, statistics, events and a persistent World Model are authoritative.
- LLM is used only for language, goal choice and difficult planning. Movement, pathing, caching, sensing, conflict control and execution are bounded deterministic code.
- No per-tick full factory scans, full World Model dumps or chat/model polling. Work is event-driven and budgeted to preserve UPS/FPS.
- `qwen3.5:4b` remains the default local model until measurements on the target PC prove a better choice is necessary.

## Factory intelligence at every scale

- Index the whole charted/known factory over time. A direct development command triggers a fast bounded refresh around the player, but does not discard distant known districts.
- Track machines, recipes, statuses, inventories/buffers, logistics, power networks, mining patches, technologies, construction coverage, player activity and modded/quality prototypes.
- Use production and consumption statistics over several windows, not a single instantaneous count. Distinguish startup noise, blocked output, missing input, saturated transport, insufficient machine capacity, power shortage and healthy demand.
- Maintain configurable headroom for future growth. A line producing about 7000/h while consuming 6900–7000/h is constrained even if it has not stopped.
- On a large factory, prefer modules, beacons, machine-tier upgrades, belt/logistic balancing and targeted replacement over blindly appending primitive blocks.
- Absence of current demand is never a reason to stop developing an incomplete factory. Fill missing foundation mining/processing/power/science/logistics, then advance to the next unlocked useful production tier and keep a practical stock reserve.
- A token pair of drills is not a developed ore patch. Cover the useful safe footprint with the strongest obtainable tier; when a working patch falls to roughly 50% of its original reserve, prepare another adequate patch before it becomes a bottleneck.
- Do not delete a small old producer merely because it is old. In-place replacement is allowed as a transaction: prepare materials and temporary buffer, record recipe/directions/connections, remove, rebuild better in the same footprint, reconnect, verify higher safe capacity, then finalize. Restore/rollback on failure.

## Planning, construction and supplies

- Plan a complete useful block before walking. Never treat one isolated machine as an adequate production expansion.
- Size mines for the useful accessible patch and use the best safe unlocked mod-aware drills; connect mining, transport, processing, power and output handling.
- Reuse existing production and storage before crafting. Acquire in this order when practical: nearby/logistic/base inventories -> hand-craft short/simple intermediates -> temporary automated production for long/bulk work.
- Carry a planned basic construction/repair/loadout reserve while keeping the main inventory around 60–70% full, with room for outputs and unexpected pickups.
- Choose machines, belts, inserters, poles, modules, fuels and quality levels from live prototypes and recipes. Treat rare/high-quality equipment and modules conservatively.
- Use construction/logistic robots when covered and faster, including exact-footprint tree/rock clearing. Do not clear unrelated terrain.
- Support complete belt routes from marked ore to the selected base destination with obstacle routing and commissioning.
- Build fluid systems from live recipe/entity fluidboxes, including modded fluids and machines. Reserve every port against cross-contamination and commission real output/byproducts.
- In Factorio 2.1, do not add pumps merely because an ordinary pipe is long: read the live pipeline-extent limit and available pump capacity. Split a route with powered directional pumps before the limit; use independently separated parallel lanes only when required flow exceeds one safe pump lane.

## Research and map markers

- Alina may choose useful research only while research control is delegated to her.
- Player-selected research is never replaced. Cancellation/disable commands are respected until explicitly released; timed holds such as 30 minutes use game time.
- Player priority technologies include their unlocked prerequisite chain. Player changes always win.
- Understand named, most-recent and GPS/map markers. Commands may bind a build, ore-patch development or belt destination to a marker.

## Movement and equipment

- Natural pathing must detect lack of progress, repath, use bounded local detours and never oscillate between two headings indefinitely.
- Belts are weighted by actual prototype speed and direction. Prefer a helpful belt as a speed route; cross/accept a slower adverse belt when necessary; avoid an adverse belt that can overpower current walking speed unless a safe detour or belt-immunity equipment is available.
- Discover modded movement equipment from live prototypes. Select among walking, belt-immunity/exoskeleton or flying-capable armour/backpack and Spidertron only when unlocked, available, safe and materially better for the current route/task.
- Vehicle/Spidertron use must preserve inventory, ownership and player access and must not strand or commandeer a player's vehicle.
- Once Alina has an owned Spidertron on an established factory, it is her primary transport: she stays mounted between jobs and keeps using it for short routes instead of repeatedly abandoning it.
- Burner-powered personal equipment and owned vehicles are refuelled deterministically when their reserve reaches roughly 40%, back to about 90-100%, using compatible mod-aware fuel without taking over another player's vehicle.
- Before crossing ground rails, use a bounded deterministic near-path check: wait for an approaching train, clear the track instead of freezing when already on it, then resume. Full train dispatch, signalling and network redesign remain deferred.

## Communication and settings

- GUI and chat are concise Russian by default. Prototype names use the active locale; unknown modded names receive a readable Russian type/colour/ordinal description instead of raw identifiers where possible.
- No autonomous progress spam. The panel shows one current goal, one short phase, useful world-model progress and an understandable bridge/transport state. Chat is for direct acknowledgements, confirmations, blockers and final results.
- Runtime settings include display name, several comma-separated address aliases, autonomy, UI verbosity and rare praise frequency. Default name is `Алина`; default aliases include `Алина, Аля, Алечка` and natural forms.
- Praise is deterministic, short, context-based, rare and never invokes the LLM or performs extra scans.

## Singleplayer and multiplayer transport

- Normal local play is one Factorio process in singleplayer. Localhost UDP is allowed only for that singleplayer bridge path.
- Multiplayer must be deterministic lockstep-safe. All state-changing external plans enter as synchronized Factorio input (server RCON/command path); clients never apply private UDP state changes.
- No mutable runtime locals may influence game/storage state across ticks. Migrations occur only in supported lifecycle hooks and all persistent decisions live in `storage`.
- Public-release gate: repeated join/rejoin plus host and at least two clients, chat commands, autonomous planning, physical construction and forced CRC checks complete without a desync report.

## Release acceptance gates

1. A fresh byte-identical copy of the real K2SO save loads without editor mode and Alina appears as a second visible character.
2. `Аля, продолжай развивать базу` produces a verified factory/power improvement, not only personal armour or wandering.
3. The player can build the same goal and Alina yields/replans.
4. Russian direct mining, storage acquisition, crafting, complete automated blocks, research holds/priorities and marker tasks pass end to end.
5. No chat flood, repeated path oscillation, freeze, original-save modification or measurable UPS regression.
6. Singleplayer needs no server. Multiplayer passes the deterministic release gate above.
7. A realistic K2SO endurance map contains at least 50,000 active player-force entities, at least 10,000 production/logistics entities, real recipes and flowing items; decorative belt count alone is not accepted as megabase evidence.
