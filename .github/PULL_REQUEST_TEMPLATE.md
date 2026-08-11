## What changed?

<!-- Briefly describe the behavior or implementation change. -->

## Why?

<!-- What gameplay or engineering problem does this solve? -->

## Validation

- [ ] Relevant focused test passed
- [ ] `scripts/Test-Project.ps1` passed when applicable
- [ ] `scripts/Run-QualityGate.ps1` passed when applicable
- [ ] No original user save was modified
- [ ] No credentials, personal paths, diagnostics, model blobs or private save data were added

## Alina invariants

- [ ] Player intent still outranks AI intent
- [ ] Runtime choices remain mod-aware where relevant
- [ ] State-changing multiplayer behavior remains deterministic / lockstep-safe
- [ ] Failed construction does not damage unrelated existing factory infrastructure
- [ ] No unbounded per-tick factory scan or model inference loop was introduced

## Notes / screenshots

<!-- Optional: before/after behavior, logs, screenshots or benchmark numbers. -->
