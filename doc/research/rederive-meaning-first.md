# A Kernel for Agentic Workflows, Re-derived Meaning-First

*Derived under Elliott's denotational-design discipline: meanings first, standard classes
recognized rather than invented, morphism equations as the specification, failed morphisms
read as diagnostics, simplicity as the criterion.*

*Derived blind. Sections 1–13 were written without consulting `agent-functor`, `incite`, or
`agent-cat`. Section 14, and only Section 14, compares the result against `agent-cat`'s `Term`
calculus.*

---

## 1. The domain, in the domain's own words (Step 1)

> A workflow sends prompts to models, tools, and humans; names their answers; feeds them into
> later prompts; runs reviewer panels whose verdicts combine; retries on objection; and
> sometimes lets an answer decide what happens next.

Read that sentence adversarially, looking for what is *content* and what is *machinery*.

- "sends prompts to models/tools/humans" — one verb, three addressees. The sentence does not
  say the verb changes with the addressee.
- "names their answers" — naming. A workflow author writes `let v = …` and uses `v` twice.
- "feeds them into later prompts" — a later prompt is a *function of* an earlier answer.
- "runs reviewer panels whose verdicts combine" — several consultations that do not depend on
  one another, and an aggregation.
- "retries on objection" — bounded repetition driven by an answer.
- "sometimes lets an answer decide what happens next" — the word *sometimes* is the whole
  design brief for the static/dynamic hierarchy. Most of a workflow is not like this.

The sentence contains exactly one thing a pure function cannot do: **ask**. Naming is binding.
Feeding is application. Combining is folding. Retrying is iteration. Branching is `if`. All of
those are already available in any host language with functions. So the entire question of this
design is:

> **What is asking?**

Everything else must be derived or deleted.

---

## 2. A workflow is a representation of *what* mathematical object? (Step 2)

### 2.1 First candidate: the answer-function

An asking computation is one that cannot produce its result alone; it needs someone to answer.
Collect all the answers into one object and asking becomes lookup. Let `Q α` be the set of
questions whose answer is an `α`. Then:

```
World  :=  ∀ α. Q α → α          -- an oracle: every question, answered
```

and the first candidate meaning is the reader over worlds:

```
[[W A]]  =  World → A
```

This is very simple and it already earns its keep: it says **a workflow is a deterministic
function of what it is told**, and it places all stochasticity outside the workflow, in the
choice of world. That is the right place for it (see §5, q1).

But it fails, and the failure is informative.

### 2.2 The failed morphism that forces the real meaning

The owner requires that costs be statically analyzable. So `cost` must be a function of the
meaning. Compute:

```
[[ ask q >>= λ_ ⇒ ask q' ]]  =  λw ⇒ w q'  =  [[ ask q' ]]
```

Two workflows with different costs have the same meaning. Therefore **cost is not a function of
`World → A`**, and no compositional cost analysis can exist over this model. By the doctrine's
diagnostic table this is the row *"the equation requires an argument that is not available: the
specification is not compositional; augment the specification until it is."*

What is missing is not a second meaning bolted alongside. What is missing is that the meaning
records only the *result* of the conversation and not the *conversation*. Asking is not lookup.
Asking is a turn in a dialogue.

### 2.3 The meaning

> **A workflow is a dialogue: either it is finished with an answer of its own, or it has a
> question and knows how to continue from every possible answer to it.**

```
[[ W A ]]  =  Dlg A
Dlg A      =  A  +  Σ (c : Code). Q c × (El c → Dlg A)      -- least fixed point
```

`Code` is a small universe of answer types with `El : Code → Type` (patch text, verdict,
yes/no, a list of objections), kept small so that `Dlg` lives in `Type` and worlds are
expressible; every `El c` is inhabited (an addressee always says *something*, even if what it
says is "I decline"). The fixed point is **least**: dialogues are well-founded, finite along
every path. §5 q5 and q8 show that this costs nothing the domain wants and buys totality.

In Lean:

```lean
inductive Dlg (A : Type) : Type
  | done : A → Dlg A
  | ask  : (c : Code) → Q c → (El c → Dlg A) → Dlg A
```

The continuation is a *function*, not a table and not a syntax tree with binders. That single
choice is what makes names unnecessary (§5 q2), makes the monad laws hold without a quotient
(§5 q9), and makes the object a mathematical one rather than a notation.

### 2.4 Why this is not a representation choice (the forcing lemma)

The doctrine's second anti-pattern is the representation *becoming* the concept. A tree looks
like a representation, so it must be shown to be forced. Define the two observations we wanted
all along:

```lean
def run   (w : World) : Dlg A → A
  | .done a      => a
  | .ask c q f   => run w (f (w q))

def trace (w : World) : Dlg A → List (Σ c, Q c × El c)
  | .done _      => []
  | .ask c q f   => ⟨c, q, w q⟩ :: trace w (f (w q))
```

**Forcing Lemma.** For `p p' : Dlg A`,
`p = p'  ↔  ∀ w, run w p = run w p' ∧ trace w p = trace w p'.`

*Proof sketch.* (→) trivial. (←) Induction. If one is `done` and the other `ask`, the traces
differ in length at every world. If both `ask` with different questions, the traces differ in
their heads. If both `ask` the same `q`, then for each `x : El c` choose a world sending `q ↦ x`
(possible because every `El` is inhabited, so total worlds exist) and apply the induction
hypothesis to `f x` and `f' x`; conclude `f = f'` by funext. ∎

So `Dlg A` **is** the object of coherent world-indexed (result, transcript) pairs. It is not one
of several encodings of that object; it is that object, presented in the only form that makes
the coherence structural instead of a side condition. `World → A` was the same object with the
transcript forgotten — a quotient, and the wrong one.

### 2.5 What the meaning *is not*

Rejected, with reasons, because each is a machine fact promoted into the model:

- `Dist A` (a distribution over results). Loses the correlation that asking the same question
  twice agrees. Derivable from `Dlg` by pushing a distribution over worlds forward; not
  conversely. The doctrine: keep the function, do not collapse to the observable.
- `A → IO B`, sessions, connection handles, message queues, retry state machines. Presentation.
- Anything with a `cache : Bool`, a `parallel : Bool`, or an `id : String`. Mode flags and
  labels (anti-patterns 7 and 8); each is deleted by a theorem below.

