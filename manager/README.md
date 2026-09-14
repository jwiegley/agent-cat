# Manager implementation boundary

This directory provides trusted profile configuration, registry, and discovery
operations and scoped private SQLite coordination storage through
`Agentic.Manager`, alongside dependency probes and import checks. The CLI
composes operator files through the existing registry-based target parser. It does not yet contain a workflow-manager service.
Implementation follows the [approved design](../doc/research/workflow-manager.md), its
[work packages](../doc/research/workflow-manager-implementation-plan.md), and the
[operator-approved SQLite scope amendment](../doc/research/workflow-manager-storage-amendment.md).

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
subprocess. The registry lock covers both queries and their readiness update.
Each query uses the installed executable, ordered prefix, working directory,
and explicit environment. The commands are `frontend --capabilities` and
`list --json --descriptor-version 3`. Their streams are drained concurrently
and bounded before the shared Runtime codecs decode them. Required operations
and versions are checked, and catalogue runner versions must agree with the
reported server. Missing support makes the profile unavailable.

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
the existing installed configuration. It does not expose SQL, credentials,
worker authority, or a network listener through the public facade.

`manager/ci/store.sh` runs the real library composition and native SQLite tests
at one and eight runtime capabilities. Storage mechanisms do not establish the
later admission, receipt, recovery, retention, or worker-containment contracts.

## Command receipts

The [command contract](COMMANDS.md) provides transactional idempotency, exact
request bindings, current credential and profile checks, ledger reservations,
independent cancellation capacity, and one-shot live dispatch. The actual worker
and native-evidence adapters remain separate. Public receipt codecs follow the
frozen contract and remain independent of SQLite and authorization machinery.

`manager/ci/commands.sh` runs real N1 and N8 database checks, frozen-validator
interoperability checks, and compiler-negative proof-opacity checks. No network
listener or credential administration endpoint is introduced by this unit.

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
consume the manager ingestion queue nor own its pipes. Exact approval, durable
ingestion and broader containment remain with their later owners.

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

## Process containment

`containment_probe.py` demonstrates the limit of process-group termination:
a descendant that creates a new session survives termination of the original
group. The fixture then terminates that descendant through its retained private
pipe and checks cleanup. It also interrupts startup and readiness waits with
SIGTERM and verifies cleanup of the owned fixture processes. This is negative
capability evidence, not a passing claim of service containment.

The Linux candidate is a service control group with finite stop deadlines,
`KillMode=control-group`, and final killing enabled. The
[upstream systemd kill contract](https://github.com/systemd/systemd/blob/main/man/systemd.kill.xml)
states that this covers the unit's remaining control-group members. Actual
Linux execution and adversarial descendant tests remain required in WM-019.

The installed macOS `launchd.plist(5)` documentation, under
`AbandonProcessGroup`, promises cleanup only for processes with the job's
process-group ID. It therefore does not establish the stronger containment
contract. The existing native supervisor and control-EOF cleanup remain useful,
but they do not justify an unattended macOS capability by themselves. WM-019
must establish the stronger boundary or keep that release capability blocked.
No service installation or platform-containment acceptance is claimed here.

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
Public Runtime projection, ingestion and full control intents remain later owners.
