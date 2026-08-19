# The confer workflow: the design

*2026-08-19. Written against `agent-cat` at pushed `2f86fda`, reading
`haskell/src/Agentic/{Workflow,WF,Builder,Plan,Exec,Chains,Text,Cli}.hs`,
`haskell/example/Example/{Harden,Isaac}.hs` and the toolbox foundation that
already exists at `workflows/Workflows/`. It executes the second half of
`doc/research/pal-vs-agent-cat.md` — the workflow-shaped counterpart of PAL's
`consensus` — and is the sibling of `pal-subsumption/routing-design.md`, whose
§8.3 says this document is the other half and that neither is blocked on the
other.*

*The owner has ruled: **PAL MCP stays configured.** Nothing here removes it,
migrates off it, or edits a line of its configuration. What confer buys is the
option — the same models, plus a price before the spend, a trace after it, and
a fold that is a term rather than a habit.*

---

## The ruling, in one page

**The program.** Five questions: three parties asked one decision under three
stances, a synthesis that folds their document into a recommendation, and an
act that writes the artefact. It takes the decision and the file context as
**inputs** (`taking`/`input`), so the operator's text reaches the prompts as
data and not as an answer.

**The fold is `panelText`, not `panel`.** A consensus output is
document-shaped: the point of consulting three parties is that three readings
survive, attributed, for the synthesis and for the human. `panel` folds prose
into a verdict tag — three essays become `APPROVE`, or an objection list, and
one *declined* member annihilates the whole fold. `panelText` folds into
`<for>…</for><against>…</against><neutral>…</neutral>`, one block per member
under a label the *author* chose, with each member's attempt to forge its own
closing tag defanged (`Agentic/Text.hs:357`). §2 argues it against both rivals.

**The price, for a 3-party roster:** `level pipeline`, `size 6`,
**`askNodes 5`**, `codes text, text, text, text, receipt`,
`cost minFold 5, maxFold 5, over 1 path`. One path, one price, not a range —
and `plan`/`cost` do not need the inputs to say so, so confer is priced before
the decision has even been written down. PAL's `consensus` gives its first
sight of cost after the spend.

**Operation.** Single-backend today and useful today: with
`acpFreshPerQuestion` defaulting to `True` (`Acp.hs:330`) the three parties are
three *fresh sessions* — independence of context, which is a real kind, and not
independence of weights, which it is not, and the report says which it got.
Cross-backend the day `acat-engine-party-routing-hcx` lands, **with the roster
unchanged**: routing keys on the serving model (`routing-design.md` §2.2), the
roster's `servedBy` pins *are* those keys, and `--route` is a run flag that
`plan` and `cost` refuse to read.

**Variants** are the same program at a different roster, which is why they are
one line each: `confer_` (no synthesis), `debate` (for/against), `secondOpinion`
(one party, challenge rubric), and `conferGate` — the one place `panel` is
right, because a gate wants a verdict and not a document.

**Two requirements on the foundation**, both small, both forced by the
pal-note's own "it should take the decision text and optional file context as
inputs": `Workflows.Panels.asksOver` must take a subject that is `Says`, not a
live handle, and the fold-to-document must take its closing line. §1.6. This
document does not name confer's module, which is the architecture phase's to
fix.

---

## 1. The program

### 1.0 What already exists, and is not reinvented here

`workflows/Workflows/` is not empty. It already carries, at pushed HEAD:

| piece | what it is | where |
|---|---|---|
| `Lens`, `Roster`, `lensNames`, `rosterTable` | a fan-out member as data: label, what it owns, its brief, its party | `Panels.hs:98`–`:119` |
| `asksOver` | one question per member over one artefact | `Panels.hs:153` |
| `documentPanel` | that fan-out folded with `panelText` | `Panels.hs:181` |
| `memberNote` | the derived "you are one of N, the others own…" paragraph | `Panels.hs:130` |
| `refusingSynthesis` | the synthesis brief that refuses on a short roster | `Panels.hs:234` |
| `reasoning` / `broad` / `lateral` | the three fail-over ladders; `lateral`'s haddock already says it is "the rung a contrarian, a skeptic or a **confer member** wants" | `Parties.hs:122`–`:133` |
| `wfText`, `bullets`, `tshow` | the mechanics every rubric module needs | `Prose.hs` |
| `unverifiedIndependence` | what a run says when an independence claim was not established | `Rubrics/Discipline.hs:169` |

Confer is written **out of** these. A parallel roster type, a second fan-out
helper or a private `wfText` would be the exact shape this repository's own
review discipline flags: a new implementation built beside an existing one.
What confer needs that is genuinely absent is two signature generalizations
(§1.6) and its own rubrics.

### 1.1 The rubrics, as `[wf|…|]` defines

Four stance defines and one shared anti-sycophancy define. Each is `wfText` of
a fence, which is the tree's rule: *the text a question sends is read in the
source at the width it is sent at*, and `Text` rather than `Words` because
chunking is normative and a scripted table keys on the define itself
(`Prose.hs:36`–`:58`).

