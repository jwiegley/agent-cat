# The Rederivation Kernel

> **Historical — the code audited here no longer exists (2026-08-20).** This page
> audits the pre-re-derivation stratum: `Agentic/*.lean` outside `Core/` — the `Term`
> calculus, its two meaning functions, the `WEqR` quotient and the resource algebra
> under them. All of it was excised under obr `acat-q1i`, so every `file:line` below
> that names one of those modules resolves in git history only. The results that
> stratum established are transcribed in `doc/research/term-algebra-results.md`; read
> that page for *what was proved*, and this one for the reasoning that condemned it.
> Nothing here describes the code as it stands.
>
> **2026-08-26 placement ruling (`acat-cvx`).** The surviving K1 remains bare-Q:
> `Ω = (c : Code) → Q c → El c`, with dialogues, traces, tables and semantic prices
> over questions. The five-form `Plan` carries `Request = Q × Intent` as an
> executable annotation; `denote` erases it. Consult/observe reuse, effect
> occurrence policy, permission and v3 lockstep live below meaning. This preserves
> the kernel rather than enriching its generator.

*The kernel that survives the three attacks. Decided, not averaged: where the four proposals
conflict, one wins on Elliott's simplicity criteria and the owner's two directives, and the loser is
recorded with the sentence that killed it.*

**Sources reconciled.** `rederive-meaning-first` (MF), `rederive-algebra-first` (AF),
`rederive-decontaminate` (DC), `contamination-ledger` (CL), `attack-simplicity`,
`attack-adequacy`, `attack-realizability` (with its eight compiled Lean files), and the incumbent
`/Users/johnw/src/agent-cat` (11,196 lines).

---

## Thesis

> **A workflow is a plan for putting questions to things that answer, where each question is a
> function of earlier answers; its meaning is the coherent world-indexed pair (answer, transcript);
> and the syntax that carries it is neither point-free nor higher-order but *first-order with
> binders* — which is the only shape in which the author writes `let`, the analyser folds over a
> term, and the owner's cost factorization is both statable and true.**

Three attacks converge on one diagnosis and it is not the one any proposal made. All four
re-derivations answered "the world is a table indexed by questions, not positions" — right, and
forced. All four then reached for `Applicative ⊂ Selective ⊂ Monad` over *question values*, and the
adequacy attack showed that ladder's lower rungs are **empty in this domain**, because a free
applicative's question list is closed before any answer exists and every prompt after the first is
built from an earlier answer. MF alone saw the missing rung ("Pipeline"), named the free static
arrow as its witness, and then built a carrier that cannot represent it. The realizability attack
showed the *other* half: the higher-order carrier that makes the meaning compile makes the cost fold
undefinable without `Fintype` on every answer type.

