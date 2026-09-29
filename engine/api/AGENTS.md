# Engine API maintenance

Import no other agent-cat layer, and never name ACP, deck, CLI, or workflow
types. Add only capabilities that the supported engines share. This layer
carries the shared permission report, `EnginePermissionReport`, and the
versioned value codecs for requests, results, steering and permission reports
that the run log uses. Keep each codec strict and exact, and change its version
when its encoding changes. Keep runtime
policy outside this interface. That policy includes decoding, retry, fail-over,
memoization, and scheduling. Concrete protocol details belong to the engine
implementations. Run `nix develop path:. -c cabal test engine-api-test` after
a change.
