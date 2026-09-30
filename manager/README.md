# Manager implementation boundary

This directory provides trusted profile configuration, registry, and discovery
operations and scoped private SQLite coordination storage through
`Agentic.Manager`, alongside dependency probes and import checks. The CLI
composes operator files through the existing registry-based target parser. It does not yet contain a workflow-manager service.
Implementation follows the [approved design](../doc/research/workflow-manager.md), its
[work packages](../doc/research/workflow-manager-implementation-plan.md), and the
[operator-approved SQLite scope amendment](../doc/research/workflow-manager-storage-amendment.md).

## Retained history and lineage

`Agentic.Manager.History` materializes complete observations of the manager root
and explicitly supplied local retention bindings. Every configured retention root
requires exactly one binding, and a missing binding refuses the observation.
Its contract is at most 256
entries and 1 MiB of public JSON within 30 seconds. Each Runtime journal read
is bounded at 64 MiB, and the catalogue fold releases each full snapshot before
reading the next. Overflow or an unassociated manager-root entry refuses the
whole observation rather than returning a prefix. HTTP page sets remain outside
this library, and the served run collection uses the Overview owner that the
next section describes. A request association normally commits before native start creates
its directory.

Local retention bindings validate an already configured root and profile. Their
opaque handles retain that exact root identity and profile across reopening.
Unreadable entries remain visible without invented workflow or native facts.
Historical workflow IDs reuse the existing profile-scoped identity rule even
when current discovery no longer contains the workflow. Retained result references
use the shared Artifacts and Runtime verification path, independently of later
journal damage. Downloads recheck the exact configured root and profile after
capture and immediately before callback entry. History retains the artifact
owner's fixed failure reason and rejects a managed revision changed since its
sample. The optional original Admission controller supplies live ownership
observations. Durable flags and absent controllers do not establish ownership.
These observations grant no worker, signalling, or cleanup rights.

Configured legacy roots remain read-only and refuse lineage mutations. This root
policy does not reject legacy manifest formats on the manager-owned root.
Restart, resume, and fork create distinct ordinary drafts through Commands and
use the existing admission, preparation, approval, and Worker owners. The route
accepts no workflow, input, target, root, or invocation override. Parent manifests
and typed edits are immutable. The accepted parent binding remains private in
assembly and review. Admission rechecks it after native preparation and before
review publication or approval consumption, including the selected descriptor
and inherited inputs. The native worker retains its post-approval revalidation.
These point-in-time checks do not attest the exact bytes read under adversarial
cross-process substitution followed by restoration. Invocation comparison uses
the current configured profile independently of descriptor availability.

The history checker in `manager/ci/artifacts.sh` owns local capability and
catalogue child processes. Its deadline unwinds the original ProcessGroup owners
inside Haskell. Its blocked-query check observes cleanup through that original
token, while a checker timeout remains a failure rather than cleanup certification.
The existing compiled audit modes `history-observation` and `history-corrections`
exercise response-entry and native lineage barriers. The latter belongs to
`manager/ci/approval.sh` and compares the manager path with the direct native
frontend at N1 and N8. Client compatibility remains separate evidence.

## Overview and read collections

`Agentic.Manager.Overview` materializes the `/v1/snapshot` overview and the
frozen `/v1/requests`, `/v1/runs` and `/v1/decisions` collections. Each source
takes the file slot, then the configuration guard and one reader charge, in
the Store lock order. It reads the member identifiers of the authorized
profiles and the retained event cursor in one transaction, renders each member
through its detail owner, and reads the cursor again. A changed cursor refuses
the page with `StoreBusy` instead of combining two commit boundaries. The
materialization has an allowance of five seconds and a limit of 64 MiB, and
`Pages` divides the result into page sets. `Transport.respondBytes` returns
every loan before the first network write.

Each identifier query has a bound of `Overview.windowSize`, 1024
identifiers. The overview lists and the decision collection hold only live
items, and a list larger than the bound refuses with `ViewTooLarge` before
any member renders. The request and run collections select keyset windows:
each window reads at most 1025 identifiers in identifier order, after the last
identifier of the previous window, and keeps 1024 of them. The first window
also counts the members at its boundary. Each window has its own boundary,
allowance and limit.

