# Cost maintenance

Depend only on planning modules. Keep the analysis pure, with no IO and no
runtime, routing, model-definition, or engine data. Reuse `Agentic.Plan.Plan`,
and never define a second workflow representation. After a change, run
`nix develop path:. -c cabal build all`, `bisim/ci/tier0.sh`, and
`cli/ci/examples.sh`.
