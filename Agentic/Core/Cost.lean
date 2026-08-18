import Agentic.Core.Level
import Mathlib.Algebra.BigOperators.Group.List.Lemmas
import Mathlib.Algebra.Order.BigOperators.Group.List
import Mathlib.Algebra.Order.Monoid.Unbundled.TypeTags
import Mathlib.Data.Finset.Lattice.Fold
import Mathlib.Data.Finset.Max
import Mathlib.Data.List.Dedup
import Mathlib.Data.Multiset.Bind
import Mathlib.Data.Multiset.Lattice
import Mathlib.Data.Set.Finite.Basic

/-!
# The bill, and what can be known about it before the run

Rederivation kernel §4 (the cost-factorization obligations C0–C5, *stated once*
as directive (1)), §3 q4 (what each rung yields), §8.2 open questions 1 and 2,
and `attack-adequacy` §7 (the three failure modes F1–F3, and the missing
hypothesis that all four re-derivations omit).

The bill is a **monoid morphism out of the transcript**, and the transcript is
in the meaning, so nothing here is a second semantics: `billFresh` is a fold of
`Plan.trace`, which is a fold of `denote`. What the analyses add is the question
the owner actually asked — *what is the bill before the run?* — and the answer
is graded by `Agentic.Core.level`:

| rung | what is known before the run | here |
|---|---|---|
| `batch` | the exact question list, independent of world *and* of environment | `asks_eq_of_le_batch` |
| `pipeline` | the exact count and code sequence, and the exact sequence of question *shapes* as a fold of the term alone; and, under `PricesByShape`, the exact bill | `codes_eq_of_le_pipeline`, `shapes_eq_trace_of_le_pipeline`, `bill_exact_pipeline` |
| `branch` | a finite `Multiset` of possible bills containing the bill; bounds; best and worst *achievable* case attained | `bill_mem_leaves`, `minFold_le_bill`, `exists_min_bill` |
| `dynamic` | nothing, and a witness says so: at `unbounded` no finite set of bills exists at all | `no_finite_bill_set_at_dyn` |

## Three corrections to the kernel, each machine-checked

1. **C2 is true, and the *representation* is why.** The kernel claims that at
   `level ≤ pipeline` the sequence of question *shapes* is world-independent.
   Under an earlier representation, in which `ask` carried an arbitrary
   `Expr Γ (Q c)`, that claim was false — an answer could select the
   *addressee*, and the addressee is part of the shape — and the repair on offer
   was a side predicate (`ShapeStatic`) asserting that answers flow into prompt
   text and nowhere else. That predicate is gone. `Plan.ask` now carries the
   shape as **term-level data** and only the prompt as an expression
   (`Q c ≅ Q.Shape c × String`), so the counterexample is not expressible and
   the shape sequence is a projection of the syntax — literally, as the fold
   `shapes`, which reads it off the term with no environment and no world
   (`shapes_eq_trace_of_le_pipeline`). `bill_exact_pipeline` carries no
   hypothesis beyond the level bound and `PricesByShape`. The domain's pivot (§2.3, "the
   prompt is a function of an earlier answer") is now the *type* of the node
   rather than a property of it.

2. **C3's attainment claim is false as stated.** A `case` whose tag does not
   depend on any answer has an arm no world reaches, so the extreme *leaves* of
   the tree need not be attained (`minFold_not_attained`). What is true, and is
   what a budget needs, is that the extremes of the *achievable* bills are
   attained (`exists_min_bill`, `exists_max_bill`) and lie inside the tree's
   bounds. The tree's bounds remain sound; only the claim that they are tight
   is withdrawn.

3. **C4 is stated too weakly by the kernel and is strengthened here.** "No
   `Φ : Plan → S` returns the bill" is true at `dynamic` but is equally true at
   `branch` (`no_static_bill_at_branch`), so it does not separate the rungs. The
   statement that does is `no_finite_bill_set_at_dyn`: a `dyn` plan is
   *exhibited* whose possible bills form no finite set, hence for which no
   `costM` of any shape exists — precisely the negation of C3, and the honest
   replacement for `Frag`. Note the quantifier: this is a witness at the rung,
   not a claim about every term the rung contains. A `dyn` whose function is
   constant costs exactly what its body costs; what `dynamic` says is that the
   rung *admits* plans no finite analysis reaches, so no analysis is licensed
   there.

## Two bills, both derived, neither baked in

`billFresh` sums over all events; `billMemo` sums over distinct questions.
Making idempotence a property of the cost *carrier* bakes a memoizing runtime
into the denotation; carrying the trace and deriving both dissolves the dispute
(kernel §4). `billMemo_dvd_billFresh` is the exact relation between them —
a divisibility in the monoid, with no order and no hypothesis — and
`billMemo_le_billFresh` is its order reading where prices are at least the unit.
-/

namespace Agentic.Core

open Plan

/-! ## Keys and shapes: what a price is a function of -/

/-- `[[Key]]` = a question together with the code it asks for: a point of
question space, forgetting the answer. This is the key of the memo table, the
key of a content-addressed cache, and the argument of a price — three uses of
one object (§3 q1). -/
abbrev Key : Type := (c : Code) × Q c

/-- `[[Shape]]` = what a question is, minus what it says, across all codes: the
total space of `Q.Shape` (`Agentic/Core/Question.lean`), which is where a
*transcript* reads shapes off, since a transcript mixes codes.

This is the finite quotient of question space that `attack-adequacy` §7 says all
four re-derivations needed and none stated. Per-call and per-latency pricing
factor through it; per-token pricing does not, and for per-token pricing the
honest output is an interval keyed to a token bound carried in the answer type
(kernel §2.5). -/
abbrev Shape : Type := (c : Code) × Q.Shape c

/-- The kind of answer asked for. -/
abbrev Shape.code (s : Shape) : Code := s.1

/-- Who is being asked. -/
abbrev Shape.addressee (s : Shape) : Addressee := s.2.addressee

/-- The question an event put. -/
def Event.key (e : Event) : Key := ⟨e.c, e.q⟩

/-- The shape of a key. -/
def Key.shape (k : Key) : Shape := ⟨k.1, k.2.shape⟩

/-- The shape of the question an event put. -/
def Event.shape (e : Event) : Shape := ⟨e.c, e.q.shape⟩

@[simp] theorem Event.shape_eq_key_shape (e : Event) : e.shape = e.key.shape := rfl

/-- Reading the shapes off a transcript factors through reading its keys. -/
theorem Event.map_shape (t : Trace) : t.map Event.shape = (t.map Event.key).map Key.shape := by
  simp [List.map_map, Function.comp_def, Event.shape, Key.shape, Event.key]

/-! ## Prices and bills -/

variable {S : Type}

/-- `[[Price S]]` = what each question costs, in the carrier `S`: a function of
the question, because a price is a fact about what is asked and of whom, not
about where in a plan it was asked. -/
abbrev Price (S : Type) : Type := (c : Code) → Q c → S

/-- A price, read at a key. -/
def priceKey (price : Price S) (k : Key) : S := price k.1 k.2

/-- `[[PricesByShape price]]` = the price of a question depends on its shape and
not on its prompt text.

The hypothesis `attack-simplicity` I1 and `attack-adequacy` §7 both identify as
missing from all four proposals, and the difference between an exact bill and a
bounded one.

