# Workflow-manager implementation plan

## 1. Purpose, authority, and source baseline

This plan translates the approved [workflow-manager design](workflow-manager.md)
into implementation work for agent-cat. It is dated 2026-09-10. It specifies
work, dependencies, acceptance criteria, and release gates. It does not state
that the manager or any service-mode client has been implemented, and it does
not authorize deployment, publication, credential provisioning, or changes to
an operator's machine.

The design remains the architectural authority. This plan supplies execution
order and resolves implementation sequencing, not new workflow semantics.
The design's source inventory and protocol/security references remain relevant.
An implementation finding that contradicts an invariant requires an explicit
change decision before code proceeds. It does not justify weakening a test or
silently revising the approved record.

The baseline was rechecked against working-tree source, not merely Git HEAD:

| Area | Baseline and consequence |
|---|---|
| Agent-cat | Worktree `.worktrees/tui`, HEAD `828e8cacb7ce37c0ffc01b8576562f8747a59868`, with substantial uncommitted runtime, CLI, TUI, tests, and documentation work. The implementation must include the verified shared frontend work rather than start from HEAD alone. |
| Pi | Worktree `.worktrees/fork-agent-cat`, the same HEAD, with separately owned extension changes. Its inspected interactive launch uses `FrontendSession.prepare`. That is not evidence of production deployment. |
| Emacs | `/Users/johnw/src/agent-workflows`, HEAD `60c8dcd9ffc3b4f64fbdc5dfbc7e27c5a2dc7d31`, with native Emacs and acceptance changes. Its existing local mode remains supported. |
| Design evidence | All 34 recorded source digests still matched when this plan began. The approved design's SHA-256 was `d2e8e47b19afb14b8fe50638dcc6b5bade332ec9174333a449aa6b6f0b0d0e11`. |
| Build environment | The currently attached direnv provides documentation tools, Node, and Lake, but does not expose GHC, `runghc`, or Cabal. This is an implementation-start prerequisite, not evidence that Haskell checks passed. |

`WM-001` through `WM-044` below are stable work-package identifiers, not existing
issue IDs or completion claims. The planning issue is `acat-45vf`, following the
completed design issue `acat-e0wv`. When implementation is authorized, create
tracker issues from these packages with their dependencies and acceptance
contracts. Keep progress, evidence, and changing estimates in the tracker.
Keep this document as the implementation plan of record.

### 1.1 Scope of the first complete release

The release provides one manager process on the workflow host, trusted execution
profiles, durable requests and captures, bounded admission, exact preparation
and approval, supervised concurrent runs, decisions and controls, verified
outputs, retained history, lineage, and exclusive export. It provides an
authenticated REST API, SSE invalidations, bounded polling, and explicit service
modes for the TUI, Emacs, and Pi.

The release also includes failure recovery, offline backup restoration,
credential rotation/revocation, resource limits, operational diagnostics,
Linux/macOS containment evidence, cross-client acceptance, and a rollback path.
These are release work, not optional cleanup after a demonstration succeeds.

The release does not include multi-user tenancy, a browser application,
WebSockets, a message broker, remote arbitrary filesystem operations, surviving
worker adoption, a remote engine connector for Pi, new workflow operators, or
arbitrary typed initial inputs. Individual input descriptions remain absent
unless separately authored and negotiated. A required text input with
`description: null` is sufficient for the existing authoring surface.

### 1.2 Reading order

- Section 2 defines release gates and invariant ownership.
- Section 3 assigns source and package boundaries.
- Section 4 gives the dependency order and implementation decisions.
- Section 5 contains the 44 executable work packages.
- Sections 6 and 7 specify transaction and endpoint coverage.
- Sections 8 and 9 define regression scenarios and verification gates.
- Sections 10 through 12 cover staffing, risks, and final acceptance.

## 2. Release gates and non-negotiable invariants

A vertical demonstration is evidence for its exercised path, not permission to
expose every endpoint. The gates below separate internal execution, read-only
network operation, remote mutation, client migration, and release readiness.
No listener is introduced before its authentication and transport boundary.

| Gate | Required result | Packages that establish it |
|---|---|---|
| G0: implementation baseline | Exact source/toolchain provenance, owner agreement, compatibility fixtures, package/import rules, and the accepted API/state contract are recorded. | WM-001 through WM-007. |
| G1: isolated manager core | Real deterministic frontend workers complete the entire lifecycle under the manager without a network listener. Crash, cleanup, controls, history, and artifact evidence are exercised. | WM-008 through WM-022. |
| G2: authenticated observation | Protected HTTP access exposes authorized catalogue, history, snapshots, verified content, SSE, and polling, with bounded parsing and revocable credentials. Mutation routes remain unavailable. | G1 and WM-023 through WM-026. |
| G3: remote mutation candidate | Request, approval, control, export, and lineage routes pass hostile-input, replay, recovery, concurrency, containment, and semantic-preservation gates. Test exposure is controlled and does not constitute deployment. | G2, WM-027, WM-028, WM-040, and the applicable WM-041 evidence. |
| G4: three-client acceptance | Emacs, TUI, and Pi service modes pass their native UI gates and cross-client/cross-machine acceptance while local modes remain intact. | WM-029 through WM-039. |
| G5: release candidate | Full failure/capacity evidence, operational procedures, reproducible packages, rollback, documentation, and independent review are complete. Deployment remains an explicit operator action. | G3, G4, and WM-041 through WM-044. |

The following invariants constrain every package. Their identifiers are used in
reviews and release evidence so that a local test cannot substitute for an
end-to-end ownership claim.

| ID | Invariant | Principal implementation owners |
|---|---|---|
| I01 | Agent-cat is the sole workflow interpreter. The manager does not compute answers, bills, memoization, routing decisions, or authored traces independently. | WM-004, WM-005, WM-015, WM-022, WM-040. |
| I02 | Requests, admission, live preparations, runtime status, supervision, pending decisions, and result verification are separate dimensions. | WM-004, WM-009, WM-013 through WM-018. |
| I03 | Only the exact live prepared worker can consume an approval. Changed inputs, profile, worker, or process generation require fresh preparation and consent. | WM-012, WM-014, WM-020, WM-027. |
| I04 | A manager-owned control pipe outlives any HTTP/SSE connection. Network disconnection does not become control EOF. | WM-012, WM-019, WM-026, WM-039. |
| I05 | Durable acceptance, attempted delivery, runtime acknowledgement, control effect, and terminal outcome are distinct facts. Ambiguous effects are not automatically replayed. | WM-010, WM-014 through WM-016, WM-020, WM-027. |
| I06 | Mandatory decisions use one per-run FIFO reservation mechanism across every endpoint. Controls retain exact occurrence, attempt, and correlation identity. | WM-016, WM-027, WM-039. |
| I07 | Stored paths, root identities, native IDs, PIDs, and invocation metadata do not confer execution or signalling authority. | WM-008, WM-012, WM-018 through WM-020, WM-024. |
| I08 | Initial inputs retain their literal/captured representation and byte contract. Typed runtime answers retain false, null, structured values, and runtime decoding. | WM-005, WM-011, WM-016, WM-029 through WM-038. |
| I09 | Artifacts are verified through retained trusted references before any successful content response. Export remains exclusive and confined. | WM-007, WM-017, WM-018, WM-025, WM-027. |
| I10 | Coordination state and invalidations commit together. Runtime sequence validation remains independent of manager commit order. | WM-009, WM-010, WM-015, WM-025, WM-026. |
| I11 | Replay has an explicit retained prefix. Snapshot boundaries, open-stream eviction, duplicate handling, and client refresh ordering cannot silently lose state. | WM-021, WM-025, WM-026, WM-029, WM-039. |
| I12 | Every application operation is authenticated and authorized. The only unauthenticated CORS exception is a bounded non-resource preflight check. | WM-023, WM-024, WM-027, WM-028. |
| I13 | Credential rotation preserves the registered client's mutation ledger. Backup restoration invalidates old authority and never treats lost receipts as unexecuted work. | WM-010, WM-020, WM-023, WM-028. |
| I14 | Resource bounds are enforced before large allocation and at global as well as client/profile boundaries. Safety supervision survives ordinary queue saturation. | WM-007, WM-009 through WM-013, WM-019, WM-021, WM-024 through WM-028. |
| I15 | Existing descriptor, session, protocol, control, manifest, store, and CLI branches retain their meaning. Client local mode does not silently become service mode. | WM-003, WM-005, WM-006, WM-018, WM-029 through WM-038. |
| I16 | Mathematical proofs, deterministic tests, platform tests, cross-machine tests, and deployment evidence have separate stated ceilings. | WM-004, WM-022, WM-039 through WM-044. |

## 3. Repository structure and extension boundaries

The repository is one Haskell package with source-directory boundaries. The
first implementation follows that structure rather than introducing a package
per subsystem. The proposed `manager/src` directory joins the existing package,
with compiler-parsed import checks preventing forbidden dependencies. Names in
the proposed column are implementation targets, not existing modules.

| Existing seam | Planned extension | Boundary and verification |
|---|---|---|
| [Package](../../agentic.cabal), [Nix shell](../../flake.nix), [source-boundary gate](../../test/source-boundaries.hs). | Add `manager/src`, manager tests, necessary dependencies, and public facades `Agentic.Manager` and `Agentic.Manager.Client`. | Keep the single-package model. Do not broadly split dependencies or reorganize existing libraries. Assert client/server import separation and preserve all existing forbidden edges. |
| [CLI frontend](../../cli/src/Agentic/Cli/Frontend.hs), `SetupRequest`, `Setup`, `InputSource`, `parseSetupRequest`, `parseDecision`, `captureInputs`. | Extract only reusable transport data, encoders, decoders, and bounds into a neutral module such as `Agentic.Runtime.Frontend.Protocol`, re-exported through `Agentic.Runtime`. | `FrontendPreparation`, registry callbacks, routing selection, environment construction, and semantic preparation remain at their existing composition boundary. Do not move a CLI interpreter into runtime. |
| [Runtime protocol](../../runtime/src/Agentic/Runtime/Protocol.hs), [control](../../runtime/src/Agentic/Runtime/Control.hs), [snapshot](../../runtime/src/Agentic/Runtime/Snapshot.hs). | Reuse validation, control encoding, and `stepRunSnapshot`. Add only the neutral representation/query support required for durable restoration and API projection. | `runSnapshotValue` already contains full occurrences and control acknowledgements. The gap is not a missing reducer. The helper's compact history reply and a durable full-snapshot decoding/checkpoint contract require separate treatment. |
| [Runtime frontend queries/export](../../runtime/src/Agentic/Runtime/Frontend.hs), [catalogue](../../runtime/src/Agentic/Runtime/Catalogue.hs), [store](../../runtime/src/Agentic/Runtime/Store.hs). | Build manager artifact/history adapters over existing helpers and verified references. Introduce a versioned helper extension only where the existing surface cannot supply a required observation. | Keep `frontend-io` v1 replies unchanged. Manager pagination does not imply that the existing bounded catalogue is unbounded. Never silently omit history after its current enumeration bound. |
| [PrivateRoot](../../runtime/src/Agentic/Runtime/PrivateRoot.hs), `publishPrivateFileAt`, [directory C support](../../runtime/cbits/private_directory.c). | Add a narrowly named durable publication facility or strengthen the shared operation with explicitly reviewed compatibility. Validate SQLite companion-file confinement. | Current exclusive publication uses `hFlush`, linking/renaming, and private descriptors. It is not a power-loss durability barrier. File and containing-directory synchronization need real platform evidence. |
| [ProcessGroup](../../runtime/src/Agentic/Runtime/ProcessGroup.hs), [pre-RTS bootstrap](../../cli/cbits/control_bootstrap.c). | Manager worker ownership and supported service containment. | Preserve waitable leader ownership, private pipes, separate diagnostics, fd3 reservation before RTS startup, and no signalling through restored PIDs. |
| [CLI composition](../../cli/src/Agentic/Cli.hs), `cliMain`, `frontendCmd`, `tuiCmd`. | Compose manager configuration, administrative commands, service startup, and explicit TUI service selection. | Proposed command spelling is settled in WM-003. The manager library never imports `Agentic.Cli`, registries, DSL authoring, Pi, or concrete engines. |
| [TUI client](../../tui/src/Agentic/Tui/Client.hs), [process](../../tui/src/Agentic/Tui/Process.hs), [run model](../../tui/src/Agentic/Tui/RunModel.hs), [application](../../tui/src/Agentic/Tui/App.hs). | Add an explicit manager client backend and service-mode presentation adapters. | Today [TUI instructions](../../tui/AGENTS.md) permit only the runtime facade. A reviewed exception for `Agentic.Manager.Client` is required. It must not permit importing server state, SQL, CLI, DSL, or concrete engines. |
| Downstream `emacs/wf.el`, `emacs/wf-smoke.el`, `ci/emacs-ui.py`, `ci/emacs-tramp.py`. | Add manager HTTP/live-delivery adapters and service-mode UI tests. | Preserve ordinary Emacs modes, editors, buffers, windows, histories, and local/TRAMP operation. HTTP credentials do not enter buffers, argv, or TRAMP commands. |
| Pi owner's `ext-pi/src/index.ts`, `frontend-session.ts`, `supervisor.ts`, `reducer.ts`, and native UI components. | Add an endpoint-bound service session and transport adapter alongside explicit local operation. | Service mode uses manager resources rather than the runtime reducer. Pi user-grant gates remain in trusted extension code. Client-bound current/child engines do not become server profiles by relabelling them. |
| [Lean model](../../model/AGENTS.md), [bisimulation](../../bisim/AGENTS.md). | Add a small abstract manager history/admission model and a separate manager conformance lane. | No HTTP, SQLite, filesystem policy, or Haskell imports enter the model. Existing workflow semantics and the frozen workflow corpus remain unchanged. |

