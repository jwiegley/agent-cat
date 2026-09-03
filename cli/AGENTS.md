# CLI maintenance

- CLI is the composition root; no lower package may import it.
- Own concrete backend grammar, adapter selection, model-definition file IO,
  registry/help/script tables, process-facing commands, and exit mapping here.
- Keep workflows symbolic and lower runtime/engine APIs identity-neutral.
- Preserve CLI text/JSON, exit codes, protocol/store versions, routing precedence,
  strict validation, secret refusal, and eager preflight.
- Use deterministic scripted/ACP/deck fixtures; never run `engine/acp/ci/route-live.sh` automatically.
- Run CLI policy, examples, routing-config, engine, and ext-pi integration gates.
