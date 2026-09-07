# engine/acp/droid

`engine/acp/droid/src` owns only the selection of the Factory Droid ACP adapter.

## Public module

`Agentic.Acp.Droid` exports `droidAdapter`, which represents the command
`droid exec --output-format acp` followed by the operator's arguments byte for
byte. It uses the native ACP mode of Droid and needs no Python SDK. The
executable must be on `PATH`, and it must be authenticated locally or through
an inherited `FACTORY_API_KEY`.

## Dependencies

`engine/acp` is the sole local dependency, and the CLI selects the returned
`AdapterSpec`. This directory never imports the DSL, the planner, the runtime,
workflow modules, conformance support, the deck engine, or another selector.

## Build and test

```sh
nix develop path:. -c cabal build all
./engine/acp/ci/acp.sh
```

## Conventions

Own only the Factory Droid command and pin policy. Common ACP protocol behavior
belongs to the parent directory, and runtime policy belongs to the runtime.
