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

`agentic-run --tui --service CLIENT_PROFILE [CLIENT_PROFILE ...]` connects the
same frontend to a running workflow manager through the public
`Agentic.Manager.Client` facade. It takes 1 to 8 absolute client-profile paths
and connects the first one at startup.
It follows one selected request or run at a time. It browses the manager
catalogue, creates a request with literal or captured inputs, opens an existing
request or run from the Manager overview view, and shows the exact manager review. Only `y` in the
summary view approves that review. The frontend then follows the run in the
live monitor, answers the questions that the manager routes to the person,
sends the run controls that the manager offers (cancel, steer, retry,
fail-over and abandon), recognizes the terminal state, retrieves the verified
result, and saves it with `s`.

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

`E` opens the Endpoints view from every service screen without text entry,
the profile and workflow browsers and the request screen included. Tab and the
other browser keys keep their behavior. The view lists each client profile in
the order of the command line with its number, its connection state (`active`,
`not connected`, `connecting` or `failed:` with the fixed reason), its path, and
the identity row of its latest session. Up and Down select a profile, `Enter`
connects it, and `Esc` returns to the screen below the view.
`Agentic.Tui.ServiceLane` owns this model (`Endpoints`, `beginSwitch` and
`switchStep`). The connection runs in a worker through
`Agentic.Tui.Service.connectEndpoint`, and the active session continues to
work while it runs. A failed connection keeps the active session and shows its
fixed reason, the same text as the startup line without the `--tui --service:`
prefix. A successful connection cancels the read, preparation, send and event
workers of the earlier session, closes that session, and clears every observation,
selection, retained result and settled command. The new session then loads
the manager profiles. The switch advances the session generation, and every
worker result carries the generation of the session that started the worker,
so a late result of an earlier session is never handled. The switch also
advances the generation of the refresh coordinator of the session, which
fences the fetches of live delivery. A command whose outcome is unresolved at the switch, or whose
send was in flight, stays listed under its own profile as `unresolved
OPERATION URI`. No later session sends it, and its pending command is bound to
the closed session, so the client refuses it with `WrongEndpoint`. Selecting an
earlier profile again opens a new session with new references.

After the profiles load, the frontend reads the authorized manager overview
(`/v1/snapshot`) through `Agentic.Manager.Client.loadOverview` in the
single-flight read lane, and it shows the profiles when that read completes.
The same happens after a switch to another endpoint and after `r` on the
profile browser. `O` opens the Manager overview view from the workflow
browser. `Tab`, `h`, `Enter`, the arrow keys and the other browser keys keep
their behavior there, and `Esc` returns from the view to the workflow browser.
The view lists the requests with their workflow, phase, admission state and
blocking reasons, then the preparations, then the runs with their runtime
status, supervision and verification as distinct fields, and then the pending
decisions with their run and kind. A queued request also shows its position
among the queued requests of its profile, in overview order
(`Agentic.Tui.Service.queuePositions`): `request queued 1 of 2` in the list
and `Profile queue position: 1 of 2` in the details. The `Position` line shows
the admission position that the manager reports, which counts the queued
requests of every profile. The view lists every active run of the authorized
profiles, so runs that run at once each show their own runtime status and
decisions. `Agentic.Tui.Service.decodeOverviewItem`
decodes each member with the decoders of the request and run collections, and
`overviewRows` projects it for display. No runtime reducer takes part. A wide
terminal shows the list beside the details of the selected row. A narrow
terminal shows one pane at a time, and `Left` and `Right` select the pane.
`Up` and `Down` select a row. The application state keeps the selected row by
its kind and identity (`Agentic.Tui.ServiceLane.RowFocus`), not by its index,
so the same row stays selected when a refresh adds or removes other rows. When
the selected row leaves the overview, the row at its last index is selected.
`g` reads the overview again. While another read is in flight, `g`
starts nothing and the status line states it. A declared refusal keeps the
last complete overview and marks it stale with the refusal code, for example
`Overview: stale (TransportUnavailable)` after the manager stops. The view is
not read on the one-second timer.

`Enter` on an overview row opens it (`Agentic.Tui.Service.overviewOpen`). A
request row selects the request and shows it by its phase: the request
screen for a draft, and the review or the live monitor of its run after the
next composite read. When the loaded workflow catalogue does not list the
workflow revision of the request, the frontend first loads the catalogue of
the request profile. A preparation row opens its request when the overview
lists that request. A run row selects the run by its identifier with the
profile of the row, and a decision row selects the run of the decision. The
composite read of a selected run reads its snapshot, its controls and the
decision at their head by the run identifier, with no request, so a run
without a request of this session opens. A row opens only while the command
lane is idle, and otherwise the status line states that a command is in
progress. `Esc` on the live monitor, on the question and recovery heads, and
on an idle request screen returns to the service list view that the operator
last used, the overview or the Manager decisions view, and sends nothing
(`Agentic.Tui.Model.serviceLeave` and `modelServiceList`). The footer of the
live monitor names that view as `Esc OVERVIEW` or `Esc DECISIONS`. The selection and its observation stay,
so the reads that confirm a command in progress continue, and the run
continues at the manager. An installed read of the selection never replaces
the overview, a browser or the help (`serviceShowsSelection`). `Enter` on the
row of the run that the installed observation already shows opens it at once
with that observation. `Enter` on the row of another run selects that run,
and the earlier run continues at the manager. The workflow browser creates a
new request while earlier runs continue. A frontend that starts again reads
the overview, which lists the active runs that an earlier session or another
client started, and `Enter` on the row of such a run shows its live monitor.
The tui-overview mode of `manager/test/service_http.py` runs two runs at once
with two execution reservations, queues a third request behind them, and
opens both runs after a restart of the frontend.

