# The parity acceptance matrix: one row per PAL tool

*2026-08-19. The document `plan.md` §3 has been waiting for. Written against
PAL MCP 1.4.0 as installed and live on this machine, against **the agent-cat
working tree that lands with this commit** — Stage R's routing, every gate green
— and against `agent-workflows` at its own HEAD — **twenty-one registered rows**
across seven families behind the `wf` binary, gated by `ci/workflows.sh` at 21
pinned, 0 failed. It reads
`pal-vs-agent-cat.md` (the analysis this track executes), `plan.md` (the plan of
record), `routing-design.md` and `confer-design.md` (the two designs), and it
reads the owner's own corpus at `~/src/nix/config/ai` — read-only, for usage
patterns and for nothing else.*

*The baseline matters and is stated exactly, because two rows depend on it.
`Agentic.Route` does not exist at pushed `586bce7`; P13b and P15 assert that
routing does exist, and they are true of **this commit's tree** and not of that
one. A reader checking those rows against `586bce7` would find no module to
check them against.*

*The owner's ruling governs this document as it governs the plan: **PAL MCP
stays configured.** There is no removal activity here, no migration checklist,
no deprecation, and no metric that counts PAL calls down. This matrix answers a
narrower and more useful question — **on what day, and after which run, does
"I could avoid PAL if I wanted to" become simply true?** — and it answers it
per row, honestly, including the rows where the answer is "never, and that is
the right answer".*

---

## How to read a row

Every row below carries four things, in this order:

| column | what it is |
|---|---|
| **counterpart** | the agent-cat expression: a workflow, an engine configuration, a rubric define, or an honest decline |
| **must exist** | what has to be built for the counterpart to be real: routing (Stage R), confer (Stage C), both, or nothing |
| **acceptance run** | a command line that can be typed, and what its output must show. A row whose run has not been executed is a row that has not shipped |
| **status** | green before this wave · Stage R · Stage C · R+C · out of track · declined · residual |

**The acceptance runs are not illustrations.** `plan.md` §3 states the rule and
this document keeps it: *the definition of done is the runs, not the landing of
the files*. Four of the rows below are already green and their acceptance is
therefore a **citation** of an existing gate rather than a new execution — that
distinction is itself part of the ledger, because a row that is already true is
a row the owner already has.

**Where a row's acceptance is a live, billed run, the gate is
`ci/route-live.sh`** — the two-provider smoke, its two negative controls, and
every assertion the routing rows quote. It is **manual on purpose**: it spends
real money on real accounts, and a gate that quietly bills somebody is worse than
no gate. Its evidence is the committed log at
`doc/research/pal-subsumption/route-live-log.txt`, and rows that assert what a
live run showed point at that file rather than at a transcript nobody can open.
The script also fixes what a live run may and may not assert: **the flagship's
last question goes to a person**, both of whose answers are correct, so no row
may pin one of them (`ci/route-live.sh:79`–`:106`).

---

## 0. What the owner actually does with PAL, read from the corpus

Grepped read-only across `~/src/nix/config/ai` for `pal`, `PAL`, `consensus`,
`thinkdeep`, `clink`, `challenge` and `apilookup`. The point of this section is
weighting: a parity matrix that gives `precommit` and `consensus` equal
prominence has not looked at what is actually called.

| PAL surface | where it is invoked in the corpus | weight |
|---|---|---|
| `consensus` | `commands/heavy.md`, `commands/review-github-pr.md`, `skills/wiggum/SKILL.md` §"Confer via PAL for real decisions", `skills/forge/SKILL.md` phases 1/2/4/5 | **dominant** — this is the habit |
| `chat`, exact-model, identity-attested | `skills/validated-code-review/` (SKILL, README, `verify-model-dispatch.py`), reached through `commands/heavy-review.md` | **load-bearing and singular** — see P1b |
| `listmodels` | `skills/forge/SKILL.md` (availability preflight), `skills/validated-code-review/` (roster attestation preflight) | supporting |
| `thinkdeep`, `analyze`, `codereview` | `skills/forge/SKILL.md` phases 1 and 4 only | occasional |
| `clink` | named once, and **explicitly rejected**: *"Clink selects a CLI name and role, while the CLI preset owns its model; it cannot attest an exact roster model"* (`validated-code-review/SKILL.md`) | rejected in place |
| `chat` with an image | `commands/transcribe-image.md` — *"use pal mcp to re-review"* handwriting | one real caller, and it is residual #2's only caller |
| `planner`, `precommit`, `refactor`, `debug`, `challenge`, `apilookup`, `version` | **nowhere** | zero |

Three things follow, and each shapes the ledger:

1. **`consensus` is the whole track.** If `confer` lands and nothing else does,
   the dominant habit has a workflow-native alternative. That is why `plan.md`
   §4.5 rules Stage C first, and this matrix agrees.
2. **`clink` is already rejected by the owner's own most demanding skill, for
   exactly the reason `--adapter` shares.** Parity on P10 is therefore exact,
   *including the limitation*, which is a more interesting kind of parity than
   the usual.
3. **The one PAL capability the corpus depends on that this track cannot
   match** is `validated-code-review`'s attested returned-model identity. It is
   row P1b, it is new — `plan.md` §3 has no row for it — and it is the fourth
   residual.

---

## 1. The matrix

### P1 — `chat` → an ask, registered as `second-opinion`

**Counterpart.** One question to one party is the atom of the language. The
registered shape is **`second-opinion`** — `secondOpinion` is the Haskell
binding's name and the design's (`confer-design.md` §5.3); the registry row is
spelled the owner's way, and it is the row name that goes on a command line:
one seat pinned
through `lateral`, the challenge rubric, an artefact, and a `reporter` act —
*"PAL's `challenge` and PAL's `chat` in one program, and it is the shape the
owner reaches for most often"*. The per-call knobs PAL exposes (temperature,
thinking effort) live one level down in adapter and session configuration,
which is `pal-vs-agent-cat.md`'s ruling and not a deferral.

**Must exist.** Stage C: `challengeRubric`, `conferSubject`, `secondOpinion`,
and a `Workflows.Registry` row. Nothing from Stage R.