The dilemma — *point-free plumbing or host binding* — is false, and the doctrine says to suspect
exactly that ("several of the corpus's cleanest results come from removing the dilemma rather than
choosing between the two"). The third option is to **own the binder**: an intrinsically-typed
first-order syntax `Plan Γ A` in which a question is built by a pure function of the variables in
scope. It gives the author `let` (so no labels, no `keep`, no copy combinator), gives the analyser a
term with an inspectable shape (so cost, width, the branch tree and the level are folds), and needs
no α-equivalence and no `Quot` (de Bruijn indices make ill-scoped terms unwritable). Everything else
in this document is a consequence.

---

## 1. The meaning table

One line per type. Nothing else is a type.

| type | `[[·]]` — a representation of *what* object |
|---|---|
| `Code`, `El : Code → Type` | a small universe of answer types; `El c` is **the set of things an addressee can say** in reply to a question of kind `c`. Every `El c` is inhabited and lives in `Type 0`. |
| `Q c` | **a question**: everything that determines the reply — addressee, mode, prompt payload, draw index. A point of question space. |
| `Ω` (world) | **one complete answer sheet**: `Ω := (c : Code) → Q c → El c`. A total function, in `Type 0`. |
| `Event`, `Trace` | **one thing said and its reply**: `Event := Σ c, Q c × El c`; `Trace := List Event`, the free monoid on `Event`. |
| `W A` (the workflow) | **the coherent world-indexed (answer, transcript) pair**: `[[W A]] = { (r,t) : Ω → A × Trace ∣ t is what r consulted, and r reads only what t recorded }`. |
| `Dlg A` | the **solved form** of the line above: `Dlg A = A + Σ (c:Code). Q c × (El c → Dlg A)`, least fixed point. Coherence is structural rather than a side condition. |
| `Γ : Ctx`, `Env Γ` | **what is known so far**: a context of answer types, and a point of its product. |
| `Expr Γ A` | **a pure function of what is known**: `Env Γ → A`. Prompt construction is ordinary data. |
| `Plan Γ A` | **the syntax**: a first-order, intrinsically-typed term denoting a workflow under an environment. `[[Plan Γ A]] = Env Γ → Dlg A`. |
| `Level` | **which analyses apply**: the four-element chain `batch ≤ pipeline ≤ branch ≤ dynamic`. Computed by a fold, never an index. |
| `S` (an analysis carrier) | a complete commutative semiring — cost (max-plus), possibility (`Prop`), probability (Viterbi), expectation (`SqZero P M`). |
| `CostTree` | **the branch structure with both arms present**: `leaf S ∣ node (tag → CostTree)`, finite. |
| `G` (scope) | a per-axis `LastOpt` product monoid; `[[G]]` = the monoid of scope overrides, whose non-commutativity *is* innermost-wins. |

**The Forcing Lemma** (MF §2.4, and it is why row 6 is legitimate rather than anti-pattern 2):
for `p p' : Dlg A`, `p = p' ↔ ∀ ω, run ω p = run ω p' ∧ trace ω p = trace ω p'`. `Dlg A` is not one
encoding of the observation pair; it *is* that object, presented so that coherence is structural.
The presentation order matters and MF got it backwards: **lead with the observation pair, derive the
tree.** (`attack-simplicity` §2, Test 1.)

**What the meaning is not**, each rejected because it is a machine fact promoted into the model:
a distribution over answers (loses the correlation that one question answered twice agrees);
`World → A` alone (cost is not a function of it — MF §2.2's failed morphism, which is what forces
the transcript); `Runner → …` (an interpreter where a sample point was specified — CL row 3);
anything indexed by a syntactic path, a history, a label, or a node id.

---

## 2. The generating algebra, and why it is minimal

### 2.1 Five term formers

```lean
inductive Plan : Ctx → Type → Type 1 where
  | ret  : Expr Γ A                              → Plan Γ A
  | askC : (c : Code) → Q c        → Plan (Γ ▷ El c) A → Plan Γ A   -- closed question
  | ask  : (c : Code) → Expr Γ (Q c) → Plan (Γ ▷ El c) A → Plan Γ A   -- question built from answers
  | case : {T : Type} [Fintype T] [DecidableEq T] →
           Expr Γ T → (T → Plan Γ A)             → Plan Γ A          -- finite-tag branching
  | dyn  : Expr Γ B → (B → Plan Γ A)             → Plan Γ A          -- quarantined: B unbounded
```

`ask` is **ask-and-bind**: the generator and the binder in one node, so the syntax is already
A-normal and the analyses never have to reconstruct where an answer goes. Variables are de Bruijn
indices, so there is no α-equivalence, no capture, no substitution soundness side condition, and no
ill-scoped term (`attack-adequacy` §10; this answers MF §5 q9's objection to first-order syntax,
which was an objection to *named* first-order syntax).

### 2.2 The morphism equations — these *are* the specification

`den : Plan Γ A → Env Γ → Dlg A`:

```
den (ret e)        γ = .done (e γ)
den (askC c q k)   γ = .ask c q       (fun x => den k (γ ▷ x))
den (ask  c e k)   γ = .ask c (e γ)   (fun x => den k (γ ▷ x))
den (case e arms)  γ = den (arms (e γ)) γ
den (dyn  e f)     γ = den (f (e γ))  γ
```

The observations out of the meaning, each a class morphism:

```
run ω : Dlg ⇒ Id                    -- a monad morphism
  run ω (.done a)    = a
  run ω (.ask c q f) = run ω (f (ω c q))

⟨run ω, trace ω⟩ : Dlg ⇒ Writer Trace     -- a monad morphism into the free monoid
  trace ω (.done _)    = []
  trace ω (.ask c q f) = ⟨c,q,ω c q⟩ :: trace ω (f (ω c q))

under σ : Dlg ⇒ Dlg                 -- the unique monad morphism extending ask ∘ σ; a monoid action
  under σ (.ask c q f) = .ask c (σ q) (under σ ∘ f)
  under 1 = id      under σ ∘ under τ = under (σ ∘ τ)

bill_S : Trace → S                  -- a monoid morphism, one per semiring and pricing
```

`Plan` is not itself a monad (it is a syntax), so what must be proved instead is that the *derived*
forms respect the meaning: substitution and weakening lemmas, and
`den (p ≫= k) γ = den p γ >>= (fun a => den (k a) γ)` for the derived sequencing. Those are the
equations every derived form in §2.4 is checked against.

### 2.3 Why each retained primitive is forced

- **`ret`** — the unit. Without it a workflow cannot produce a value. Morphism: `den (ret e) γ = pure (e γ)`.
- **`askC`** — the generator, and the *only* effect. Model, tool and human are three inhabitants of
  one `Q` (q7). Its question is closed, and that is not decoration: it is what gives a
  `Const S`-valued analysis a domain. **AF §4.2's argument, imported verbatim and it is the single
  most valuable paragraph in the four documents**: `Const S` is `Applicative` and not `Monad`, so
  the exact-bill homomorphism exists at the closed fragment and provably nowhere above it. The level
  must be *recorded in the term* or the analysis is not well defined (`attack-adequacy` F1 refutes
  MF outright on this point).
- **`ask`** — forced by the domain's pivot: *the prompt is a function of an earlier answer.* Without
  this node, "two reviewers sharing one reading of a style guide" — the owner's own example — is
  `bind`, the workflow is monadic, and by every kernel's own theorems it has no static cost. This is
  the rung MF named and could not carry, and that K2/K3/K4 do not have at all
  (`attack-adequacy` §1, §2.2). It is Elliott's Step-6 arrow row (`Op i o ≅ i → Q o`) obtained with
  a binder instead of a point-free spine.
- **`case`** — forced by directive (1)'s "a tree structure whenever branching happens". Both arms are
  present in the term, so the cost is a genuine finite tree, and the payload rides in the context
  into whichever arm is taken — which is `ArrowChoice`'s `|||` with open arms, and which
  `Selective` gives only when the arms are closed. We **recognize the class** (`case` is
  `Selective.branch`; the fragment is the selective fragment) and **do not depend on a free
  selective construction**, because only the free *rigid* selective is known and the general
  construction is open (`attack-realizability` §6.1 — the largest unlanded dependency in the
  dossier, here deleted rather than budgeted).
- **`dyn`** — forced by directive (1)'s "retain monad in cases where decision branching on answers is
  needed", for the residue that `case` cannot reach: a plan computed from an unbounded answer. It is
  the one higher-order node, exactly as agent-cat's `bindT` is (the one constructor CL judged
  FORCED). Quarantined: `level (dyn …) = dynamic`, and the **non-existence** of an analysis
  homomorphism there is a theorem (§4, obligation C4) — the honest replacement for `Frag`.

Redundancy is admitted once, deliberately: `askC c q k` and `ask c (const q) k` have the same
meaning. That is the specification's own "no weakening constructor" rule bent, and it is bent for
AF's reason and only that reason. It carries a coherence obligation (§4, C0).

### 2.4 Every deleted construct, with its derived form

| agent-cat | here | why it is not a primitive |
|---|---|---|
| `prim` | `askC` / `ask` | the generator, split by whether the question is closed |
| `pureT` | `ret`, and `Expr` composition | a pure function is data, not an effect |
| `seqT` | juxtaposition of `ask` nodes | ask-and-bind already sequences; `>>=` is substitution |
| `parT` | two `ask` nodes whose questions do not mention each other's variable | independence is a **decidable predicate on the term**, not a former (q6) |
| `sumT` | `case` on an acceptability tag | a plan is deterministic given a world; weighted alternation is a search strategy over plans, not a plan |
| `choiceT` | `case` | `Selective.branch`, with the payload on the wire |
| `gateT` | `case` on a `Bool` | the not-taken arm contributes nothing to the taken path; annihilation is a theorem about the bill, and `Gate.indicator`/`smul` remain the statement at the matrix carrier |
| `scopeT` | `under σ`, a fold | agent-cat's own no-weakening rule: "that is a fold, defined where the recursion's target lives, not a constructor" |
| `shareT ℓ` | a de Bruijn variable used twice | sharing **is** binding; labels name nothing once the world is keyed by questions |
| `retryT n` | `Nat.rec` in the metalanguage, building an unrolled plan | the meaning is the unrolling; no star, no truncation, no ℕ∞ |
| `fanT n` | `case` on a length tag carried **in the answer type**, then an unrolled sequence | the bound belongs where the domain puts it — in the answer — not in a meaning that truncates |
| `bindT` | `dyn` | kept, quarantined, with a non-existence theorem attached |

Twelve constructors and a grade index become **five formers and a fold**.

### 2.5 The width repair, which nobody proposed

`attack-adequacy` §4 states it and it is adopted: put the bound in the answer type.

```lean
El fileListCode := Σ n, PLift (n ≤ 8) × Vec File n      -- or  Vec File 8 ⊕ TooMany
```