`D` opens the Manager decisions view from the workflow browser. `Tab` and the
other browser keys keep their behavior, and `Esc` returns from the view to the
workflow browser. The view reads the complete page set of `/v1/decisions`
without `runId` (`Agentic.Tui.Service.loadDecisions`), which lists the
pending decision head of each run of the authorized profiles in manager
observation order. `decodeDecisionHeads` decodes each item with the decision
decoder and refuses a collection that names one decision or one run twice.
`decisionRows` keeps the order of the collection and does not sort it. Each
row shows the kind and the run of the head in the list, and the details show
the decision, the run, the kind, the state, the occurrence and, for a
question, the answer type, the addressee and the prompt. An ask that the
reviewed policy field `personAnswers` routes to the person is a question
decision whose addressee names the person, for example `person
model:fixed-point`, so it appears in the view like every other pending head.
The overview shows the same detail lines for its decision rows. `Up` and
`Down` select a row, and the application state keeps the selected row by its
identity. `Enter` opens the run of the selected head by its identifier with
the profile of the decision (`decisionsOpen`), as a decision row of the
overview does, and the live monitor shows the question head of that run. The
answer editor converts the typed text with the existing simple codes of
`Agentic.Tui.Person.personAnswerValue`, or with the structured answer editor
for a structured question, and `Ctrl-D` sends it to that decision with the
decision observation as `If-Match`. The details of a structured head also
show its answer schema, for example `Answer schema: {"notes": [string], "ok":
boolean}`. `Esc` on the live monitor
returns to the Manager decisions view. Opening the view starts a read of the
decision heads through live delivery, and live delivery keeps them current
while the view is shown. `g` reads them again. A declared refusal keeps the
last complete heads and marks them stale with the refusal code, for example
`Decisions: stale (TransportUnavailable)`. The status line above the list
states the number of pending heads, for example `Decisions: current; pending
heads: 2`.

`H` opens the History view from the workflow browser. `Tab` and the other
browser keys keep their behavior, and `Esc` returns from the view to the
workflow browser. The view reads the complete page set of `/v1/runs`
(`Agentic.Tui.Service.loadHistory`). The client follows every page of every
window of the set, so the view lists each managed run of the authorized
profiles and each legacy entry of their bound retention roots once, in the
identifier order of the collection. `decodeHistory` decodes each item with
the run decoder and refuses a collection that names one run twice.
`historyRows` keeps the order of the collection. Each row shows the runtime
status and the run in the list, and the details show the workflow, the
profile, the request, the runtime status, the supervision, the verification,
the integrity and the limitations. A legacy entry
(`Agentic.Tui.Service.historyLegacy`) is an entry with an unreadable
manifest, or a known run with `observer` supervision and no request. The
status line above the list counts the runs, for example `History: current;
runs: 302 (managed 2, legacy 300)`. `Up` and `Down` select a row, `Home` and
`End` select the first and the last run, and the application state keeps the
selected row by its identity. Opening the view starts a read of the run list
through live delivery, and live delivery keeps it current while the view is
shown. `g` reads it again. A declared refusal keeps the last complete run
list and marks it stale with the refusal code.

`Enter` on a row opens the read-only run detail of that run. It selects
nothing and sends nothing, so the selection, its reads and a command in
progress stay. `Agentic.Tui.Service.observeHistoryDetail` reads the snapshot
page set of a managed run and `/v1/runs/{id}` of a legacy entry, whose
snapshot the manager refuses. The detail shows the run, the workflow, the
target, the runtime status, the supervision, the integrity, the
verification, the result reference and the number of occurrences of a
managed run, or the representation of a legacy entry. Live delivery keeps
the detail current while it is shown, and `g` reads it again. `r` retrieves
the verified result of a succeeded managed run with a verified or referenced
result through `Agentic.Tui.Service.retrieveResult` and
`Agentic.Manager.Client.downloadVerified`, which check the size and the
SHA-256 digest of the run outputs. `r` on any other run starts nothing and
the status line states the reason (`historyRetrievable`), for example
`result not retrieved: a legacy entry publishes no size and digest for its
result`, because the representation of a legacy entry gives no size and
digest against which the frontend could verify a download. A refused
retrieval retains no bytes, the status line states `verified result not
retrieved: CODE; r retries`, and the next `r` retries at once. `s` then opens
the save dialog, which publishes the retained bytes with
`Agentic.Tui.Save.saveExact`. `Esc` returns to the History view.

The application state keeps the retrievals of the verified results by run
identifier (`Agentic.Tui.ServiceLane.Retrievals`), for the live monitor and
for the run detail alike. Each run keeps its own retrieval and its own retry
rule, so the result of one run stays retained while another run is
retrieved. At most eight runs are kept. A retrieval of a new run beyond that
bound removes the run whose retrieval completed first, so the retained bytes
stay within 512 MiB.

