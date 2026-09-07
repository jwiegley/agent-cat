# Meaning and Representation

This document explains the two layers of agent-cat and the function between
them. The first layer is the meaning of a workflow. The meaning is a
mathematical object that was chosen because it explains the domain well, and it
was chosen with no regard for whether a computer can compute it. The second
layer is the representation of a workflow. The representation is a finite
syntax that an author writes, that tools analyse before it runs, and that a
runtime executes against a live agent. The proofs in `model/Agentic/Core` show
that every operation on the representation commutes with the function that maps
it to its meaning.

The dependence between the layers runs in one direction. The meaning constrains
the implementation, and the implementation never constrains the meaning
(Elliott, *Denotational Design with Type Class Morphisms*, 2009). The sections
below follow that order. They treat the meaning, the representation, the
function that joins them, the analyses that only the representation supports,
execution, and the point at which proof gives way to stated assumption. The
Texinfo manual in `doc/agent-cat.texi` gives the same material as reference
chapters, and this document gives the argument.

## Part I. The meaning

The design begins with one sentence about the domain. A workflow puts questions
to parties, receives typed replies, and uses those replies to decide which
question to put next. That sentence says nothing about how a question is
carried out, and the meaning records nothing about it either.

### Worlds

A world is a total answer sheet. It holds one reply for every question that a
workflow can ask:

```lean
abbrev Ω : Type := (c : Code) → Q c → El c
```

`Code` names the kind of a reply. A reply is text, a verdict, a flag, a
receipt, or a structured value with a schema. `Q c` is a question of kind `c`,
and it records the party that is asked, the scope of the question, the prompt,
and the draw. These four fields are the whole identity of a question. Equal
questions receive one answer in every world. Two authored occurrences of the
same question remain two events in the transcript, whether or not a runtime
reuses the answer. A deliberate resample changes the draw and therefore changes
the question. The manner in which an occurrence is executed changes nothing
here. That annotation appears later, in the representation.

### What a workflow denotes

The first candidate for a meaning is a function from worlds to answers. This
candidate is too coarse. Under it, a workflow that asks a question, discards
the reply, and then asks a second question means exactly what the second
question means alone. Every account of what the workflow consulted, and of what
that consultation cost, is lost. The meaning therefore records both the result
and the questions that produced the result:

```text
⟦ a workflow ⟧ : Ω → (A × Trace)
```

For each world, the meaning gives an answer together with the ordered
transcript of the bare questions and their replies. Physical execution,
permission, memoization, and the intent behind an occurrence are not
observations of this object.

### Where the meaning is defined

A function of this type cannot be defined by cases on a workflow, because at
this stage a workflow is not yet a mathematical object. The function is defined
instead on an intermediate carrier, the dialogue, and a dialogue supports
structural recursion:

```lean
inductive Dlg (A : Type) : Type where
  | done : A → Dlg A
  | ask  : (c : Code) → Q c → (El c → Dlg A) → Dlg A
-- model/Agentic/Core/Dlg.lean:50
```

A dialogue is either finished or one bare question paired with a continuation
for every possible reply. It is the free monad on the question signature. Two
folds give the result and the exact semantic trace:

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

The claim that this pair of folds is the meaning has three parts, and the
library proves each part.

The first part is that the folds constitute the semantic function. Together
they define one map from the carrier into the meaning space, written
`⟦p⟧ ω = (run ω p, trace ω p)`. A dialogue is not itself the meaning. It is the
object from which the meaning is computed.

The second part is that the folds respect composition. Both folds are monad
morphisms. The meaning of a composite workflow is therefore built from the
meanings of its parts, and no separate account of sequencing is needed:

```lean
theorem run_bind   : run ω (p >>= k) = run ω (k (run ω p))
theorem trace_bind : trace ω (p >>= k) = trace ω p ++ trace ω (k (run ω p))
```

The third part is that the folds fix equality. Two workflows are the same
workflow when their meanings agree in every world:

```lean
Obs p p' ↔ ∀ ω, run ω p = run ω p' ∧ trace ω p = trace ω p'
```

The semantic function is not injective. Dialogues that differ in structure can
agree in every world, and `Dlg.not_forcing` exhibits such a pair. Equality of
dialogues is therefore strictly finer than equality of meaning. `Obs` is the
equality of the domain, and the ordinary equality of the carrier is not. The
definition of `Obs` as the kernel of the meaning gives congruence directly, with
no axioms and no quotient type. The cost of this choice is that `Obs` must be
written explicitly wherever two workflows are compared.

## Part II. The representation

