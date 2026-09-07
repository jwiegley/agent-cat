# Factory Droid ACP selector maintenance

Own only the Factory Droid adapter command and pin selection. Preserve the command `droid exec --output-format acp` and the literal
arguments that follow it. Depend on the
common ACP module, and never on the DSL, the planner, the runtime, the CLI,
workflow modules, or another engine.