`e` on the live monitor or on the run detail of a managed run opens the
export name editor when the snapshot of the run publishes a verified result
of a succeeded run (`Agentic.Tui.Service.exportSource`). For any other run,
and for a legacy entry, `e` starts nothing and shows a numbered key outcome,
for example `export did not start: the run did not succeed.` The editor takes
one export name: 1 to 128 ASCII letters, digits, dots, underscores and
hyphens that start with a letter or a digit (`exportNameValid`). `Esc`
closes it and sends nothing. `Ctrl-D` starts the export
(`Agentic.Tui.Service.Export`) through the command lane, as every mutation
key does, and a name that is not valid keeps the editor open with its reason.
The preparation of the export observes the first page of the export
collection `/v1/runs/{id}/exports` through
`Agentic.Manager.Client.observeResource` (`observeExports`), because no
displayed view holds that page. The POST body is `{"name": NAME}`, and the
strong entity tag of that page is `If-Match`. The export is sent once. A 412
`stale-revision` refusal, which the manager gives when the collection
changed after that observation, leaves the command lane idle with nothing to
resend, and the export line of the run states `Export NAME: refused (412
stale-revision); the export collection changed and nothing was sent again; e
exports again`. A new `e` and `Ctrl-D` start a new export with a new
idempotency key. After the 202 receipt, the frontend reads the export
command receipt with `Agentic.Tui.Service.observeExport` in place of the
composite read, on the timer and after each invalidation of the receipt,
also when no request or run is selected. When the command records the
effect `exported`, it reads `/v1/exports/export_{commandId}`. That receipt
must name the command, the run and the name and have the state `published`.
`Agentic.Manager.Client.downloadVerified` then downloads the export through
its `download` link and checks the size and the SHA-256 digest of the
receipt. The command then completes, and the export lines of the run show
the receipt and the verified download, for example `Export result.json:
export_cmd_21 state published` and `Export download: verified 32 bytes,
SHA-256 DIGEST`, with a bounded preview. The exported bytes are the code and
value of the verified result as compact JSON followed by one LF, as [the
protocol description](../doc/api/README.md) states, so they differ from the
bytes of the source-result artifact. A refused or unresolved export receipt
leaves the command unresolved, and nothing is sent again automatically.

`l` on the live monitor or on the run detail of a managed run reads the first
page of the lineage collection `/v1/runs/{id}/lineage-requests` through
`Agentic.Manager.Client.observeResource`
(`Agentic.Tui.Service.observeLineageCollection`) and opens the lineage menu
(`Agentic.Tui.Service.LineageMenu`). The key ends a read in flight, and live
delivery fetches that read again. For a legacy entry, `l` opens nothing and
the status line states that a legacy entry has no lineage authority. The
menu names the parent run, counts its child requests and states for each of
restart, resume and fork whether the `eligible` list of the page names it.
When that list is empty, the menu shows the `refusal` code of the page, for
example `Refusal: quarantined; no lineage operation is eligible`. `r` sends a
restart and `s` sends a resume. `f` opens the fork edits, which list the
completed occurrences of the run snapshot (`forkTargets`) with their
observation code and published answer. There, `Up` and `Down` select an
occurrence, `d` drops its answer, `k` keeps it, and `Enter` opens the
replacement answer editor. In that editor, `Ctrl-D` converts the text by the
observation code of the occurrence with
`Agentic.Tui.Person.personAnswerValue` (`forkReplacement`), as the answer
editor converts an answer: text as given, a flag from `yes`, `no`, `true` or
`false`, an acknowledgement from empty text, and a verdict or a structured
answer from JSON text. A text that does not convert keeps the editor open
with its reason. The native preparation checks each replacement against the
persisted code and schema of the occurrence. `Ctrl-D` on the fork edits
sends the fork with one edit for each dropped or replaced occurrence. `Esc`
closes the replacement editor, leaves the fork edits, or closes the menu, and
sends nothing.

An operation that the `eligible` list does not name is refused before any
send (`Agentic.Tui.Service.lineageMutation`), and the menu shows the reason,
for example `restart did not start: restart is not eligible: the manager
lists no lineage operation for run RUN; refusal quarantined`. An eligible
operation becomes the mutation `Agentic.Tui.Service.Lineage`, which carries
the strong entity tag of the first collection page that the menu showed. The
POST body is `{"operation": "restart"}`, `{"operation": "resume"}` or
`{"operation": "fork", "edits": EDITS}`, and that entity tag is `If-Match`.
The request is sent once through the command lane. A 412 `stale-revision`
refusal, which the manager gives when the revision of the run changed after
the menu read the page, for example after the verification of its result,
leaves nothing to resend, and the lineage line of the run states `Lineage
fork: refused (412 stale-revision); nothing was sent again; l opens the
lineage menu again`. After the 202 receipt, the frontend reads the lineage
command receipt with `Agentic.Tui.Service.observeLineageCommand` in place of
the composite read. When the command records the effect `lineage-created`,
it reads the child request that the effect names, which must name the parent
run, the operation and the profile of the mutation. The command then
completes, the lineage line of the parent run states `Lineage restart:
created request REQUEST; it opens for setup and review`, and the frontend
opens the child request by its phase, as `Enter` on a request row of the
Manager overview does.