The boundary parser that must already turn a tool's stdout into a typed answer is exactly where
"more than eight files" becomes a *value the workflow branches on*. Then `case` on the length tag
selects a statically unrolled arm, width is exact, the cost tree has nine leaves, **and no meaning
truncates anything**. This closes CL row 5 without deleting the bound, and it is the correct
application of "partiality that matters lives in the answer type" (q8) to width instead of failure.

---

## 3. The ten questions, answered

> **q1. If the same question is asked twice, is it the same answer or independent samples? What is
> resampling? What does caching MEAN?**

**Same answer.** `Ω` is a function; that is its type, not a policy. Two occurrences of one question
denote one answer in every world.

**Resampling is a different question, not a different operation.** `Q c` carries `draw : Nat` and a
namespace component of `scope`. `bestOf` is an ordinary combinator:

```lean
def draws (ns : Name) (n : Nat) (q : Q c) : Plan Γ (Vec (El c) n) :=   -- n-fold unrolled askC
def bestOf (ns) (n) (q) (judge : Q jc) := ask jc (fun γ => judgeQ (γ.candidates)) …
```

**Hygiene without a gensym.** AF needed one and never said where it came from
(`attack-simplicity` §3, Test 2); MF had no story at all. Here the namespace is an **ordinary
argument the author supplies**. Two call sites of `draws "a" 3 q` and `draws "a" 3 q` get the same
three answers — which is the *defined* meaning, is reported by the `asks` fold before it is paid
for, and is therefore a checkable fact rather than a silent bug. Nothing stateful is required at any
layer.

**Caching means the construction of the world, and it is not a mode.** A memo table keyed on
question identity *is* a finite world, extended monotonically; a memoizing interpreter therefore
discharges the functionality condition **structurally**, and the value-adequacy theorem then assumes
nothing whatever about the agents (`attack-realizability` §5.2, compiled, `#print axioms` =
`[propext]`). MF's stronger claim — that the runtime *must* memoize or adequacy is vacuous — is
right in effect and better stated as: a non-memoizing runtime simply has no adequacy theorem, and
the certificate of §5 is what a run carries instead. Content-addressed caching across occurrences is
sound **because** two occurrences of one question denote one answer; it needs no side condition
here, unlike DC's kernel oracle, where it silently replaces two draws by one.

> **q2. What IS sharing — labels, or structural?**

**Structural: a variable used twice.** `ask c e₁ (… x … x …)` consults once and reads twice;
two `ask` nodes consult twice. `share_ne_dup` — the theorem the incumbent's entire label/site/key
apparatus exists to state — is two lines about traces: one event versus two, in the object that
decides equality.

The point the applicative kernels miss, and the reason this kernel exists: the shared answer feeds
**another question**, not just a pure function. MF's, AF's and DC's sharing theorems are all stated
for pure consumers (`f, g` pure; `(fun a => (a,a)) <$> ask q`), and the domain's sharing case is not
covered by the theorem offered for it (`attack-adequacy` §1). Here `ask` takes `Expr Γ (Q c)`, so
the guide flows into two reviewer prompts and the plan stays at the **pipeline** rung, exactly costed.

Deleted with labels: `L`, `Step`, `Site`, `Key`, `rebase`, `relocate`, `splice`, `Relabels`,
`Runner.rename`, `WLe`, `WEqR`, the four missing congruences, and `acat-bmc` (an invariant
maintained by documentation — anti-pattern 9 — and one the *precedent* actually checked).

> **q3. What is scoping — primitive, an index transformation, or part of the question?**

**Part of the question**, because what determines the answer belongs in the question: which model,
at what temperature, in which mode. The bulk operator is derived: `under σ : Plan Γ A → Plan Γ A`,
the fold relabelling every question, which is the unique morphism extending `ask ∘ σ` and hence a
**monoid action** of `(Sig, ∘, id)`. `under 1 = id` and `under σ ∘ under τ = under (σ ∘ τ)` are the
action laws, free.

`LastOpt` survives verbatim — a genuine Mathlib gap (the right-zero semigroup with unit adjoined),
whose non-commutativity *is* innermost-wins — together with `Scope`'s product and
`axis_independence`. What dies is `scopeT` as a constructor and the `Scoped G R` stratum around
every meaning: MF's `under` is one mechanism where DC has two (`attack-simplicity` I7).

> **q4. The hierarchy: which STANDARD structures, and how does cost factor?**

Four rungs, computed by a **fold** `level : Plan Γ A → Level`, never by a type index:

