# The PAL-parity track: the implementation plan of record

*2026-08-19. The plan the designs under this directory fold into —
`routing-design.md`, `confer-design.md` and `parity-matrix.md` — read against
`doc/research/pal-vs-agent-cat.md`, which is the analysis this whole track
executes, and against `agent-cat` at pushed `2f86fda` with every gate green.*

> **One document this plan could not read.** `parity-matrix.md` had not been
> written to disk when this plan was composed (the directory held
> `routing-design.md` and `confer-design.md` and nothing else, polled over nine
> minutes). §3's acceptance runs are therefore derived **directly from
> `pal-vs-agent-cat.md`'s own feature-by-feature correspondence** — which is the
> matrix's source as well as this plan's — one row per PAL tool family, and a
> reconciliation rule is stated at the head of §3. **When the matrix lands, §3
> is reconciled against it and this note is deleted.** Every other section of
> this plan reads the two designs that exist and is unaffected.

*The owner's ruling, stated once at the top because it governs every section
below: **PAL MCP stays configured.** There is no removal activity, no config
edit, no migration checklist, and no deprecation. The deliverable of this track
is **capability** — that the owner can avoid PAL with an ordinary workflow
whenever they want to, and reach for it when they want that instead. Both
sentences stay true on the day the track is done.*

---

## The ruling, in one page

**Two stages, and they are independent by design.** Stage R lands
party→backend routing in the engines (`acat-engine-party-routing-hcx`), so one
run reaches several model backends. Stage C lands the `confer` workflow — a
roster of parties, stance rubrics, a document fold, a synthesis — as the
workflow-shaped counterpart of PAL's `consensus`. Stage C needs **nothing**
from Stage R: it is single-backend-runnable and useful the day it is written,
and cross-backend the day Stage R lands, *with the roster unchanged*. Stage R
needs nothing from Stage C: `harden` is already the fixture and already the
smoke. Either may go first; neither blocks the other.

**One invariant spans both.** The semantics do not move. Stage R is confined to
`WorldIO`, a layer no conformance executable imports; Stage C adds programs to
a registry that is deliberately not the examples registry. The check is stated
as a check and not as a claim (§1.4), and it is the one check in this plan whose
scheduling the coordinator must actively protect (§4.4).

**The conflicts between the three designs are two, both small, both resolved in
the routing spec's favour** (§0). Nothing in the confer design assumes a routing
surface the routing spec does not provide; what it assumes it may get more
cheaply than it expects, and §0.2 says where.

**The definition of done is the acceptance runs of §3**, not the landing of the
files. A stage whose files are in and whose acceptance run has not been executed
is a stage that has not shipped.

---

## 0. Conflicts between the three designs, resolved

The rule, stated before it is applied: **where the confer design assumes a
routing surface, the routing spec wins and confer adapts.** Applied, it turns
out to bind twice, and both times lightly — the confer design was written
against the routing spec and cites it correctly at §4.2 and §4.3. What follows
is the audit, not a repair.

### 0.1 Resolved: the synthesis seat and the `for` seat share a backend

**The clash.** `confer-design.md` §1.2 argues that the roster's three primaries
are distinct *on purpose*, "what makes `--route` able to put this roster on
three providers". Its §1.5 then puts the synthesis at
`reasoning (model "synthesis")` — and `reasoning`'s primary is `opus`, which is
also the `for` seat's primary (`Parties.hs:123`, `confer-design.md` §1.2).

**The ruling.** Routing keys on the serving model and never on the party
(`routing-design.md` §2.2), so **no route table can separate the `for` seat from
the synthesis.** They are one model, therefore one backend, however the run is
routed. This is not a defect in either design; it is §2.2 applied one statement
further than the confer design applied it.

**What confer does about it: nothing, by default, and the reason is written
down.** The three *panel* seats are what the roster's distinctness claim is
about, and they remain distinct. The synthesis riding the `for` seat's backend
costs the artefact nothing: the synthesis is not compared against the seats, it
reads them. If the architecture phase later wants the synthesis on a backend of
its own, the fix is one line — give the synthesis seat its own primary — and it
is a fix to `conferRoster`'s neighbourhood, not to routing. **Action for Stage
C: `confer-design.md` §1.2's haddock must say "the three panel seats", not "the
roster", so a reader routing this program is not surprised.**

### 0.2 Resolved: the four-backend demonstration routes a spare

**The clash.** `routing-design.md` §7.4 says confer "becomes the second smoke —
a roster whose `reasoning` / `broad` / `lateral` rungs pin `opus`, `fable`,
`gpt-5.5-pro` and `gemini-3.1-pro-preview`, which is a four-backend route
table". But `gpt-5.5-pro` is a primary of nothing: it is an *alternate* of
`reasoning` and of `lateral` and appears in no `servedBy` (`Parties.hs:123`,
`:133`).

**The ruling.** The routing spec is right and its own §2.3 is why: an alternate
is a model name, so it is routed like any other, and `--route`'s pinnable set is
`servedChains`' keys **plus every alternate** (`routing-design.md` §1.5). So
`--route 'gpt-5.5-pro=acp:codex'` is accepted and a four-backend table is legal.
**What it is not is four backends that answer.** A route on a spare fires only
on a fail-over, so a confer run with all four routed and nothing falling over
reaches three. The demonstration is honest only if it says so.