A lineage child request declares no input, because its inputs come from the
parent run, and the request screen states `Lineage: restart of run RUN; the
inputs come from the parent run`. `Enter` prepares its review. The summary
review names the parent run, the operation and the fork edits, for example
`Lineage: fork of run RUN` and `Lineage edits: replace occurrence 0 (answer
SHA-256 DIGEST)`, and the detail view `d` shows them as JSON.
`Agentic.Tui.Service.reviewMatches` accepts a lineage review only when its
lineage names the parent run and the operation of the request and it lists
one captured parent input for each input declaration of the workflow. The
frontend holds no bytes of the parent inputs, so the review shows their size
and SHA-256 as the manager states them. `y` approves the child review as it
approves any exact review, and the approved child run appears on the live
monitor.

In the input editor of a request, `Ctrl-D` sends the editor text as a
literal. `Ctrl-T` captures the exact editor text as raw UTF-8 bytes instead.
`Ctrl-O` opens a path editor. There, `Ctrl-D` reads the named local file and
captures its exact bytes, and `Esc` closes the editor. The file must be a
regular UTF-8 file of at most the `captureBytes` limit of the capabilities,
and `Agentic.Tui.Service.readCaptureFile` reads it in the frontend, so the
manager receives the bytes and never the path. A path that the frontend
cannot read keeps the path editor open with its reason and sends nothing.
Each capture key has one lane outcome, as every mutation key has. A capture
(`Agentic.Tui.Service.Capture`) is one octet-stream POST of
`/v1/captures?requestId=ID` with no `If-Match`, prepared by
`Agentic.Manager.Client.prepareCapture` and sent once. Its 202 response must
carry a capture receipt with the request, the profile, the size and the
SHA-256 of the sent bytes (`captureMatches`). When the next request read
shows the capture command receipt, the frontend prepares a new `set-input`
command with source `capture` and the capture identifier
(`SaveCapture`) from that request observation. That command completes on its
own `input-changed` effect, as a literal does. An uncertain capture or
`set-input` offers only the exact resend of the retained command. The frontend
keeps the capture receipts of the session, and a captured input agrees with
the exact review only when the review repeats the size and SHA-256 of such a
receipt. A request whose capture this session did not make therefore shows
its request screen and not an approvable review. The request screen lists
the captured inputs with their capture identifiers, and it lists the missing
inputs that the readiness of the request names.

Three more request mutations complete the setup of a request. In the input
editor, `Ctrl-R` removes the supplied value of the displayed input
(`Agentic.Tui.Service.RemoveInput`): a `remove-input` command with the name of
the input and the request entity tag as `If-Match`. A request that supplies no
value for the input shows a key outcome and sends nothing. On the request
screen of a request in the `draft` or `queued` phase, `W` opens the
confirmation of a withdrawal (`Withdraw`): a `withdraw` command with the
request entity tag. On the exact review, `X` opens the confirmation of a
discard (`Discard`): a `discard` command of the preparation with the
preparation entity tag, which also requires the `control` scope. A key opens
its confirmation (`Agentic.Tui.ServiceLane.Confirmation`) only when
`mutationKeyOutcome` would start the mutation, and otherwise it shows that key
outcome. In the confirmation, `y` decides the mutation once more with
`mutationKeyOutcome` and starts it only for the request or preparation that
the key named, while that resource is still displayed and installed. `n` or
`Esc` closes the confirmation with a key outcome that states that nothing was
sent, and the confirmation takes every other key without an action. Each
command is sent once and completes only on its own effect-observed receipt
whose effect names the request (`receiptMatches`): `input-changed` for a
removal, `withdrawn` for a withdrawal, and `discarded` for a discard. The
request screen then shows the request of that read. A removal shows the input
as missing and ends the draft of the input. A withdrawal shows the phase
`withdrawn`. A discard shows the phase `draft` without a preparation, and
`Enter` then prepares a new review.

The tui-inputs mode of `manager/test/service_http.py` captures editor text
and a local file through the actual frontend and checks both exact reviews.
It also removes a captured input, discards a review twice, prepares a new
review after the first discard, closes a withdrawal confirmation without a
send, and withdraws the request. It then checks that the coordination
database holds one command of each removal, discard and withdrawal.

The tui-controls mode of `manager/test/service_http.py` opens runs of the
ACP control fixtures from the Manager overview and sends their controls
through the actual frontend. A cancel of a held run shows `cancel accepted`
and then the runtime status Cancelled, and no frame shows the run as
succeeded or failed. A steer reaches the effect `steered`, and the run log
holds the steer record. A fail-over at a recovery head asks the spare
candidate. `i` and `b` at a recovery head whose controls offer no steer are
refused locally with numbered key outcomes and send nothing, and an abandon
then ends the decision and the run fails. The mode checks that the
coordination database holds exactly one command for each control.

The tui-redirect mode of `manager/test/service_http.py` sends redirects
through the actual frontend with the profiles of the live-redirect mode: a
first candidate that holds its turn and a spare candidate that answers at
once. A digit inside the dispatch window closes it. A digit then redirects the
held attempt to the spare candidate, the stopped attempt ends
`attempt.failed`, and the run succeeds with the answer of the spare candidate.
A second run shows that a redirect inside the dispatch window puts the chosen
target first. While an effect is in flight, the monitor lists no redirect
target, and `1` is refused locally. A third profile routes both candidates to
the hold fixture, so that the manager offers a live redirect back to the
first target after a redirect to the spare candidate. The runtime rejects it,
and the monitor shows the `rejected-stale` acknowledgement without a resend
offer or a second send. A digit without an offered target is refused locally,
and the mode checks the redirect commands in the coordination database.

