# Workflow-manager halt checkpoint

<!-- checkpoint-id: wm023-20260923; status: paused-unaccepted-wip; accepted: WM001..WM022,G0,G1; resume-branch: workflow-manager-checkpoint-20260923; fess: every-subtask -->

This checkpoint preserves work at the operator's halt request on 2026-09-23. It is a resumable implementation, not application acceptance or release approval. The accepted baseline remains **WM001–WM022 and G0/G1**, which is **22 of 44 packages and two of six gates**. WM023 remains partial, and the full TUI workflow is unfinished.

## Authoritative state and branches

Resume from **`origin/workflow-manager-checkpoint-20260923`**. Its code sequence is based on canonical `a8bf8c115e2d01701ba49699f72e0687a3a257cc`, without overwriting current planning records with the older isolated copies.

| Commit | Scope |
| --- | --- |
| `12fc322` | Current native session, runtime and manager-schema compatibility domains and refusal fixtures. |
| `910db08405b3240276b5edc14d90439ec9e5ef1f` | Protected manager service, scoped observations, paging, polling/SSE and implemented mutation routes. |
| `073508ff759addf9dcdf6e643e5e6bac2783efba` | Endpoint-bound public client, original pending commands and verified downloads. |
| `d8c0609a7ea1b22dc70e863a288a1fa15fc46325` | TUI request/approval path and the still-unwired public observation adapters. |

The subsequent documentation commit `bf516dba427e6034ce454cf499ec19c3d878f14d` documents the service-mode selector. This checkpoint bundle and the current tracker follow it. The `tui` branch retains the accepted application/dependency baseline and points to this separate WIP branch. Do not interpret publication of the WIP branch as integration clearance.

The original pre-broker prototype is separately preserved on **`origin/archive/service-tui-pre-broker-20260923`**, commit **`74ad50e93de6a0ff301142b24784fccf6d81a88c`**, based on `4cf7828c`. That eight-file prototype is historical material. Do not resume feature work there or deploy its old TLS stack.

## What is implemented

The default in-process broker is integrated at `678326b`. It carries actual runtime requests/replies, engine traffic, controls, events, logging and persistence. Runtime remains the sole workflow interpreter and owner of decoding, policy, scheduling, retry semantics, authored traces and exact bills.

The WIP service composes the original configuration, Store, Admission, Service, local administration and HTTPS listener lifetimes. It supplies authenticated capabilities, profiles, workflows/help, Overview, request/preparation/command observations, managed run/control/decision/snapshot/output observations, artifact downloads, polling and SSE. Implemented mutations include request creation, literal edits, enqueue/withdraw, approval and owned controls. This is not the complete frozen HTTP surface.

The client loads an explicit private JSON profile, retains endpoint-bound references and exact GET validators, assembles complete bounded page sets, verifies response framing and downloaded byte identities, and never retries a mutation automatically. The TLS family uses `crypton-x509` and `crypton-x509-validation` 1.9.1 with the reviewed IP-only SAN dispatch correction. GHC remains 9.10.3 and the flake lock is unchanged.

The TUI reuses its existing Brick App, Model and Presentation. Local and service owners are disjoint. Service mode has no synthetic local configuration, private root or RunningMachine. Actual keyboard interaction can browse the remote catalogue/help, create a request, submit exact Unicode input, display every complete review selector, approve with explicit summary `y`, observe association, and detach without cancelling the original manager-owned run.

The mutation lane retains `PendingCommand` before its one send. An uncertain outcome can be resent only through explicit confirmation using the same object, body, key and validator. Receipt visibility and request visibility are independent. Approval remains `dispatch-attempted` in the exercised protocol and is not relabelled as an observed runtime effect.

## Exact current limit

The TUI does **not** yet complete a run. It does not display the complete live public snapshot, answer the pending Bool decision, select the offered recovery retry, or retrieve the final verified bytes through its UI.

At the halt request, the newest additions to `tui/src/Agentic/Tui/Service.hs` were unwired observation adapters. During checkpoint preparation they compiled and received focused fixture tests. They remain unwired into App. Relevant entry points are:

- `observeSnapshot`, `decodeSnapshot` and `RunObservation`.
- `observeControl`, `decodeControl` and `ControlView`.
- `observeDecision`, `decodeDecision`, `headMatches`, `answerOffered`, `answerValue` and `retryOffer`.
- `observeResult` and `Artifact`.
- `Agentic.Manager.Client.downloadVerified`, which has no TUI caller yet.