**Action for Stage R: `ci/route-live.sh`'s closing note and the issue transcript
must distinguish backends *configured* from backends *reached*.** This is
`conferProvenance`'s own discipline (`confer-design.md` §1.4) applied to the
smoke that demonstrates it, and the routing spec has already ruled that the
header states policy and only the trace states outcome (`routing-design.md`
§5.2, requirement 6).

### 0.3 Not a conflict, but a shared invariant neither design owns alone

`acpFreshPerQuestion` is `True` and the CLI never overrides it (`Acp.hs:330`,
`Cli.hs:1014`–`:1018`). Two independent things rest on that one fact:

- **Stage R** deduplicates adapters by spec, which is safe *only* because two
  pins sharing an adapter never share a conversation (`routing-design.md` §3.1);
- **Stage C** claims independence of context for its three seats, and its
  artefact's provenance line is written to be exactly as honest as that
  (`confer-design.md` §1.4, §4.1).

**Ruling: no flag exposing `acpFreshPerQuestion = False` lands in either stage.**
If one is ever wanted, it moves *both* — routing must disable dedup or key
sessions by pin, and confer's provenance line must stop claiming context
independence — and the two must move in the same commit. Recorded here because
it is the one coupling between the stages, and it is a coupling of facts rather
than of code, which is the kind that is discovered late.

### 0.4 Not a conflict: everything else the confer design assumes of routing

Checked, item by item, and each holds:

| `confer-design.md` says | `routing-design.md` provides | verdict |
|---|---|---|
| §4.2's route table names `gemini-3.1-pro-preview` and `gpt-5.5-pro` | §1.5's pinnable set is keys ∪ alternates; both are in it | holds |
| §4.2: `neutral`'s **first spare** falls over onto another provider | §2.3: alternates are routed, each on its own | holds |
| §4.3.3: `--route` is not part of the price | §1.1: `--route` is not a `plan`/`cost` flag | holds |
| §4.3.4: the artefact's block names are `lensName`s and do not move | routing touches no program text at all (§8.1's not-touched list) | holds |
| §3.1's `plan` numbers are the numbers before and after | same | holds |
| §4.1: the header contradicts an over-read of the pins truthfully | §5.1: a one-backend run prints today's header verbatim | holds |

One mechanical note that neither design states and an implementer needs:
Stage R's third refusal (`--route` naming a model this program never pins)
computes the pinnable set from `servedChains (progRawOut prog)`, which requires
an elaborated program. Confer is `Parameterized`, and `run` already demands
every input before it elaborates (`Cli.hs:501`), so the refusal is computable at
the point it is checked. `plan` and `cost` do not elaborate under inputs they
were not given — and they do not read `--route` either, so nothing is owed
there.

---

## 1. Stage R — party→backend routing

Closes `acat-engine-party-routing-hcx`. The design of record is
`routing-design.md`; this section is its landing order, its gates, and the
invariant stated as a check.

### 1.1 The landing order, file by file

Five landings, in this order, each green on its own before the next begins.
Sizes are the routing spec's §8.1.

**R1 — `Agentic.Route`, alone.**

| file | change | ± |
|---|---|---|
| `haskell/src/Agentic/Route.hs` | **new**: `Backend`, `Routes`, `parseBackend`, `parseRoute`, `backendFor`, `routedWorld`, dedup | +200 |
| `haskell/agentic.cabal` | `Agentic.Route` in the library's `exposed-modules` | +1 |
| `haskell/test/PolicyProbe.hs` | the pure probes for `parseBackend`, `parseRoute`, `backendFor` | +40 of the +90 |

Nothing imports it; no behaviour changes anywhere; green by construction. **This
is where the resolution rule (`routing-design.md` §2) is reviewed** — before any
wiring exists to argue about. A reviewer who disagrees with "a question is
routed by its model axis" must say so here, because after R3 it is expensive.

**R2 — `withAcps` in `Acp.hs`.**

| file | change | ± |
|---|---|---|
| `haskell/src/Agentic/Acp.hs` | `withAcps`, a fold of `withAcp`, beside it and exported | +15 |

Fifteen lines, unused, `-Wall`-clean because it is exported. Green.

**R3 — the `Routed` refactor at an empty route table. This is the risky one.**

| file | change | ± |
|---|---|---|
| `haskell/src/Agentic/Cli.hs` | `Target` becomes `Scripted \| Routed Routes`; `runCmd`'s three arms become two; `forbid` generalizes over the set of schemes the run uses | +120 / −60 |

**No new flag.** Today's behaviour expressed in the new shape:
`--engine acp --adapter X` builds `Routed (Routes (BackendAcp …) [])`, and the
single-backend header prints today's words **verbatim**, including
"every addressee — model, tool and person — is this one adapter", because with
one backend that sentence is still true (`routing-design.md` §5.1).

*The acceptance test for R3 is that `ci/acp.sh` and `ci/deck.sh` pass with not
one assertion edited.* Scenario 12 in particular — the flag-forbidding
scenario — must stay green unedited, which is what proves `forbid`'s
generalization is the identity at one scheme (`routing-design.md` §1.6).