The tui-decisions mode of `manager/test/service_http.py` answers asks that
the policy field `personAnswers` routes to the person through the Manager
decisions view. It configures two profiles with the fixture of the
person-answers mode, and the harness starts one prompt-source run of each.
Without a key press, the view lists the two pending heads in the order of
`GET /v1/decisions`, each a `text` ask addressed to `person
model:fixed-point`. `Enter` on the second head opens its run, the typed answer
completes that run with the typed text as its only recorded answer, and the
other head stays pending. Each answer is sent with two `Ctrl-D` presses in
one write, and the second press shows the numbered key outcome of an answer
in flight. `Esc` returns to the view, which then lists only the other head.
The frontend answers that head in the same way, and the view then lists no
pending head. The harness then starts a structured-person run, whose two
person questions take one structured object code. The view shows the answer
schema of its head, and an answer whose field `ok` is a string is refused
before any send. With a valid draft in the editor, the harness stops the TUI
process, answers the first question through HTTP, writes `Ctrl-D` and lets
the TUI continue. The TUI answer receives 412 `stale-revision`, the monitor
states `answer refused: 412 stale-revision; decision changed; draft kept`,
the second question shows the draft, and nothing is sent until `Ctrl-D`
sends the draft to the second question. The run records the harness answer
and the draft as typed values.

The tui-history mode of `manager/test/service_http.py` reads the History
view. It binds a local retention root with 300 legacy entries, more than one
window of `/v1/runs` holds, and the harness runs two prompt-source runs to
success. Without a key press, the view counts both managed runs and every
legacy entry. The rows of the view at the positions of both managed runs and
of the legacy entries on both sides of the window bound name the runs at the
same positions of the harness list, which is in identifier order. The
frontend opens the earlier run, retrieves its verified result with `r` and
saves it with `s`, and the saved file holds mode 0600 and the exact bytes and
SHA-256 digest of the artifact that the harness downloads. After a retrieval
of the later run, the detail of the earlier run still shows its retained
result. The detail of a legacy entry shows `observer` supervision, and `r`
states that a legacy entry publishes no size and digest for its result. On
the detail of the earlier run, `e` and `Ctrl-D` export its verified result
once. The detail shows the export receipt with the state `published` and the
verified size and SHA-256 digest. The export collection of the run holds that
one receipt, and the harness download of the export and the published file
hold the same bytes: the code and value of the verified result as compact
JSON followed by one LF. On the detail of the earlier run, `l` opens the
lineage menu with restart, resume and fork eligible, and `r` sends a
restart. The frontend opens the child request, which names the parent run
and the operation, and the lineage collection of the run holds that child.
`Enter` prepares its review, which names the parent run, the operation
restart and no edits, and `y` approves it. The child run succeeds and names
the earlier run as its parent and restart as its lineage. On the live
monitor of that child run, after the frontend retrieved its verified result,
`l` and `f` open the fork edits, `Enter` and `Ctrl-D` replace the answer of
occurrence 0 with typed text, and `Ctrl-D` sends the fork. The review of the
fork child request shows the replacement of occurrence 0 with the SHA-256
that the preparation states.

The application state keeps the text drafts by identity
(`Agentic.Tui.ServiceLane.Drafts`): the input editor text of each request and
input, and the answer text of each decision of each run. An editor shows the
draft of the displayed identity, so a draft survives a refresh, a resize, a
change of the selection, and leaving and reopening a run. A completed
`set-input` or answer command removes its draft. An input without a draft
shows its accepted literal, and a question without a draft shows an empty
editor. Only the decision at the head of a run can be answered, so the display
of the head of a run removes the answer drafts of the other decisions of that
run. One exception keeps a draft: when the head of the displayed run changes
before this session sent an answer to the earlier head
(`Agentic.Tui.ServiceLane.keepDraft`), the new head takes the draft of the
earlier head unless it has its own draft, a run without a head keeps the
draft, and the line `Control:` states `decision changed; draft kept`. The
frontend never sends a kept draft by itself. At most 64 drafts are kept, and
each is bounded by its editor.

