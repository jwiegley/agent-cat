# DSL maintenance

- This is dependency root of `agentic`: never import another agent-cat module layer.
- Keep workflow-facing APIs pure and engine-independent. Runtime facts belong
  in `runtime`, concrete model mappings in `cli`, and analyses in `plan`/`cost`.
- Workflows name models symbolically; do not add ACP, deck, routing, session, Pi,
  or provider concepts.
- Preserve typed construction and raw bytes. Run
  `nix develop path:.. -c cabal build agentic` and conformance gates after changes.
- Expose the smallest coherent module surface; hide implementation details.
