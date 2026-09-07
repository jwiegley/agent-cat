# Engine API maintenance

Import no other agent-cat layer, and never name ACP, deck, CLI, or workflow
types. Add only capabilities that the supported engines share. Keep runtime
policy outside this interface. That policy includes decoding, retry, fail-over,
memoization, and scheduling. Concrete protocol details belong to the engine
implementations. Run `nix develop path:. -c cabal test engine-api-test` after
a change.