**R4 — `--route`. This is the landing that closes the issue.**

| file | change | ± |
|---|---|---|
| `haskell/src/Agentic/Cli.hs` | parsing, `roRoutes :: ![Text]`, the five refusals of §1.5, the multi-backend header of §5.2, `withAcps` wired, `routedWorld` installed, usage text | +60 |
| `haskell/test/PolicyProbe.hs` | fold-invisibility, toolExec-not-routed, cross-backend fail-over | +50 of the +90 |
| `haskell/ci/acp.sh` | scenarios 13, 14, 15; summary count 12 → 15 | +90 |
| `haskell/ci/policies.sh` | check count in the header comment | +2 / −2 |

**R5 — the live smoke and the narrative.**

| file | change | ± |
|---|---|---|
| `haskell/ci/route-live.sh` | **new**, manual only, never in an automatic lane | +80 |
| `haskell/agentic.cabal` description | one paragraph in the existing week-by-week style | +12 |

Run once by hand; the transcript is pasted into
`acat-engine-party-routing-hcx` as the evidence that two providers answered one
program, with §0.2's configured-versus-reached distinction stated in the note.

**Not touched, and this is the design's headline:** `Exec.hs`, `AgentDeck.hs`,
`Workflow.hs`, `Workflow/Do.hs`, `Builder.hs`, `Plan.hs`, `World.hs`, `Raw.hs`,
`Guards.hs`, `Chains.hs`, `Shell.hs`, `Observe.hs`, `Text.hs`, `WF.hs`,
`run/Main.hs`, `tier0/`, `tier1/`, `bisim/`, `test/corpus/`, and every Lean
file. A diff touching any of them is a diff that has left this plan.

### 1.2 The gates that must not move

Every existing gate stays green at its existing numbers, unedited. This is the
whole of the compatibility contract and it is checked, not assumed.

| gate | pinned at | after Stage R |
|---|---|---|
| `ci/tier0.sh` | tier0 **189/189**, tier1 **29/29** (24 exact + 5 alpha) | **identical, unedited** |
| `ci/tier1.sh` (bisim) | P1 40/40, P2 960/960 | **identical, unedited** |
| `ci/examples.sh` | 7 registered, 0 failures; `level`, `size`, `askNodes`, `costSummary`, both bills by **equality** | **identical, unedited** |
| `ci/deck.sh` | 7/7 | **identical, unedited** |
| `agent-workflows/ci/workflows.sh` | every registered row: `level` and `paths` by equality, `costMax` as a ceiling, scripted exit 0 | **identical, unedited** |
| `ci/citations.sh` | every `X.lean:N` under `haskell/` resolves | **green**; `Route.hs`'s new citations are new obligations it must satisfy |

Two gates move, and only by addition:

| gate | before | after |
|---|---|---|
| `ci/policies.sh` | 19 checks | **19 + the eight probe rows** of `routing-design.md` §7.1 (ten probes if the three unpinned-addressee cases are counted apart); the header's stated count is edited to match, and that edit is the *only* edit to an existing assertion in this stage |
| `ci/acp.sh` | 12/12 | **15/15** — scenarios 13 (two adapters, dispatch by pin), 14 (dead route, nothing spent), 15 (the four usage refusals). Scenarios 1–12 **unedited** |

`test/SurfaceRefusals.hs` gains **nothing**, and that is the correct answer: a
route is not something an author writes, so there is nothing for the authoring
surface to refuse (`routing-design.md` §7.2).

### 1.3 The two new gate obligations, spelled out

**The PolicyProbe cases** (`routing-design.md` §7.1) — pure, no process, no
network, no Lean, no corpus, so they run on every commit beside the rest:

1. `parseBackend`: the three `acp:` spellings, `deck:`, the first-colon split on
   a value containing a colon, and the unknown-scheme refusal **wording**.
2. `parseRoute`: `NAME=BACKEND` splits on the first `=`; a missing `=` refuses
   with the shape in the message.
3. `backendFor`, pinned: `scope.model = Just "gemini"` picks `gemini`'s backend.
4. `backendFor`, unrouted pin: `Just "fable"` with no `fable` route takes the
   default.
5. `backendFor`, unpinned: `Nothing` takes the default — one case each for
   `AddrModel`, `AddrTool`, `AddrPerson`.
6. **Routing is invisible to the fold**: `hardenProgram` twice through
   `routedWorld` over a table whose every backend is `pureWorldIO w` for the
   *same* `w`, once empty and once with three routes; **the two traces are equal
   event for event and both bills agree.** This is §1.4's invariant made
   executable at the unit level.
7. **Routing does not intercept `toolExec`**: `executingWorld sh (routedWorld
   rs)` where every routed backend raises on consultation; a `toolExec` program
   settles, proving no question reached routing.
8. **Cross-backend fail-over**: `deep or broad`, two *distinct* worlds, `deep`'s
   raising a gap and `broad`'s answering — the run settles, the trace names
   `broad`, the narration keeps the existing wording, and *with no alternates
   declared the same two worlds abandon in exactly the words they always did*.

Case 8 is the one that proves the capability without a process: two `WorldIO`s
*are* two backends as far as `routedWorld` is concerned.

