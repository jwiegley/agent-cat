# workflow/extra

`workflow/extra` holds `Isaac`, the five workflows derived from incite together
with the prompt library they share: `planFeatureProgram`, `reviewLite`,
`shipFeatureLiteProgram`, `grindTestsProgram`, and `stackPRsProgram`. The
module exports those five values and the prompt text that the CLI's
deterministic fixtures reuse.

## Dependencies

`dsl` is the sole local dependency. The CLI registers these values. No sibling
workflow, planner, cost, runtime, engine, extension, or conformance dependency
is allowed.

## Build and test

```sh
nix develop path:. -c cabal build all
./cli/ci/examples.sh
```

The examples gate pins each program's level, size, ask-node count, cost
summary, and scripted bills.

## Conventions

The serving names `balanced`, `review`, `reasoning`, and `coding` are symbolic
profile names; their concrete realizations appear only in
`cli/model-definitions.example.yaml`. Keep the prompt text single-sourced.
Registry rows, operator help, routing, and scripted execution stay in `cli`.