Requests render through `Drafts.readDraftAt`, managed runs through
`History.managedRunInView`, and decisions through `State.decisionInView`, so
each collection item equals its detail representation. The request collection
lists every request of the authorized profiles, including withdrawn, refused
and associated requests. The run collection lists every managed run of those
profiles. The decision collection lists the pending run heads that
`State.decisionHeadIds` selects in manager observation order, or, with a run
selector, the pending queue that `State.decisionQueueIds` selects for that
run. The run collection also lists the legacy entries of the retention
roots that the service binds, as "Served legacy history" states.

`Pages.withPage` reserves a set for the client, authorization view, path and
query before the owner materializes it, and keeps the encoded pages until the
last page has been sent, a send fails, or the sixty-second lifetime ends. Its
`Producer` supplies the first window with the set revision and total, and each
following window after a last identifier. `Pages.wholeSet` is the producer of
a set of one window. A set holds the pages of its current window only. The
token of the page after the last page of a window builds the next window,
replaces the held pages and renews the lifetime, and a token of any other
index outside the current window refuses with `ViewExpired`. The
`collections` mode of `manager-artifact-check` pages request and run
collections of 2W + 1 members through three windows of a small test size W,
and checks the stale index and a collection of at most one window. The
`pages` mode of `manager/test/service_http.py` checks these facts through the
running protected manager: every page of multi-page sets and their ETags, token
binding and expiry, the per-client quota, a mutation between two pages,
revocation, a connection reset during a page, the 413 bound and the absence of
private bytes from every page body.

### Served legacy history

`RUNNER --manager serve --config ABSOLUTE_FILE` accepts the repeatable option
`--legacy-history ROOT=PROFILE`. ROOT is an absolute path that must be one of
the configured `localRetentionRoots`, and PROFILE must be a configured profile.
The profile follows the last equals sign, and each ROOT can appear once. At
service start, `serveManager` binds each pair through
`History.bindLegacyHistory`, which records the root in `history_roots` with
`legacy=1` and refuses a binding of the same root to another profile. A
binding that fails refuses the start with the configuration diagnostic, and
the listener does not open. Without the option the service binds no retention
root, and the run collection lists managed runs only. The service does not
require a binding for each configured root.

`Service` keeps the bindings. For the run collection, `History.legacyRuns`
renders the entries of the bound roots of the observable profiles before the
Overview source takes its loans. It applies the history bounds of 256 entries,
1 MiB and 30 seconds, and it retains each opaque handle, result reference and
revision first. Overview then merges these entries into the identifier order
and keyset condition of the managed runs, lists those of the authorized
profiles, and counts them in the total. No window writes to the Store.
`GET /v1/runs/{id}` reads a retained legacy entry through `History.legacyRun`
and returns the same representation. A retained entry of a root that the
service does not bind, or of a profile that the credential cannot observe,
refuses as an unknown run.

A legacy entry uses the frozen Run representation with `observer`
supervision, a null `requestId`, and the limitations that
`History.legacyItems` computes. An unreadable legacy manifest gives the
`unreadable-manifest` form. The frozen Run schema represents every legacy
entry without a contract change. Its advertised result artifact downloads
through `Artifacts.artifactDownload`, which rechecks the configured root and
profile. The control, snapshot, output, export and lineage-request resources
resolve runs through `State.resolveRun`, which finds no managed run for a
legacy entry, so they refuse with `insufficient-scope`. Case 10 of the `pages`
mode of `manager/test/service_http.py` writes one completed run into a
configured retention root through a local frontend session, serves it with
`--legacy-history`, and checks the collection item, the detail resource, the
result bytes and these refusals.

The export and lineage-request collections of one run use their owners.
`Artifacts.withRunExportsSource` supplies the export receipts, as
[ARTIFACTS.md](ARTIFACTS.md) describes. `Drafts.withLineageRequestsSource`
takes the file slot, then the configuration guard and one reader charge. It
reads every child request through `Drafts.readDraftAt` and refuses more than
256 children or 1 MiB of encoded children. It refuses with `StoreBusy` when
the parent revision changes while it reads. Its eligibility applies the parent
checks of `createLineageDraft` in the same order: supervision and reservation,
profile quarantine, root identity and ownership, invocation, and the parent
workflow in the current catalogue. Cleanup-pending supervision and a
quarantined profile give `quarantined`. Live or foreign ownership and a changed
root give `ownership-unavailable`. A different invocation and a workflow absent
from the catalogue give `incompatible-parent`. A refusal lists no eligible
operation. Eligibility does not read inherited inputs, checkpoints or effects.

