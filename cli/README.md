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

The command is `agentic-run`. Its verbs for human use are `list`, `help`,
`plan`, `cost`, and `run`, and its verbs for a supervising process are
`machine`, `machine-restart`, `machine-resume`, `machine-fork`, and
`lineage-check`. Exit status 0 is a completed command, 1 is a usage or
preflight refusal, 2 is a transport failure, and 3 is a run that was abandoned
over what arrived. `list --json` publishes descriptor version 3 with additive
routing and protocol-negotiation capabilities. Machine mode continues to speak
protocol version 1 and store format 1, and descriptor-version-2 clients remain
compatible. The chapter "Runner Reference" of the Texinfo manual documents every
verb and option.

## Model definitions

Workflow source contains symbolic model and profile names. Version-1
`routing.yaml` files retain their existing router and whole-profile layering and
raw `--route` precedence. Version 2 gives the user file at
`$XDG_CONFIG_HOME/agent-cat/routing.yaml` authority over environment references,
engines, bounded catalogues, concrete model aliases, personas, defaults, and
profiles. The nearest project file can select a persona and replace whole
profiles, but it cannot widen either allowlist or introduce privileged data.
Discovery fixes user/project authority from those paths before decoding, so a
user-shaped project document is still rejected as a project document. Untagged
version-2 loading is refused. Mixed versions are refused.

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
these definitions. Secret values come only from named environment variables and
never from YAML or argv. This environment overlay is a routing context, not an
operating-system credential sandbox. ACP options enter `AcpModelConfig` and never
the neutral engine API. The file `model-definitions.example.yaml` is documentation
rather than an automatic default, and it covers every `servedBy` profile that the
bundled workflows name.

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
nix develop path:. -c cabal run agentic-run -- --routing --json --offline
nix develop path:. -c cabal run agentic-run -- --migrate-routing old.yaml --output new.yaml
```

## Conventions

Keep concrete backend and model selection here, and keep the lower APIs
neutral to identity. Preserve the routing precedence, the strict schema and
secret refusals, the eager preflight, the command-line text and JSON, and the
exit mapping. Registry, help, and scripted data describe workflows and stay in
this directory. After a change to the composition, run `ci/policies.sh`,
`ci/examples.sh`, `ci/routing-config.sh`, and both engine gates.