```haskell
-- | PAL's `challenge` tool, which is a wrapper prompt and not a workflow, as
-- the one define every party in this tree stands under.
--
-- /Source:/ `doc/research/pal-vs-agent-cat.md` — "`challenge` → one rubric
-- define. A `[wf|…|]` constant of a dozen words. The transplant is so small it
-- is barely a line item."
challengeRubric :: Text
challengeRubric =
  wfText
    [wf|
    Evaluate what is put to you on its merits. Do not agree because the
    question was asked confidently, because agreeing is shorter, or because
    the person asking appears to want a particular answer. Where you find the
    case sound, say which part carries the weight; where you do not, say where
    it fails and what the failure costs. Deference is not analysis, and a
    reader who wanted agreement did not need to ask three parties.|]

-- | Every party stands under the challenge rubric, and stands under it
-- __second__.
--
-- The order is not cosmetic. A scripted table matches "the first entry whose
-- key is a prefix of the prompt" (`Exec.hs:1337`), and the tree's rule is that
-- a key is a prefix __by construction__ because each member's prompt opens
-- with its own `lensBrief` (`Hello.hs:91`–`:94`). Put the shared rubric first
-- and all three parties open with the same bytes: one canned answer would
-- serve all three and `wf run confer --scripted` would silently stop being a
-- test of a fan-out. The stance leads; the shared rule follows it.
underChallenge :: Text -> Text
underChallenge stance =
  wfText
    [wf|
    {stance}

    {challengeRubric}|]

forStance :: Text
forStance =
  wfText
    [wf|
    You are arguing FOR the decision below. Your job is the strongest honest
    case that it is right: what it buys, what it unblocks, and what not doing
    it costs. Two other parties argue the other side and the middle, so do not
    hedge and do not write their blocks for them.

    Argue from what the decision and its context actually say. An advantage you
    cannot point at is an advantage you are inventing, and a case built on one
    is worse than no case: it spends the reader's trust on the parts that were
    true.|]

skepticStance :: Text
skepticStance =
  wfText
    [wf|
    You are arguing AGAINST the decision below. Your job is what goes wrong:
    what it breaks, what it commits the tree to that a later change would have
    to undo, and what it costs that the proposal does not price.

    Trace every objection to a concrete mechanism -- the caller, the format,
    the file, the version. An objection you cannot trace is not an objection,
    it is unease, and the synthesis will rightly set it aside. Three real
    objections beat ten plausible ones.|]

neutralStance :: Text
neutralStance =
  wfText
    [wf|
    You are the neutral party. The other two argue the sides; nobody has asked
    them what is actually true. Sort the claims: which are settled by the
    context below, which are judgement calls where reasonable people differ,
    and which are simply unknowable from what is here.

    Name the one fact that would decide this if somebody went and got it. If
    the decision is underspecified, say what it is missing rather than choosing
    on the asker's behalf.|]
```

`skepticStance` is deliberately Isaac's voice — `Example/Isaac.hs:238`'s
"a risk that you did not trace to a concrete mechanism is not a risk — it is
anxiety" is the best sentence in that file and the confer roster is where it
belongs a second time.

The closing line each party's block is asked for, and the subject the roster
reads:

```haskell
-- | What a party is told about the shape of its answer.
--
-- Not `verdictSpec`: a stance is prose, and the runner already appends
-- `answerSpec CodeText` -- "Reply with the text itself and nothing else"
-- (`Exec.hs:645`) -- to every text question. What this adds is the one thing
-- the code cannot say: your answer is __one block of a document__, so do not
-- write the other blocks and do not address the reader of any block but your
-- own.
stanceClosing :: Text
stanceClosing =
  wfText
    [wf|
    Write your case as prose, at most twelve lines, and do not summarise the
    decision back: the reader has it above your block. Your answer is one block
    of a document whose other blocks are the other parties'. Do not write
    theirs, do not address the reader of the whole, and do not pre-empt the
    synthesis -- it is a later question, put to somebody who has read all of
    you.|]

-- | The decision and its context, as one define the whole roster reads.
--
-- Two inputs and one subject, because a fan-out member takes one artefact. The
-- context may be empty and the words say what empty means, so that an operator
-- who has nothing to attach does not have to invent a placeholder and a party
-- that receives nothing does not have to guess whether something was lost.
conferSubject :: Text -> Text -> Text
conferSubject decision context =
  wfText
    [wf|
    The decision:

    {decision}

    The context. This may be empty, and empty means the decision stands on its
    own words -- it does not mean a document failed to arrive:

    {context}|]
```

### 1.2 The roster, which is data

```haskell
-- | Three parties, three stances, three distinct serving models.
--
-- __The three primaries are distinct on purpose.__ Routing keys on the serving
-- model and not on the party (`routing-design.md` §2.2), so two seats pinned to
-- one model are two seats on one backend however the run is routed. Three
-- ladders, three primaries -- `opus`, `gemini-3.1-pro-preview`, `fable` -- is
-- what makes `--route` able to put this roster on three providers, and it is
-- also what `Agentic.Chains` wants: each primary is pinned with one spelling,
-- so `servedChains` is well defined and the run does not refuse to start
-- (`Chains.hs:70`--`:86`).
--
-- __`lensOwns` is load-bearing and not decoration.__ `memberNote` derives every
-- party's sibling table from this column, so "do not write their blocks for
-- them" is a sentence with a referent, and a fourth seat arrives in the other
-- three's briefs __by being added__.
conferRoster :: Roster
conferRoster =
  [ Lens
      { lensName = "for",
        lensOwns = "the strongest honest case that the decision is right",
        lensBrief = underChallenge forStance,
        lensParty = reasoning (model "advocate")
      },
    Lens
      { lensName = "against",
        lensOwns = "what breaks, traced to a mechanism",
        lensBrief = underChallenge skepticStance,
        lensParty = lateral (model "skeptic")
      },
    Lens
      { lensName = "neutral",
        lensOwns = "which claims the context settles, and which it cannot",
        lensBrief = underChallenge neutralStance,
        lensParty = broad (model "assessor")
      }
  ]
```

`lensName` is the **block label** in the folded document and never the
addressee's id — which is `panelText`'s own rule, stated where the combinator
lives: *"two members of one spread routinely share an addressee, and a document
whose names change when an operator repoints a lens is naming the wrong thing"*
(`Workflow.hs:651`–`:653`). It is also, as §4.3 shows, what makes the artefact
stable under routing.

### 1.3 The synthesis brief, derived from the roster it will refuse on

