# Routing version 2 verification report

Status: implementation and verification complete and uncommitted for review.

Verified: 2026-09-04.

## Scope and isolation

The final reviewable change lives in the detached worktree
`/Users/johnw/src/agent-cat-routing-v2-final` at committed base
`fe388ede5275fe83111bf5bcbd69b73fd0537f48`. Every routing implementation,
test, and documentation file is staged there; the worktree has no untracked or
unstaged implementation file. The concurrent Brick planning artifacts are absent
from that worktree and remain preserved in the shared tree. No implementation
commit, push, pull request, paid route, or live vendor request was made.

The change remains in one public Cabal package, `agentic`. The implementation
modules `Agentic.RoutingConfig.V2`, `Agentic.RoutingDiscovery`,
`Agentic.RoutingInspect`, and `Agentic.RoutingSecrets` are Cabal-hidden. No file
under `dsl/`, `plan/`, `cost/`, `model/`, or `workflow/` changed, and no `tui/`
source directory was added.

## Pre-edit planning chronology and traceability

The planning chronology is preserved by two complementary pre-edit records:

- `2026-09-03T20:08:42.078Z`: session event `b130aea5` confirmed the active
  goal contract. Its normative success criteria, boundaries, constraints, and
  verification contract enumerate the design's normative obligations and the
  required implementation, migration, test, documentation, and compatibility
  evidence.
- `2026-09-03T20:10:00.161Z`: obr issue `acat-xo2` was created, and it entered
  `in_progress` at `20:10:00.382Z`.
- `2026-09-03T20:18:22.081Z`: session event `9af75b99` submitted the nine-point
  obr design mapping those requirement groups to concrete files and symbols,
  ownership, order, tests, compatibility, rollback, and exclusions; event
  `dc8231e0` records successful persistence at `20:18:22.469Z`.
- `2026-09-03T20:19:42.787Z`: task `routing-plan-baseline` completed with the
  isolated baseline and plan evidence.
- `2026-09-03T20:20:59.171Z`: event `ac83b814` made the first source-tree
  mutation, the `RoutingV2Probe` test; the first production-module write was
  `Agentic.RoutingConfig.V2` at `20:23:48.746Z` in event `f6b9dd20`.

The confirmed goal contract enumerated the section-level obligations, and the obr
design mapped their requirement groups to files and symbols. Both predate edits.
The goal revision confirmed at `2026-09-04T16:59:41Z` expressly permits a later,
truthfully dated §1–17 crosswalk to map those groups to final evidence. The table
below is that forensic index; it makes no retroactive claim. The same chronology,
index, and event identifiers are preserved in the `acat-xo2` comments exported to
`doc/PLAN.org`.

