# Meaning and Representation

This document explains the two layers of agent-cat and the function between
them. The first layer is a meaning: a mathematical object chosen because it
explains the domain well, with no regard for whether it can be computed. The
second layer is a representation: a finite syntax that an author writes, that
tools analyse before it runs, and that a runtime executes against a live
agent. The proofs in `model/Agentic/Core` show that every operation of the
second layer commutes with the function into the first.

Dependence runs one way. The meaning constrains the implementation, and the
implementation never constrains the meaning (Elliott, *Denotational Design
with Type Class Morphisms*, 2009). The sections below follow that order: the
meaning, the representation, the function that joins them, the analyses that
only the representation supports, execution, and the point at which proof
gives way to stated assumption. The Texinfo manual in `doc/agent-cat.texi`
gives the same material as reference chapters; this document gives the
argument.

## Part I. The meaning

The design begins with one sentence about the domain. A workflow puts
questions to parties, receives typed replies, and uses those replies to decide
which question to put next. Nothing in that sentence says how a question is
carried out, and the meaning keeps that silence.

### Worlds

A world is a total answer sheet with one reply for every question:

```lean
abbrev Ω : Type := (c : Code) → Q c → El c
```

`Code` names the kind of reply: text, verdict, flag, receipt, or a structured
value with a schema. `Q c` is a question of kind `c`. It records the
addressee, the scope, the prompt, and the draw. Together these four fields
are the whole of a question's identity. Equal questions receive one answer in
every world. Two authored occurrences of the same question remain two events
in the transcript, whether or not a runtime reuses the answer. A deliberate
resample changes the draw and therefore changes the question. The way an
occurrence is executed changes nothing here; that annotation appears later,
in the representation.

### What a workflow denotes

The first candidate for a meaning is a function from worlds to answers. It is
too coarse. Under it, a workflow that asks a question, discards the reply, and
then asks a second question would mean exactly what the second question means
alone. Every account of what was consulted, and of what it cost, would be
lost. The meaning therefore records both the result and the questions that
produced it:

```text
⟦ a workflow ⟧ : Ω → (A × Trace)
```

For each world, the meaning gives an answer together with the ordered
transcript of bare questions and their replies. Physical execution,
permission, memoization, and the intent behind an occurrence are not
observations of this object.

### Where the meaning is defined

A function of this type cannot be defined by cases on a workflow, because at
this stage a workflow is not yet a mathematical object. It is defined instead
on an intermediate carrier, the dialogue, which supports structural
recursion:

```lean
inductive Dlg (A : Type) : Type where
  | done : A → Dlg A
  | ask  : (c : Code) → Q c → (El c → Dlg A) → Dlg A
-- model/Agentic/Core/Dlg.lean:50
```

A dialogue is either finished, or one bare question paired with a
continuation for every possible reply. It is the free monad on the question
signature. Two folds give the result and the exact semantic trace:

```lean
def run (ω : Ω) : Dlg A → A
  | .done a    => a
  | .ask c q f => run ω (f (ω c q))

def trace (ω : Ω) : Dlg A → Trace
  | .done _    => []
  | .ask c q f => ⟨c, q, ω c q⟩ :: trace ω (f (ω c q))
-- model/Agentic/Core/Dlg.lean:136, :147
```

### In what sense the folds are the meaning

Calling this pair of folds "the meaning" makes three separate claims, and the
library discharges each one.

The folds constitute the semantic function. Together they define one map
from the carrier into the meaning space, `⟦p⟧ ω = (run ω p, trace ω p)`. A
dialogue is not itself the meaning. It is the thing the meaning is computed
from.

The folds respect composition. Both are monad morphisms, so the meaning of a
composite workflow is built from the meanings of its parts, and no separate
account of sequencing is needed:

```lean
theorem run_bind   : run ω (p >>= k) = run ω (k (run ω p))
theorem trace_bind : trace ω (p >>= k) = trace ω p ++ trace ω (k (run ω p))
```

The folds fix equality. Two workflows are the same workflow when their
meanings agree in every world:

```lean
Obs p p' ↔ ∀ ω, run ω p = run ω p' ∧ trace ω p = trace ω p'
```

One consequence deserves plain statement. The semantic function is not
injective. Dialogues that differ in structure can agree in every world, and
`Dlg.not_forcing` exhibits such a pair. Equality of dialogues is therefore
strictly finer than equality of meaning, so `Obs` is the equality of the
domain and the ambient equality of the carrier is not. Defining `Obs` as the
kernel of the meaning has one benefit and one cost. Congruence follows
directly, with no axioms and no quotient type. In exchange, `Obs` must be
written explicitly wherever two workflows are compared.

## Part II. The representation

A meaning of this kind cannot be inspected. The continuation inside a dialogue
is a function from an answer type that is not finite, so its branches cannot
be enumerated, its questions cannot be listed, and its cost cannot be priced.
That is the right posture for a specification and an unusable one for a
tool. The representation exists to be read, analysed, and executed.

```lean
inductive PlanF (A : Type) : Ctx → Type where
  | ret  (e : Expr Γ A)
  | askC (c) (q : Request c)                            (k : PlanF A (c :: Γ))
  | ask  (c) (s : Request.Shape c) (e : Expr Γ String)  (k : PlanF A (c :: Γ))
  | case (t : Tag) (e : Expr Γ t.El) (arms : t.El → PlanF A Γ)
  | dyn  (b : Code) (e : Expr Γ (El b)) (f : El b → PlanF A Γ)

abbrev Plan (Γ : Ctx) (A : Type) : Type := PlanF A Γ
-- model/Agentic/Core/Plan.lean:467, :525
```

`ret` returns a pure function of what is known. `askC` asks a closed request
whose words are already in the term. `ask` computes the words from earlier
answers and asks a request of fixed shape. `case` branches over a finite tag
with every arm present. `dyn` computes a plan from an unbounded answer. Each
asking node binds the answer it obtains, so a plan reads as a sequence of
bindings, and the context `Γ` lists the answers in scope. Two decisions in
this type do the work.

### First order, with binders

A point-free presentation, built from composition and tupling operators, can
be analysed but is hard to read, because the flow of values is expressed as
plumbing. A higher-order presentation reads well but cannot be analysed,
because a fold over it would need every answer type to be finite, and free
text is not finite. The representation takes neither path. It owns the
binder. Contexts are lists, variables are indices, and the author writes a
binding. Sharing is a variable mentioned twice. Branching is `case`. Nothing
needs a name.

### The shape is written, and only the words are computed

A request divides into a question shape, an execution intent, and words. Only
the words are computed from earlier answers:

```text
Request c  ≅  Request.Shape c × String
```

The semantic sequence of question shapes is therefore a projection of the
syntax. A question whose shape must depend on an answer uses `case`, where
all arms remain visible and priced.

### Intent, and why the representation carries it

`Request c` pairs a bare question with an `Intent c`. The intent has three
values. `consult` asks an addressee for an answer. `observe` reads external
state through a declared command. `effect` requests a change to external
state, and it is available only at the receipt code, so no plan can branch on
an alleged effect result (`model/Agentic/Core/Request.lean:27`).

The mathematics did not ask for this field, and that is the point. Part I
identifies a question by who is asked, in what scope, with what words, at
which draw. A runtime that executes a plan has to make decisions the
mathematics does not record. It must decide whether an occurrence may reuse an
answer already obtained for the same bare question. It must decide whether an
occurrence has to run every time it is reached, because it acts on the world.
It must decide whether the addressee may be granted tool permission, and in
what order the occurrence stands relative to other acts. Neither the answer
code nor the addressee settles these questions: a receipt-valued question to a
tool may be a harmless consultation or an act on the world. The author
therefore declares the intent, and the runtime reads it.

Intent lives in the representation and never in the question. Worlds stay
indexed by `Q`, so the answer to a question cannot depend on the policy under
which it is asked, and two workflows that ask the same questions in the same
order and hear the same answers have the same meaning under every execution
policy. The denotation projects the question and forgets the intent:

```lean
theorem denote_askC_intent_irrel (c : Code) (q : Q c) (i i' : Intent c) ... :
    denote (Plan.askC c ⟨q, i⟩ k) γ = denote (Plan.askC c ⟨q, i'⟩ k) γ := rfl
-- model/Agentic/Core/Denote.lean:234; the open-request form follows at :239
```

The annotation is fixed by source position, not chosen by an answer. An
ordinary value question lowers to `consult`. An executable tool in value
position lowers to `observe`. A statement-position act lowers to `effect`
(`model/Agentic/Core/Dsl/Check.lean:174`). Intent lives in the request shape
rather than in the words, so computing prompt words cannot change it
(`Request.intent_withPrompt`).

Operationally the tag buys four things. Consult and observe occurrences share
one memo table keyed by the bare question, so a repeated question is answered
once. Effect occurrences never read or populate that table; every effect is
dispatched, and it is billed per occurrence. Under the ACP transport only an
effect is granted tool permission, and effects enter an ordered lane so that a
later act cannot overtake an earlier one. Finally, every execution event
retains the authored request beside its answer source, so a trace can say
whether an answer was reused or which dispatched question produced it after
fail-over. The theorem that ties this back to Part I is the trace square
`Plan.execAnnotated_correct` (`model/Agentic/Core/AnnotatedExec.lean:190`):
the annotated executor returns the semantic value, extends the bare-question
table, and its execution trace erases event by event to the semantic trace.

The tag also has a ceiling. `observe` does not prove that a command is
read-only, and `effect` does not prove that a change occurred. A completed
adapter turn establishes that the adapter reported completion. Evidence about
the world requires an independent observation, which the workflow can be
written to include.

## Part III. The relation

One function joins the layers. It is defined by structural recursion on the
representation, and every theorem in the library is a statement about it:

```lean
def denote : Plan Γ A → Env Γ → Dlg A
  | .ret e,       γ => .done (e γ)
  | .askC c r k,  γ => .ask c r.question                    (fun x => denote k (x ∷ γ))
  | .ask c s e k, γ => .ask c (s.question.withPrompt (e γ)) (fun x => denote k (x ∷ γ))
  | .case e arms, γ => denote (arms (e γ)) γ
  | .dyn e f,     γ => denote (f (e γ)) γ
-- model/Agentic/Core/Denote.lean:78, as a PlanAlg fold
```

Denotation has two stages. The first is defined by recursion on syntax and
produces a dialogue. The second is defined by recursion on the carrier and
produces, for each world, an answer and a transcript. Their composite is the
meaning of a written workflow.

### The commuting square

Every way of building a plan has a counterpart way of building a dialogue,
and the requirement on each pair is one equation. Building a plan and then
taking its meaning agrees with taking the meanings and then building. This
square must commute for each operation:

```text
                        f
        Plan …  ──────────────────▶  Plan Γ B
           │                             │
   denote… │                             │ denote (·) γ
           ▼                             ▼
        Dlg …   ──────────────────▶  Dlg B
                        f̂
```

Here `f` is an operation on plans and `f̂` is the corresponding operation on
dialogues, taken from a standard structure wherever one exists. The theorem
for each row of the table is the commutativity of this square.

| Operation on plans | Counterpart on dialogues | Theorem |
|---|---|---|
| `graft p k`, run `p` and continue | `>>=`, monadic bind | `denote_graft` |
| the same, read on transcripts | `++`, concatenation | `trace_graft` |
| `panel ps`, several reviewers | `foldr (liftA2 (· * ·)) (pure 1)` | `denote_panel` |
| `under σ p`, a standing scope | reindexing of the world, `ω ∘ σ` | `run_under` |
| `case e arms`, finite branching | selection of the arm the answer names | `denote_case` |
| `revising n`, bounded revision | check-then-revise unrolling | `denote_revising` |

`model/Agentic/Core/Morphism.lean` holds one such theorem for every operation
the surface offers. Two of them repay a closer reading:

```lean
theorem trace_graft (hk : Denotes k K) :
    Plan.trace ω (Plan.graft p k) γ
      = Plan.trace ω p γ ++ Dlg.trace ω (K (Plan.run ω p γ) γ)

theorem denote_panel [Monoid (El c)] (ps : List (Plan Γ (El c))) :
    denote (Plan.panel ps) γ
      = (ps.map (denote · γ)).foldr (fun x y => (· * ·) <$> x <*> y) (pure 1)
```

The first says that the transcript of a sequence is the concatenation of the
transcripts. This is what makes every cost a monoid homomorphism on traces.
The second says that a review panel is the applicative lifting of the verdict
monoid's product across the reviewers' meanings. Verdicts form a monoid in
which approval is the unit and any objection carries, so the panel needs no
reducer of its own and inherits its laws from the standard library.

One equation is absent from the table because it needs no proof. Running a
plan is defined as running its denotation, `Plan.run ω p γ := Dlg.run ω
(denote p γ)`, so the square for execution commutes by reflexivity. There is
no second semantics to reconcile.

## Part IV. The difference, and what it purchases

The two layers are two different things, and the design rests on the
asymmetry between them. The meaning supports quantification over every world,
so a theorem can say that in all worlds the guide is consulted exactly once.
It supports the definition of equality, since two workflows are the same when
their meanings agree. It can be infinite and uncomputable without
embarrassment, because a specification that cannot run cannot be mistaken for
the artefact it constrains. And it is indifferent to scheduling, caching,
retry, and transport.

The representation supports folding: the level, the sequence of shapes, and
the cost tree are computable functions of a term. It supports typing by
context, so no answer can be mentioned before it arrives. It supports
execution, by an interpreter that opens a connection to a live agent. And it
records distinctions the meaning declines to record.

That last item governs the analyses, and one example shows why it matters. In
`denote`, the clause for `case` and the clause for `dyn` are the same clause.
The two nodes mean exactly the same thing. They differ only in what can be
established about them, since `case` carries every arm in the term while `dyn`
carries a function. Keeping the distinction in the syntax is possible because
the meaning does not record it. A representation may know more than its
meaning. It may never mean anything other than its meaning.

### The four levels

The level of a plan is a fold over the term rather than an index in its type
(`model/Agentic/Core/Level.lean:133`). A fold leaves the syntax free of proof
obligations and puts the whole analysis in ordinary functions.

| Level | Mark in the term | What is established about cost |
|---|---|---|
| `batch` | closed requests only | The request list is fixed by the term. The bill is exact and the same in every world. |
| `pipeline` | words built from answers | The shape sequence is a projection of the syntax. The bill is exact when prices depend on shape. |
| `branch` | finite branching | A finite cost tree exists. Every world's bill is one of its leaves, and folds give the extremes. |
| `dynamic` | a plan from an unbounded answer | A non-existence theorem, witnessed by a plan whose bills are unbounded. |

The hierarchy restricts nothing that may be written. It states what may be
known about what has been written. It is graded so that the common case, a
prompt assembled from an earlier answer, is priced exactly rather than
surrendered to the general case. The Haskell authoring surface emits no `dyn`
node, and the theorem `Dsl.checkProgram_level_le`
(`model/Agentic/Core/Dsl.lean:832`) states that every first-order program the
checker accepts lies at or below `branch`.

## Part V. Execution, and three statements of correctness

Production execution is Haskell. Lean keeps two reference interpreters.
`SemanticExec` interprets bare questions against a memo table and is proved
against `denote`. `AnnotatedExec` interprets intent below denotation: consult
and observe occurrences reuse by bare question, effects bypass the memo, and
each occurrence records an execution event. The conformance protocol at
version 3 compares this annotated representation between Lean and Haskell and
also carries `semanticTrace`, its erasure.

```lean
semanticOracle : (c : Code) → Q c → Table → m (El c)
execOracle     : (c : Code) → Request c → Table → m (El c)
```

The semantic table is a finite bare-question answer sheet. The executable
memo stores typed answers under bare `Q`, and each Plan occurrence constructs
its own annotated event. These policies do not alter principal meaning.

