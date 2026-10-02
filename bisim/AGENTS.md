# Bisimulation maintenance

This directory is test-only, and no production component can depend on it.
Build the Lean oracle before a live differential run, and never make the oracle
closure import the expensive flagship. Keep `corpus/` identical byte for byte
unless the user changes the specification explicitly. Write `manager/cases/`
only with `manager-cases`, and keep it unchanged unless a manager case or the
manager encoding changes. Keep the Haskell side limited to DSL and planner
modules. Cost and canonical workflows belong to the private verification
library. Use deterministic local processes only, and never a paid engine. After
a change, run tier 0, the rebuilt tier 1 cases, and a fixed-seed live
bisimulation. After a change to the manager lane, run the steps and the
controls of `bisim/ci/manager.sh` in their stated order, one at a time.