## Non-network lifecycle harness

`manager/ci/vertical.sh` builds `manager-vertical-check` and its configured native
frontend with Haskell warnings treated as errors, then runs fresh private roots at one
and eight runtime capabilities. It reuses the approval probe's original Worker,
Admission and Store owners without an HTTP listener. The sequence exercises
captured inputs, exact approval, concurrent runs, typed person answers, ACP
recovery and steering, verified results, exclusive export, history, lineage,
restart and uncertain delivery. Existing ingestion fixtures supply malformed
sequence and terminal-trace refusals through the same manager ingestion path.
Parent-substitution races and blocked control writes run through the existing
instrumented audits after the ordinary N1/N8 sequence.

`VerticalCheck` compares independently executed managed and direct native runs.
It uses Runtime codecs, artifact verification and lifecycle projection, and
compares complete native manifests, captured bytes, typed answer records,
checkpoints, effects, ordered events, policies and exact bills. The log records
injective run and control correspondences and explicit owner, timestamp and
verified artifact correspondences. Only physical identities, wall clocks and
artifact envelopes containing those identities may differ. Authored occurrence
and attempt coordinates, answer text, typed values, lineage edits and policy
facts must agree exactly. The lineage fixture explicitly declares its independent
model occurrence and shared person lane. Their physical events may interleave,
but each lane retains its original order and the start, authored trace and
terminal boundaries stay fixed. Every original sequence validates independently,
and the log records each matched sequence pair without sorting or dropping events.
Mutations of actual answers, bills, within-lane order or event counts must fail
the comparison. The capture fixture hashes the complete semantic input inside its
workflow so that large input transport does not require an oversized review.
Raw captured bytes are also compared without normalization.

The gate retains its private roots and logs. It does not certify client,
network, deployment or platform acceptance, and it performs no OS containment.

## Client baseline policy

The minimum supported targets for the version 1 manager clients are GNU Emacs
30.2 and Pi coding-agent 0.85.1. Older versions are outside this manager-client
support policy. This baseline does not narrow the native extension's existing
peer-dependency declarations or establish service-mode compatibility before the
owning client acceptance gates run.

These minima are support-policy decisions, not inferred compatibility limits.
The [native frontend evidence](../doc/tui-release-evidence.md) records Emacs 30.2
byte-compilation, checkdoc, and smoke execution. The Pi package pins coding-agent
0.85.1 for development, and the installed host reports that version. Companion
Pi client, server, and TUI package pins are separate dependencies rather than
coding-agent version floors. The current pinned development shell reports Node
22.23.2, which is a reproducible build-runtime observation rather than an
independently established Node compatibility minimum.

No older-version compatibility or manager service-mode test is implied by these
records. Each released client must pass its owning acceptance gate on its actual
environment, including versions newer than the baseline.

## Profile authority

`OperatorProfile` is a private immutable value supplied by trusted CLI
composition. It contains the configured invocation, working directory, target
arguments, explicit environment, public labels, ownership classification,
quarantine state, person-answering mode, resource keys, and a configuration-limits
snapshot. It has no generic `Show`, `Eq`, or JSON representation. The
caller validates concrete target grammar, named-route ownership, workspace
policy, and root ownership before installation. An invocation copied from a
manifest or a process-reported server identity does not supply that authority.

`newRegistry` creates a private registry with positive per-query budgets capped
at 4 MiB per output stream and 30 seconds per query. `reloadProfiles` validates
the entire candidate set before atomically replacing its snapshot. Every
successful reload gives every profile a new revision, even when its values are
unchanged. The revision combines a random registry namespace with a generation
counter and contains no secret-derived hash. Invalid definitions leave the
previous snapshot and revisions intact.