**Acceptance run.**

```
wf plan second-opinion --require-pinned
wf run  second-opinion --scripted \
  --input-arg decision='<the claim to be tested>' \
  --input-file context=./<the document>
wf run  second-opinion --engine acp --adapter claude \
  --input-arg decision='<the claim to be tested>' \
  --input-file context=./<the document>
```

`plan` answers with the inputs ungiven and `run` does not: *"run needs every
input"* is `wf`'s refusal, so a scripted line written without them tests the
refusal and not the fan-out. Only `plan` may be typed bare.

Must show, in that order: the plan prints `level pipeline`, `size 3`,
`askNodes 2`, `codes text, receipt`, `cost minFold 2, maxFold 2, over 1 path`
and `--require-pinned` refuses nothing; the scripted run exits `0` at
`billFresh 2` / `billMemo 2`; the live run exits `0`, writes
`second-opinion-<date>.md` into the run directory with the opinion **verbatim**
under a heading naming the question, and the trace shows the seat answered
under `lateral`'s pin — *a second opinion from somewhere other than the house
model, which is the whole value of asking for one*.

**Status: Stage C.** This is `plan.md` §3's **A1**, unchanged.

---

### P1b — `chat`, with the returned model identity attested. **The row §3 lacks.**

**Counterpart: partial, and the shortfall is deliberate.** The owner's
`validated-code-review` skill does not merely name a model per call; it saves
the raw response, reads `metadata.model_used`, and **aborts the review** if the
returned identity is not exactly the requested one
(`skills/validated-code-review/scripts/verify-model-dispatch.py`). Its stated
constraint: *"Every model response has runner-returned `metadata.model_used`
exactly equal to its requested roster identity."*

agent-cat gives two of the three things that contract wants and refuses the
third **on purpose**:

| what the contract wants | what agent-cat gives | verdict |
|---|---|---|
| a pre-flight that the roster is reachable | `--require-pinned` refuses before a plan is printed (`Cli.hs:486`–`:493`, where the guard is consulted before the verb runs) — *stronger*: it is a guard, not a remembered call | **better** |
| a statement of who was asked, per answer | the trace's `EventKey` carries the addressee and the scope model; the header carries the backend policy | **equal in kind** |
| a runner-returned attestation of **which weights answered** | **nothing, and by design.** `routing-design.md` §4.2 tables every structure that identifies a run's answer — `EventKey`, `Event`, `eventJson`, `scopeJson`, the two bills — and none names a backend; §4.4 says why: *"putting the backend in the trace would put execution policy into a structure the frozen corpus compares by equality."* An ACP adapter serves whatever its CLI session is configured for; the header names a *transport*, not a SKU | **PAL is stronger** |

**Must exist.** Nothing buildable in this track. Closing this would require a
returned-identity field on the answer, which `routing-design.md` §4.2 and §4.4
forbid for a reason this matrix does not dispute. (§1.5 is the flag's five usage
refusals and says nothing about the trace; earlier drafts of this row cited it,
and the citation is corrected here.)

**Acceptance run** — negative, and documentary:

```
wf run review-deep --engine acp --adapter claude
```

Read the header and the trace. The run can prove *which pin was asked and which
backend this run was pointed at*; it cannot prove *which weights answered*. The
acceptance criterion is that this document, `conferProvenance`
(`confer-design.md` §1.4) and `plan.md` §3's residual list all say so in the
same words, and that **no claim of parity with `validated-code-review` is made
anywhere in this track**.

**Status: accepted residual #4.** `validated-code-review` keeps PAL, and under
the owner's ruling that is a correct outcome and not a failure of the track.

---

### P2a — `consensus` → `confer`, at one backend

**Counterpart.** `confer` (`confer-design.md` §1.5): three parties over three
stances, `panelText` into a fenced document, a synthesis that locates
disagreement, an act that writes the artefact. Stances are prompts, a roster is
a list of parties, the synthesis is a fold — and the artefact is on disk rather
than in a chat window.

**Must exist.** Stage C, entire: the stance defines, `conferSynthesis`,
`conferProvenance`, `conferWriteBrief`, `conferOver`, `confer`, the registry
row, the scripted table. Nothing from Stage R.

**Acceptance run** — four commands, and each one shows something the other
three cannot:

```
wf plan confer --require-pinned            # the pre-spend contract, without the inputs
wf cost confer                             # one price, not a range
wf run  confer --scripted \
  --input-arg decision='<anything at all>' \
  --input-file context=./<any file>        # the fan-out, provably fanned out
wf run  confer --require-pinned --engine acp --adapter claude \
  --input-arg decision='<a real decision the owner faces>' \
  --input-file context=./<a real document>
```

The first two are the only ones that may be typed bare: `plan` and `cost` answer
with the inputs ungiven — which is the point of row 1 below — and `run` refuses
without them (*"run needs every input"*). A scripted line written bare tests that
refusal instead of the fan-out.

Must show:

1. `plan` prints `level pipeline`, `size 6`, `askNodes 5`,
   `codes text, text, text, text, receipt`, `cost minFold 5, maxFold 5, over 1
   path` — **and prints it with the inputs ungiven**, each reported as *"not
   given; the folds below do not depend on it"* (`Cli.hs:639`). This is the
   property PAL structurally cannot have: the price is available before the
   decision has been written down.
