# Contributing

Alina AI Teammate is currently source-available under the repository `LICENSE`; it is not an open-source project.

If you want to contribute, open an issue first and describe the proposed change. Do not assume permission to reuse project code outside this repository.

Contributions should preserve the product invariants in `docs/PRODUCT_REQUIREMENTS.md`:

- player intent always wins;
- development and tests never load an original user save;
- runtime choices come from live prototypes and recipes instead of vanilla-only names;
- sensing and execution remain bounded and deterministic, with no per-tick factory scans;
- failed construction leaves the existing factory intact;
- multiplayer state changes remain lockstep-safe.

Before submitting a change, run the focused test for the affected subsystem, `scripts/Test-Project.ps1`, `scripts/Run-QualityGate.ps1` and `scripts/Package-Mod.ps1`. Performance-sensitive changes should also pass `scripts/Test-AlinaPerformance.ps1`; fluid and rail changes have dedicated tests.

Do not commit saves, autosaves, diagnostics, credentials, local configuration, generated build output or personal filesystem paths.

By submitting a pull request, you confirm that you have the right to contribute the submitted material and permit the repository owner to use that contribution as part of this project under the project's current or future distribution terms.