---

## 3. Questions: the one primitive (Step 3)

`ask` is the only operation that is not derived. Its argument, the question, must therefore carry
everything that determines the answer, because the world is a *function* of it:

```lean
structure Q (c : Code) where
  scope  : Scope        -- who answers, and under what standing conditions
  prompt : Prompt       -- everything said to them
  draw   : Nat          -- which independent draw this is (0 unless deliberately resampling)

structure Scope where
  addressee : Addressee
  mode      : Mode      -- reasoning depth, tool permissions, temperature class, …

inductive Addressee | model (m : ModelId) | tool (t : ToolId) | person (p : PersonId)

def ask {c} (q : Q c) : W (El c) := .ask c q .done
```

Three deletions are already visible.

- **`draw : Nat` replaces a resampling primitive.** Two independent samples of one prompt are
  two *questions*, so nothing else in the language needs to know about sampling (§5 q1).
- **`Scope` inside the question replaces a reader monad / environment.** Asking two models the
  same text is asking two different questions; that is what "same question, same answer" means.
  Scoping-as-a-block is then derived, not primitive (§5 q3).
- **`Addressee` includes `person`.** No separate human-in-the-loop construct survives (§5 q7).

---

## 4. Which standard classes does the meaning inhabit? (Step 6)

`Dlg` is the free monad on the signature `Q`. That is not a design decision; it is a fact about
the object of §2.3, and it hands over the entire API without a single bespoke name.

```lean
instance : Monad Dlg where
  pure := .done
  bind p k := match p with
    | .done a    => k a
    | .ask c q f => .ask c q (fun x => bind (f x) k)
```

From `Monad` come `Functor`, `Applicative`, `<$>`, `<*>`, `traverse` (via `Traversable` on any
container), `sequence`, `mapM`, `foldM`, `replicateM`, `when`, `unless`, and the whole standard
library. From the doctrine's Step 6 list, the other classes the model calls for:

| Domain phrase | Standard structure | Nothing invented |
|---|---|---|
| "feeds them into later prompts" | `Monad` / Kleisli composition | `>>=` |
| "panels" | `Traversable` + `Applicative` | `traverse` |
| "verdicts combine" | `Monoid`, and monoid homomorphisms for policy | `foldMap` |
| "retries on objection" | bounded iteration = structural recursion on `Nat` | host recursion |
| "under a deep model" | monoid action of signature endomorphisms | `under` (derived, §7) |
| cost | choice-semiring, and a lax semiring morphism | `cost` (derived, §8) |
| budgets | graded monad = subtype cut by a cost bound | `W γ A` (derived, §8.4) |
| the static/dynamic hierarchy | free applicative ⊂ static arrows ⊂ selective ⊂ free monad | §8 |

**Vocabulary deleted outright**, each because a standard class already supplies it: `sequence`
/ `parallel` / `fanout` (they are `traverse`), `share` / `let` / `bind-name` (host binding),
`withModel` / `withMode` (a signature action), `retry` (recursion on `Nat`), `orElse` /
`catch` (a value-level `match`), `cache` (a theorem about the interpreter), `panel` (a
one-line `traverse` I keep only as an abbreviation).

---

## 5. The ten questions

### q1 — The same question twice; resampling; what caching *means*

**Same answer.** The world is a *function*. This is a choice, and it is the load-bearing one.

*Theorem (functionality).* `run w (ask q >>= λa ⇒ ask q >>= λb ⇒ k a b) = run w (ask q >>= λa ⇒ k a a)`.
Immediate: both reduce to `run w (k (w q) (w q))`.

Note precisely what the theorem does and does not say. The two dialogues are **not equal** — they
have different traces and different costs. They agree only under `run`. That asymmetry is the
whole design: *value is insensitive to repetition; cost is not.*

**Deliberate resampling is a different question, not a different operation.** Best-of-`n` on one
prompt:

```lean
def draws (n : Nat) (q : Q c) : W (List (El c)) :=
  (List.range n).traverse (fun i => ask { q with draw := i })

def bestOf (n) (q) (pick : List (El c) → El c) : W (El c) := pick <$> draws n q
```

This is `traverse`: an *applicative*, not a monad. Its cost is exactly `n` (§8). Contrast a
design where sampling is a flag on a `Consult` node: there the analyzer must special-case the
flag, and the type no longer says whether the draws are independent. Here it is in the questions.

**Therefore caching is not a feature.** It is not in the language, it is not a flag, and it does
not appear in the meaning. Its status is stronger and stranger than that, and it falls out of
q10: a memoizing interpreter is *how the runtime makes the world be a function at all*. See
§11.3. In one sentence: **caching is not an optimization of the semantics; it is the construction
of the world the semantics quantifies over.** Without it, the adequacy theorem needs an
assumption about live agents that is false. With it, the theorem needs no assumption.

### q2 — Sharing one consultation among several consumers

**Structural, by binding. No labels, no `share`, no identifiers.**

```lean
do let guide ← ask (read styleGuide)
   let v₁ ← ask (reviewWith guide r₁ patch)
   let v₂ ← ask (reviewWith guide r₂ patch)
```

`guide` is an ordinary host-language variable holding an ordinary value. Two reviewers "share one
reading" in exactly the sense that two functions share an argument.

Why no labels are needed, stated as a theorem rather than a convention:

*Theorem (sharing is cost-only).* Let `p = ask q >>= λa ⇒ k a a` (ask once, use twice) and
`p' = ask q >>= λa ⇒ ask q >>= λb ⇒ k a b` (ask twice). Then `∀w. run w p = run w p'`, and
`cost p ≤ cost p'`.

So sharing never changes what a workflow means, only what it costs — which is the doctrine's
"efficiency lives elsewhere" landing exactly on this feature. A label-based sharing mechanism
(`bind "guide" …` / `ref "guide"`) would introduce: a name type, a scoping discipline, capture,
a lookup that can fail, and a well-formedness side condition a type checker cannot enforce
(anti-pattern 9). All of it deleted by using the host's binder, which is available because the
continuation in §2.3 is a *function*.

### q3 — Scoping: which model, under which mode

**Part of the question.** Forced by q1: if scope were not part of the question, then "the same
question" asked of a shallow and a deep model would have to have the same answer, which is
absurd. So `Scope` is a field of `Q`.