```haskell
-- | The brief for the question that reads all three blocks.
--
-- The first half is `refusingSynthesis`' argument, unchanged and unarguable:
-- an unauthenticated backend returns nothing, and nothing folded into a
-- recommendation reads exactly like agreement. A confer is the shape where
-- that failure is most expensive, because the whole claim of the artefact is
-- that N parties were consulted.
--
-- The second half is confer's own, and is where it differs from a review
-- synthesis: a review deduplicates and ranks findings; a confer locates
-- __disagreement__ and says what turns on it.
conferSynthesis :: Roster -> Text
conferSynthesis r =
  wfText
    [wf|
    Below is the decision, its context, and a document of {count} blocks, one
    per party, each fenced under its own name. The parties and what each was
    asked to own:

    {table}

    First, account for the blocks. If any named party's block is missing or
    empty, reply with exactly

      INCOMPLETE: <the names of the missing blocks>

    and nothing else. Do not synthesise what did arrive: a partial roster
    folded into a recommendation is indistinguishable from a unanimous one, and
    that is the one mistake this step exists to prevent.

    Otherwise:

    - Say where the parties actually disagree -- not where they used different
      words for one thing. Quote the sentence from each block that carries the
      disagreement.
    - For each disagreement, say what turns on it: what would follow if each
      side were right.
    - Then the recommendation, in one paragraph, and the condition that would
      change it.

    Attribute every load-bearing claim to the block it came from. You are the
    only party that has read all of them, and a claim you cannot attribute is a
    claim you introduced.|]
  where
    count = tshow (length r)
    table = rosterTable r
```

### 1.4 The provenance, which is where the single-backend caveat lives

```haskell
-- | What the artefact says about how the confer was run.
--
-- /Source:/ `Rubrics/Discipline.hs:169`'s `unverifiedIndependence`, whose whole
-- shape is: a report that did not establish something does not get to imply it.
--
-- A confer's implied claim is that N parties were consulted. Today's engines
-- bind every addressee to one backend per run (`Cli.hs:711`, `:743`), so a
-- three-block document produced by three sessions of one model is exactly as
-- honest as it says it is and no more. The pins below are what the __program__
-- asked for; the run header is the record of what the __run__ did, and the two
-- are different statements. This says so.
conferProvenance :: Roster -> Text
conferProvenance r =
  wfText
    [wf|
    Provenance: the `confer` workflow, {count} parties.

    {table}

    Those are the models the program pins. Whether they were answered by
    distinct backends is a property of the run and not of the program: unless
    the run's header names more than one backend, every block below was
    produced by the one answerer this run was pointed at, in a separate session
    per question. Separate sessions are independence of context, not
    independence of judgement. Do not describe agreement between two blocks as
    independent confirmation unless the header says the two were answered by
    different backends.|]
  where
    count = tshow (length r)
    table = bullets [(lensName l, lensOwns l) | l <- r]
```

### 1.5 The program

```haskell
-- | Confer over any roster. The shape is one; the roster is data.
--
-- Every variant in §5 is this function at a different table, which is why each
-- of them is one line and why none of them can drift from this one in anything
-- but its roster.
conferOver :: Roster -> Text -> Text -> Program
conferOver roster decision context = workflow W.do
    stances <- panelText (zip (lensNames roster) (asksOver roster stanceClosing subject))

    recommendation <- ask (reasoning (model "synthesis")) [wf|
        {synthesis}

        {subject}

        {stances}|]

    ask_ reporter [wf|
        {writeBrief}

        {provenance}

        {stances}

        {recommendation}|]
  where
    subject = conferSubject decision context
    synthesis = conferSynthesis roster
    provenance = conferProvenance roster
    writeBrief = conferWriteBrief

-- | The program the registry holds: `conferOver` at the standing roster, with
-- its two inputs.
--
-- An input is a `define` supplied at run time (`Workflow.hs:1874`), so a
-- program with inputs is an ordinary Haskell function of them and
-- `conferOver conferRoster` __is__ that function already: `Curried` reduces
-- `(Text, (Text, ()))` to `Text -> Text -> Program`, which is this signature.
confer :: Parameterized
confer = taking (input "decision" (input "context" noInputs)) (conferOver conferRoster)
```

with the closing brief:

```haskell
-- | The artefact.
--
-- The blocks go in __verbatim__ and the recommendation goes in beside them,
-- because the whole difference between a confer and an opinion is that the
-- reasoning is inspectable. A tool and not a model: an act at `receipt` is the
-- only kind of answer the ACP transport grants write authority to
-- (`Parties.hs:173`--`:179`).
conferWriteBrief :: Text
conferWriteBrief =
  wfText
    [wf|
    Write the confer below to `confer-<date>.md` in the current directory:
    the provenance line first, then every party's block verbatim under its own
    name, then the recommendation, marked as one reading of the blocks and not
    as their sum.

    Change no party's words. The blocks are the evidence; the recommendation is
    an argument about them, and a reader who disagrees with the argument must
    be able to check it against what was actually said. Then reply DONE.|]
```

**Why the run ends in an act.** A run announces each answer through
`announcingWorld`, which prints it through `oneLine` (`Exec.hs:247`) — a
multi-paragraph stance collapsed to a single console line. The trace holds the
answers, but the trace is not a document a person reads over coffee. So confer
pays one leaf for its artefact, exactly as `Example.Isaac`'s `review-lite` pays
one for a fold `incite` gets for free — and, as there, it is worth naming as a
cost rather than hiding: **confer is five questions where PAL's `consensus` is
three model calls plus caller-side prose.** What the two extra questions buy is
a synthesis that is a *question in the term* (priced, traced, attributable) and
an artefact on disk that no one had to copy out of a chat window.

**The write may equally be a call.** `call_ conferFn (arg provenance :> arg
stances :> arg recommendation :> noArgs)` followed by `stop`, where `conferFn`
is a `Fn '[ 'CodeText, 'CodeText, 'CodeText] 'CodeAck` in the report family,
prices **identically**: a call is priced at the callee's own `bodyAsks` and
`graft` splices the callee's node rather than adding one (`Report.hs:19`–`:22`).
Which one confer uses is a question about whether confer's output format should
be shared with another rung, and that is the architecture phase's call, not this
document's. Both spellings are `askNodes 5`.

