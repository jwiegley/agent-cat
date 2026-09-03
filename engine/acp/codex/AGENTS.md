# Codex ACP selector maintenance

Own only the Codex adapter command and pin selection. Preserve the resolution order, which searches `PATH` first and falls back to
the pinned path. Depend on the
common ACP module, and never on the DSL, the planner, the runtime, the CLI,
workflow modules, or another engine.