Block scoping (`under deep ⟨…⟩`) is then **derived, and it is an index transformation on the
signature, lifted freely**:

```lean
def Sig := ∀ {c}, Q c → Q c                     -- endomorphisms of the signature

def under (σ : Sig) : W A → W A
  | .done a    => .done a
  | .ask c q f => .ask c (σ q) (fun x => under σ (f x))
```

`under σ` is the unique monad morphism extending `ask ∘ σ`. Its laws are therefore free:

```
[[ under σ (pure a) ]]      =  pure a
[[ under σ (p >>= k) ]]     =  under σ [[p]] >>= (under σ ∘ k)
[[ under id p ]]            =  [[p]]
[[ under σ (under τ p) ]]   =  [[ under (σ ∘ τ) p ]]
```

The last two say that scoping is a **monoid action of `(Sig, ∘, id)` on `Dlg`**. Nesting,
overriding, and "innermost wins" are consequences of `σ ∘ τ`, not rules to be documented. A
reader-monad formulation would have given the same behaviour at the cost of an extra layer in
every type and a separate `local` law to prove.

### q4 — The hierarchy, and how cost factors

This is the owner's directive (1), and it is answered in three parts: **one meaning, four
semantic classes, four standard witnesses.**

**Part A: the classes are properties of the meaning, not different meanings.** Define, for
`p : Dlg A`:

```
Batch     p  :=  ∀ w w'. map fst (trace w p) = map fst (trace w' p)   -- same questions, always
Pipeline  p  :=  ∀ w w'. length (trace w p) = length (trace w' p)     -- same shape, dynamic content
Branching p  :=  { shape (trace w p) | w : World }  is finite         -- finitely many shapes
Dynamic   p  :=  ⊤
```

`Batch ⊂ Pipeline ⊂ Branching ⊂ Dynamic`, strictly. These are semantic predicates: they mention
only `trace`, never syntax.

**Part B: the standard structures that witness each class.** All four are free constructions over
the *same* signature `Q`, and all four embed into `Dlg` by maps that commute with `run`:

| Level | Structure | Literature | Witnesses |
|---|---|---|---|
| post-processing only | free `Functor` | — | one question, mapped |
| **Batch** | **free `Applicative`** | Capriotti & Kaposi | `⟨questions, answers → A⟩`: a finite vector of questions fixed in advance, plus a pure combiner |
| **Pipeline** | **free static arrow** (`Category` + `Cartesian`, i.e. `Arrow` without `app`) | Hughes | shape static, prompt *content* flows along wires from earlier answers |
| **Branching** | **free `Selective`** (`select`, `branch`, `matchS` on finite answer types) | Mokhov, Lukyanov, Marlow, Dimino | finite tree with the alternatives visible and statically enumerable |
| **Dynamic** | **free `Monad`** (= `Dlg` itself, = `ArrowApply`) | — | continuation is an arbitrary function of unbounded content |

The **Pipeline** level is the one a naive applicative/monad dichotomy misses, and the given
example forces it: *"two reviewers sharing one reading of a style guide"* builds a reviewer
prompt **out of** an earlier answer. That is a genuine data dependency, so it is not applicative;
but the *number* of consultations is still fixed in advance, so it should not cost us static
analysis. Static arrows are exactly the structure whose shape is static while values flow. Any
design that offers only `Applicative` and `Monad` is forced to call this monadic and forfeit
exact costing for the single most common pattern in the domain. That is the derivation's sharpest
result.

The **Branching** level is where the domain's decisions live, and there is a crisp criterion for
when a decision is Selective rather than Monadic:

> **A `bind` is finitely branching exactly when its answer type is finite.**

`Verdict`, `Bool`, `Approve | Object`, a fixed enum of next steps: finite, hence `matchS`, hence
a finite tree. Free text: infinite, hence genuinely monadic. So the domain's "sometimes lets an
answer decide what happens next" is almost always Selective, and the full monad is needed only
when a *prompt-shaped* answer determines the *shape* of the rest.

**Part C: how cost factors.** §8 proves it; the summary is:

- **Batch / Pipeline:** `cost` is an exact semiring homomorphism. Cost is a *value*.
- **Branching:** `cost` is an exact map into a finite *tree* (or an interval `[min, max]` after
  folding). Branch points are visible; that is what the owner asked for.
- **Dynamic:** `cost` is only *lax* — an over-approximation — and the exact cost is a function
  `World → C`, nothing smaller.

The morphism **fails** at exactly one operation, `>>=` on an infinite answer type. That single
failed equation is the reason the hierarchy exists. It is a diagnostic, not a defect.

### q5 — Retry / bounded iteration

**Derived, not primitive, and it lives at the Branching level.**

```lean
inductive Step (S A) | again : S → Step S A | stop : A → Step S A

def loop : Nat → (S → W (Step S A)) → S → W (Option A)
  | 0,     _,    _ => pure none
  | n+1,   body, s => do match ← body s with
                         | .stop  a  => pure (some a)
                         | .again s' => loop n body s'
```

`loop` is structural recursion on `Nat` in the host language. It introduces no constructor, no
class, no law. Its cost tree is the `n`-fold unfolding, finite, with exact `[min, max]` bounds
(§8.3). "Revise up to twice on objection" is `loop 2`.

*Unbounded* iteration is a different object: it requires a coinductive `Dlg`, an Elgot/`ArrowLoop`
iteration operator, `run` becoming partial, and cost moving to `ℕ∞`. Four theorems die together.
That price is exactly right, and the domain never asks to pay it — real workflows say "up to
twice", never "until it works". **The kernel is deliberately Elgot-free.**

### q6 — Panels: structure, the verdict monoid, and whether "parallel" is semantic

**Structure:** `traverse`. Nothing else.

```lean
abbrev panel (rs : List Scope) (mk : Scope → Prompt) : W (List Verdict) :=
  rs.traverse (fun r => ask ⟨r, mk r, 0⟩)
```

`traverse` uses only `Applicative`, so a panel is `Batch` by construction, and its cost is
exactly `rs.length`. The type says the reviewers are independent; that is the *semantic* content
of using `⊛` rather than `>>=`.

**The verdict monoid enters at the fold, not in the panel.** Reviewers produce elements of a
monoid `V`; the panel's aggregate is `foldMap id`; a *policy* is a monoid homomorphism out of `V`
into a decision lattice:

```lean
abbrev Verdict := List Objection      -- free monoid; approval = []

def unanimous : Verdict → Bool  := List.isEmpty            -- monoid hom into (Bool, ∧)
def severity  : Verdict → Sev   := foldMap sevOf           -- monoid hom into a lattice
```

Quorum ("at most one objector") is *not* a homomorphism out of the concatenation monoid — it is
one out of `(ℕ, +)`, obtained by first mapping each reviewer to `0` or `1`. That the algebra
tells you which policies are compositional and which need a different measure is a genuine
return on using the standard class.

**"Parallel" is a runtime fact, not a semantic one.** There is no `par` combinator. What is
semantic is **independence**, and it is expressed by which class you used. The licence to run
concurrently is a theorem:

*Theorem (scheduling freedom).* For `p` built with `⊛` only, `run w p` is invariant under every
interleaving of its questions, and `trace w p` is determined up to permutation.

*Proof.* The world is stateless: `w q` does not depend on what else has been asked. ∎

This theorem is where the stateless-world decision earns its keep, and where its cost becomes
visible (§12).

### q7 — Human in the loop

**The same consultation effect with a different addressee.** `person p : Addressee`. There is no
`AskHuman` node, no approval type, no interaction monad.

Run the diagnostic properly — what *could* distinguish a human?

1. *Latency.* A cost-semiring fact (§8), not a semantic one. Models differ in latency too.
2. *They may not reply.* Then the answer type is `Option`/`Timeout`, which is a fact about `El c`,
   not about the language. See q8.
3. *Their answer carries authority — "apply only on yes".* That is a fact about what the caller
   does with the value, at the boundary (§12). The workflow just returns `Option Patch`.
4. *You should ask a human once, not resample.* `draw` is a field the author simply does not vary.

No morphism separates them. A separate construct would be four duplicated code paths bought with
zero semantic content.

### q8 — Failure and partiality

**There is no partiality in the meaning.** Three phenomena get conflated as "errors"; separating
them removes the error channel entirely.

1. **The addressee declines, refuses, or emits garbage.** That is an *answer*, not an absence.
   It belongs in `El c`: `El verdictCode = Approve | Object (List Objection) | Declined`. The
   world stays total. This deletes an entire `ExceptT` layer and, with it, the question of how
   errors interact with panels and retries.
2. **The workflow gives up** — retries exhausted, human said no. That is an ordinary *value*:
   `Option A`, `A ⊕ Objection`. Produced by a pure `match`, not by an effect. `loop` above
   returns `Option A` for precisely this reason.
3. **Non-termination.** Excluded: `Dlg` is a *least* fixed point, so every dialogue is
   well-founded and `run w` is **total**. Every workflow terminates in every world; every cost is
   finite. This is the payoff of q5's deliberate Elgot-freedom.

So: `[[W A]] = Dlg A`, not `Dlg (Option A)`, not `Dlg A⊥`, not `World ⇀ A`. Partiality that
matters is in the answer type where the domain put it; partiality that does not matter is gone.

### q9 — What makes equality semantic

**Lawful by construction, and provably semantic. No quotient.**

Because the continuation in §2.3 is a Lean *function*, the monad laws for `Dlg` hold as
propositional equalities by structural induction plus `funext` — they are lemmas about an
inductive type, not axioms and not a `Quot`:

```
bind (pure a) k = k a                          -- by rfl
bind p pure = p                                -- induction + funext
bind (bind p k) h = bind p (fun a => bind (k a) h)   -- induction + funext
```

And the Forcing Lemma (§2.4) says this syntactic-looking equality *is* the semantic one:

```
p = p'   ↔   ∀ w. run w p = run w p' ∧ trace w p = trace w p'
```

Compare the alternative: a first-order `Term` syntax with named binders, an environment, and
`Var` nodes. There, α-equivalence, substitution, and the monad laws are all non-trivial, equality
must be a `Quot`, every function out of it needs a `Quot.lift` with a soundness proof, and
ill-scoped terms are representable. The higher-order carrier makes all of that unwritable rather
than merely manageable — the doctrine's instruction in its strongest form.

(Historical note without weight: this is why Elliott's own first paper was about higher-order
abstract syntax.)

### q10 — What the runtime-adherence theorem must say

Stated fully in §11. The shape, briefly: an interpreter `exec : Dlg A → IO A` speaking to live
processes must be proved a **monad morphism**, and adequacy must be stated **existentially over
worlds**, because a live run does not have a world — it *reveals* one.

```
∀ p τ a.  exec p ⇓ (τ, a)  →  Functional τ  →
             ∀ w ⊒ τ.  run w p = a  ∧  trace w p = τ  ∧  costOf τ = cost_w p
```

The interesting part is `Functional τ` (the transcript never answers one question two ways) and
who discharges it. A memoizing interpreter discharges it *by construction*; a non-memoizing one
must assume it of live agents, where it is false.

---

## 6. The API, derived (Steps 6–8)

Complete. Everything below is either a standard class member or three lines of derivation.

```lean
-- The only primitive
ask     : Q c → W (El c)

-- Free structure (Monad ⊃ Applicative ⊃ Functor), nothing written by hand
pure, (>>=), (<$>), (<*>), traverse, sequence, foldM, replicateM, …

-- Derived in three lines each
under   : Sig → W A → W A                       -- §5 q3   (monoid action)
draws   : Nat → Q c → W (List (El c))           -- §5 q1   (traverse)
panel   : List Scope → (Scope → Prompt) → W (List Verdict)   -- §5 q6 (traverse)
loop    : Nat → (S → W (Step S A)) → S → W (Option A)        -- §5 q5 (recursion on Nat)

-- Observations (the specification; §7, §8, §11)
run     : World → W A → A
trace   : World → W A → List Event
cost    : [Choice C] → (∀c, Q c → C) → W A → C
```

Names that do **not** appear, each deleted by a theorem or a class:
`share`, `label`, `ref`, `cache`, `parallel`, `par`, `fanout`, `withModel`, `local`, `retry`,
`catch`, `throw`, `askHuman`, `approve`, `session`, `Var`, `Let`, `Env`.

---

## 7. The morphism equations (Step 7 — this section *is* the specification)