The pure Runtime snapshot projection deliberately supplies no native last envelope, question path, result path, launch capability or execution handle. Public replacement metadata remains separate. Do not reconstruct ownership from its IDs.

## Current validation and its limits

All required execution in this checkpoint was local macOS through the existing Nix/direnv setup. The single serialized build directory was `credentials.QHYL3FHM/build` under the local implementation unit.

| Source and check | Result and scope |
| --- | --- |
| Contract commit | 99 schemas, 29 operations, 333 payload cases, 20 SSE cases and three byte-bound downloads passed on 2026-09-23 at 22:55:50–22:55:52Z. No service execution is implied. |
| Service commit, detached exact-commit worktree | Werror build plus response-order, observation and actual verified-TLS/polling/SSE/quota/revocation/restart checks passed at N1 then N8, 23:00:49–23:05:43Z. |
| Client commit, detached exact-commit worktree | Werror build, all 18 external HTTPS client-boundary cases, and actual protected-manager client observations passed at N1 then N8, 23:07:57–23:08:57Z. |
| TUI commit, detached exact-commit worktree | Werror build, full model/property/golden/render/root-role tests and actual 140×36 request/approval/detach PTY checks passed at N1 then N8, 23:10:57–23:12:49Z. Import boundaries passed with 48 syntax/frontend and 343 forbidden-edge fixtures. |
| Newest observation adapter | Fixture tests cover exact sequences above 2^53, maximum occurrence/attempt IDs, retained Unicode output, absence of fabricated native references/status, forbidden fields, matched head/generation, typed false conversion and required nullable scope fields. These are not live TUI answer/recovery/download evidence. |
| Archived pre-broker prototype | Its library compiled with its original GHC 9.10.3 package set at 23:16:09–23:21:45Z. No native execution or security acceptance is claimed for that archive. |

The shared local build directory was last used for the archived prototype. **Rebuild from the current checkpoint with the current Nix package set before running any binary.** Stale executable runs are not acceptable evidence.

Earlier success and failure records remain distinct:

- The full Python HTTP mixed workflow passed at N1/N8 at 09:17:56–09:19:14Z. It was not a TUI run and predates the TLS update.
- `tls-owning-native` later failed with a request still queued before preparation. Its cause is unproved.
- The first TUI approval attempt failed before review. The second associated a real run but its UI failed to follow that association. The final screen reported 503, without proving that every intervening read failed.
- The App incorrectly required successful receipt polling before updating an independently authorized request, and incorrectly required `preparationId` to persist after association. Those assumptions were corrected without changing Store policy.
- A documented canonical documentation command timed out during its Haskell build. The separately resumed `check-haskell` invocation passed. The later pass does not certify the interrupted invocation or its cleanup.
- The earlier TLS SAN run reused a static executable despite a successful package build. Only the explicit relink and subsequent checks validate the corrected dependency.

The halt documentation gate first failed because the manual and CLI index omitted `--service`. Commit `bf516db` documents the implemented selector and its unfinished UI scope. The corrected `make -C doc check` passed at 23:57:01–23:57:06Z on 2026-09-23. Tracker comparison, resume-shell parsing, remaining-package coverage and bounded publication scans also passed. Both documentation attempts are retained under `validation/`.

The final current-checkpoint Haskell documentation/API inventory is not fully reconciled or accepted. The earlier successful `check-haskell` evidence belongs to its recorded source scope. A fresh-clone rebuild of the portable recipe was not executed during the halt.

## Open findings that remain binding

| Issue or review | Required next work |
| --- | --- |
| `acat-response-ingestion-budget-zaoi`, P1 | Resolve the protected-response/ingestion contention ceiling. A response can retain configuration for several individually bounded writes while ingestion has only its existing five-second contention allowance. Reproduce the interaction and correct existing owners without widening waits, dropping authorization or replaying an operation. |
| `acat-tls-name-forms-6gbo`, P1 | Resolve residual upstream Name Constraints validation, including unsupported IP forms and review of DNS normalization/inheritance. The targeted dependency/SAN improvement does not establish general-CA acceptance. |
| `acat-tui-internal-faults-jj13`, P2 | `safeService` maps every synchronous exception to transport failure. Distinguish unexpected internal faults from expected transport errors, retain uncertainty and terminal cleanup, and do not offer ordinary retries for programming defects. |
| `acat-tui-consent-barrier-wby2`, P2 | Strengthen the negative Enter/detail-view approval assertions with a post-key processing boundary and a guard-breaking negative control. PTY input delivery alone is not that boundary. |
| Service-liveness review | Continued clearance of the corrected loan order and the remaining negative scenarios is still required. The order tests do not settle total response liveness. |
| Pages and events | Complete native page-set quota, expiry, token, concurrent-send and interruption checks, plus complete client snapshot/event attachment and stale-view handling. |