A practical initial manager subdivision is `State`, `Store`, `Profile`, `Worker`,
`Artifacts`, `Protocol`, `Http`, `Events`, and `Client`, behind the two public
facades. Split additional modules only when a concrete ownership or dependency
boundary requires it. `Client` uses public resource types and HTTP, never the
server coordinator or database. The proposed names are not a requirement to
create empty files before they have implementations.

The following work-to-source map assigns an initial editing surface. Proposed
module paths are subordinate to the boundary decisions in WM-002, and do not
require a separate module for every work package.

| Work packages | Primary editing surfaces |
|---|---|
| WM-001 through WM-003 | `agentic.cabal`, `flake.nix`, `test/source-boundaries.hs`, import fixtures, proposed `manager/AGENTS.md`, `doc/api/`, and `test/fixtures/manager/`. |
| WM-004, WM-040 | Proposed `model/Agentic/Manager/`, `bisim/manager/`, [model Lake targets](../../model/lakefile.toml), [oracle Lake targets](../../bisim/lakefile.toml), and the manager state/model comparison tests. |
| WM-005 | `cli/src/Agentic/Cli/Frontend.hs`, proposed `runtime/src/Agentic/Runtime/Frontend/Protocol.hs`, `runtime/src/Agentic/Runtime.hs`, and frontend session fixtures/probes. |
| WM-006 | `runtime/src/Agentic/Runtime/Snapshot.hs`, `Frontend.hs`, `Catalogue.hs`, the runtime facade, and runtime/query contract tests. |
| WM-007 | `runtime/src/Agentic/Runtime/PrivateRoot.hs`, relevant directory C support, and storage/export regression tests. |
| WM-008 | Proposed `manager/src/Agentic/Manager/Profile.hs`, CLI composition, and profile/capability fixtures. |
| WM-009 through WM-011 | Proposed manager `State.hs` and `Store.hs`, migrations, capture storage adapter, and pure/SQLite integration tests. |
| WM-012 through WM-016 | Proposed manager `Worker.hs` and `State.hs`, shared runtime facade consumers, and real-worker/control fixtures. |
| WM-017, WM-018 | Proposed manager `Artifacts.hs`, state/store adapters, and the existing verified runtime query/export/lineage interfaces. |
| WM-019 through WM-022 | Manager worker/state/store lifecycle, the selected service-containment support, proposed `manager/test/` and `test/manager_probe.py`. |
| WM-023 through WM-028 | Proposed manager `Protocol.hs`, `Http.hs`, `Events.hs`, authorization/store integration, CLI admin composition, and `test/manager_http_probe.py`. |
| WM-029 | Proposed `manager/src/Agentic/Manager/Client.hs`, neutral public resource types, and `test/manager_client_vectors.json`. |
| WM-030 through WM-032 | Downstream `emacs/wf.el`, a focused transport module if warranted, `wf-smoke.el`, and existing/new Emacs acceptance harnesses. |
| WM-033 through WM-035 | `tui/AGENTS.md`, TUI `Client.hs`, `Types.hs`, `Model.hs`, `RunModel.hs`, `App.hs`, local `Process.hs` dispatch, and TUI rendering/PTY tests. |
| WM-036 through WM-038 | Pi owner's `ext-pi/src/index.ts`, `config.ts`, `supervisor.ts`, a proposed `manager-client.ts`, native setup/review/run/decision components, and extension/host acceptance tests. |
| WM-039, WM-041 | Manager integration/fault harnesses and the three clients' actual acceptance drivers. |
| WM-042 through WM-044 | CLI admin composition, Nix/Cabal packaging, `doc/agent-cat.texi`, public inventories, proposed manager runbooks and release-evidence document, and client READMEs. |

## 4. Dependency order and decision gates

### 4.1 Phase order

The numbered packages are reviewable units, not a demand for exactly 44 commits.
A package may require several coherent changes, each with its owning regression
checks. Dependencies below refer to completed contracts and tested behavior,
not merely the presence of a file.

| Phase | Packages | Delivery | Scheduling constraint |
|---|---|---|---|
| P0: contracts and evidence | WM-001 through WM-004. | Baseline, dependency decisions, API/state contract, and abstract model. | Establish ownership and meaning before representation choices become difficult to change. |
| P1: shared runtime facilities | WM-005 through WM-007. | Neutral frontend codecs, snapshot/query contract, durable publication. | Preserve native behavior through existing fixtures. |
| P2: durable coordination | WM-008 through WM-011. | Trusted profiles, private DB, receipts, captures, readiness. | No network listener. |
| P3: complete supervised lifecycle | WM-012 through WM-018. | Workers, admission, approval, events, controls, results, history, lineage. | Use real deterministic frontend processes early. |
| P4: failure-safe core | WM-019 through WM-022. | Containment, recovery, retention, full direct-versus-managed acceptance. | G1 is the first complete lifecycle demonstration. |
| P5: authenticated API | WM-023 through WM-028. | Credential administration, protected HTTP, read surfaces, replay, mutation routes, adversarial tests. | G2 precedes mutation access. G3 additionally requires WM-040 and relevant capacity evidence. |
| P6: client transport and Emacs | WM-029 through WM-032. | Shared client contract and the first native service client. | Integrate against G3, not a permissive fake server. |
| P7: TUI | WM-033 through WM-035. | Brick service mode with real PTY acceptance. | Reuse the settled client contract and preserve explicit local mode. |
| P8: Pi | WM-036 through WM-038. | Trusted extension service mode with real-host acceptance. | Coordinate with its owner and preserve client-bound engine exclusions. |
| P9: cross-system evidence | WM-039 through WM-041. | Cross-client/TLS acceptance, formal/conformance bridge, capacity and fault evidence. | WM-040 starts after G1 and can run before client work. It is not deferred until P8 finishes. |
| P10: operations and release | WM-042 through WM-044. | Operator procedures, reproducible packages, rollback and independent release review. | Preparation may run in parallel, but release requires every gate. |

```text
P0 -> P1 -> P2 -> P3 -> P4/G1 -> P5/G2
                              |        |
                              +-> WM-040 + WM-041 core evidence
                                       |
                                       v
                                      G3
                                       |
                              WM-029 client contract
                                       |
                            Emacs -> TUI -> Pi
                                       |
                                    WM-039
                                       |
                 WM-041 final + P10 -> G5 release candidate
```

The arrows describe integration order. Independent contract fixtures, native UI
work, documentation, and proof work can proceed in isolated lanes once their
inputs are stable. The source-boundary, schema, worker-ownership, and transaction
changes retain a single integration owner.

### 4.2 Decisions to close before dependent work

These are implementation decisions, not permission to reopen settled security
or semantic requirements. Each decision has a recommended starting point and
an explicit deadline in the dependency graph.

| Decision | Recommended starting point | Evidence and deadline |
|---|---|---|
| D1: Haskell network stack | Evaluate WAI/Warp and the existing HTTP client stack first. Select one supported TLS termination path for the reference deployment. | WM-002 verifies pinned Nix availability, cancellation/streaming behavior, limits, licensing, and maintenance. Do not claim a package version is available without checking it. |
| D2: SQLite binding and confinement | Use a maintained SQLite binding with explicit transactions, `synchronous=FULL`, backup support, and observable errors. Use a local filesystem. | WM-002 and WM-007 test database/WAL/shared-memory opening and root replacement. If the binding cannot meet the private-storage contract, resolve that before WM-009 accepts data. Do not quietly add a custom VFS or weaken confinement. |
| D3: process containment | Reuse ProcessGroup inside an independently enforced Linux/macOS service boundary. | Investigate feasibility in WM-002, implement WM-019, and require platform-specific hard-death evidence before unattended mutation on that platform. No PID-based reconstruction. |
| D4: content retention and quotas | Keep the design's initial bounds. Retain runtime histories needed by lineage. Do not introduce remote destructive pruning. | WM-021 supplies configured global limits, refusal behavior, and conservative capture collection. WM-041 measures capacity and WM-042 records operator policy. |
| D5: richer initial-input metadata | Keep required text fields and explicit absent descriptions. | WM-003 records the existing contract. Additional descriptions or typed initial-input semantics need separate authoring work and are not on the critical path. |
| D6: deployment trust arrangement | Use HTTPS with a protected backend, per-client credentials, and an additional protected-network or mutually authenticated boundary for Internet exposure. | WM-024 tests the reference arrangement. WM-043 requires an operator-selected certificate/network/service configuration before deployment can be authorized. |
| D7: Emacs live transport | Use supported HTTP/TLS facilities and a bounded SSE consumer if available in the supported Emacs environment. | WM-030 proves incremental delivery and cleanup. If no suitable SSE facility is available, use the already specified bounded polling fallback and advertise that capability honestly. Do not write an unsafe HTTP/TLS stack to force streaming. |

## 5. Work packages

Each package states dependencies, implementation work, and a completion
contract. Source paths are existing unless explicitly described as proposed.
Tests belong with the package that introduces behavior, even where a later
package assembles the larger failure matrix.

### P0. Contracts and evidence

#### WM-001. Establish the implementation baseline and verification environment

**Dependencies:** None.

**Work:** Record the exact shared, Pi, and downstream source revisions and dirty
file digests. Agree which owner integrates the existing native frontend work
and which owner changes each client. Identify current public facades, immutable
runner packages used by tests, supported platforms, and the minimum supported
Emacs/Pi environments. Establish reproducible Nix development environments
through the permitted direnv entry points before invoking compilers.

Inspect every owning gate for embedded environment setup. Several existing
shell gates and `doc/Makefile` invoke `nix develop` internally. Resolve how to
run their exact checks under the execution policy, using an approved
application of the existing shell or a narrowly reviewed environment-native
entry point. Wrapping such a script in `direnv exec` alone does not remove its
nested invocation. Do not skip the underlying checks or install tools ad hoc.

**Complete when:** The baseline can build and run its relevant existing tests,
the environment recipe and unavailable checks are recorded, and ownership is
agreed. Any baseline failure has a diagnosis and owner before it is attributed
to manager changes. No unrelated dirty work is discarded or implicitly included
in an implementation commit.

#### WM-002. Settle package boundaries and dependency feasibility

**Dependencies:** WM-001.

**Work:** Review the proposed `manager/src` namespace, two public facades, and
single-package integration in `agentic.cabal`. Check available HTTP, TLS, and
SQLite packages in the pinned Nix environment. Use bounded technical probes for
stream cancellation, transaction failure, database confinement, and service
containment. These probes support decisions D1 through D3 and do not become an
alternative manager implementation.

Specify import rules for manager server modules, neutral resource types, and
`Agentic.Manager.Client`. Plan the exact TUI exception rather than exporting the
entire manager through `Agentic.Runtime`. Add negative import fixtures for the
new layer and its future submodules. Introduce production dependencies only
with the first code that needs them.