### 1.6 Every construct used, and where it comes from

Every name below exists today. Nothing in this design needs a new combinator in
`Agentic.Workflow`.

| construct | export | used for |
|---|---|---|
| `workflow` | `Workflow.hs:1785` | the program, at the empty function table |
| `taking`, `input`, `noInputs`, `Parameterized` | `:1917`, `:1910`, `:1906`, `:1892` | the decision and the context as run-time defines |
| `wf` quoter, `Says` | `Agentic.WF` | every prompt and every define |
| `panelText` | `:657` | the fold (§2) |
| `ask` | `:611` | the synthesis question |
| `model`, `tool` | `:545`, `:549` | the addressees |
| `servedBy`, `fallingBackTo` | `:559`, `:575` | inside `reasoning`/`broad`/`lateral` |
| `ask_` | `:1249` | the closing act and the terminal, in one statement |
| `Program` | `Agentic.Builder` | the type |
| `caseVerdict`, `panel` | `:1383`, `:637` | the `conferGate` variant only (§5.4) |
| `call_`, `arg`, `:>`, `noArgs`, `defining` | `:1722`, `Gives`, `:1776` | the alternate spelling of the write (§1.5) |

Two constructs are deliberately **not** used, and their absence is the design:

- **No `revising`.** A confer does not iterate to approval; it collects and
  recommends. A bounded revision would turn the parties into reviewers of one
  another, which is a different workflow (and a more expensive one — a
  `revising` at `atMost n` replicates its tail `2n+1` times).
- **No `if`, no `case`, no `decide`.** Confer does not branch, which is why it
  is `level pipeline` and has one price (§3). The module therefore does not
  need `RebindableSyntax` at all — the tree's standard header includes it
  because `if` reaches `ifThenElse` there, and a confer module may keep the
  standard header for uniformity or drop the pragma and the explicit `Prelude`
  import with it. Nothing else moves.

### 1.7 The two requirements this places on the foundation

Both are forced by the pal-note's own sentence — *"It should take the decision
text and optional file context as inputs"* — and neither is a layout claim.

**R1. A fan-out's subject must be anything a hole may name, not only a live
handle.** `asksOver` is typed `(KnownIx h s) => Roster -> Text -> V h 'CodeText
-> [Ask s]` (`Panels.hs:153`), so its subject must be a *binding*. Confer's
subject is a *define*, because its subject is an input, and an input is a define
supplied at run time. The generalization is one constraint:

```haskell
asksOver :: (Says a s) => Roster -> Text -> a -> [Ask s]
```

`Says` has exactly the three instances a hole may resolve to — a live `V h c`,
a `Text`, and a `[Piece s]` fence (`WF.hs:117`–`:137`) — so this widens the
subject to precisely the set of things the prompt could already have spliced,
and every existing caller resolves through the `Says (V h c) s` instance
unchanged. The `KnownIx` constraint moves from the signature into that
instance, where it already lives.

Without R1, confer must either open by asking a tool to read the decision —
which spends a question and turns the operator's text into an *answer*, the
difference `Example/Isaac.hs:504`–`:508` names — or hand-roll a private copy of
`asksOver`, which is the parallel-implementation shape this repository's own
review discipline exists to catch.

**R2. The fold-to-document must take its closing line.** `documentPanel`
(`Panels.hs:181`) hard-codes *"Report your findings and nothing else"*, which is
right for a review roster and wrong for a stance roster: a party arguing a case
is not reporting findings. `asksOver` already takes its closing as a parameter;
`documentPanel` should too —

```haskell
documentPanelWith :: (Says a s) => Text -> Roster -> a -> Rhs s 'CodeText
documentPanelWith closing r subject = panelText (zip (lensNames r) (asksOver r closing subject))
```

— with today's `documentPanel` as `documentPanelWith reportClosing`. Until it
exists, §1.5's program writes that one line itself, which is what it does above.

**A third, optional.** `conferSynthesis`' first half and `refusingSynthesis`'
first half are the same paragraph with different nouns. If the architecture
phase wants it shared, the fragment is `accountForBlocks :: Roster -> Text` and
both briefs hole it. Not required; noted because the argument in that paragraph
is the tree's, not confer's, and an argument stated twice drifts once.

---

## 2. The fold: `panelText`, argued against both rivals

Three shapes could hold three parties' answers. Two of them cost exactly the
same. The argument is therefore not about price.

### 2.1 Not `panel`: a verdict is not a consensus

`panel` folds its members right in the noncommutative verdict monoid
(`Builder.hs:626`–`:648`). Four things follow, and each of them is fatal here:

1. **The prose is gone.** A verdict is `approve`, or `objection: <lines>`, or
   `declined`. Three arguments, each the reason the party was consulted, become
   a tag and at most one line apiece. The synthesis then has nothing to
   synthesise, and the human artefact — the thing the owner actually wants out
   of a confer — does not exist at any point in the run.
2. **A declining party annihilates the fold.** `declined` is the absorbing
   element. One party that will not answer takes the other two's contributions
   with it, and what the run has in hand is "no answer" for the *roster*, not
   for the member. That is the correct semantics for a gate (one reviewer who
   refuses to review has not approved) and the wrong one for a survey.
3. **It forces the stance into a vote.** Every panel member is elaborated at
   `verdict` positionally (`Check.lean:365`, ported at `Builder.hs:628`), so
   each party's prompt has to end in "reply APPROVE or OBJECTION". A party told
   to reduce a judgement call to a two-valued answer will do it, and the
   reduction is the analysis being thrown away at the source rather than at the
   fold.
