# Re-derivation, Algebra First: A Kernel for Agentic Workflows

**Status.** Written under a blinding rule: nothing in `agent-functor`, `incite`, or
`agent-cat` was read before §11. §11 is the single permitted comparison, added after
the derivation was closed. Where §11 reports convergence, the convergence is a
finding, not a justification; every construct in §§1–10 is justified by a morphism
equation or deleted.

**Thesis.** A workflow denotes a polymorphic function from an oracle to an answer;
worlds are *functions*, so sharing and caching are free and unobservable, sampling
is a measure on worlds rather than an effect, and the applicative / selective /
monadic grade is exactly the ladder along which the cost observable degrades from a
point mass to a finite tree to a measure.

---

## 1. The domain, in the domain's own words (Step 1)

> A workflow is a plan for consulting oracles and combining what they say into a
> result.

Everything the domain contains, said without types:

- One consults *models*, *tools*, and *people*. A consultation has an addressee, a
  mode of address, and a body.
- Consultations cost money, tokens, wall-clock, and human attention. One wants to
  know the bill before paying it.
- Some plans are fixed: the consultations they will perform are known in advance.
- Some plans choose between fixed alternatives depending on what came back.
- Some plans compute the next question from the last answer, without bound.
- The same consultation may be wanted twice with the same answer (reuse), or twice
  with different answers (best-of-n).
- A consultation may fail, be refused, or time out.
- Several consultations that do not depend on one another may be run at once.

Two of these sentences carry the whole design. *"One wants to know the bill before
paying it"* is what forces a grading. *"The same consultation may be wanted twice
with the same answer, or twice with different answers"* is what forces the shape of
the world.

## 2. Stripping the incidental (Step 3)

Deleted before any type is written, each because it is a fact about machines or
about a particular runtime rather than about consulting oracles:

| Deleted | Why |
|---|---|
| conversation history, message lists, turn counters | presentation of a prompt, not a prompt |
| tokens, context windows, truncation | pricing and capacity, downstream of meaning |
| concurrency, thread pools, `par`, fan-out width | a schedule, not a plan (§7 q6) |
| caches, cache keys, TTLs, memo tables | an implementation of a function (§7 q1) |
| node identifiers, labels, `share` handles | a representation's way of spelling equality (§7 q2) |
| retry loops, backoff, jitter | a derived form and a runtime policy (§7 q5) |
| streams of samples, RNG seeds threaded through state | a tape (anti-pattern 4); see §9 Attempt B |
| an error monad transformer layer | duplicates branching that `select` already has (§9 Attempt E) |

What survives: questions, answers, combination, and a grade.

## 3. The types and their meanings (Step 2, Step 4)

### 3.1 Questions and answers

```lean
structure Addressee where          -- a model, a tool, a person
  kind : Party
  name : Name

structure Question where
  ns     : Namespace               -- free monoid on names; see §6.3
  who    : Addressee
  mode   : Mode                    -- temperature, system posture, tool permissions
  body   : Prompt
  draw   : Draw                    -- Settled | Nth (n : ℕ); see §7 q1

abbrev Q := Question
variable (R : Q → Type)            -- the answer type a question admits
```

`R` is dependent because the answer type is *determined by* what was asked: a
free-text question admits text, a structured question admits its schema's values, a
yes/no question admits `Bool`. Making `R` dependent is free in Lean and removes an
entire class of "the caller must ensure the schema matches" side conditions
(anti-pattern 9).

**⟦Q⟧ = a point of the question space.** Nothing more. `Q` has decidable equality
and that is the whole of its algebra, plus a monoid action (§6.3).

### 3.2 Worlds

> **⟦World⟧ = `Ω := (q : Q) → R q`.**

A world is a *function*. Not a stream, not a distribution, not a stateful oracle: a
total assignment of one answer to each question. This is the single most consequential
choice in the design, and §9 records the two alternatives that were tried and how
their morphism equations failed.

Consequences, all immediate:

- Asking the same question twice in one world yields the same answer. Always.
- Therefore *sharing is not a construct*; it is a theorem about functions.
- Therefore *caching is not observable*; a cache is a memo table for a function, and
  memoizing a function is the identity transformation.
- Therefore deliberate resampling cannot be "ask again"; it must be "ask a different
  question". The `draw : Draw` field is where that difference lives, and it is in
  the question because *which sample I want* is part of what I am asking for.
- Randomness has left the algebra entirely. A model's stochasticity is a probability
  measure `μ ∈ P(Ω)` on the *index*, not an effect in the workflow. Independence of
  two draws is a property of `μ` (a product structure across distinct `draw`
  coordinates), stated once, in one place, about one object.

The kernel is therefore *cartesian*: every value is copyable and discardable, the
copy-discipline obligations of a CD- or Markov-category are discharged trivially, and
the Markov machinery is not needed. §5.4 states the theorem that recovers the
stochastic reading as a pushforward, so nothing is lost.

### 3.3 Grades

```lean
inductive Grade | ap | sel | mon
-- a three-element chain, ap ≤ sel ≤ mon, with join ⊔
```

`Grade` is a bounded join-semilattice. It is *computed* by the operations, never
declared by the user (§4). It exists for exactly one reason: it is the coordinate
along which the cost observable degrades (§5).

### 3.4 The workflow type — the meaning

> **⟦W g A⟧ = `∀ F ∈ Class(g), ((q : Q) → F (R q)) → F A`, natural in `F`**

where `Class(ap) = Applicative`, `Class(sel) = Selective` (Mokhov, Mokhov, Lukyanov,
Marlow & Dimino, *Selective Applicative Functors*, ICFP 2019), `Class(mon) = Monad`,
and the quantifier ranges over *lawful* members of the class with lawful morphisms
between them.

Read it in English: **a workflow is a recipe that, given any way of answering
questions, answers the whole question.** The oracle argument `(q : Q) → F (R q)` is
the "way of answering". The polymorphism is the content: a workflow may not inspect
the answering mechanism, may not depend on how many times it is run, may not depend
on anything but the class laws. Naturality in `F` is what says a workflow is a
*plan*, not a *program about programs*.

This meaning is uncomputable (it quantifies over a proper class of functors) and is
meant to be. It is the specification. §8 gives the Lean-side carrier that realizes it.

Three instantiations of `F` are the working semantics, and all three are folds of the
same object:

| `F` | class needed | what it computes | §  |
|---|---|---|---|
| `Id` | Applicative | the **outcome**: `Ω → A` | 5.1 |
| `Const S` | Applicative | the **exact bill** | 5.2 |
| `Over S` / `Under S` | Selective | **bill bounds** | 5.3 |
| `Writer C ∘ Id` | Monad | **per-world bill** | 5.3 |
| `Giry` | Monad | the **law of the outcome** | 5.4 |
| `IO` | Monad | the **live run** | 5.5 |

