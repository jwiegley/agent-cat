# engine/acp/droid

`agentic-acp-droid` owns Factory Droid's native ACP command selection.

## Public API

`Agentic.Acp.Droid` exports `droidAdapter`, representing
`droid exec --output-format acp` with literal following arguments.

## Dependencies and adjacent modules

Its sole local dependency is `agentic-acp`; CLI selects the returned `AdapterSpec`.
No DSL, plan, runtime, workflow, bisim, deck, or other selector dependency is allowed.

## Build and test

```sh
nix develop path:../../.. -c cabal build agentic-acp-droid
./engine/acp/ci/acp.sh
```

## Conventions

Preserve the native command and byte-for-byte user arguments; own no common ACP
protocol or runtime policy.