| rung | syntactic criterion | recognized class | what the analysis yields |
|---|---|---|---|
| `batch` | only `askC` and `ret` | free `Applicative` | the **exact question multiset**, world-independent; exact bill |
| `pipeline` | `ask` allowed; no `case`, no `dyn` | free **static arrow** (`Category` + `Cartesian`, Hughes's `Arrow` without `app`) | the exact **count** and the exact **shape sequence**; exact bill iff pricing factors through shape |
| `branch` | `case` allowed; no `dyn` | `Selective` (`branch`), realized directly | an exact finite **CostTree**; attained min/max by tropical folds |
| `dynamic` | `dyn` present | `Monad` | **no analysis homomorphism exists** — and that non-existence is a theorem |

Two things must be said plainly.

**The grade is a fold and not an index.** `attack-realizability` compiled the refutation: Lean
refuses to eliminate `W : Grade → Type → Type` whose index is a computed `max g g'` (*"Dependent
elimination failed"*, `D_graded_index_fails.lean`), so every theorem AF states about `W .ap A` never
gets off the ground; the working repair, verified in `E_grade_as_fold_works.lean`, is grade-as-fold
plus a totality theorem. That is CL's own verdict on `Frag` — *"a type index that provably fails to
bound the quantity it was introduced for is not a specification, it is a decoration"* — turned
around and applied to the proposal that made the accusation. **In Lean, a semilattice-valued index
on an inductive family is nearly always a mistake; make it a fold and prove the theorem.**

**The syntactic level is finer than a trace predicate, and that is why it is sound.** MF defined the
rungs as semantic predicates on traces and its Pipeline theorem is *false*: `ask c` then
`if v then ask q₁ else ask q₂` has constant trace length in every world but world-dependent cost
(`attack-simplicity` §2, Test 3). Here that term contains a `case`, so `level = branch`, and the
theorem it satisfies is the tree theorem, which is true. The syntactic fold avoids the refuted
statement by construction. The cost of this choice is honest and stated in §8: the fold classifies
*terms*, and whether it exactly captures the corresponding semantic fragment is open.

> **q5. Retry / bounded iteration: primitive or derived? What does it mean?**

**Derived, in the metalanguage, and its meaning is the unrolling.**

```lean
def revise : Nat → (Γ ⊢ body producing a finite verdict tag) → Plan Γ (Option Patch)
  | 0,   _    => ret (fun _ => none)
  | n+1, body => review ≫ case verdict (fun | .approve => ret some
                                            | .object  => reviseOnce ≫ revise n body)
```

Three points, all corrections.

1. **Check first, revise in the recursive call.** MF, AF and DC all wrote the body as
   *review-then-maybe-revise*, so `loop 2` performs two reviews, two revisions, and pays for a final
   revision it never reviews (`attack-adequacy` A1). "Revise up to twice" wants **three reviews and
   two revisions**. Three independent derivations wrote the domain's single most-used combinator
   backwards; the shape above is the one the English asks for.
2. **No truncated star.** CL row 10's charge — *"the meaning is truncated in order to make an index
   true"* — is answered by deleting both the index and the truncation. The unrolled plan's meaning is
   its unrolling; the cost is a finite tree of depth `n`; `Star.lean`'s `retryTrunc` and `starTrunc`
   are not needed.
3. **Unbounded iteration is deliberately absent**, and its price is printed in advance: a coinductive
   `Dlg`, an Elgot operator, `run` becoming partial, costs moving to `ℕ∞`, and four theorems dying
   together. Real workflows say "up to twice", never "until it works" (MF §5 q5, adopted).

> **q6. Panels: what structure, where does the reducer enter, is "parallel" semantic or runtime?**

**Structure:** a sequence of `ask` nodes whose question expressions do not mention one another's
variables. **The reducer enters in the pure part**, as `foldMap` into a verdict monoid inside a `ret`
or the next question's `Expr`. Quorum is not a homomorphism out of the concatenation monoid — it is
one out of `(ℕ,+)` after mapping each reviewer to `0`/`1`, and that the algebra tells you which
policies are compositional is a genuine return on the standard class.

**"Parallel" is a runtime fact; independence is the semantic one — and here it is *decidable*.**

```lean
def indep : Plan Γ A → Bool          -- occurs-check on de Bruijn indices, a fold
theorem may_reorder : indep p = true →
    ∀ ω, run ω (den p γ) = run ω (den (swap p) γ) ∧ trace ω (den p γ) ~ trace ω (den (swap p) γ)
```

This is strictly better than every proposal in the dossier. MF's scheduling-freedom theorem has a
hypothesis ("for `p` built with `⊛` only") that is not a property of `p`, so a runtime cannot check
it (`attack-adequacy` A4); AF's needs grade `ap`, which no workload reaches; the incumbent needed a
`parT` constructor. Here the licence is a `Bool` the scheduler computes from the term.

Convolution survives where it belongs: the *distribution* of a panel's aggregate verdict is a
product in the monoid semiring `S⟨K⟩`, which is `Panel.lean`'s theorem, now reachable from a written
plan for the first time (`acat-x9v` closed).

> **q7. Human-in-the-loop: a distinct construct, or the same effect with a different addressee?**

**The same effect.** `Addressee = model ∣ tool ∣ person`. Run the diagnostic properly: latency is a
cost coordinate; "they may not reply" is a fact about `El c` (q8); "their answer carries authority"
is a fact about what the caller does at the boundary (§7); "ask a human once" is a `draw` the author
does not vary. **No morphism separates them**, therefore no construct does. The differences are cost
coordinates — `price` loads `HumanMinutes`, and is monotone in `draw`.

> **q8. Failure and partiality: where does "no outcome" live?**

**In the answer type, and in ordinary values. There is no partiality in the meaning.**

- The addressee declines, refuses, times out, or emits garbage: that is an **answer**.
  `El verdictCode = Approve ∣ Object (List Objection) ∣ Declined`. The world stays total, and an
  entire `ExceptT` layer is deleted along with the question of how errors interact with panels and
  retries. AF's Attempt E is the argument: an error layer short-circuits, so the consulted count
  depends on answers even at the batch rung, and the exact-cost theorem becomes false for every
  fallible workflow — i.e. for every real one.
- The workflow gives up: an ordinary **value**, `Option A` or `A ⊕ Objection`, produced by `case`.
- Non-termination: **excluded**. `Dlg` is a least fixed point and `Plan` is finite, so `run ω` is
  total and every cost is finite.

So `[[W A]] = Dlg A`, not `Dlg (Option A)`, not `World ⇀ A`, and no `⊥` anywhere. The one thing DC
buys that this gives up is a semantic zero that annihilates downstream cost; here refusal is a
`case` arm whose taken path costs nothing, which reproduces the cost collapse *on the path* while
keeping `Gate.indicator`/`smul` as the statement at the matrix carrier.

> **q9. What makes equality semantic?**

**Equality is the kernel of the meaning, and by the Forcing Lemma it is plain `=` on `Dlg`.**

```lean
p ≈ p'  ⟺  ∀ γ, den p γ = den p' γ  ⟺  ∀ γ ω, run ω (den p γ) = run ω (den p' γ)
                                            ∧ trace ω (den p γ) = trace ω (den p' γ)
```

Three consequences, each of which deletes something the incumbent had to build.

1. **Congruence is free.** The kernel of a compositional meaning function is automatically a
   congruence for every former, with no proof. agent-cat's four missing congruences (`retryT`,
   `fanT`, `bindT`, `shareT` — the last impossible in kind) are missing because `WEqR` is `∃σ. …`
   and is not the kernel of anything.
2. **No quotient.** `Dlg`'s monad laws hold as propositional equalities by induction plus `funext`
   — compiled, `A_dlg_lawful.lean`, no `Quot`, no `Classical.choice`. AF's and DC's quotiented-free
   carriers make `bind` noncomputable (`F_quotient_needs_choice.lean`), so the interpreter cannot
   run on the semantic type.
3. **Cost is an invariant of equality.** Because the transcript is *in* the meaning, a shared read
   is one event and a duplicated read is two **in the object that decides equality**. This is MF's
   best insight and it is decisive: `acat-qtv` ("a matrix has no room to record a site") and the
   two-meaning split it belongs to become unstatable rather than unsolved, and
   `one_add_one_of_muS_respects_WEq` — the incumbent's proof that no cost fold descends to its
   quotient — has no analogue here.

> **q10. What must the runtime-adherence theorem SAY?**

See §5. In one sentence: **a run exhibits a finite world; every total world extending it assigns the
plan exactly the value the run returned** — proved against an arbitrary history-dependent
adversarial agent, and available additionally as a *decidable per-run certificate* with zero axioms.
`IO` is never modelled.

---

## 4. The graded hierarchy and the cost-factorization theorem, as Lean proof obligations

Let `price : (c : Code) → Q c → S` for a complete commutative semiring `S`, and

```lean
def bill (price) : Trace → S                      -- monoid morphism; two readings, see below
def PricesByShape (price) : Prop :=
  ∀ c (q q' : Q c), shape q = shape q' → price c q = price c q'
```

`shape q` is the addressee, model, mode and size class — everything except the prompt text. Per-call
and per-latency pricing satisfy `PricesByShape`; per-token pricing does not. This hypothesis is the
one `attack-simplicity` I1 and `attack-adequacy` §7 both identify as missing from all four
proposals, and it is the difference between an exact bill and a bounded one.

**Two bills, both derived, neither baked in.** `billFresh` sums over all events; `billMemo` sums over
distinct questions. AF made idempotence a property of the cost *carrier* (`Finset Q`), which bakes a
memoizing runtime into the denotation and violates step 9; MF used an additive carrier, which is
inconsistent with the memoization its own adequacy requires (`attack-realizability` §3.1). Carrying
the trace and deriving both bills dissolves the dispute — the richer object is kept and the
observable is derived, which is what the doctrine asks.

### The obligations

```lean
-- C0  Coherence of the recorded closedness (the one admitted redundancy)
theorem askC_coherent : den (askC c q k) γ = den (ask c (fun _ => q) k) γ

-- C1  BATCH: exact, world-independent bill
theorem cost_exact_batch (p : Plan Γ A) (h : level p = .batch) (hp : PricesByShape price) :
    ∀ γ ω ω', bill price (trace ω (den p γ)) = bill price (trace ω' (den p γ))
            ∧ bill price (trace ω (den p γ)) = asks price p          -- a fold of the term alone

-- C2  PIPELINE: exact count and exact shape sequence; exact bill under PricesByShape
theorem cost_exact_pipeline (p) (h : level p ≤ .pipeline) :
    ∀ γ ω ω', (trace ω (den p γ)).map evShape = (trace ω' (den p γ)).map evShape
theorem bill_exact_pipeline (p) (h : level p ≤ .pipeline) (hp : PricesByShape price) :
    ∀ γ ω, bill price (trace ω (den p γ)) = asks price p

-- C3  BRANCH: an exact finite tree, and attained bounds
theorem cost_tree_branch (p) (h : level p ≤ .branch) :
    ∀ γ ω, bill price (trace ω (den p γ)) = evalTree (costTree price p) (decisions p γ ω)
theorem cost_bounds_attained (p) (h : level p ≤ .branch) :
    minFold (costTree price p) ≤ bill price (trace ω (den p γ)) ≤ maxFold (costTree price p)
    ∧ ∃ ω⁻ ω⁺, the two ends are attained
-- minFold/maxFold are the folds at the min-plus and max-plus tropical semirings; the interval is
-- the fold at their product (the doctrine's own toolbox row).

-- C4  DYNAMIC: the honest replacement for Frag — a NON-EXISTENCE theorem
theorem no_static_bill_at_dyn :
    ¬ ∃ Φ : (∀ {Γ A}, Plan Γ A → S), ∀ p γ ω, Φ p = bill price (trace ω (den p γ))
-- witnessed by a `dyn` over an infinite answer type whose two branches have different bills.

-- C5  Soundness of the level fold as an over-approximation
theorem level_sound : level p ≤ ℓ → (the analyses licensed at ℓ apply to p)
```

**C1–C4 are directive (1), stated once.** "Exact value when monad is not necessary; a tree when
branching is genuinely involved; nothing at full monad, truthfully." The owner's requirement is
claimed by all four re-derivations and satisfied by none of them on any workflow in the brief
(`attack-adequacy` §7); it is satisfied here on all six, because the `ask` node keeps content-
dependent prompts *below* the monadic rung.

**Budgets as types** follow from C1–C3 without new machinery: `PlanUpTo γ Γ A := { p : Plan Γ A //
level p ≤ .branch ∧ maxFold (costTree price p) ≤ γ }`. Unlike MF §8.4, the defining function exists
— `maxFold ∘ costTree` is a computable fold of a first-order term, where MF's `cost` requires
`Fintype (El c)` and is therefore undefined for free-text answers (`G_cost_needs_fintype.lean`).

---

## 5. Runtime adherence (Path 2)

Three statements, in increasing strength, all over the *first-order* plan via `den`.

**(i) Commutation is `rfl`, because the interpreter is the fold.** AF §7 q10 Part A, and it is
correct and free. Writing the interpreter as anything other than `den` at the execution monad is
what would make this theorem hard, and there is no reason to.

**(ii) Adequacy against an adversarial agent.** Compiled in `B_adequacy.lean`; restated here over
`Plan`:

```lean
abbrev Strategy := Hist → (c : Code) → (q : Q c) → El c     -- history-dependent, may lie, may drift
abbrev Table    := List ((c : Code) × (q : Q c) × El c)     -- the memo table = a finite world
def Extends (w : Ω) (t : Table) : Prop := ∀ c q a, lookup t c q = some a → w c q = a

theorem adequacy (σ : Strategy) (p : Plan ∅ A) (t : Table) :
    ∀ w, Extends w (exec σ t (den p ())).1 → run w (den p ()) = (exec σ t (den p ())).2
-- #print axioms adequacy  →  [Code, El, Q, propext]
```

No Mathlib, no `sorry`, no `Classical.choice`, and **no assumption whatsoever about the agents**.
MF's `Functional τ` hypothesis is not assumed — the memo table discharges it structurally. The
lemma that needed strengthening (`prepending preserves lookups only if the key was absent`) is
precisely the memoization discipline, formalized.

**(iii) The decidable per-run certificate.** `C_certificate.lean`, `#print axioms` empty:

```lean
def worldOf (t : Table) : Ω := fun c q => (lookup t c q).getD default
def certify (p : Plan ∅ A) (t : Table) (a : A) [DecidableEq A] : Bool :=
  decide (run (worldOf t) (den p ()) = a)
theorem certify_sound : certify p t a = true → ∃ w : Ω, run w (den p ()) = a

-- and the cost half, which is new here because the static bound now exists:
theorem certify_cost (h : level p ≤ .branch) :
    certify p t a = true →
      bill price (traceOf t) ∈ leaves (costTree price p)
      ∧ minFold (costTree price p) ≤ bill price (traceOf t) ≤ maxFold (costTree price p)
```

**Why this is the right answer and the three documents' are not.** DC's `ρ : IO ⇒ V` ("the law of an
`IO` action") is not a Lean object; both it and `IsMonadHom ρ` must be axioms that no term can
instantiate — a strictly larger trust boundary than the one proved here, and the opposite of what
that document claims for itself. AF's Part B needs an operational semantics for `IO` plus an
oracle-fidelity axiom. The certificate models `IO` not at all: each run carries its own
machine-checked warrant.

**What is left outside, stated so it is not oversold.** The certificate certifies *this* run's value
and bill, not the workflow and not the next run. It needs `DecidableEq` on results and questions
(true for the domain, records over strings). It is only as good as the log — the ACP shim must be the
only path to `perform`, a code-organization obligation. And the entire remaining trust boundary is
**one total parsing function per `Code`**, discharged by construction once `Declined` is an answer
(q8). The independence/fidelity axiom that DC and AF both introduce here is *not needed for the
value semantics* and should be quarantined in the distributional layer, where it belongs.

---

## 6. The KILL LIST and the SURVIVAL LIST

Specific, by declaration, against `/Users/johnw/src/agent-cat` at 11,196 lines.

### KILL — the syntax stratum and everything built to give it a meaning

| module | declarations that die | lines |
|---|---|---|
| `Agentic/Term.lean` | **all of it**: `Term` (12 constructors), `grade`, `castGrade`, `toMonadic`, `dupPair`, `sharedPair`, and the `noncomputable` literal workflows at `:323,347,353,360,366,380` | 535 |
| `Agentic/Frag.lean` | **all of it**: `Frag := ℕ∞`, `static/bounded/monadic`, `copies`, `scale` (with its `max 1`), and all 15 arithmetic theorems | 285 |
| `Agentic/Meaning.lean` | **all of it.** `Interp`, `muS` + its 12 clause theorems, `widthT`; `Step` (14 constructors), `Site`, `Key`, `root/push/rebase/extend/relocate/splice`; `Runner`, `Relabels`, `Runner.rename`; `retryLoop`, `retryLoop_congr`, `fanRun`, `fanRun_congr`; `muExt` + ~30 theorems, `AgreeBelow`, `muExt_transport`, `muExt_rename`; `peak`, `writtenSites`, `peak_le_writtenSites_mul_copies` and the whole of Stage 2b; `WEq`, `WLe`, `WEqR`, `seqAssocPath`, all six `WLe.*_congr` and six `WEqR.*_congr`, `wSetoidR`, `Workflow`, `Workflow.seq`, `StaticObj`, `staticCategory` | 2831 |
| `Agentic/Env.lean` | the toy stratum only: `Ext`, `extId`, `extNone`, `extComp` + 5 laws, `cachedAt`, `cached_eq`, `askPair*`, `shareEx`, `dupEx`, `epsSplit`, `share_ne_dup`, `TwoQ` — superseded by traces | ~180 of 342 |
| `Agentic/Trace.lean` | `Swap`, `traceCon`, `Trace`, `Session`, `deriv` — the Mazurkiewicz quotient; the transcript is a list and reordering is the decidable-independence theorem (q6) | 221 → attic |
| `Agentic/Context.lean` | `Interior`, `Ctx`, `collapse`, `constIx` — compaction as an interior operator, unreached by any term; prompt construction is pure `Expr` | 153 → attic |
| `Agentic/Pareto.lean` | `pareto_incomparable` — a true fact about multi-objective cost, no consumer | 65 → attic |
| `Agentic/Matrix.lean` | `fanMat`, `fanMat_take`, `fanMat_eq_zero_of_length_gt`, `fanMat_zero` (die with `fanT`'s truncation); `retryTrunc*` (dies with the truncated star) | ~80 |
| `Agentic/Star.lean` | `starTrunc` and its ~8 lemmas | ~60 |
| `Agentic/Panel.lean` | the hand-written applicative half — trim to the convolution carrier and its four theorems | ~600 of 843 |
| `example/*.lean`, `test/Pollution.lean` | rewritten against the new syntax; `HardenPatch` survives **as an acceptance test**, with two corrections: thread the objections into the revision, and put the check before the revise (§3 q5) | 1,008 |

Approximately **4,700 lines deleted outright**, and every deletion is licensed by a theorem or by a
recorded failed morphism, not by taste.

**Kept as recorded diagnostics, in the new repository's `doc/`, not as code** — they are the evidence
that the rebuild was necessary, and the doctrine says to report them: `peak_not_le_grade`
(`Meaning.lean:1636`), `grade_zero_not_indep` (`:1796`), `one_add_one_of_muS_respects_WEq`
(`:2814`), `muExt_shareT_label_collision` (`:1306`), `muS_dupPair_eq_sharedPair` (`:2769`), and the
`acat-qtv` / `acat-bmc` / `acat-1xo` / `acat-x9v` / `acat-vgz` / `acat-0vv` notes.

### SURVIVE — the mathematics, none of the syntax

| module | what carries over | change |
|---|---|---|
| `Agentic/Semiring.lean` (510) | `CompleteCSemiring`, `csum` + its 12 lemmas, `CsumIsSup`, `StarSemiring`, `KleeneAlgebra.ofSupDistrib` | unchanged; now the theory of the **analysis** carriers rather than of a second meaning |
| `Agentic/Instances.lean` (1397) | `Cost` (max-plus), `Prob` (Viterbi), `Prop` (possibility), `SqZero P M` (expectation), `CompletePMod` | **unchanged**; the four carriers the cost folds evaluate at |
| `Agentic/Matrix.lean` (~680 after trim) | `Mat`, `idMat`, `comp` (Chapman–Kolmogorov), `kron`, `pointMat`, `caseMat`, `matAdd`, `matZero`, `KleeneAlgebra` instance, `powSum`/`sumPow`, `dependentSeq`, and the arbitrary-index `csum` justification | unchanged; the quantitative reading of a `case`/`ask` chain |
| `Agentic/Gate.lean` (206) | `indicator`, `smul`, `gate`, and the annihilation theorems `gate_comp`, `comp_gate`, `zeroMat_comp`, `comp_zeroMat` | unchanged; now the matrix-carrier statement of "a not-taken arm contributes nothing" |
| `Agentic/Star.lean` (~950 after trim) | `retry`, `retry_fixed`, `retry_least`, `reach`, `reach_least`, `CostBounded`, the Prob/Cost/SqZero specializations | **moved to an analysis module**, off the kernel path; needed only when unbounded iteration returns |
| `Agentic/Keys.lean` (344) | `Tally`, `Width`, `Race`, the newtype discipline, `MSemiring` examples | unchanged; the verdict/aggregate monoids. AF §11.4 is right that one monoid per carrier is the discipline the moment two folds over `ℕ` coexist |
| `Agentic/Monoid.lean` (251) | `SupMon`, `PMonoid`/`CMonoid`/`IdemCMonoid`, `actR`, `actL`, `actR_unit`, `actR_compose` | unchanged; `actR_compose` **is** the `under σ` action law |
| `Agentic/Scope.lean` (~180 after trim) | `LastOpt` + `instPMonoid` + `set_overrides` + `unset_defers`; `Scope μ α` product; `innermost_wins`, `outer_survives_silence`, `axis_independence` | kept verbatim — a genuine Mathlib gap. `Scoped`/`withScope` fold into `under` |
| `Agentic/Panel.lean` (~240 after trim) | `MSemiring`, `convOne`, `conv`, `delta`, `conv_delta`, `conv_assoc`, `total`, `total_conv` | kept as the **distribution of a panel's aggregate**, now reachable from a written plan |
| `Agentic/Env.lean` (~90 after trim) | `Env`, `pin`, `pin_same`, `pin_other`, `pin_pin_same`, `pin_get`, `pin_pin_comm` | re-indexed to `Ω = (c:Code) → Q c → El c`; a **two-level dependent** update, so the five laws must be re-derived (half a day — `attack-realizability` §6.7 warns against budgeting zero) |
| `example/HardenPatch.lean` | the **workload**, as the kernel's acceptance test | rewritten; must come out `level = .branch` with an exact cost tree |

Roughly **4,000 lines survive**, essentially all of the mathematics and all of the genuine
derivations: the matrix meaning forced by the failure of pair-of-(kernel, cost), the retry star, the
convolution collapse, the interior operator's theory, `LastOpt`, and `pin`. The contamination was
never in the meanings.

**New code required.** `Plan` + `den` + `run` + `trace` + `under` (~250 lines; `Dlg`'s half is
already compiled). `level`, `indep`, `asks`, `costTree` and their theorems (~400). `exec` +
`adequacy` + `certify` (~200; compiled). An `Expr`/`do`-style surface elaborator (~200–400, and it
is not optional — see §8.6). Total on the order of **1,200–1,500 lines against 4,700 deleted**.

---

## 7. Contamination verdicts inherited from the ledger, resolved

| CL row | verdict | resolution here |
|---|---|---|
| **1.** point-free profunctor spine (`Term` over `Op i o`) | INHERITED | **Killed, but not as CL proposed.** CL's alternative — a free applicative/selective/monad over question *values* `Q α` — makes the domain's dominant pattern monadic and empties the analyzable rungs. The resolution is the third option neither document considered: a first-order syntax **with binders**. Both the arrow's plumbing and the applicative's closed question list are rejected. |
| **2.** label-keyed `shareT` + `Step`/`Site`/`Key`/`Relabels`/`Runner.rename` | INHERITED | **Confirmed kill.** Sharing is a de Bruijn variable used twice. `acat-bmc`, `acat-qtv` and `acat-0vv` all cease to exist rather than being solved. |
| **3.** `Runner` in place of `Env` | INHERITED | **Confirmed kill**, with a correction to CL's replacement: `Ω := (c:Code) → Q c → El c` in `Type 0`, **not** CL's `History → ∀α, Q α → α`, which is `Type 1` with a rank-2 field (so no measure sits on it either — CL reproduces the defect it names) and which threads a history, i.e. re-imports AF's rejected Attempt B tape. |
| **4.** `Frag = ℕ∞` as a type index | INHERITED | **Confirmed kill.** Replaced by `level : Plan → Level`, a **fold**, plus the non-existence theorem C4 — not by a type index of any kind, because Lean refuses to eliminate computed indices (`D_graded_index_fails.lean`). |
| **5.** `fanT n` truncating the meaning | INHERITED | **Confirmed kill**, and the bound is *not* lost: it moves into the answer type (`Σ n ≤ 8, Vec File n`), where the domain already puts it and where nothing truncates. |
| **6.** `WEqR`, the quotient up to relabelling | INHERITED | **Confirmed kill.** Equality is the kernel of `den`; congruence is free; no `Quot`, no `Classical.choice`, and no noncomputable monad. |
| **7.** `scopeT` as a constructor, `Scoped` wrapping every meaning | INHERITED | **Confirmed kill.** `under σ` is a fold and a monoid action; the incumbent's own no-weakening-constructor rule condemned `scopeT` in its own words. |
| **8.** `muExt` into `Option` with left-first and leftmost-defined biases | INHERITED | **Confirmed kill.** No `Option` in the meaning; refusal is an answer; the two contradictory folds collapse to one meaning, so no bias can be silently lost. |
| **9.** `Op : Type → Type → Type`, the arrow-shaped leaf | INHERITED | **Overturned in form, kept in content.** CL is right that the input index is redundant *as an index*; it is wrong that the fix is `Q : Type → Type` as a value, because that is precisely what empties the rungs. The question is a **value built by a pure expression over the context** (`ask : Expr Γ (Q c) → …`), which recovers `i → Q o` without an arrow spine. This is the one ledger verdict this kernel overturns, and `attack-adequacy` §1 is the argument. |
| **10.** `retryT` fuel in the syntax, truncated star as the meaning | INHERITED | **Confirmed kill.** Retry is `Nat.rec` unrolling in the metalanguage; the meaning is the unrolling; the star returns only when unbounded iteration does. |
| honorable: missing `zeroT`, `gateT` standing in | — | `gate` is `case` on a `Bool`; `Gate.lean` survives as the matrix-carrier statement. |
| honorable: missing `panelT` (`acat-x9v`) | — | a panel is independent `ask`s plus a monoid fold; `Panel.lean`'s convolution theorem is reachable from a written plan for the first time. |
| honorable: missing `pinT` (`acat-vgz`) | — | `pin` is `Function.update` on `Ω`; fork, resume and fixture-edit are three uses of one operation. |
| honorable: `Gate`'s `Prop` unreachable behind `gateT : Bool` | — | the tag is decided by pure `Expr`; the undecided `Prop` remains available at the analysis carrier. |

**CL's constructive half (§4) is discarded**, exactly as `attack-simplicity` §5 recommends: it
retains two meanings and a projection π it cannot state, introduces history-indexing (a tape), gives
three fragment-specific meanings so equality is not uniform, and reintroduces `⊥`. CL is
indispensable as a diagnostic and self-refuting as a proposal.

---

## 8. Where each losing option lost, and what genuinely remains open

### 8.1 Losing options, one line each

- **MF's `Dlg` as the artifact** — lost because static cost over a HOAS carrier requires
  `[∀ c, Fintype (El c)]`, which free text does not have, so §8.2's theorem, §8.3's worked number
  and §8.4's budget subtype are unstatable for the domain's own answer type (`G_cost_needs_fintype`).
  `Dlg` is retained as the **meaning**, which is where it is unbeatable.
- **MF's Pipeline-as-a-trace-predicate** — lost to a two-line counterexample (constant trace length,
  world-dependent cost); the syntactic fold classifies that term as `branch` and states a true
  theorem instead.
- **MF's invented "choice-semiring"** — lost to `cost_is_meaning`: one fold at min-plus, max-plus and
  their product gives best, worst and interval with no new carrier.
- **AF's graded inductive `W : Grade → Type → Type`** — lost because Lean refuses to eliminate a
  computed index; the verified repair is grade-as-fold, which is what this kernel uses.
- **AF's `Finset Q` idempotent cost carrier** — lost because it bakes a memoizing runtime into the
  denotation (step 9 violated); carrying the trace and deriving `billFresh`/`billMemo` keeps the
  policy out of the meaning.
- **AF's `∀F ∈ Class(g)` meaning** — lost because AF abandons it at §8.1 for the inductive carrier;
  a meaning that the host cannot use is not the meaning being used.
- **AF's namespace + draw + unspecified gensym** — lost because freshness from nowhere is
  anti-pattern 9; the namespace is an ordinary argument here.
- **DC's weighted meaning `Oracle → V A`** — lost because `Weighting` asserts its laws as class
  fields (anti-pattern 10), `VS S A = A → S` is a schema with an unfilled hole (`PMF` has no
  `Alternative`), `pin` of an individual draw becomes inexpressible (killing replay and fixtures),
  and no transcript survives. Its semirings are retained wholesale as **analysis** carriers, which is
  where they were always doing the work.
- **DC's state-kernel oracle for acting leaves** — lost because it withdraws applicative
  commutativity for *every* leaf, not only acting ones. MF §12 is adopted instead: **a workflow
  decides; it does not act**, and the price of generalizing is printed in advance. Note the
  consolation: because adequacy is proved against a *history-dependent* strategy, an acting agent
  already satisfies the value theorem; what acting costs is the reordering licence and
  replayability, not adequacy.
- **DC's three carriers plus two inclusions** — lost because every library function must pick a
  level and every composition inserts a coercion; one carrier plus a fold is the same content
  without the noise.
- **Free `Selective` as the branching witness** — lost because only the free *rigid* selective is
  known, the general construction is open, the law set is deliberately incomplete, and the reference
  implementation still carries an unproved functor law. `case` is written directly and *identified*
  with `Selective.branch`; the class is recognized, the unlanded dependency is deleted.
- **Point-free arrow spine (the incumbent)** — lost because it has no way to say "use this value
  twice" except by naming nodes, which is `Share Label`, which is the ledger's row 2.
- **Free applicative over question values (CL §4, K2/K3/K4)** — lost because its question list is
  closed before any answer exists, so the domain's dominant pattern is monadic and the analyzable
  rungs are empty.
- **Weighted alternation (`sumT`, `<|>`, beam search)** — lost from the kernel because a plan is
  deterministic given a world; search over plans is a different domain, and adding it would be a
  real extension rather than a derivation. Recorded honestly as the one expressive thing DC has that
  this does not.
- **Unbounded iteration / Elgot** — deferred, with the price printed: coinductive `Dlg`, partial
  `run`, `ℕ∞` costs, four theorems dying together.

### 8.2 Open questions, each with the experiment that settles it

1. **Do the syntactic rungs coincide with the semantic fragments?** Nobody in the dossier proves
   that the static-arrow fragment is exactly the world-independent-shape fragment, or that `case`
   captures exactly finite branching. *Experiment:* prove soundness (`level p ≤ pipeline →` shape is
   world-independent) — expected easy — then search for a completeness counterexample (a term with
   world-independent shape whose `level` is `branch`). Predict soundness holds and completeness
   fails; then state every cost theorem about *terms*, which is what DC's strain note 3 already
   recommends and no other document does.
2. **Does `price` factor through question shape for the real backends?** This hypothesis is the
   difference between C1/C2's exact bill and an interval. *Experiment:* instrument 200 real ACP runs;
   regress observed spend and latency against a shape-only predictor; report the residual. If
   per-token pricing dominates, demote C1/C2 to intervals keyed to a token bound carried in the
   answer type — which is the same repair as §2.5.
3. **Is `askC` worth its redundancy?** The batch rung's only extra guarantee over pipeline is an
   exact bill under content-dependent pricing. *Experiment:* write all six brief workloads and count
   how many `ask` nodes are genuinely closed. If the answer is "one, the first, in every workflow",
   delete `askC`, collapse to three rungs, and the coherence obligation C0 disappears.
4. **Does anyone actually need `dyn`?** *Experiment:* survey `incite`'s existing workflows and count
   those requiring a plan computed from an unbounded answer. If zero, delete `dyn`; the kernel
   becomes total, C4 becomes vacuous, and every plan has a finite cost tree. This is the single
   largest simplification still available.
5. **Is finite-tag `case` enough, or is a dependent (Σ-shaped) branch needed?** AF's open point 5.
   *Experiment:* encode workloads (d) planner-picks-a-sub-workflow and (e) race-with-model-judge with
   dependent answer types and see whether `T : Type` with `Fintype` suffices.
6. **Does the answer-typed width bound burden the author?** *Experiment:* write the N-files review
   workload both ways and count lines and boundary-parser code against the `fanT 8` version. If the
   parser burden is real, consider `Vec File 8 ⊕ TooMany` (one tag) over `Σ n ≤ 8` (nine tags).
7. **The two-level dependent `pin` laws.** `Function.update` and its five Mathlib laws are for one
   level; `Ω` is two levels and dependent. *Experiment:* write them. Half a day; the risk is that
   `pin_pin_comm` needs `DecidableEq (Σ c, Q c)` in a form that is awkward under the dependent index.
8. **The surface elaborator.** Ask-and-bind is already A-normal, so a `do`-like surface should map
   onto `ask`/`case` directly with no dependency analysis — which is *cheaper* than the
   applicative-do that DC and AF both need and neither budgets. *Experiment:* elaborate MF §10's
   twelve-line `hardenPatch` and check that the result reads as well as MF's does. If it does not,
   the kernel has relocated its complexity into its clients and the whole design must be reopened —
   this is the honest failure condition, and it should be tested early.
9. **Measure theory over worlds.** `Ω` is a dependent function space and Mathlib has no measurable
   structure on it. *Experiment:* defer; restrict the distributional layer to `PMF` over countable
   answer types. All four documents rank this last and that ranking is correct.

---

## 9. The four completion tests

1. **Every type has a stated meaning.** Thirteen types, thirteen one-line answers (§1), each an
   *object* rather than a layout, and the one that looks like a syntax (`Dlg`) is derived from the
   observation pair by the Forcing Lemma. ✔
2. **Every operation's meaning is forced.** Five morphism equations for five formers (§2.2), each
   former justified by a morphism equation that cannot otherwise close (§2.3), and twelve deleted
   constructs each with a one-line derived form (§2.4). No operation is named that a standard class
   supplies; where a standard class exists but its free construction does not (`Selective`), the
   class is named and the node is built. ✔
3. **Nothing is left to prove that is not a lemma from the denotation.** `Dlg`'s laws hold
   propositionally with no quotient (compiled). Equality is the kernel of `den`, so congruence is
   free. Commutation at the runtime boundary is `rfl` because the interpreter is the fold. The
   residue is §4's C0–C5 and §5's three theorems, of which the two hardest are already compiled. ✔
4. **Efficiency lives elsewhere.** `run ω` is a valid, slow implementation. Memoization, batching,
   concurrency, session reuse and content-addressing are refinements licensed by theorems about a
   denotation that has not moved — and the one that looked like pure efficiency, memoization, turns
   out to be what makes the adequacy theorem hold against an adversarial agent, which is the method's
   characteristic kind of surprise. ✔

**The three results this kernel would defend hardest.**

1. **`ask : Expr Γ (Q c) → Plan (Γ ▷ El c) A → Plan Γ A`** — the node that keeps content-dependent
   prompts below the monadic rung. Without it, the owner's own example has no static cost in any of
   the four proposals.
2. **The level is a fold, not an index, and it classifies terms, not meanings** — verified against
   the compiler in one direction and against a counterexample in the other.
3. **Cost is an invariant of semantic equality, because the transcript is in the meaning** — which
   makes `acat-qtv`, the two-meaning split, and the missing projection π unstatable rather than
   unsolved.
