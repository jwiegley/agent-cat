# engine/acp

`agentic-acp` implements Agent Client Protocol transport behind `Agentic.Engine`.
It owns process lifecycle, JSON-RPC/ACP frames, sessions, permissions, stop reasons,
steering, common model-setting application, and transport failures.

## Public API

`Agentic.Acp` exposes connection/configuration primitives, neutral `AdapterSpec`,
ACP-specific `AcpModelConfig`, and `engineOfAcp`/`engineOfAcpConfigured`. Arbitrary
ACP configuration options stop at this package boundary. Claude, Codex, and Droid
commands/pins belong to child selector packages.

## Dependencies and adjacent modules

```text
engine/acp -> engine/api
engine/acp/{claude,codex,droid} -> engine/acp
cli -> engine/acp and selectors
runtime -> engine/api (never ACP)
```

`agentic-engine` is the sole local dependency.

## Build and test

```sh
nix develop path:../.. -c cabal build agentic-acp
./engine/acp/ci/acp.sh
```

`ci/route-live.sh` is manual and paid; never invoke it automatically.

## Conventions

Return raw neutral results. Decode/retry/failover/memo policy stays in runtime;
provider selector policy stays in the three children. Preserve ACP permissions,
completion evidence, bounded frames, cleanup, and exact diagnostics.