A meaning of this kind cannot be inspected. The continuation inside a dialogue
is a function from an answer type that is not finite. Its branches cannot be
enumerated, its questions cannot be listed, and its cost cannot be priced. A
specification can be uncomputable, but a tool cannot. The representation
therefore exists so that a workflow can be read, analysed, and executed.

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

`ret` returns a pure function of the answers that are known. `askC` asks a
closed request whose words are already part of the term. `ask` computes its
words from earlier answers and asks a request of fixed shape. `case` branches
over a finite tag, and every arm is present in the term. `dyn` computes a plan
from an unbounded answer. Each asking node binds the answer that it obtains, so
a plan reads as a sequence of bindings, and the context `Γ` lists the answers
that are in scope. Two decisions in this type do the work.

### First order, with binders

A point-free presentation is built from composition and tupling operators. It
can be analysed, but it is hard to read, because the flow of values is
expressed as plumbing. A higher-order presentation reads well, but it cannot be
analysed, because a fold over it needs every answer type to be finite, and free
text is not finite. The representation takes neither path. Instead, it owns the
binder. Contexts are lists, variables are indices, and the author writes a
binding. Sharing is a variable that is mentioned twice, branching is a `case`,
and no construction needs a name.

### The shape is written, and only the words are computed

A request divides into a question shape, an execution intent, and words. Only
the words are computed from earlier answers:

```text
Request c  ≅  Request.Shape c × String
```

The semantic sequence of question shapes is therefore a projection of the
syntax. A question whose shape must depend on an answer uses `case`, and there
all arms remain visible and priced.

### Intent, and why the representation carries it

`Request c` pairs a bare question with an `Intent c`, and the intent has three
values. A `consult` asks a party for an answer. An `observe` reads external
state through a declared command. An `effect` requests a change to external
state. The `effect` intent is available only for the receipt kind, so no plan
can branch on an alleged result of an effect
(`model/Agentic/Core/Request.lean:27`).

The mathematics has no use for this field, and its absence from the meaning is
deliberate. Part I identifies a question by the party that is asked, the scope,
the words, and the draw. A runtime that executes a plan must make decisions
that the mathematics does not record. It must decide whether an occurrence can
reuse an answer that was already obtained for the same bare question. It must
decide whether an occurrence must run every time it is reached, because the
occurrence acts on the world. It must decide whether the party can receive
permission to use tools, and in what order the occurrence stands relative to
other acts. Neither the answer kind nor the party settles these decisions. A
receipt-valued question to a tool can be a harmless consultation or an act on
the world. The author therefore declares the intent, and the runtime reads it.

The intent lives in the representation and never in the question. Worlds stay
indexed by `Q`, so the answer to a question cannot depend on the policy under
which the question is asked. Two workflows that ask the same questions in the
same order and hear the same answers have the same meaning under every
execution policy. The denotation projects the question and forgets the intent:

```lean
theorem denote_askC_intent_irrel (c : Code) (q : Q c) (i i' : Intent c) ... :
    denote (Plan.askC c ⟨q, i⟩ k) γ = denote (Plan.askC c ⟨q, i'⟩ k) γ := rfl
-- model/Agentic/Core/Denote.lean:234; the open-request form follows at :239
```

The position of a request in the source fixes its intent, and no answer can
change it. An ordinary value question is a `consult`. An executable tool in
value position is an `observe`. An act in statement position is an `effect`
(`model/Agentic/Core/Dsl/Check.lean:174`). The intent lives in the shape of the
request rather than in its words, so the computation of prompt words from
earlier answers cannot change it (`Request.intent_withPrompt`).

During a run, the intent gives the runtime four things. Consult and observe
occurrences share one memo table that is keyed by the bare question, so a
repeated question is answered once. Effect occurrences never read or populate
that table. The runtime dispatches every effect and bills each one separately.
Under the ACP transport, only an effect receives tool permission, and effects
enter an ordered lane so that a later act cannot overtake an earlier one.
Finally, every execution event retains the authored request beside the source
of its answer. A trace can therefore say whether an answer was reused, or which
dispatched question produced it after a fail-over. The theorem that ties these
policies back to Part I is `Plan.execAnnotated_correct`
(`model/Agentic/Core/AnnotatedExec.lean:190`). It states that the annotated
executor returns the semantic value, that it extends the bare-question table,
and that its execution trace erases event by event to the semantic trace.

The intent also has a ceiling. An `observe` does not prove that a command is
read-only, and an `effect` does not prove that a change occurred. A completed
adapter turn establishes only that the adapter reported completion. Evidence
about the world requires an independent observation, and a workflow can be
written to include one.

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

