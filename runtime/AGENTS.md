# Runtime maintenance

- Depend only on `agentic-plan` and `agentic-engine`; do not import DSL authoring types.
- `Agentic.Runtime.Facts` stays Text-only and engine-neutral.
- Never import ACP, agent-deck, CLI, workflow packages, Pi, or bisimulation.
- Keep typed translation, rendering, decode/retry, failover, memo, scheduling, effects, and persistence here.
- Treat engines as opaque `Agentic.Engine` values; never dispatch on identity.
- Preserve protocol versions, private storage, ordering, and failure behavior.
- Verify policy, control, lineage, ACP, deck, routing, and scripted gates.
