# Security and privacy

Alina AI Teammate is local-first. The Factorio mod contains no credentials, analytics or third-party network endpoints. The optional bridge accepts only loopback transport by default and validates its local Ollama URL and bounded action schema.

Never publish or attach original saves, `player-data.json`, RCON passwords, authentication tokens, local bridge configuration or model files. Reproduce save-specific bugs on a copy and remove personal chat, map labels and server information before sharing it.

For a security report, do not publish secrets or a weaponized save in a public issue. Contact the repository owner privately once a public contact channel is listed. Until then, retain the report locally and provide only a non-sensitive summary.

The project does not auto-upload diagnostics, saves or telemetry. Multiplayer gameplay changes must remain deterministic and synchronized by Factorio; private per-client input must never mutate shared state.