**What it is, categorically: object-blindness of the target.** A `Const M`-valued
interpretation of the term language has no argument position — the carrier is
`fun _ _ => M`, so nothing an answer could flow into is available to it. An
interpretation of the `ask` generator into such a target is therefore exactly a
function of the generator's *label*, and at `pipeline` the label an `ask` node
carries is its shape (`Q.Shape c`) and not its whole question, because the words
are an `Expr` computed from answers in scope. `PricesByShape` is that fact
written as a condition on the price: it is not an assumption about terms, it is
the statement that the target is a `Const`. The one rung where it is not needed
is `batch`, where the generator is nullary (`Plan.askC` carries a whole `Q c`)
and every function `Key → M` is a legitimate interpretation — see
`bill_exact_batch`. -/
def PricesByShape (price : Price S) : Prop :=
  ∀ (c : Code) (q q' : Q c), q.shape = q'.shape → price c q = price c q'

/-- Read at keys: shape-equal keys are priced equally. The `Sigma` disequality
of `World.lean` reappears here as a `Sigma` *equality*, and it is discharged the
same way — the code is a field of the shape, so shape equality forces it. -/
theorem PricesByShape.key {price : Price S} (hp : PricesByShape price) :
    ∀ (k k' : Key), k.shape = k'.shape → priceKey price k = priceKey price k' := by
  rintro ⟨c, q⟩ ⟨c', q'⟩ h
  have hc : c = c' := congrArg Shape.code h
  subst hc
  exact hp c q q' (by simpa [Key.shape] using h)

/-- `[[billOfKeys price ks]]` = what that list of questions comes to. -/
def billOfKeys [Monoid S] (price : Price S) (ks : List Key) : S :=
  (ks.map (priceKey price)).prod

/-- `[[billFresh price t]]` = what the transcript `t` comes to, **charging every
event**: the monoid morphism out of the free monoid on `Event`.

**Morphism equation** (`billFresh_append`, proved below):
`bill (t ++ t') = bill t * bill t'`, with `bill [] = 1`. Because the transcript
is in the meaning, this makes cost an invariant of semantic equality: a shared
read is one factor and a duplicated read is two (§3 q9). -/
def billFresh [Monoid S] (price : Price S) (t : Trace) : S :=
  billOfKeys price (t.map Event.key)

/-- `[[billMemo price t]]` = what the transcript comes to **charging each
distinct question once**: the bill a memoizing runtime pays.

Derived from the same trace as `billFresh` rather than baked into the carrier.
Note that it is *not* a monoid morphism (`billMemo_not_monoid_hom`), which is
exactly why making idempotence a property of the carrier is a mistake: the
policy is a property of the runtime, and the meaning should record neither. -/
def billMemo [Monoid S] (price : Price S) (t : Trace) : S :=
  billOfKeys price ((t.map Event.key).dedup)

section BillLaws

variable [Monoid S] {price : Price S}

@[simp] theorem billOfKeys_nil : billOfKeys price ([] : List Key) = 1 := rfl

@[simp] theorem billOfKeys_cons (k : Key) (ks : List Key) :
    billOfKeys price (k :: ks) = priceKey price k * billOfKeys price ks := by
  simp [billOfKeys]

theorem billOfKeys_append (ks ks' : List Key) :
    billOfKeys price (ks ++ ks') = billOfKeys price ks * billOfKeys price ks' := by
  simp [billOfKeys, List.prod_append]

@[simp] theorem billFresh_nil : billFresh price ([] : Trace) = 1 := rfl

@[simp] theorem billFresh_cons (e : Event) (t : Trace) :
    billFresh price (e :: t) = price e.c e.q * billFresh price t := by
  simp [billFresh, Event.key, priceKey]

/-- **The morphism equation for the bill**: it is a monoid morphism out of the
transcript, which is what makes it a fold of the meaning rather than a second
semantics. -/
theorem billFresh_append (t t' : Trace) :
    billFresh price (t ++ t') = billFresh price t * billFresh price t' := by
  simp [billFresh, billOfKeys_append]

end BillLaws

/-- **The exact relation between the two bills**, with no order and no
hypothesis on the prices: the memoized bill *divides* the fresh one, because the
deduplicated key list is a sublist of the key list. -/
theorem billMemo_dvd_billFresh [CommMonoid S] (price : Price S) (t : Trace) :
    billMemo price t ∣ billFresh price t :=
  (((t.map Event.key).dedup_sublist).map (priceKey price)).prod_dvd_prod

/-- …and its order reading, where every question costs at least the unit:
memoizing never costs more. The hypothesis is on the *prices*, not on the
carrier — an idempotent carrier would be a memoizing runtime smuggled into the
denotation. -/
theorem billMemo_le_billFresh [Monoid S] [Preorder S] [MulLeftMono S] [MulRightMono S]
    (price : Price S) (h1 : ∀ (c : Code) (q : Q c), 1 ≤ price c q) (t : Trace) :
    billMemo price t ≤ billFresh price t := by
  refine List.Sublist.prod_le_prod' (((t.map Event.key).dedup_sublist).map _) ?_
  intro a ha
  obtain ⟨k, _, rfl⟩ := List.mem_map.mp ha
  exact h1 k.1 k.2

/-! ## What a scheduler is allowed to change about the bill

`Agentic/Core/Denote.lean` states the scheduling licence twice — on the approval
decision (`approved_panel_perm`) and on the transcript up to permutation
(`trace_panel_perm`). This is the third reading, and the one an owner cares
about: reordering a panel does not change what it costs, provided the cost
carrier does not care about order either. -/

/-- Permuted transcripts cost the same in a **commutative** carrier. The
hypothesis is on the carrier and not on the runtime: `Multiplicative ℕ` (hence
`tick`) is commutative, so counting bills are order-blind, while a carrier that
records the order of charges is not and must not be told otherwise. -/
theorem billFresh_perm [CommMonoid S] (price : Price S) {t t' : Trace} (h : t.Perm t') :
    billFresh price t = billFresh price t' :=
  ((h.map Event.key).map (priceKey price)).prod_eq

/-- **The scheduling licence, on the bill.** A runtime may run a panel's members
in any order without changing what the run costs. This is the cost reading of
`trace_panel_perm`, and it is the statement that makes reordering *safe* rather
than merely undetectable. -/
theorem billFresh_panel_perm [CommMonoid S] (price : Price S) {Γ : Ctx} {c : Code}
    [Monoid (El c)] (ω : Ω) {ps ps' : List (Plan Γ (El c))} (h : ps.Perm ps') (γ : Env Γ) :
    billFresh price (Plan.trace ω (Plan.panel ps) γ)
      = billFresh price (Plan.trace ω (Plan.panel ps') γ) :=
  billFresh_perm price (trace_panel_perm ω h γ)

/-! ## The counting price, which is what "#asks" means as a bill -/

/-- `[[tick]]` = one unit per consultation. The bill at this price is the number
of events, so every statement below about bills specializes to a statement about
`#asks` without a second notion of cost. -/
def tick : Price (Multiplicative Nat) := fun _ _ => Multiplicative.ofAdd 1

/-- **Morphism equation.** The bill at the counting price is the length of the
transcript: `Multiplicative ℕ` is the free monoid on one generator, and `tick`
is the map that sends every question to it. -/
@[simp] theorem billFresh_tick (t : Trace) :
    billFresh tick t = Multiplicative.ofAdd t.length := by
  induction t with
  | nil => rfl
  | cons e t ih =>
    rw [billFresh_cons, ih, List.length_cons]
    show Multiplicative.ofAdd 1 * Multiplicative.ofAdd t.length = _
    rw [← ofAdd_add, Nat.add_comm]

/-- **`billMemo` is not a monoid morphism**, and the counting price is enough to
see it: a transcript concatenated with itself has the same distinct questions,
so the memo bill does not double. Recorded in code because it is the reason the
memoization policy cannot live in the carrier. -/
theorem billMemo_not_monoid_hom :
    ∃ (t : Trace), billMemo tick (t ++ t) ≠ billMemo tick t * billMemo tick t := by
  refine ⟨[⟨.ack, ⟨.tool "t", 1, "", 0⟩, ()⟩], ?_⟩
  decide

/-! ## The default world, and what a fold of the term is a fold *of* -/

/-- `[[ωDefault]]` = the world in which every addressee says the least
informative thing it can. It exists because every `El c` is inhabited, and it is
what makes an analysis a computable fold of the term: `asks p γ` below is the
key list of `p`'s transcript *in this world*, which is why it is exact exactly
when the transcript's shape does not depend on the world. -/
def ωDefault : Ω := fun _ _ => default

@[simp] theorem ωDefault_apply (c : Code) (q : Q c) : ωDefault c q = default := rfl

/-! ## The analyses, as `Option`-valued folds of the term

Grade-as-fold, following the compiled repair `E_grade_as_fold_works.lean`: the
analysis is defined everywhere, returns `none` outside its fragment, and the
theorem `…_isSome_of_le_…` is the totality statement that the level fold is
sound. No type index, no dependent elimination, no `Frag`. -/

/-- The code sequence, as an algebra. `codes` just below is its fold.

`none` at `case` and `dyn` — where the sequence is not fixed by the term — and a
fold of the term *alone* elsewhere: no environment, no world.

`Const (Option (List Code))` is the carrier, and the two `none`
clauses are where the analysis stops. -/
def codesAlg : PlanAlg (fun _ _ => Option (List Code)) where
  ret _ := some []
  askC c _ k := (c :: ·) <$> k
  ask c _ _ k := (c :: ·) <$> k
  case := fun _ _ _ => none
  dyn _ _ _ := none

/-- `[[codes p]]` = the sequence of answer codes `p` will ask for, if that
sequence is fixed by the term. -/
def codes : {Γ : Ctx} → {A : Type} → Plan Γ A → Option (List Code) :=
  fun p => codesAlg.fold p

/-! ### The five defining equations of `codes`, each a `rfl` -/

theorem codes_ret {Γ : Ctx} {A : Type} (e : Expr Γ A) : codes (Plan.ret e) = some [] := rfl

theorem codes_askC {Γ : Ctx} {A : Type} (c : Code) (q : Q c) (k : Plan (c :: Γ) A) :
    codes (Plan.askC c q k) = (c :: ·) <$> codes k := rfl

theorem codes_ask {Γ : Ctx} {A : Type} (c : Code) (s : Q.Shape c) (e : Expr Γ String)
    (k : Plan (c :: Γ) A) : codes (Plan.ask c s e k) = (c :: ·) <$> codes k := rfl

theorem codes_case {Γ : Ctx} {A : Type} (t : Tag) (e : Expr Γ t.El) (arms : t.El → Plan Γ A) :
    codes (Plan.case t e arms) = none := rfl

theorem codes_dyn {Γ : Ctx} {A : Type} (b : Code) (e : Expr Γ (El b)) (f : El b → Plan Γ A) :
    codes (Plan.dyn b e f) = none := rfl

/-- The shape sequence, as an algebra. `shapes` just below is its fold: the
sequence of question *shapes* `p` will put — who is asked, under what scope, at
which draw — if that sequence is fixed by the term.

**No environment and no world.** This fold is the payoff of the representation
repair: an `ask` node carries `s : Q.Shape c` as data, so its shape can be read
off without evaluating anything. Under the old node, in which the whole question
was an `Expr Γ (Q c)`, no such fold could exist — the best available was `asks`,
which substitutes `default` answers and is exact only up to shape.

`none` at `case` and `dyn`, where the sequence is not fixed by the term. -/
def shapesAlg : PlanAlg (fun _ _ => Option (List Shape)) where
  ret _ := some []
  askC c q k := (⟨c, q.shape⟩ :: ·) <$> k
  ask c s _ k := (⟨c, s⟩ :: ·) <$> k
  case := fun _ _ _ => none
  dyn _ _ _ := none

/-- `[[shapes p]]` = the sequence of question shapes `p` will put, if that
sequence is fixed by the term. `shapesAlg.fold`. -/
def shapes : {Γ : Ctx} → {A : Type} → Plan Γ A → Option (List Shape) :=
  fun p => shapesAlg.fold p

/-! ### The five defining equations of `shapes`, each a `rfl` -/

theorem shapes_ret {Γ : Ctx} {A : Type} (e : Expr Γ A) : shapes (Plan.ret e) = some [] := rfl

theorem shapes_askC {Γ : Ctx} {A : Type} (c : Code) (q : Q c) (k : Plan (c :: Γ) A) :
    shapes (Plan.askC c q k) = (⟨c, q.shape⟩ :: ·) <$> shapes k := rfl

theorem shapes_ask {Γ : Ctx} {A : Type} (c : Code) (s : Q.Shape c) (e : Expr Γ String)
    (k : Plan (c :: Γ) A) : shapes (Plan.ask c s e k) = (⟨c, s⟩ :: ·) <$> shapes k := rfl

theorem shapes_case {Γ : Ctx} {A : Type} (t : Tag) (e : Expr Γ t.El) (arms : t.El → Plan Γ A) :
    shapes (Plan.case t e arms) = none := rfl

theorem shapes_dyn {Γ : Ctx} {A : Type} (b : Code) (e : Expr Γ (El b)) (f : El b → Plan Γ A) :
    shapes (Plan.dyn b e f) = none := rfl

/-- The question list, as an algebra. `asks` just below is its fold.

An environment is needed because an `ask` builds its *words* from the answers in
scope; `default` stands in for those answers, and the two theorems below say
exactly when that substitution is harmless: exactly at `batch` (there are no
`ask` nodes), and up to shape at `pipeline` — where "up to shape" is now free,
since the shape is written in the term.

**Not a static analysis: this is the semantics, evaluated at one world.**
`asks_eq_default` below is the proof, and it should be read as a
*classification* rather than a convenience — at `level p ≤ pipeline`,
`asks p γ = some ((Plan.trace ωDefault p γ).map Event.key)`, so `asks` is the
question list of a *run*, in the world that answers everything with `default`.
That it can be computed by structural recursion on the term is a consequence of
the pipeline bound, not evidence that it is a fold of the term alone: it is not
one, and the environment argument is the visible sign. The genuine folds of the
term alone are `codes` and `shapes`, which take no environment, and
`shapes_eq_map_asks` says precisely what `Key.shape` throws away to get from one
to the other — the words, which is exactly the data `default` was standing in
for.

`asksAlg.fold`, at the function-space carrier `P Γ A = Env Γ → Option (List Key)`
— the environment is the accumulator, and `Env.cons default` is the algebra's
action on it. -/
def asksAlg : PlanAlg (fun Γ _ => Env Γ → Option (List Key)) where
  ret _ := fun _ => some []
  askC c q k := fun γ => (⟨c, q⟩ :: ·) <$> k (.cons default γ)
  ask c s e k := fun γ => (⟨c, s.withPrompt (e γ)⟩ :: ·) <$> k (.cons default γ)
  case := fun _ _ _ => fun _ => none
  dyn _ _ _ := fun _ => none

/-- `[[asks p γ]]` = the list of questions `p` will put, evaluated with the
least informative answers. `asksAlg.fold`. -/
def asks : {Γ : Ctx} → {A : Type} → Plan Γ A → Env Γ → Option (List Key) :=
  fun p => asksAlg.fold p

/-! ### The five defining equations of `asks`, each a `rfl` -/

theorem asks_ret {Γ : Ctx} {A : Type} (e : Expr Γ A) (γ : Env Γ) :
    asks (Plan.ret e) γ = some [] := rfl

theorem asks_askC {Γ : Ctx} {A : Type} (c : Code) (q : Q c) (k : Plan (c :: Γ) A) (γ : Env Γ) :
    asks (Plan.askC c q k) γ = (⟨c, q⟩ :: ·) <$> asks k (.cons default γ) := rfl

theorem asks_ask {Γ : Ctx} {A : Type} (c : Code) (s : Q.Shape c) (e : Expr Γ String)
    (k : Plan (c :: Γ) A) (γ : Env Γ) :
    asks (Plan.ask c s e k) γ
      = (⟨c, s.withPrompt (e γ)⟩ :: ·) <$> asks k (.cons default γ) := rfl

theorem asks_case {Γ : Ctx} {A : Type} (t : Tag) (e : Expr Γ t.El) (arms : t.El → Plan Γ A)
    (γ : Env Γ) : asks (Plan.case t e arms) γ = none := rfl

theorem asks_dyn {Γ : Ctx} {A : Type} (b : Code) (e : Expr Γ (El b)) (f : El b → Plan Γ A)
    (γ : Env Γ) : asks (Plan.dyn b e f) γ = none := rfl

/-- `[[asksBill price p γ]]` = the bill read off the term, without running it.

The kernel writes this fold `asks price p`, and the two obligations it appears
in — `bill_exact_batch` and `bill_exact_pipeline` — are the equation
`bill price (trace ω (den p γ)) = asks price p` at the two rungs where it
holds. -/
def asksBill [Monoid S] (price : Price S) {Γ : Ctx} {A : Type} (p : Plan Γ A) (γ : Env Γ) :
    Option S :=
  (asks p γ).map (billOfKeys price)

variable {Γ Δ : Ctx} {A B : Type}

/-! ### The three folds are one fold, read through two projections

`codes`, `shapes` and `asks` are not three analyses. They are one analysis and
two forgetful maps — `Shape.code : Shape → Code` and `Key.shape : Key → Shape` —
and the two equations below say so, **with no level hypothesis at all**. They are
true at `branch` and `dynamic` too, where all three sides are `none`.

That is the right shape for the statement, and the package used to entangle two
different things: the level bound belongs to *totality* (is the analysis
defined?) and not to *factorisation* (do the three agree where they are?). The
axiom footprints make the point cleanly — both fusions are `[propext]`, where
`codes_eq_of_le_pipeline` and `shapes_eq_trace_of_le_pipeline` are
`[propext, Classical.choice, Quot.sound]`: factorisation does not need the order
theory, only totality does. -/

/-- **Fusion 1.** `codes` is `shapes` read through `Shape.code`. No level
hypothesis, and none is available to want: at `branch` and `dynamic` both sides
are `none`. -/
theorem codes_eq_map_shapes (p : Plan Γ A) :
    codes p = (shapes p).map (List.map Shape.code) := by
  induction p with
  | ret e => rfl
  | askC c q k ih => simp [codes_askC, shapes_askC, ih, Option.map_map, Function.comp_def, Shape.code]
  | ask c s e k ih => simp [codes_ask, shapes_ask, ih, Option.map_map, Function.comp_def, Shape.code]
  | case t e arms _ => rfl
  | dyn b e f _ => rfl

/-- **Fusion 2, and in *every* environment.** `shapes` is `asks` read through
`Key.shape`: the environment `asks` needs is exactly the data `Key.shape` throws
away.

This is a sharper statement of "the shape is a projection of the syntax" than
`shapes_eq_of_le_pipeline` below, because it needs no world, no level bound and
no choice of `γ` — the left-hand side does not mention one, so the right-hand
side's value is independent of it, which is the content. -/
theorem shapes_eq_map_asks : ∀ {Γ : Ctx} {A : Type} (p : Plan Γ A) (γ : Env Γ),
    shapes p = (asks p γ).map (List.map Key.shape) := by
  intro Γ A p
  induction p with
  | ret e => intro γ; rfl
  | askC c q k ih =>
      intro γ
      simp [shapes_askC, asks_askC, ih (Env.cons default γ), Option.map_map, Function.comp_def, Key.shape]
  | ask c s e k ih =>
      intro γ
      simp [shapes_ask, asks_ask, ih (Env.cons default γ), Option.map_map, Function.comp_def, Key.shape]
  | case t e arms _ => intro γ; rfl
  | dyn b e f _ => intro γ; rfl

/-- **C5, first half — and the one induction the three totality theorems now
share.** The shape fold is total on the pipeline fragment: the level being
`≤ pipeline` is not a side condition on the analysis, it is the statement that
the analysis is defined.

Stated at `shapes` rather than at `asks` because `shapes` is the fold of the
term alone, and under the old `ask` node it could not have been proved at all —
there was no shape in the term to fold over. The other two follow from it by the
two fusions, and their `absurd … decide` tails go with them. -/
theorem shapes_isSome_of_le_pipeline (p : Plan Γ A) (h : level p ≤ Level.pipeline) :
    (shapes p).isSome := by
  induction p with
  | ret e => simp [shapes_ret]
  | askC c q k ih => simpa [shapes_askC, Option.isSome_map] using ih h
  | ask c s e k ih => simpa [shapes_ask, Option.isSome_map] using ih (le_of_ask h).2
  | case t e arms _ => exact absurd (le_of_case h).1 (by decide)
  | dyn b e f _ => exact absurd h (by simp only [level_dyn]; decide)

/-- The code fold is total there too — a corollary of `codes_eq_map_shapes`, not
a second induction. -/
theorem codes_isSome_of_le_pipeline (p : Plan Γ A) (h : level p ≤ Level.pipeline) :
    (codes p).isSome := by
  rw [codes_eq_map_shapes]; simpa using shapes_isSome_of_le_pipeline p h

/-- …and so is the question fold, in every environment — a corollary of
`shapes_eq_map_asks` read backwards: `Option.map` reflects `isSome`, so the
environment cannot affect whether the analysis is defined. -/
theorem asks_isSome_of_le_pipeline (p : Plan Γ A) (h : level p ≤ Level.pipeline) (γ : Env Γ) :
    (asks p γ).isSome := by
  simpa [shapes_eq_map_asks p γ] using shapes_isSome_of_le_pipeline p h

/-! ## C1 — BATCH: the exact question list, independent of world and environment -/

/-- **Kernel obligation C1.** At `level ≤ batch` the questions a plan puts are
*written in the term*: the same list in every world and under every environment.

Stronger than the kernel asks in two ways, and both are free: the list is exact
rather than the multiset, and it is independent of the environment as well as of
the world — at `batch` there is no `ask` node, so there is nothing for an answer
to flow into. -/
theorem asks_eq_of_le_batch (p : Plan Γ A) (h : level p ≤ Level.batch) :
    ∀ (γ γ' : Env Γ) (ω : Ω), asks p γ = some ((Plan.trace ω p γ').map Event.key) := by
  induction p with
  | ret e => intro γ γ' ω; simp [asks_ret, Plan.trace]
  | askC c q k ih =>
    intro γ γ' ω
    rw [asks_askC, ih h (.cons default γ) (.cons (ω c q) γ') ω]
    simp [Plan.trace_askC, Event.key]
  | ask c s e k _ => exact absurd (le_of_ask h).1 (by decide)
  | case t e arms _ => exact absurd (le_of_case h).1 (by decide)
  | dyn b e f _ => exact absurd h (by simp only [level_dyn]; decide)

/-- The multiset the kernel names, as an immediate corollary: at `batch` the
multiset of asked questions is world-independent. (The list equality above says
more; the multiset is what the kernel's C1 asks for and what a scheduler cares
about.) -/
theorem asked_multiset_eq_of_le_batch (p : Plan Γ A) (h : level p ≤ Level.batch)
    (γ : Env Γ) (ω ω' : Ω) :
    ((Plan.trace ω p γ).map Event.key : Multiset Key)
      = ((Plan.trace ω' p γ).map Event.key : Multiset Key) := by
  have h₁ := asks_eq_of_le_batch p h γ γ ω
  have h₂ := asks_eq_of_le_batch p h γ γ ω'
  exact congrArg _ (Option.some.inj (h₁.symm.trans h₂))

/-- **The bill is exact at `batch`, with no hypothesis on the price at all.**
Content-dependent pricing is fine here: the content is in the term. This is the
guarantee `askC` exists to record, and the only guarantee `batch` has over
`pipeline` (kernel open question 3).

**Kernel open question 3, answered: `askC` buys a nullary generator.** The
question is what `batch` has that `pipeline` does not, given that both are
`Const`-analysable. The answer is the arity of the generator. `Plan.askC c q k`
carries the *whole* question `q : Q c` as term-level data, so the batch
signature is `{ g_{c,q} : 1 ⇝ El c }` — one nullary generator per element of
`Cost.Key` — and an interpretation into a monoid `M` is any function
`Key → M` whatsoever. `Plan.ask c s e k` carries only the shape, its words being
an `Expr` over the answers in scope, so the pipeline signature is
`{ g_{c,s} : String ⇝ El c }` — unary generators labelled by `Cost.Shape` — and
an interpretation must be constant in the argument it cannot see. That is the
whole of the asymmetry between this theorem's hypothesis list and
`bill_exact_pipeline`'s, and it is why content-dependent pricing (per-token, say)
is a legitimate analysis exactly here and nowhere above. -/
theorem bill_exact_batch [Monoid S] (price : Price S) (p : Plan Γ A)
    (h : level p ≤ Level.batch) (γ : Env Γ) (ω : Ω) :
    asksBill price p γ = some (billFresh price (Plan.trace ω p γ)) := by
  rw [asksBill, asks_eq_of_le_batch p h γ γ ω]
  rfl

/-! ## C2 — PIPELINE: the exact count, code sequence and shapes -/

/-- **Kernel obligation C2, at the codes.** At `level ≤ pipeline` the sequence
of answer codes — and hence the number of consultations — is fixed by the term:
no world and no environment can change it.

The code is the coarsest thing a question has, so this is the weakest half of
the pipeline guarantee; `shapes_eq_trace_of_le_pipeline` below strengthens it to
the whole shape, and that half was the one the kernel got wrong before the `ask`
node carried its shape. -/
theorem codes_eq_of_le_pipeline (p : Plan Γ A) (h : level p ≤ Level.pipeline) :
    ∀ (γ : Env Γ) (ω : Ω), codes p = some ((Plan.trace ω p γ).map Event.c) := by
  induction p with
  | ret e => intro γ ω; simp [codes_ret, Plan.trace]
  | askC c q k ih =>
    intro γ ω
    rw [codes_askC, ih h (.cons (ω c q) γ) ω]
    simp [Plan.trace_askC]
  | ask c s e k ih =>
    intro γ ω
    rw [codes_ask, ih (le_of_ask h).2 (.cons (ω c (s.withPrompt (e γ))) γ) ω]
    simp [Plan.trace_ask]
  | case t e arms _ => exact absurd (le_of_case h).1 (by decide)
  | dyn b e f _ => exact absurd h (by simp only [level_dyn]; decide)

/-- **`#asks` is constant across worlds at `pipeline`** — the count the owner
asks for, before the run, with no hypothesis on the price. -/
theorem length_trace_eq_of_le_pipeline (p : Plan Γ A) (h : level p ≤ Level.pipeline)
    (γ : Env Γ) (ω ω' : Ω) :
    (Plan.trace ω p γ).length = (Plan.trace ω' p γ).length := by
  have h₁ := codes_eq_of_le_pipeline p h γ ω
  have h₂ := codes_eq_of_le_pipeline p h γ ω'
  have := Option.some.inj (h₁.symm.trans h₂)
  simpa using congrArg List.length this

/-! ## …and the half the kernel got wrong, now true by construction -/

/-- A coin to consult. -/
def coinQ : Q .flag := { addressee := .tool "coin", scope := 1, prompt := "heads?", draw := 0 }

/-- The world that says heads. -/
def heads : Ω := fun c => match c with
  | .text => fun _ => "" | .verdict => fun _ => 1 | .flag => fun _ => true | .ack => fun _ => ()

/-- The world that says tails. -/
def tails : Ω := fun c => match c with
  | .text => fun _ => "" | .verdict => fun _ => 1 | .flag => fun _ => false | .ack => fun _ => ()

/-- A price that charges by addressee — per-call pricing with two vendors. It
satisfies `PricesByShape` exactly because the addressee is part of the shape,
and it is the witness that `PricesByShape` is not a vacuous hypothesis: `tick`
satisfies it by not reading the question at all, `byVendor` by reading only the
part of it the term fixes. -/
def byVendor : Price (Multiplicative Nat) :=
  fun _ q => Multiplicative.ofAdd (if q.addressee = Addressee.model "a" then 5 else 1)

theorem byVendor_pricesByShape : PricesByShape byVendor := by
  intro c q q' h
  have : q.addressee = q'.addressee := congrArg Q.Shape.addressee h
  simp [byVendor, this]

/-- **Kernel obligation C2, and it needs no hypothesis.** At
`level ≤ pipeline` the sequence of question shapes is not merely fixed by the
term but *computed from it*: `shapes p` is a fold over the syntax alone, and it
returns the shape sequence of the run, in every world and under every
environment.

**Why there is nothing to assume.** The kernel's C2 was refuted under a
representation in which `ask` carried an arbitrary `Expr Γ (Q c)`: an answer
could then choose the *addressee*, and the addressee is part of the shape. The
counterexample is no longer expressible. `Plan.ask` carries `s : Q.Shape c` as
term-level data and `e : Expr Γ String` as the words, and the `ask` case of this
induction is `congrArg₂ _ rfl …` — the shape on both sides is the literal `s`
written in the term. The side predicate that used to repair this theorem
(`ShapeStatic`, "the answer flows into the prompt text and nowhere else") is
deleted: it said of a term exactly what the term's type now says of itself.

The `ask` case of the induction is `simp [Plan.trace_ask, Event.shape]` and
nothing else: the shape recorded in the event is the literal `s` written in the
node. -/
theorem shapes_eq_trace_of_le_pipeline (p : Plan Γ A) (h : level p ≤ Level.pipeline) :
    ∀ (γ : Env Γ) (ω : Ω), shapes p = some ((Plan.trace ω p γ).map Event.shape) := by
  induction p with
  | ret e => intro γ ω; simp [shapes_ret, Plan.trace]
  | askC c q k ih =>
    intro γ ω
    rw [shapes_askC, ih h (.cons (ω c q) γ) ω]
    simp [Plan.trace_askC, Event.shape]
  | ask c s e k ih =>
    intro γ ω
    rw [shapes_ask, ih (le_of_ask h).2 (.cons (ω c (s.withPrompt (e γ))) γ) ω]
    simp [Plan.trace_ask, Event.shape]
  | case t e arms _ => exact absurd (le_of_case h).1 (by decide)
  | dyn b e f _ => exact absurd h (by simp only [level_dyn]; decide)

/-- …and the world-independence the kernel actually wrote, as its immediate
corollary: two runs of a `pipeline` plan, in any two worlds and under any two
environments, put questions of the same shapes in the same order. -/
theorem shapes_eq_of_le_pipeline (p : Plan Γ A) (h : level p ≤ Level.pipeline)
    (γ γ' : Env Γ) (ω ω' : Ω) :
    (Plan.trace ω p γ).map Event.shape = (Plan.trace ω' p γ').map Event.shape :=
  Option.some.inj
    ((shapes_eq_trace_of_le_pipeline p h γ ω).symm.trans
      (shapes_eq_trace_of_le_pipeline p h γ' ω'))

/-- Shape-equal question lists cost the same, when the price factors through the
shape. The induction compares the two lists position by position, and the
dependent pair is unpacked exactly as in `PricesByShape.key`. -/
theorem billOfKeys_eq_of_shape_eq [Monoid S] {price : Price S} (hp : PricesByShape price) :
    ∀ (ks ks' : List Key), ks.map Key.shape = ks'.map Key.shape →
      billOfKeys price ks = billOfKeys price ks' := by
  intro ks
  induction ks with
  | nil => intro ks' h; cases ks' with
    | nil => rfl
    | cons k' ks' => simp at h
  | cons k ks ih =>
    intro ks' h
    cases ks' with
    | nil => simp at h
    | cons k' ks' =>
      simp only [List.map_cons, List.cons.injEq] at h
      rw [billOfKeys_cons, billOfKeys_cons, hp.key k k' h.1, ih ks' h.2]

/-- Shape-equal transcripts cost the same. -/
theorem billFresh_eq_of_shape_eq [Monoid S] {price : Price S} (hp : PricesByShape price)
    {t t' : Trace} (h : t.map Event.shape = t'.map Event.shape) :
    billFresh price t = billFresh price t' := by
  refine billOfKeys_eq_of_shape_eq hp _ _ ?_
  rw [← Event.map_shape, ← Event.map_shape]
  exact h

/-- **The bill is world-independent at `pipeline`**, under the one hypothesis
that is left: the price factors through the shape. That the answers flow only
into the prompt is no longer a hypothesis but the shape of the `ask` node. -/
theorem bill_indep_of_le_pipeline [Monoid S] {price : Price S} (hp : PricesByShape price)
    (p : Plan Γ A) (h : level p ≤ Level.pipeline)
    (γ γ' : Env Γ) (ω ω' : Ω) :
    billFresh price (Plan.trace ω p γ) = billFresh price (Plan.trace ω' p γ') :=
  billFresh_eq_of_shape_eq hp (shapes_eq_of_le_pipeline p h γ γ' ω ω')

/-- The question fold is the transcript of the default world: this is the sense
in which `asks` is computable from the term. -/
theorem asks_eq_default (p : Plan Γ A) (h : level p ≤ Level.pipeline) :
    ∀ (γ : Env Γ), asks p γ = some ((Plan.trace ωDefault p γ).map Event.key) := by
  induction p with
  | ret e => intro γ; simp [asks_ret, Plan.trace]
  | askC c q k ih =>
    intro γ
    rw [asks_askC, ih h (.cons default γ)]
    simp [Plan.trace_askC, Event.key]
  | ask c s e k ih =>
    intro γ
    rw [asks_ask, ih (le_of_ask h).2 (.cons default γ)]
    simp [Plan.trace_ask, Event.key]
  | case t e arms _ => exact absurd (le_of_case h).1 (by decide)
  | dyn b e f _ => exact absurd h (by simp only [level_dyn]; decide)

/-- **Kernel obligation C2's bill, exact and unconditional beyond the price.**
At `level ≤ pipeline`, with a shape-factoring price, the bill is computed from
the term and is the bill of the run in *every* world.

This is directive (1)'s "exact value when monad is not necessary", stated where
it is true — and, since the shape repair, stated with the hypothesis that the
kernel actually asked for and nothing else. -/
theorem bill_exact_pipeline [Monoid S] {price : Price S} (hp : PricesByShape price)
    (p : Plan Γ A) (h : level p ≤ Level.pipeline) (γ : Env Γ) (ω : Ω) :
    asksBill price p γ = some (billFresh price (Plan.trace ω p γ)) := by
  rw [asksBill, asks_eq_default p h γ]
  exact congrArg _ (bill_indep_of_le_pipeline hp p h γ γ ωDefault ω)

/-! ## C3 — BRANCH: a finite bag of possible bills -/

/-- `[[costM price p h γ]]` = the finite bag of every bill `p` can run up: one
element per path through the branch structure with **both arms present**, priced.

The target is a **monoid semiring** and not a bespoke tree of leaves: `Multiset S`
is `ℕ⟨S⟩`, the natural-number-weighted formal sums over the price monoid, which
is the construction `Agentic/Panel.lean` writes `S⟨K⟩` with the coefficient and
key roles exchanged. The three non-`dyn` clauses are that semiring's operations:
`{1}` is the multiplicative unit (the point mass at `1`), an `ask` multiplies by
the point mass at its price, and a `case` is the *sum* — `Multiset.bind` over the
tag type, which on `ℕ⟨S⟩` is addition of the arms' weightings.

What a cost tree was for is the bag it had at its leaves; the fold produces that
bag directly, and `Multiset.card` counts the paths — a `Multiset` and not a
`List` or a `Finset` because the order of a branch's arms is not part of what a
cost analysis says while the *multiplicity* of a bill is (`Explain.leafBills`
prints it under that word, and two paths that cost the same are two paths).

Finite because `case`'s tag type is, which is the whole reason `case` is a
former and `dyn` is quarantined; `no_cost_tree_at_dyn` is that finiteness
failing at `dynamic`.

Defined **only** where it exists: the level bound is an argument, so "the
analysis applies at this rung" is the type of the fold rather than a side
condition on a theorem — the `dyn` clause is discharged by `absurd`, not by a
`none`. This is `E_grade_as_fold_works.lean`'s repair with the totality theorem
absorbed into the signature, and it is why `costM` is the one analysis in this
package that is not a `PlanAlg.fold`: an algebra carrier may not mention `p`.

```
costM (ret e)       γ = {1}
costM (askC c q k)  γ = map (price c q *)                     (costM k γ)
costM (ask c s e k) γ = map (price c (s.withPrompt (e γ)) *)  (costM k γ)
costM (case _ arms) γ = Finset.univ.val.bind (fun t => costM (arms t) γ)
```

The continuation is analysed under `default` answers. That is harmless because
an `ask` node writes its shape in the term: the *question* the analysis reads
may differ from the run's in its words, and a `PricesByShape` price cannot see
the difference. `bill_mem_leaves` is that argument. -/
def costM [CommMonoid S] (price : Price S) {A : Type} :
    {Γ : Ctx} → (p : Plan Γ A) → level p ≤ Level.branch → Env Γ → Multiset S
  | _, .ret _, _, _ => {1}
  | _, .askC c q k, h, γ => (costM price k h (.cons default γ)).map (price c q * ·)
  | _, .ask c s e k, h, γ =>
      (costM price k (le_of_ask h).2 (.cons default γ)).map (price c (s.withPrompt (e γ)) * ·)
  | _, .case _ _ arms, h, γ =>
      -- The tag's type is enumerated in the analyses; the bag sums over the
      -- `Fintype` Mathlib derives from that enumeration, which is the same
      -- finite set with the order forgotten.
      Finset.univ.val.bind (fun x => costM price (arms x) ((le_of_case h).2 x) γ)
  | _, .dyn _ _ _, h, _ => absurd h (by simp only [level_dyn]; decide)

/-- **Kernel obligation C3.** At `level ≤ branch`, with the one hypothesis that
`pipeline` needs, the bill of *every* run is one of the bag's elements.

The kernel writes this as `bill = evalTree (costTree p) (decisions p γ ω)`;
membership is that statement with the path existentially quantified — and the
existential is the whole reason the branch structure need not be carried, which
is why `costM` returns the bag and not a tree. It is what the bounds and the
budget subtype are proved from.

The `ask` case is where the shape repair pays: the analysis prices
`s.withPrompt (e γ')` and the run pays for `s.withPrompt (e γ)`, two questions
of the *same shape* `s`, so `PricesByShape` closes the gap with no side
condition on the term. -/
theorem bill_mem_leaves [CommMonoid S] {price : Price S} (hp : PricesByShape price) :
    ∀ {Γ : Ctx} {A : Type} (p : Plan Γ A) (h : level p ≤ Level.branch),
      ∀ (γ γ' : Env Γ) (ω : Ω),
        billFresh price (Plan.trace ω p γ) ∈ costM price p h γ' := by
  intro Γ A p
  induction p with
  | ret e => intro h γ γ' ω; simp [costM, Plan.trace]
  | askC c q k ih =>
    intro h γ γ' ω
    simp only [costM, Plan.trace_askC, billFresh_cons]
    exact Multiset.mem_map_of_mem _ (ih h _ _ ω)
  | ask c s e k ih =>
    intro h γ γ' ω
    simp only [costM, Plan.trace_ask, billFresh_cons]
    rw [hp c (s.withPrompt (e γ)) (s.withPrompt (e γ')) rfl]
    exact Multiset.mem_map_of_mem _ (ih (le_of_ask h).2 _ _ ω)
  | case t e arms ih =>
    intro h γ γ' ω
    rw [Plan.trace, denote_case]
    refine Multiset.mem_bind.mpr ⟨e γ, Finset.mem_univ_val _, ?_⟩
    exact ih (e γ) ((le_of_case h).2 _) γ γ' ω
  | dyn b e f hdyn => intro h; exact absurd h (by simp only [level_dyn]; decide)

/-! ### The tropical folds, and the bounds they give -/

section Tropical

variable [CommMonoid S] [LinearOrder S]

/-- `[[minFold m]]` = the cheapest bill the bag admits: the fold at the min-plus
tropical semiring, in `WithTop S` because an arm-less branch admits none — and
`Multiset.inf ∅ = ⊤` is exactly that "none", printed `—` by `Explain.sayNat?`.

`Multiset.inf` and not `Finset.inf`: the bag is not a set, but `inf` does not
care about multiplicity, so the two agree wherever both are defined. -/
def minFold (m : Multiset S) : WithTop S :=
  Multiset.inf (m.map (fun s : S => (s : WithTop S)))

/-- `[[maxFold m]]` = the dearest bill the bag admits: the fold at the max-plus
tropical semiring. The pair `(minFold, maxFold)` is the fold at their product,
which is the interval the doctrine's toolbox row asks for. -/
def maxFold (m : Multiset S) : WithBot S :=
  Multiset.sup (m.map (fun s : S => (s : WithBot S)))

omit [CommMonoid S] in
theorem minFold_le_of_mem (m : Multiset S) {s : S} (hs : s ∈ m) :
    minFold m ≤ (s : WithTop S) :=
  Multiset.inf_le (Multiset.mem_map_of_mem _ hs)

omit [CommMonoid S] in
theorem le_maxFold_of_mem (m : Multiset S) {s : S} (hs : s ∈ m) :
    (s : WithBot S) ≤ maxFold m :=
  Multiset.le_sup (Multiset.mem_map_of_mem _ hs)

/-- **The bounds are sound**: every run's bill lies in the bag's interval. -/
theorem minFold_le_bill {price : Price S} (hp : PricesByShape price) (p : Plan Γ A)
    (h : level p ≤ Level.branch) (γ : Env Γ) (ω : Ω) :
    minFold (costM price p h γ) ≤ ((billFresh price (Plan.trace ω p γ) : S) : WithTop S) :=
  minFold_le_of_mem _ (bill_mem_leaves hp p h γ γ ω)

theorem bill_le_maxFold {price : Price S} (hp : PricesByShape price) (p : Plan Γ A)
    (h : level p ≤ Level.branch) (γ : Env Γ) (ω : Ω) :
    ((billFresh price (Plan.trace ω p γ) : S) : WithBot S) ≤ maxFold (costM price p h γ) :=
  le_maxFold_of_mem _ (bill_mem_leaves hp p h γ γ ω)

/-- **Best and worst case are attained** — by *worlds*, which is what a budget
argument needs and what the kernel asks for.

Note what does the work: the bag makes the set of achievable bills finite, and
a nonempty finite set in a linear order has a least element. The kernel's
version of this theorem attains `minFold`, and that is false
(`minFold_not_attained`); this is the true statement in its place. -/
theorem exists_min_bill {price : Price S} (hp : PricesByShape price) (p : Plan Γ A)
    (h : level p ≤ Level.branch) (γ : Env Γ) :
    ∃ ω₀ : Ω, ∀ ω : Ω,
      billFresh price (Plan.trace ω₀ p γ) ≤ billFresh price (Plan.trace ω p γ) := by
  set f : Ω → S := fun ω => billFresh price (Plan.trace ω p γ) with hf
  have hsub : Set.range f ⊆ {x | x ∈ costM price p h γ} := by
    rintro _ ⟨ω, rfl⟩
    exact bill_mem_leaves hp p h γ γ ω
  have hfin : (Set.range f).Finite :=
    Set.Finite.subset (Multiset.finite_toSet _) hsub
  have hne : hfin.toFinset.Nonempty :=
    ⟨f ωDefault, hfin.mem_toFinset.mpr ⟨ωDefault, rfl⟩⟩
  obtain ⟨b, hb, hmin⟩ := hfin.toFinset.exists_min_image id hne
  obtain ⟨ω₀, rfl⟩ := hfin.mem_toFinset.mp hb
  exact ⟨ω₀, fun ω => hmin (f ω) (hfin.mem_toFinset.mpr ⟨ω, rfl⟩)⟩

theorem exists_max_bill {price : Price S} (hp : PricesByShape price) (p : Plan Γ A)
    (h : level p ≤ Level.branch) (γ : Env Γ) :
    ∃ ω₁ : Ω, ∀ ω : Ω,
      billFresh price (Plan.trace ω p γ) ≤ billFresh price (Plan.trace ω₁ p γ) := by
  set f : Ω → S := fun ω => billFresh price (Plan.trace ω p γ) with hf
  have hsub : Set.range f ⊆ {x | x ∈ costM price p h γ} := by
    rintro _ ⟨ω, rfl⟩
    exact bill_mem_leaves hp p h γ γ ω
  have hfin : (Set.range f).Finite :=
    Set.Finite.subset (Multiset.finite_toSet _) hsub
  have hne : hfin.toFinset.Nonempty :=
    ⟨f ωDefault, hfin.mem_toFinset.mpr ⟨ωDefault, rfl⟩⟩
  obtain ⟨b, hb, hmax⟩ := hfin.toFinset.exists_max_image id hne
  obtain ⟨ω₁, rfl⟩ := hfin.mem_toFinset.mp hb
  exact ⟨ω₁, fun ω => hmax (f ω) (hfin.mem_toFinset.mpr ⟨ω, rfl⟩)⟩

end Tropical

/-! ### …and the arm no world takes -/

/-- A question to charge for. -/
def ackQ (n : Nat) : Q .ack := { addressee := .tool "tick", scope := 1, prompt := "", draw := n }

/-- A branch whose tag mentions no answer, so one arm is unreachable — and the
unreachable arm is the cheap one. -/
def constBranch : Plan [] Unit :=
  Plan.caseB (fun _ => true) (.askC .ack (ackQ 0) (.ret (fun _ => ()))) (.ret (fun _ => ()))

theorem level_constBranch : level constBranch ≤ Level.branch := by decide

/-- Every world pays for the one consultation on the taken path. -/
theorem bill_constBranch (ω : Ω) :
    billFresh tick (Plan.trace ω constBranch Env.nil) = Multiplicative.ofAdd 1 := rfl

/-- The unreachable arm's bill is in the bag all the same. -/
theorem one_mem_leaves_constBranch :
    (1 : Multiplicative Nat) ∈ costM tick constBranch level_constBranch Env.nil := by
  decide

/-- **The kernel's attainment claim is false.** The tree's minimum is not
attained by any world, because the arm that realizes it is not reachable: the
tag is a constant. The bounds stay sound (`minFold_le_bill`); what is withdrawn
is that they are tight.

`exists_min_bill` is the repair — the extreme of the *achievable* bills is
attained — and the gap between the two is precisely the reachability analysis
that this kernel does not do (kernel open question 1). -/
theorem minFold_not_attained (ω : Ω) :
    minFold (costM tick constBranch level_constBranch Env.nil)
      ≠ ((billFresh tick (Plan.trace ω constBranch Env.nil) :
          Multiplicative Nat) : WithTop (Multiplicative Nat)) := by
  intro heq
  have hle := minFold_le_of_mem _ one_mem_leaves_constBranch
  rw [heq, bill_constBranch] at hle
  revert hle
  decide

/-! ## C4 — DYNAMIC: the honest non-existence -/

/-- `[[ticks n]]` = `n` closed consultations, each a different draw. Ordinary
`Nat.rec` in the metalanguage building an unrolled plan (§3 q5), and the vehicle
for making a `dyn` plan's bill unbounded. -/
def ticks : {Γ : Ctx} → Nat → Plan Γ Unit
  | _, 0 => .ret (fun _ => ())
  | _, n + 1 => .askC .ack (ackQ n) (ticks n)

theorem length_trace_ticks (ω : Ω) :
    ∀ (n : Nat) {Γ : Ctx} (γ : Env Γ), (Plan.trace ω (ticks n) γ).length = n := by
  intro n
  induction n with
  | zero => intro Γ γ; rfl
  | succ n ih => intro Γ γ; simp [ticks, Plan.trace_askC, ih]

/-- The question whose answer decides how much work there is. -/
def sizeQ : Q .text := { addressee := .tool "ls", scope := 1, prompt := "how many?", draw := 0 }

/-- **A `dyn` plan whose bill is unbounded.** One closed question, then a plan
*computed from* the answer: the residue `case` cannot reach, and the reason
`dyn` is quarantined rather than deleted. -/
def unbounded : Plan [] Unit :=
  .askC .text sizeQ (.dyn .text (fun γ => γ.head) (fun s => ticks s.length))

theorem level_unbounded : level unbounded = Level.dynamic := rfl

/-- The world whose answer is `n` characters long. -/
def sayLong (n : Nat) : Ω := fun c => match c with
  | .text => fun _ => String.ofList (List.replicate n 'a')
  | .verdict => fun _ => 1
  | .flag => fun _ => false
  | .ack => fun _ => ()

theorem bill_unbounded (n : Nat) :
    billFresh tick (Plan.trace (sayLong n) unbounded Env.nil) = Multiplicative.ofAdd (n + 1) := by
  have hlen : (Plan.trace (sayLong n) unbounded Env.nil).length = n + 1 := by
    have hstr : (sayLong n .text sizeQ).length = n := by simp [sayLong]
    rw [unbounded, Plan.trace_askC, List.length_cons, Plan.trace, denote_dyn]
    simp only [Env.head_cons, hstr]
    exact congrArg (· + 1) (length_trace_ticks (sayLong n) n _)
  rw [billFresh_tick, hlen]

/-- **Kernel obligation C4, strengthened — and stated as the witness it is.**
For the plan `unbounded` there is no finite set of possible bills, so for that
plan there is no `costM`, no interval and no static bill: the answer chooses
how much work there is, and answers are unbounded.

Read the quantifier carefully. This is a theorem about *one* `dyn` plan, not a
universal over the rung: `dyn (const b) (fun _ => ret e)` is `dynamic` and costs
nothing, and no theorem here says otherwise. What separates the rungs is that
`dynamic` **admits** a plan like this one while `branch` does not
(`no_cost_tree_at_dyn` plus `bill_mem_leaves`), which is exactly why no analysis
is licensed at `dynamic` — a fold defined there would have to be sound for this
plan too.

The kernel's own formulation ("no `Φ : Plan → S` returns the bill") is *also*
true at `branch`, where the bill genuinely varies with the world, so it does not
distinguish `dyn` from `case`; the failure of finiteness does. -/
theorem no_finite_bill_set_at_dyn :
    ¬ ∃ L : List (Multiplicative Nat),
        ∀ ω : Ω, billFresh tick (Plan.trace ω unbounded Env.nil) ∈ L := by
  rintro ⟨L, hL⟩
  have hsub : Set.range (fun n : Nat => Multiplicative.ofAdd (n + 1)) ⊆ {x | x ∈ L} := by
    rintro _ ⟨n, rfl⟩
    have := hL (sayLong n)
    rwa [bill_unbounded n] at this
  have hinj : Function.Injective (fun n : Nat => Multiplicative.ofAdd (n + 1)) := by
    intro a b hab
    simpa using hab
  exact Set.infinite_range_of_injective hinj (Set.Finite.subset (List.finite_toSet _) hsub)

/-- **Hence C3 does not extend**: no cost analysis of any shape describes *this*
`dyn` plan, because `costM` returns a `Multiset` and a `Multiset` is finite. The
bag is not merely *uncomputable* for it; it does not exist. And a `costM`
defined at `dynamic` would have to cover this plan, which is why the fold's
signature stops at `branch`.

Quantifying over `Multiset` rather than over the cost *tree* this package used
to carry is a strengthening, not a weakening: a tree's leaves were a `Multiset`,
so a tree meeting the old statement supplies a bag meeting this one. What the
old formulation added was the branch structure, and no step of the argument ever
looked at it — finiteness of the leaf bag is the whole content. -/
theorem no_cost_tree_at_dyn :
    ¬ ∃ m : Multiset (Multiplicative Nat),
        ∀ ω : Ω, billFresh tick (Plan.trace ω unbounded Env.nil) ∈ m := by
  rintro ⟨m, hm⟩
  refine no_finite_bill_set_at_dyn ?_
  classical
  exact ⟨m.toList, fun ω => Multiset.mem_toList.mpr (hm ω)⟩

/-- `[[StaticBill price]]` = there is a function of the term alone that returns
the bill of every run of it. This is the property the kernel's C4 denies at
`dynamic`. -/
def StaticBill [Monoid S] (price : Price S) : Prop :=
  ∃ Φ : ∀ (Γ : Ctx) (A : Type), Plan Γ A → S,
    ∀ (Γ : Ctx) (A : Type) (p : Plan Γ A) (γ : Env Γ) (ω : Ω),
      Φ Γ A p = billFresh price (Plan.trace ω p γ)

/-- The kernel's own C4, as a corollary of unboundedness: two worlds are enough,
which is exactly why this statement is weaker than the one above. -/
theorem no_static_bill_at_dyn : ¬ StaticBill tick := by
  rintro ⟨Φ, hΦ⟩
  have h0 := hΦ [] Unit unbounded Env.nil (sayLong 0)
  have h1 := hΦ [] Unit unbounded Env.nil (sayLong 1)
  rw [bill_unbounded 0] at h0
  rw [bill_unbounded 1] at h1
  rw [h0] at h1
  exact absurd h1 (by decide)

/-- A branch whose tag **is** an answer, so both arms are reachable and the two
bills differ. -/
def coinBranch : Plan [] Unit :=
  .askC .flag coinQ (Plan.caseB (fun γ => (γ.head : Bool))
    (.askC .ack (ackQ 0) (.ret (fun _ => ()))) (.ret (fun _ => ())))

theorem level_coinBranch : level coinBranch ≤ Level.branch := by decide

theorem bill_coinBranch_heads :
    billFresh tick (Plan.trace heads coinBranch Env.nil) = Multiplicative.ofAdd 2 := by
  rw [billFresh_tick]; rfl

theorem bill_coinBranch_tails :
    billFresh tick (Plan.trace tails coinBranch Env.nil) = Multiplicative.ofAdd 1 := by
  rw [billFresh_tick]; rfl

/-- **…and the kernel's C4 formulation does not separate the rungs.** It already
fails at `branch`, on a plan whose cost tree exists and is exact, because the
bill of a *branching* plan genuinely varies with the world. That is why
`no_finite_bill_set_at_dyn` — and not this — is the theorem that says what
`dyn` costs. -/
theorem no_static_bill_at_branch : ¬ StaticBill tick := by
  rintro ⟨Φ, hΦ⟩
  have h0 := hΦ [] Unit coinBranch Env.nil heads
  have h1 := hΦ [] Unit coinBranch Env.nil tails
  rw [bill_coinBranch_heads] at h0
  rw [bill_coinBranch_tails] at h1
  rw [h0] at h1
  exact absurd h1 (by decide)

/-! ## Budgets as types

Kernel §4's closing claim — "budgets as types follow from C1–C3 without new
machinery" — machine-checked. Unlike a budget over a HOAS carrier, the defining
function exists: `maxFold ∘ costM` is a computable fold of a first-order
term, needing no `Fintype (El c)` and therefore defined for free-text answers
(`G_cost_needs_fintype.lean` is what happens otherwise). -/

/-- `[[PlanUpTo price β A]]` = the plans that cannot cost more than `β`: a
closed plan at or below `branch` whose dearest path is within budget.

Two conditions where there used to be three: "the answers flow only into
prompts" was the third, and it is now the type of the `ask` node.

`Type 0`, like everything else here, since the closed tag universe put `Plan`
there: the analysis carrier is `Multiset S`, which was always `Type 0`. -/
def PlanUpTo [CommMonoid S] [LinearOrder S] (price : Price S) (β : S) (A : Type) : Type :=
  { p : Plan [] A // ∃ h : level p ≤ Level.branch,
      maxFold (costM price p h Env.nil) ≤ (β : WithBot S) }

/-- **And the budget is honoured, in every world.** The subtype's defining
condition is about the term; the conclusion is about every run. -/
theorem PlanUpTo.bill_le [CommMonoid S] [LinearOrder S] {price : Price S}
    (hp : PricesByShape price) {β : S} {A : Type} (p : PlanUpTo price β A) (ω : Ω) :
    billFresh price (Plan.trace ω p.1 Env.nil) ≤ β := by
  obtain ⟨p, h, hβ⟩ := p
  have := le_trans (bill_le_maxFold hp p h Env.nil ω) hβ
  exact WithBot.coe_le_coe.mp this

/-! ## The workloads, billed

The two acceptance workloads of `Agentic/Core/Denote.lean`, priced. They are
what kernel §4 means by "directive (1) is satisfied on all six workloads in the
brief": the sharing example is exact at `pipeline`, and bounded revision is a
finite tree at `branch`. -/

namespace Acceptance

/-- The owner's own example — two reviewers sharing one reading of a style
guide — is `pipeline`: content-dependent prompts, no branching, no `dyn`. -/
theorem level_sharedGuide : level sharedGuide = Level.pipeline := rfl

/-- **The bill is exact, in every world**: three consultations, priced from the
term, with the guide read once. This is the workload `attack-adequacy` §1 says
no applicative kernel can carry and no proposal in the dossier bills. -/
theorem bill_sharedGuide (ω : Ω) :
    billFresh tick (Plan.trace ω sharedGuide Env.nil) = Multiplicative.ofAdd 3 := by
  rw [billFresh_tick, trace_sharedGuide]
  rfl

/-- Bounded revision is `branch`, and its tree is finite: the acceptance
workload comes out where kernel §6 says it must. -/
theorem level_upToTwice_le : level upToTwice ≤ Level.branch := le_of_eq level_upToTwice

end Acceptance

end Agentic.Core
