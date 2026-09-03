# cli

`cli` is the composition root of the `agentic` package. It combines the
workflow registries, the pure plan and cost interpreters, the runtime, the
model-definition loader, and the concrete engines into the `agentic-run`
executable. No other directory imports it.

## Layout

`cli/src` holds the library modules. `Agentic.Cli` is the registry and the
command dispatcher. `Agentic.Route` is the concrete grammar for `acp:` and
`deck:` backends over the generic runtime route table. `Agentic.RoutingConfig`
is the strict layered schema for model definitions and its resolver.
`Agentic.Chains` and `Agentic.RequirePinned` are hidden implementation modules.
`cli/example` holds the registry rows, the help pages, and the scripted replies
for the bundled workflows, and these build into the internal `examples` library
beside the workflow values. `cli/run/Main.hs` is the executable, and it applies
`cliMain` to the examples registry. `cli/test` holds the policy, routing, and
schema probes that the gate scripts drive. `cli/verification` holds the private
`verification` library, which assembles complete conformance observations, and
the `tier1` and live `bisim` executables.

## External behavior

The command is `agentic-run`. Its verbs for human use are `list`, `help`,
`plan`, `cost`, and `run`, and its verbs for a supervising process are
`machine`, `machine-restart`, `machine-resume`, `machine-fork`, and
`lineage-check`. Exit status 0 is a completed command, 1 is a usage or
preflight refusal, 2 is a transport failure, and 3 is a run that was abandoned
over what arrived. `list --json` publishes descriptor version 2. Machine mode
speaks protocol version 1 and store format 1. The chapter "Runner Reference"
of the Texinfo manual documents every verb and option.

## Model definitions

Workflow source contains symbolic model and profile names. Optional version-1
`routing.yaml` files map those names to routers, concrete models, thinking
levels, output limits, and scalar ACP options. The user file is
`$XDG_CONFIG_HOME/agent-cat/routing.yaml`. The project layer is the nearest
`.agent-cat/routing.yaml` between the working directory and the repository
boundary, and its named routers and profiles replace the user-layer entries
with the same names. A command-line `--route` is the highest backend override.
The CLI alone discovers, validates, merges, resolves, preflights, and records
these definitions. ACP options enter the adapter-specific `AcpModelConfig` and
never the neutral engine API. The file `model-definitions.example.yaml` is
documentation rather than an automatic default, and it covers every `servedBy`
profile that the bundled workflows name.

## Dependencies

The CLI can depend on every other production directory and on the workflow
registries. It is the only directory that imports concrete engines, and it
alone chooses Claude, Codex, Droid, agent-deck, or an explicit adapter path.
The Pi extension drives the versioned process protocols of the CLI and never
imports Haskell modules.

## Build and use

```sh
nix develop path:. -c cabal build all
nix develop path:. -c cabal run agentic-run -- list
nix develop path:. -c cabal run agentic-run -- plan harden
nix develop path:. -c cabal run agentic-run -- cost harden
nix develop path:. -c cabal run agentic-run -- run harden --scripted
```

## Conventions

Keep concrete backend and model selection here, and keep the lower APIs
neutral to identity. Preserve the routing precedence, the strict schema and
secret refusals, the eager preflight, the command-line text and JSON, and the
exit mapping. Registry, help, and scripted data describe workflows and stay in
this directory. After a change to the composition, run `ci/policies.sh`,
`ci/examples.sh`, `ci/routing-config.sh`, and both engine gates.
