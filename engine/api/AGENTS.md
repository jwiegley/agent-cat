# Engine API maintenance

Import no other agent-cat layer and never name ACP, deck, CLI, or workflow
types. Add only capabilities shared across the supported engines, and keep
runtime policy, meaning decode, retry, fail-over, memoization, and scheduling,
outside this interface. Concrete protocol details belong to the engine
implementations. Run `nix develop path:. -c cabal test engine-api-test` after
a change.
