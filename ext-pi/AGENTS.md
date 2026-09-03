# Pi extension maintenance

- Communicate with agent-cat only through the versioned descriptor/machine/control process protocols.
- Do not interpret DSL Raw/Plan values or import Haskell implementation details.
- Preserve `/wf`, private input handling, launch approval, supervision, controls, retention, and durable references.
- Keep protocol versions and backward compatibility explicit.
- Run `npm run check`, `npm test`, and `npm run test:integration` with a freshly built `agentic-run`.
- Use only deterministic local ACP/deck fixtures; never require paid/live models.