`probeProfile` accepts only an installed ID and its exact revision. It refuses
unknown, removed, stale, client-bound, and quarantined selections before any
subprocess. The registry lock covers every discovery query and the readiness
update. Each query uses the installed executable, ordered prefix, working
directory, and explicit environment. The commands are `frontend --capabilities`,
then `list --json --descriptor-version 3`, then one `help NAME` for each
catalogue row. Their streams are drained concurrently and bounded before the
shared Runtime codecs decode them. Required operations and versions are
checked, and catalogue runner versions must agree with the reported server.
Missing support makes the profile unavailable. A pool of four workers runs the
help queries, and each worker starts the next row when its previous query ends.
All of them share one deadline equal to the configured query time. At that
deadline, each help query in flight completes its own process cleanup before
discovery reports a query timeout. Each help reply is checked as valid UTF-8 of
at most 262144 characters when it arrives, and a rejected reply stops the pool
from starting later rows. Replies are accepted in catalogue order against the
discovery byte ceiling. Replies that wait behind an earlier row count against
the same ceiling, so the pool starts no row once their sum crosses it. The
first failure in catalogue order is the reported failure. When acceptance
reaches that failure, discovery cancels the help queries in flight, lets each
complete its own process cleanup, and reports the failure without waiting for
the deadline.

`publicProfiles` emits the frozen public Profile shape without invocation,
environment, target arguments, or raw diagnostics. Failures are fixed categories
rather than stderr or decoder messages. `selectProfile` returns an opaque
immutable context only after current revision and readiness checks. That value
is not approval, and this module has no operation that launches a returned
selection. Approval commitment must be serialized with reload by the owning
coordinator. An approved worker keeps its captured environment rather than
taking a later profile's bindings.

These operations do not freeze mutable executable or configuration files.
They do not infer ownership from executable names or ACP transport, and process
groups do not provide a sandbox. Each query has its own time budget, while the
shared Runtime cleanup retains sole-reaper authority and can exceed that budget.
The configuration layer captures person and resource policy but does not enforce
quotas or implement approval and worker lifecycles. Those integration obligations
remain explicit.

## Operator configuration

The [versioned operator format](CONFIGURATION.md) is loaded through
`Agentic.Cli.loadManagerConfiguration`. `openManagerConfiguration` installs a
validated snapshot, and `reloadManagerConfiguration` replaces an active one.
They reuse the actual native target parser and credential-argument policy,
including prefix checks on unused runner definitions. The manager receives
validated private values rather than executable data from a network request.

The shared Runtime reader checks the opened file's type, effective-user
ownership, private permissions, and byte bound before reading it. Configuration
parsing checks Aeson's decoded token stream for duplicate keys and excessive
nesting before object-map construction. Unknown fields and invalid definitions
refuse with fixed diagnostics, without publishing a role marker or starting a
query process.

Initial installation requires an existing, durably provisioned private root.
Active operations recheck the retained root, its existing manager role, and
configured retention-root separation. Reload cannot change the root binding or
repair a missing role marker. A masked configuration transaction replaces profile
revisions and the configuration-limits snapshot together. Closing the installed
handle closes its descriptor without removing the manager role.

`manager/ci/configuration.sh` builds canonical Cabal targets and runs the actual
CLI configuration probe at one and eight runtime capabilities. Its private
fixture evidence remains under `CABAL_BUILDDIR`. No service, provider execution,
or approval implementation is substituted for that configuration check.

## Coordination storage

The [storage contract](STORAGE.md) describes the installation lease, scoped
SQLite lifetime, relational records, atomic invalidations, bounded internal
transactions, and passive checkpoint results. `withCoordinationStore` consumes
the existing installed configuration without exposing SQL, bearer material or
worker authority. The local credential operations described in
[COMMANDS.md](COMMANDS.md) use that original Store through trusted embedding,
the exclusive offline stdin CLI, or its configured same-user local channel.
`withLocalAdministration` scopes that channel around an existing Store owner's
action. It creates no HTTP listener. `RUNNER --manager serve` starts the
foreground HTTPS service and serves this channel for the lifetime of that
service.

`manager/ci/store.sh` runs the real library composition and native SQLite tests
at one and eight runtime capabilities. Storage mechanisms do not establish the
later admission, receipt, recovery, retention or worker-cleanup contracts.