**Complete when:** Binding and containment choices have recorded evidence,
package/module ownership is unambiguous, and the compiler-parsed boundary gate
rejects manager-to-CLI/engine/DSL edges, runtime-to-manager edges, and
client-to-server edges. Unresolved platform feasibility blocks the relevant
release claim, not unrelated documentation or pure model work.

#### WM-003. Freeze the manager protocol and compatibility fixtures

**Dependencies:** WM-001, WM-002.

**Work:** Produce a proposed OpenAPI document, public JSON examples, SSE grammar,
resource-state tables, error catalogue, capability matrix, and scope matrix.
Place the authoritative API description under a proposed `doc/api/` area and
fixtures under `test/fixtures/manager/`. Define exact command bodies, body/header
limits, duplicate-key rejection, ETags, pagination, authority epochs, mutation
keys, and version negotiation. Include every resource in Section 7.

Freeze CLI syntax for service startup, local administration, and explicit client
endpoint selection. Never put bearer values in arguments. Specify how client
capabilities distinguish SSE and polling. Define typed resource representations
without copying raw private runtime references into network responses. Retain
separate version domains for API, snapshots, events, descriptors, sessions,
controls, manifests, and stores.

**Complete when:** Every resource has a method, authorization rule, lifecycle
precondition, bounded response shape, and refusal example. Existing native
fixtures remain unchanged. Initial inputs are required text, runtime answers
use their real code/schema, and unsupported compatibility branches refuse.
The schema and examples agree, including false, null, empty arrays, large
integer encodings, and Unicode.

#### WM-004. Define the abstract coordination model and laws

**Dependencies:** WM-003.

**Work:** Model finite histories, indexed run observations, request states,
reservations, prepared capabilities, decisions, command receipts, and verified
artifact observations. Use standard finite maps, ordered lists, and folds.
State the design's `M`, `Q`, and per-run projection meanings, including command
intent before pipe delivery. Reserved run identities without runtime envelopes
remain coordination data rather than fabricated running snapshots.

Add a small Lean development under a proposed `model/Agentic/Manager/` namespace.
Keep HTTP, SQL, paths, timestamps-as-authority, and process implementation out
of the normative model. Represent environment observations abstractly and state
the assumptions under which live capability and cleanup predicates hold.
Derive coordinator operations from their commuting equations rather than
retrofitting laws to a scheduler implementation.

Extend `model/lakefile.toml` so every new manager module belongs to the default
model build, including modules not imported by the root. Its current glob
includes only `Agentic` and `Agentic.Core.+`. A file under the new namespace
does not become checked merely because it is present on disk.

**Complete when:** Exact theorem statements cover projection composition,
coordination-state refinement, reservation exclusivity, valid approval, and
per-run decision ordering. Abstract proofs and axiom reports are available.
Any unclosed equation has a diagnosis rather than a weakened statement.
WM-040 owns the subsequent implementation/conformance bridge, not these proofs
alone. A deliberately broken, otherwise unimported manager module in an
isolated negative fixture must make the owning model build fail.

### P1. Shared runtime facilities

#### WM-005. Extract and reuse the neutral frontend transport contract

**Dependencies:** WM-003.

**Work:** Move reusable request/response data and strict transport parsing from
`Agentic.Cli.Frontend` into a neutral runtime module. Add encoders where the
manager needs to send existing preparation, lineage, start, and discard frames.
Represent and validate prepared replies and capability replies without making
stored invocation metadata authoritative. Reuse existing bounds, ID parsers,
and control codecs rather than creating a second wire dialect.

Leave `FrontendPreparation`'s executable closure, registry lookup, target
selection, environment handling, and workflow capture semantics at their
existing boundary. Keep private input/control pipes and the pre-RTS fd3
bootstrap. Preserve v1 frontend and v2 control/runtime framing exactly unless
a separately reviewed version change is necessary.

**Complete when:** The real frontend session, input-source, invocation, lineage,
and export fixtures pass before and after extraction, including threaded
`GHCRTS=-N8` execution. Literal, transport, and file sources preserve their
existing bytes. The manager can encode/decode the shared contract without
importing CLI modules or hand-assembling a rival parser.

#### WM-006. Provide the complete observation and restoration contract

**Dependencies:** WM-003, WM-005.

**Work:** Reuse `RunSnapshot`, `stepRunSnapshot`, and `runSnapshotValue` for live
observations. Define a versioned, bounded representation sufficient to restore
manager projections, including attempts, acknowledgements, decisions, results,
trace evidence, and bills. Select a validated checkpoint plus retained-envelope
suffix or another explicitly bounded representation, with a precise decoder
and refusal rules. Do not infer missing fields from compact history summaries.

Determine what the worker helper must expose for legacy observation and large
catalogues. Extend a negotiated helper operation/version only if necessary.
Keep current `frontend-io` v1 replies and their limits intact. Reuse verified
question/result and catalogue APIs, including corrupt entries. Derive editor
schemas through the existing code interpretation rather than parsing code names
in each client.

**Complete when:** Full snapshots round-trip at their advertised version, invalid
checkpoints refuse, and replay produces the same shared snapshot. A compact
history response cannot be mistaken for a complete control view. Large history
is either completely paginated through an explicit new contract or explicitly
refused, never truncated into a successful catalogue.

#### WM-007. Establish durable private publication and database confinement

**Dependencies:** WM-002, WM-003.

**Work:** Add the shared storage operation needed to publish an immutable capture
with a documented durability contract. Retain private parent descriptors,
exclusive temporary creation, no-clobber publication, bounded streaming,
file synchronization, containing-directory synchronization, and root
revalidation. Specify the outcome when publication succeeds but a later sync
or receipt fails. Do not conflate namespace atomicity with durable persistence.

Test the selected SQLite binding's actual database, WAL, and shared-memory file
behavior under private-root permissions and directory replacement. Document
what the library and filesystem guarantee and how unsafe reopening refuses.
Do not assume a retained `PrivateRoot` automatically confines a library that
opens its own pathnames. Preserve existing export behavior while sharing the
minimum appropriate primitive.

**Complete when:** Linux and macOS tests cover no-clobber races, stale temporary
files, interruption, root/parent replacement, sync errors, and lost replies.
A successful capture receipt has the claimed persistence barrier. Database
opening cannot silently cross the agreed storage boundary. Existing Store and
export consumers retain their semantics and regression coverage.

### P2. Durable coordination

#### WM-008. Implement trusted profiles and composition-root configuration

**Dependencies:** WM-002, WM-003, WM-005.

**Work:** Define local operator configuration for runner alias, executable,
ordered prefix, private roots, workspace/target policy, person-answering mode,
resource keys, quotas, and profile revision. Compose it in the CLI and pass
validated values to the manager. Public profile representations contain only
safe IDs, labels, readiness categories, and revisions.

Select a dedicated manager root, separate from locally configured legacy and
client-retention roots. Detect and refuse overlapping configured ownership or
pruning paths before workers start. Specify a root-role check for updated local
clients so that their restore/retention code refuses a manager-owned root before
enumeration or deletion. Directory separation remains necessary for older
clients that do not understand this check. A v3 manifest exemption alone does
not protect partial directories that lack a manifest.

Probe the configured executable's isolated frontend capabilities and bounded
catalogue using direct argv. Keep actual server identity separate from the
trusted invocation tuple. Recheck mutable configuration through a defined
revision/reload transaction that invalidates unapproved preparations. Construct
worker environments explicitly so that manager client/admin credentials are
not inherited. Reject client-bound Pi engines as service profiles.

**Complete when:** Unknown/revoked/stale profiles refuse without launching an
untrusted executable. Wrapper/prefix ordering is preserved, missing capabilities
refuse mutation, and capability/catalogue timeouts are bounded. Profile edits
cannot replace the environment of an approved worker. Configuration and logs
contain no accidental credential disclosure. Manager and local-retention roots
remain disjoint under the configured identity/path checks.

#### WM-009. Implement the private coordination database and service lock

**Dependencies:** WM-004, WM-007, WM-008.

**Work:** Introduce SQLite schema migrations and one writer for service metadata,
registered client identities, credentials/verifiers, requests/input bindings,
captures, reservations, preparations, runs, ingested-envelope identities,
commands, decisions, artifact/export references, and replay invalidations.
These are logical records, not a requirement for one table per noun. Use SQL
constraints for uniqueness and referential integrity where they directly
express the invariant.

Persist schema version, database authority epoch, stream identity/sequence,
and revisions separately from process generation. Set and verify WAL and
`synchronous=FULL` for every relevant connection. Acquire an exclusive local
service lock before owning roots or starting workers. Bound transactions,
readers, migration time, and checkpoint behavior. Never retain a read transaction
while waiting for a network writer.

**Complete when:** Two managers cannot concurrently own the same state, partial
migrations fail safely, and incompatible newer databases refuse older binaries.
Transaction rollback leaves no partial resource/event change. Power-loss claims
are limited to the tested filesystem/VFS contract, and a lock file or stored
PID is not treated as a worker control capability.

#### WM-010. Implement command receipts, revisions, and idempotency

**Dependencies:** WM-003, WM-009.

**Work:** Build the common mutation transaction used by local test calls and
later HTTP routes. It checks current authorized client/profile facts, authority
epoch, exact key/body/media-type/precondition binding, strong resource revision,
and lifecycle transition before recording intent and invalidations. Use
registered client identity rather than credential value as the ledger key.
Record exact request bytes for comparison or a cryptographic binding with the
same collision/security contract and bounded private retention.

Separate accepted intent, dispatch reservation, attempted delivery, runtime
acknowledgement, effect evidence, and unresolved outcome. Matching retries
return the original receipt. Conflicting keys return 409 and retired receipt
keys return 410 through permanent non-content tombstones. Never add a generic
restart-time outbox replay that reissues uncertain starts or controls.

**Complete when:** Concurrent matching POSTs cause one intent and at most one
dispatch attempt in the owning generation. Different bodies/preconditions
cannot reuse a key. Stale updates refuse while exact completed retries remain
recognizable. Credential rotation preserves deduplication, ledger quotas do not
evict replay protection, and SQL failure produces no false durable receipt.

#### WM-011. Implement drafts, immutable captures, and readiness

**Dependencies:** WM-005, WM-007, WM-008, WM-009, WM-010.

**Work:** Create durable drafts from exact workflow/profile revisions. Store
literal inputs as literals until frontend capture. Accept uploaded transport
bytes through bounded private publication, associate captures with authorized
client/profile use, and bind them to declared request inputs transactionally.
Persist supplied/missing names, validation failures, and capture references.
Reject duplicate/unknown names, invalid UTF-8, and null-as-text substitution.

Calculate readiness from complete representations, not speculative workflow
execution. Preserve declaration order when assembling frontend inputs. Use
inline transport only when the encoded frontend frame fits. Pass large captures
through server-owned immutable file references. Do not reread client paths or
duplicate prompt/newline semantics. Enforce aggregate input, draft, upload,
and unbound-capture budgets as well as per-body limits.

**Complete when:** A draft survives restart with identical submitted bytes.
Post-upload source mutation has no effect. Empty text is supplied input. Large
Unicode/escaped payloads obey both HTTP and frontend limits. Interrupted uploads
create no successful binding, and a committed binding to missing/changed bytes
refuses rather than reconstructing content.

### P3. Complete supervised lifecycle

#### WM-012. Implement the manager-owned frontend worker adapter

**Dependencies:** WM-005, WM-008, WM-009.

**Work:** Use shared ProcessGroup facilities to create a configured frontend
process with private stdin/stdout, separate bounded stderr, and the correct
working directory/environment. Keep its handles and live ownership token in
manager memory. Decode capability/prepared/runtime phases explicitly, with
frame/time limits and no PTY in the protocol path.

Provide a single serialized command writer and a lossless bounded event reader.
Network handlers never own or close these handles. Reserve the native identity
returned by preparation without inventing a runtime-start event. Clean up all
handles and the original group on startup/decoding failure, and preserve the
existing fd3 bootstrap through the CLI proxy/worker arrangement.

**Complete when:** Real deterministic workers prepare, discard, start, receive
controls, and terminate under manager ownership. Malformed/truncated/oversized
frames, stderr flooding, startup exceptions, and failed writes do not leak
processes. Closing a test observer has no effect on the worker. A restored PID
cannot be inserted into this adapter as live ownership.

#### WM-013. Implement admission and resource reservations