### First: the interpreter is the fold

```lean
theorem Plan.execWith_eq_execM_denote :
    execWith o p γ t = execM o (denote p γ) t
-- bare-question semantic interpreter; the proof is rfl

theorem Plan.execAnnotated_correct (ω : Ω) (p : Plan Γ A) :
    ∀ γ t, Extends ω t → (Plan.execAnnotated ω p γ t).Correct ω p γ
-- the annotated executor returns Plan.run, extends the table,
-- and its trace erases to Plan.trace
```

The first theorem is semantic factorization. The second is the representation
square for the executor that performs bare-question memo hits and effect
bypass. Haskell scheduling and physical effects remain empirical realizations
rather than consequences of either theorem.

### Second: adequacy, against an arbitrary answerer

```lean
theorem Plan.adequacy (o : Oracle Id) (h : execWith o p ∅ nil = (a, t)) :
    (∀ ω, Extends ω t → Plan.run ω p ∅ = a) ∧
    (∀ ω, Extends ω t → Plan.trace ω p ∅ = Plan.trace (worldOf t) p ∅)
-- model/Agentic/Core/Certify.lean:135; axioms: [propext]
```

The answering party is an arbitrary history-dependent strategy. It may drift,
contradict itself, and answer differently on different occasions, and the
theorem assumes nothing to the contrary. It states that the table a run
produces is a finite world, and that every total world extending it evaluates
the plan to exactly the value the run reported. Non-determinism at the edge
is absorbed by quantification rather than by assumption.

### Third: the certificate, as a warrant for one run

```lean
def certify (p : Plan [] A) (t : Table) (a : A) : Bool :=
  decide (Plan.run (worldOf t) p ∅ = a)

theorem certify_sound : certify p t a = true → ∃ ω : Ω, Plan.run ω p ∅ = a
-- model/Agentic/Core/Certify.lean:169, :180; axioms: none
```

No theorem governs what a live process writes to a pipe, and none is
asserted. Each execution instead replays its own log as a world, evaluates
the plan purely, and compares. A certificate of `true` exhibits a world in
which the plan means what the run reported, and the soundness proof reaches
nothing that could carry an axiom. Both axiom claims are pinned in the source
by `#guard_msgs`, so any drift is a build failure.

## Part VI. The flagship workflow and its theorems

The flagship is a patch-hardening workflow of about a dozen lines. It reads a
style guide, drafts a patch under a designated model, submits the draft to
three reviewers, two of whom read the guide, revises up to twice on
objection, puts the question of consent to a person, and applies the patch
only upon assent. Its Haskell source is `workflow/example/Harden.hs`; its
meaning and its Plan are written in `model/Agentic/Core/HardenPatch.lean`,
and its first-order term is checked in `model/Agentic/Core/DslFlagship.lean`.

The theorems fall into three kinds, and the distinction is the reason for the
whole construction. A meaning theorem quantifies over worlds and speaks only
of `run` and `trace`. A representation theorem is a computation on the term,
decided by evaluation. A bridge theorem connects the two, and it is what
allows a computation on syntax to be believed about all worlds.

| Theorem | Kind | Content |
|---|---|---|
| `denote_hardenPatch` | bridge | The denotation of the written workflow is a particular dialogue, given independently. Every meaning theorem below rewrites with this equation and then reasons in the meaning space alone. |
| `consent_of_ack`, `no_ack_of_refused` | meaning | The apply question can occur only after affirmative consent. Refusal removes every acknowledgement question. |
| `consent_of_effect`, `no_effect_of_refused` | bridge | The annotated execution trace classifies that apply occurrence as an effect. The proof factors through `ExecEvent.forget`. |
| `guide_once` | meaning | The style guide is consulted exactly once in every world. |
| `draft_count_le_three` | meaning | At most three drafts are requested, in every world. |
| `level_hardenPatch` | representation | The level fold returns `branch`, by reflexivity. |
| `card_leaves_demo`, `minFold_demo`, `maxFold_demo` | representation | The cost tree computed from the term has nine leaves, with extremes 5 and 15 request occurrences. |
| `bill_hardenPatch` | meaning | In every world the bill read from the transcript is one of 6, 7, 10, 11, 13, 14, or 15, with a world exhibited for each end of the range. |
| `minFold_not_attained_demo` | meaning | No world attains the tree's minimum of 5. The computed bound is sound and slack by one request. |