## Command receipts

The [command contract](COMMANDS.md) provides transactional idempotency, exact
request bindings, current credential and profile checks, ledger reservations,
independent cancellation capacity, and one-shot live dispatch. The actual worker
and native-evidence adapters remain separate. Public receipt codecs follow the
frozen contract and remain independent of SQLite and authorization machinery.

`manager/ci/commands.sh` runs real N1 and N8 database and offline/live local CLI
checks, frozen-validator interoperability, and compiler-negative proof-opacity
checks. The local administrative channel does not provide a public HTTP service.

## Drafts and immutable inputs

The [draft contract](DRAFTS.md) provides catalogue-authorized creation, immutable
creation replies, literal chunk integrity, bounded capture publication, readiness
and shared frontend-frame assembly. It retains the existing literal/transport
meaning. The admission owner supplies live-worker edit invalidation and confirmed
cleanup without changing the standalone draft operation into a worker owner.

`manager/ci/drafts.sh` exercises actual installed-runner discovery, SQLite,
Runtime publication and codecs at N1 and N8. Public output is checked with the
frozen validator. Worker ownership, approval and later retention remain separate.

## Native frontend workers

The [worker contract](WORKERS.md) provides scoped native frontend ownership,
serialized private controls and bounded lossless ingestion. It reuses the actual
CLI proxy/pre-RTS bootstrap and Runtime ProcessGroup completion. Observers neither
consume the manager ingestion queue nor own its pipes. Approval and durable
ingestion have separate owners, as does restart reconciliation.

`manager/ci/workers.sh` runs actual native N1/N8 workers, controlled phase failures,
queue/observer/write regressions and original-token cleanup retention checks.

## Admission and reservations

The [admission contract](ADMISSION.md) provides explicit enqueue, global
oldest-eligible selection, atomic resource claims, live preparation ownership,
monotonic review expiry and cleanup-confirmed release. It extends the existing
command and draft owners for real edit and withdrawal invalidation. Original
worker associations remain opaque and are not reconstructed after reopen.

`manager/ci/admission.sh` runs bounded policy properties and real native lifecycle
checks at N1 and N8. The [approval owner](APPROVAL.md) supplies complete review, exact approval and actual
accepted-running retention through the original Worker. Its owning gate adds final
worker/deadline checks and interruption evidence without a new service endpoint.

## Root separation

`validateRootSeparation` compares manager storage with the configured local
retention roots. It checks canonical path ancestry and observed directory
device/inode identities, including the suffix of a not-yet-created path.
Equal, nested, and observed aliased roots refuse before a worker is started.
The supplied manager `PrivateRoot` is revalidated around the check. A successful
check is an observation, not authority for later pathname operations, and it
does not freeze filesystem mounts or discover aliases outside the inspected
ancestor paths.

