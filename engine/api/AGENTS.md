# Engine API maintenance

- Import no other agent-cat module layer and never name ACP, deck, CLI, or workflow types.
- Add only capabilities shared across supported engines.
- Keep runtime policy—decode, retry, failover, memo, scheduling—outside this API.
- Keep concrete protocol details in engine implementations.
- Run `nix develop path:../.. -c cabal test agentic` after changes.