The pattern generalises. A property of interest is proved in the meaning
space, where worlds can be quantified over and nothing depends on how the
workflow was written. An analysis is computed in the representation, where a
term can be folded. A bridge theorem, or a soundness theorem for the
analysis, permits the second to be read as evidence about the first. Neither
layer is asked to do the other's work.

`DslFlagship.lean` adds the kernel-checked facts about the first-order term:
the checker accepts it, its level is `branch`, its cost tree has nine leaves
with extremes 5 and 15, and its transcript in four named worlds equals the
hand-written dialogue's. Those four transcript agreements are the anchor. The
file states plainly that a universally quantified transcript agreement is not
proved.

### Execution against a live agent

The same Plan is what `agentic-run` executes, through a scripted table, an
ACP adapter, or an agent-deck session. The replies of a live model constitute
one world among many, which is why the theorems transfer to a live run
without weakening. A run in which every reviewer approves consults the guide
once, asks for one draft, and bills seven request occurrences, one of them an
effect. Had a reviewer objected, the run would have taken a revision round and
landed on another member of the same proved set. A run that differs only in
the answer to the consent question bills six, produces no effect occurrence,
and leaves the working tree untouched.

## Part VII. The boundary of proof

A proof is informative in proportion to the clarity of its boundary. Four
things are trusted, and each is stated in the source rather than hidden inside
a theorem.

The decoders. One total parser attends each kind of answer. How a particular
English sentence divides into words is not something the kernel can settle,
so measured replies are pinned as tests in `model/Agentic/Core/Exec.lean` and
frozen in the conformance corpus. The parser fails closed. A word of refusal
anywhere denies, while assent must be the whole reply, since no rule that
admits "Yes, apply it" can exclude "I cannot approve this patch".

Adapter fidelity. That the process at the far end of the pipe relays the
model faithfully is an empirical assumption, and it is labelled as one.

The permission grant. Under ACP the runtime grants tool permission only to an
effect-annotated occurrence, within the scratch directory of its own
session, and denies it to consultations and observations. Refusal is not the
conservative choice it appears to be. A refused permission does not end the
turn, which completes normally with prose in place of an act, at considerable
cost and with no protocol signal to distinguish it from an answer. The grant
is therefore a declared policy, and every decision is announced on standard
error.

The log. The certificate warrants a claim about the table a run recorded,
from which one rule follows without exception: nothing may be written into
the table that no party said. When decoding fails after its retries, the run
is abandoned and the unreadable reply is quoted, because a defaulted answer in
a table without provenance cannot be told from an answer given.

## Coda

Three layers, one function between the first two, and one oracle between the
second and the world. A meaning: for each world, an answer and a transcript,
computed by two folds over a carrier that exists only to make the definition
compositional. A representation: first-order, with binders, each of whose
operations is proved to commute with its meaning, and whose surplus structure
funds the analyses and carries the execution intent the runtime needs. A
runtime: the same fold supplied with an oracle, each of whose runs carries a
decidable certificate of agreement with the mathematics.

What the arrangement buys is the property the discipline exists to secure. A
workflow value may be treated as being its meaning. When a run reports that
the guide was consulted once, that is a theorem about every world, and the
run is evidence that the machinery beneath the theorem told the truth.

The Lean sources are `model/Agentic/Core/{Question, World, Dlg, Request,
Plan, Denote, Level, Cost, Morphism, HardenPatch, SemanticExec,
AnnotatedExec, Exec, Certify}.lean`, built with Lean 4.30.0 and Mathlib
v4.30.0 as pinned in `model/lean-toolchain` and `model/lakefile.toml`. Every
result of the certified spine lies within `propext`, `Classical.choice`, and
`Quot.sound`, and `certify_sound` within none of them.
