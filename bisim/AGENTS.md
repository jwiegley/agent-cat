# Bisimulation maintenance

This directory is test-only, and no production component may depend on it.
Build the Lean oracle before a live differential run, and never make the
oracle closure import the expensive flagship. Keep `corpus/` byte-identical
unless the user changes the specification explicitly. Keep the Haskell side
limited to DSL and planner modules; cost and canonical workflows belong to the
private verification library. Use deterministic local processes only and never
a paid engine. After a change, run tier 0, the rebuilt tier 1 cases, and a
fixed-seed live bisimulation.
