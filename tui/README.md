# Terminal interface

`Agentic.Tui` is the terminal frontend for an agent-cat runner. `agentic-run
--tui` and its explicit form `agentic-run --tui --local` select local mode,
which this section describes. Local mode discovers
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
`process` library without changing inherited limits or disabling `close_fds`. On macOS,
the Runtime spawns through `posix_spawn` with `POSIX_SPAWN_CLOEXEC_DEFAULT`, so a spawn
does not close descriptors up to the limit. Helpers
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
prompt. In service mode, `s` saves the retained verified result bytes of the
run in the same way, and a refusal shows a fixed message with the path. Save
errors are scrollable with `PgUp` and `PgDn`. Steering uses a bounded
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

## Service mode

`agentic-run --tui --service CLIENT_PROFILE` connects the same frontend to a
running workflow manager through the public `Agentic.Manager.Client` facade.
It performs one workflow journey. It browses the manager catalogue, creates one
request with literal inputs, and shows the exact manager review. Only `y` in the
summary view approves that review. The frontend then follows the run in the
live monitor, answers the questions that the manager routes to the person,
invokes an offered recovery retry with `r`, recognizes the terminal state,
retrieves the verified result, and saves it with `s`.

Service mode starts no local machine, helper process or local runner state.
When the connection fails at startup, the frontend prints one fixed line that
`Agentic.Tui.ServiceLane.startupFailureText` gives for the declared failure,
for example `--tui --service: manager unreachable` or `--tui --service:
credential refused`, and exits with status 1 before the terminal interface
starts. The shell header has an identity row in every service screen when the
terminal has at least 72 columns and 16 rows. The row names the endpoint host
and port from the client profile (`Agentic.Manager.Client.clientEndpoint`), the
first 18 characters of the authority epoch, the credential scopes, and the
stream identifier of the capabilities. The stream identifier comes last, so a
narrow terminal shows only its leading characters. A smaller terminal keeps its
one-row header without the identity row.

A key whose operation needs a scope that the capabilities do not list starts
nothing and shows the numbered key outcome `OPERATION did not start: this
credential lacks SCOPE.` before any other admission is decided, so it never
defers and sends no request. The manager rule `requiredScopes` of the client
facade decides the scopes: `submit` for create, capture, set-input,
remove-input, enqueue and withdraw, `submit` and `control` for approve and
discard, `control` for answer, retry and every run control, and `observe` and
`export` for export. On the exact review, a summary `y` without such a scope
shows the approval notice `Approval did not start: this credential lacks
SCOPE.`, and the approval hint is absent.

`Agentic.Tui.ServiceLane` owns the read ticket, the one command lane, the
internal-fault flag and the resend confirmation. Every read of the manager
passes through that single-flight lane. One composite read covers the selected
request, its review, the receipt of a retained command, and the run snapshot,
run controls and pending decision, and a complete read is installed in one
step. The frontend repeats the read on a one-second timer, and `g` requests it
at once. A declared refusal keeps the last complete observation and marks it
stale with the refusal code. Every mutation key has one visible outcome: a
start, a refusal or a deferral. A refusal or a deferral is a numbered key
outcome that remains until the next key or view change. A key never cancels a
page-set read and is deferred instead, and a deferred key is never replayed.
A deferral pauses automatic refresh until the deferring page-set read completes
or for at most three seconds from the key outcome, whichever comes first.
While the pause holds, the observation line states that automatic refresh is
paused instead of `Observation: current`.

Every command is sent once. The lane retains the original pending command and
receipt location. An uncertain send is never repeated automatically. When the
manager offers an exact resend, `x` opens a confirmation and `y` sends the
retained command unchanged. Any failure that the client does not declare is an
internal fault. The frontend then shows fixed text without exception detail,
stops automatic refresh and every further mutation, and keeps only read-only
actions and detachment. `Ctrl-C`, or `q` while no answer editor has the keys,
exits without cancelling manager-owned work.

A question head accepts the simple codes `text`, `verdict`, `flag` and
`receipt`. `Agentic.Tui.Person.personAnswerValue` converts the editor input by
the question code, as in the local person view, so `false` for a `flag` question
is sent as the JSON value `false`. The answer carries the entity tag of the
displayed decision as its precondition. A recovery head sends only the retry
that the run controls offer, with the entity tag of the displayed control
observation. `f` and `a` refuse failover and abandon.

A run is terminal only when the snapshot runtime status is succeeded, failed,
cancelled or orphaned. For a succeeded run with a verified result reference,
the frontend reads the run outputs and downloads the artifact through
`Agentic.Manager.Client.downloadVerified`, which checks the size and SHA-256
digest. It retains up to 64 MiB of unchanged bytes and does not retrieve them
again. A declared refusal, or a retrieval that finds no verified result, retains
no bytes. The status line and the result lines show it as a failure that the
next refresh retries. An automatic refresh retries after the next installed
composite read, so each one-second refresh starts at most one retrieval, and
`g` retries at once. `Agentic.Tui.Save.saveExact` publishes those bytes at a
new absolute path with mode 0600 and refuses an existing entry, a symbolic
link, or an invalid path. It writes a private file in the destination
directory and publishes it with a hard link, so the destination file system
must support hard links. When the private file cannot be removed after the
link, the save succeeds, the destination holds the exact bytes, and the saved
line names the private file that remains.

`Agentic.Tui.Service` also decodes the items of the `/requests` and `/runs`
collections and the members of the `/snapshot` overview, with
`decodeRequestItem`, `decodeRunItem` and `decodeOverviewMember`. A run item
is a known run with its public summary or a catalogue entry with an
unreadable manifest. Service mode does not read these resources yet.
`tui-model-test` checks these decoders, the decision and control decoders and
the answer conversion against the `resources` section of
`test/manager_client_vectors.json`, which [the protocol
description](../doc/api/README.md#pages-and-live-delivery) describes.

Service mode does not support cancellation, steering, redirect, failover or
abandon, the structured answer editor, captured and other non-literal inputs,
withdrawal or discarding of a request, more than one concurrent run, run history,
lineage, export, event-driven refresh, reconnection after a manager restart or a
credential revocation, endpoint switching, observation of earlier runs after a
frontend restart, Overview bootstrap, or acceptance at 40x12 and 80x24. The
[manual](../doc/agent-cat.texi) entry for `--service` states the complete key
behavior. Service mode is not an accepted milestone.
