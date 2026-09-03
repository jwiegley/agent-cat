# DSL maintenance

This directory is the dependency root of the `agentic` package; it never imports
another agent-cat layer. Workflow-facing APIs stay pure and engine-independent:
run facts belong in `runtime`, concrete model mappings in `cli`, and analyses in
`plan` and `cost`. Workflows name models symbolically, so no ACP, deck, routing,
session, Pi, or provider concept enters here.

Preserve typed construction and raw bytes. After a change, run
`nix develop path:. -c cabal build all` and the conformance gates
`bisim/ci/tier0.sh` and `cli/ci/policies.sh`. Expose the smallest coherent
module surface and keep implementation modules hidden in `agentic.cabal`.