| Design section | Pre-edit plan step/task | Planned and delivered files/symbols | Tests, documentation, and compatibility evidence |
|---|---|---|---|
| 1 Decision | steps 1–9; all task contracts | `RoutingConfig.V2`, existing resolver, CLI finalization | v2 probes; no DSL/Plan/Cost/Lean changes |
| 2 Vocabulary | step 1 / `routing-schema-v2` | `SecretReference`, `EngineDefinition`, `ConcreteModel`, `Persona`, `ProfileV2` | strict decoder probe; schema and manual vocabulary |
| 3 Version-1 contract | steps 1, 2, 6 | unchanged `decodeRoutingConfig`, `mergeRoutingConfig`, `resolveRoutingConfig`; conditional v2 fields | original routing probe, exact v1 policy key sets, byte comparison to `fe388ed` |
| 4 Trust-separated files | step 1 | `RoutingLayerRole`, `discoverRoutingLayers`, `loadRoutingLayers`, distinct user/project decoders | project-only user-shaped bypass refusal before secret lookup, untagged-v2 refusal, mixed-version, replacement and allowlist tests |
| 5 Schema and field semantics | step 1 | strict `FromJSON` instances, libyaml warning retention, URL/header/duration validators | block/flow duplicate, unknown field, bounds, literal-secret and reference tests; v2 example |
| 6 Persona selection | steps 1 and 4 / `routing-resolution` | `selectRoutingPersona`, `rrPersonaOverride`, `loadCommandRouting` | command/environment/project/default precedence and no-`run.*` source scan |
| 7 Child environment | steps 4 and 5 / `routing-secrets-environment` | `SecretValue`, `resolveEngineContexts`, opaque `ChildEnvironment`, `connectAcp` | spawned-child sentinel, pre-store missing-secret, argv and store/log scans; v1 ACP gate |
| 8 Discovery and cache | steps 3 and 4 / `routing-discovery-cache` | `discoverRoutingInventories`, `fetchPage`, dialect decoders, engine/endpoint fingerprints, cache reader/writer | local HTTP and trusted TLS, auth, synthesized-request limits, pagination, cache mode/corruption/permission/separation tests |
| 9 Resolution algorithm | steps 2, 4, 6 | `expandRoutingConfigV2`, `freezeRoutingConfigV2`, `finalizeTargetForProgram` | fixed-point, frozen inventory, chain axes, pre-store timing, ACP/deck preflight |
| 9.1 Overrides | step 4 | `rrRealizeOverrides`, `--realize`, managed-axis raw-route refusal | alias eligibility, duplicate/unknown axis, unconfigured/v1 raw-route tests |
| 10 Provenance and inspection | steps 2, 6, 7 / `routing-cli-persistence` | `ResolvedRealization`, `resolvedRealizationPolicy`, `targetPolicy`, stable lineage projection, `RoutingInspect` | sanitized JSON/human assertions, digest recomputation, fresh-to-aged-cache compatibility, engine/environment/persona-source mismatch |
| 11 Worked outcomes | steps 2–4 | persona/profile/selector/cache implementations above | independent 20-outcome oracle plus production fixtures for exact, prefix, stale, missing and ambiguous cases |
| 12 Module ownership | architecture constraint plus steps 1, 3, 5, 8 | hidden CLI modules; ACP owns only child environment; runtime only descriptor constant | policy import gate, Haddock, one-package check |
| 13 Validation contract | step 9 / `routing-final-verification` | schema, discovery, shell and TypeScript probes | commands and selected output in this report; deterministic local fixtures only |
| 14 Migration and rollback | step 7 | `migrateRoutingConfigV1`, `--migrate-routing`, untouched v1 path | equivalence, mode 0600, exclusive no-overwrite, offline inspection and rollback evidence |
| 15 Rejected alternatives | architecture/out-of-scope clauses | no persona fact, provider SDK, `curl`, price/regex language, extra secret provider, or TUI code | source searches and dependency/import gates |
| 16 Implementation sequence | obr steps 1–9 and nine goal tasks | schema → resolver → environment → discovery → persistence/CLI → ext-pi → docs → verification | task timestamps/evidence and final verification matrix |
| 17 Source register | `routing-plan-baseline` | local source/register inspection and pinned provider references | `model-routing-v2.md` source register, locked Nix inputs, local-only acceptance fixtures |

## Implemented contract

- Version-1 routing decoding, overlay, raw routes, axes, preflight, policy shape,
  protocol 1, and store 1 remain intact.
- Version-2 discovery assigns user/project authority from conventional paths
  before decoding and uses distinct trust-level parsers. A project-only user-shaped
  document and all untagged v2 loads are refused. Libyaml duplicate warnings are
  retained for block and flow maps.
- Persona selection follows command line, environment, project, then user
  default. Projects can select personas and replace profiles but cannot define
  privileged objects or widen allowlists.
- Version-2 resolution lowers through the existing routing resolver, expands the
  existing `#N` axes, applies allowlisted model-alias overrides, and freezes exact
  model identifiers after the routing/run-fact fixed point.