Denotation has two stages. The first stage is defined by recursion on the
syntax, and it produces a dialogue. The second stage is defined by recursion on
the carrier, and it produces an answer and a transcript for each world. The
composite of the two stages is the meaning of a written workflow.

### The commuting square

Every way to build a plan has a counterpart way to build a dialogue, and one
equation states the requirement on each pair. To build a plan and then take its
meaning must agree with taking the meanings first and then building. This
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

Here `f` is an operation on plans, and `f̂` is the corresponding operation on
dialogues. Where a standard structure supplies the counterpart, the counterpart
is taken from it. The theorem for each row of the table below states that this
square commutes.

| Operation on plans | Counterpart on dialogues | Theorem |
|---|---|---|
| `graft p k`, run `p` and continue | `>>=`, monadic bind | `denote_graft` |
| the same, read on transcripts | `++`, concatenation | `trace_graft` |
| `panel ps`, several reviewers | `foldr (liftA2 (· * ·)) (pure 1)` | `denote_panel` |
| `under σ p`, a standing scope | reindexing of the world, `ω ∘ σ` | `run_under` |
| `case e arms`, finite branching | selection of the arm that the answer names | `denote_case` |
| `revising n`, bounded revision | check-then-revise unrolling | `denote_revising` |

`model/Agentic/Core/Morphism.lean` holds one such theorem for every operation
that the surface offers. Two of them show the pattern:

```lean
theorem trace_graft (hk : Denotes k K) :
    Plan.trace ω (Plan.graft p k) γ
      = Plan.trace ω p γ ++ Dlg.trace ω (K (Plan.run ω p γ) γ)

theorem denote_panel [Monoid (El c)] (ps : List (Plan Γ (El c))) :
    denote (Plan.panel ps) γ
      = (ps.map (denote · γ)).foldr (fun x y => (· * ·) <$> x <*> y) (pure 1)
```

The first theorem says that the transcript of a sequence is the concatenation
of the transcripts. Every cost is therefore a monoid homomorphism on traces.
The second theorem says that a review panel is the applicative lifting of the
product of the verdict monoid across the meanings of the reviewers. Verdicts
form a monoid in which approval is the unit and any objection carries. The
panel therefore needs no reducer of its own, and it inherits its laws from the
standard library.

One equation is absent from the table because it needs no proof. To run a plan
is defined as to run its denotation, `Plan.run ω p γ := Dlg.run ω (denote p
γ)`, so the square for execution commutes by reflexivity. There is no second
semantics to reconcile.

## Part IV. The difference, and what it purchases

The two layers are different objects, and the design rests on the asymmetry
between them. The meaning supports quantification over every world, so a
theorem can say that in all worlds the guide is consulted exactly once. The
meaning supports the definition of equality, because two workflows are the
same when their meanings agree. The meaning can be infinite and uncomputable
without difficulty, because a specification that cannot run cannot be mistaken
for the artefact that it constrains. The meaning is also indifferent to
scheduling, caching, retry, and transport.

The representation supports folding, so the level, the sequence of shapes, and
the cost tree are computable functions of a term. The representation supports
typing by context, so no answer can be mentioned before it arrives. The
representation supports execution by an interpreter that opens a connection to
a live agent. The representation also records distinctions that the meaning
declines to record.

That last item governs the analyses, and one example shows why it matters. In
`denote`, the clause for `case` and the clause for `dyn` are the same clause.
The two nodes mean exactly the same thing. They differ only in what can be
established about them, because `case` carries every arm in the term while
`dyn` carries a function. The syntax can keep this distinction because the
meaning does not record it. A representation can know more than its meaning,
and it can never mean anything other than its meaning.

### The four levels

The level of a plan is a fold over the term rather than an index in its type
(`model/Agentic/Core/Level.lean:133`). A fold leaves the syntax free of proof
obligations and puts the whole analysis in ordinary functions.

| Level | Mark in the term | What is established about cost |
|---|---|---|
| `batch` | closed requests only | The term fixes the request list. The bill is exact and is the same in every world. |
| `pipeline` | words built from answers | The shape sequence is a projection of the syntax. The bill is exact when prices depend on shape. |
| `branch` | finite branching | A finite cost tree exists. The bill of every world is one of its leaves, and folds give the extremes. |
| `dynamic` | a plan from an unbounded answer | No finite cost tree exists, and a plan with unbounded bills witnesses this fact. |