That one object supports all six is the entire payoff of choosing a free structure:
"the laws come already paid for", and so does every homomorphic observable one will
ever want.

## 4. The generating algebra (Step 6)

Five generators. Three are standard class methods, one is the single effect, one is
forced by the grading.

```lean
inductive W : Grade → Type → Type where
  | pure   : A → W .ap A
  | ask    : (q : Q) → W .ap (R q)
  | ap     : W g (A → B) → W g' A                → W (g ⊔ g') B
  | select : W g (A ⊕ B) → W g' (A → B)          → W (g ⊔ g' ⊔ .sel) B
  | bind   : W g A → (A → W g' B)                → W .mon B
```

Nothing else. No `retry`, `fan`, `gate`, `scope`, `share`, `choice`, `panel`,
`parallel`, `human`, `fail`, `catch`, `cache`, `fresh`. Each is discharged in §6 or
deleted in §7.

### 4.1 Morphism equations (Step 7 — these *are* the specification)

Write `⟦w⟧_F h` for the meaning at functor `F` and oracle `h`. Then:

```
⟦pure a⟧_F h            =  pure a
⟦ask q⟧_F h             =  h q
⟦ap wf wx⟧_F h          =  ⟦wf⟧_F h  <*>  ⟦wx⟧_F h
⟦select wc wf⟧_F h      =  select (⟦wc⟧_F h) (⟦wf⟧_F h)
⟦bind w k⟧_F h          =  ⟦w⟧_F h  >>=  fun a => ⟦k a⟧_F h
```

Five equations. Each is literally the Kernel's "Applicative / Monad" row with the
reader's argument threaded, and the reader threading is itself the Reader-applicative
morphism. Nothing is invented; nothing is asserted; the class laws for `W` are
inherited from the class laws for `F` because `⟦·⟧` is a homomorphism into every
lawful `F` at once. This is Step 6's "`A → B` ⇒ reader Functor/Applicative/Monad plus
everything `B` inhabits, transported pointwise" applied twice: once for the oracle
argument, once for `F`.

`Functor` is not a generator: `fmap f w = ap (pure f) w`, and `⟦fmap f w⟧_F h =
pure f <*> ⟦w⟧_F h = fmap f (⟦w⟧_F h)`, the required natural transformation.

### 4.2 Why three sequencing generators and not one

At the level of the **outcome** semantics (`F := Id`), `ap` and `select` are
definable from `bind`:

```
ap wf wx     ≡ bind wf (fun f => fmap f wx)
select wc wf ≡ bind wc (Sum.elim (fun a => fmap (· a) wf) pure)
```

and these equations *hold* — see the coherence theorem below. So the value semantics
does **not** justify three generators. The cost semantics does, and this is exactly
the Kernel's standard for admitting a primitive: *a morphism equation that cannot
otherwise close.*

> **Justification of `ap` as a generator.** `Const S` is an Applicative for any
> monoid `S` and is **not** a Monad. Therefore `⟦·⟧_{Const S}` exists on `W .ap`
> and does not exist on `W .mon`. If `ap` were sugar for `bind`, every applicative
> workflow would have grade `mon` and the exact-bill homomorphism (§5.2) would have
> no domain. The equation `⟦ap wf wx⟧_{Const S} h = ⟦wf⟧ h <> ⟦wx⟧ h` cannot be
> obtained through `bind`.

> **Justification of `select` as a generator.** `Over S` and `Under S` are Selective
> and not Monads. The finite-tree cost homomorphism (§5.3) is a fold over the
> `select` nodes; a `bind` node's continuation is a *function of the answer*, so no
> finite tree exists for it. The equation `⟦select wc wf⟧_{Over S} h = ⟦wc⟧ h <>
> ⟦wf⟧ h` cannot be obtained through `bind`.

> **Justification of `bind` as a generator.** It is not definable from `select`: `select`
> chooses among alternatives *present in the term*, `bind` computes an alternative
> *from the answer*. Mokhov's own separating example (a continuation whose shape
> depends on an unbounded value) applies verbatim.

> **`ask` is the only effect.** There is one consultation effect. Humans, tools and
> models differ only in `Addressee` (§7 q7); failure differs only in `R q` (§7 q8);
> scoping differs only by a monoid action on `Q` (§6.3).

**Coherence theorem (grade coercion is meaning-preserving).** Let `ι : W g A → W g' A`
for `g ≤ g'` be the evident inclusion (rewriting `ap`/`select` into `bind` as above).
Then `⟦ι w⟧_Id h = ⟦w⟧_Id h` for every world `h`. *Only the cost observable is
refined by lowering the grade; the answer never changes.* This is the theorem that
makes the grading safe to ignore when one does not care about cost, and it is a
proof obligation, not a convention.

## 5. The cost observables, and the graded factorization theorem (the owner's requirement)

### 5.1 Outcome

Take `F := Id`, which is a lawful Monad. An oracle at `Id` is exactly a world
`ω : (q : Q) → R q`. Hence

> **⟦w⟧ : Ω → A**, the *outcome semantics*, defined for every grade.

Everything pointwise for free (Step 6, reader row). `W .mon` is a monad, `W .sel` a
selective functor, `W .ap` an applicative, and all their laws hold by morphism.

### 5.2 The cost carrier

The naive choice `Cost = (ℕ, +)` fails; §9 Attempt D records how. The choice that
closes is:

```lean
abbrev S := Finset Q                 -- free join-semilattice on Q
-- (∪, ∅): idempotent, commutative monoid
```

> **⟦cost⟧ = the finite set of questions consulted.**

Idempotence is not an accident to be tolerated; it is the *statement* that a correct
runtime consults each distinct question once. `w *> w` costs what `w` costs, which is
true precisely because worlds are functions. The numeric bill is a derived observable
on the carrier, not a homomorphism out of it:

```lean
def bill (price : Q → C) (s : S) : C := s.sum price     -- C an ordered commutative monoid
```

`C` is a product of coordinates, one per resource: `C = Money × Tokens × Seconds ×
HumanMinutes`. The addressee's `Party` decides which coordinates a question loads;
that is the *whole* content of "human-in-the-loop costs differently" (§7 q7).

### 5.3 The three levels

**Level `ap` — exact, a value.**

`Const S` is Applicative because `S` is a monoid. Instantiate:

