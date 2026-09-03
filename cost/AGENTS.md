# Cost maintenance

- Depend only on `agentic-plan` among repository packages.
- Keep analysis pure: no IO, runtime, routing, model-definition, or engine data.
- Reuse `Agentic.Plan.Plan`; never define a second workflow representation.
- Run `nix develop path:.. -c cabal build agentic-cost`, Tier 0, examples,
  and bisimulation after changes.
