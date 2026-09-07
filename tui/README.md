# Terminal interface

`Agentic.Tui` is the terminal frontend for an agent-cat runner. It discovers
workflows and routing through bounded machine-readable subprocesses. Routing
inspection supplies opaque target arguments and a launch fingerprint owned by the
CLI; launch repeats offline resolution and refuses a changed fingerprint. The TUI
launches the same executable in protocol-v2 machine mode, reduces events with
`Agentic.Runtime.Snapshot`, and sends correlated controls on an inherited file
descriptor. It does not interpret workflows.

The pure screen model and text projections are separate from the Brick adapter.
Runtime stores and frontend manifests remain private beneath the configured
state directory. An explicit `AGENT_CAT_STATE_DIR` must be absolute. An existing root
must be a no-follow directory owned by the effective user with no group or other mode
bits; the TUI refuses rather than repairs a symlink, foreign owner, or public mode.
The shared `Agentic.Runtime.PrivateRoot` contract retains the validated descriptor,
and creates, opens, renames, links, and removes descendants through no-follow `*at`
operations. The frontend supplies the captured path/device/inode identity to its
plan and machine children through `AGENT_CAT_STATE_ANCHOR`. Each child validates
that identity before opening inputs or creating its own descriptor-anchored store.
Without `AGENT_CAT_STATE_DIR`, each runner uses
`$XDG_STATE_HOME/agent-cat/tui/<runner-id>` (or the corresponding directory under
`~/.local/state`), so frontends share state only by explicit configuration. The
supported platforms are macOS and Linux. Helper queries have a 30-second and 4-MiB
bound; the Linux Nix override corrects large-limit descriptor closure in GHC's bundled
`process` library without changing inherited limits or disabling `close_fds`. Helpers
and machine children share one owner that retains the leader through group signalling
and final reap. Shutdown joins helper workers before releasing their state root.

The browser cycles through workflows, restored runs, and sanitized routing. Workflow
rows support a `/` fuzzy filter; run rows include lineage, persona, realizations, bills,
result availability, and ownership; routing rows include profile chains and inventory
provenance. Each workflow retains bounded runner help. A launch collects source-aware inputs and shows
exact-input plan facts, the executable and target arguments, and concrete routing
before a separate confirmation creates a run. Lineage rechecks the confined parent
and its current owner before preview and launch; cached browser facts cannot authorize
a foreign live run. Live children may be detached and
reattached; Enter while one is detached reattaches instead of starting a second
child. Cancellation requires confirmation and has a bounded process-group
fallback. The monitor header shows workflow, persona, realization, status, elapsed
time, and bills. Occurrence selection remains attached to identity, while a separate
bounded output viewport supports explicit `G`/End tail following. Correlated redirect,
steering, FIFO recovery, and local-person controls remain keyboard-accessible. A
verified final result can be copied to a new mode-0600 file through the `s` path prompt.

Protocol-v2 public messages, tool patches, complete todo snapshots, usage, and
explicit reasoning summaries are rendered separately from answer output. Text and
collections are bounded before persistence. Tool diagnostics are redacted, and
private reasoning updates are ignored. The renderer uses safe plain text, lightweight
Markdown heading/quotation/fence cues, status classes, and diff classes; it has no
tree-sitter or native grammar dependency. The complete requirement-to-test matrix is
in [`../doc/tui-release-evidence.md`](../doc/tui-release-evidence.md).