Because the carrier was chosen to *be* the meaning, the doctrine's morphism discipline moves one
level out: the equations to write are those for the **observations**, each of which must be a
homomorphism for every class `W` inhabits. This is the whole specification; an implementation is
correct exactly when it satisfies it.

### 7.1 `run w` is a monad morphism into `Id`

```
run w (pure a)      =  a
run w (p >>= k)     =  run w (k (run w p))
run w (f <$> p)     =  f (run w p)
run w (mf <*> mx)   =  run w mf (run w mx)
run w (ask q)       =  w q
```

*Reading:* the value semantics forgets the asking entirely. Every theorem about "same answer,
sharing is free, order does not matter" is a corollary of this one line-per-operation.

### 7.2 `⟨run w, trace w⟩` is a monad morphism into `Writer (List Event)`

```
trace w (pure a)     =  []
trace w (ask q)      =  [⟨q, w q⟩]
trace w (p >>= k)    =  trace w p ++ trace w (k (run w p))
trace w (mf <*> mx)  =  trace w mf ++ trace w mx
trace w (under σ p)  =  map (relabel σ) (trace w p)
```

*Reading:* the transcript is a free-monoid homomorphism. This is what makes cost compositional
at all, and what §11 matches against a live run.

### 7.3 `under σ` is a monad morphism `Dlg → Dlg` (§5 q3)

```
under σ (pure a)   =  pure a
under σ (p >>= k)  =  under σ p >>= (under σ ∘ k)
under σ (ask q)    =  ask (σ q)
under id           =  id
under σ ∘ under τ  =  under (σ ∘ τ)
```

### 7.4 `cost` is a semiring morphism — strictly on `⊛`, laxly on `>>=`

Let `(C, 1, ⊗, ⊕)` be a **choice-semiring** with sequencing `⊗`, independent composition `∥`,
and alternation `⊕` (an indexed sup); let `μ : Q c → C` weigh a single question.

```
cost (pure a)          =  1
cost (ask q)           =  μ q
cost (p ∥ q)           =  cost p ∥ cost q             -- exact
cost (mf <*> mx)       =  cost mf ∥ cost mx           -- exact
cost (under σ p)       =  cost p [μ := μ ∘ σ]         -- exact
cost (matchS p ks)     =  cost p ⊗ (⊕ x. cost (ks x)) -- exact, finite ⊕
cost (p >>= k)         ≤  cost p ⊗ (⊕ a. cost (k a))  -- LAX: the morphism fails here
```

The last line is the derivation's one failed morphism, and §8 reads it.

### 7.5 `foldMap` is a monoid morphism on verdicts (§5 q6)

```
foldMap f []        =  ∅
foldMap f (v :: vs) =  f v ⊕ foldMap f vs
policy (u ⊕ v)      =  policy u ⊕ policy v     -- policies must be monoid homs, or be honest
```

---

## 8. Cost, in detail (the owner's directive (1))

### 8.1 The cost carrier is a semiring with three operations

Cost is not a number, because the domain measures two incomparable things and combines them
differently:

| | sequencing `⊗` | independence `∥` | alternation `⊕` |
|---|---|---|---|
| **spend** (dollars, tokens, calls) | `+` | `+` | `max` (worst) / `min` (best) / interval |
| **latency** (wall clock) | `+` | `max` | `max` / `min` / interval |
| **question set** (what gets asked) | `∪` | `∪` | `∪` |

One `cost` function, parameterized by the semiring, yields all three analyses. `∥` distinct from
`⊗` is exactly why "parallel" needs no combinator: the *class used* determines which operation
the analysis applies. Choosing the interval semiring `[min, max]` for `⊕` yields bounds; choosing
the free choice-tree semiring yields the tree itself, unfolded, with branch points visible.

### 8.2 The tri-partite cost theorem

*Theorem.* For `p : Dlg A` and any choice-semiring `C`:

1. If `Batch p` or `Pipeline p`, then `cost` is an **exact semiring homomorphism** and
   `∀ w. costOf (trace w p) = cost p` — a single value, world-independent.
2. If `Branching p`, then `cost p` is an **exact finite tree**, and its `⊕`-fold gives exact
   `[min, max]` bounds, attained.
3. In general, `costOf (trace w p) ≤ cost p`, and the exact cost is the function
   `λ w. costOf (trace w p)`, which is not finitely presentable.

*Caveat, stated because it is real:* (1) requires `μ` to factor through the question's *shape*
rather than its content. Per-call pricing and latency do; per-token pricing does not, since
`Pipeline` fixes the number of questions but not the length of the prompts. The honest statement
is therefore *"exact in the shape-determined semirings, bounded in the content-determined ones"*,
and the type system can carry that distinction because it is a property of `μ`, not of `p`.

### 8.3 Worked: the example's cost

For the workflow of §10, in the spend semiring with unit weights:

- style-guide read: `1`
- initial draft: `1`
- one review round: `3` (a `Batch`, so `∥` of three `1`s)
- one revision: `1`
- `loop 2` unfolds to a tree with 3 rounds of review and at most 2 revisions
- human confirmation: `1`

`cost = 1 + 1 + (3 ⊗ (approve ⊕ (1 + 3 ⊗ (approve ⊕ (1 + 3)))))  + 1` ⇒ **min 7, max 15**, with
the tree available in full for display. In the latency semiring the panels collapse to `1` each,
giving **min 5, max 9**. No profiling, no execution: read off the meaning.

### 8.4 Budgets are a graded monad, and grading is the lax morphism

Because §7.4's inequality is exactly the graded-monad shape, budgets come for free as a subtype:

```lean
def W (γ : C) (A : Type) := { p : Dlg A // cost p ≤ γ }

pure  : A → W 1 A
(<*>) : W γ (A → B) → W δ A → W (γ ∥ δ) B
(>>=) : W γ A → (A → W δ B) → W (γ ⊗ δ) B
```

The graded-monad laws *are* the semiring laws of `C` plus the lax inequalities. Nothing new is
proved; the grading is the failure of §7.4 read as a type index. Budgets become types, and
"this workflow costs at most $2" becomes a statement the type checker enforces.

---

## 9. What I deleted, and the theorem that authorized each deletion