After the first overview of a session is installed, the frontend starts the
event worker of the session in its own worker slot (`ServiceEventsWork`). The
worker follows `/v1/events` from the cursor of that overview with
`Agentic.Manager.Client.streamEvents`. It records the resource of each
invalidation in a set of at most 1024 resources (`Invalidated`) and records
the delivery state. It then writes one `ServiceWakeup` event to the Brick
channel unless a wakeup is pending, so a full channel never drops an
invalidation. A resource beyond the bound sets the overflow mark of the set,
which invalidates every read. The handler of the wakeup takes the set and the
delivery state, and `Agentic.Tui.ServiceLane.invalidatedFetches` routes the
resources to the reads that read them. An invalidation of an overview member,
`/v1/requests/{id}`, `/v1/preparations/{id}`, `/v1/runs/{id}` or
`/v1/decisions/{id}`, or of a resource below a member, invalidates the
overview. The manager reports a change of the runtime status of a run as
`/v1/runs/{id}/snapshot`, and the overview shows that status, so such an
invalidation reads the overview again. An invalidation of a resource
that the composite read of the selected request reads
(`Agentic.Tui.Service.compositeResources`), or of a resource below or above
one of them, invalidates the composite read. An invalidation of a run or a
decision, or of a resource below one, invalidates the decision heads of the
Manager decisions view, because a new head, an answered head and the end of a
run change them. An invalidation of a run, or of a resource below one,
invalidates the History view, which reads the run list or the detail of the
shown run. The refresh coordinator of the
session decides each fetch, so each read has at most one fetch in flight and
invalidations during that fetch give exactly one later fetch. An invalidation
of a read whose fetch waits for the read lane changes nothing. `Fetches` holds
the waiting fetches and the fetch that holds the read ticket. A fetch runs
through the single-flight read lane like any other read, under the rules of
automatic refresh: no fetch starts during a preparation or a send, after an
internal fault, or while a deferred key pauses refresh. A mutation key or an
exact resend that ends the read of a fetch makes that fetch wait again. The
overview is fetched while its view is shown, the decision heads are
fetched while the Manager decisions view is shown, and the History view is
fetched while it or its run detail is shown. An invalidation of one of these
reads while its view is hidden leaves its fetch waiting until the view opens. A fetch of the composite read
without a selected request reads nothing. A result of an earlier generation
does not install. The header row above the identity row shows the delivery
state at its right end: `delivery connecting`, `delivery live`, `delivery
polling`, `delivery disconnected since HH:MM:SSZ (CODE)`, `delivery
resnapshot`, `delivery stopped (REASON)` or `delivery not started`. The time
of a disconnection is the UTC time of the first failure since delivery last
succeeded. The pure rules `Agentic.Tui.ServiceLane.afterStream` and
`afterPoll` decide each step of the worker from its transport state
(`Follow`): the last complete event identifier, the backoff and the number
of consecutive SSE failures. After the manager ends the stream or a failure,
the worker reconnects with the identifier of the last complete event after
the jittered backoff of the client, which doubles from one second up to 30
seconds. A connection that delivered a heartbeat or an invalidation resets
the backoff and the count of failures. After two consecutive SSE failures, or
after a refusal of the stream such as 429 `storage-quota` when the two SSE
readers of the credential are in use, the worker polls with
`Agentic.Manager.Client.pollEventBatch` from the same identifier: at once
after a batch with `hasMore`, and otherwise every second. Each batch gives
the cursor of the next poll and the state `delivery polling`, and its
invalidations take the same path as those of the stream. When the jittered
backoff has passed, the worker connects the stream again. A refused attempt
while polling keeps `delivery polling` and doubles the backoff, and a
connection that delivers returns the state to `delivery live`. A 410 refusal
of the stream or of a poll ends the worker. The frontend then makes a resnapshot
(`Agentic.Tui.ServiceLane.resnapshotFetches`): the refresh coordinator
advances its generation, so a fetch in flight completes without installing,
and an overview read from before the refusal installs no old cursor. Every
read is fetched again in the new generation. Only an overview read that
started in the current generation starts a new worker from its cursor
(`overviewStartsStream`). The session generation does not change, so the
other worker results of the session stay admitted. When an overview read of
live delivery or of the resnapshot is refused, the timer reads the overview
again after the backoff of the client, which doubles from one second up to 30
seconds, until an overview installs. While the view is hidden, that read waits
until the view opens, except for a resnapshot. A refused overview read of
live delivery keeps the status line, and the overview line shows the refusal
code. Closing the client ends the worker, and an internal
fault of the worker stops the stream.

`Agentic.Tui.ServiceLane.readReachability` decides from each completed read
whether the manager answers. A read that fails with `TransportUnavailable`,
or that the manager refuses with 503 `storage-unavailable`
(`managerUnreachable`), makes the manager unreachable, and the time of the
first such failure stays until a read reaches the manager again. Any other
manager refusal also reaches the manager. While the manager is unreachable,
the header row shows `manager unreachable since HH:MM:SSZ` in place of the
delivery state, and the screen context gives way to it. Every retained
observation is shown as stale (`shownStale`), with the refusal code of its own
latest read or else `manager unreachable`, so the live monitor keeps the
question of a held run and its last observation. The frontend sends no
command by itself and shows no run as cancelled or completed because of the
failure. The first read that reaches the manager again ends the state and
invalidates every read of live delivery, so each view is read again when it
is shown. The event worker reconnects as described above. After a manager
restart, the live monitor shows a run of the earlier lifetime as the manager
reports it: the runtime line names every supervision other than `owned` after
the runtime status of the snapshot, for example `Runtime: Running;
supervision lost`. A restart publishes new profile revisions, so each
workflow catalogue read first reads the current profile
(`Agentic.Tui.Service.loadProfileWorkflows`), and a request that the earlier
lifetime queued opens from the overview. The tui-failures mode of
`manager/test/service_http.py` kills the manager with SIGKILL while the TUI
shows a held run and a second request waits for the one execution
reservation, starts a new lifetime on the same root, releases the quarantined
reservation through `check-store`, `check-quarantine` and
`release-quarantine`, and approves the queued request in the TUI, whose run
then completes in the live monitor.

