# cli

`cli` is the composition root of the `agentic` package. It combines the
workflow registries, the pure plan and cost interpreters, the runtime, the
model-definition loader, and the concrete engines into the `agentic-run`
executable. No other directory imports it.

## Layout

`cli/src` holds the library modules. `Agentic.Cli` is the registry and command
dispatcher, `Agentic.Route` is the concrete `acp:` and `deck:` backend grammar
over the generic runtime route table, and `Agentic.RoutingConfig` is the strict
layered model-definition schema and resolver. `Agentic.Chains` and
`Agentic.RequirePinned` are hidden implementation modules. `cli/example` holds
the registry rows, help pages, and scripted replies for the bundled workflows;
they build into the internal `examples` library beside the workflow values
themselves. `cli/run/Main.hs` is the executable, which applies `cliMain` to the
examples registry. `cli/test` holds the policy, routing, and schema probes that
the gate scripts drive. `cli/verification` holds the private `verification`
library, which assembles complete conformance observations, and the `tier1`
and live `bisim` executables.

## External behavior

The command is `agentic-run` with the verbs `list`, `help`, `plan`, `cost`,
`run`, and the machine family `machine`, `machine-restart`, `machine-resume`,
`machine-fork`, and `lineage-check`. Exit status 0 is a completed command, 1 a
usage or preflight refusal, 2 a transport failure, and 3 a run abandoned over
what arrived. `list --json` publishes descriptor version 2; machine mode
speaks protocol version 1 and store format 1. The Texinfo manual's "Runner
Reference" chapter documents every verb and option.

## Model definitions

Workflow source contains symbolic model and profile names. Optional version-1
`routing.yaml` files map those names to routers, concrete models, thinking
levels, output limits, and scalar ACP options. The user file is
`$XDG_CONFIG_HOME/agent-cat/routing.yaml`, and the nearest `.agent-cat/routing.yaml`
between the working directory and the repository boundary is the project
layer, whose named routers and profiles replace their user-layer
counterparts. A command-line `--route` is the highest backend override. The
CLI alone discovers, validates, merges, resolves, preflights, and records
these definitions, and ACP options enter the adapter-specific `AcpModelConfig`
rather than the neutral engine API. `model-definitions.example.yaml` is
documentation rather than an automatic default; it covers every `servedBy`
profile the bundled workflows name.

## Dependencies

The CLI may depend on every other production directory and on the workflow
registries. It is the only directory that imports concrete engines and
chooses Claude, Codex, Droid, agent-deck, or an explicit adapter path. The Pi
extension drives its versioned process protocols and never imports Haskell
modules.

## Build and use

```sh
nix develop path:. -c cabal build all
nix develop path:. -c cabal run agentic-run -- list
nix develop path:. -c cabal run agentic-run -- plan harden
nix develop path:. -c cabal run agentic-run -- cost harden
nix develop path:. -c cabal run agentic-run -- run harden --scripted
```

## Conventions

Keep concrete backend and model selection here and the lower APIs
identity-neutral. Preserve the routing precedence, the strict schema and
secret refusals, eager preflight, the command-line text and JSON, and the exit
mapping. Registry, help, and scripted data may describe workflows and stay in
this directory. After a composition change, run `ci/policies.sh`,
`ci/examples.sh`, `ci/routing-config.sh`, and both engine gates.