| Deleted | Authorizing result |
|---|---|
| names / labels / `Var` / environments | continuations are functions; host binding suffices (§5 q2) |
| a `share` combinator | sharing is cost-only; `run w` is a monad morphism (§5 q2) |
| a `cache` flag | caching is the interpreter constructing the world (§5 q1, §11.3) |
| `parallel` / `par` / `fanout` | independence is `⊛`; scheduling freedom is a theorem (§5 q6) |
| a reader monad for model/mode | scope is in the question; `under` is a monoid action (§5 q3) |
| a `retry` primitive | structural recursion on `Nat` (§5 q5) |
| an error monad / `throw` / `catch` | declining is an answer; giving up is a value (§5 q8) |
| `askHuman` / approval nodes | `person` is an addressee; no morphism distinguishes it (§5 q7) |
| a `Panel` type | `traverse` (§5 q6) |
| a sampling primitive | `draw` is a field of the question (§5 q1) |
| a `Quot` on syntax | lawful-by-construction carrier + Forcing Lemma (§5 q9) |
| non-termination and `⊥` | least fixed point; `run` is total (§5 q8) |

Twelve constructs, twelve theorems. If a design has these constructs and not these theorems, the
constructs are carrying complexity that a meaning would have carried for free.

---

## 10. The example, in the kernel

> *Draft a patch under a deep model; three reviewers, two sharing one reading of a style guide;
> revise up to twice on objection; ask the human; apply only on yes.*

```lean
def workflow (task : Text) : W (Option Patch) := do
  let guide ← ask (readTool "STYLE.md")                             -- one reading …
  let p₀    ← under deep (ask (drafting task))                      -- … a deep draft
  let final ← loop 2 (fun p => do
      let vs ← panel [expert guide, stylist guide, fresh] (reviewOf p)  -- 3, independent
      match foldMap id vs with                                          -- verdict monoid
      | []   => pure (.stop p)                                          -- unanimous approve
      | objs => .again <$> ask (revising p objs))                       -- objection ⇒ revise
    p₀
  match final with
  | none   => pure none                                             -- revisions exhausted
  | some p => do let yes ← ask (confirming (person "john") p)       -- the human is an addressee
                 pure (if yes then some p else none)                -- "apply only on yes"
```

Twelve lines of workflow. Reading it against the design:

- `guide` is bound once and passed to two of the three reviewers — sharing, structurally, no
  labels (q2). The third reviewer does not receive it, which is visible in the code and in the
  trace.
- `under deep` scopes exactly one consultation and is a signature relabelling (q3).
- `panel` is `traverse`, so the three reviews are `Batch`; the analyzer sees `3` and the
  scheduler may run them concurrently (q6).
- `loop 2` is host recursion; the cost tree unfolds to depth 2 with visible branch points (q5).
- The human is an `ask` (q7).
- "Apply only on yes" is `Option Patch` returned to the caller — the workflow decides, the
  boundary acts (§12).
- Cost, statically: 7–15 calls, 5–9 latency units (§8.3).
- Everything except `readTool`/`drafting`/`reviewOf`/`revising`/`confirming` (which are just
  prompt constructors — ordinary data) is standard-library.

---

## 11. Runtime adherence (q10, in full)

### 11.1 What a live run is

An interpreter `exec : Dlg A → IO A` talks to processes. Instrument it to emit a transcript:

```
exec p ⇓ (τ, a)          τ : List (Σ c, Q c × El c),  a : A
Functional τ   :=   ∀ e e' ∈ τ. e.q = e'.q → e.answer = e'.answer
w ⊒ τ          :=   ∀ e ∈ τ. w e.q = e.answer
```

### 11.2 The theorem

**Adequacy.** If `exec` is a monad morphism — i.e. it satisfies, *by construction*,

```
exec (pure a)   =  return a
exec (p >>= k)  =  exec p >>= (exec ∘ k)
exec (ask q)    =  perform q
```

— then for every terminating run `exec p ⇓ (τ, a)` with `Functional τ`:

```
∀ w ⊒ τ.   run w p = a        ∧        trace w p = τ
```

and consequently, in any choice-semiring, `costOf τ = costOf (trace w p) ≤ cost p`, so the
static bound of §8 is a true bound on the live run.

*Proof.* Induction on `p`. `done`: both sides `a`, both traces empty. `ask c q f`: `exec`
performs `q`, obtaining some `x`, and `τ = ⟨q,x⟩ :: τ'`; any `w ⊒ τ` has `w q = x`, so
`run w (ask c q f) = run w (f x)` and `trace w (ask c q f) = ⟨q,x⟩ :: trace w (f x)`; apply the
induction hypothesis to `f x` and `τ'`. Termination is guaranteed because `Dlg` is
well-founded (§5 q8). ∎

This is the precise sense in which **"each operation commutes with the denotation"**: the three
`exec` equations are the commuting squares, one per operation, and adequacy is their closure over
all programs. Extending the language means adding one square, and adequacy re-derives.

### 11.3 The `Functional τ` hypothesis, and why caching is semantic infrastructure

Adequacy quantifies over worlds and so needs the transcript to be extensible to a world at all.
`Functional τ` is exactly that condition. Who supplies it?

- **A non-memoizing interpreter** must *assume* it — i.e. assume that a live model asked the same
  question twice answers identically. This is **false**. Adequacy would then be vacuous.
- **A memoizing interpreter** keyed on question identity **establishes** it by construction: the
  memo table *is* a finite partial world, extended monotonically as the run proceeds, and
  `Functional τ` is its functionality, which holds because it is a table.

*Corollary.* The runtime **must** memoize on question identity for adequacy to have content, and
when it does, adequacy assumes nothing whatever about the agents.

And nothing is lost, because deliberate resampling was made a property of the *question*
(`draw`, §5 q1): independent draws are distinct keys and are never conflated. This is the
derivation's most surprising result: **a feature everyone implements for speed is in fact the
mechanism that makes the semantics true.** A `cache : Bool` flag is not a tuning knob — it is a
switch for whether the specification applies.

### 11.4 What is left unproved, and where

One assumption survives, and it is stated once rather than scattered: `perform q` returns *some*
element of `El c`. Everything a live agent can do — refuse, time out, emit malformed output — is
an element of `El c` by §5 q8, so this assumption is discharged by parsing at the boundary with a
total function into a sum type that includes `Declined`. That is the entire trust boundary of the
system, and it is one function per answer code.

---

## 12. The one honest boundary: acts

