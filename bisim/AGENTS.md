# Bisimulation maintenance

- This module is test-only. Never make a production package depend on it.
- Build the Lean oracle before live differential tests; do not build the
  expensive flagship as part of the oracle closure.
- Keep `corpus/` byte-identical unless the user explicitly changes semantics.
- Keep Haskell bisimulation limited to DSL and planner modules. Cost and canonical
  workflows belong to private verification; never duplicate them.
- Use deterministic local processes only. Do not run paid/live engines.
- Run Tier 0, rebuilt Tier 1, and fixed-seed live bisimulation after changes.
