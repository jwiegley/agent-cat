# cli

`cli` is the composition root of the `agentic` package. It combines the
workflow registries, the pure plan and cost interpreters, the runtime, the
model-definition loader, and the concrete engines into the `agentic-run`
executable. No other directory imports it.

## Layout

`cli/src` holds the library modules. `Agentic.Cli` is the registry and the
command dispatcher. `Agentic.Route` is the concrete grammar for `acp:` and
`deck:` backends over the generic runtime route table. `Agentic.RoutingConfig`
retains the version-1 resolver and the high-level resolved-policy surface. The
hidden modules `Agentic.RoutingConfig.V2`, `Agentic.RoutingDiscovery`,
`Agentic.RoutingSecrets`, and `Agentic.RoutingInspect` own trust-separated
version-2 decoding, bounded catalogue and cache input, environment references,
and inspection and migration. `Agentic.Chains` and `Agentic.RequirePinned` are
also hidden implementation modules.
`cli/example` holds the registry rows, the help pages, and the scripted replies
for the bundled workflows, and these build into the internal `examples` library
beside the workflow values. `cli/run/Main.hs` is the executable, and it applies
`cliMain` to the examples registry. `cli/test` holds the policy, routing, and
schema probes that the gate scripts drive. `cli/verification` holds the private
`verification` library, which assembles complete conformance observations, and
the `tier1` and live `bisim` executables.

## External behavior

The command is `agentic-run` with top-level `--tui`, the verbs `list`, `help`,
`plan`, `cost`, `run`, and the machine family `machine`, `machine-restart`,
`machine-resume`, `machine-fork`, and `lineage-check`. Exit status 0 is a
completed command, 1 a usage or preflight refusal, 2 a transport failure, and 3
a run abandoned over what arrived. `list --json` preserves descriptor version 2,
and `--descriptor-version 3` selects the current frontend contract.
Omitted machine protocol remains version 1/store 1; negotiated protocol 2/store 2
adds result/question artifacts, local person answers, and bounded public progress.
`--tui` delegates to the public Runtime-only terminal facade, which launches the
current executable rather than importing this module's interpreter. The Texinfo
manual's "Runner Reference" chapter documents every verb and option.

## Model definitions

Workflow source contains symbolic model and profile names. A live run with no
`--engine` or `--session` always loads `routing.yaml`. Every engine-bound
question must carry a model pin, and every pin must resolve through the selected
routing policy. A tool or person question therefore requires an explicit target.
An explicit engine or session is the complete command-line policy, even when
`--routing` is also present, and `--route` refines only that explicit target.
Version 1 retains its router and whole-profile layering. Version 2 gives the user
file at `$XDG_CONFIG_HOME/agent-cat/routing.yaml` authority over environment
references, engines, bounded catalogues, concrete model aliases, personas,
defaults, and profiles. The nearest project file can select a persona and replace
whole profiles, but it cannot widen either allowlist or introduce privileged
data. Discovery fixes user/project authority from those paths before decoding,
so a user-shaped project document is still rejected as a project document.
Untagged version-2 loading and mixed versions are refused.

Persona precedence is `--persona`, `AGENT_CAT_PERSONA`, the project selector, and
then the user default. The option `--realize AXIS=MODEL-ALIAS` replaces a managed
axis without detaching a model from its engine. `--routing --json` is the
sanitized frontend contract, and `--migrate-routing SOURCE --output DESTINATION`
creates an offline version-2 file without overwriting either path. The options
`--offline` and `--refresh-models` select explicit cache behavior. Manifests retain
the complete frozen inventory provenance, while semantic lineage ignores only
observation-time source, timestamp, age, warning, and their full-snapshot digest;
the selected persona, engine, endpoint fingerprint, exact model, and settings
remain exact.

The CLI alone discovers, validates, resolves, preflights, freezes, and records
these definitions. Secret values come only from named environment variables,
never YAML or argv, and selected ACP children receive a redacted environment
overlay after declared source/destination variables are scrubbed. This is routing
context, not an operating-system credential sandbox. Agent Deck receives no
synthetic environment behavior. `model-definitions.example.yaml` is documentation
rather than an automatic default and covers every `servedBy` profile in the
bundled workflows.

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
