# agent-deck maintenance

Depend only on `engine/api`; never import the DSL, the planner, the runtime,
the CLI, conformance support, the ACP engine, or workflow modules. Preserve
the polling, staleness, private-file, timeout, and cleanup guarantees, and
report raw results and unverified completion honestly. Decoding, retry,
fail-over, memoization, and scheduling stay in the runtime. Verify with the
deterministic deck fixture and never require a live session.
