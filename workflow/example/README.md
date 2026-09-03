# workflow/example

`workflow/example` holds the small teaching and representation examples.
`Harden` exports the flagship `hardenProgram`, whose first-order term is frozen
as corpus entry `example-000` and proved accepted in
`model/Agentic/Core/DslFlagship.lean`. `Hello` exports `helloProgram`, the
smallest complete program, which the manual's first chapter walks through.
`Structured` exports the structured-answer programs and the host record whose
schema one `deriveSchema` splice derives.

## Dependencies

`dsl` is the sole local dependency. The CLI registers these values, and the
conformance suite rebuilds `hardenProgram` and `helloProgram` against the
frozen corpus.

## Build and test

```sh
nix develop path:. -c cabal build all
./cli/ci/examples.sh
./bisim/ci/tier0.sh
```

## Conventions

Keep the examples small, symbolic, and engine-independent. `hardenProgram` and
`helloProgram` must print exactly as their frozen fixtures do. Help pages and
canned answers stay in `cli/example`.
