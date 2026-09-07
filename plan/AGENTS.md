# Planner maintenance

Depend only on `dsl` modules. Keep `Agentic.Plan` pure, total, and independent
of engines and runtime. Reuse `Agentic.DSL.Plan` rather than copy it or wrap it
in a parallel tree. Price interpretation belongs in `cost`, and execution
belongs in `runtime`. After a change, run `nix develop path:. -c cabal build
all`, then `bisim/ci/tier0.sh` and `cli/ci/examples.sh`.