A credential refusal (`Agentic.Tui.ServiceLane.credentialRefusal`: a 401
refusal, `CredentialUnavailable` or `CredentialChanged`) of a read, a
preparation, a send or the event stream sets the credential-refusal flag of
the lane (`refuseCredential`). The flag records the number of the last read
ticket that the frontend issued. While it is set, `mutationAdmission` gives
`KeyCredentialRefused`, so every mutation key shows the numbered key outcome
`OPERATION did not start: the credential was refused.`, a summary `y` shows
`Approval did not start: the credential was refused.`, and no exact resend is
offered. The footer and the key help offer no mutation key. The event worker
ends with `DeliveryRefused`, and neither the timer read, the fetches of live
delivery nor the overview retry starts. The header row shows `credential
refused` in place of the delivery state, and the status line shows
`credential refused: no mutation or automatic refresh starts; g reads again`.
The installed observations stay, marked stale with the refusal code. Only a
read that starts after the refusal, which in this state is an explicit read
such as `g`, can end the state: its delivery clears the flag
(`credentialStep`), and the next installed overview starts the event worker
again. The delivery of a read that started before the refusal does not clear
it. The frontend never falls back to a local launch. The tui-failures mode
also revokes the TUI credential through local administration while the TUI
shows a held run. It requires the refused state, a refused `Ctrl-D` and a
refused `Enter` on the workflow browser with no command added, and a run that
still runs at its question as the harness credential reads it. It then quits
the TUI with `q`. In a second TUI session with a new credential it opens the
held run and quits with `Ctrl-C`. After each quit no process of the TUI
process group remains, and the run still runs at its question.

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
internal-fault flag, the resend confirmation and the credential-refusal flag. Every read of the manager
passes through that single-flight lane. One composite read covers the selected
request, its review, the receipt of a retained command, and the run snapshot,
run controls and pending decision, and a complete read is installed in one
step. Without a live event stream, in particular while the event worker
polls or is disconnected, the frontend repeats the read on a one-second
timer. While the stream is live, live delivery reads it again after
each invalidation of a resource that it reads, and the timer read is a safety
read at most every five seconds (`safetyReadDue`). A timer read that starts
no read, because another read holds the read lane, does not count toward
that interval. `g` requests it at once. A declared refusal keeps the last complete observation and marks it
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
retained command unchanged. When the receipt read of a retained command
reports `refused` or `unresolved`, for example for an approval or an answer
whose dispatch a manager restart left unresolved, the lane keeps the original
pending command and receipt location, and the notice states the receipt state
and the reconciliation that `Agentic.Manager.Client.reconcile` gives
(`Agentic.Tui.ServiceLane.receiptReconciliation`), for example `Outcome
unresolved: receipt unresolved; reconciliation uncertain`. Only `x` and `y`
send it again. A 412 `stale-revision` refusal of a send is
definite, because the manager recognizes a matching retry of a durable
command before it evaluates the precondition. The lane becomes idle, retains
nothing to resend, and reads the selection again
(`Agentic.Tui.ServiceLane.SendRefused`). A refused answer keeps its draft,
and the line `Control:` states `answer refused: 412 stale-revision; decision
changed; draft kept`. Any failure that the client does not declare is an
internal fault. The frontend then shows fixed text without exception detail,
stops automatic refresh and every further mutation, and keeps only read-only
actions and detachment. `Ctrl-C`, or `q` while no answer editor has the keys,
exits without cancelling manager-owned work. Service mode owns no child
process, so the manager runs continue and no process of the frontend remains.

A question head accepts the simple codes `text`, `verdict`, `flag` and
`receipt`. `Agentic.Tui.Person.personAnswerValue` converts the editor input by
the question code, as in the local person view, so `false` for a `flag` question
is sent as the JSON value `false`. A question with a structured code takes
JSON text in the structured answer editor. Its header shows the editor schema
of the decision, for example `structured JSON {"notes": [string], "ok":
boolean}`. Before any send, `Agentic.Tui.Service.editorCheck` checks the JSON
value against that schema (`Agentic.Tui.Service.EditorSchema`): the exact
fields of an object, the type of each value and of each array item. A value
that does not agree is refused with a numbered key outcome that names the
first field, for example `answer did not start: answer field ok must be a
boolean`. A structured question whose decision gives no editor schema takes no
answer. The answer carries the entity tag of the displayed decision as its
precondition. `Ctrl-D` while an answer to the displayed decision is in flight
shows the numbered key outcome `answer did not start: an answer to this
decision is in flight.` and sends nothing (`Agentic.Tui.Service.answerKey`).

The live monitor sends a run control only when the displayed run controls
(`/v1/runs/{id}/control`) offer it. `c` opens a cancel confirmation when the
controls allow a cancel, and its `y` sends the cancel with the entity tag of
the displayed control observation. `i` and `b` open the steer editor below
the monitor for a steer with the timing `interrupt-now` or `next-boundary`
when a steer offer has that timing. The offer of the selected occurrence
comes first. `Ctrl-D` sends the text with the entity tag of the displayed
control observation, and `Esc` closes the editor. At a recovery head, `r`
sends the retry that the controls offer with the entity tag of the control
observation. `f` and `a` send the fail-over or the abandon choice that a
`choose-recovery` offer of the controls carries through `POST
/v1/decisions/{id}`, with the entity tag of the displayed decision
observation. The recovery dialog and the footer show the key of each offered
choice and list the published choices that the controls do not offer. A key
for an operation that the controls do not offer sends nothing and shows a
numbered key outcome, for example `steer did not start: the manager offers no
interrupt-now steer for this run.` The footer shows `c CANCEL`, `i/b STEER`
and `1-9 REDIRECT` only while the controls offer them.

