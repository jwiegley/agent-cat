# cli

`cli` is the composition root of the `agentic` package. It combines the
workflow registries, the pure plan and cost interpreters, the runtime, the
model-definition loader, and the concrete engines into the `agentic-run`
executable. No other directory imports it.

## Layout

`cli/src` holds the library modules. `Agentic.Cli` is the registry and command
dispatcher, `Agentic.Route` is the concrete `acp:` and `deck:` backend grammar
over the generic runtime route table. `Agentic.RoutingConfig` retains the public
version-1 resolver and the sanitized resolved-policy surface. Hidden
`Agentic.RoutingConfig.V2`, `Agentic.RoutingDiscovery`,
`Agentic.RoutingSecrets`, and `Agentic.RoutingInspect` own strict trust-separated
version-2 decoding, bounded catalogue/cache I/O, environment references, and
inspection/migration. `Agentic.Chains` and `Agentic.RequirePinned` remain hidden
implementation modules. `cli/example` holds
the registry rows, help pages, and scripted replies for the bundled workflows;
they build into the internal `examples` library beside the workflow values
themselves. `cli/run/Main.hs` is the executable, which applies `cliMain` to the
examples registry. `cli/test` holds the policy, routing, and schema probes that
the gate scripts drive. `cli/verification` holds the private `verification`
library, which assembles complete conformance observations, and the `tier1`
and live `bisim` executables.

## External behavior

The command is `agentic-run` with top-level `--tui`, the verbs `list`, `help`,
`plan`, `cost`, `run`, and the machine family `machine`, `machine-restart`,
`machine-resume`, `machine-fork`, and `lineage-check`. Exit status 0 is a
completed command, 1 a usage or preflight refusal, 2 a transport failure, and 3
a run abandoned over what arrived. `list --json` publishes descriptor version 3.
Omitted machine protocol remains version 1/store 1; negotiated protocol 2/store 2
adds result/question artifacts, local person answers, and bounded public progress.
`--tui` delegates to the public Runtime-only terminal facade, which launches the
current executable rather than importing this module's interpreter. The Texinfo
manual's "Runner Reference" chapter documents every verb and option.

## Model definitions

Workflow source contains symbolic model and profile names. Version-1
`routing.yaml` files retain their existing whole-router/profile overlay and raw
`--route` precedence. Version 2 separates a privileged user file at
`$XDG_CONFIG_HOME/agent-cat/routing.yaml` from the nearest restricted project
file `.agent-cat/routing.yaml`: the user defines environment secret references,
engine instances, bounded catalogues, concrete model aliases, personas, and
profiles; a project may select a persona and replace profiles only. Mixed
versions are refused.

Persona precedence is `--persona`, `AGENT_CAT_PERSONA`, project selector, then
user default. `--realize AXIS=MODEL-ALIAS` safely replaces a managed v2 axis; a
raw `--route` for such an axis is refused, while v1 and unconfigured route
behavior is unchanged. `--offline` and `--refresh-models` select cache policy.
`--routing --json` is the sanitized frontend contract, and
`--migrate-routing SOURCE --output DESTINATION` creates an offline v2 file
without overwriting either path.

The CLI alone discovers, validates, resolves, preflights, freezes, and records
these definitions. Secret values come only from named environment variables,
never YAML or argv, and selected ACP children receive a redacted environment
overlay after declared source/destination variables are scrubbed. This is routing
context, not an operating-system credential sandbox. Agent Deck receives no
synthetic environment behavior. `model-definitions.example.yaml` is documentation
rather than an automatic default and covers every `servedBy` profile in the
bundled workflows.
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
nix develop path:. -c cabal run agentic-run -- --tui
nix develop path:. -c cabal run agentic-run -- --routing --json --offline
nix develop path:. -c cabal run agentic-run -- --migrate-routing old.yaml --output new.yaml
```

## Conventions

Keep concrete backend and model selection here and the lower APIs
identity-neutral. Preserve the routing precedence, the strict schema and
secret refusals, eager preflight, the command-line text and JSON, and the exit
mapping. Registry, help, and scripted data may describe workflows and stay in
this directory. After a composition change, run `ci/policies.sh`,
`ci/examples.sh`, `ci/routing-config.sh`, both engine gates, and `../tui/ci/tui.sh`.
