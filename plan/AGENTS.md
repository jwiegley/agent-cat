# Planner maintenance

- Depend only on DSL modules.
- Keep `Agentic.Plan` pure, total, and engine/runtime independent.
- Reuse `Agentic.DSL.Plan`; never copy or wrap it in a parallel AST.
- Price interpretation belongs in `../cost`; execution belongs in `../runtime`.
- Run `nix develop path:.. -c cabal build agentic`, Tier 0, examples,
  and bisimulation after changes.
