# Droid ACP selector maintenance

- Own only Droid's native ACP command selection.
- Preserve `droid exec --output-format acp` and literal following arguments.
- Depend on common ACP API, never DSL, plan, runtime, CLI, workflows, or other engines.