The hierarchy restricts nothing that an author can write. It states what can be
known about what the author has written. The common case is a prompt that is
assembled from an earlier answer, and the hierarchy prices that case exactly
rather than surrendering it to the general case. The Haskell authoring surface
emits no `dyn` node. The theorem `Dsl.checkProgram_level_le`
(`model/Agentic/Core/Dsl.lean:832`) states that every first-order program that
the checker accepts lies at or below `branch`.

## Part V. Execution, and three statements of correctness

Production execution is written in Haskell, and Lean keeps two reference
interpreters. `SemanticExec` interprets bare questions against a memo table,
and it is proved against `denote`. `AnnotatedExec` interprets the intent below
the denotation. In it, consult and observe occurrences reuse answers by bare
question, effects bypass the memo, and each occurrence records an execution
event. The conformance protocol at version 3 compares this annotated
representation between Lean and Haskell, and it also carries `semanticTrace`,
the erasure of the annotated trace.

```lean
semanticOracle : (c : Code) → Q c → Table → m (El c)
execOracle     : (c : Code) → Request c → Table → m (El c)
```

The semantic table is a finite bare-question answer sheet. The executable memo
stores typed answers under bare `Q`, and each Plan occurrence constructs its
own annotated event. These policies do not alter the principal meaning.

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

The first theorem is a semantic factorization. The second theorem is the
representation square for the executor that performs bare-question memo hits
and effect bypass. Haskell scheduling and physical effects remain empirical
realizations, and neither theorem implies them.

### Second: adequacy, against an arbitrary answerer

```lean
theorem Plan.adequacy (o : Oracle Id) (h : execWith o p ∅ nil = (a, t)) :
    (∀ ω, Extends ω t → Plan.run ω p ∅ = a) ∧
    (∀ ω, Extends ω t → Plan.trace ω p ∅ = Plan.trace (worldOf t) p ∅)
-- model/Agentic/Core/Certify.lean:135; axioms: [propext]
```

The answering party is an arbitrary strategy that can depend on history. It
can drift, contradict itself, and answer differently on different occasions,
and the theorem assumes nothing to the contrary. The theorem states that the
table that a run produces is a finite world, and that every total world that
extends this table evaluates the plan to exactly the value that the run
reported. Quantification absorbs the non-determinism at the edge, so no
assumption about the answerer is needed.

### Third: the certificate, as a warrant for one run

```lean
def certify (p : Plan [] A) (t : Table) (a : A) : Bool :=
  decide (Plan.run (worldOf t) p ∅ = a)

theorem certify_sound : certify p t a = true → ∃ ω : Ω, Plan.run ω p ∅ = a
-- model/Agentic/Core/Certify.lean:169, :180; axioms: none
```

No theorem governs what a live process writes to a pipe, and none is asserted.
Instead, each execution replays its own log as a world, evaluates the plan
purely, and compares the result. A certificate of `true` exhibits a world in
which the plan means what the run reported, and the soundness proof uses no
axiom. Both axiom claims are pinned in the source by `#guard_msgs`, so any
drift is a build failure.

## Part VI. The flagship workflow and its theorems

The flagship is a patch-hardening workflow of about a dozen lines. It reads a
style guide and drafts a patch under a designated model. It submits the draft
to three reviewers, two of whom read the guide, and it revises the patch up to
twice on objection. It then puts the question of consent to a person, and it
applies the patch only after assent. Its Haskell source is
`workflow/example/Harden.hs`. Its meaning and its plan are written in
`model/Agentic/Core/HardenPatch.lean`, and its first-order term is checked in
`model/Agentic/Core/DslFlagship.lean`.

The theorems about the flagship fall into three kinds, and this distinction is
the reason for the whole construction. A meaning theorem quantifies over worlds
and speaks only of `run` and `trace`. A representation theorem is a computation
on the term that evaluation decides. A bridge theorem connects the two kinds,
and it allows a computation on the syntax to be believed about all worlds.