```
asks : W .ap A → S
asks = ⟦·⟧_{Const S} (fun q => Const {q})

asks (pure a)      = ∅
asks (ask q)       = {q}
asks (ap wf wx)    = asks wf ∪ asks wx
```

> **Theorem (Exact cost).** For all `w : W .ap A` and all worlds `ω`,
> `consulted(w, ω) = asks w`. In particular the bill is independent of `ω`, known
> before any consultation, and `asks` is a monoid homomorphism.

This is the mathematical reason the applicative level is the level of exact static
cost: *the cost functor `Const S` exists exactly at the applicative level and no
higher.*

**Level `sel` — a finite tree, plus tight bounds.**

`Over S` (`select (Over x) (Over y) = Over (x <> y)`) and `Under S` (`select (Under x)
_ = Under x`) are Selective and not Monads. Instantiate both:

```
asksOver, asksUnder : W .sel A → S
```

> **Theorem (Selective bounds, tight).** For all `w : W .sel A` and all worlds `ω`,
> `asksUnder w ⊆ consulted(w, ω) ⊆ asksOver w`; and both inclusions are attained —
> there exist worlds `ω⁻, ω⁺` realizing each. Consequently
> `bill (asksUnder w) ≤ bill(consulted(w,ω)) ≤ bill (asksOver w)`
> with the two ends being the folds into the tropical semirings `(min, +)` and
> `(max, +)` (Step 6, "an interval or bound ⇒ a product of tropical semirings").

The exact structure, not merely the bounds:

```lean
inductive CostTree | leaf : S → CostTree | branch : S → CostTree → CostTree → CostTree

costTree : W .sel A → CostTree
```

> **Theorem (Finite tree).** `costTree w` is finite, computable from `w` alone, and
> `consulted(w, ω) = path (costTree w) (decisions w ω)`, where `decisions w ω`
> is the finite list of `Sum.inl`/`Sum.inr` outcomes at the `select` nodes. The tree
> has at most `2^d` leaves for `d` the number of `select` nodes, and `d` is a
> structural measure of the term.

This is the level the owner's phrase "a tree structure" names, and the derivation
places it one notch *below* full monad — a divergence from the directive's literal
wording that the mathematics forces and that strictly improves the result: branching
on answers does **not** require `bind`, and a great deal of real branching (retry,
fallback, validate-then-repair, guardrails) is selective, hence still statically
analyzable to a finite tree.

**Level `mon` — a measure, and three residues.**

At `bind`, no static tree exists: the continuation is a function of an answer drawn
from a possibly infinite `R q`. What remains:

1. `asks : W .mon A → (Ω → S)`. Still a homomorphism, now into the reader.
2. **Finite observation lemma.** For every `w` and `ω`, `asks w ω` is finite and
   `⟦w⟧ ω` depends on `ω` only through its restriction to `asks w ω`. Formally, `⟦w⟧`
   is continuous for the Scott topology on `Ω = Π_q R q` with `R q` discrete. This
   is the lemma that makes replay, transcript-based proof (§8.3), and caching sound
   at *every* grade.
3. If every `R q` is finite, `costTree` still exists with branching factor `|R q|`;
   it is a bound of size, not a refusal.

### 5.4 The unifying statement: cost is an element of a monoid semiring

Let `C` be the numeric cost monoid and let `μ ∈ P(Ω)` be the law of the oracle. The
bill is a random variable `bill_w : Ω → C`, and its law is an element of the **monoid
semiring**

```
ℝ≥0[C]  =  finitely-supported (or measure-valued) functions C → ℝ≥0
```

whose multiplication *is* convolution *is* `liftA2 (+)` on the index monoid — exactly
the Kernel's "monoid-indexed semiring-valued function" row.