**Dependencies:** WM-004, WM-008, WM-009, WM-011, WM-012.

**Work:** Implement explicit enqueue, transactionally assigned queue ordinals,
and oldest-eligible selection under global/profile/resource limits. Reserve the
global slot and all trusted resource keys before preparation. Keep a queued
request's blocking reason visible. Independent resources may proceed while a
conflicting request waits. Default unclassified shared resources to serialization.

Cover preparing, review, starting, running, and cleanup with the reservation.
Editing or withdrawal removes queue position and invalidates a live preparation.
Do not reserve one resource and wait while holding it for another in a way that
creates admission deadlock. Bound draft/queue state, worker launch concurrency,
and review timers. Use monotonic timers while alive and invalidate preparations
on restart rather than reconstructing timer-based authority.

**Complete when:** Property tests establish no over-admission, no conflicting
resource ownership, and FIFO fairness among eligible conflicting requests.
Review waiting consumes capacity. Expiry never approves work, and release waits
for verified cleanup. Cancellation remains possible when the admission queue
is full.

#### WM-014. Implement exact review, approval, and start intent

**Dependencies:** WM-010, WM-011, WM-012, WM-013.

**Work:** Validate prepared identity, descriptor, captured input summaries,
program hash, public policy, person mode, target, and trusted invocation. Create
a public review plus a protected exact binding to request/profile revisions,
worker identity, process generation, and expiry. Include sufficient consent
facts without exposing raw environment or secret-bearing invocation details.

Approval checks the preparation ETag, review digest, live association, scopes,
and current profile in one state transition. Commit the approving client, start
intent, native identity, reservation, and invalidation before sending the
existing start frame to the same worker. An edit/revocation before that commit
invalidates approval. After accepted start intent, stopping work is an explicit
run cancellation, not retrospective rewriting of the approval.

**Complete when:** Lost replies return the original start receipt without a new
worker or start. Expiry, edits, worker death, restart, and changed profile each
force a new review. Fault injection on both sides of the intent/write boundary
produces an unresolved outcome where necessary, never automatic re-execution.
HTTP-style acceptance does not fabricate running or successful state.

#### WM-015. Implement validated runtime ingestion and durable projections

**Dependencies:** WM-006, WM-009, WM-012, WM-014.

**Work:** Feed unchanged validated envelopes to `stepRunSnapshot`. Identify
inputs by trusted profile/root/native run identity, sequence, and digest.
Commit deduplication identity, updated projection, decision/output observations,
and bounded manager invalidations together. Preserve runtime sequence numbers
and keep the manager's global commit order separate.

Retain enough versioned projection/checkpoint and envelope evidence for bounded
restart reconciliation. Matching duplicates do nothing. Conflicting duplicates,
sequence gaps, wrong-run events, and invalid terminal sequences become integrity
failures. Preserve authored trace completion, fresh/memo bills, attribution,
and result references without client-style inference. Keep ingestion independent
of network subscribers while treating an unavailable durable writer as storage
failure rather than permission to drop events.

**Complete when:** Direct and managed deterministic envelope histories produce
the same runtime snapshot. Checkpoint restoration and suffix replay agree with
full folding. Repaint coalescing cannot drop runtime input. Exit status or prose
cannot create a success that the validated terminal sequence does not support.

#### WM-016. Implement decisions and correlated runtime controls

**Dependencies:** WM-006, WM-010, WM-012, WM-015.

**Work:** Materialize verified person/recovery decisions from runtime evidence.
Maintain mandatory FIFO order per run and global ordering of run heads. Bind
decision revisions to occurrence/attempt generation and authoritative control
availability. Use one reservation path for both decision and run-control routes.
Decode typed values through shared runtime facilities.

Forward cancellation, person answers, retry, failover, abandon, redirect, and
both steering timings through the existing control codec with exact correlated
IDs. Track accepted, queued, delivered, stale, unsupported, failed, and unresolved
states separately. Release a decision reservation only on evidence that permits
it, not a timeout. Preserve failover correlation with `occurrence.retried`.
Do not add a generic pause or shell-command control.

**Complete when:** Two clients cannot submit two answers to one generation,
non-head decisions refuse through every route, and another run can continue.
Typed false/null/structured values arrive unchanged. Tests exercise delayed
acceptance, unsupported-after-acceptance, failure release, stale editors, and
ambiguous delivery without unauthorized replay.

#### WM-017. Implement outputs, verified artifacts, and exclusive export

**Dependencies:** WM-006, WM-007, WM-010, WM-015, WM-016.

**Work:** Expose bounded intermediate output, attempt attribution, diagnostics,
result references, and verification state as distinct resources. Assign opaque
artifact handles to trusted internal references. Fetch questions/results through
existing verification rather than raw paths. Retain verified captured bytes
before constructing a successful download, with aggregate memory/read limits.

Use `frontend-export` or its shared implementation for explicit fixed-root
no-clobber export. Strip server paths from public receipts. Record intended
name and verified output identity before publication where needed for recovery.
A lost receipt may be reconciled against expected verified bytes, but conflicting
or uncertain destinations remain unresolved and are never overwritten/deleted
to make retry succeed.

**Complete when:** Terminal success with a corrupt result displays success and
unavailable content separately. Journal damage does not prevent independently
verifying a known good artifact. Root replacement, symlink substitution, wrong
type/run/hash, concurrent exports, and lost replies cause no unverified response
or false export receipt. Sensitive content is absent from incidental logs.

#### WM-018. Implement history, lineage requests, and legacy observation

**Dependencies:** WM-006, WM-008, WM-011, WM-014, WM-015, WM-017.

**Work:** Build retained history over trusted roots with opaque manager handles,
full lineage links, verified result access, and explicit corrupt/foreign-owner
states. Keep legacy roots locally configured and read-only. Do not expose an
HTTP equivalent of arbitrary `open-root(path)` or infer ownership from history.
Preserve exact invocation matching against current trusted configuration.

Create new restart/resume/fork requests through `prepare-lineage`, carrying only
permitted parent, invocation, person mode, and typed edits. Do not accept new
workflow, input, or target overrides on that path. Preserve immutable parent
facts and post-approval revalidation. Block conflicting live/quarantined parents.
Test legacy/v2/v3 parent branches, including the current Emacs refusal when v3
invocation metadata is absent, rather than claiming universal restoration.

**Complete when:** Lineage creates distinct request/run identities and preserves
authored answers, traces, memoization, bills, and policy provenance. A stored
executable is never run as authority. Foreign live owners remain observers,
corrupt entries are visible, and bounded history is complete within its declared
contract rather than silently truncated.

### P4. Failure-safe core

#### WM-019. Implement shutdown, containment, and storage-failure supervision

**Dependencies:** WM-012, WM-013, WM-014, WM-015, WM-016.

**Work:** Implement draining shutdown, explicit cancel-with-deadline, invalidation
of unapproved preparations, and cleanup-based reservation release. Keep a
bounded safety path able to stop workers when ordinary mutation/storage queues
are saturated. If durable storage is unavailable, refuse normal operations and
do not return a committed receipt for emergency physical cleanup.

Integrate the selected Linux/macOS containment boundary around manager-owned
workers. Test parent death, nested children, ignored termination, and descendants
that leave an ordinary process group. Containment evidence must identify what
engine/process resources it can actually stop. Never claim cancellation undoes
completed provider effects. Do not signal old PIDs read from disk.

**Complete when:** Both platforms have real hard-death and clean-shutdown
acceptance for supported profiles. Unproven survivors cause resource quarantine,
not reuse. Database full/busy/failure does not block the in-memory safety path
or produce false terminal cancellation. An unsupported containment environment
cannot advertise unattended mutation support.

#### WM-020. Implement restart reconciliation and fenced backup restoration

**Dependencies:** WM-009, WM-010, WM-011, WM-014, WM-015, WM-018, WM-019.

**Work:** On ordinary restart, take the service lock, validate roots/schema,
advance process generation, invalidate preparations, and restore drafts/queue
order only after profile/capture checks. Inspect native history as evidence,
not as a way to recreate control handles. Retain unresolved start/control
outcomes and quarantine resources until actual cleanup evidence permits reuse.

Implement an offline restore procedure with the network boundary closed.
Fence old workers, restore a coherent database/capture set, rotate stream and
authority identities, revoke all restored credentials, and require local
reprovisioning and client reconciliation. Make interruption during restoration
fail closed before serving requests. Preserve the distinction between ordinary
credential rotation and restoration to older facts. Arbitrary live replacement
of database files is unsupported.

**Complete when:** Every design failure-matrix row has a tested recovery outcome.
An old mutation key refuses even with replacement credentials after restore.
No client automatically creates a new key to replay uncertain pre-restore work.
Missing terminal evidence is reported honestly, and restoring a backup never
implies that effects outside that backup did not occur.

#### WM-021. Implement quotas, retention, and bounded collection

**Dependencies:** WM-009, WM-010, WM-011, WM-015, WM-017, WM-020.

**Work:** Enforce global/client/profile budgets for drafts, uploads, captures,
worker reservations, history observations, commands, event records, snapshots,
artifact readers, and diagnostics. Implement event retention with a durable
retained-floor marker and a transactionally consistent eviction boundary.
Do not tie history or lineage retention to UI/event-cache expiry.

Retain active command receipts and the specified post-terminal interval, then
non-content key tombstones for the registered client's lifetime. Quota refusal
must occur before protection would need eviction. Collect only proven
unreferenced captures/temporary files after a grace period and root checks.
Coordinate collection with draft binding, preparation, pending commands,
exports, backup, and lineage references. There is no remote prune endpoint.

**Complete when:** Long-running load remains bounded without silent deletion of
replay protection, native evidence, or referenced captures. A full submission
queue leaves cancellation capacity. An open event reader observes either a
valid retained batch or an explicit retention loss, never a successful gap.
Collection races cannot unlink content that becomes referenced concurrently.

#### WM-022. Prove the complete non-network vertical slice

**Dependencies:** WM-013, WM-014, WM-015, WM-016, WM-017, WM-018, WM-019, WM-020, WM-021.

**Work:** Add a manager test executable and integration harness using real
configured frontend processes and deterministic scripted/ACP/deck fixtures.
Exercise selection, missing inputs, capture, enqueue, approval, simultaneous
runs, intermediate output, person/recovery decisions, controls, verified results,
history, export, and lineage without an HTTP listener.

Compare managed and direct runtime behavior under matched captured facts,
controls, policy, and deterministic engine observations. Compare authored
semantics and bills exactly. Validate physical IDs and event order without
pretending independent real runs have identical random IDs or wall clocks.
Record the explicit identity correspondence and reject semantic normalization
that would hide a changed answer, bill, policy, or lineage fact.

**Complete when:** G1 is evidenced by real workers, not mocked success replies.
The core passes restart/uncertain-delivery/cleanup tests and each lifecycle
branch has an exercised refusal. The test fixture is a runner fixture, not a
second workflow interpreter. No network exposure is needed to demonstrate the
manager's correctness boundary.

### P5. Authenticated API

#### WM-023. Implement local credential administration and authorization

**Dependencies:** WM-008, WM-009, WM-010, WM-020.

**Work:** Implement local registered-client creation, verifier-only credential
storage, expiry, rotation overlap, revocation, and profile-scoped observe,
submit, control, and export permissions. Generate at least 256 random bits for
bearer credentials using established cryptographic facilities. Use an explicit
private destination or protected interactive channel for the one-time secret,
not arguments, logs, or ordinary command transcripts.

Separate registered client identity from credential identity. Check current
authorization in the transaction accepting each intent and when returning a
retained receipt. Stream revocation/permission changes notify transport readers
without cancelling already-owned work. Local administrative access is not a
remote API scope. Bind public page/cursor state to the authorized view.

**Complete when:** Revoked/expired/scoped credentials cannot observe or mutate
forbidden resources, including cached receipts and downloads. Rotation cannot
bypass idempotency. Profile revocation fences later intents. Timing/error
handling does not expose token verifiers or resource existence to unauthenticated
callers. Worker environments contain no manager credential material.

#### WM-024. Implement the protected HTTP boundary

**Dependencies:** WM-002, WM-003, WM-007, WM-023.

**Work:** Add the selected HTTP server under CLI composition, initially with no
mutation routes. Implement HTTPS or the explicitly protected local backend
behind tested TLS termination. Validate Host and trusted proxy configuration.
Authenticate actual resource requests before exposing protected state. Apply
header, body, depth, content-type, decompression, connection, timeout, and rate
limits before large allocation or work.