- Environment values come only from named environment variables or declared
  non-sensitive literals. Selected ACP children receive a redacted exact map
  after every declared source and destination is scrubbed. Agent Deck receives no
  synthetic environment behavior.
- Discovery uses `http-client` and TLS, not `curl`. It has URL/query/header/body,
  timeout/page/item/id limits, refuses redirects, normalizes OpenAI and Anthropic
  responses, and ignores provider array order.
- Cache paths use the selected persona and a SHA-256 fingerprint of the complete
  non-secret engine definition, including environment structure and cache policy.
  A separate endpoint fingerprint remains in model-selection provenance. Cache
  files are atomic, mode 0600, bounded before allocation, and managed parent
  directories are private, real directories.
- Inspection and persisted policy contain non-secret persona, engine, model,
  selector, settings, timestamps, cache source/age, endpoint and engine
  fingerprints, plus a canonical policy digest. Migration exclusively creates an
  equivalent offline version-2 file, including for empty policies and v1 routers
  that share a backend while retaining distinct provider provenance.
- Descriptor version 3 advertises routing inspection and protocol negotiation
  while machine protocol and store format remain version 1. ext-pi accepts
  descriptor versions 1, 2, and 3, reads only sanitized inspection JSON, and
  persists only persona/model-alias argv. Rebuilt current-session, owned-child,
  and remote lineage targets retain those explicit parent arguments.

## Focused production evidence

The following commands passed:

```sh
nix develop path:. -c cabal run routing-config-probe -- +RTS -N8 -RTS
nix develop path:. -c cabal run routing-v2-probe -- +RTS -N8 -RTS
nix develop path:. -c cabal run routing-discovery-probe -- +RTS -N8 -RTS
nix develop path:. -c bash cli/ci/routing-config.sh
```

Selected final output was:

```text
routing v2 schema probe: all checks passed
ok   catalogue URL bytes, query bytes, and query item count are bounded
ok   cache identity includes the complete non-secret engine definition
ok   Anthropic pagination cannot exceed final query-item bound
ok   Anthropic pagination cannot exceed final query-byte bound
ok   Anthropic pagination cannot exceed final URL bound
ok   resolved authentication headers are bounded before request
ok   literal, auth, and generated headers share the final count bound
ok   literal and resolved authentication headers share the final byte bound
ok   chunked response streaming stops at the body bound
ok   standard TLS manager rejects an untrusted local certificate
ok   trusted local TLS sends bearer auth and selects OpenAI inventory
ok   trusted local TLS sends raw x-api-key auth across Anthropic pagination
routing discovery probe: all checks passed
routing config: all checks passed
```

The version-2 schema probe covers block and flow duplicate keys, trust authority,
persona and model eligibility, selection precedence, process-definition backend
sharing with per-router provider provenance, managed-route refusal, model-alias overrides, exact/prefix ordering,
provenance, environment scrubbing, URL/query/header/time/body bounds, migration
input, and unchanged version-1 loading.

The discovery probe uses only local servers and an ephemeral test certificate. It
covers:

- OpenAI and cursor-paginated Anthropic normalization;
- provider-order permutation and timestamp/id tie-breaking;
- URL, query, header, timeout, body, page, item, and identifier limits;
- both content-length and chunked oversized responses;
- redirect, malformed JSON, status, timeout, duplicate-id, and pagination errors;
- rejection by the standard TLS manager of an untrusted certificate;
- successful TLS with a generated local CA and hostname verification;
- bearer `Authorization` and raw `x-api-key` requests without recording headers;
- fresh, fresh-cache, stale-if-error, offline, and forced-refresh behavior;
- corrupt, oversized, broadly-permissioned, and symlink-directed caches;
- cache separation by persona and by the complete engine fingerprint; and
- absence of endpoint and credential text from cache records.