The controls offer `redirect` for an occurrence inside its dispatch window,
and after the window for the one attempt in flight of an occurrence that is
not an effect ([the control contract](../manager/CONTROLS.md#fail-over-and-redirect)).
`Agentic.Tui.Service.redirectOffer` selects the redirect offer of the selected
occurrence, or else the first redirect offer. The live monitor shows it on
the line `Redirect occurrence N`, which states the open dispatch window or the
attempt in flight and lists each offered target with its digit, for example
`Redirect occurrence 0, attempt 0 in flight: 1 model controlled@spare`. A
digit key from `1` to `9` sends the redirect of that occurrence to the target
of that digit to `POST /v1/runs/{id}/control`, with the entity tag of the
displayed control observation. The body names the occurrence and the target.
The attempt in flight is shown only, because the redirect body names no
attempt. A digit without an offered target sends nothing and shows a numbered
key outcome with fixed text: `redirect did not start: the manager offers no
target 9 for occurrence 0.`, or `redirect did not start: the manager offers no
redirect for this run.` when no redirect is offered, for example while an
effect is in flight.

`Agentic.Tui.Service.controlOutcome` reads the outcome of a control from its
own receipt, and the live monitor shows it on the line `Control:`. A cancel
completes when the runtime acknowledgement accepts, queues or delivers it,
because the runtime cancellation names no control and the receipt records no
cancel effect. The line then shows `cancel accepted; waiting for the runtime
status Cancelled` until the snapshot publishes the runtime status cancelled,
and `cancel accepted; the runtime status is Cancelled` after it. An accepted
cancel is never shown as a finished or succeeded run. A steer completes on
the effect `steered`, and a fail-over or an abandon on the effect
`recovery-chosen`, which the line shows as `steered`, `failed over` and
`abandoned`. A redirect completes on the effect `redirected` for its
occurrence, which the line shows as `redirected occurrence 0 to TARGET`, or as
`redirected occurrence 0 from attempt 1 to TARGET` for a live redirect. A
runtime acknowledgement that rejects a control (`rejected-stale`,
`unsupported` or `failed`) is the outcome of that control: the line shows, for
example, `redirect to TARGET: runtime acknowledgement rejected-stale`, the
command lane becomes idle, and nothing is sent again.

A run is terminal only when the snapshot runtime status is succeeded, failed,
cancelled or orphaned. For a succeeded run with a verified result reference,
the frontend reads the run outputs and downloads the artifact through
`Agentic.Manager.Client.downloadVerified`, which checks the size and SHA-256
digest. It retains up to 64 MiB of unchanged bytes and does not retrieve them
again. A declared refusal, or a retrieval that finds no verified result, retains
no bytes. The status line and the result lines show it as a failure that the
next refresh retries. An automatic refresh retries after the next installed
composite read, so each automatic refresh starts at most one retrieval, and
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
unreadable manifest. The Manager overview view reads the members of the
`/snapshot` overview, and the History view reads the `/runs` collection.
Service mode does not read the `/requests` collection.
`tui-model-test` checks these decoders, the decision and control decoders and
the answer conversion against the `resources` section of
`test/manager_client_vectors.json`, which [the protocol
description](../doc/api/README.md#pages-and-live-delivery) describes.

The summary view of the exact review (`serviceReviewRows`) shows the request,
the preparation, the profile with the expiry, the `If-Match` value and the
five approval selectors. `d` in the footer opens the complete exact review.
`serviceReviewAllowed` reserves the rows of the longest approval-key notice
and permits approval only when every row fits. With the identifiers that the
manager issues, a review without lineage fits 80x24, and at 40x12 a summary
`y` shows `Approval did not start: the complete review does not fit. Resize
the terminal.` The header row above the identity row always shows the
delivery state, or the state that replaces it, complete after at least one
space, and a long screen context gives way to it. At 40x12 the service lines
of the live monitor fill the main area, so the terminal and result lines
appear from 80x24 on, and `d` shows the run details at every size.

The tui-sizes mode of `manager/test/service_http.py` drives the service
journey through the keyboard at 40x12, 80x24 and 140x36. At 40x12 the TUI
opens the catalogue, pastes the literal into the input editor, and keeps the
draft across a resize to 80x24 and back. It sends the literal and prepares the
review, and a summary `y` is refused because the selectors do not fit. A
resize to 80x24 keeps the review with all five selectors, and `y` approves
there. At the question head the TUI types the answer, and a resize to 140x36
keeps it in the editor. The TUI answers, retries the recovery, shows terminal
success and the verified result, and saves it with `s`. The live monitor, the
Manager overview, the Manager decisions view and the History view are each
resized to all three sizes, and the mode requires the restored terminal after
`q`. The control mode `tui-sizes-broken-draft` clears the input editor before
the first resize and must fail with `JOURNEY-ASSERT draft survives resize`.

The [manual](../doc/agent-cat.texi) entry for `--service` states the complete
key behavior. Service mode is not an accepted milestone.