Implement strict JSON decoding that rejects duplicate fields before they are
lost in an object map. Return bounded RFC 9457 problems and proper status codes.
Implement default-deny CORS with exact Origin/method/header preflight checks,
unauthenticated non-resource OPTIONS handling, exposed ETag/Location/Retry-After,
and `Vary: Origin`. Accept no cookies or query tokens. Disable unexpected
redirect/forwarded-authority behavior.

**Complete when:** The reference TLS path validates certificates and hostnames,
rejects unexpected Host/Origin, and cannot be bypassed through an exposed backend.
Preflight succeeds only for permitted policy and actual requests still require
authorization. Slow/malformed/oversized requests cannot monopolize workers or
leak private errors. There is no plaintext bearer development exception.

#### WM-025. Implement catalogue, history, snapshot, and artifact queries

**Dependencies:** WM-006, WM-008, WM-017, WM-018, WM-021, WM-024.

**Work:** Implement the read resources in Section 7 from the coordinator and
verified artifact adapter. Return separate execution/supervision/result states
and exact allowed-action revisions. Redact private paths and raw invocation
fields. Include useful workflow help and public planning information without
pretending an input-dependent exact plan exists before preparation.

Materialize each overview/detail/history page set from one consistent read
transaction. Bind tokens to client, query, revision, expiry, and bounds. Release
the transaction before network writes. The overview includes every admitted
request and active summary within advertised limits, while large detail has
explicit pages. Verify content before successful downloads and use attachment,
no-store, fixed-content-type, and nosniff headers.

**Complete when:** Query pagination neither duplicates nor silently omits state
as concurrent mutations occur. Expired page sets return 410. Scope changes
invalidate forbidden page tokens. Large views refuse explicitly at bounds,
legacy owners remain read-only, and artifact byte/path integrity tests pass
through the actual HTTP response path.

#### WM-026. Implement SSE and bounded event polling

**Dependencies:** WM-015, WM-021, WM-023, WM-024, WM-025.

**Work:** Serve committed invalidations strictly after the authorized cursor.
Every event-batch read, including an existing stream, atomically validates its
retained floor and reads the batch. Use wakeups only to request a durable-log
read, never as the sole source of events. Wrong/expired/future/view-mismatched
cursors require reconciliation. Close a stream overtaken by eviction before
emitting a later cursor.

Implement bounded UTF-8 SSE blocks, heartbeat comments, write deadlines,
subscriber limits, and polling pages from the same cursor rules. Stream IDs
persist normal restart and change on restored history, while runtime sequences
remain untouched. Ensure the tested proxy flushes events and disables harmful
buffering/caching. A slow subscriber never holds the database or worker pipe.

**Complete when:** Snapshot-to-stream attachment has no subscribe race. Partial
blocks are discarded, reconnect resumes the applied cursor, unauthorized events
are absent, and numerical gaps from filtering are not treated as corruption.
Revocation closes access. Flooding/slow-reader tests keep workers progressing
and enforce advertised bounds. G2 is complete with mutations still unavailable.

#### WM-027. Implement request, approval, control, export, and lineage routes

**Dependencies:** WM-010, WM-011, WM-014, WM-016, WM-017, WM-018, WM-020, WM-023, WM-024, WM-025, WM-026.

**Work:** Bind the remaining resources to the existing coordinator transitions,
not independent HTTP-specific state machines. Enforce the route scope matrix,
current authority epoch, exact mutation-key binding, resource-specific strong
If-Match, operation schema, lifecycle guards, and per-run FIFO. Perform strict
validation before reserving a decision or dispatch slot.

Return 201 for created drafts and 202 for accepted asynchronous intent with a
queryable command link. Do not wait for engine completion to hold an HTTP
connection open. Disconnection after commit cannot cancel the intent. Use the
same reservation/correlation path whether an action arrives from a decision
resource or the run control surface. Body fields cannot select argv, arbitrary
roots, environment, or a different stored invocation.

**Complete when:** Every mutation route has positive, unauthorized, stale,
conflicting, oversized, lost-reply, and crash-boundary tests. Same-key retries
cannot create a second effect. Cancellation acceptance is not terminal status,
and changing endpoint or registered identity does not silently replay commands.
Network mutation remains behind G3 until the required evidence is complete.

#### WM-028. Complete the HTTP/security and failure-boundary gate

**Dependencies:** WM-024, WM-025, WM-026, WM-027.

**Work:** Build adversarial tests over real TLS and HTTP, not handler functions
alone. Cover credential rotation/revocation, two-client races, preflight and
actual requests, Host/proxy bypass, authorization on pages/events/artifacts,
duplicate JSON fields, invalid numeric representations, request smuggling
relevant to the selected proxy, decompression/slow-body attacks, and redirects.

Exercise capture/intent/event/export boundaries with lost connections, worker
death, service restart, database-full, and older-backup restoration. Verify
bounded diagnostics and logs with recognizable synthetic secret/content markers.
Test malformed SSE delivery from the client side separately from trusted server
framing. Confirm that the full HTTP surface implements the frozen API schema.

**Complete when:** No security finding is left as a future cleanup item for an
enabled route. Failures produce explicit refusals or unresolved states rather
than invented success. Together with WM-019, WM-040, and applicable WM-041
capacity evidence, the result establishes G3. It still does not authorize a
public or production deployment.

### P6. Client transport and Emacs

#### WM-029. Implement the shared client contract and Haskell client facade

**Dependencies:** WM-003, WM-025, WM-026, WM-027, WM-028.

**Work:** Define endpoint-bound resource references, capability negotiation,
private credential lookup, request/receipt handling, versioned DTOs, snapshot
paging, SSE/polling parsing, and reconnect policy. Implement the Haskell portion
behind `Agentic.Manager.Client` using the existing HTTP client dependencies.
Do not generate a broad SDK or duplicate the runtime reducer.

Provide common conformance vectors usable by Haskell, Emacs, and TypeScript.
Require one in-flight refresh per resource, a dirty flag for coalesced
invalidations, and a fetch generation that discards old responses after a full
resnapshot or endpoint switch. ETags are equality tokens, not sortable counters.
Keep pending mutation bytes/key/preconditions private until resolution. Restart
with a new overview rather than trusting a cursor whose pending work was lost.

**Complete when:** Clients agree on complete/partial SSE blocks, Unicode,
duplicates, cursor expiry, stale pages, false/null/numeric values, backoff,
revocation, and out-of-order refreshes. Credentials never follow cross-origin
redirects. No API representation or import from this facade pulls server
coordination or SQL into the TUI.

#### WM-030. Add Emacs HTTP, credential, and live-delivery support

**Dependencies:** WM-029.

**Work:** In the downstream repository, add an explicit manager connection
configuration and endpoint identity. Use existing secret-storage/private-file
facilities without exposing tokens in Custom displays, buffers, histories, argv,
or process errors. Implement asynchronous REST with exact typed JSON and bounded
response handling in the declared supported Emacs versions.

Prove the chosen SSE transport's incremental delivery, TLS validation, idle
handling, cancellation, and cleanup. Use the specified polling fallback if a
safe supported SSE consumer is unavailable, and report that transport explicitly.
Keep this a transport choice over the same cursor/snapshot contract. Do not
reuse TRAMP process EOF as network subscription ownership or write a second HTTP
or TLS implementation without a demonstrated need and review.

**Complete when:** Real protected GET/POST and live observation work without
blocking editing. Partial/reordered responses, expired credentials, endpoint
switches, reconnects, and closed buffers do not leak tokens/processes or overwrite
newer state. The existing local/TRAMP transport and minimum-version claims are
separately tested rather than inferred from one newer Emacs build.

#### WM-031. Migrate the Emacs lifecycle presentation

**Dependencies:** WM-030.

**Work:** Connect existing workflow completion, setup editors, review buffers,
run views, decision editors, controls, results, history, and lineage commands to
manager resources in service mode. Show queue position/blocking reasons and the
separate runtime/supervision/verification dimensions. Preserve local drafts and
editor contents across refresh/resize. Explicit approval renders the manager's
exact review, not a fresh client-side plan.

Replace service-mode process ownership, runtime event reduction, FIFO state,
artifact file lookup, and export execution with the API adapter. Keep local-mode
implementations where they remain required. Preserve independent run windows,
follow behavior, verified downloads, and explicit mode selection. Do not silently
retarget historical references to a newly selected endpoint.

**Complete when:** Every lifecycle action works through the manager without
spawning a local frontend worker or reading manager filesystem paths. Questions
retain typed values and stale drafts refuse safely. Quitting an Emacs buffer or
process does not cancel manager-owned work. Existing local mode remains usable,
including its explicit v3 invocation compatibility behavior.

#### WM-032. Add real Emacs service-mode acceptance

**Dependencies:** WM-031.

**Work:** Extend downstream ERT, warning-free byte compilation, checkdoc, and PTY
acceptance with manager service mode. Use real key input at 40×12, 80×24, and
140×36, real deterministic workers, and protected HTTP. Cover all inputs,
review, several runs, delayed questions, retry/dispatch/failover, cancellation,
verified results, history, lineage, and export.

Resize during setup, review, answer, and control editing. Disconnect/reconnect
transport and restart Emacs while the service continues. Test independent window
following and terminal restoration. Keep existing local/TRAMP acceptance as a
separate gate. Clean fixture credentials, private homes, listeners, and children.

**Complete when:** Evidence comes from actual keys, buffers, windows, and
manager/runtime observations rather than calling interactive functions directly.
The selected SSE or polling path is named. Tests fail against a deliberately
broken service-mode interaction, and do not claim cross-machine acceptance
until WM-039 supplies it.

### P7. TUI

#### WM-033. Add the TUI's explicit manager transport backend

**Dependencies:** WM-002, WM-029, WM-032.

**Work:** Add explicit service selection through CLI composition and
`Agentic.Manager.Client`. Update `tui/AGENTS.md` and compiler-parsed import
fixtures for that narrow public facade. Preserve existing configured-executable
local mode and do not expose the manager server library or database to Brick.

Represent local versus service resources explicitly in client state, including
endpoint identity and capability/refusal information. Make connection lifetime
independent of owned service runs. Reuse the Haskell client refresh and command
contracts. Keep terminal events/drawing in Brick and server state authoritative.

**Complete when:** Service mode builds with only the permitted facade dependency,
never starts a local machine/frontend process, and never opens manager files.
Selecting another endpoint cannot acquire or retarget old references. Failed
authentication or unsupported API versions fail clearly without falling back
to an unapproved local launch.

#### WM-034. Migrate TUI setup, run views, and controls

**Dependencies:** WM-033.

**Work:** Connect catalogue, missing-input setup, captures, queue display,
prepared review, concurrent run views, decisions, controls, outputs, history,
lineage, and export to manager resources. Reuse existing presentation models,
keyboard navigation, output selection, syntax highlighting, and terminal-safe
rendering. Remove service-mode staging, leases, native control ownership, and
runtime folding from that path.

Display stale/disconnected state without inventing cancellation or clearing
pending decisions. Preserve edits and focus across live updates. Fetch verified
content through opaque handles. Keep compulsory decision ordering and command
status in the manager, while the TUI retains selection and presentation state.

**Complete when:** Every service action is keyboard reachable and uses the same
review/decision revision rules as Emacs. Active attempts and pending decisions
can coexist visibly. An accepted cancellation is not rendered as finished work.
Local-mode behavior remains intact without a duplicated service runtime model.

#### WM-035. Add TUI service-mode rendering and PTY acceptance

**Dependencies:** WM-034.

**Work:** Extend pure presentation tests, fixed-size render expectations, and
real PTY scenarios at the three specified terminal sizes. Use the actual
manager and deterministic frontend workers for setup, review, outputs,
question/recovery controls, cancellation, verified artifacts, and history.
Keep local process ownership/terminal restoration tests.

Exercise a slow event stream, expired snapshot pages, API restart, stale answer,
credential revocation, and endpoint switching while drafts remain open. Include
terminal control-sequence payloads in untrusted output and diagnostics. Assert
no child process is owned by the TUI for service runs.

**Complete when:** The tests observe keyboard-driven service behavior and
terminal restoration, not only snapshots of desired state. Closing the TUI
leaves service work intact. Formatting and compiler boundary checks pass, and
removing the new transport handling makes at least one behavioral regression
check fail.

