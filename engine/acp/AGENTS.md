# ACP maintenance

- Depend only on `../api`; never import DSL, plan, runtime, CLI, bisim, deck, or workflows.
- Own ACP wire behavior, permissions, completion evidence, configuration, and process cleanup.
- Return raw neutral results; decoding, retry, failover, and memoization belong to runtime.
- Preserve deterministic stub behavior and exact external diagnostics.
- Keep provider selector policy in `claude`, `codex`, and `droid` children.