**The two-backend live smoke** (`ci/route-live.sh`, `routing-design.md` §7.4) —
manual only, because it spends real money on real accounts, which is the same
reason `ci/tier1.sh` is nightly and fails loudly rather than degrading:

```
agentic-run run harden --engine acp --adapter claude --route 'deep=acp:codex'
```

Six assertions in the order they discriminate: (1) the header names **2
backends**, one `claude-agent-acp` and one `codex-acp`, with `deep` on the codex
line; (2) two adapter processes during the run and **none after** — the `pgrep`
check scenario 11 already uses, at the bracket instead of at the timeout;
(3) `billFresh 7`, `billMemo 7` — **the flagship's frozen numbers, unchanged**,
which is §1.4 observed on the wire rather than argued; (4) the announced
consultations name the parties and the draft is visibly a different voice from
the reviews; (5) `applied.c` exists and holds what the patch adds, in the one
shared directory both providers were pointed at; (6) exit `0`.

Plus two negative controls it buys free: the same command with `--route` removed
is today's behaviour, today's header, today's bills; and
`--route 'author=acp:codex'` is **refused at exit 1**, because `author` is a
party and not a pin — the resolution rule defended at the command line, where an
operator will actually make the mistake.

### 1.4 The semantics-untouched invariant, as a check

The claim is that Stage R moves no frozen reply. It is stated three ways, in
descending order of how mechanical each is, and **all three must be executed**.

**Check A — the import graph (mechanical, cheap, no build).**
`tier0/`, `tier1/` and `bisim/` do not import `Agentic.Exec`. They have no
`WorldIO`, no interpreter and no transport; they decide conformance against
`Agentic.World`'s pure `WorldSpec` through `Agentic.Observe`'s reply assembly. A
change confined to `WorldIO` is therefore *unreachable* from the code that
decides a frozen reply. The check is a grep, it runs without a build, and it
must be re-run after R4 with the addition of `Agentic.Route` to the search:

```
grep -rn "Agentic.Exec\|Agentic.Route\|WorldIO" haskell/tier0 haskell/tier1 haskell/bisim
```

**Expected output: nothing.** A hit is a STOP-AND-REPORT.

**Check B — no field of the trace names a backend (mechanical, by reading).**
`EventKey` is code, addressee, scope, prompt, draw (`World.hs:392`); `Event`
adds the answer; `eventJson` (`:508`) emits exactly those; `scopeJson` (`:490`)
emits `model` and `mode`. None mentions a backend, so two runs differing only in
their route table and producing identical answers produce **byte-identical
traces and identical bills**. There is no field in which they could differ. The
executable form of this check is PolicyProbe case 6 (§1.3), which is why that
case is not optional.

**Check C — corpus regeneration is a no-op (mechanical, expensive, and the one
that must be scheduled).**

```
# in the coordinator's own build window, never concurrently:
lake exe corpus-gen           # or the tree's current spelling
git status --porcelain test/corpus/     # expected: empty
./haskell/ci/tier0.sh                   # expected: tier0 189/189, tier1 29/29
```

**A dirty `test/corpus/` after regeneration is a STOP-AND-REPORT and the stage
does not land.** Regeneration is idempotent at 189 today and must remain so.

This check needs Lean and the build directory, and both are exactly what §4's
sequencing constraints forbid to a Stage R builder. **It is therefore the
coordinator's to run, in a window they own, and it is the one item in this plan
most likely to be skipped on the grounds that Checks A and B already argued it.**
They argue it; they do not observe it. A stage that ships on the argument alone
has repeated the failure `ci/tier1.sh`'s own header refuses — "a green suite that
quietly tested nothing".

### 1.5 What Stage R deliberately does not build

Named so that a reviewer does not read their absence as an oversight:

- **No `--route-arg`.** A per-route adapter argument is a two-line wrapper
  script, and `adapterArgv` already falls through to a bare path; scenario 13
  is written to need one and demonstrates that it suffices.
- **No per-route timeout, scratch, binary, poll or verbosity.** A turn budget is
  a statement about how long *this run* waits, not about which provider it
  waited on.
- **No per-route `ExecSettings`.** There is no per-*run* surface for
  `esRetry*` either, and inventing a per-route spelling for a knob with no
  per-run spelling would be the second storey of an unbuilt house.
- **No backend-level fail-over, ever.** A route is a total, deterministic
  function of the pin, fixed for the run. The memo table is why: one pin tried
  at two backends is the same `EventKey` put twice to two processes, and the
  second is a consultation the bill cannot see. Cross-provider recovery goes
  through the pin ladder, which relabels the key, and there is nowhere else for
  it to go. **A route whose backend is dead is a dead question.**
- **No backend field in the trace.** Backend attribution is the composition of
  the header (policy, before) and the trace (outcome, after). Putting the
  backend in the trace would put execution policy into a structure the frozen
  corpus compares by equality.

---

## 2. Stage C — the confer workflow

The design of record is `confer-design.md`. This section is what it needs, what
it does not need, and how it is gated.

### 2.1 What it needs from Stage R: nothing

By design, and this is worth stating rather than assuming, because "wait for
routing" is the obvious wrong sequencing.