### P8. Pi

#### WM-036. Add the Pi manager session and transport adapter

**Dependencies:** WM-029, WM-035.

**Work:** Coordinate with the Pi source owner before editing its branch. Add an
endpoint-bound manager session using the frozen API DTOs and shared client
conformance vectors. Keep bearer retrieval inside trusted extension code,
outside tool arguments and model-visible data. Separate service resources from
`OwnedRun` and restored local observers rather than giving a remote ID a fake
local process owner.

Negotiate server profiles and advertise only independently supervised targets.
Keep current-session and client-owned-child engines in explicit local mode.
Do not reuse their bridge sockets or lifecycle as a manager UI connection.
Implement real HTTP/SSE cancellation, bounded polling fallback, refresh
serialization, and command reconciliation in the supported host environment.

Keep service resources out of local restoration and pruning indexes. Inspect
`config.ts`, session-start restoration in `index.ts`, and
`RunSupervisor.restore` in `supervisor.ts`, including deletion of aged
directories without manifests. Service startup must not run that retention path
against manager storage. Explicit local mode checks the configured root role
before pruning, while older clients remain isolated through WM-008's distinct
root configuration.

**Complete when:** Remote observation does not instantiate a local runtime
reducer or filesystem monitor. Closing/reloading the extension closes its
transport but does not cancel service work. Endpoint changes, revocation,
unsupported profiles, and stale DTO versions fail without retargeting stored
invocation tuples or exposing secrets.

#### WM-037. Migrate Pi native UI and tool-mediated controls

**Dependencies:** WM-036.

**Work:** Wire native catalogue/setup/review components, run browser, output
views, person/recovery editors, history, lineage, and export to service resources.
Retain Pi user-grant, project-trust, and tool-authorization checks for every
model-initiated mutation. The server independently checks scopes, revisions,
exact approval, and FIFO rather than accepting a forgeable grant field.

Keep the UI's local drafts, modal ownership, focus, and labels native to Pi.
Expose request admission and command receipts separately from execution.
Do not rewrite existing local invocation records or remove local control paths
needed by host-bound engines. No shared browser-style renderer is introduced.

**Complete when:** Human and model tool paths reach the same manager transition
only after their respective trusted-client checks. Stale decisions and grant
reuse cannot issue controls. Service-mode inputs, exact review, typed answers,
verified output, and lineage behave consistently with the other clients.

#### WM-038. Add Pi real-host service-mode acceptance

**Dependencies:** WM-037.

**Work:** Extend the existing TypeScript check, unit, integration, and actual host
UI harnesses against a freshly built manager and compatible runner. Exercise
native selection, input capture, approval, several runs, decision/control
interaction, reconnect, results/history, lineage, and export. Include extension
shutdown/reload and API credential changes.

Test denial/consumption of model mutation grants separately from ordinary human
UI operation. Verify current/child engine targets remain local and are not
mistaken for service capabilities. Use a private test host configuration and
deterministic backends rather than activating the extension in production.

Create distinct local and manager fixture roots, including old completed
records, protected lineage parents, and manager partial directories without
manifests. Run local startup and retention and verify that no manager entry is
removed or changed. A misconfigured manager root must refuse before pruning.
Do not interpret the current v3 record exemption as proof of this root-level
exclusion.

**Complete when:** Actual host interaction and server evidence corroborate the
unit/integration results. Existing local tests pass. The report names the tested
host/package versions and distinguishes source acceptance from installation,
production adoption, or deployment.

### P9. Cross-system evidence

#### WM-039. Prove cross-client and cross-machine operation

**Dependencies:** WM-020, WM-028, WM-032, WM-035, WM-038.

**Work:** Run the Section 8 acceptance matrix with at least two authenticated
clients on a real second machine over certificate-validated TLS. Create in one
client, approve or answer in another, observe concurrently in a third, disconnect
all presentations, reconnect, and verify outputs/history/lineage. Use distinct
client credentials and exercise authorization differences.

Race answers and controls, rotate/revoke credentials, expire page/event state,
restart the manager with prepared and active work, and perform controlled
older-backup restoration. Preserve unsubmitted client drafts but refuse stale
submissions. Exercise both SSE and the bounded polling path, and test the actual
proxy idle/buffering behavior of the reference deployment.

**Complete when:** Client/server/runner identities, timestamps, and correlated
operation IDs demonstrate the behavior without leaking content or credentials.
Loopback HTTP, SSH/TRAMP, and independent single-client tests are not substituted
for cross-machine evidence. Fixture resources are cleaned up and no production
configuration is changed.

#### WM-040. Complete the formal-to-implementation conformance bridge

**Dependencies:** WM-004, WM-009, WM-010, WM-013, WM-014, WM-015, WM-016, WM-020, WM-022.

**Work:** Connect the abstract coordination model to the implemented pure state
transition and logical database-row representation. Establish the design's
projection/refinement equations at the specified representation boundary.
Compare generated valid histories and refused transitions through an independent
model/oracle lane, with a pinned input/output encoding and retained failures.

Keep this manager conformance lane separate from the frozen workflow corpus.
Do not claim a generic fold lemma proves the HTTP server, SQLite commit, process
containment, or physical engine effects. Report exact Lean theorem statements,
axiom footprints, representation assumptions, and concrete Haskell/model
comparison results. Retain direct-versus-managed runtime equivalence evidence
for answers, traces, bills, policy, and lineage.

Wire the separate manager oracle/library into explicit targets in
`bisim/lakefile.toml` and the manager conformance gate. Record source directories,
entry modules, and the exact build/run commands. Preserve a cheap import closure
that does not pull in `Agentic.Core.DslFlagship` or the whole model root.
Existing workflow oracle targets and their corpus remain unchanged.

**Complete when:** Model proofs and implementation comparison both pass, the
logical storage square closes without weakening its statement, and the tested
physical boundaries are explicitly outside the proof claim. This package may
start immediately after G1 and must finish before G3 is declared. Deliberately
breaking a manager oracle or model fixture must fail its named gate, so a green
legacy workflow build cannot conceal an unchecked manager development.

#### WM-041. Complete capacity, security, and fault-injection evidence

**Dependencies:** WM-019, WM-020, WM-021, WM-026, WM-028.

**Work:** Measure the design's default and maximum reservations, queued drafts,
upload sizes, aggregate captures, artifact readers, event flood rates, slow
subscribers, page-set memory, command-ledger growth, and SQLite checkpoints.
Publish the test workload and accepted memory/latency ceilings before measuring.
Use deterministic workers to isolate manager overhead from provider latency.

Inject database disk-full/busy/I/O errors, root changes, pipe failures, worker
crashes, manager hard death, partial frames, backup interruption, credential
changes, and delayed client refreshes. Add randomized schedule tests after the
deterministic boundary tests, retaining seeds. Repeat client-sensitive cases
with the integrated clients before G5. Core bound/safety evidence is required
before G3 even though the final matrix can finish later.

**Complete when:** No advertised resource bound is untested, saturated ordinary
traffic leaves the defined safety path usable, and slow clients do not impede
independent workers. No unresolved high-impact security/ownership finding is
hidden behind a passing throughput result. Claims name tested platforms and
workloads rather than extrapolating unmeasured capacity.

### P10. Operations and release

#### WM-042. Provide operator controls, observability, and recovery procedures

**Dependencies:** WM-008, WM-020, WM-021, WM-023, WM-026, WM-028.

**Work:** Finish local administration for profile validation/reload, client
provisioning/rotation/revocation, drain/cancel shutdown, backup/restore, and
quarantine inspection/release. A quarantine release requires current cleanup
evidence and an explicit local operator action, not a stale owner file or an
acknowledgement that substitutes for evidence. Keep destructive or trust-changing
operations outside the network API.

Expose bounded structured health/operational metrics for queue age, reservations,
worker ingestion, unresolved commands, cleanup, verification, subscribers,
retention misses, storage quotas, and DB/checkpoint latency. Protect diagnostic
resources and distinguish readiness from liveness. Write procedures for expired
credentials, lost replies, disk pressure, corrupt stores, proxy failures, and
restoring an older backup. Prefer a drained/offline backup procedure first.

**Complete when:** Another operator can execute the procedures in fixtures using
only documented interfaces. No log contains synthetic secret/content markers.
Health does not report a lost supervisor as merely a disconnected subscriber,
and backup/restore has an exercised failure path rather than a filesystem-copy
recipe that ignores WAL or unresolved effects.

#### WM-043. Build reproducible packages and prove rollback

**Dependencies:** WM-039, WM-040, WM-041, WM-042.

**Work:** Package the manager and required shared/client changes through the
project's Nix/Cabal and downstream release mechanisms. Test Linux and macOS
service startup, containment, protected sockets, permissions, certificate handling,
and defaults. Provide reference service/proxy configuration as documentation or
package assets without installing it automatically. Record the exact source and
artifact identities used by acceptance.

Test upgrades from each supported manager schema fixture and refusal of unknown
newer schemas. Test rollback by stopping admissions, draining/cancelling work,
retaining read-only manager history, and selecting explicit local client mode.
Restore compatible backups only through WM-020. Do not transfer live workers,
rewrite native manifests, retarget stored invocation records, or silently open
newer databases with older binaries.

**Complete when:** A clean supported environment reproduces the artifacts and
runs the relevant acceptance. Binary rollback, data compatibility, and operator
recovery are distinguished. Defaults do not expose an unprotected listener or
provision a reusable shared token. Installation/activation remains a separate,
explicitly authorized operation.

#### WM-044. Complete documentation, independent review, and release handoff

**Dependencies:** WM-001 through WM-043.

**Work:** Update the Texinfo manual, public Haskell/member/CLI inventories,
manager operating guide, API schema, client documentation, and compatibility
matrix to describe implemented behavior. Preserve this plan and the approved
design as dated records. Assemble a requirement-by-requirement release evidence
matrix linking tests, theorem/axiom reports, platform/remote runs, and exact
artifact/source identities.

Run independent architecture/correctness and security/failure reviews against the
integrated candidate. Review test quality as well as test totals. Resolve all
release-blocking findings and rerun their owning checks. Record accepted limits
without changing the meaning of G3, G4, or G5. Review the final diff for unrelated
work and secrets before any separately requested commit or publication.

**Complete when:** Every requirement in Section 12 has fresh, appropriate
evidence and every enabled capability has passed its gate. There are no
placeholder handlers, mock production paths, disabled checks, unaudited schema
changes, or unrecorded platform gaps. The handoff states that a release candidate
is ready, not that an operator has deployed it.

## 6. State, transaction, and side-effect contracts

The coordination transaction is the principal integration boundary. HTTP
handlers, timers, worker readers, and local administration feed the same checked
transitions. The writer commits state and outgoing invalidations together.
External work follows that commit only where the operation's contract permits
it. An ordinary message-queue pattern that blindly replays every unsent record
would violate exact approval and uncertain-effect handling.

| Operation | Durable transaction | Work outside the transaction | Failure interpretation |
|---|---|---|---|
| Publish a capture | Record published identity, digest/size, scope, and reference after durable private publication. | Bound/validate bytes, write and sync the immutable capture, then commit metadata. | Published file without metadata is unreferenced. Metadata with missing/changed content refuses. No reread of a client source. |
| Enqueue/admit | Assign queue ordinal and atomically reserve all required resources for one request revision. | Launch the configured frontend after reservation. | Failed launch requires cleanup before release. No partial-resource deadlock. |
| Accept a prepared worker | Bind exact validated review, worker/native identity, request/profile revisions, expiry, and process generation. | Keep the prepared worker and its private pipes alive. | A durable record is not sufficient to reconstruct a live preparation after restart. |
| Approve/start | Recheck authorization and preparation, consume approval, reserve dispatch, record native identity/start intent and event. | Send one existing start frame to that same live worker. | An uncertain boundary remains unresolved. No automatic replay after lost supervision. |
| Submit a decision/control | Recheck scope/revision/FIFO, bind command and reservation, and commit receipt/event. | Send through the one live command writer and correlate runtime evidence. | Timeout does not release a possibly delivered answer. All routes use this transaction. |
| Ingest runtime evidence | Validate identity/sequence/digest and commit projection, derived records, and invalidations. | Read worker frames independently of network writers. | Conflicting duplicate/gap is an integrity failure. Storage failure invokes safety supervision, not event dropping. |
| Publish an export | Record operation identity, intended exclusive destination, and expected verified output, then receipt/event when justified. | Verify captured bytes and call the confined no-clobber export operation. | Lost receipt can leave a complete file. Reconcile or report conflict/uncertainty, never overwrite. |
| Revoke/reload | Update credential/profile authority and invalidate affected unapproved preparations/page views. | Close affected streams and discard invalidated workers through owned cleanup. | Intents committed before revocation are not retroactively erased. Later intents refuse. |
| Evict replay history | Update retained floor and remove evicted event rows together. | Disconnect readers overtaken by retention before a later cursor is emitted. | Every batch checks the same committed floor. A new snapshot is required after loss. |
| Restore a backup | Offline replacement commits new authority/stream identities and revoked credentials before service readiness. | Fence old workers, validate capture/store sets, and reprovision locally. | Lost interval effects remain potentially executed. Old keys and approvals cannot cross the new authority boundary. |