`run w q` does not depend on what has already been asked. That statelessness is load-bearing:
scheduling freedom (§5 q6), memoization (§11.3), and sharing-is-free (§5 q2) all rest on it.
Reading tools (`grep`, file reads, running a test suite on a fixed tree) are consultations and
fit. **Writing** — applying the patch — does not.

The kernel's position is therefore explicit: **a workflow does not act; it decides.** Its meaning
is a dialogue returning a value, and the example's "apply only on yes" is *"yield `some patch`
only on yes"*. Application happens in the effectful shell that ran the workflow.

The generalization is available and its price is exactly computable. Split the signature
`Q = Consult ⊕ Act` and index the world by history, `World := History → Q c → El c`. Then:

- The Forcing Lemma still holds (dialogues are still strategies).
- `run` and `trace` still work, threading the history.
- Memoization becomes unsound on `Act`, so §11.3's corollary weakens to *"memoize the `Consult`
  part; assume nothing about `Act`."*
- `⊛` on two `Act`s no longer licenses concurrency: §5 q6's theorem fails.
- Exact cost survives; the equational theory does not.

Three theorems for one feature, with the ledger printed. That is the method working, and it is
the reason to keep acts at the boundary until a domain requirement pays the price.

---

## 13. The four completion tests

1. **Every type has a stated meaning.** `W A` is a dialogue; `Q c` is a question; `World` is an
   oracle; `Verdict` is a monoid element; `C` is a choice-semiring element. One line each.
2. **Every operation's meaning is forced.** §7 gives one morphism equation per operation, and no
   operation is named that a standard class already supplies (§4, §9).
3. **Nothing is left to prove.** Monad, applicative, monoid, and semiring laws hold by
   construction or by morphism. The remaining results — Forcing, functionality, sharing,
   scheduling freedom, tri-partite cost, adequacy — are *lemmas from* the denotation, which is
   what the doctrine asks for.
4. **Efficiency lives elsewhere.** `run w` is a valid (uncomputable) implementation. Batching,
   concurrency, memoization, streaming, and prompt caching are all refinements justified by §7's
   equations, and none of them moves the denotation. The one that looked like pure efficiency —
   memoization — turned out to be specification (§11.3), which is the method's characteristic
   kind of surprise.

**The three results this derivation would defend hardest:**

1. The **Pipeline** level (static arrows). Without it, "build a prompt from an earlier answer"
   is monadic and the most common pattern in the domain loses exact costing.
2. **Memoization is adequacy, not optimization** (§11.3).
3. **Sharing needs no names** because the continuation is a function (§5 q2, q9) — which
   simultaneously removes labels, scoping rules, capture, `Quot`, and ill-scoped terms.

---

## 14. Comparison against `agent-cat`'s `Term` calculus (written after un-blinding)

`agent-cat` (~10k lines of Lean, `Agentic/*.lean`, design revision 2.1) is built under the same
doctrine — its README's design rule is literally *"every declaration carries a docstring saying
what it means — for a type that is usually the form 'a `T` is a representation of …'"*. So this
is a like-for-like comparison, and where it disagrees with my derivation the disagreement is
substantive rather than stylistic.

Its shape: a first-order graded syntax `Term Op G L f i o` (`prim`, `pureT`, `seqT`, `parT`,
`sumT`, `choiceT`, `gateT`, `scopeT`, `shareT`, `retryT`, `fanT`, `bindT`) indexed by a fragment
grade `Frag = ℕ∞` (`static = 0`, `bounded n`, `monadic = ⊤`), with **two** meaning folds: `muS`
into matrices over a complete star semiring, and `muExt` into site-keyed partial functions over
an answer sheet `Env C O = C → O`.

### 14.1 What my derivation KEEPS (convergence the meaning forces)

