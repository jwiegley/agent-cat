# Manager maintenance

The manager coordinates existing runtime sessions and does not interpret
workflows. Import shared process, protocol, control, snapshot, and store
contracts through `Agentic.Runtime`. Keep CLI composition, workflow registries,
DSL authoring, and concrete engines outside this directory.

Production modules belong under `manager/src/Agentic/Manager`. The client
facade and its submodules depend on public manager protocol types and HTTP
client facilities, not server state, runtime interpretation, WAI, or SQLite.
Public protocol modules remain independent of both client and server machinery.
The TUI may import only `Agentic.Manager.Client`, not its internal submodules.

Use current-worktree direnv and the pinned development dependencies. Keep
technical probes separate from production service code and place their build
and temporary data under `~/Products`. Verify module boundaries with the shared
compiler-parsed gate. Preserve exact approval, private pipes, correlated
controls, and the distinction between coordination records and runtime evidence.