The logical schema must distinguish at least the following identities:

- Registered client identity survives normal credential rotation. Individual
  credentials have separate IDs, verifiers, expiry, and revocation state.
- Database authority epoch fences mutation history after restoration. Stream
  identity fences replay history. Process generation fences live preparations.
- Manager run handle identifies a public resource. Its trusted internal
  profile/root/native-run tuple identifies runtime evidence without renaming it.
- Runtime sequence and manager commit sequence are independent. JSON encodes
  sequences without JavaScript-number precision loss.
- Resource revision identifies a representation/precondition. Decision generation
  additionally binds the runtime occurrence/attempt. Neither replaces a live
  supervisor capability.

Schema migrations preserve these distinctions. Restore tests include an older
backup containing credentials revoked after its snapshot. The restore procedure
must invalidate those restored credentials too, including observe-only access.

## 7. API coverage and authorization ledger

WM-003 supplies exact schemas and WM-024 through WM-027 implement them. The
following ledger prevents catalogue/help, history, uploads, and administrative
work from being omitted while launch/control routes receive attention. All
paths are beneath `/v1` and are proposed until their implementation gate passes.

| Resource family | Work package | Authorization and important acceptance |
|---|---|---|
| GET `/capabilities`, `/profiles` | WM-008, WM-023, WM-025. | Authenticate. Reveal only the client's permitted public view, versions, limits, authority epoch, and supported transports. |
| GET `/workflows`, `/workflows/{id}` | WM-003, WM-008, WM-025. | Profile-authorized catalogue/help/result code and required textual inputs. No secret configuration or fake exact pre-input plan. |
| GET/POST `/requests` | WM-011, WM-025, WM-027. | Observe for reads, submit for creation. Creation records a draft without workflow execution. Bound drafts as well as queued work. |
| GET/POST `/requests/{id}` | WM-011, WM-013, WM-025, WM-027. | Scope, exact key, current ETag, and state guard for input edits/enqueue/withdraw. Queued/prepared edits invalidate the old admission/review. |
| POST `/captures` | WM-007, WM-011, WM-027. | Submit scope for the selected profile. Bound UTF-8 raw bytes, aggregate storage, ownership/binding, and incomplete upload cleanup. No pathname or URL source. |
| GET/POST `/preparations/{id}` | WM-014, WM-025, WM-027. | Observe for review and submit plus control for approval. Current ETag/digest/live worker are mandatory. Discard requires the specified mutation authority. |
| GET `/runs`, `/runs/{id}`, `/runs/{id}/snapshot` | WM-015, WM-018, WM-025. | Observe scope, endpoint-bound IDs, full bounded state, consistent pages, and explicit legacy/corrupt/foreign-owner limits. |
| GET/POST `/runs/{id}/control` | WM-016, WM-025, WM-027. | Observe for allowed controls and control scope plus genuine ownership for commands. Exact resource ETag and occurrence/attempt where required. |
| GET `/decisions`, GET/POST `/decisions/{id}` | WM-016, WM-025, WM-027. | Verified authorized question, exact typed answer, current generation/ETag, and the same per-run FIFO reservation as control routes. |
| GET `/commands/{id}` | WM-010, WM-025. | Current authorized access to the command's profile and operation. A known command ID never bypasses revocation or reveals a private request body. |
| GET `/runs/{id}/outputs`, `/artifacts/{id}` | WM-017, WM-025. | Observe scope and verified trusted references. Output/diagnostics/result remain separate. Content is verified before successful response. |
| POST `/runs/{id}/exports`, GET `/exports/{id}` | WM-017, WM-025, WM-027. | Export authority plus the required content access, exact request key and source revision, confined name, verified receipt/download, and no overwrite. |
| POST `/runs/{id}/lineage-requests` | WM-018, WM-027. | Parent access and submit authority, current parent eligibility/revision, exact trusted invocation and typed edits. New preparation still requires approval. |
| GET `/snapshot`, `/events` | WM-025, WM-026. | Authorized consistent boundary, view-bound cursors/page tokens, SSE or bounded JSON, explicit retention loss and revocation. |
| OPTIONS preflight | WM-024. | Bounded policy-only check without bearer credentials. It accesses no protected resource and authorizes no actual operation. |
| Local administration | WM-023, WM-042. | No network admin scope. Provisioning, root/profile trust, restoration, and quarantine decisions use a protected local channel. |

For collection POSTs such as exports and lineage, WM-003 specifies the exact
same-URI precondition representation where the operation relies on an existing
resource revision. Do not borrow an ETag from a different URI. If a collection
needs GET to supply that revision, add that method explicitly to the contract
and conformance fixtures before implementing the mutation. This resolves a
schema detail left by the design's representative resource table without
weakening its strong-precondition rule.

## 8. Acceptance scenarios and regression matrix

Each scenario has a deterministic fixture and an explicit observation. The
first responsible package adds the test. Later packages run it through HTTP
and actual clients where indicated. These are future tests, not results obtained
while writing this plan.

| ID | Scenario and expected observation | Initial owner and integration gate |
|---|---|---|
| A01 | Create a request with several missing inputs. Empty text is present, null-as-text refuses, duplicate/unknown names refuse, and readiness creates no engine work. | WM-011, then WM-027 and all client gates. |
| A02 | Upload Unicode/CRLF/trailing-LF bytes, mutate the original file, and prepare. Captured digest and resulting semantic input remain exact. Exercise inline JSON expansion and the server-owned large-file path. | WM-005, WM-011, WM-022, then WM-028. |
| A03 | Enqueue competing shared/independent profiles at maximum reservations. Confirm FIFO eligibility, no partial-resource deadlock, review occupancy, and cleanup-based release. | WM-013, WM-019, WM-041. |
| A04 | Edit/expire/revoke a preparation or kill its worker before approval. An old digest/ETag cannot start a replacement worker. Restart requires a new review. | WM-014, WM-020, then WM-028. |
| A05 | Commit start intent and lose the HTTP reply or kill the manager around pipe delivery. Exact retries return the same receipt and no second start is attempted. Ambiguity remains explicit. | WM-010, WM-014, WM-020, WM-028. |
| A06 | Run two workflows with active attempts and mandatory decisions simultaneously. Show both dimensions, choose another run, and reject a non-head answer through every endpoint. | WM-015, WM-016, WM-027, WM-039. |
| A07 | Race two clients answering the same generation with false/null/structured data. One reservation wins, typed bytes remain correct, stale/unsupported/failed delivery is distinguished, and timeout does not allow a second answer. | WM-016, WM-028, WM-039. |
| A08 | Exercise retry, failover, abandon, redirect, both steering timings, and cancellation. Exact control IDs and occurrence/attempt effects correlate, including `occurrence.retried`. | WM-016, all native UI gates. |
| A09 | Close all network clients during active work and outstanding decisions. Work remains owned, decisions remain pending, and another authorized client can reconnect. | WM-012, WM-026, WM-039. |
| A10 | Send duplicate/gapped/wrong-run/conflicting envelopes and terminal events without valid authored trace. Preserve valid state and refuse invalid transitions without manufactured success. | WM-006, WM-015, WM-022, WM-040. |
| A11 | Report runtime success but remove/corrupt its result. Show terminal status separately from unavailable content. Verify a known good artifact despite journal corruption. | WM-017, WM-025, WM-028. |
| A12 | Replace state/export roots and race identical export names. At most one complete exclusive publication wins, existing bytes remain unchanged, and lost receipts never cause overwrite. | WM-007, WM-017, WM-028. |
| A13 | Restart/resume/fork legacy/v2/v3 parents with typed drop/replacement edits. Preserve parent facts and refuse invocation mismatch, live ownership, or quarantined resources. | WM-018, WM-020, WM-022, WM-040. |
| A14 | Attach SSE at a snapshot boundary while commits occur. Reconnect after a partial block, evict unseen events during an open stream, and expire detail pages. Apply complete events or resnapshot without gaps. | WM-025, WM-026, WM-028, WM-039. |
| A15 | Delay GET responses and resnapshot/switch endpoints while they are pending. Old responses/page sets cannot overwrite a newer fetch generation. Opaque ETags are never numerically sorted. | WM-029, WM-030, WM-033, WM-036. |
| A16 | Revoke/rotate credentials during POST, artifact download, pagination, and SSE. Preserve registered-client idempotency across rotation, revoke ongoing access, and fence later intents. | WM-023, WM-028, WM-039. |
| A17 | Restore an older backup after accepted operations and revocations. Old credentials, cursors, and authority keys fail. No unresolved old operation is reissued under a new key automatically. | WM-020, WM-028, WM-039. |
| A18 | Send allowed/forbidden CORS preflights, missing/forged Origin, unexpected Host, bypassed proxy headers, and redirects. Policy-only preflight reveals no resource, and actual access remains authenticated. | WM-024, WM-028. |
| A19 | Saturate uploads/drafts/event streams/page sets/commands and fill the DB disk. Refuse normal work honestly, keep bounded safety supervision available, and never acknowledge an uncommitted cancellation. | WM-019, WM-021, WM-028, WM-041. |
| A20 | Kill manager/worker/group leader and exercise escaped descendants on Linux and macOS. Prove containment or quarantine affected resources, never signal a recycled stored PID. | WM-019, WM-020, WM-041, WM-043. |
| A21 | Inject synthetic tokens, prompts, answers, provider diagnostics, HTML, and terminal escapes into failure paths. Incidental logs/URLs/argv remain clean and displays remain safe. | WM-008, WM-017, WM-023, WM-028, native UI gates. |
| A22 | Perform real keyboard interaction at three terminal sizes, preserving setup/review/answer/control drafts across resize and reconnect. Terminal/windows/focus are restored. | WM-032, WM-035, WM-038. |
| A23 | Create in one client, approve/answer in another, observe in a third across a real machine boundary, then disconnect/reconnect and verify lineage/results. | WM-039. |
| A24 | Upgrade and roll back a manager candidate with pending and completed work. Preserve compatible read-only history, reject incompatible DB versions, and retain explicit local client mode without live ownership transfer. Run local startup/pruning against distinct fixture roots and prove that manager records, lineage parents, and partial directories remain untouched. | WM-008, WM-020, WM-038, WM-042, WM-043. |

Crash injection covers before and after every durable boundary, not just a
single process kill in a convenient idle state. Use explicit barriers around
capture sync/publication, metadata commit, reservation, prepared response,
start/control intent commit, dispatch marker, pipe write, runtime acknowledgement,
ingestion commit, terminal artifact, export publication, and HTTP reply. Avoid
sleep-based race tests when a deterministic synchronization point is available.

For semantic equivalence, pin program/input facts, inherited answers, target
policy, person mode, control schedule, deterministic engine observations, runner
identity, and protocol versions. Compare answers, authored traces, result
code/value, fresh and memo bills, routing/policy fingerprints, and semantic
lineage exactly. State any physical-ID correspondence separately. Do not strip
fields until two disagreeing runs appear equivalent.

## 9. Verification layout and command policy

### 9.1 Planned test ownership

Use existing test tools before adding frameworks. Haskell already has
QuickCheck and exit-code test suites. Python's existing process/PTY harnesses
supply cross-process testing. Pi already uses TypeScript and Vitest. Emacs
already has ERT, compiler/checkdoc checks, and keyboard-driven terminal harnesses.