> **Theorem (Graded cost factorization — the owner's requirement, in one object).**
> For every workflow `w`, `law(bill_w) ∈ ℝ≥0[C]`, and the grade bounds its support:
>
> | grade | support of `law(bill_w)` | statically computable? |
> |---|---|---|
> | `ap` | a single atom (Dirac at `bill (asks w)`) | yes, exactly |
> | `sel` | finite, ≤ #leaves(`costTree w`), atoms enumerable from the term | yes, exactly, as a tree |
> | `mon` | arbitrary; bounded only under finiteness of `R` | no; bounds and expectations only |
>
> Moreover, when `w₁` and `w₂` consult disjoint question sets and `μ` makes their
> coordinates independent,
> `law(bill (w₁ *> w₂)) = law(bill w₁) ⊛ law(bill w₂)` (convolution),
> and for unbounded retry (§6.2) `law(bill (retry^ω w)) = (law(bill w))^*` in the
> star semiring, `x^* = 1 + x ⊛ x^*`.

Three sentences of the owner's directive — *exact value at the static level, finite
tree where branching is visible, what remains at full monad* — are one theorem about
the support of one measure. The three cost analyses are not three algorithms; they
are one homomorphism into `ℝ≥0[C]` whose image happens to be a point, a finite
combination, or a general measure.

**Randomization lemma (recovers the stochastic reading).** For `w : W .mon A` and
`μ ∈ P(Ω)`, `⟦w⟧_{Giry} (fun q => marginal μ q) = μ ⤍ ⟦w⟧_Id` **iff** `μ` is a
product measure across the coordinates `w` consults. This is the exact price of
moving randomness out of the algebra, and it is the one place where the choice is
visible: correlated oracles (a model whose answer to `q₂` depends on having been
asked `q₁`) are representable as a non-product `μ` in the world semantics, and are
*not* representable by a Giry-valued oracle. The world semantics is therefore
strictly more expressive, which is an argument in its favour.

### 5.5 Parallelism

There is no `par`. There is no operator to derive. The semantic fact is
*independence*, which is exactly the grade-`ap` shape: `ap wf wx` has no data
dependence between `wf` and `wx`, and the applicative laws license any schedule.
Whether a runtime exploits it is a runtime fact.

> **Theorem (Schedule independence).** For `w : W .ap A`, every evaluation order of
> the `ask` nodes yields the same `⟦w⟧ ω` and the same `asks w`.

That theorem is the licence, and it is the *only* thing "parallel" could have meant
in the meaning.

## 6. Every named constructor, discharged (Step 6: "delete custom vocabulary")

### 6.1 `fan` / `panel` / `consensus`

```lean
def panel [Monoid V] (qs : List Q) (judge : (q : Q) → R q → V) : W .ap V :=
  qs.foldMapA (fun q => judge q <$> ask q)      -- traverse + monoid
```

It is `foldMapA`. The "verdict monoid" enters as the `Monoid V` constraint and
nowhere else. A general reducer (majority, argmax, weighted vote) is a
`Monoid`/`Semigroup` on `V` or, when it is genuinely not associative, a plain
`List V → V` applied after `traverse`; in the latter case it is not part of the
algebra at all, it is a pure function.

Morphism equation, discharged: `⟦panel qs judge⟧_F h = foldMapA (fun q => judge q <$>
h q) qs`, which is `traverse`'s own morphism law. **Not primitive.**

### 6.2 `retry`, bounded iteration

```lean
def retry : (n : ℕ) → W g (E ⊕ A) → W g' (E → A) → W _ A
  | 0,     w, fallback => select w fallback
  | n+1,   w, fallback => select w (fun _ => retry n w fallback)   -- schematically
```

Bounded retry is *n-fold `select`*: grade `sel`, `costTree` a path of length ≤ n,
bounds `bill(w) ≤ · ≤ (n+1)·bill(w)`. It is derived, and its cost theorem is a
corollary of §5.3, not a separate analysis. Unbounded retry needs a fixpoint; it is
grade `mon` (or grade `sel` with an infinite tree), and §5.4's star-semiring line is
its cost law. **Not primitive**, at either level.

Note that this reproduces the Kernel's own worked example ("retrofitting a retry
policy") and lands where that example lands: a policy is a value, not a control
construct.

### 6.3 `scope`, and the same mechanism as `fresh`

`Q` carries a `ns : Namespace` from the free monoid on names, and namespaces act:

```lean
instance : MulAction Namespace Q where smul s q := { q with ns := s ++ q.ns }

def under (s : Namespace) (w : W g A) : W g A := ...   -- relabel every ask
```

> **Morphism equation.** `⟦under s w⟧_F h = ⟦w⟧_F (h ∘ (s • ·))`.

That is `local`. `under` is the reader's `local` and nothing else; its laws
(`under 1 = id`, `under (s*t) = under s ∘ under t`, `under s (pure a) = pure a`,
`under s` commutes with `ap`/`select`/`bind`) are the monoid-action laws, transported
for free. It is *definable* as the fold that relabels `ask`, so it is not a
generator; it is a natural transformation `W ⇒ W`.

Two things collapse onto it, which is the argument that it is the right mechanism:

- **Scoping "which model, which mode"** — override components of `who`/`mode`
  throughout a subtree. Same action, on a different component of `Q`. (Alternatively,
  and equivalently, just build the right `Q`: scoping is a convenience over
  *questions*, never a separate semantic layer. Neither reading needs a primitive.)
- **Hygiene for resampling** — a library that does best-of-3 internally, invoked
  twice, must not reuse the same three draws. `under (fresh-name) w` shifts the whole
  subtree into a new namespace, making its questions distinct. This is not a
  workaround: it is the statement that "the third independent draw" is only meaningful
  relative to a naming context, which is *true of the domain*.

So `scope`, `fresh`, `local`, and namespace hygiene are one derived operator with one
morphism equation. **Not primitive.**

### 6.4 `gate`, `choice`, `when`, `unless`, `ifS`

All are Mokhov's derived selective combinators, verbatim:

```
branch  c l r = select (fmap (fmap Left) c) ... -- standard
ifS     c t e = branch (bool (Right ()) (Left ()) <$> c) (const <$> t) (const <$> e)
whenS   c a   = ifS c a (pure ())
fromMaybeS, orElse, anyS, allS ...
```

Each arrives with its laws and its `Over`/`Under` cost behaviour already established
in the literature. **Not primitive.** Naming any of them as a kernel construct
forfeits exactly what anti-pattern 8 says it forfeits.

### 6.5 `share`

**Deleted.** Its morphism equation cannot even be written. A candidate `share : W A →
W (W A)` would need `⟦share w⟧_F h = ?`, and there is no operation on `(q : Q) → F (R q)
→ F A` that "makes a value shared" — because in a world that is a function, every
value already is. This is the Kernel's fourth diagnostic row ("a whole class that
cannot be instantiated at all → the representation is wrong for that job") applied in
reverse: the class cannot be instantiated because the construct is empty.

Operationally, "don't pay twice" is §5.2's idempotence, and "don't *compute* twice" is
memoization of a function — an optimization with a one-line correctness proof and no
semantic content. This is the largest single deletion the derivation makes.

### 6.6 `cache`, `memo`, `deterministic`

**Deleted**, by the same argument. See §7 q1.

### 6.7 `human`, `askHuman`, `approval`

**Deleted.** `ask { who := ⟨Person, "john"⟩, .. }`. See §7 q7.

### 6.8 `fail`, `catch`, `orElse`, `timeout`

**Deleted as constructs.** `R q` is a sum containing refusal/timeout/malformed;
branching on it is `select`. See §7 q8 and §9 Attempt E.

**Score.** Of the constructors the brief names — `retry`, `fan`, `gate`, `scope`,
`share`, `choice` — five are derived forms with discharged morphism equations and one
(`share`) is empty. None survives as a primitive. The generating algebra is `pure`,
`ask`, `ap`, `select`, `bind`, and of those, four are standard class methods.

## 7. The ten questions, answered

### q1 — Same answer or independent samples? Resampling? What does caching MEAN?

**Same answer.** A world is a function `(q : Q) → R q`, so `ask q` denotes the same
value everywhere it occurs, in every world, at every grade. This is not a policy; it
is the type of `Ω`.

**Deliberate resampling is a different question, not a repeated one.** `Draw` is a
field of `Q`. Best-of-n on one prompt:

```lean
def bestOf (n : ℕ) (q : Q) (score : R q → ℝ) : W .ap (R q) :=
  argmax score <$> (List.range n).traverse (fun i => ask { q with draw := .Nth i })
```

grade `ap` (no branching), `asks = { q with draw := .Nth i | i < n }`, exact bill
`n · price q`, and independence of the n answers is a property of `μ` (a product
measure across the `draw` coordinate), stated once about `μ` rather than n times
about the workflow. Hygiene across call sites is §6.3's `under`.

**Caching means nothing.** It is not an operation, not a mode, not a policy, and not
a semantic distinction. A cache is a memo table for the function `ω`, and the
correctness statement is `memo ω = ω`. Every question about cache scope, invalidation,
and key equality reduces to: *what is the identity criterion on `Q`* — which is
decidable equality on a record. The dilemma "cached or fresh?" is dissolved rather
than resolved (Kernel: "several of the corpus's cleanest results come from removing
the dilemma rather than choosing between the two").

The residual honest cost: a *live* model is not a function, and two consultations
with an identical `Q` at different wall-clock times may differ. The model's answer is
that such an oracle is not consulting the same question — time, if it matters, is a
component of `Q` (`mode` or `ns`); if it is not a component of `Q`, one has *asserted*
that it does not matter, and the assertion is visible in the type. That is the right
place for it to be visible.

### q2 — What IS sharing? Labels or structural?

**Neither labels nor binding structure: sharing is free.** `⟦ask q⟧ ω = ω q`
independently of where the occurrence sits, so two occurrences of the same question
denote the same value *by referential transparency of the meaning*. There is nothing
to name, nothing to bind, nothing to plumb.

Sharing among several consumers is therefore ordinary value-level sharing in the host
language: `let a ← ask q; pure (f a, g a)` and `(f <$> ask q, g <$> ask q)` are equal
at `Id`, and equal in `asks` (by idempotence of `∪`). That equality is a *theorem*:

> **Sharing theorem.** For `f, g` pure, `(fun a => (f a, g a)) <$> ask q  ≡
> (·,·) <$> (f <$> ask q) <*> (g <$> ask q)` at every `F` — where the right side has
> grade `ap` and the left has grade `ap`, and both have `asks = {q}`.

A design in which this theorem is false has put something into the meaning that the
domain does not contain. Note the contrapositive: any design that needs `share`
handles or node labels has a world that is not a function, and §9 records what that
costs.

### q3 — Scoping: primitive, index transformation, or part of the question?

**Part of the question; and the operator that manipulates it in bulk is an index
transformation, namely a monoid action, namely `local`.** Both halves of the
disjunction are true and they are the same thing (§6.3). Not primitive. The morphism
equation `⟦under s w⟧_F h = ⟦w⟧_F (h ∘ (s • ·))` closes, and the action laws give the
operator's laws for free.

### q4 — Which standard structures carry the hierarchy, and how does cost factor?

`Applicative` / `Selective` (Mokhov et al. 2019) / `Monad`, as a three-element graded
family with meaning-preserving coercions (§4.2 coherence theorem), realized as a
free (quotiented) structure over the single effect `ask` so that every observable is
a fold (§8).

Cost factors as §5.4: one homomorphism into the monoid semiring `ℝ≥0[C]`, whose
support is a point at `ap`, finite and tree-enumerable at `sel`, arbitrary at `mon`.
The reason each level behaves as it does is structural and not empirical: `Const S` is
Applicative-not-Monad; `Over S`/`Under S` are Selective-not-Monad; at `mon` no
`Const`-like functor exists because `bind`'s continuation must consume an answer.

The refinement of the owner's directive: **branching on answers does not require
monad.** The genuinely monadic residue is narrower than it looks — it is *computing a
new question from an answer*, not *choosing among known alternatives*. Most workflow
branching is the latter, and the derivation buys it a finite static tree.

### q5 — Retry: denotational meaning, primitive or derived?

**Derived** (§6.2). Bounded retry is n-fold `select`, hence grade `sel`, hence a
path-shaped `costTree` and tight tropical bounds. Unbounded retry is a fixpoint, hence
grade `mon`, and its cost law is the Kleene star in `ℝ≥0[C]` (§5.4). Denotationally,
`retry n w fallback` means: the first component of the sequence
`w, w, …` (n+1 terms, at namespaces distinguished by `under` if independent attempts
are intended) whose answer is `inr`, else `fallback` of the last `inl`. That is a
statement about a finite list, not a control construct.

### q6 — Panels: what structure, where does the verdict monoid enter, is parallel semantic?

Structure: `traverse` (§6.1). Verdict monoid: as the `Monoid V` of `foldMapA`, at the
combining step only. **Parallel is a runtime fact.** The semantic fact is grade `ap`,
i.e. absence of data dependence, and §5.5's schedule-independence theorem is exactly
the licence a scheduler needs. No `par`, no width parameter, no fan operator.

### q7 — Human-in-the-loop: distinct construct or same effect?

**Same effect, different addressee.** `Addressee.kind : Party` with
`Party = Model | Tool | Person`. Nothing in the algebra changes. Two real differences
exist and both land where they belong:

- *Cost*: `price q` loads the `HumanMinutes` coordinate of `C`. A cost coordinate, not
  a construct.
- *Resampling*: asking a person the "second independent draw" of a question is
  possible but rude and slow. That is again `price`, monotone in `draw`.

The test for whether it should be a distinct construct is whether some morphism
equation fails without one. None does. Therefore it is not one.

### q8 — Failure/partiality: where does "no outcome" live?

**In the answer.** `R q` is a sum: `R q = Refusal ⊕ Timeout ⊕ Malformed ⊕ Good q`.
Branching on it is `select`, which is why failure handling is *the* paradigmatic
selective-grade phenomenon and remains statically cost-analyzable. `⟦·⟧` stays total;
`Ω` stays a total function; no `⊥` enters the meaning.

Workflow-level abort is `pure (inl e)` and short-circuit is `select`, i.e. it is data.
§9 Attempt E records why a separate error layer was rejected: it duplicates the
branching that `select` already carries, and it silently promotes every fallible
applicative workflow to a grade at which the exact-cost theorem is false.

The one thing genuinely outside: a runtime that never returns. That is not partiality
of the meaning, it is failure of §8.3's adequacy hypothesis, and it belongs there.

### q9 — What makes equality semantic?

**Lawful-by-construction: a quotiented-free carrier, with equality defined as
indistinguishability by every lawful interpretation.**

```
w₁ ≡ w₂   ⟺   ∀ F ∈ Class(g), ∀ h, ⟦w₁⟧_F h = ⟦w₂⟧_F h
```

Three facts make this the right choice rather than a dodge:

1. It is *semantic*: it quantifies over meanings, not over syntax.
2. It coincides with free-modulo-the-class-laws. The free applicative/selective/monad
   on a signature has normal forms (a vector of asks with a pure combiner; a finite
   tree; a tree), and two terms are equal in the free structure iff they agree under
   every lawful interpretation. So the quotient is *decidable on normal forms* even
   though the defining quantifier is not.
3. It is strictly finer than any single instantiation, and deliberately so. `⟦·⟧_Id`
   alone is not injective (it forgets cost); `asks` alone is not injective (it forgets
   the answer). The polymorphic meaning is the conjunction, and it is exactly right:
   two workflows are the same workflow iff they give the same answer *and* cost the
   same *and* do so for the same reason.

This is the Kernel's "define equality semantically" plus its "free structures make the
meaning function the unique homomorphism" in one move, and it is what makes §8.3's
adherence theorem provable rather than merely plausible.

### q10 — What must the runtime-adherence theorem SAY?

Two parts, and it matters enormously which is which.

**Part A — commutation, which is free.** Define the interpreter as the fold:

```lean
def run [Monad m] (query : (q : Q) → m (R q)) : W g A → m A := ⟦·⟧_m query
```

Then "each operation commutes with the denotation" is *true by construction*:

```
run query (pure a)      = pure a
run query (ask q)       = query q
run query (ap wf wx)    = run query wf <*> run query wx
run query (select c f)  = select (run query c) (run query f)
run query (bind w k)    = run query w >>= (run query ∘ k)
```

These are `rfl` in Lean, because `run` *is* `⟦·⟧` at `m`. Writing the interpreter as
anything other than the fold is what makes this theorem hard, and there is no reason
to. This is the Kernel's "the laws come already paid for" cashed at the runtime
boundary. It is worth being blunt that a large fraction of what such a project would
otherwise spend proof effort on evaporates here.

**Part B — adequacy, which must be proved, and one axiom, which must be stated.**
The live agent process is not a world. Relate them through the transcript.

Let an execution of `run query w` in `IO` produce a value `a` and a transcript
`τ : List (Σ q, R q)` of the consultations actually performed and the replies actually
received. Define the *induced partial world* `ω̂_τ : (q : Q) ⇀ R q`.

> **Adequacy theorem (the runtime-adherence theorem).** For every `w : W g A` and
> every terminating execution of `run query w` yielding `(a, τ)`:
> 1. **Functionality.** `τ` contains no two entries with equal `q` and different
>    replies. (`query` must be memoizing; this is the *only* obligation a cache
>    carries, and it is an obligation of *soundness*, not of performance.)
> 2. **Coverage.** `dom(ω̂_τ) = asks w ω` for every total extension `ω ⊇ ω̂_τ`.
> 3. **Value.** For every total extension `ω ⊇ ω̂_τ`, `⟦w⟧_Id ω = a`.
> 4. **Bill.** `bill (dom ω̂_τ) = bill (asks w ω)`, and at grade `ap` this equals the
>    statically computed `bill (asks w)`; at grade `sel` it lies in
>    `[bill (asksUnder w), bill (asksOver w)]`.
>
> In one sentence: **a run exhibits a world, and the value returned is the meaning of
> the workflow at that world.**

Clause 3 is well-posed only because of the finite-observation lemma (§5.3.2), which is
therefore load-bearing and must be proved first. Clauses 1–4 go by structural induction
on `w`, with an operational semantics for `IO` given as a state transformer over
`(τ, external)`.

> **Axiom (Oracle fidelity).** The external process, viewed as a source of replies,
> has law `μ ∈ P(Ω)`; distinct `draw` coordinates are `μ`-independent.

This axiom cannot be proved and must not be hidden. It is the entire empirical content
of the model, it is stated once, and it is exactly what §5.4's distributional results
are conditioned on. Everything else in the system is a theorem. Reporting it plainly
is the Kernel's "report the failures that resist repair."

## 8. Realization in Lean 4

### 8.1 Carrier

Take `W` as the inductive family of §4 (initial), *not* the `∀F` type (final). Reasons:
Lean has no parametricity theorem, so the final encoding's laws would need axioms;
and the inductive form is what `costTree` and `asks` pattern-match on. Then:

- Define `⟦·⟧_F : W g A → ((q:Q) → F (R q)) → F A` by structural recursion — this is
  §4.1, definitionally.
- Define `≈` as §7 q9's quantified equality, and prove it is an equivalence and a
  congruence for all five generators. The congruence proofs are one line each,
  because `⟦·⟧` is a fold.
- Provide `Applicative (Quotient ≈ ∘ W .ap)`, `Monad (Quotient ≈ ∘ W .mon)` etc., and
  discharge the class laws by `⟦·⟧`-injectivity on the quotient — i.e. **by morphism,
  never by per-constructor case analysis.**

The normal-form theorem (free applicative ≅ `Σ n, Vec Q n × (Π i, R (qs i)) → A`;
free selective ≅ finite decision tree) is worth proving because it makes `≈`
decidable on closed terms and gives `costTree` its finiteness bound for free.

### 8.2 Grade inference

`Grade` is inferred, not annotated: `ap`/`select`/`bind` compute `g ⊔ g'` (and join in
`sel`/`mon` respectively). A user writes `do`-notation and gets grade `mon`; writing
`<*>`/`ifS` gets `ap`/`sel`. Provide `Grade`-polymorphic combinators so that library
code does not force grades it does not need. The one discipline the design asks of a
user is: *reach for `<*>` and `ifS` before `>>=`*, and the reward is stated in §5.

### 8.3 Proof obligation ledger

| # | Obligation | Difficulty |
|---|---|---|
| 1 | `⟦·⟧_F` is a class morphism at each `F` | `rfl` (definitional) |
| 2 | `≈` is a congruence; class laws for `W` | easy, by 1 |
| 3 | Coherence: `⟦ι w⟧_Id = ⟦w⟧_Id` (§4.2) | easy induction |
| 4 | Exact cost at `ap` (§5.3) | easy induction |
| 5 | Selective bounds tight (§5.3), with attaining worlds | moderate; construct `ω⁻, ω⁺` |
| 6 | Finite observation lemma (§5.3.2) | moderate; needed by 8 |
| 7 | Normal forms for `W .ap`, `W .sel`; decidability of `≈` | moderate |
| 8 | Adequacy (§7 q10 Part B, clauses 1–4) | the main theorem |
| 9 | Randomization lemma (§5.4) | needs a measure-theory layer; optional |
| 10 | Convolution/star laws for `law(bill)` (§5.4) | needs 9 |

Obligations 1–4 and 8 are the kernel. 9–10 are the quantitative theory and can be
deferred without weakening anything above them.

## 9. Failed morphisms, recorded (the method's most valuable output)

**Attempt A — `⟦W A⟧ = P(A)`, a probability distribution.**
The applicative morphism `⟦f <*> x⟧ = ⟦f⟧ <*> ⟦x⟧` forces the product (independent)
coupling, so `⟦ask q *> ask q⟧` is a product of two independent draws — which is right
for resampling and *wrong* for reuse, with no way to say which is meant. Adding a
`share`/label mechanism to distinguish them then makes `⟦·⟧` non-compositional, since
the meaning of a subterm would depend on labels bound outside it.
*Diagnostic:* the equation requires an argument that is not available → the
specification is not compositional. *Repair chosen:* move randomness out of the
algebra; make the world a function; put the reuse/resample distinction in `Q`.

**Attempt B — `⟦W A⟧ = Σ → A × Σ`, a world as a consumable stream of samples per question.**
Sharing and resampling are distinguished correctly. But `⟦f <*> x⟧ = ⟦f⟧ <*> ⟦x⟧` now
threads `Σ` left-to-right, so `<*>` acquires an order; `traverse` (panels) acquires an
order the domain does not have; and §5.5's schedule-independence theorem becomes
false, taking parallelism with it.
*Diagnostic:* an ordering silently gained — a tape has entered the model
(anti-pattern 4 and 6). *Repair chosen:* same as A. The stream index becomes the
`draw` field, moving a piece of state into the question where it is inert.

**Attempt C — `share : W A → W (W A)` as a primitive.**
No morphism equation can be written at all: given `⟦w⟧_F : ((q:Q) → F (R q)) → F A`,
there is no candidate right-hand side. *Diagnostic:* a whole class that cannot be
instantiated → the construct is empty, because worlds are already functions.
*Repair:* delete (§6.5).

**Attempt D — `Cost = (ℕ, +)` with `cost (ap wf wx) = cost wf + cost wx`.**
The morphism is well-defined, but the adequacy theorem then fails: a memoizing runtime
consults `w *> w`'s questions once and the predicted bill is double the real one. One
can either forbid memoization (giving up §7 q1's whole result) or change the carrier.
*Diagnostic:* the element type of the model is wrong. *Repair:* `S = Finset Q`, the
free *idempotent* commutative monoid, with `bill` a derived function on the target
rather than a homomorphism out of it (§5.2). The idempotence is not slack; it is the
statement of the sharing theorem in the cost algebra.

**Attempt E — failure as an `ExceptT`-style layer over `W`.**
`⟦·⟧` still closes, but `Except` short-circuits, so the number of questions consulted
depends on the answers even at grade `ap`, and the exact-cost theorem (§5.3) becomes
false for every fallible workflow — i.e. for every real workflow. One would have to
promote all of them to grade `mon` and abandon static costing entirely.
*Diagnostic:* the model is a functor composition that has not been factored — the
branch structure `Except` carries is the branch structure `select` already carries.
*Repair:* factor it out; failure is a value in `R q` and its branch is a `select`
node, visible in `costTree` (§7 q8).

**Unrepaired, and reported as such.** A live model is not a function of `Q` if answers
drift over time. §7 q1 gives the only honest options (put time in `Q`, or assert it does
not matter), and neither is free. This is a genuine limit, and it is stated where a
reader will meet it rather than buried.

## 10. The four completion tests

1. **Every type has a stated meaning.** `Q`: a point of question space. `Ω`: a
   function `(q:Q) → R q`. `Grade`: a three-element join-semilattice. `S`: the free
   join-semilattice on `Q`. `W g A`: a natural transformation from oracles to answers,
   uniformly in every lawful `F` of class `g`. `C`: an ordered commutative monoid.
   `law(bill)`: an element of the monoid semiring `ℝ≥0[C]`.
2. **Every operation's meaning is forced.** Five morphism equations (§4.1) for five
   generators, of which four are standard class methods. Every other named operation
   is a derived form with a discharged equation (§6) or is deleted (§6.5–6.8).
   Primitiveness of `ap` and `select` is justified by cost-morphism equations that
   cannot otherwise close (§4.2).
3. **Nothing is left to prove that is not a lemma from the denotation.** Class laws
   hold by morphism. The interpreter's commutation is definitional (§7 q10 Part A).
   The residue is the ledger of §8.3, every item of which is a lemma *from* `⟦·⟧`, plus
   exactly one clearly labelled empirical axiom.
4. **Efficiency lives elsewhere.** `⟦·⟧_Id` is a valid, slow implementation (it
   consults a total world). Caching, batching, concurrency, and streaming are all
   refinements that leave `⟦·⟧` where it is — and §7 q1 shows caching is not merely
   safe but *invisible*, which is the strongest form of that test being passed.

---

## 11. Comparison with `agent-cat`'s `Term` calculus

*Read only after §§1–10 were complete and written.* Sources consulted:
`/Users/johnw/src/agent-cat/Agentic/{Term,Env,Keys,Scope}.lean`.

### 11.1 Convergences, and why each is forced

Four agreements, none of which may be cited as justification, all of which are
independently derived above:

1. **The world is a function.** `agent-cat`'s `Env C O := C → O` is a "complete answer
   sheet", and it draws the same two consequences: *caching is the identity on
   meanings* (`Env.cached_eq`) and *randomness sits at the outermost edge*, with a
   measure taken once at the end and no distribution threaded through any operator.
   §3.2, §5.4 and §7 q1 reach the same place from Attempts A and B in §9. The
   convergence is forced: it is the only representation under which the applicative
   morphism does not either fabricate independence (Attempt A) or fabricate an order
   (Attempt B).
2. **Consultation is one effect with three faces.** `Op i o` covers "a model turn, a
   tool invocation, an `Ask` of the human", and the module says the design "insists on
   the identification, because every operator that treats them alike (caching,
   pinning, gating, retry) would otherwise have to be written three times". §7 q7,
   same conclusion, same argument.
3. **Scope is precomposition on a reader's domain, with innermost-wins a theorem.**
   `Agentic/Scope.lean` uses a per-axis `Last` monoid; §6.3 uses a monoid action and
   `local`. These are the same structure named twice, and the Kernel's reader row
   forces it.
4. **Cost lives in a monoid semiring, and combination is convolution.**
   `Agentic/{Panel,Keys,Semiring,Matrix,Star}.lean` build `S⟨K⟩` with `MSemiring.conv`,
   fan-in as convolution over a key monoid, and fueled retry solved as star truncation
   `(M_A·d)* · M_B`. §5.4 states the same object and the same two laws (convolution for
   independent sequencing, Kleene star for unbounded retry). Forced by Step 6's
   "monoid-indexed semiring-valued function ⇒ the monoid semiring, whose multiplication
   *is* convolution".

That the two derivations agree on all four is the strongest evidence available that
these four are consequences of the domain rather than of anyone's taste.

### 11.2 The real disagreement: what a world is indexed by

`agent-cat` indexes `Env` by a **consultation site**, identified *positionally*:
"Every syntactic occurrence of `prim` is a distinct consultation site. Identity of
sites is *positional* — the path through the term." Duplication is the default;
sharing is the override, written `shareT (l : L)`, which rebases inner sites to
`(l, site-within-t)`.

This kernel indexes `Ω` by the **question** (§3.1), and puts the resample/reuse
distinction inside `Q` as the `draw` field (§7 q1). Both designs preserve the fact
`agent-cat` proves as `Env.share_ne_dup` — asking one index twice and two indices once
are different meanings — so the disagreement is not about *whether* to distinguish
them but about *where the distinction is written*. Three consequences separate them,
and they are checkable rather than matters of taste:

- **Compositionality.** Positional identity makes the meaning of a subterm depend on
  its position in the enclosing term, so the fold must carry a path context. That is
  the Kernel's third diagnostic row ("the equation requires an argument that is not
  available → the specification is not compositional"), and `agent-cat` applies the
  prescribed repair — it augments the fold with the context. The repair is legitimate.
  It is also avoidable: content-addressed identity needs no context, and §4.1's five
  morphism equations carry no path argument.
- **An unchecked obligation.** `Term.lean` states plainly that the fold "keys on the
  label alone and never compares bodies", so "one label over two *different* bodies
  collides wherever the inner sites coincide. Writing one label over one body is the
  designer's obligation, not a checked property (acat-bmc)." That is anti-pattern 9
  verbatim — an invariant maintained by documentation. Under §3.1 there is no such
  obligation, because equality of questions is decidable equality on a record and
  nothing else is ever compared.
- **The quantitative half.** `Term.lean` also records that "share costs one, dup costs
  two — is not yet paid; `Term.muS` is transparent at `shareT`." In §5.2 that debt does
  not exist: the cost carrier is the *idempotent* semilattice `Finset Q`, so
  `asks (w *> w) = asks w` holds by `∪`'s idempotence and dup costs two exactly because
  two distinct `draw` indices are two distinct questions. Attempt D in §9 is the record
  of choosing that carrier and why the additive one fails.

The honest cost of this kernel's choice, stated so it is not hidden: a user who writes
`ask q` twice intending two samples gets one. `agent-cat`'s default protects that user
("A default may only be the reading that cannot silently equate distinct samples"),
which is a serious argument. The answer here is that the mistake is *visible before it
is paid for*: `asks` reports `{q}` and `bill` reports one consultation, and the type of
`bestOf` (§7 q1) cannot produce n answers without producing n distinct questions. I
regard that as sufficient, but it is the one place where the two designs trade a real
guarantee for a real simplification rather than one dominating the other.

### 11.3 Divergences where this kernel claims the simpler position

1. **Applicative, not Arrow.** `Term Op G L f i o` is arrow-shaped: a symmetric
   monoidal category with `seqT`, `parT : Term f i j → Term g k l → Term (f+g) (i×k) (j×l)`,
   and explicit `pureT` plumbing (`fun x => (x, x)`) to route one input to two
   consumers. `W g A` is applicative-shaped and uses the host language's binding, so
   the plumbing does not exist and no copy combinator is written. The arrow shape buys
   point-free composition and a clean matrix semantics; it costs the standard class
   hierarchy — in particular there is no `Selective` for an arrow, and so no
   `Over`/`Under` and none of Mokhov's derived combinators.
2. **Branching strength as the grade, not width.** `Frag` grades *data-dependent
   width* (`static | bounded n | monadic`, with `+` at `parT` and `scale n` at
   `fanT`). `Grade` here grades *sequencing strength* (`ap ≤ sel ≤ mon`). These are
   orthogonal axes, and the difference shows at `choiceT`, which `agent-cat` grades
   `f ⊔ g` — so a choice between two static branches stays `.static`. Value-dependent
   branching is therefore invisible in the `Frag` index, and "a term at `.static` has
   exact folds" is true only in the semiring-matrix sense, where a branch is a sum of
   scalars. Naming the branching level `sel` makes the cost tree, the tight tropical
   bounds, and the attaining worlds (§5.3) statable as theorems about the *term*.
3. **Eight constructors deleted.** `agent-cat` has thirteen term formers; this kernel
   has five. `retryT`, `fanT`, `gateT`, `scopeT`, `shareT`, `choiceT`, `sumT`, `parT`
   are derived or deleted here (§6), each with a discharged morphism equation or a
   demonstration that none exists. Every named former costs a clause in every fold and
   a case in every proof; the `Term` module's own remarks about `castGrade`,
   `Frag.scale`'s `max 1`, and `peak_not_le_grade` are the visible price.
4. **`gateT` is the one place the deletion is not free, and I say so.** `agent-cat`
   reads a gate as a *semimodule scalar action* where refusal is `0` and annihilates
   downstream cost — a genuinely different equation from `ifS`, which keeps both
   branches in the cost tree. The kernel above has no zero and therefore no annihilator;
   §7 q8's "refusal is a value in `R q`" reproduces the *outcome* but not the *cost
   collapse*. Either the cost carrier gains a zero (making `S` a semiring rather than a
   semilattice) or gates stay `ifS` and a vetoed branch is charged its `Under` bound
   (zero) rather than annihilating the whole product. This is an open point, recorded
   in §11.5 rather than argued away.

### 11.4 What should be adopted from `agent-cat`

- **`pin = Function.update`.** `Env.pin` observes that forking a session, resuming from
  a checkpoint, and editing a recorded fixture are three uses of counterfactual
  substitution on the answer sheet. That falls out of §3.2 for free and I did not name
  it. It should be named: `pin : Ω → (q : Q) → R q → Ω`, with Mathlib's five update
  laws, and it is the specification of replay, fixtures, and "what if the tool had said
  this instead".
- **The `Frag` width axis.** §§1–10 have no account of data-dependent *width*, which
  is a genuine resource question (`fanT n` over a list whose length the values decide)
  and is orthogonal to `Grade`. A complete kernel plausibly wants the product
  `Grade × Frag`, and `Frag`'s `+` at tensoring and `scale` at fanning are the right
  operations. `peak_not_le_grade` — the report that consultations-in-flight is
  *incomparable* with the grade — is exactly the kind of negative result the Kernel
  asks to have reported, and it should be carried forward.
- **The newtype discipline of `Keys.lean`.** One monoid per carrier (`Tally`, `Width`,
  `Race`), so that the type of a verdict says which fold it belongs to. §6.1's
  `Monoid V` needs the same discipline the moment two folds over `ℕ` coexist.

### 11.5 Open points after the comparison

1. The gate/annihilator question (§11.3.4): does `S` need a zero?
2. The width axis (§11.4): `Grade × Frag`, and whether the product's laws close.
3. The default-sharing trade (§11.2): the one place where neither design dominates.
4. §9's unrepaired item: a live model that drifts is not a function of `Q`.
5. Whether `Selective` survives the move to a dependent `R : Q → Type` without
   friction — `select`'s `A ⊕ B` is at fixed types, and the dependent answer type may
   force a `Σ`-shaped variant whose `Over`/`Under` instances must be re-derived rather
   than imported.
