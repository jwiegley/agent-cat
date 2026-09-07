# workflow/extra

`workflow/extra` holds `Isaac`, the module with the five workflows that were
derived from incite, together with the prompt library that they share. The
five values are `planFeatureProgram`, `reviewLite`, `shipFeatureLiteProgram`,
`grindTestsProgram`, and `stackPRsProgram`. The module also exports the prompt
text that the deterministic fixtures of the CLI reuse.

## Dependencies

`dsl` is the sole local dependency. The CLI registers these values. No sibling
workflow, planner, cost, runtime, engine, extension, or conformance dependency
is allowed.

## Build and test

```sh
nix develop path:. -c cabal build all
./cli/ci/examples.sh
```

The examples gate pins the level, the size, the ask-node count, the cost
summary, and the scripted bills of each program.

## Conventions

The serving names `balanced`, `review`, `reasoning`, and `coding` are symbolic
profile names. Their concrete realizations appear only in
`cli/model-definitions.example.yaml`. Keep the prompt text in one place.
Registry rows, operator help, routing, and scripted execution stay in `cli`.