- **The answer sheet.** `Env C O = C → O` is my `World`, for the same stated reason ("because
  `Env C O` is a *function*, the same question asked twice under the same `ε` receives the same
  answer"). Two independent derivations reaching the same object from the same q1 pressure is
  the strongest evidence available that the object is right.
- **Randomness at the edge.** Identical: one measure, at the outermost boundary, appearing in no
  operator and no law.
- **Scoping is a monoid action, and innermost-wins is a theorem** (`Agentic.Scope`, `Last` per
  axis). My `under` is the same fact obtained one step earlier — as a signature endomorphism
  rather than a reader — but the theorem is the same theorem.
- **Grading is an object, not a prohibition.** `Frag`'s slogan is exactly right and I keep it
  (§8.4), while changing what is graded (14.3).
- **Refusal is not an exception.** `gateT`'s "no `Halt` constructor, no exception, no
  early-return bias" is my §5 q8 reached by a different route.
- **`pin` — counterfactual substitution as `Function.update` on the answer sheet**, unifying
  forking a session, resuming from a checkpoint, and editing a cache. My derivation did not
  produce this and it is plainly right; `pin w q a := Function.update w q a` on `World` costs one
  line and I adopt it wholesale.
- **The resource semirings** (`Cost` max-plus, `Prob` Viterbi, the expectation semiring
  `P ⋉ M`). My §8 admits any choice-semiring and names none; agent-cat has done that work and it
  drops straight in.

### 14.2 What my derivation CHANGES

**(a) Two meanings become one.** `agent-cat` runs `muS` and `muExt` side by side and its own
`Meaning.lean` header records that **"there is no projection between them in either direction"**
— `muS` cannot respect extensional equality without forcing `1 + 1 = 1`, and matrix equality does
not imply extensional equality since `muS_dupPair_eq_sharedPair` holds by `rfl`. By the doctrine
that is a failed morphism, and the module names the consequences itself: the quantitative fold
**over-charges sharing by exactly the number of extra reads**, `peak` over-charges it identically,
and repairing it is an open work item (`acat-qtv`, *"a matrix has no room to record a site"*).

In my derivation there is one meaning, `Dlg`, and `run`, `trace`, and `cost` are all folds out of
it with `cost` factoring through `trace` (§7). Cost therefore *cannot* disagree with extension
about sharing: the trace records which questions were asked, so a shared reading is one event and
a duplicated one is two, in the same object that decides equality. The two-meaning split and the
whole `acat-qtv` problem do not arise — not because they are solved, but because the meaning was
chosen so that they are unstatable. That is the clearest evidence in this comparison that the
re-derivation is the simpler design.

**(b) The star semiring becomes structural recursion.** `Matrix` + `Star` + `Semiring` +
`Instances` is roughly 3,700 lines whose principal customer is `retryT`, solved as
`(M_A·d)* · M_B` with fuel as the star's truncation, requiring complete semirings, `csum` over
arbitrary index types, Kleene induction, and leastness. My §5 q5 makes `Dlg` a *least* fixed
point, so every dialogue is well-founded, retry is `n`-fold structural recursion in the host, and
its cost is the finite unfolded tree. No star, no completeness, no leastness obligation — and
nothing the domain asks for is lost, because real workflows say "up to twice" and never "until it
works". The star returns the day unbounded iteration is required, and §5 q5 prints its price in
advance (coinduction, partial `run`, `ℕ∞` costs).

**(c) The grade is defined by the fold instead of beside it.** `Frag` has its own arithmetic
(`⊔`, `+`, `scale n f = n * max 1 f`, `Frag.copies`) and the repository proves that the index does
**not** bound the quantity it is named for: `peak t ≤ f` is *false in both directions*
(`peak_not_le_grade`: `dupPair` peaks at 2 at grade `static`; `grade_zero_not_indep`), the true
statement being `peak t ≤ writtenSites t * Frag.copies f`. That is a failed morphism — the grade
is not a homomorphic image of the meaning. My §8.4 defines the index *as* the subtype cut by the
cost fold, `W γ A = { p : Dlg A // cost p ≤ γ }`, so "the index bounds the count" is true by
construction and the graded-monad laws are the semiring laws of `C` plus the lax inequality of
§7.4. Nothing has its own arithmetic.

**(d) The hierarchy is re-cut along branching, not only width.** `Frag`'s payload is
*data-dependent width* (fan-out), so `choiceT` and `retryT` are graded `.static`, and the axis the
owner's directive names — *"a tree structure whenever monad is genuinely involved"* — has no index
of its own. My §5 q4 cuts the hierarchy semantically (`Batch ⊂ Pipeline ⊂ Branching ⊂ Dynamic`,
predicates on `trace`) and gives the standard witnesses (free applicative ⊂ static arrows ⊂ free
**selective** ⊂ free monad), with the cost object per level: exact value, exact value, finite
**tree**, lax bound. `Selective` (Mokhov et al.) is the class `agent-cat` has not recognized;
`choiceT` + the finite-answer-type criterion (§5 q4) is precisely `matchS`, and naming it buys the
finite branch tree the owner asked for. Credit where due: `Term` is already a *category*
(`seqT`/`parT`/`choiceT`), so agent-cat has my Pipeline level — it merely conflates it with Batch
under `.static`, losing the "questions known before any answer" property that licenses real
batching.

**(e) `bindT` extends to the whole syntax.** `agent-cat` already uses a Lean function as the
continuation at `bindT` (paying `Type 1` for it) while keeping every other node first-order. My
`Dlg` uses a function at *every* node and stays in `Type 0` by indexing questions over a small
universe of answer codes. That one change is what §14.3 is about.

### 14.3 What my derivation DELETES

**Sharing labels, and with them the largest documented liability in the repository.** Because
`Term` is first-order, consultation identity must be *positional*, so `parT (prim q) (prim q)` is
two sites and sharing needs an explicit `shareT l t` that rebases keys to `(l, site-within-t)`.
The repository is scrupulous about what this costs, and the list is long: the fold **"keys on the
label alone and never compares bodies"**, so *"one label over two different bodies collides
wherever the inner sites coincide"*; **"body agreement is the designer's obligation, not a checked
property (acat-bmc)"**; and `shareT` is quantitatively transparent, so the cost fold cannot see
sharing at all (14.2a). That is doctrine anti-pattern 9 in its purest form — an invariant
maintained by documentation because the representation is too weak to carry it.

My §5 q2 deletes the entire mechanism. Continuations are functions, so "ask once, read twice" is
`let g ← ask q; …g…g…` and "ask twice" is two `ask`s; the distinction `Env.share_ne_dup` needs a
label to *state* is, in `Dlg`, a difference of traces. Deleted with it: the label type `L`, the
`Key`/`Site` machinery, key rebasing, `DecidableEq` questions, `acat-bmc`, and the possibility of
a mis-keyed workflow. Deliberate resampling survives untouched because it was made a property of
the question (`draw`), not of the sharing mechanism.

Also deleted: `gateT` and `Agentic.Gate` (permission is a `Bool` the pure code branches on;
refusal is an answer, §5 q8); `Agentic.Trace`'s Mazurkiewicz quotient (my trace is a list and its
permutation-freedom is the scheduling-freedom theorem, §5 q6); `Agentic.Context`'s compaction
(prompt construction is pure data); `Agentic.Keys` and `Agentic.Pareto` (choose a semiring);
`castGrade` and `toMonadic` (no bespoke grade arithmetic to transport along); and the `Panel`
module's convolution algebra (`traverse` + `foldMap`, §5 q6).

### 14.4 What `agent-cat` has that I do not, honestly

- **Nondeterministic alternation.** `sumT` denotes matrix addition — genuine alternatives, beam
  search, fallback with weight. `run w` in my kernel is a *function*, so my language has no
  nondeterminism operator; "try two and take the better" is `bestOf` (§5 q1), which is weaker.
  If weighted alternation is a requirement, my meaning must move from `World → A` to a
  semiring-weighted reading, and that is a real extension rather than a derivation.
- **Formalization.** ~10k lines of proved Lean against ~14 pages of derivation. Everything in
  §§7–11 above is stated but unproved.
- **The `1 + 1 = 1` theorem** (`one_add_one_of_muS_respects_WEq`) is a genuinely elegant result
  and it is the reason their design has two meanings; my answer is that the meaning should have
  been the trace-carrying one from the start, at which point the theorem becomes the observation
  that `run` forgets the trace.

**Net.** Keep: the answer sheet, randomness at the edge, scope-as-action, `pin`, the semirings,
grade-as-object. Change: one meaning instead of two; recursion instead of a star; the index
defined by the fold; the hierarchy cut by branching with `Selective` named; higher-order
throughout. Delete: sharing labels and their entire key apparatus, gates, trace quotients,
context compaction, panel convolution, and the bespoke grade arithmetic — roughly two-thirds of
the module list, each removal licensed by a theorem in §9 rather than by taste.
