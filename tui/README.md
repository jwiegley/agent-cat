# Terminal interface

`Agentic.Tui` is the terminal frontend for an agent-cat runner. It discovers
workflows and routing through bounded machine-readable subprocesses. Routing
inspection supplies opaque routing-only arguments and a launch fingerprint owned
by the CLI. A shared strict runtime decoder supplies exact post-input plan facts.
Launch requires full pin coverage, repeats offline resolution, and refuses a
changed routing fingerprint. The TUI
launches the same executable in protocol-v2 machine mode, reduces events with
`Agentic.Runtime.Snapshot`, and sends correlated controls on an inherited file
descriptor. It does not interpret workflows.

The pure screen model and text projections are separate from the Brick adapter.
Runtime stores and frontend manifests remain private beneath the configured
state directory. An explicit `AGENT_CAT_STATE_DIR` must be absolute. An existing root
must be a no-follow directory owned by the effective user with no group or other mode
bits. The TUI refuses rather than repairs a symlink, foreign owner, or public mode.
The shared `Agentic.Runtime.PrivateRoot` contract retains the validated descriptor,
and creates, opens, renames, links, and removes descendants through no-follow `*at`
operations. The frontend supplies the captured path/device/inode identity to its
plan and machine children through `AGENT_CAT_STATE_ANCHOR`. Each child validates
that identity before opening inputs or creating its own descriptor-anchored store.
Without `AGENT_CAT_STATE_DIR`, each runner uses
`$XDG_STATE_HOME/agent-cat/tui/<runner-id>` (or the corresponding directory under
`~/.local/state`), so frontends share state only by explicit configuration. The
supported platforms are macOS and Linux. Helper queries have a 30-second and 4-MiB
bound. The Linux Nix override corrects large-limit descriptor closure in GHC's bundled
`process` library without changing inherited limits or disabling `close_fds`. Helpers
and machine children share one owner that retains the leader through group signalling
and final reap. Machine callbacks remain gated until Brick adopts that owner. Startup
cancellation and protocol failure retain ownership through synchronous termination and
reap. Shutdown joins helper workers before releasing their state root.

The application enters Brick before it starts runner discovery. Its fixed shell keeps
the current section, context, status, and applicable controls on screen while bounded
workers load the catalogue, help, routing, previews, and machine process. The browser
cycles through workflows, restored runs, and sanitized routing. Wide terminals show
one workflow name per row beside an overview of the selected workflow's description,
inputs, result type, and execution capabilities. Narrow terminals show one pane at a time. `Left`, `Right`,
and `Tab` select panes and sections, and a bullet marks the focused pane.
`?` opens context-specific key help. `/` filters names and descriptions as text is
entered. `Enter` or `Ctrl-D` applies the filter, while `Esc` keeps the prior filter.
Run details include lineage, persona, realizations, bills, result availability, and
ownership. Routing details include credential readiness, profile chains, output
limits, execution fingerprints when supplied, and inventory provenance.

Input editors preserve descriptor order and source semantics. `Enter` inserts a
newline and `Ctrl-D` accepts the exact value. Vty bracketed paste is enabled when the
terminal supports it. Printable characters remain editor data while an editor has
focus. Moving backward between input, target, and review steps restores the accepted
or draft value. Escape from the first input cancels workflow configuration and returns
to the browser.

A launch first checks the exact plan identity against the selected catalogue row.
The compact review shows workflow, target, persona, request bounds, path count, effect
capabilities, relevant exact-pin profile chains, working directory, routing warning
count, and live billing risk. Restarts, resumes, and forks retain the billing
classification of the restored target. Offline readiness does not verify provider
model support or authentication.
`d` opens a scrollable exact-details view with the complete warnings first, followed
by all plan fields, direct argv, routing provenance, and fingerprints. Neither view
renders input bodies or the raw program.
`Enter` or `y` creates the run, while `n` returns to
target selection with input state intact. Consent is enabled only when every required
review row and the launch, back, and exact-detail controls fit. Resizing does not
change the pending launch.

Lineage rechecks the confined parent and its current owner before preview and launch.
Cached browser facts cannot authorize a foreign live run. Live children may be
detached and reattached. Enter while one is detached reattaches instead of starting a
second child. Cancellation requires confirmation and has a bounded process-group
fallback. The monitor header shows workflow, persona, realization, human-readable
status, elapsed time, follow state, and bills. Terminal elapsed time ends at the last
recorded event. A run-level failure appears above the occurrence panes, including
failures before the first request. `d` opens the complete diagnostic and run identity;
stored-run details begin with the same failure. The request rail occupies at most
one quarter of a wide terminal, capped at 32 columns. Its rows show request number,
lifecycle, and addressee. The reading pane shows the answer or the latest attempt
output, with paragraph spacing and lightweight Markdown cues. Full prompts, earlier
attempts, public progress, routing history, and control acknowledgements remain in
`d` Details. `Tab` changes pane focus, `G` or `End` resumes tail following, and
manual output scrolling displays `Paused`. Correlated redirect
and steering remain keyboard-accessible. Recovery and local-person decisions share a
single FIFO ordered by protocol sequence, so a later decision cannot replace an
earlier blocked producer. Filter, input, person, steering, and save editors retain
separate drafts when a mandatory layer preempts another editor. `r` shows a verified
result on demand. `s` copies it to a new mode-0600 file through an explicit path
prompt. Save errors are scrollable with `PgUp` and `PgDn`. Steering uses a bounded
editor beneath the run view so that the output remains visible during composition.

The color map uses terminal-default backgrounds and semantic foreground colors.
Setting a nonempty `NO_COLOR` removes semantic foreground colors while preserving
textual focus markers, reverse-video selection, headings, warnings, and diff prefixes.
Every string crosses a presentation boundary that replaces terminal control
characters before Brick constructs Vty cells.

Protocol-v2 public messages, tool patches, complete todo snapshots, usage, and
explicit reasoning summaries are rendered separately from answer output. Text and
collections are bounded before persistence. Tool diagnostics are redacted, and
private reasoning updates are ignored. The renderer uses safe plain text, lightweight
Markdown heading/quotation/fence cues, status classes, and diff classes. It has no
tree-sitter or native grammar dependency. The complete requirement-to-test matrix is
in [`../doc/tui-release-evidence.md`](../doc/tui-release-evidence.md).