4. **Attribution is positional and lossy.** Objections concatenate in member
   order; nothing in the folded value says which member raised which. The
   document form carries the attribution in the bytes.

### 2.2 Not three separate binds: the same price, a worse shape

Three `x <- ask …` statements and three holes in the synthesis prompt is
`Example/Isaac.hs`'s `grindTestsProgram` (six lenses, one synthesis), it works,
and it costs **exactly what `panelText` costs**: `panelText` grafts one `PAsk`
per member (`Plan.hs:742`–`:746`), so three members are three ask nodes either
way. Four differences, none of them about money:

| | three binds | `panelText` |
|---|---|---|
| the roster | three statements; a fourth party is a new statement *and* a new hole in the synthesis prompt | a list; a fourth party is a new row (`Isaac.hs:1345`–`:1356` names the static-list limit, and a member list is the one place it does not bite) |
| the boundary between answers | whatever the prompt's line breaks are | `<for>\n…\n</for>\n`, and a member that writes `</for>` in its own body gets it defanged (`Text.hs:357`) |
| who said what | the prompt's layout, by convention | the label, in the bytes, and the label is the author's |
| what a later statement can read | each answer alone | the document; a single member's answer is not separately spliceable |

The last row is the honest cost of `panelText`, and it is what decides between
the two: **use separate binds when a later statement needs one member's answer
alone.** Confer never does. It needs all three, once, in one place, in member
order — which is `panelText`'s exact shape.

The fencing is not a nicety. `escapeClose`'s haddock states the threat plainly:
*"If it may contain `</alpha>`, a member can forge the end of its own block and
open a block of its own choosing, and the synthesis that reads the document is
steered by a member"* (`Text.hs:345`–`:348`). Three parties asked to argue
opposing sides is precisely the configuration where one of them has an incentive
to write the others' block. Three separate binds concatenated into one prompt
have no defence against this at all. PAL's `consensus` has none either: it
concatenates responses into the caller's context and the caller reads them as
prose.

### 2.3 And the independence is structural

No member of a fan-out can see another's answer, because none of them is bound
when the others are asked: all members stand at one scope, in one list, before
the bind. `Workflows.Panels`' own haddock makes the same observation about
`skills/parallelize` — *"a panel is independent by construction… no member sees
another's answer, and no `ask` writes anything"* (`Panels.hs:21`–`:31`). PAL's
`consensus` consults its roster one model at a time and relies on the server not
to thread them; here it is not a policy that could be changed.

### 2.4 Where `panel` *is* right, and it is not confer

If what the owner wants is a **go/no-go** rather than a document — three parties
must all approve before the run proceeds — that is `panel` plus `caseVerdict`,
it is a different program, and §5.4 prices it. Calling it a confer would be
naming a gate after a survey.

---

## 3. The price: the pre-spend contract

### 3.1 What `wf plan confer` prints

```
confer, as elaborated:

  inputs    decision (text) = 412 B given with --input-arg
  inputs    context (text) = 6.1 kB from ./proposal.md
  level     pipeline
  size      6
  askNodes  5
  codes     text, text, text, text, receipt
  cost      minFold 5, maxFold 5, over 1 path
  (--raw prints the program itself)
```

Every number is a fold of the elaborated term (`Cli.hs:565`–`:594`), and each
is derivable by hand:

- **`askNodes 5`** — `PAsk` counts one per consultation written
  (`Plan.hs:957`): three panel members (`panelText` grafts one `PAsk` per
  member, `Plan.hs:742`), one synthesis, one closing act. An act is an ask at
  `receipt`; `ask_` is `act` and then `stop`, *literally the same term*
  (`Workflow.hs:1236`–`:1240`).
- **`size 6`** — `size` counts nodes and a straight line is `askNodes + 1` for
  the terminal `PRet` (`Plan.hs:942`). Compare `helloProgram`: `size 4`,
  three asks.
- **`level pipeline`** — `PAsk` joins `Pipeline`; there is no `PCase`, because
  confer has no `if`, no `caseVerdict` and no bounded revision
  (`Plan.hs:928`–`:934`).
- **`codes`** — the sequence is fixed exactly because the program does not
  branch: four text answers and a receipt. A `Nothing` here would mean "the
  program branches, so no one sequence of answer kinds".

### 3.2 What `wf cost confer` prints

```
confer, priced:

  inputs    decision (text) = 412 B given with --input-arg
  inputs    context (text) = 6.1 kB from ./proposal.md
  costSummary   minFold 5, maxFold 5, over 1 path

  every path consults 5 times, so this program has one price and not a range.

  the fold, path by path (1 in all):
    5
```

**One path, one price.** `costM` is the bag of bills, one element per path
(`Plan.hs:1020`); with no `PCase` the bag is a singleton. A run's `billFresh`
that is not 5 is a run of a different program — which is what a bound is *for*
(`Cli.hs:602`–`:606`), and confer is the rare shape where the bound is an
equality.

A scripted run then reports:

```
  the run is over.
    answer      () — a workflow's value is the unit; what it did is the trace
    billFresh   5 (consultations the run reached)
    billMemo    5 (distinct questions, which is what was put)
```

