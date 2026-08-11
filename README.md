# Alina AI Teammate for Factorio

> **Not a chat box next to Factorio. A second engineer inside your factory.**

**Alina** is an autonomous teammate for **Factorio 2.1 + Space Age**. She exists as a separate visible character, understands the factory through the Factorio Lua API, chooses useful bounded tasks, gathers materials, builds real connected production, checks whether it actually works, and yields when a human player is working in the same area.

This is the **first public playable MVP / early-access release**. The foundation is already playable; the roadmap from here is about making Alina broader, smarter and more capable — trains, planets, deeper late-game chains and combat are still ahead.

**Author: Korty / KORTYDEV**

## Why this is different

Alina is built to behave like a teammate, not like a command console or a scripted showcase:

- **A real physical character.** She walks, mines, carries items, builds, equips gear and can use her own Spidertron.
- **Existing factories are first-class.** She can join a real developed save instead of requiring a clean sandbox made for her.
- **She understands the actual modded game.** Recipes, machines, technologies, fluids and upgrades are read from live runtime prototypes instead of hard-coded vanilla assumptions.
- **She builds systems, not props.** Connected miners, smelting/assembly, belts, inserters, power, buffers and multi-fluid production blocks are planned as working chains.
- **She verifies results.** A task is not considered successful just because entities were placed; production and state are checked afterwards.
- **She can roll back her own failed construction.** Existing player infrastructure is protected from an unfinished task.
- **Player intent wins.** Active player areas, protected zones and explicit ownership rules take priority over autonomy.
- **Multiplayer-safe architecture.** The release gate includes a host + two clients, disconnect/rejoin and no desync report.
- **No screenshots are needed to understand the factory.** The World Model is built directly from Factorio state.
- **No giant per-tick inference loop.** Ordinary gameplay is deterministic and bounded; the optional local model is only for limited high-level requests.

The result is already far beyond a proof-of-concept: on a copy of a real K2SO save, Alina independently selected work, built and verified a useful four-machine production block, while the save-copy integrity hash remained unchanged after the test.

And this is **version 0.1.0**.

## Verified release gate

The current playable MVP passed:

- clean .NET build with no warnings;
- contract tests: **15/15**;
- full physical E2E;
- multiplayer host + 2 clients, disconnect/rejoin, no desync report;
- multi-fluid production E2E;
- rail-safety E2E;
- performance and megabase endurance checks;
- a real K2SO save-copy test with an autonomously built and verified 4-machine production block;
- save-copy integrity verification;
- project quality gate.

Detailed evidence and current limits: [`docs/CURRENT_STATUS.md`](docs/CURRENT_STATUS.md).

# Start playing

There are **two ways to use Alina**.

## 1. Full local mode — recommended

This is the complete repository workflow with the local bridge and optional high-level local model.

### Requirements on Windows

- Factorio 2.1;
- **.NET 8 SDK**;
- **Ollama**;
- several GB of free disk space for the local model.

Install the two runtime dependencies once:

```powershell
winget install Microsoft.DotNet.SDK.8
winget install Ollama.Ollama
```

You do **not** need to manually search for or download the Alina model. On the first full-mode launch, the launcher checks Ollama and automatically downloads **`qwen3.5:4b`** if it is missing. Later launches reuse the already downloaded model.

### Continue an existing factory

Close Factorio and run:

```text
START_ALINA_PLAYABLE.cmd
```

What happens:

1. Alina's launcher finds your latest Factorio save.
2. It creates a separate safe save called `Alina-Playable.zip`.
3. **Your original save is not used as the working copy.**
4. The Alina mod is enabled without changing the enabled/disabled state of other mods.
5. The local bridge starts.
6. Factorio opens directly into the safe copy.
7. Alina appears as a second character and can begin analysing the factory.

To deliberately recreate the safe copy from your newest save later, use:

```text
RESET_ALINA_PLAYABLE_FROM_LATEST_SAVE.cmd
```

