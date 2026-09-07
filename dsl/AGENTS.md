# DSL maintenance

This directory is the dependency root of the `agentic` package, and it never
imports another agent-cat layer. Workflow-facing APIs stay pure and independent
of engines. Run facts belong in `runtime`, concrete model mappings belong in
`cli`, and analyses belong in `plan` and `cost`. Workflows name models
symbolically, so no ACP, deck, routing, session, Pi, or provider concept enters
here.

Preserve typed construction and the raw bytes. After a change, run
`nix develop path:. -c cabal build all`, then the conformance gates
`bisim/ci/tier0.sh` and `cli/ci/policies.sh`. Expose the smallest coherent
module surface, and keep implementation modules hidden in `agentic.cabal`.