The shared Runtime root-role contract records manager ownership independently
of manifests. The current TUI uses that contract for local startup, discovery,
catalogue refresh, preview, and launch boundaries. It refuses a manager root
even when its run directories have no manifests. Generic Runtime observation
and manager IO remain available. Pi and downstream Emacs adoption are not
provided by this component, and older clients still require configured directory
separation. See [the Runtime contract](../runtime/README.md#state-root-roles).

`manager/ci/profiles.sh` builds the actual library and runs the profile and root
checks at one and eight runtime capabilities. It retains private fixture evidence
under `CABAL_BUILDDIR`. Process checks use a deterministic executable with actual
Runtime capability and descriptor codecs. No provider or workflow execution is
part of that gate.

## Selected facilities

The dependency evaluation on 2026-09-10 selected WAI 3.2.5, Warp 3.4.15,
warp-tls 3.4.14, and direct-sqlite 2.3.29 through pinned Nix definitions. The
SQLite binding uses its standard `systemlib` flag and the pinned SQLite 3.53.3,
not its bundled SQLite 3.45.0. The latter predates the
[WAL-reset correction](https://sqlite.org/wal.html#walresetbug).

Direct-sqlite supplies the public `open2`, `SQLOpenNoFollow`, statement, binding,
and backup interfaces needed at the storage boundary. The evaluation did not
select sqlite-simple, whose public opening interface does not expose these
flags. The hidden storage module unwraps the binding handles only for native
SQLite limits, bounded column accounting, and statement-readonly checks. No
alternate database implementation is used. Production package dependencies are added when production code
first uses them, while the development shell already supplies the probe tools.

Cabal gates use `test/cabal.sh`, which disables repositories and isolates its
store below `CABAL_BUILDDIR`. This prevents a user-level Cabal store from mixing
a different TLS package instance with the Nix-provided HTTP client/server
libraries. No source download or dependency installation through Cabal is part
of the gate.

## Licensing and maintenance assessment

The package metadata and changelogs below were checked on 2026-09-10. These
sources establish the licensing and maintenance decisions, not a claim that a
particular package will remain the latest release.

| Component | License and source | Assessment and decision |
|---|---|---|
| WAI 3.2.5 | [MIT package metadata](https://hackage.haskell.org/package/wai-3.2.5/wai.cabal). | The maintained yesodweb/wai release line provides the incremental body interface used by the probe. Version 3.2.5 supplies the request representation required by the selected Warp release. |
| Warp 3.4.15 | [MIT metadata](https://hackage.haskell.org/package/warp-3.4.15/warp.cabal) and [versioned changelog](https://hackage.haskell.org/package/warp-3.4.15/changelog). | The initial Nix version, 3.4.9, predates the 3.4.13 shutdown changes, 3.4.14 descriptor-exhaustion deadlock fix, and 3.4.15 header/connection fixes. It was not retained as the implementation dependency. The updated release and required HTTP libraries are fixed by source hashes. |
| warp-tls 3.4.14 | [MIT package record](https://hackage.haskell.org/package/warp-tls-3.4.14), uploaded on 2026-04-16. | The shared release line remains compatible with the chosen Warp and TLS packages. The old introductory recommendation permitting TLS 1.0/1.1 is not adopted. The actual probe configures TLS 1.3 and verifies certificate and plaintext refusal. |
| direct-sqlite 2.3.29 | [BSD-3-Clause package metadata](https://hackage.haskell.org/package/direct-sqlite-2.3.29/direct-sqlite.cabal). | The public low-level API meets the required opening/binding operations and builds with the current GHC. Its bundled engine and older changelog demonstrate maintenance lag, so engine updates are taken from the pinned system SQLite rather than the bundle. |
| SQLite 3.53.3 | [Public-domain policy](https://sqlite.org/copyright.html) and [WAL advisory](https://sqlite.org/wal.html#walresetbug). | The selected engine includes the WAL-reset correction, and its actual linked version is checked. Engine advisories and patch releases must be reviewed again before release. A pragma result does not prove filesystem or hardware durability. |

The compatible HTTP closure includes http2 5.4.4, http-semantics 0.4.1, and
time-manager 0.3.2. The HTTP/2 tests require network-run 0.5.0, and Warp's tests
require curl. Both test dependencies are supplied through Nix rather than
disabling upstream checks. Their source hashes and build inputs are recorded
in `nix/haskell-overrides.nix`. Package updates require the dependency probe and
owning regression gates again. Release packaging must retain applicable license
texts and notices.

## Executable evidence

Run the probe in the configured development environment:

```sh
direnv exec . bash manager/ci/dependencies.sh
```

Build products and fresh private fixtures are placed below `CABAL_BUILDDIR` in
`~/Products`. The probe exercises the actual linked SQLite version, WAL and FULL
settings, bound Unicode values, transaction rollback, reader snapshots, database
symlink refusal, and replacement refusal through the shared `PrivateRoot` guard.
It also exercises bounded chunked HTTP input, incremental response flushing,
stream cleanup after client cancellation, a TLS 1.3 listener, certificate
validation, and plaintext refusal. These are library integration fixtures, not
manager endpoints or workflow executions.

The retained-root dependency probe requires the shared guard to reject an
observed replacement before an application write. It does not establish that
SQLite's own pathname operations remain confined during directory replacement.
The operator withdrew that additional experiment and guarantee in the
[storage scope amendment](../doc/research/workflow-manager-storage-amendment.md).
Database operation assumes a stable, operator-controlled private local namespace,
while existing guards and tests remain intact. The independently verified
immutable-capture publication contract is unchanged, and a successful pragma
query is not a power-loss test.

## Process ownership and cleanup limits

The manager uses existing Runtime process ownership, private control pipes and
process-group cleanup. It does not provide an OS containment boundary. The
[user's scope correction](../doc/workflow-manager-handoff.md#scope-correction-of-2026-09-20)
excludes OS containment features and experiments across the roadmap.

The existing `containment_probe.py` records a limitation of process-group
termination: a descendant that creates a new session survives termination of
the original group. Its fixture then terminates that descendant through a
retained private pipe and checks cleanup. Its interrupted startup/readiness
cases check cleanup of owned fixture processes. This retained evidence does
not promise cleanup of arbitrary escaped descendants after manager death.

Original-handle cleanup and honest uncertainty remain required. Stored PIDs
do not confer signalling authority, and unconfirmed cleanup does not justify
resource reuse. No service, sandbox or VM boundary is required by the current
product scope.

## Module policy

Server code may depend on the shared `Agentic.Runtime` facade and manager-owned
modules, not CLI composition, authoring, concrete engines, or runtime internals.
Client modules depend on their own implementation and public manager protocol
modules, without server state, runtime interpretation, SQLite, or WAI. Public
protocol modules do not depend on either side's implementation. The TUI receives
only the exact `Agentic.Manager.Client` facade exception.

The compiler-parsed gate in `test/source-boundaries.hs` enforces these rules
with positive and negative fixtures. It derives source roots from parsed Cabal
metadata, including executable and disabled conditional components. It also
rejects manager dependencies from lower layers and preserves the existing
terminal and runtime boundaries. No empty public facade is introduced merely
to make a package directory exist.

## Exact review and approval

The internal Approval owner publishes frozen public consent with protected exact
binding and a stable nonce-bound digest. Admission retains the original worker and
one-shot start ticket through committed intent, delayed delivery, actual running
and confirmed cleanup. `manager/ci/approval.sh` runs real N1/N8 native cases, frozen
public-schema validation, opacity and test-only interrupted-delivery controls.
Runtime projection and correlated control intents have the separate State owner
described below.

## Durable Runtime ingestion

The internal State owner persists original validated Worker envelopes and restores
their immutable sequence-zero prefix through Runtime's shared checkpoint fold.
First committed evidence associates a bound managed request, with matching request
and reservation revisions in the same transaction as its projection and observations.
Exact duplicates do not publish another invalidation or repair unrelated state.

Physical cleanup does not depend on database availability. The original opaque
Worker retains validated queued evidence for later ingestion, while starts and
controls remain fenced. Failed callbacks retain the queue head for explicit retry.

The [storage contract](STORAGE.md#validated-ingestion-projections) states the
separate original-wire and canonical checkpoint bounds, fixed-prefix restoration,
concurrent publication checks and quadratic replay cost. `manager/ci/ingestion.sh`
runs the differential, genuine native, concurrency and negative-control checks at
N1 and N8. These checks do not establish a deployed manager service, public control
endpoints or general verified artifact content.

## Decisions and correlated controls

The [control contract](CONTROLS.md) provides verified person questions, recovery
choices, per-run FIFO reservations and manager-ordered run heads. Decision and
run-control entrypoints share strict acceptance and the original Admission owner.
Native frames remain in original one-shot tickets rather than durable replay
payloads. Acknowledgements, effects, terminal state and uncertainty remain distinct.
The dedicated `manager/ci/controls.sh` gate exercises native workers and compiled
negative controls. It does not introduce HTTP endpoints or client presentation.

## Verified artifacts and exclusive export

The [artifact contract](ARTIFACTS.md) describes bounded output items, authorized
captured-byte downloads and explicit exclusive publication. State owns trusted
references, Store owns the file loan and the response-lifetime artifact response
slot, Commands owns acceptance and dispatch, and Runtime owns verification and publication. Source and export
byte identities remain distinct. Durable successful-publisher observations can be
reconciled after reopen, while filesystem-only publication remains unresolved.
`manager/ci/artifacts.sh` checks the shared primitives, frozen representations and
schema-eight migration at N1 and N8 without executing workflow processes.