Confer is **useful on the day it is written**, at one backend. With
`acpFreshPerQuestion` defaulting to `True` and the CLI never overriding it, the
three seats are three *fresh sessions*: none sees another's answer, none
inherits a transcript, each reads only its own stance and the subject. That is
**independence of context** — a real kind, and precisely the kind PAL's
`continuation_id` threads deliberately do not give you. It is not independence
of weights, and `conferProvenance` (`confer-design.md` §1.4) is the line that
stops the artefact from implying otherwise.

On the day Stage R lands, confer goes cross-backend **with no program text
edited at all**, for the four reasons audited in §0.4. That is the requirement
the pal-note set — "design the roster so that routing slots in without changing
the program text" — and it is met.

**Ruling for the coordinator: Stage C may land first, and probably should**, on
the grounds that it is the half the owner uses daily and the half whose gates
are cheapest.

### 2.2 What it needs from the ai-config track's foundation

Four things, three of them already written and pushed in the toolbox repository,
and this is the point: **confer is written *out of*
`agent-workflows/src/Workflows/`, never beside it.** A
parallel roster type, a second fan-out helper or a private `wfText` is the exact
shape this repository's own review discipline exists to catch.

**Already there, and used unchanged:**

| piece | where |
|---|---|
| `Lens`, `Roster`, `lensNames`, `rosterTable`, `memberNote` | `Panels.hs:98`–`:130` |
| `reasoning` / `broad` / `lateral`, and `reporter` | `Parties.hs:122`–`:133`, `:178` |
| `wfText`, `bullets`, `tshow` | `Prose.hs` |
| `refusingSynthesis`, `unverifiedIndependence` | `Panels.hs:234`, `Rubrics/Discipline.hs:169` |

**Owed by the foundation, both one-line signature generalizations in
`Workflows.Panels`:**

- **R1 — a fan-out's subject must be anything a hole may name.**
  `asksOver :: (KnownIx h s) => Roster -> Text -> V h 'CodeText -> [Ask s]`
  becomes `asksOver :: (Says a s) => Roster -> Text -> a -> [Ask s]`. `Says` has
  exactly the three instances a hole may resolve to (`WF.hs:117`–`:137`), so
  this widens the subject to precisely the set the prompt could already have
  spliced, and every existing caller resolves through the `Says (V h c) s`
  instance unchanged. Confer's subject is an **input**, which is a define and
  not a live handle, so without R1 confer must either spend a question asking a
  tool to read the decision — turning the operator's text into an *answer* — or
  hand-roll a private `asksOver`.
- **R2 — the fold-to-document must take its closing line.** `documentPanel`
  hard-codes "Report your findings and nothing else", which is right for a
  review roster and wrong for a stance roster. `documentPanelWith closing` with
  today's `documentPanel = documentPanelWith reportClosing`.

**Confer is blocked on neither.** Until they land, `confer-design.md` §1.5's
program writes the fold out itself, which is what it does. Taking them is what
keeps confer from being a second implementation of an existing fan-out — a
quality obligation, not a schedule dependency.

**Owed by the ai-config track as an ownership decision, not as code:**

- **The module home.** Four stance defines, one challenge define, two briefs and
  one provenance function. They are `Rubrics/`-shaped; `confer-design.md`
  deliberately does not name the file, and the ai-config architecture phase
  does. Stage C cannot land until that phase has ruled, because a module placed
  and then moved is a diff nobody reviews twice.
- **The registry rows.** `Workflows.Registry` is one row today (`hello`). Stage
  C adds `confer` and `secondOpinion` (certain), `confer_` and `debate` (one
  line each, cost nothing to carry), and rules on whether `conferGate` belongs
  with the gates instead. The naming rule is the registry's own: *the owner's
  own word where one exists, and one name per shape, never one per invocation.*
- **The optional third: `accountForBlocks :: Roster -> Text`**, shared between
  `conferSynthesis` and `refusingSynthesis`. Not required; noted because the
  argument in that paragraph is the tree's and not confer's, and an argument
  stated twice drifts once.

**Coordination note.** `Workflows.Panels` is a file the ai-config track is
actively authoring. R1 and R2 are edits to *its* module, so they are the
ai-config track's to make, requested by this one — not a Stage C builder's to
land unilaterally.

### 2.3 The landing order

**C1 — the rubrics.** The stance defines, the challenge define, `stanceClosing`,
`conferSubject`, `conferSynthesis`, `conferProvenance`, `conferWriteBrief`, in
the module home the architecture phase ruled. Pure `Text`, nothing registered,
nothing priced yet. Every define carries the haddock line naming the corpus file
or design section it came from — the tree's first house rule.

**C2 — `conferOver` and `confer`.** The program and its `Parameterized`
wrapper. Not yet registered.

**C3 — registration and the gate.** `confer` and `secondOpinion` into
`Workflows.Registry`; the canned scripted table beside each;
`agent-workflows/ci/workflows.sh`
picks them up by reading the registry from the binary rather than by
transcription, so the gate rows are automatic once the rows exist.

**C4 — the variants.** `confer_`, `debate`, and the ruling on `conferGate`. Each
is `conferOver` at a different roster, which is why each is one line and why none
can drift from the others in anything but its roster.

**C5 — the live smoke.** Manual, once, transcript kept.

### 2.4 The gates