The routing shell gate additionally proves missing-secret failure before an
agent-cat run store or adapter, version-2 ACP and Agent Deck preflight, catalogue
evidence not replacing ACP evidence, sanitized inspection, project-only
user-shaped configuration refusal before secret lookup, policy digest
recomputation, fresh-to-aged-cache lineage compatibility, exact
environment/persona-source lineage mismatch, migration no-overwrite,
migration of valid same-backend/different-provider v1 routers with exact provider
provenance, and zero sentinel occurrence in output, events, manifests, caches, or
child logs.

## Full agent-cat verification

These exact commands passed during the final verification cycle. After audit
remediation, the impacted Cabal, routing, documentation, ext-pi, and downstream
commands were run again:

```sh
nix flake check --no-build path:.
nix develop path:./model -c bash -c 'cd model && lake build'
nix develop path:./model -c bash -c 'cd bisim && lake build && lake exe corpus-gen'
nix develop path:. -c cabal build all -v0
nix develop path:. -c cabal test all -v0
./bisim/ci/tier0.sh
SEED=20260903 N=500 ./bisim/ci/tier1.sh
nix develop path:. -c bash cli/ci/policies.sh
nix develop path:. -c bash cli/ci/citations.sh
nix develop path:. -c bash cli/ci/examples.sh
nix develop path:. -c bash cli/ci/routing-config.sh
nix develop path:. -c bash engine/acp/ci/acp.sh
nix develop path:. -c bash engine/agent-deck/ci/deck.sh
nix develop path:. -c make -C doc check
make -C doc check-haskell
nix develop path:. -c cabal haddock lib:agentic -v0
```

Observed summaries:

- corpus regeneration: 193 files, no Git change;
- Tier 0: 193/193 and Tier 1: 30/30;
- differential bisimulation at seed `20260903`: P1 500/500, P2
  12000/12000, P3 416/500 with 84 classified `other` skips, zero failures;
- citations: 197 references against 42 Lean files;
- examples: 9/9 programs;
- ACP: 18 scenarios; Agent Deck: 10 scenarios;
- manual: 238 source items, 129 compiler-exported children, 112 instances;
- independent design oracle: four YAML examples and 20 outcomes.

One Agent Deck stale-reply fixture run transiently observed zero sends while still
reaching its expected transport failure. An immediate isolated rerun passed all
10 scenarios; earlier full runs also passed. No production code was changed to
hide that signal.

## ext-pi verification

From `ext-pi/`:

```sh
npm ci --legacy-peer-deps --ignore-scripts
npm run check
npm test
AGENT_CAT_E2E_RUNNER="$(cd .. && nix develop path:. -c cabal list-bin agentic-run)" \
  npx vitest run test/native-targets-e2e.test.ts
AGENT_CAT_E2E_RUNNER="$(cd .. && nix develop path:. -c cabal list-bin agentic-run)" \
  npm run test:integration
```

The ordinary suite passed 68 tests with seven environment-dependent tests
skipped. The focused routing-lineage test verifies both trailing selector
extraction and an owned-child resume manifest; current-session and remote rebuilds
use the same path. The real-runner native target suite passed four tests. The integration
command was then run in a temporary copy with the accompanying built local Pi
protocol/client/server/coding-agent packages linked, as required by
`ext-pi/README.md`; all 10 integration tests passed across five files. The normal
`node_modules` tree was freshly restored with `npm ci` afterwards.

## Downstream agent-workflows verification

A detached agent-workflows compatibility worktree adds `pkg-config` and `zlib`
to its Nix development shell: local Cabal builds of this routing-v2 package need
the `http-client-tls` foreign dependency. Its two-file change (`flake.nix` and
the obr record) is staged and separate from the routing-only agent-cat worktree.
These commands passed:

```sh
nix develop path:. -c cabal build all -v0
nix build path:. --no-link
nix develop path:. -c bash ci/workflows.sh
nix develop path:. -c bash ci/taskmaster.sh
nix develop path:. -c bash ci/cookbook.sh
EMACS="$(nix build --no-link --print-out-paths \
  github:NixOS/nixpkgs/8be7bd0c83f12e2e3bbba07c9044d6fed9e66f7f#emacs-nox)/bin/emacs" \
  nix develop path:. -c bash ci/emacs.sh
```

