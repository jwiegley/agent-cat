# Decisions engine maintenance

Depend only on `engine/api`. Never import the DSL, the planner, the runtime,
the CLI, conformance support, a sibling engine, or workflow modules. Every
vendor field name belongs in `Agentic.Decisions.Wire`, and `Agentic.Decisions`
names none. Mark each detail that no primary source confirms with an
`UNCONFIRMED(Uk)` comment beside the code that it governs. Never invent a
distribution: a refused, missing or malformed answer is a protocol failure.
Choose TLS trust only in `newDecisionsManager`, and add no platform-specific
path or certificate code. Decoding, retry, fail-over, memoization, and
scheduling stay in the runtime. Verify with `ci/decisions.sh`, which uses a
loopback stub inside the test process, and never contact a real or paid
endpoint from a test.