**Gate C-a — the price, pasted.** `wf plan confer` and `wf cost confer` are run
and their output pasted into the landing record. The expected numbers, derivable
by hand from the design:

```
  level     pipeline
  size      6
  askNodes  5
  codes     text, text, text, text, receipt
  cost      minFold 5, maxFold 5, over 1 path
```

Three panel members (`panelText` grafts one `PAsk` per member), one synthesis,
one closing act; `size` is `askNodes + 1` for the terminal on a straight line;
`level` is `pipeline` because there is no `PCase`; one path, therefore one price
and not a range. And the property that makes this a *contract*: **`plan` and
`cost` do not require the inputs**, so `wf cost confer` answers "what will this
spend" before a word of the decision has been written. PAL's first sight of cost
is the response.

The variants' numbers, for the same paste:

| variant | `askNodes` | `size` | level | cost | codes |
|---|---|---|---|---|---|
| `confer` | 5 | 6 | pipeline | 5, 1 path | text ×4, receipt |
| `confer_` | 4 | 5 | pipeline | 4, 1 path | text ×3, receipt |
| `debate` | 4 | 5 | pipeline | 4, 1 path | text ×3, receipt |
| `secondOpinion` | 2 | 3 | pipeline | 2, 1 path | text, receipt |
| `conferGate` | 6 | 10 | **branch** | 4, **3 paths** | none — it branches |

**Gate C-b — the scripted run.** `wf run confer --scripted` exits 0, bills
`billFresh 5` / `billMemo 5`, and — the assertion that matters — **the three
seats receive three different canned answers.** This works only because the
shared `challengeRubric` comes *after* each seat's stance in its prompt: a
scripted table matches the first entry whose key is a prefix of the prompt, so a
roster whose seats shared an opening chunk would have one canned answer serving
all three, and the fan-out would be untested by the gate that exists to test it.
**Stage C must assert the three distinct answers, not merely exit 0**, or the
ordering rule is unenforced.

**Gate C-c — `agent-workflows/ci/workflows.sh`, automatically.** Per registered
row: `level`
equality (`pipeline` for confer, `branch` for `conferGate` if it lands here),
`paths` equality (1, or 3), `costMax` as a **ceiling** (5), scripted exit 0.
`size`, `askNodes` and the bills are deliberately not pinned — they are exactly
what a reworded rubric moves, and this is a toolbox, not the examples registry.
`ci/examples.sh` is **not touched**: confer is not an example, and the whole
reason there are two registries is that a reworded rubric must not be able to
turn the language's gate red.

**Gate C-d — `--require-pinned` passes by construction.**
`wf plan confer --require-pinned` refuses before a plan is printed if any model
ask lacks a `served by`. Confer passes: every seat and the synthesis are pinned
through a ladder. Run it and paste it; it is one line and it is the pre-flight
PAL's nearest equivalent (a remembered `listmodels`) is not.

**Gate C-e — the live smoke.** Manual, once:

```
wf run confer --require-pinned --engine acp --adapter claude \
  --input-arg decision='<a real decision the owner faces>' \
  --input-file context=./<a real document>
```

Assert: exit 0; `billFresh 5`; `confer-<date>.md` written in the run directory;
the artefact opens with the provenance line and **that line's single-backend
disclaimer is present**, because the header named one backend; three blocks
under `for`, `against`, `neutral`, each in the party's own words and unedited;
the recommendation present, attributed, and marked as one reading of the blocks
rather than their sum.

Prefer `--engine acp`. The deck engine is the weaker configuration for a confer
and the plan says so: one durable session for the whole run means the parties
**do** share context in program order, so the third seat has read the first two.
Use `--engine deck` only when the point is to put the confer into a session a
person is watching.

### 2.5 What Stage C deliberately does not build

- **No mirrors of PAL's seven guided investigations.** `thinkdeep`, `debug`,
  `codereview`, `analyze`, `planner`, `precommit`, `refactor` are step-numbered
  forms whose discipline is an honour system over parameter names. Their
  agent-cat expression is not a program named `debug`; it is a `revisingOn`
  whose settle/amend/abandon comes from a verdict, a `decide` that reads a gate
  for zero questions, and a `toolExec` receipt the world authored by actually
  running the build. **Those are the ai-config track's workflows, built from the
  owner's own command corpus, and this track must not invent parallel ones.**
  Confer is the single PAL tool that is a *shape* rather than a form, which is
  why it is the one that gets a workflow.
- **No automatic model selection.** Declined on principle, not missing: a
  program that does not know who answers cannot honestly price or attribute, and
  a guard that refuses an unpinned model ask cannot coexist with a system whose
  selling point is that asks are unpinned. The ladder is the principled fragment
  of the idea.
- **No `revising`, no branching in `confer` itself.** A confer collects and
  recommends; it does not iterate to approval. That is what keeps it `pipeline`
  and one price.

---

## 3. The acceptance runs — the definition of done for the whole track

These are the parity matrix's rows executed. **The track is done when every
row's run has been performed and its evidence recorded**, and not when the files
have landed. Each row names the PAL habit it stands opposite, the command, and
what the run must show.