The halt fess audit permits **WIP preservation only** and blocks application acceptance or release. Its history isolation was not independently verified because no parent-history sentinel probe was performed. Newest-adapter compilation and fixture coverage reported above supersede only the audit's cutoff verification gap, not its remaining findings.

## Resume on this machine

The intended source worktree is:

```text
/Users/johnw/Products/agent-cat-workflow-manager/implementation.9tGzKH/service-tui.purvEwEv/broker-source
```

Its branch is `workflow-manager-checkpoint-20260923`. The original `source` sibling is now the archival branch. The detached `halt-20260923/verify-source` sibling is a verification checkout, not the work branch.

Enter the canonical direnv shell, then source the recorded private environment and change to the checkpoint worktree:

```bash
direnv exec /Users/johnw/src/agent-cat/.worktrees/tui bash
source /Users/johnw/Products/k.M0a5ItPm/environment.sh
cd /Users/johnw/Products/agent-cat-workflow-manager/implementation.9tGzKH/service-tui.purvEwEv/broker-source
git status --short --branch
ghc --numeric-version
ghc-pkg latest crypton-x509-validation
```

The expected compiler is 9.10.3 and the package version is 1.9.1. The private environment selects the patched Nix derivation. The old cached direnv environment alone was not globally regenerated.

## Resume from a fresh clone

```bash
git clone --branch workflow-manager-checkpoint-20260923 \
  git@github.com:jwiegley/agent-cat.git agent-cat-manager
cd agent-cat-manager
nix develop path:. -c bash
```

Create a new private local test environment. Do not copy fixture credentials or assume old Products paths are capabilities:

```bash
set -euo pipefail
umask 077
mkdir -p "$HOME/Products"
work=$(mktemp -d "$HOME/Products/manager-resume.XXXXXXXX")
mkdir -p "$work"/{home,config,cache,state,data,runtime,tmp,build}
export HOME="$work/home"
export XDG_CONFIG_HOME="$work/config" XDG_CACHE_HOME="$work/cache"
export XDG_STATE_HOME="$work/state" XDG_DATA_HOME="$work/data"
export XDG_RUNTIME_DIR="$work/runtime"
export TMPDIR="$work/tmp" TMP="$work/tmp" TEMP="$work/tmp"
export CABAL_BUILDDIR="$work/build" CABAL_CONFIG="$work/config/cabal-config"
printf 'active-repositories: :none\n' > "$CABAL_CONFIG"
export PYTHONDONTWRITEBYTECODE=1
if [[ -v GHCRTS ]] || compgen -A variable AGENT_CAT_ >/dev/null; then
  printf 'Refusing inherited GHCRTS or AGENT_CAT_* settings.\n' >&2
  exit 1
fi
```

Use the repository Bash Cabal wrapper offline. The initial rebuild must eliminate old static linkage:

```bash
bash test/cabal.sh build agentic-run routing-fixed-point-probe \
  manager-client-check manager-artifact-check tui-model-test \
  --with-compiler="$(command -v ghc)" --with-hc-pkg="$(command -v ghc-pkg)" \
  --ghc-options='-Werror -threaded -rtsopts -fforce-recomp'
bash manager/ci/contract.sh
checker=$(bash test/cabal.sh list-bin tui-model-test)
"$checker" +RTS -N1 -RTS
"$checker" +RTS -N8 -RTS
```

Re-establish the current actual TUI baseline in fresh fixture roots:

```bash
frontend=$(bash test/cabal.sh list-bin agentic-run)
runner=$(bash test/cabal.sh list-bin routing-fixed-point-probe)
fixture=$(mktemp -d "$TMPDIR/tui-resume.XXXXXXXX")
for n in 1 8; do
  mkdir "$fixture/N$n"
  TUI_CHECK="$frontend" python3 -B manager/test/service_http.py \
    "$PWD" "$fixture/N$n" "$runner" "$n" tui-approval || exit "$?"
done
```

