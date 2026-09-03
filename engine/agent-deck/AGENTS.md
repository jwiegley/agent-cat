# agent-deck maintenance

- Depend only on `../api`; never import DSL, plan, runtime, CLI, bisim, ACP, or workflows.
- Preserve polling, staleness, private-file, timeout, and cleanup guarantees.
- Report raw results and unverified completion honestly.
- Keep decoding, retry, failover, memoization, and scheduling in runtime.
- Verify with the deterministic deck fixture; never require a live session.
