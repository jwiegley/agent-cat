# ACP maintenance

Depend only on `engine/api`. Never import the DSL, the planner, the runtime,
the CLI, conformance support, the deck engine, or workflow modules. Own the ACP
wire behavior, permissions, completion evidence, configuration, and process
cleanup here, and return raw neutral results. Preserve the deterministic stub
behavior and the exact external diagnostics. Provider selector policy lives in
the `claude`, `codex`, and `droid` children.