2. `cost` prints one path and therefore one number, not a range.
3. The scripted run exits `0` at `billFresh 5` / `billMemo 5` **and the three
   seats receive three different canned answers.** Exit `0` alone is not
   acceptance here: a scripted table matches the first entry whose key is a
   prefix of the prompt, so a roster whose seats shared an opening chunk would
   have one canned answer serving all three and the fan-out would be untested by
   the gate that exists to test it (`plan.md` Gate C-b, and `confer-design.md`
   §7's fifth open question — the document has no §7.5; §7 is a numbered list).
4. The live run exits `0` at `billFresh 5`, writes `confer-<date>.md`, and that
   file opens with the provenance paragraph reproduced word for word, its
   backend-count conditional **unresolved** — not resolved *toward* the
   single-backend reading either, because the reporter is never shown the header
   and `conferWriteBrief` forbids it from guessing (see P2b) — followed by three
   blocks under `for`, `against`, `neutral`, each in the party's own words and
   unedited, followed by a recommendation that is attributed and marked as one
   reading of the blocks rather than their sum.

**Status: Stage C.** This is `plan.md` §3's **A5**, with Gates C-a, C-b and C-d
folded into the row as the runs they are.

---

### P2b — `consensus` → `confer`, across providers

**Counterpart.** The same program, byte for byte. That is the row's entire
claim.

**Must exist.** Stage R **and** Stage C — the only row in the matrix that needs
both.

**Acceptance run.**

```
wf run confer --require-pinned --engine acp --adapter claude \
  --route 'gemini-3.1-pro-preview=deck:gemini-pane' \
  --route 'gpt-5.5-pro=acp:codex' \
  --input-arg decision='…' --input-file context=./…
```

Must show: the roster **unchanged from P2a's run, byte for byte** — this is the
row that proves the design constraint was met; a header naming **3 backends**,
deduplicated, with the default named first and what falls to it stated, and the
pinned models no `--route` claims printed on their own line; and the provenance
paragraph reproduced word for word, its backend-count conditional left
**unresolved** — see the deferral below.

**The provenance clause — DEFERRED, and owed back to this repository.** This row
originally asked for a provenance line *"whose single-backend disclaimer is now
**absent**, because the header contradicts it"*. That criterion is **not met
today, and it is not met because the fact it needs is not supplied**: the run
header is printed by the runner and **no party is ever given it**, so a reporter
asked to drop the disclaimer would be deciding the backend count of a run it
cannot see.

**It is deferred rather than impossible, and the deferral's own source says so.**
`agent-workflows/doc/followups.md`, **F1-followup**, records the current
behaviour as *"a repair, not a fix"* and names the fix: *"for the runner to bind
the backend count as a fact prompts can carry (an agent-cat `Registry` / CLI
request…), at which point provenance can state what the run did. Until then:
unresolved by design."* The same follow-up asks that the fact carry the run's
**engine and session policy** too, because the paragraph turns on a second
header-only condition — whether the seats shared one conversation, which is
false of `--engine acp` and true of a deck session. So the mechanism is
identified, unbuilt, and owed **to this repository**: it is an agent-cat request,
not an agent-workflows one, and it is not in Stage R's scope.

What ships today is the forbid: `conferWriteBrief` refuses to resolve either
conditional — *"Do not resolve either condition in either direction. You cannot
know how many backends answered this run or which engine it was pointed at — the
run's header is the authority for both and it is not in front of you"*
(`agent-workflows/src/Workflows/Rubrics/Stances.hs:431`–`:436`; the same forbid
is carried by `conferBareWriteBrief` at `:464`–`:469`). Verification earned it:
a one-backend run resolved the conditional by guess and got it right by luck,
and a two-backend run copied it unresolved. So:

- **The artefact carries the provenance conditional UNRESOLVED, by design.** It
  is constant text in every run, single-backend or not, and a `confer-<date>.md`
  that had resolved it would be the defect, not the acceptance.
- **The run header is the runtime authority on backend count.** A reader who
  wants to know whether two blocks were answered by different backends reads the
  header — which is exactly what the provenance paragraph's closing sentence
  tells them to do — and not the artefact's opinion of itself.

The acceptance criterion for this row is therefore: **the header names 3
backends, and the artefact's provenance paragraph is byte-identical to P2a's.**
The two facts live in the two places that can honestly hold them.

Two preconditions the run must state rather than assume: an agent-deck session
titled `gemini-pane` must exist — **the gemini CLI is absent on this machine**
(`pal-vs-agent-cat.md`), so this run cannot be executed here as written until
that session exists or the route is repointed — and per `plan.md` §0.2 the note
recording this run must distinguish backends **configured** from backends
**reached**, because `gpt-5.5-pro` is a spare of `reasoning` and `lateral` and
answers only on a fail-over.

**Status: R + C — graded.** The **capability is green**: routing exists, the
multi-backend header is Stage R's, and the program is the same registered row as
P2a's — a `--route` is a command-line flag and not a program edit, so "unchanged
byte for byte" is structural here rather than something the run has to discover.
The **provenance clause is deferred**, not met and not withdrawn — the fact it
needs is one the runner could supply and does not, recorded as F1-followup and
owed to this repository, and until it is supplied the write briefs forbid
guessing it. The **run itself is not yet executed on this machine**, gemini CLI
absent.
This is `plan.md` §3's **A6** with its provenance sentence amended here; §3's
command line and its other evidence requirements stand unedited.

---

### P3 — `thinkdeep` → no program of that name; two halves, two owners

**Counterpart, split honestly.** PAL's `thinkdeep` does two things and the
corpus uses it for both:

- **"Consult the strongest reasoning models on a hard question"** — `forge`
  phase 1's actual use. Counterpart: `confer`, `debate`, `secondOpinion`.
- **"Fill in a step-numbered investigation form"** — the `step_number` /
  `findings` / `confidence` scaffolding. Counterpart: **not a program named
  `thinkdeep`**. Its agent-cat expression is a `revisingOn` whose
  settle/amend/abandon comes from a verdict, a `decide` that reads a gate for
  zero questions, and a `toolExec` receipt the world authored — and those are
  the ai-config workflows track's to build from the owner's own command corpus.

**Must exist.** Stage C for the first half; nothing here for the second.

**Acceptance run.** P2a's run for the first half. For the second, the criterion
is **negative and it is a real gate on this track's reviewers**:

```
wf list
```

must contain no row named `thinkdeep`, `debug`, `codereview`, `analyze`,
`planner`, `precommit` or `refactor`. This track has invented no workflow named
after a PAL tool; `confer` is named for the shape and for the owner's own word
in `heavy` and `wiggum`.

**Status: Stage C (first half) · out of track (second half).** This is
`plan.md` §3's **A10** applied per row rather than in bulk.

---

### P4 — `debug` → the `green` family. **Green before this wave.**

**Counterpart.** `green-ci`, `green-tree`, `green-flaky`, registered in
`Workflows.Registry` today: *"sweep the bot threads, then repair until
`gh pr checks` exits 0"*, *"repair the working tree until `nix flake check`
exits 0"*, *"three drawn runs, a repair loop, and a fourth draw that says flaky
or broken"*.

The structural difference is the whole argument of this track. PAL's `debug`
asks the caller to self-report `findings` and `confidence` into typed slots;
`green-tree` asks the *world* whether `nix flake check` exited 0, and the answer
is a receipt the run did not author. `green-flaky`'s fourth draw is `drawing` —
*two draws of one prompt are two questions, which is what the memo bill prices
apart* — which is a statement about flakiness the language can price.

**Must exist. Nothing.** Landed, registered, gated.

**Acceptance run** — a citation, not a new execution:

```
./ci/workflows.sh          # in agent-workflows, inside the devShell
```

Must show `green-ci`, `green-tree` and `green-flaky` at their pinned `level`
and `paths` by **equality**, their `costMax` under its **ceiling**, and a
`--scripted` run at exit `0` for each. 21 pinned, 0 failed.

**Status: green before this wave.**

---

### P5 — `codereview` → the `review` ladder. **Green before this wave.**

**Counterpart.** `review-quick`, `review-deep`, `review-sec`, `review-heavy`,
registered today: one lens over a frozen snapshot; the language roster, perf and
the four required skill lenses over receipts; the same plus the security lens;
*"the seven independent passes of `heavy-review`, over one snapshot"*. Four
rungs, four rosters, four prices — which is precisely what a registry row should
differ in.

**Must exist. Nothing.**

**Acceptance run.**

```
wf plan review-heavy --require-pinned
./ci/workflows.sh
```

Must show: `--require-pinned` refuses nothing, so every lens in the heaviest
rung is pinned through a ladder before a token moves; and the four rows green at
their pinned numbers.

**One caveat, and it is P1b.** `heavy-review`'s *validated* pass is the one
place the corpus wants an attested returned identity, and this row does not
supply it. `review-heavy` is parity with `codereview`; it is not parity with
`validated-code-review`.

**Status: green before this wave, with residual #4 noted against it.**

---

### P6 — `analyze` → `fess` for the audit half, `confer` for the architecture half

**Counterpart.** PAL's `analyze` is used in the corpus for two different things.
The **audit** shape — an artefact examined against a fixed taxonomy — is `fess`:
*"eleven sin categories as eleven independent stances over three receipts"*,
registered and gated today, and structurally the same fan-out `confer` uses. The
**architecture-analysis** shape — `forge` phase 1's use — is `confer` over a
design document.

**Must exist.** Nothing for the audit half; Stage C for the other.

**Acceptance run.**

```
wf run fess --scripted                     # and ./ci/workflows.sh for its pinned row
wf run confer --require-pinned --engine acp --adapter claude \
  --input-arg decision='<the architectural question>' \
  --input-file context=./doc/design/<the document>
```

Must show: `fess` at its pinned `level` and `paths` with eleven stances
distinctly **asked** — `billMemo 16`, and a memo bill counts *distinct
questions*, so eleven separate stance prompts were put. Not eleven distinct
*answers*: under `--scripted` the eleven share one canned reply by design, which
is what a scripted table is for, and a run that read eleven different answers
out of it would be reading the gate wrong. Then the confer artefact locating
**disagreement between the seats** and saying what turns on it — which is the
thing a single `analyze` call cannot produce, because there is only one of it.

**Status: green before this wave (audit) · Stage C (architecture).**

---

### P7 — `planner` → no counterpart row today. **Out of track.**

**Counterpart.** None registered. The owner's own words for this shape are
`breakdown`, `infer-tasks`, `halt` and `report`, and they are commands, not
workflows. The *choose between plans* half is `confer` and `debate`; the
*decompose a task into ordered subtasks* half has no row.

**Must exist.** Nothing in this track. This is the ai-config workflows track's,
built from the owner's own command corpus.

**Acceptance run.** Negative, per P3: `wf list` contains no row named `planner`.
The positive row, when it lands, is that track's to gate.

**Status: out of track — and this matrix says so rather than letting `plan.md`
§3's A10 be read as coverage.**

---

### P8 — `precommit` → the `commit` and `stack` families. **Green before this wave.**

**Counterpart.** `commit`, `commit-push`, `commit-recommit`,
`commit-bankruptcy`, `stack`, `stack-rebase`, `stack-rebase-fix`,
`stack-cleanup` — eight registered rows. `commit` is *"the working tree as an
atomic, ordered series, gated on `make test`"*; `commit-recommit` is *"the same
series, each commit held to standalone CI (three repair trips)"*;
`stack-rebase` *"proves nothing was lost"*.

This is the sharpest of the already-green rows. PAL's `precommit` asks the
caller to report that the tests pass. `commit` **gates on `make test`** and
`commit-recommit` **holds every commit to standalone CI** — receipts the world
authored, at a bounded number of repair trips the plan prices in advance. The
honour system is replaced by a term.

**Must exist. Nothing.**

**Acceptance run.**

```
wf plan commit-recommit
./ci/workflows.sh
```

Must show `commit-recommit`'s `level` and `paths` by equality — the three
repair trips are visible in the path count, which is what makes "three trips" a
design decision a gate watches rather than a sentence in a prompt — and its
`costMax` under its ceiling.

**Status: green before this wave.**

---

### P9 — `refactor` → no counterpart row; expressible as a lens. **Out of track.**

**Counterpart.** None registered. The owner's words are `simplify`,
`ponytail-review`, `eliminate-dead-code` and `bankruptcy` (which *is* a
registered commit rung). The agent-cat expression of `refactor` is not a program
— it is a `Lens` in a `review` roster with a different `lensOwns` and
`lensBrief`, which is a two-line addition to an existing table when somebody
wants it.

**Must exist.** Nothing in this track.

**Acceptance run.** Negative, per P3.

**Status: out of track — declined by name, expressible as a lens.**

---

### P10 — `clink` → the engine layer. **Green before this wave; re-run as Stage R's control.**

**Counterpart.** `--engine acp --adapter claude|codex` and `--engine deck
--session <id>`. Forwarding a prompt to a CLI with a role preset is what this
*is*, plus types, pricing and a trace. Role presets are parties with rubric
prompts.

**Must exist.** Nothing. Stage R re-runs it as R3's own control, because the
`Target` refactor must not move it.

**Acceptance run.**

```
agentic-run run harden --engine acp --adapter codex
agentic-run run harden --engine acp --adapter claude
```

Must show: the same program, priced identically, reaching either CLI, with a
trace and a bill `clink` has no analogue for. Re-run unedited after R3;
`ci/acp.sh` scenarios 1–12 must stay green with **not one assertion edited**.

**The bills are graded either-branch, and this is not a weakening.** The flagship
ends by asking a **person** whether to apply the patch, and in a live run that
person is a real one behind a real adapter. Both answers are correct: *yes* is
seven consultations and a written `applied.c`; *no* is six and nothing written —
`ci/acp.sh` scenario 2 pins that second branch as right behaviour and
`Harden.bill_refuse_demo` is the theorem it comes from. Nothing about the command
line decides which comes back, so **`billFresh 7` / `billMemo 7` is not the
criterion; landing squarely on one branch is**: either `7/7` with `applied.c`
written, or `6/6` with it absent, and never a mixture. That is exactly how
`ci/route-live.sh` grades it (`ci/route-live.sh:79`–`:106`, `want_owner_branch`),
and this row is graded the same way so that the two agree. A run asserted at
`7/7` alone would fail a well-behaved *no*.

**The parity is exact, including the limitation.** The corpus's own
`validated-code-review` rejects `clink` because *"the CLI preset owns its
model"* — which is precisely true of `--adapter` as well. Two surfaces with the
same honest shortfall are at parity; see P1b.

**Status: green before this wave.** This is `plan.md` §3's **A3**.

---

### P11 — `apilookup` → an ask to a web-capable party

**Counterpart.** A doc lookup is not a language concern. An adapter session can
search; the question is an ordinary ask; local searxng covers the same need
outside any workflow entirely.

**Must exist.** Nothing new. To run it *as a workflow* rather than as a bare
ask, `secondOpinion` must exist (Stage C) — that is the row's only dependency
and it introduces no code of its own.

**Acceptance run** — P1's program at a lookup question:

```
wf run second-opinion --engine acp --adapter claude \
  --input-arg decision='What is the current signature of <API>, and what changed in the last release?' \
  --input-file context=./<the calling code>
```

Must show: exit `0`, `billFresh 2`, and an artefact whose answer cites what it
found. Acceptance is that it works as an **ordinary ask** — there is nothing to
build and nothing special about it, which is the finding.

**Status: green today outside a workflow · Stage C as a registered run.** This
is `plan.md` §3's **A9**.

---

### P12 — `challenge` → one rubric define

**Counterpart.** `challengeRubric` (`confer-design.md` §1.1): a `[wf|…|]`
constant of a paragraph, spliced into every confer seat and into
`secondOpinion`, and standing **second** — after each seat's stance — which is
the ordering rule that keeps the scripted table honest (P2a, assertion 3).

**Must exist.** Stage C: the define, in whatever module home the ai-config
architecture phase rules.

**Acceptance run.** None of its own, and that is correct. Its evidence is P1's
and P2a's transcripts, in which the paragraph appears in every party's prompt.
The mechanical criterion:

```
grep -rn 'challengeRubric' agent-workflows/src/Workflows/
```

must show **one definition and every party's call site** — one binding read by
every party in the tree, rather than a wrapper prompt typed per call. A second
definition is the parallel-implementation shape this repository's review
discipline exists to catch.

**Status: Stage C.** This is `plan.md` §3's **A2**, with the grep added as the
criterion §3 states in prose.

---

### P13 — `listmodels` / `version` → `--require-pinned` and the run header

**Counterpart, in two halves with two dates.**

- **The pre-flight half.** `wf plan <name> --require-pinned` refuses a program
  that leaves any model ask without a `served by`, **before a plan is printed or
  an adapter started** (`Cli.hs:486`–`:493`, `Guards.hs:424`). PAL's nearest
  equivalent is a `listmodels` call the caller has to remember to make — and
  `forge` and `validated-code-review` both remember it in prose, which is the
  definition of a convention rather than a guard. **This half is green today.**
- **The header half.** Who is answering, under what policy, before a token
  moves. Today's single-backend header already says it; the multi-backend header
  is Stage R.

**Must exist.** Nothing for the first half; Stage R for the second.

**Acceptance run.**

```
wf plan confer --require-pinned                                        # green today
agentic-run run harden --engine acp --adapter claude --route 'deep=acp:codex'
```

The header must be **true and complete**, which is six things
(`routing-design.md` §5.2): backends counted **deduplicated**, so the count is
processes and not route lines; the default named first with what falls to it
stated; **the pinned models no `--route` claims printed on their own line**, so
a mistyped route reads as a mistyped route and not as an absent one; the
working-directory lines kept; the chain lines kept; and **no claim that any
backend answered anything** — the header states policy before the run, and only
the trace states outcome.

Plus the negative control the same command buys free:
`--route 'author=acp:codex'` must be **refused at exit 1**, because `author` is
a party and not a pin — the resolution rule defended at the command line, where
an operator will actually make the mistake.

Both are `ci/route-live.sh`'s: the second line above is its `two-providers`
scenario, whose first assertion is the header (`ci/route-live.sh:148`–`:153`),
and the refusal is its `route-a-party` control (`:205`–`:209`). **Three of the
six requirements are asserted and three are not**, and the row should say which:
the script pins the deduplicated count, `deep` on the codex line and the
default's remainder sentence, and `ci/acp.sh`'s `unclaimed-pins` scenario pins
the unclaimed-pins line at no cost in tokens. The working-directory lines, the
chain lines and the absence of any answered-by claim are **not** asserted by any
gate; they are properties of what `sayBackends` prints, and a reader who wants
them checked reads the header. The evidence for the three that are asserted is
the committed log, `doc/research/pal-subsumption/route-live-log.txt`.

**One caution carried forward.** PAL's `version` reports its *client's* working
directory as its installation path and suggests `git pull` there; on this
machine that pointed at `agent-cat` itself. Do not follow it. Nothing in
agent-cat has an analogous failure because nothing in agent-cat reports an
installation path.

**Status: green before this wave (pre-flight) · Stage R (multi-backend header).**
This is `plan.md` §3's **A8**.

---

### P14 — `continuation_id` → session policy. **Green before this wave, negatively.**

*Not a tool; a parameter. Included because `plan.md` §3 carries it as A7 and
because the corpus works hard to defend against it.*

**Counterpart.** `acpFreshPerQuestion = True` (`Acp.hs:331`), which the CLI
never overrides — `acpConfigFor` (`Cli.hs:877`–`:884`) is the only place the CLI
builds an `AcpConfig`, and it sets the working directory, the turn timeout and
verbosity and nothing else. Every question is a fresh session: none
sees another's answer, none inherits a transcript. Multi-turn context with the
same model is an engine setting, not a server-side thread — and unlike PAL's
thread, **what was said is in the trace**.

The corpus's own defence makes the point better than the design does:
`validated-code-review` runs a *sentinel probe* against every roster model to
prove no parent history leaked, and forbids `continuation_id` on every call.
That is a runtime check standing in for a structural property. agent-cat has the
structural property, so it needs no probe.

**Must exist. Nothing.** And per `plan.md` §0.3 this is a **coupling of facts**
neither stage owns alone: no flag exposing `acpFreshPerQuestion = False` may
land in either stage, because Stage R's adapter deduplication and Stage C's
independence-of-context claim both rest on it, and if one ever moves they both
move in the same commit.

**Acceptance run.** The criterion is negative, and that is the point — there is
nothing to observe, only something that must be absent. It has two readings, and
only one of them exists today. **Today:** the committed log of this track's one
live run, `doc/research/pal-subsumption/route-live-log.txt`, is the record of a
run under `--engine acp` in which no question saw another's answer; the property
is structural (`acpFreshPerQuestion = True`, `Acp.hs:331`, which the CLI never
overrides), so what the log evidences is that a real two-provider run behaved as
the structure says and needed no sentinel probe to establish it. **At Stage C:**
P2a's live run reads the same property at five questions and five `session/new`
calls. Until that run happens, this row's evidence is the structure and the
committed log, and not P2a's numbers.

**Status: green before this wave.** This is `plan.md` §3's **A7**.

---

### P15 — cross-backend fan-out in one run. **The residual the track closes.**

*Not a PAL tool either; it is `pal-vs-agent-cat.md`'s residual #1, the single
thing PAL could do that the runner could not, and the reason Stage R exists.*

**Counterpart.** `--route NAME=BACKEND`, repeatable, keyed on the **serving
model** and never on the party (`routing-design.md` §2.2).

**Must exist.** Stage R, entire: `Agentic.Route`, `withAcps`, the `Routed`
refactor, the flag and its five refusals, the header, the probes, the smoke.

**Acceptance run.** It is not typed by hand: it is `ci/route-live.sh`, which is
this command plus its two negative controls and every assertion below, and which
is **manual on purpose** — it spends real money on real accounts, so no
automatic lane calls it.

```
./ci/route-live.sh          # runs, among others:
agentic-run run harden --engine acp --adapter claude --route 'deep=acp:codex'
```

Five assertions in the order they discriminate (`routing-design.md` §7.4,
`ci/route-live.sh:121`–`:177`): the header names **2 backends**, one
`claude-agent-acp` and one `codex-acp`, with `deep` on the codex line; **two
adapter processes during the run and none after**, checked at the bracket rather
than at the timeout; **the flagship's frozen numbers, unchanged on whichever
branch the owner chose**, which is the semantics-untouched invariant observed on
the wire rather than argued; the announced consultations name the parties and the
draft is visibly a different voice from the reviews; exit `0`. Plus the two
controls the script carries: the same command with `--route` removed is today's
run and today's header, and `--route 'author=acp:codex'` is refused at exit 1.

**The bills are graded either-branch, exactly as in P10.** The flagship's last
question goes to a **person**, and a live person may say either thing: *yes* is
`billFresh 7` / `billMemo 7` with `applied.c` written into the one shared
directory both providers were pointed at, *no* is `6/6` with it absent. What is
pinned is that the run landed squarely on one branch and that the bills and the
act agree — `want_owner_branch` (`ci/route-live.sh:79`–`:106`) is that
assertion, and a criterion of `7/7` alone would fail a well-behaved *no*.

**Status: Stage R.** This is `plan.md` §3's **A4**, and the committed log of the
run — `doc/research/pal-subsumption/route-live-log.txt` — is what closes
`acat-engine-party-routing-hcx`.

---

## 2. The parity ledger

The at-a-glance answer to *when is "I could avoid PAL" simply true*.

### Green before this wave — nothing to build, seven rows

| row | counterpart | acceptance |
|---|---|---|
| P4 `debug` | `green-ci` / `green-tree` / `green-flaky` | `./ci/workflows.sh` — pinned rows green |
| P5 `codereview` | `review-quick` / `-deep` / `-sec` / `-heavy` | `wf plan review-heavy --require-pinned`; the gate |
| P6a `analyze` (audit) | `fess` | the gate's `fess` row |
| P8 `precommit` | `commit` / `commit-push` / `commit-recommit` / `commit-bankruptcy` / `stack` / `stack-rebase` / `stack-rebase-fix` / `stack-cleanup` | `wf plan commit-recommit`; the gate |
| P10 `clink` | `--engine acp --adapter …` / `--engine deck` | `agentic-run run harden` at either adapter, on one owner branch: `7/7` with `applied.c` or `6/6` without |
| P13a `listmodels` (pre-flight) | `--require-pinned` | `wf plan confer --require-pinned` |
| P14 `continuation_id` | `acpFreshPerQuestion = True` | structural (`Acp.hs:331`); the committed `route-live-log.txt` is the live run it held in |

### Turn green at Stage R — two rows

| row | what turns it | acceptance |
|---|---|---|
| P15 cross-backend fan-out | `--route` | `ci/route-live.sh`, five assertions, the bills unmoved on whichever branch the owner chose; the committed `route-live-log.txt` |
| P13b the multi-backend header | `routing-design.md` §5.2 | the same run's header: 6 requirements, plus the `author=` refusal at exit 1 |

### Turn green at Stage C — six rows

| row | what turns it | acceptance |
|---|---|---|
| P1 `chat` | `second-opinion` | plan `2/3/pipeline`; live run at `billFresh 2` with an artefact |
| P2a `consensus`, one backend | `confer` | plan/cost/scripted/live — four runs, four properties |
| P3a `thinkdeep` (consult half) | `confer`, `debate` | P2a's run |
| P6b `analyze` (architecture half) | `confer` over a design doc | the artefact locates disagreement |
| P11 `apilookup` | `secondOpinion` at a lookup question | works as an ordinary ask |
| P12 `challenge` | `challengeRubric` | one definition, every call site |

### Turns green only at R + C — one row

| row | acceptance |
|---|---|
| P2b `consensus`, across providers | the roster unchanged byte for byte from P2a, a header naming 3 backends, the provenance paragraph reproduced with its conditional **unresolved** (the "disclaimer absent" clause is deferred, not withdrawn — F1-followup, see P2b), configured distinguished from reached |

### Out of track — three rows

Owned by the ai-config workflows track, built from the owner's own command
corpus. Their acceptance criterion **here** is negative: `wf list` names none of
them.

| row | why | nearest thing today |
|---|---|---|
| P3b `thinkdeep` (step-numbered form) | a form, not a shape | `revisingOn` + a gate + a receipt, unbuilt |
| P7 `planner` | no registered row | `breakdown`, `infer-tasks`, `halt`, `report` — commands, not workflows |
| P9 `refactor` | no registered row | a `Lens` in a `review` roster, two lines when wanted |

### Declined on principle — one

**Automatic model selection.** A program that does not know who answers cannot
honestly price or attribute, and a guard that refuses an unpinned model ask
cannot coexist with a system whose selling point is that asks are unpinned. The
`servedBy` ladder is the principled fragment. Not a gap.

### Accepted residuals — four

1. **Inline images.** PAL's `chat` takes base64 screenshots; asks are text. The
   working answer is that adapter sessions have a working directory and the
   claude CLI reads images from it, so *"look at ./screenshot.png"* expresses
   it. A convention, not a surface feature. **One real caller in the corpus:**
   `commands/transcribe-image.md`.
2. **Auto model selection.** Declined above. Listed here only because
   `pal-vs-agent-cat.md` lists it as a residual.
3. **Per-call temperature and effort knobs.** Configuration, not capability;
   reachable through adapter arguments today and through a two-line wrapper
   script per route after Stage R.
4. **Attested returned model identity (P1b). New in this document.** PAL
   returns `metadata.model_used`; agent-cat's trace deliberately carries no
   backend field. `validated-code-review` therefore keeps PAL, and under the
   owner's ruling that is a correct outcome.

### The one-sentence answer

**"I could avoid PAL if I wanted to" becomes true for the dominant habit —
`consensus`, which is four of the corpus's PAL call sites and the whole of
`heavy`, `wiggum`, `forge` and `review-github-pr` — on the day Stage C's
acceptance runs pass, single-backend.** It becomes true *with cross-provider
independence* on the day P2b's run passes, which needs both stages. It is
already true today for `debug`, `codereview`, `precommit`, `clink`,
`continuation_id`, the `listmodels` pre-flight and the audit half of `analyze`.
It never becomes true for `validated-code-review`'s attestation contract, and
that is by design, not by omission.

---

## 3. Reconciliation with `plan.md` §3, applied explicitly

§3's rule, quoted so that its application can be checked:

> **the matrix is the roster of rows** — if it names a parity claim absent
> below, that claim is added here and the track is not done until it has a run.
> **This section is the acceptance criterion** — a row the matrix states as a
> correspondence is not done until the command below has been executed and its
> evidence recorded. Where the two differ on a row's *wording*, keep this
> section's; where they differ on a *capability*, the matrix wins and this plan
> is amended rather than the matrix.

### 3.1 Rows §3 lacks — the matrix wins; §3 is amended

**(a) P1b — attested returned model identity.** §3 has no row for it and its
residual list has three entries, not four. This is a **capability** finding: the
matrix asserts that agent-cat is *weaker* than PAL here and weaker on purpose.

> **Amendment to `plan.md` §3 — applied, see §3.5.** The residual list "The
> three residuals, restated as accepted rather than closed" becomes **four**
> (and its heading now reads "The four residuals"), gaining:
> *"**Attested returned model identity.** PAL's `chat` returns
> `metadata.model_used` and the owner's `validated-code-review` skill aborts on
> a mismatch. agent-cat's trace carries no backend field by design
> (`routing-design.md` §4.2 tables the structures; §4.4 gives the reason), so the
> run can attest the pin and the configured backend but not the answering
> weights. That skill keeps PAL. **Accepted.**"*
> And §3's closing "Done, stated once" sentence changes *"the three residuals
> acknowledged in writing"* to *"the four residuals"*.

No new acceptance **run** is owed: P1b's criterion is documentary, and it is
satisfied by this section plus the amendment above.

**(b) P4, P5, P6a, P8 — four rows that are already green and that §3 cannot
see.** §3's **A10** sweeps all seven guided investigations into *"explicitly out
of this track"* with a purely negative criterion. That is **correct about this
track's build scope** and **silent about parity status** — and the silence
matters, because it is the difference between a ledger that can answer the
owner's question and one that cannot.

The reason §3 is silent is visible elsewhere in the plan: **§2.2 states that
`Workflows.Registry` is one row today (`hello`)**. It is twenty-one, across
seven families — `hello`, four `review-*` rungs, three `green-*` rungs, four
`commit*` rungs, `fess`, four `stack*` rungs and, since Stage C, four confer
rungs (`confer`, `confer-bare`, `debate`, `second-opinion`) — gated by
`ci/workflows.sh` at 21 pinned, 0 failed. Four PAL rows already have registered,
gated counterparts that §3 could not have counted.

> **Amendment to `plan.md` §3 — applied, see §3.5.** A10 **keeps its negative
> criterion verbatim** (§3's wording wins, see 3.3) and gains one sentence:
> *"Four of the seven
> already have registered, gated counterparts in `agent-workflows` today —
> `debug` → the `green` family, `codereview` → the `review` ladder, `analyze`
> (audit) → `fess`, `precommit` → the `commit` and `stack` families — whose
> acceptance is a citation of `ci/workflows.sh` and not a new run. Three do not:
> `thinkdeep`'s step-numbered form, `planner` and `refactor`."*

This adds **no work** to the track. It adds four citations to the done
statement, without which the ledger's "green before this wave" column is
unevidenced.

**(c) P15 as a row of its own.** §3 carries cross-backend fan-out as **A4**, an
acceptance run, but not as a *parity row* — it is residual #1 of
`pal-vs-agent-cat.md` rather than a PAL tool. The matrix promotes it to a row
because it is the thing the ledger's "R" column is about. Not a conflict; a
promotion. §3's A4 stands unedited as its acceptance.

### 3.2 The capability disagreement — the matrix wins

**A10 read as coverage.** If A10 is read as *"the seven guided investigations
are handled elsewhere, therefore parity on them is somebody else's problem"*,
the matrix disagrees on capability: four of them are **already at parity today**
and three of them are **not at parity and have no row**. The matrix's per-row
verdicts (P3, P4, P5, P6, P7, P8, P9) win, and §3 is amended per 3.1(b). A10's
*prohibition* — that this track invents no workflow named after a PAL tool — is
untouched and is strengthened by being stated per row.

### 3.3 Wording differences — §3 wins, recorded so the difference is not lost

| where | §3's wording | the matrix's | ruling |
|---|---|---|---|
| **A8** | *"`listmodels`/`version` → the run header. **(both stages)**"* | the pre-flight half (`--require-pinned`) is **green today**; only the multi-backend header is Stage R | **§3's wording stands** — its *acceptance run* genuinely spans both stages, since it reads A4's and A6's headers. The matrix's split is finer detail beneath the same label, not a contradiction. P13 records both. |
| **A9** | *"`apilookup` → an ask to a web-capable party. **(Stage C, no new code)**"* | running it *as a workflow* requires `secondOpinion`, which is Stage C code | **§3's wording stands.** "No new code" means *this row* contributes none — it reuses A1's program entirely — which is true and is what the matrix says in longer form. |
| **A2** | *"No run of its own"* | adds `grep -rn 'challengeRubric'` as the mechanical criterion | **§3's wording stands**; the grep is the prose criterion made executable, which §3 already asks for in words (*"one binding read by every party in the tree"*). Not a conflict. |
| **A5 / Gates C-a, C-b, C-d** | three separate gates plus one acceptance run | folded into P2a as four commands of one row | **§3's wording stands.** The matrix's folding is presentational; every one of §3's four commands survives with its own assertion. |

### 3.4 What §3 has that the matrix does not dispute

A1, A3, A4, A6, A7 are adopted **unchanged** as P1, P10, P15, P2b and P14. Their
command lines are §3's, their evidence requirements are §3's, and where this
document restates them it restates them in §3's words. §0.2's
configured-versus-reached discipline and §0.3's `acpFreshPerQuestion` coupling
are carried into P2b and P14 respectively, because both are acceptance
conditions and not merely design notes.

### 3.5 The note at the head of `plan.md`

> *"When the matrix lands, §3 is reconciled against it and this note is
> deleted."*

The matrix has landed. §3 is reconciled above: **two amendments** (3.1(a) and
3.1(b)), **one promotion** (3.1(c)), **four wording rulings all in §3's favour**
(3.3), and **no capability of §3 overturned**.

**And the reconciliation has been performed in `plan.md`, not merely declared
here.** Three edits land in that document with this commit:

1. **The head note is replaced.** The paragraph beginning *"One document this
   plan could not read"* is gone; in its place is a note recording that the
   matrix landed, that §3 is reconciled, that both amendments have been applied,
   and where the reconciliation is written down — this section.
2. **3.1(a) applied.** *"The three residuals, restated as accepted rather than
   closed"* is now **the four residuals**, gaining "Attested returned model
   identity" as item 4 in the words of the amendment above, and the closing
   "Done, stated once" sentence now reads *"the four residuals acknowledged in
   writing"*.
3. **3.1(b) applied.** A10 keeps its negative criterion verbatim and gains the
   paragraph naming the four already-green counterparts and the three that are
   not, marked as added by this reconciliation.

One further correction was made in `plan.md` while applying these, and it is not
a reconciliation ruling but a defect: **A1's command line said
`wf run secondOpinion`, which `wf` refuses by name** — the registry row is
`second-opinion`. It is corrected there as well as in P1, so that §3.4's claim
that these rows' command lines are §3's remains true of lines that run. Gate
C-b's `wf run confer --scripted` gained its two inputs for the same reason.

---

## 4. What this matrix is not

**It is not a migration plan.** There is no row that says "stop calling PAL",
no counter, and no date by which a PAL call becomes a defect. `plan.md` §5 is
the governing sentence and this document adds nothing to it: *the deliverable is
capability, not substitution.*

**It is not a claim that every row is equally worth building.** §0's weighting
is the honest reading: `consensus` is the habit, and a track that landed
`confer` and nothing else would have delivered most of the value. The rows that
are already green are already green, and the rows that are out of track are out
of track because another track owns them and not because they do not matter.

**It is not a scorecard against PAL.** One row — P1b — records PAL as
**stronger**, and it is the row the owner's most rigorous review skill depends
on. A parity matrix with no such row would be an advertisement.