| Planned artifact | Purpose |
|---|---|
| `manager/test/Main.hs` and Cabal `manager-contract-test` | Pure transitions, logical row mapping, protocol decoding, admission, revisions, and properties. Split test modules when the suite needs it. |
| `test/fixtures/manager/` | Versioned API, SSE, snapshot, error, compatibility, and race-history vectors. Keep separate from the frozen workflow corpus. |
| `test/manager_probe.py` | Real non-network manager/worker lifecycle and deterministic crash boundaries. |
| `test/manager_http_probe.py` | Real TLS/HTTP, scope, replay, resource, and failure tests. |
| `test/manager_client_vectors.json` | Cross-language transport/reconciliation expectations, with a single canonical copy in the package source. |
| `manager/ci/manager.sh` | Environment-native deterministic manager gate, using configured/private artifacts and no paid providers. Its final CLI is frozen during WM-003. |
| `bisim/manager/` | Separate manager model/oracle comparison and retained counterexamples without altering the workflow corpus. |
| Existing `tui/test`, `test/tui_probe.py` | Service presentation and PTY scenarios alongside local mode. |
| Downstream `emacs/wf-smoke.el`, `ci/emacs-ui.py` and a focused HTTP harness if needed | Service HTTP/live-delivery and actual Emacs UI acceptance, with existing local/TRAMP checks retained. |
| Pi `ext-pi/test` and its actual host UI harness | Service transport, grants, integration, and UI acceptance without production activation. |
| `doc/manager-release-evidence.md` | Future requirement/evidence matrix, exact platform/package provenance, unavailable checks, and release limitations. |

These paths are proposed deliverables. No test count, command, or module listed
here is evidence that it already exists or has passed.

### 9.2 Existing gates to retain

| Changed layer | Owning checks |
|---|---|
| Shared frontend/runtime/storage/control | Cabal runtime and engine tests, `cli/ci/policies.sh`, `test/frontend_session_probe.py`, `test/frontend_io_probe.py`, `test/frontend_export_probe.py`, and the existing control/person/lineage/progress probes used by those gates. Preserve threaded framing coverage. |
| CLI/profile composition | `cli/ci/examples.sh`, `cli/ci/routing-config.sh`, deterministic `engine/acp/ci/acp.sh` and `engine/agent-deck/ci/deck.sh`, plus source-boundary checks. |
| Model and workflow semantic preservation | The default model build explicitly includes every manager module through WM-004. The separate manager oracle/conformance target is wired by WM-040 and exercised by the manager gate, with negative build-coverage fixtures. Retain `bisim/ci/tier0.sh` and `bisim/ci/tier1.sh` with their compatible prebuilt workflow oracle. A missing oracle is not a pass. Never run two full Lean builds concurrently. |
| TUI | Cabal `tui-model-test`, compiler-parsed import fixtures, `tui/ci/tui.sh`, rendering and PTY acceptance. |
| Emacs | Downstream `ci/emacs.sh`, actual `ci/emacs-ui.py`, local `ci/emacs-tramp.py`, and new service-mode checks with explicit compatible runner fixtures. |
| Pi | `npm run check`, `npm test`, `npm run test:integration`, and actual host UI checks in the owner-selected checkout. |
| Documentation/API | `make -C doc check`, `make -C doc check-haskell`, public API/member inventories, OpenAPI/example validation, and local-link/prose checks. |

Execution uses the environments and command recipes established in WM-001.
The table identifies gate ownership rather than authorizing their embedded
`nix develop` commands in this session. Environment-native manager commands may
use `direnv exec . cabal build all` and `direnv exec . cabal test
manager-contract-test` only after those components and the correct shell exist.
Do not execute the paid `engine/acp/ci/route-live.sh` as a deterministic gate.

Start with the changed unit and its negative regression, then run the owning
integration gate, then broader suites when shared semantics/boundaries change.
The release candidate runs the complete relevant matrix once on the integrated
source. A previous native package's successful tests do not verify a changed
manager or HTTP client. Report unavailable, failed, timed-out, and conditional
checks explicitly.

### 9.3 Evidence required per implementation package

A package closes with its changed paths, precise behavior, positive/negative
checks, command output, source/runner versions, and residual risks recorded in
its tracker issue. A behavioral regression must fail without the relevant fix
or be supported by an equally concrete injected-failure observation. Passing a
mock that reproduces the intended state machine is not equivalent to exercising
the real worker, TLS path, or native UI.

At release, retain sanitized evidence under an operator-selected private
artifact root. Logs never contain credentials, captured prompts, answers, or
raw provider content. Record theorem statements with their axiom footprints,
not only that `lake build` returned zero. Record immutable package/source
identity separately from installation and activation.

## 10. Work allocation and integration discipline

The highest-risk work is the shared contract, durable effect boundary, process
containment, and restoration fence. Assign an integration owner with authority
to stop downstream work when those contracts are incomplete. Do not maximize
parallel writers at the expense of a stable protocol.

| Lane | Suitable work | Shared-state restriction |
|---|---|---|
| Model and conformance | WM-004, then WM-040. | Separate model/manager-conformance paths. Coordinate the one-full-Lean-build constraint. No changes to frozen workflow meaning/corpus. |
| Shared runtime | WM-005 through WM-007, supported by the source owner. | One writer for frontend/runtime facades, compatibility fixtures, and private storage. |
| Manager core | WM-008 through WM-022. | One coordinator for schema, transactions, worker ownership, and state transitions. Separate test-only work after interfaces stabilize. |
| Network/security | WM-023 through WM-028. | Authentication and mutating routes share the coordinator's transaction contract. No parallel competing mutation implementation. |
| Client adapters | WM-029 through WM-038. | Separate repositories/worktrees and client files. Integrate Emacs, TUI, then Pi against the same accepted server contract. |
| Operational evidence | WM-041 through WM-044 and documentation preparation. | Use isolated fixture roots/ports and coordinate package/schema changes with the integration owner. |

Within a lane, split work by a stable contract, not by arbitrary file count.
Read-only review and fixture design can run concurrently. Writers use isolated
namespaces or worktrees and do not edit the same schema/facade together. The
integrator alone stages/commits when separately authorized. Baseline work in
the shared and Pi worktrees is reconciled through its owners, not reset away.

Relative effort is largest in WM-007, WM-019, WM-020, WM-028, WM-039, and WM-040.
Binding behavior, OS containment, cross-machine acceptance, and proof refinement
are uncertainty drivers. Do not attach a calendar promise to the 44-package
count. After WM-002, estimate each package from its established platform/API
constraints and available owner capacity. Re-estimate after G1 and G3 rather
than disguising unknowns as precise dates.

The first implementation batch should close WM-001 through WM-003 and begin
WM-004 through WM-007. It should not begin by building a network launch endpoint
or migrating every client in parallel. The first complete user-visible batch
is the isolated lifecycle at G1, followed by protected observation at G2 and
verified remote mutations at G3.

## 11. Risks, stop conditions, and rollback constraints

| Risk | Required response |
|---|---|
| The implementation baseline omits uncommitted shared or peer work. | Stop integration, compare exact source/fixture identities, and agree the baseline with owners. Do not reconstruct it from a matching HEAD alone. |
| A selected binding cannot provide bounded streaming, cancellation, or required private/durable storage behavior. | Resolve D1/D2 before dependent production code. Prefer a supported binding or narrower implementation, never a weaker invariant or bespoke infrastructure by default. |
| Linux/macOS containment does not cover supported descendants. | Refuse unattended capability on the affected platform and retain quarantine. The full release cannot claim both platforms until their tests pass. |
| A proof equation fails or Haskell/model results disagree. | Record the counterexample and diagnose the representation or specification issue. Do not weaken the theorem, normalize away a mismatch, or alter the frozen corpus merely for green tests. |
| A manager DB receipt outlives native journal/artifact bytes. | Preserve the observed outcome and separately report unavailable verification. Do not manufacture native evidence from the manager projection. |
| Restore loses receipts or resurrects revoked credentials. | Apply the offline authority fence, invalidate all restored credentials, and require reconciliation. Never automatically reissue unresolved work under new keys. |
| Global storage/ledger limits are reached. | Refuse ordinary admissions/mutations before evicting protective state. Preserve bounded physical safety supervision without a false durable acknowledgement. |
| A client transport cannot safely consume SSE. | Use the specified bounded polling fallback with identical reconciliation semantics and explicit capability reporting. Do not weaken TLS/authentication to fit a transport constructor. |
| A client retains a second runtime interpretation in service mode. | Move authoritative behavior to the shared runtime/manager boundary and retain only presentation state. Preserve local-mode code until its supported use ends. |
| Pi host-bound engines are requested through the manager UI. | Refuse that service profile and retain explicit local mode. A remote engine connector is a separate approved design, not an endpoint added opportunistically. |
| Cross-machine access or operator configuration is unavailable during acceptance. | Record the exact missing evidence and stop the corresponding release claim. Do not substitute loopback TRAMP or source tests. |
| A rollback binary cannot read the current DB schema. | Do not open it. Drain/cancel, retain compatible read-only access, or restore through the fenced procedure. Never silently downgrade or rewrite manifests. |

Implementation approval does not authorize paid backends, production
configuration changes, publication, or deployment. Those remain explicit
operator decisions. Test-only credentials, private listeners, and fixture
processes must have bounded lifetime and verified cleanup during implementation
acceptance.

## 12. Requirement traceability and final definition of done

The complete release is the conjunction of the following outcomes. A source
file, endpoint stub, successful unit suite, or installed package cannot stand in
for the required evidence type.

| Approved design obligation | Implementation coverage | Release evidence |
|---|---|---|
| Source-grounded reuse and correct boundaries, Sections 2–3. | WM-001 through WM-008, WM-033, WM-036. | Provenance, public/import-boundary checks, shared codec regressions, and no service-mode interpreter. |
| Mathematical meaning and unchanged workflow semantics, Sections 3 and 10. | WM-004, WM-015, WM-022, WM-040. | Exact theorems/axioms, model/Haskell comparison, and matched direct/managed answers, traces, bills, policies, and lineage. |
| Selection, missing inputs, readiness, capture, admission, and concurrent lifecycle, Section 4. | WM-008, WM-011 through WM-016, WM-027. | A01 through A08 and real-client lifecycle acceptance. |
| Exact preparation/approval and control ownership, Sections 4–5. | WM-012, WM-014, WM-016, WM-019, WM-020. | A04 through A10, A20, and no network-to-control-EOF coupling. |
| Durability, uncertain effects, restart, retention, and restore, Section 5. | WM-007, WM-009, WM-010, WM-019 through WM-021. | Transaction/crash matrix, A05, A12 through A17, A19, A20, and A24. |
| Complete REST resources, values, validation, and errors, Section 6. | WM-003, WM-023 through WM-028. | OpenAPI/fixture agreement, endpoint ledger coverage, and real TLS/HTTP tests. |
| Replay, snapshot consistency, duplicates, backpressure, and reconnect, Section 7. | WM-015, WM-021, WM-025, WM-026, WM-029. | A14 through A16, A19, and measured bounded operation. |
| Remote authentication, authorization, TLS, browser/model boundaries, and redaction, Section 8. | WM-008, WM-023, WM-024, WM-028, WM-036, WM-037, WM-041. | Scope/credential/proxy/CORS tests, grant tests, hostile input and secret-marker checks. |
| Verified outputs, history, lineage, and exclusive export, Sections 4–6 and 8. | WM-017, WM-018, WM-025, WM-027. | A11 through A13, legacy compatibility, journal-independent artifact verification, and no-clobber receipts. |
| Thin native clients, coexistence, compatibility, and rollback, Section 9. | WM-029 through WM-039, WM-043. | Real Emacs/TUI/Pi interaction, local-mode regressions, endpoint binding, cross-machine TLS, and rollback exercise. |
| Operational evidence and supportable release, Sections 10–11. | WM-039 through WM-044. | Platform containment, capacity/failure results, runbooks, reproducible artifacts, current manual, and independent review. |

G5 requires all enabled API operations and all three service-mode clients to
meet these contracts. Supported platforms and transports are named explicitly.
No missing compiler, oracle, remote test machine, or platform test is reported
as green. No implementation test is claimed by the act of writing this plan.

The final handoff includes the candidate source and package identities, version
matrix, API/schema artifacts, test/proof evidence, operator procedures, known
limits, and the explicit authorization still required for deployment. The
approved design remains unchanged, and local clients remain usable throughout
the migration.
