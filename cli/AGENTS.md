# CLI maintenance

The CLI is the composition root, and no other directory may import it. Own the
concrete backend grammar, adapter selection, model-definition file IO, the
registry, help, and scripted tables, the process-facing commands, and the exit
mapping here. Keep workflows symbolic and the runtime and engine APIs
identity-neutral. Preserve the command-line text and JSON, the exit codes, the
protocol and store versions, the routing precedence, strict validation,
secret refusal, and eager preflight. Use the deterministic scripted, ACP, and
deck fixtures, and never run `engine/acp/ci/route-live.sh` automatically.
Verify with the policy, examples, routing-config, engine, and Pi extension
gates.