> **The reconciliation rule.** These rows are derived from
> `pal-vs-agent-cat.md`'s correspondence section, because `parity-matrix.md` was
> not on disk when this plan was written (see the note at the head of this
> document). When it lands: **the matrix is the roster of rows** — if it names a
> parity claim absent below, that claim is added here and the track is not done
> until it has a run. **This section is the acceptance criterion** — a row the
> matrix states as a correspondence is not done until the command below has been
> executed and its evidence recorded. Where the two differ on a row's *wording*,
> keep this section's; where they differ on a *capability*, the matrix wins and
> this plan is amended rather than the matrix.

### A1 — `chat` → an ask. *(Stage C)*

```
wf run secondOpinion --engine acp --adapter claude \
  --input-arg decision='…' --input-file context=./…
```

Shows: two questions, a `second-opinion-<date>.md` on disk, a bill of 2, and the
party pinned through `lateral` — a second opinion from somewhere other than the
house model, which is the whole value of asking for one.

### A2 — `challenge` → one rubric define. *(Stage C)*

No run of its own: `challengeRubric` is spliced into every confer seat and into
`secondOpinion`, and A1's and A5's transcripts are its evidence. The acceptance
criterion is that the define exists as one binding read by every party in the
tree, rather than as a wrapper prompt typed per call.

### A3 — `clink` → the engine layer. *(Stage R)*

```
agentic-run run harden --engine acp --adapter codex
agentic-run run harden --engine acp --adapter claude
```

Shows: the same program, priced identically, reaching either CLI, with a trace
and a bill that `clink` has no analogue for. Green today; re-run after R3 as the
refactor's own control.

### A4 — cross-backend fan-out in one run. *(Stage R — the filed residual, and the run that closes it)*

```
agentic-run run harden --engine acp --adapter claude --route 'deep=acp:codex'
```

Shows: `ci/route-live.sh`'s six assertions (§1.3). **This run is the evidence
that `acat-engine-party-routing-hcx` is closed**, and its transcript belongs in
the issue.

### A5 — `consensus` → confer, at one backend. *(Stage C)*

The Gate C-e run (§2.4). Shows what `consensus` structurally cannot: a price
before the spend, a trace after it, a fold that is a term rather than caller
bookkeeping, block-level attribution defended against a member forging another's
closing tag, and an artefact on disk nobody had to copy out of a chat window.

### A6 — `consensus` → confer, across providers. *(Stage R + Stage C — the only row needing both)*

```
wf run confer --require-pinned --engine acp --adapter claude \
  --route 'gemini-3.1-pro-preview=deck:gemini-pane' \
  --route 'gpt-5.5-pro=acp:codex' \
  --input-arg decision='…' --input-file context=./…
```

Shows: **the roster unchanged, byte for byte, from A5** — this is the row that
proves the pal-note's design constraint was met — a header naming three
backends and the pinned models no route claims, and a provenance line whose
single-backend disclaimer is now absent because the header contradicts it. Per
§0.2, the note recording this run must distinguish backends *configured* from
backends *reached*: `gpt-5.5-pro` is a spare and answers only on a fail-over.

### A7 — `continuation_id` → session policy. *(Stage C, no new code)*

Read from A5's run: five questions, five `session/new` calls, no thread. The
acceptance criterion is negative and it is the point — what was said is in the
trace, not in a server-side thread nobody can audit.

### A8 — `listmodels` / `version` → the run header. *(both stages)*

Read from A4's and A6's headers: who is answering, under what policy, before a
token moves. Nothing to build; the acceptance criterion is that the header of a
routed run is **true and complete** — it names every backend, deduplicated, says
what falls to the default, and prints the pinned models no route claims, so that
a mistyped route reads as a mistyped route and not as an absent one.

### A9 — `apilookup` → an ask to a web-capable party. *(Stage C, no new code)*

An A1-shaped run whose question is a doc lookup, against an adapter session that
can search. Acceptance is that it works as an ordinary ask; there is nothing to
build, and local searxng covers the same need outside any workflow.

### A10 — the seven guided investigations → **explicitly out of this track.**

Owned by the ai-config workflows track and built from the owner's own command
corpus. The acceptance criterion here is a *negative* one, and it is a real gate
on this track's reviewers: **this track has invented no workflow named after a
PAL tool.** `confer` is named for the shape and for the owner's own word in
`heavy`/`wiggum`, not for `consensus`.

### The three residuals, restated as accepted rather than closed

1. **Inline images.** PAL's `chat` takes base64 screenshots; asks are text. The
   working answer is that adapter sessions have a working directory and the
   claude CLI reads images from it, so "look at ./screenshot.png" expresses it —
   a convention, not a surface feature. **Accepted as a convention. Not in
   scope.**
2. **Auto model selection.** Declined on principle (§2.5). **Not a gap.**
3. **Per-call temperature and effort knobs.** Configuration, not capability;
   reachable through adapter arguments today, and through a two-line wrapper
   script per route after Stage R. **Accepted.**

**Done, stated once:** A1 through A9 executed with evidence recorded, A10
verified as a negative, the three residuals acknowledged in writing, every gate
of §1.2 green at its stated numbers, and Check C of §1.4 observed rather than
argued.

---

## 4. Sequencing constraints for the coordinator

These are hard, and they are about *machines and directories*, not about
politeness.

### 4.1 No builds while the ai-config workflow holds the build directory

