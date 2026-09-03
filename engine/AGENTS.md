# Engine maintenance

- All concrete engines depend on `api`, never on DSL, plan, runtime, CLI, bisim,
  or sibling engines.
- Keep decode/retry/failover/memo policy in runtime.
- Keep model routing and definition-file loading in CLI composition.
- Preserve transport protocol, permissions, completion evidence, and failures.
- Do not create an MCP directory/package until implementing it fully.