### Start a completely new game with Alina

Run:

```text
START_ALINA_NEW_GAME.cmd
```

Factorio opens at the normal main menu with Alina already enabled and the local bridge running. Choose **New game**, configure the world normally and start playing. There is no requirement to have an existing save.

### First command

You do not need to constantly micromanage her. After the world loads, Alina can work autonomously. You can also redirect her in Russian, for example:

```text
Аля, продолжай развивать базу
```

or give a more concrete priority, protected area, research request or map marker target.

## 2. Mod-only mode

The packaged Factorio mod can also be installed normally into the Factorio `mods` folder. Core deterministic world modelling, autonomy and supported in-game commands live inside the mod; the local bridge/model is an optional extension for bounded high-level requests.

This mode is the simplest installation if you do not want to install Ollama or .NET.

## Architecture

```text
Factorio 2.1 / Space Age
        │
        ├── deterministic Lua runtime
        │     ├── World Model
        │     ├── planner / autonomy
        │     ├── movement / construction
        │     ├── player-conflict policy
        │     └── verification / rollback
        │
        └── optional localhost bridge
              └── local qwen3.5:4b for bounded high-level requests
```

No screenshots are used to understand the factory. Low-level gameplay stays deterministic and bounded.

## Current capabilities

The first release already includes:

- physical mining, crafting and acquisition from existing storage/machines;
- planned construction inventory and equipment/fuel handling;
- drills, furnaces, assemblers, belts, inserters, poles, buffers and robot logistics;
- connected item-production blocks and long belt routes;
- multi-fluid production using real fluidbox topology, isolated lines, tanks and powered pumps;
- production/consumption analysis and bottleneck classification;
- power repair and capacity handling;
- player-priority zones and permanent protected areas;
- research priority, pause and return-to-autonomy control;
- runtime mod-aware recipe/prototype/technology selection;
- transactional construction, verified upgrades and rollback;
- movement on belts, robots, equipment, Spidertron and rail-crossing safety;
- Russian names and commands including `Алина`, `Аля`, `Алечка` and custom variants.

Full capability document: [`docs/ALINA_MVP_CAPABILITIES_RU.md`](docs/ALINA_MVP_CAPABILITIES_RU.md).

## Current limitations

Not included in `0.1.0` yet:

- full train-network design/control;
- interplanetary logistics and planet progression;
- large-scale combat strategy;
- guaranteed autonomous victory for every possible modpack;
- arbitrary-depth late-game fluid-chain solving;
- general megabase optimization.

These are roadmap items, not claims hidden behind the first release.

## Repository map

- `factorio-mod/alina-ai-teammate_0.1.0/` — Factorio mod source;
- `bridge/` — optional localhost bridge;
- `scripts/` — launchers, packaging and release-gate scripts;
- `tests/fixtures/` — deterministic test fixtures;
- `docs/ARCHITECTURE.md` — architecture;
- `docs/CURRENT_STATUS.md` — verified current state;
- `docs/ALINA_MVP_CAPABILITIES_RU.md` — detailed capability description;
- `docs/INSTALL_AND_RUN.md` — installation/troubleshooting;
- `docs/MOD_PORTAL.md` — Mod Portal release text.

## Validation

```powershell
scripts\Test-Project.ps1
scripts\Test-AlinaFluids.ps1
scripts\Test-AlinaRailSafety.ps1
scripts\Test-AlinaPerformance.ps1
scripts\Run-QualityGate.ps1
scripts\Package-Mod.ps1
```

## Support the project

If Alina becomes useful to you and you want to accelerate the next versions, a project-support link will be added here.

## License

Copyright © 2026 KORTYDEV. All rights reserved.

The source is public for inspection, security review and evaluation. Reuse, modification, redistribution, relicensing or derivative works require prior written permission. See [`LICENSE`](LICENSE).

---

**Alina AI Teammate for Factorio — by Korty**
