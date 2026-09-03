# Pi extension maintenance

Communicate with agent-cat only through its versioned descriptor, machine, and
control process protocols; never interpret `RawProgram` or `Plan` values or
import Haskell implementation details. Preserve `/wf`, private input handling,
launch approval, supervision, controls, retention, and durable references, and
keep protocol versions and backward compatibility explicit. Verify with
`npm run check`, `npm test`, and `npm run test:integration` against a freshly
built `agentic-run`, using only the deterministic local ACP and deck fixtures
and never a paid model.