Results were 74 workflows, the Taskmaster 25-check gate, 74 cookbook rows, and 37
Emacs smoke facts. The Taskmaster gate uses its manifest-pinned historical
agent-cat evidence fixture at `a88dc85935032fd760c2cd489e05b34c2d9736dd`, while
its `wf` executable was built against this staged routing-v2 worktree.

## Compatibility and integrity evidence

An untouched `fe388ed` runner and the new runner produced byte-identical stdout
and stderr for:

```text
list
help hello
plan hello
cost hello
run hello --scripted
```

Every descriptor-v2 field and capability retained its value; descriptor version 3
only adds the documented routing and negotiation capabilities. Version-1 machine
policy tests assert its exact original key sets and absence of persona, model
alias, engine fingerprint, or routing-version fields.

Frozen values remain:

```text
corpus aggregate SHA-256:
  ddc3c072660c1bc09e2ef06e850ae314512dbafff06734ad23ef1d4a47be14e5
manual workflow source SHA-256:
  10f66aa25cf654376ce436c1b1e0c354b2f0697962f45668e7ab8ce19e2c2654
```

`git diff --check` passes. Every routing implementation, test, and documentation
file is staged, with no untracked or unstaged file; the staged scope excludes the
concurrent Brick planning artifacts. There are no unknown generated files.
`cli/ci/policies.sh` verifies source import boundaries. Searches find no
routing/persona imports in DSL, Plan, Cost, Lean, workflow, neutral runtime, or
neutral engine sources, and no production use of `curl`.

## Review findings resolved

Independent read-only reviews examined correctness, architecture, and security.
Successive audit findings produced these corrections:

- complete engine fingerprint for cache identity and lineage;
- duplicate warnings for flow maps;
- percent-decoded query validation and syntactically valid loopback addresses;
- bounded cache reads and private non-symlink managed directories;
- narrowed public facade instead of wholesale internal-module re-export;
- final rendered URL/query and complete explicit-header bounds after synthesis;
- resolved authentication value/count/aggregate bounds before network;
- path-derived layer authority preventing project-only user-document promotion
  before secret lookup;
- stable lineage comparison that retains complete inventory provenance while
  excluding only observation-time source, timestamp, age, warning, and digest;
- ext-pi preservation of explicit parent persona/model-alias arguments when
  rebuilding current-session, owned-child, and remote lineage targets;
- equivalent migration for empty v1 policies and same-backend routers with
  differing provider provenance, with direct environment and catalogue conflict
  regressions;
- exact two-layer pre-edit chronology plus an honestly labeled forensic §1–17
  index and corrected authoritative headings in this report and the obr PLAN
  comments.

A final focused review of both lineage remediations found no correctness,
security, or compatibility issue. Current-session and remote target rebuilding
share the exact branch exercised by the owned-child regression.

The approved design intentionally retains config paths and backend locators in
sanitized inspection/provenance, and permits two aliases to share a backend only
when their environment and catalogue process definitions are equal; provider
provenance may differ so that valid version-1 configurations remain migratable.
These decisions are documented and tested.

## Residuals and explicit exclusions

- The locked nixpkgs revision passes current-system flake evaluation. An optional
  `nix flake show --all-systems` fails because nixpkgs 26.11 removed
  `x86_64-darwin`; obr issue `acat-2f6` records that pre-existing platform-policy
  decision.
- `cabal check` rejects both the untouched base and this tree for the package's
  pre-existing lack of a `base` upper bound. Build, test, Haddock, and downstream
  Nix derivations pass.
- No paid/live route was run. In particular,
  `engine/acp/ci/route-live.sh` was not invoked.
- No Brick TUI code exists in this worktree. The only deferred routing work is the
  future TUI pane consuming the implemented sanitized inspection contract.