Another workflow owns `dist-newstyle` and the Lean build right now. **No Stage R
or Stage C builder runs `cabal`, `lake`, `nix develop -c cabal`, or any `ci/*.sh`
that shells into one, until the coordinator says the directory is free.** Every
`ci/` script in this tree begins by building; there are no read-only ones.

Two consequences the coordinator must plan for rather than discover:

- **A design-phase agent can write files and cannot verify them.** Every number
  in §2.4 is derived by hand from the design and must be *confirmed by running
  `wf plan`*, not trusted. A pasted number that was computed rather than
  observed is exactly the honour system this whole track is written against.
- **Check C of §1.4 (corpus regeneration) is gated on the same window**, and it
  is the check the track cannot ship without. See §4.4.

### 4.2 Stage R and Stage C builders must not run concurrently

They touch mostly disjoint trees — `haskell/src/Agentic/`, `haskell/test/`,
`haskell/ci/acp.sh` in `agent-cat` versus `src/Workflows/` and `ci/workflows.sh`
in `agent-workflows` — but they collide in two places that matter:

- **`haskell/agentic.cabal`.** Stage R adds `Agentic.Route` to the library's
  `exposed-modules` and a paragraph to the description; Stage C adds confer's
  modules to `agent-workflows.cabal`'s library, whose `wf` stanza depends on it.
  Two cabal files in two repositories, then — but the library Stage R is editing
  is the one Stage C's build resolves against, so a half-written
  `exposed-modules` list breaks the other stage's build rather than merging
  badly.
- **`dist-newstyle`.** Two concurrent `cabal build`s in one directory is not a
  merge conflict, it is a corrupted build.

**Ruling: serialize, or give each stage its own git worktree with its own build
directory.** Separate worktrees are the better answer, because the stages are
genuinely independent (§2.1) and there is real time to be won — but a worktree
per stage must be an actual `git worktree`, not two agents in one checkout on
two branches.

### 4.3 The corpus and the Lean tree are untouchable

`test/corpus/` and every `.lean` file are **read-only for both stages.** Neither
design touches them and neither may. Specifically:

- No refreeze, no regeneration-and-commit, no vector added, no vector edited.
- No `lake build` inside a test run — the one-build rule stands.
- A change that *would* move a corpus vector is a STOP-AND-REPORT that ends the
  stage, not a change to be accommodated by re-freezing.

The routing design's headline is that it touches none of this, and the plan's
job is to make that headline falsifiable rather than decorative: §1.4's Check A
is the falsifier and it costs a grep.

### 4.4 The one scheduling obligation the coordinator personally owns

**Check C of §1.4 — `lake exe corpus-gen`, a clean `git status` on
`test/corpus/`, and `ci/tier0.sh` at 189/189 and 29/29 — must be run by the
coordinator in a window they own, after Stage R lands and before the track is
called done.** It cannot be delegated to a Stage R builder, because §4.1 forbids
that builder the Lean tree and the build directory. It cannot be inferred from
Checks A and B, because those are arguments and this is an observation.

If the window does not exist, **the track is not done** — it is landed and
unverified, which is a different and more dangerous state, and one this
repository has a name for.

### 4.5 Suggested order, given the above

1. **Stage C first**, in its own worktree: cheapest gates, no Lean, no live
   money until C5, and it is the half the owner uses daily.
2. **Stage R second**, in its own worktree, in its five landings, R3 reviewed
   hardest.
3. **The coordinator's build window**: Check C, then `ci/acp.sh` at 15/15,
   `ci/policies.sh` at its new count, and every unmoved gate of §1.2 at its
   stated numbers.
4. **The live smokes**, A4 then A6, in that order — A4 is the one held to a
   frozen number and therefore the one that discriminates; A6 is the better
   demonstration and the worse test.

---

## 5. What this track is not

Stated last, plainly, because it is the ruling that governs everything above and
the one most likely to erode under momentum.

**PAL MCP stays configured.** It is live on this machine with three providers
and 127 models, and it stays that way. This track does not remove it, disable
it, deprecate it, or plan for its removal.

**No configuration is edited anywhere.** Not `~/src/nix/config/ai`, which is
read-only reference for this track and is being written by another. Not the MCP
server list. Not a skill file, not an agent file, not a settings file. **The
change list of both stages is `agent-cat`'s `haskell/src/`, `haskell/test/`,
`haskell/ci/`, `haskell/agentic.cabal` and this directory, plus
`agent-workflows/src/Workflows/` in the separate toolbox repository. Nothing
else.**

**There is no migration checklist**, because there is no migration. A PAL call
the owner makes tomorrow is not a defect and is not a metric this track moves.

**The deliverable is capability, not substitution.** When the track is done, the
owner can run a confer that reaches three providers, priced before it starts,
traced after it ends, with an artefact on disk and a semantics the corpus
decides — *or* they can call `mcp__pal__consensus` and get an answer in one
round-trip with no ceremony. Both remain available, both remain correct choices
for different moments, and the only thing that has changed is that the first one
now exists.

The `wiggum` and `heavy` skills' "confer via PAL for real decisions" clause may,
once confer is registered, read "or run `wf run confer`". **Both halves of that
sentence are true, and editing those skills is the ai-config track's call and
not this one's.**
