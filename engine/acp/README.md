# engine/acp

`engine/acp/src` implements the Agent Client Protocol transport behind
`Agentic.Engine`. It owns the lifecycle of the adapter process, the JSON-RPC
frames, sessions, permission decisions, stop reasons, steering, the
application of common model settings, and transport failures.

## Public module

`Agentic.Acp` exposes the connection and configuration primitives, the neutral
`AdapterSpec`, the ACP-specific `AcpModelConfig`, and the two constructors
`engineOfAcp` and `engineOfAcpConfigured`. Arbitrary ACP configuration options
stop at this boundary and never enter the neutral engine API. `AcpConfig` also
carries an opaque `ChildEnvironment`. Its default inherits the complete ambient
environment, as version 1 did. Version-2 CLI composition can supply one explicit
map whose `Show` instance reveals only a binding count, and the retained ACP
configuration discards it after process creation.

Permission follows the intent of a request. `permissionByIntent` grants a tool
request only for an effect-annotated occurrence, and it cancels the request for
consultations and observations. Every decision is announced on standard error.
The commands and pins for Claude, Codex, and Droid belong to the three child
directories.

## Dependencies

`engine/api` is the sole local dependency. The three selector directories
depend on this one, and the CLI depends on all four. The runtime never imports
this directory.

## Build and test

```sh
nix develop path:. -c cabal build all
./engine/acp/ci/acp.sh
```

The gate drives the deterministic adapters under `test/` over real pipes. The
first of them is `stub_adapter.py`, and none of them is a real agent. The
script `ci/route-live.sh` contacts paid backends, and an operator runs it only
by explicit choice.

## Conventions

Return raw neutral results. Decoding, retry, fail-over, and memoization stay in
the runtime, and provider selection stays in the children. Preserve the
permission policy, the completion evidence, the bounded frames, the process
cleanup, and the exact diagnostics.
