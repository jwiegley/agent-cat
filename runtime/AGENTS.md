# Runtime maintenance

Depend only on planning modules and the neutral engine API. Do not import DSL
authoring types, ACP, agent-deck, the CLI, workflow modules, Pi, or conformance
support. `Agentic.Runtime.Facts` stays Text-only and neutral to engines. Keep
typed translation, rendering, decoding and retry, fail-over, memoization,
scheduling, effects, and persistence here, and treat engines as opaque
`Agentic.Engine` values. Preserve protocol versions, private storage, ordering,
and failure behavior. Verify with the policy, control, lineage, ACP, deck,
routing, and scripted gates.
