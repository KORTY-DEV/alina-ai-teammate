# Contributing

Contributions should preserve the product invariants in `docs/PRODUCT_REQUIREMENTS.md`:

- player intent always wins;
- development and tests never load an original user save;
- runtime choices come from live prototypes and recipes instead of vanilla-only names;
- sensing and execution remain bounded and deterministic, with no per-tick factory scans or LLM control loop;
- failed construction leaves the existing factory intact;
- multiplayer state changes remain lockstep-safe.

Before submitting a change, run the focused test for the affected subsystem, `scripts/Test-Project.ps1`, `scripts/Run-QualityGate.ps1` and `scripts/Package-Mod.ps1`. Performance-sensitive changes should also pass `scripts/Test-AlinaPerformance.ps1`; fluid and rail changes have dedicated tests.

Do not commit saves, autosaves, diagnostics, credentials, local configuration, model blobs, generated build output or personal filesystem paths. Keep unrelated user changes intact and document any test that still requires manual verification.
