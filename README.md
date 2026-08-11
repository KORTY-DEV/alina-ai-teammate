# Alina AI Teammate for Factorio

**Playable MVP / early-access release for Factorio 2.1 + Space Age.**

Alina is an autonomous local teammate for existing Factorio factories. She appears as a separate visible character, reads the real factory through the Factorio Lua API, chooses bounded useful tasks, gathers materials, builds production, verifies the result and yields to player intent.

This is the first public playable version — not a promise of full autonomous completion of every modpack.

## What works now

- separate physical character with persistent state;
- existing-save-first workflow using a safe copy of the save;
- mod-aware World Model built from live prototypes, recipes, technologies and known factory state;
- physical mining, crafting and material acquisition from existing storage/machines;
- connected item-production blocks with drills, furnaces/assemblers, belts, inserters, power and buffers;
- multi-fluid production blocks using real fluidbox topology, tanks and powered pumps;
- bottleneck detection for upstream shortages, power limits and blocked outputs;
- player-priority zones, explicit protected areas and ownership-aware conflict handling;
- research priority, pause and return-to-autonomy commands;
- construction transactions, result verification and rollback when a task makes things worse;
- equipment/fuel handling, construction robots and Alina's own Spidertron;
- safe rail crossing without train-network control;
- deterministic ordinary gameplay without per-tick full-factory scans.

## Verified release gate

The current `0.1.0` playable MVP passed:

- clean .NET build with no warnings;
- contract tests: **15/15**;
- full physical E2E;
- multiplayer host + 2 clients, disconnect/rejoin, no desync report;
- fluid-production E2E;
- rail-safety E2E;
- performance and megabase endurance checks;
- real K2SO save-copy test where Alina autonomously built and verified a useful 4-machine production block;
- save-copy integrity check with unchanged SHA-256 after the test;
- project quality gate.

Detailed evidence and current limits: [`docs/CURRENT_STATUS.md`](docs/CURRENT_STATUS.md).

## Quick start

1. Close Factorio.
2. Put the packaged mod in your Factorio `mods` folder, or use the repository launcher for development/testing.
3. Start a **copy** of the save you want to use first.
4. In game, address Alina in Russian, for example:

```text
Аля, продолжай развивать базу
```

For the repository workflow on Windows:

```text
START_ALINA_PLAYABLE.cmd
```

To rebuild a safe playable copy from the latest save:

```text
RESET_ALINA_PLAYABLE_FROM_LATEST_SAVE.cmd
```

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
        └── optional local bridge for bounded high-level requests
```

The mod does not use screenshots to understand the factory. Low-level gameplay remains deterministic and bounded; optional high-level assistance is outside the per-tick gameplay loop.

## Tested scope

The current release is aimed at real existing factories, including large mod-aware saves. It has been exercised against Factorio 2.1.12 + Space Age and K2/K2SO-style runtime prototypes.

## Current limitations

Not included in `0.1.0`:

- full train-network design/control;
- interplanetary logistics and planet progression;
- large-scale combat strategy;
- guaranteed full autonomous victory for arbitrary modpacks;
- arbitrary-depth late-game fluid-chain solving;
- general megabase optimization.

## Repository map

- `factorio-mod/alina-ai-teammate_0.1.0/` — Factorio mod source;
- `bridge/` — optional local bridge;
- `scripts/` — packaging, validation and release-gate scripts;
- `tests/fixtures/` — deterministic test fixtures;
- `docs/ARCHITECTURE.md` — architecture;
- `docs/CURRENT_STATUS.md` — verified current state;
- `docs/ALINA_MVP_CAPABILITIES_RU.md` — full Russian capability description;
- `docs/MOD_PORTAL.md` — Mod Portal release text/checklist.

## Validation

```powershell
scripts\Test-Project.ps1
scripts\Test-AlinaFluids.ps1
scripts\Test-AlinaRailSafety.ps1
scripts\Test-AlinaPerformance.ps1
scripts\Run-QualityGate.ps1
scripts\Package-Mod.ps1
```

## License

Copyright © 2026 KORTYDEV. All rights reserved.

The source is public for inspection, security review and evaluation. Reuse, modification, redistribution, relicensing or derivative works require prior written permission. See [`LICENSE`](LICENSE).

---

**Alina AI Teammate for Factorio — by Korty**
