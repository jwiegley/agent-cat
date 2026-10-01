# Pi extension maintenance

Communicate with agent-cat only through its versioned descriptor, machine, and
control process protocols, and in service mode only, with the agent-cat
manager through the versioned `/v1` HTTP protocol. Never interpret
`RawProgram` or `Plan` values or import Haskell implementation details. Only
`src/manager/profile.ts` reads a manager credential file. Never place the
bearer in a tool argument, a tool result, a transcript entry or a
notification. Preserve `/wf`, private input handling,
launch approval, supervision, controls, retention, and durable references, and
keep protocol versions and backward compatibility explicit. Verify with
`npm run check`, `npm test`, and `npm run test:integration` against a freshly
built `agentic-run`. Use only the deterministic local ACP and deck fixtures,
and never a paid model.