The loop stops at the first failure. Preserve its root and outcome rather than repeatedly running for a favourable result. This baseline ends after approval and detach, not workflow completion.

## Immediate next work

1. Read the current goal, AGENTS.md, this checkpoint and the outside remaining-scope report. Recheck the wall clock and keep the hourly refocus rule active.
2. Address the two P2 fess findings before relying on the affected recovery and negative-test claims. Keep the known P1 obligations visible.
3. Wire the already compiled observation adapters into the original single-flight read lane. Install complete page sets atomically and retain absent runtime as absent.
4. Reuse existing person/recovery presentation for a genuinely pending FIFO head. Require matching run, profile, occurrence, generation, current offer and exact resource GET validator. Send JSON `false`, not a text surrogate.
5. Invoke only an actually offered retry, observe the independent native terminal outcome, then fetch the matching exact source-result bytes through `Client.downloadVerified`. Keep verified bytes unchanged for saving.
6. Extend the existing PTY driver to one uninterrupted Unicode → exact approval → progress → false → retry → genuine completion → verified retrieval journey at N1 then N8. Do not finish missing steps with Python mutations and call that TUI acceptance.
7. Complete the remaining observation/bootstrap, negative, security and liveness requirements, then seek coherent independent review. Do not close a package or gate from one happy-path demonstration.

**Run the `fess` skill at the end of every downstream subtask**, including implementation, tests, documentation, cleanup, review, failed attempts and blocked attempts. Record findings, exact evidence and its limits before proceeding. If the skill is unavailable, say so and apply the recorded rubric rather than claiming an audit ran. Do not recursively delegate an auditor from an auditor.

## Full remaining roadmap

The complete package definitions remain in [the implementation plan](../../research/workflow-manager-implementation-plan.md). The current amendments in [the handoff](../../workflow-manager-handoff.md) govern conflicts.

- WM023–WM028 complete protected authentication, transport, all read/mutation routes, pages/events and the integrated hostile-input gate.
- WM029 and WM033–WM035 finish the shared client and full TUI lifecycle/acceptance. The first TUI journey comes before Emacs, but does not erase the remaining UI features.
- WM030–WM032 finish the actual Emacs service client and native interaction acceptance.
- WM036–WM038 finish the owner-coordinated Pi service client, trusted grants and actual host UI acceptance.
- WM039–WM041 finish local cross-client concurrency, the manager conformance bridge, capacity and failure evidence.
- WM042–WM044 finish operations, reproducible local packaging, rollback, current documentation and integrated independent review.
- G2–G5 remain open under these functional obligations.

Linux, external-host and cross-machine testing are **not current completion prerequisites**. Local macOS cross-client evidence satisfies the amended validation location, without being labelled historical remote evidence. No paid provider, deployment, live client/infrastructure configuration change or new Lean/oracle build is authorized by implication. If WM040 requires a newly built proof/oracle artifact, obtain separate targeted authorization rather than silently substituting source inspection.

RabbitMQ and John Mark integration remain deferred. Do not turn them into blockers or implement a second interpreter.

## Preserved material and publication boundary

- `notes/` contains dated working records and failure chronology.
- `reviews/` contains the service-liveness review, bounded TLS review and halt audits.
- `proposals/` contains advisory source proposals, not implementation or acceptance evidence.
- `public-fixtures/` contains only public synthetic fixture observations and TUI screens.
- `validation-history.tar.gz` contains allowlisted command, log and outcome records, including original failures and halt checks. Paths in old commands are historical. Use the portable resume recipe above.
- `validation/` preserves the failed and corrected final documentation checks, with their original commands, times and outcomes.

This README and the current handoff supersede earlier status paragraphs in copied notes. The roadmap advisory's original-platform caveats are superseded by the explicit local-only amendment. The TUI proposal's prompt-byte assumption, deprecated API names and unsupported command examples are not authoritative.

Private fixture credentials, private keys, raw SQLite stores, live configuration, unrelated worktrees and compiler/build caches are intentionally not published. Their original local roots remain untouched. Byte-for-byte preservation of those private roots requires an operator-controlled backup. A fresh session can recover the source, requirements, audit findings and non-secret evidence from Git, and regenerate new fixtures without reconstructing ownership from old IDs or PIDs.
