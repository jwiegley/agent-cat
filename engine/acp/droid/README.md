# engine/acp/droid

`engine/acp/droid/src` owns the selection of the Factory Droid ACP adapter and
nothing else.

## Public module

`Agentic.Acp.Droid` exports `droidAdapter`, which represents `droid exec --output-format acp` followed by the operator's arguments byte for byte. It uses Droid's native ACP mode and needs no Python SDK. The executable must be on `PATH` and authenticated locally or through an inherited `FACTORY_API_KEY`.

## Dependencies

`engine/acp` is the sole local dependency, and the CLI selects the returned
`AdapterSpec`. The DSL, the planner, the runtime, workflow modules,
conformance support, the deck engine, and the other selectors are never
imported.

## Build and test

```sh
nix develop path:. -c cabal build all
./engine/acp/ci/acp.sh
```

## Conventions

Own only the Factory Droid command and pin policy. Common ACP protocol behavior and
runtime policy belong to the parent directory and the runtime.
