# engine/acp

`engine/acp/src` implements the Agent Client Protocol transport behind
`Agentic.Engine`. It owns the adapter process lifecycle, the JSON-RPC frames,
sessions, permission decisions, stop reasons, steering, the application of
common model settings, and transport failures.

## Public module

`Agentic.Acp` exposes the connection and configuration primitives, the neutral
`AdapterSpec`, the ACP-specific `AcpModelConfig`, and the two constructors
`engineOfAcp` and `engineOfAcpConfigured`. Arbitrary ACP configuration options
stop at this boundary and never enter the neutral engine API. Permission
follows intent: `permissionByIntent` grants a tool request only for an
effect-annotated occurrence and cancels it for consultations and observations,
and every decision is announced on standard error. The commands and pins for
Claude, Codex, and Droid belong to the three child directories.

## Dependencies

`engine/api` is the sole local dependency. The three selector directories
depend on this one, and the CLI depends on all four. The runtime never imports
this directory.

## Build and test

```sh
nix develop path:. -c cabal build all
./engine/acp/ci/acp.sh
```

The gate drives the deterministic adapters under `test/`, beginning with
`stub_adapter.py`, over real pipes and never a real agent.
`ci/route-live.sh` contacts paid backends and is run only by explicit operator
choice.

## Conventions

Return raw neutral results; decoding, retry, fail-over, and memoization stay in
the runtime, and provider selection stays in the children. Preserve the
permission policy, completion evidence, bounded frames, process cleanup, and
exact diagnostics.