| Theorem | Kind | Content |
|---|---|---|
| `denote_hardenPatch` | bridge | The denotation of the written workflow is a particular dialogue that is given independently. Every meaning theorem below rewrites with this equation and then reasons in the meaning space alone. |
| `consent_of_ack`, `no_ack_of_refused` | meaning | The apply question can occur only after affirmative consent. Refusal removes every acknowledgement question. |
| `consent_of_effect`, `no_effect_of_refused` | bridge | The annotated execution trace classifies the apply occurrence as an effect. The proof factors through `ExecEvent.forget`. |
| `guide_once` | meaning | The style guide is consulted exactly once in every world. |
| `draft_count_le_three` | meaning | At most three drafts are requested in every world. |
| `level_hardenPatch` | representation | The level fold returns `branch` by reflexivity. |
| `card_leaves_demo`, `minFold_demo`, `maxFold_demo` | representation | The cost tree that is computed from the term has nine leaves, with extremes of 5 and 15 request occurrences. |
| `bill_hardenPatch` | meaning | In every world the bill that is read from the transcript is one of 6, 7, 10, 11, 13, 14, or 15, and a world is exhibited for each end of the range. |
| `minFold_not_attained_demo` | meaning | No world attains the minimum of 5 that the tree computes. The computed bound is sound and slack by one request. |

The same pattern applies beyond the flagship. A property of interest is proved
in the meaning space, where worlds can be quantified over and nothing depends
on how the workflow was written. An analysis is computed in the
representation, where a term can be folded. A bridge theorem, or a soundness
theorem for the analysis, permits the analysis to be read as evidence about
the meaning. Neither layer is asked to do the work of the other.

`DslFlagship.lean` adds the kernel-checked facts about the first-order term.
The checker accepts the term, its level is `branch`, its cost tree has nine
leaves with extremes of 5 and 15, and its transcript in four named worlds
equals the transcript of the hand-written dialogue. Those four transcript
agreements are the anchor. The file states plainly that a transcript agreement
for all worlds is not proved.

### Execution against a live agent

The same plan is what `agentic-run` executes, through a scripted table, an ACP
adapter, or an agent-deck session. The replies of a live model form one world
among many, so the theorems transfer to a live run without any weakening. A run
in which every reviewer approves consults the guide once, asks for one draft,
and bills seven request occurrences, one of them an effect. If a reviewer
objects, the run takes a revision round and lands on another member of the
same proved set of bills. A run that differs only in the answer to the consent
question bills six, produces no effect occurrence, and leaves the working tree
untouched.

## Part VII. The boundary of proof

A proof is informative in proportion to the clarity of its boundary. Four
things are trusted, and each is stated in the source rather than hidden inside
a theorem.

The decoders are trusted. One total parser attends each kind of answer. The
kernel cannot settle how a particular English sentence divides into words, so
measured replies are pinned as tests in `model/Agentic/Core/Exec.lean` and
frozen in the conformance corpus. The parser fails closed. A word of refusal
anywhere denies, while assent must be the whole reply, because no rule that
admits "Yes, apply it" can exclude "I cannot approve this patch".

The fidelity of the adapter is assumed. Whether the process at the far end of
the pipe relays the model faithfully is an empirical question, and the source
labels the answer as an assumption.

The permission grant is a declared policy. Under ACP the runtime grants tool
permission only to an effect-annotated occurrence, and only within the scratch
directory of its own session. It denies permission to consultations and
observations. To refuse every request appears more conservative, but a refused
permission does not end the turn. The turn completes normally, with prose in
place of an act, at considerable cost, and with no protocol signal that
distinguishes it from an answer. The runtime therefore announces every decision
on standard error.

The log is trusted as a record. The certificate warrants a claim about the
table that a run recorded, and one rule follows from this without exception.
Nothing can be written into the table that no party said. When decoding fails
after its retries, the run is abandoned and the unreadable reply is quoted,
because a defaulted answer in a table without provenance cannot be told from an
answer that was given.

## Coda

The design has three layers. One function stands between the first two, and
one oracle stands between the second and the world. The meaning gives, for each
world, an answer and a transcript. Two folds compute the meaning over a carrier
that exists only to make the definition compositional. The representation is
first-order and has binders. Each of its operations is proved to commute with
its meaning, and its surplus structure funds the analyses and carries the
execution intent that the runtime needs. The runtime is the same fold supplied
with an oracle, and each of its runs carries a decidable certificate of
agreement with the mathematics.

The arrangement secures the property that the discipline exists for. A
workflow value can be treated as being its meaning. When a run reports that
the guide was consulted once, that report is a theorem about every world, and
the run is evidence that the machinery beneath the theorem told the truth.

The Lean sources are `model/Agentic/Core/{Question, World, Dlg, Request,
Plan, Denote, Level, Cost, Morphism, HardenPatch, SemanticExec,
AnnotatedExec, Exec, Certify}.lean`. They are built with Lean 4.30.0 and
Mathlib v4.30.0, as pinned in `model/lean-toolchain` and
`model/lakefile.toml`. Every result of the certified spine lies within
`propext`, `Classical.choice`, and `Quot.sound`, and `certify_sound` lies
within none of them.
