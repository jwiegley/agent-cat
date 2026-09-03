# DSL maintenance

- This is the dependency root of the Haskell workspace: never import another
  agent-cat package.
- Keep workflow-facing APIs pure and engine-independent. Runtime facts belong
  in `runtime`, concrete model mappings in `cli`, and analyses in `plan`/`cost`.
- Workflows name models symbolically; do not add ACP, deck, routing, session, Pi,
  or provider concepts.
- Preserve typed construction and raw bytes. Run
  `nix develop path:.. -c cabal build agentic-dsl` and the conformance gates
  after changes.
- Expose the smallest coherent module surface; hide implementation details.