`billMemo` equals `billFresh` because all five prompts differ. Worth checking
rather than assuming: the memo key is code, addressee, scope, prompt and draw,
so even two parties given *identical* stance text would be two questions by
their addressees alone — and if a future roster ever wanted the same party
sampled twice, `drawing` is the surface for it ("two draws of one prompt are two
questions, which is what the memo bill prices apart", `Workflow.hs:605`).

### 3.3 What this contract is, that PAL has no analogue for

Four properties, in descending order of how much they matter.

1. **It is available before the decision exists.** `plan` and `cost` do not
   require the inputs — an ungiven input prints *"not given; the folds below do
   not depend on it"* (`Cli.hs:532`), and only `run` demands every one
   (`Cli.hs:501`). So `wf cost confer` answers "what will this spend" before a
   word of the decision has been written. PAL's first sight of cost is the
   response.
2. **It is checkable after.** A five-question contract that a run bills at four
   or six is a discrepancy anybody can see, and `ci/examples.sh`'s discipline —
   *"a new program cannot be registered without being priced"* — is what makes
   that a gate rather than a hope for the examples registry. (The toolbox
   registry deliberately does not pin by equality, and `Registry.hs` states
   why: a reworded rubric moving a number is a Tuesday.)
3. **It is a question count and not a token count, and that cuts both ways.**
   Splicing the whole context into the synthesis prompt as well as into the
   parties' — which §1.5 does, so that the party writing the recommendation has
   read the artefact and not only three summaries of it — costs **nothing** the
   price counts. Adding a fourth party costs one. That is the correct
   incentive: the language prices the thing that has a semantics (a
   consultation) and not the thing that does not (a byte count that no fold in
   the kernel mentions). It is also the honest limitation: confer's price does
   not tell an operator what the run will cost in money.
4. **`--require-pinned` is a pre-flight, not a convention.** `wf plan confer
   --require-pinned` refuses a program that leaves a model ask without a
   `served by`, before a plan is printed or an adapter started
   (`Cli.hs:353`–`:359`, `Guards.hs:397`). Confer passes by construction: every
   seat and the synthesis are pinned through a ladder. PAL's nearest equivalent
   is a `listmodels` preflight the caller has to remember to run.

### 3.4 The roster is what moves the number

`askNodes` is `|roster| + 2` for confer and `|roster| + 1` for `confer_`. A
five-party roster is `askNodes 7`, still `pipeline`, still one path, still one
price. This is the whole of confer's cost model and it is legible at a glance —
which is the point `Example/Isaac.hs:1367`–`:1381` makes about
`4611686018427387927`, the nineteen-digit worst case that `agent-functor`'s
unbounded loop compiles to and that "no operator can read anything from".

---

## 4. Operation

### 4.1 Today: one backend, three sessions, and the report says so

Both engines bind every addressee to one backend per run. The header says it in
as many words:

- ACP: *"cwd …, 900000ms to a turn, a new session per question; every addressee
  — model, tool and person — is this one adapter"* (`Cli.hs:736`–`:744`);
- deck: *"every addressee — model, tool and person — is this one session"*
  (`Cli.hs:705`–`:711`).

```
wf run confer --engine acp --adapter claude \
  --input-arg decision='Should the parser be rewritten as a table-driven DFA?' \
  --input-file context=./doc/parser-notes.md
```

**This is useful today, and the useful part is exact.** `acpFreshPerQuestion`
defaults to `True` (`Acp.hs:330`) and the CLI never overrides it, so every one
of the five questions opens its own `session/new`. The three parties are three
sessions of one model: none of them can see the others' answers, none inherits
a transcript, and each is reading only its own stance and the subject. That is
**independence of context** — a real kind, and the kind that PAL's
`continuation_id` threads deliberately do *not* give you. It is not independence
of weights, and §1.4's `conferProvenance` is what stops the artefact implying
otherwise: agreement between two blocks of a single-backend run is not
independent confirmation, and the document says so on its own first line.

The deck engine is the weaker configuration for a confer and should be named as
such: one durable session for the whole run means the parties **do** share
context, in program order, so the third party has read the first two. Prefer
`--engine acp` for confer; use `--engine deck` when the point is to put the
confer into a session a person is watching.

The pins do three things today, none of which is choosing a backend:

1. they are the fail-over chain (`Chains.hs`), and *"fail-over is a service you
   get by pinning"* (`Exec.hs:469`) — an unpinned question has no candidate list
   to walk;
2. they land on the question's scope model axis, which is what the trace records
   as who answered and what `candidates` relabels on fail-over
   (`Exec.hs:470`–`:477`);
3. they are what `--require-pinned` checks.

### 4.2 The day routing lands

`routing-design.md` §1.1's flag, at confer:

```
wf run confer --require-pinned \
  --engine acp --adapter claude \
  --route 'gemini-3.1-pro-preview=deck:gemini-pane' \
  --route 'gpt-5.5-pro=acp:codex' \
  --input-arg decision='…' --input-file context=./proposal.md
```

and the header becomes a table naming three backends, the default's remainder,
and the pinned models no route claims (`routing-design.md` §5.2). The `for` seat
(`reasoning`, primary `opus`) takes the claude default; `against` (`lateral`,
primary `gemini-3.1-pro-preview`) goes to the deck pane; `neutral` (`broad`,
primary `fable`) takes the default too, and its **first spare** is
`gemini-3.1-pro-preview` — so if `fable` will not answer, that seat falls over
onto a different provider, which is the capability in one sentence.

### 4.3 Why the roster does not move, in four steps

The requirement is that routing lands **without changing program text**. It
holds, and here is why rather than the assertion:

1. **A route names a serving model, never a party.** `backendFor` reads
   `scopeModelAxis (qScope q)` and nothing else (`routing-design.md` §2.2). The
   roster's serving models are `opus`, `gemini-3.1-pro-preview` and `fable` —
   `Text` constants in `Workflows.Parties`, written down before either design
   existed, under the heading *"a serving model is what answers **for** an
   addressee, and the addressee is the role"* (`Parties.hs:82`–`:86`).
2. **A pin is not part of the question.** Two asks differing only in their pin's
   alternates elaborate to the same plan, put the same question and bill the
   same, because the chain is a property of the model that `Agentic.Chains`
   collects before the run (`Chains.hs:11`–`:15`). So the ladders cost nothing
   to write and nothing to price, today or after routing.
3. **A route is not part of the price.** `--route` is a `run` flag and
   explicitly not a `plan`/`cost` flag: *"a price that varied with a route table
   would be the first time in this language that who answers changed what a
   program costs"* (`routing-design.md` §1.1). So §3's numbers are the numbers
   before and after, unedited.
4. **The artefact does not move either.** The document's block names are
   `lensName`s — `for`, `against`, `neutral` — which are the author's and not
   the addressee's id (`Workflow.hs:651`). Repoint a seat at another provider
   and the artefact's section headings are byte-identical. That is the property
   `panelText`'s label rule exists for, and confer is the workflow where it pays
   off: two confer reports a month apart are comparable across a fleet change.

The one thing that *would* move the program text is wanting three backends
where two seats share a serving model — because routing keys on the model, two
seats pinned to `fable` are two seats on one backend however the run is routed.
§1.2's three distinct primaries are chosen for exactly this, and the reason is
written on the roster rather than left in a design document.

**And the pins are worth writing now, before routing exists.** They buy
fail-over today, they satisfy `--require-pinned` today, and they are the routing
keys tomorrow. The only cost is that a single-backend run names models it did
not reach — which the header already contradicts truthfully in the line above
the first question, and which `conferProvenance` repeats inside the artefact
where a reader will actually be.

---

## 5. Variants, as thin wrappers

Each is `conferOver` at a different roster, or the same program minus a
statement. None of them is a second copy of anything.

| variant | roster | `askNodes` | `size` | level | cost | codes |
|---|---|---|---|---|---|---|
| `confer` | 3 seats | **5** | 6 | pipeline | 5, 1 path | text ×4, receipt |
| `confer_` | 3 seats, no synthesis | 4 | 5 | pipeline | 4, 1 path | text ×3, receipt |
| `debate` | 2 seats (for/against) | 4 | 5 | pipeline | 4, 1 path | text ×3, receipt |
| `secondOpinion` | 1 seat, challenge only | 2 | 3 | pipeline | 2, 1 path | text, receipt |
| `conferGate` | 3 seats, verdict fold | 6 | 10 | **branch** | 4, **3 paths** | (none — it branches) |

### 5.1 `confer_` — the blocks, unsynthesised

```haskell
-- | Confer with no synthesis: the parties' blocks, written down and not
-- reconciled.
--
-- /Source of the argument:/ `review-lite`'s fold is `hierarchical` -- reorder,
-- then union -- and it has no synthesis leaf __on purpose__, "because six
-- independent opinions are worth more unreconciled than one reconciled one"
-- (`Isaac.hs:1052`--`:1054`). A decision the owner intends to make personally
-- wants the same thing: three arguments and no aggregator standing between
-- them and the reader.
conferBareOver :: Roster -> Text -> Text -> Program
conferBareOver roster decision context = workflow W.do
    stances <- panelText (zip (lensNames roster) (asksOver roster stanceClosing subject))

    ask_ reporter [wf|
        {writeBrief}

        {provenance}

        {subject}

        {stances}|]
  where
    subject = conferSubject decision context
    provenance = conferProvenance roster
    writeBrief = conferBareWriteBrief

confer_ :: Parameterized
confer_ = taking (input "decision" (input "context" noInputs)) (conferBareOver conferRoster)
```

The brief differs in one clause — write the blocks, reconcile nothing, rank
nothing — which is `reviewReportBrief`'s clause at `Isaac.hs:494`–`:499`.

*A note on the task's wording.* This was specified as "raw verdicts". Under
§2's ruling the raw thing is a fenced **document**, not a verdict; a variant
that really wanted verdicts is `conferGate` (§5.4), and it is a gate.

### 5.2 `debate` — the pair, and only the pair

```haskell
-- | For and against, with the synthesis. The middle seat is what a debate
-- deliberately does not have.
debateRoster :: Roster
debateRoster = [seat | seat <- conferRoster, lensName seat /= "neutral"]

debate :: Parameterized
debate = taking (input "decision" (input "context" noInputs)) (conferOver debateRoster)
```

Filtering the standing roster rather than writing a second table is the point:
`memberNote` and `conferSynthesis` both derive from whatever list they are
handed, so the two seats' briefs tell each of them that there is exactly one
other party and who it is, and the synthesis refuses on exactly two blocks. Add
a seat to `conferRoster` and `debate` is unaffected; rewrite a stance and both
programs get it.

### 5.3 `secondOpinion` — one party, the challenge rubric

```haskell
-- | The quick second opinion: one party, no stance, no roster, no synthesis.
--
-- This is PAL's `challenge` and PAL's `chat` in one program, and it is the
-- shape the owner reaches for most often -- which is why it is a row and not a
-- flag on `confer`.
secondOpinion :: Parameterized
secondOpinion = taking (input "decision" (input "context" noInputs)) \decision context ->
  workflow W.do
    opinion <- ask (lateral (model "second")) [wf|
        {challengeRubric}

        {subject}

        {opinionClosing}|]

    ask_ reporter [wf|
        Write the opinion below to `second-opinion-<date>.md`, verbatim, under
        a heading naming the question. Then reply DONE.

        {subject}

        {opinion}|]
  where
    subject = conferSubject decision context
    opinionClosing =
      "Say whether the claim holds, where it is weakest, and what would change \
      \your answer. At most ten lines."
```

`lateral` and not `reasoning`: the whole value of a second opinion is that it is
not the party that produced the first, and `lateral`'s haddock says exactly that
— *"a second opinion from somewhere else… and the reason its primary is not the
house model"* (`Parties.hs:130`–`:133`). Under a routed run it goes to another
provider by the roster's own words.

Note the write is not optional here either, for §1.5's reason: `ask_` at a
*model* would be an ask at `receipt`, and the runner appends *"Do what was
asked, then reply with exactly DONE"* (`Exec.hs:648`) — the opinion would be
asked for and thrown away. Two questions, and the second is the artefact.

### 5.4 `conferGate` — the one place `panel` is right

```haskell
-- | Not a confer: a gate. Three parties must approve before the run proceeds.
conferGate :: Roster -> Text -> Text -> Program
conferGate roster decision context = workflow W.do
    verdict <- panel (asksOver roster verdictSpec subject)

    caseVerdict verdict
      (ask_ reporter [wf|Record that the panel approved, then reply DONE.{subject}|])
      (ask_ reporter [wf|Record the panel's objections verbatim, then reply DONE.{verdict}|])
      (ask_ reporter [wf|Record that a party declined to answer, then reply DONE.{subject}|])
  where
    subject = conferSubject decision context
```

Priced: three panel asks plus one act per arm is `askNodes 6`; `size` is
`3 + 1 + 3×2 = 10` (a `case` counts itself, `Plan.hs:947`); `costM` is `[4,4,4]`
— `minFold 4, maxFold 4, over 3 paths` — and `codes` is `null`, because a
program that branches has no one sequence of answer kinds. It is `level branch`,
and that is the honest signal that it is a different animal from the four above.

---

## 6. What confer does not try to be

### 6.1 Not PAL's seven guided investigations

`thinkdeep`, `debug`, `codereview`, `analyze`, `planner`, `precommit`,
`refactor` are step-numbered forms the *calling agent* fills in as it
investigates, ending in one validation call — and the discipline is *"an honor
system over parameter names"* (`pal-vs-agent-cat.md`). They are not confer's to
mirror, for two reasons and the second is decisive:

1. The corpus's own commands already cover those shapes, and the ai-config
   track's triage owns them. `pal-note.md` says so explicitly: *"the triage
   should not invent separate workflows to mirror PAL's tool names."*
2. Mirroring a tool name would produce a workflow whose *shape* is a form. The
   agent-cat expression of `debug` is not a program called `debug`; it is a
   `revisingOn` whose settle/amend/abandon comes from a verdict, a `decide` that
   reads a gate for zero questions, and a `toolExec` receipt the world authored
   by actually running the build. Those are the corpus's own workflows, and they
   are being built from the owner's own command corpus, not from PAL's tool
   list.

Confer is the one PAL tool that is a **shape** rather than a form — a roster, a
fan-out, a fold, a synthesis — which is why it is the one that gets a workflow
of its own.

### 6.2 Not automatic model selection

PAL ships a scored catalog and picks a model per task. Confer pins its parties,
and this is **a feature declined on principle**, not one missing. The argument
is `pal-vs-agent-cat.md`'s, and it is short:

> agent-cat pins parties on purpose — *a program that does not know who answers
> cannot honestly price or attribute* — so this is a feature declined rather
> than a feature missing. The fail-over ladder (`servedBy` alternates) is the
> principled fragment of it.

Three consequences hold in this design specifically:

- **Attribution.** The artefact names, per block, which model was asked. Under
  auto-selection the document could not say what it was a document *of*, and a
  confer whose blocks are anonymous is three paragraphs of prose.
- **Comparability.** Two confers a month apart are comparable because the roster
  is in the source and moves when somebody edits it. A roster that varies per
  call by a scoring heuristic makes every comparison a coincidence.
- **`--require-pinned` would become unenforceable.** A guard that refuses an
  unpinned model ask cannot coexist with a system whose selling point is that
  asks are unpinned.

What confer *does* take from the idea is the ladder: `reasoning`, `broad`,
`lateral` are three named policies about the *kind* of answering a seat wants,
each with its spares in order, and a model retirement moves one rung rather than
sweeping every brief in the tree.

### 6.3 Not a replacement mandate

`pal-note.md`'s framing is the operative one: confer is *"an alternative
offered, not a replacement mandated"*. The `wiggum` and `heavy` skills' "confer
via PAL for real decisions" clause can, once confer is registered, read "or run
`wf run confer`" — and both remain true sentences.

### 6.4 Not a claim about independence it has not established

Stated once more because it is the failure this design is most likely to be
accused of later: a three-block artefact produced by one backend is not three
independent opinions, and confer's own provenance line says so. When routing
lands and the header names three backends, the same line stops disclaiming what
is no longer true — and the *only* thing that changes is the run's header,
because the sentence is derived from the roster and the roster did not move.

---

## 7. Open questions for the architecture phase

Five, each of which this design has an opinion about and none of which it owns.

1. **Where confer's rubrics live.** Four stance defines, one challenge define,
   two briefs and one provenance. They are `Rubrics/`-shaped; whether they are
   `Rubrics/Stances.hs` or something else is the layout question this document
   deliberately does not answer.
2. **R1 and R2** (§1.6) — the `Says` subject and the parameterised closing.
   Both are one-line signature changes in `Workflows.Panels`, and confer is
   blocked on neither (it can inline the fold and hand `asksOver` a handle),
   but taking them is what keeps confer from being a second implementation of
   an existing fan-out.
3. **Whether the write is a `Fn`.** §1.5 shows both spellings at identical
   prices. A `conferFn` in the report family is right if any other rung will
   ever produce a confer-shaped artefact; `ask_ reporter` is right if none will.
4. **The registry rows.** `confer` and `secondOpinion` are certain; `confer_`
   and `debate` are one line each and cost nothing to carry;
   `conferGate` is a gate and might belong with the gates instead. The naming
   rule is the registry's: *the owner's own word where one exists, and one name
   per shape, never one per invocation* (`Registry.hs`).
5. **The scripted table.** Four rows — one per seat, keyed on `lensBrief l`
   derived from the roster, plus one on `conferSynthesis roster` — and nothing
   for the closing act, because `scriptedDefault` answers a receipt `DONE`
   (`Exec.hs:1350`). This is `helloScript`'s shape exactly (`Hello.hs:99`–`:106`)
   and it works only because §1.1 puts the shared rubric *after* the stance; a
   confer whose seats shared an opening chunk would have a scripted run in which
   one canned answer served all three, and the fan-out would be untested by the
   gate that exists to test it.
