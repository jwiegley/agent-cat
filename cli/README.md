# cli

`agentic-cli` is agent-cat's composition root. It combines workflow registries,
pure plan/cost interpreters, runtime, model-definition loading, and concrete
engines into the `agentic-run` executable. No lower package imports CLI.

## Public API

- `Agentic.Cli` — registry and command dispatcher
- `Agentic.Route` — concrete `acp:`/`deck:` backend grammar, re-exporting the
  generic runtime route table
- `Agentic.RoutingConfig` — strict layered model-definition schema and resolver

`Agentic.Chains` and `Agentic.RequirePinned` are hidden implementation modules.
The private `verification` library owns cost/workflow-dependent conformance assembly
and never enters the production CLI library dependency graph.

Registry/help/scripted-reply modules under `example/` are CLI-owned composition
data. Workflow packages export only canonical workflow values.

## Model definitions

Workflow source contains symbolic model/profile names. Optional version-1
`routing.yaml` files map those symbols to routers, concrete models, thinking
levels, output limits, and scalar ACP options. CLI alone discovers, validates,
merges, resolves, preflights, and records those definitions; ACP options enter its
adapter-specific `AcpModelConfig`, never the neutral engine API. User configuration
precedes the nearest project file; a command-line `--route` is the highest
backend override. [`model-definitions.example.yaml`](model-definitions.example.yaml)
is documentation, not an automatic default; it includes every `servedBy` profile
used by the bundled workflows.

## Dependencies

CLI may depend on every lower production package and all workflow registries.
It is the only package that imports concrete engines and chooses Claude, Codex,
Droid, agent-deck, or an explicit adapter path. `ext-pi` invokes its versioned
process protocol and never imports Haskell implementation modules.

## Build and use

From repository root:

```sh
nix develop path:. -c cabal build agentic-cli
nix develop path:. -c cabal run agentic-run -- list
nix develop path:. -c cabal run agentic-run -- plan harden
nix develop path:. -c cabal run agentic-run -- cost harden
nix develop path:. -c cabal run agentic-run -- run harden --scripted
```

External behavior remains the `agentic-run` command, exit codes 0/1/2/3,
descriptor version 2, machine protocol 1, and store format 1.

## Conventions

Keep concrete backend/model selection here and lower APIs identity-neutral. Preserve
routing precedence, strict schema/security refusals, eager preflight, CLI output and
exit mapping. Registry/help/scripted data may describe workflows but must not move
into the workflow packages.

Run `cli/ci/{policies,examples,routing-config}.sh` and both engine gates after
composition changes.
