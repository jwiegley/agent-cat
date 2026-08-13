import Agentic.Core.Level
import Mathlib.Algebra.BigOperators.Group.List.Lemmas
import Mathlib.Algebra.Order.BigOperators.Group.List
import Mathlib.Algebra.Order.Monoid.Unbundled.TypeTags
import Mathlib.Data.Finset.Lattice.Fold
import Mathlib.Data.Finset.Max
import Mathlib.Data.List.Dedup
import Mathlib.Data.Multiset.Bind
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
| `pipeline` | the exact count and code sequence; and, under `ShapeStatic` + `PricesByShape`, the exact bill | `codes_eq_of_le_pipeline`, `bill_exact_pipeline` |
| `branch` | a finite `CostTree` containing the bill; bounds; best and worst case attained | `bill_mem_leaves`, `minFold_le_bill`, `exists_min_bill` |
| `dynamic` | **nothing**: no finite set of bills exists at all | `no_finite_bill_set_at_dyn` |

## Three corrections to the kernel, each machine-checked

1. **C2 as written is false.** The kernel claims that at `level ≤ pipeline` the
   sequence of question *shapes* is world-independent. It is not: `ask`'s
   question is an arbitrary `Expr Γ (Q c)`, so an earlier answer can select the
   *addressee*, and `shape` includes the addressee. `shapes_not_world_indep`
   exhibits the two-line counterexample, and `bill_not_world_indep` upgrades it
   to two different bills under a price that does satisfy `PricesByShape`. The
   repair is the missing hypothesis `ShapeStatic`: an answer may flow into the
   *prompt text* and nowhere else. That is exactly the domain's pivot (§2.3:
   "the prompt is a function of an earlier answer"), it is a property of the
   term, and under it C2 is true — `bill_exact_pipeline`.

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
   statement that does is
   `no_finite_bill_set_at_dyn`: at `dynamic` there is no finite *set* of
   possible bills, hence no `CostTree` of any shape — which is precisely the
   negation of C3 and the honest replacement for `Frag`.

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

/-! ## The shape of a question: everything except the prompt -/

/-- `[[Shape]]` = what a question is, minus what it says: the code of the answer
asked for, the addressee, the standing conditions and the draw index.

This is the finite quotient of question space that `attack-adequacy` §7 says all
four re-derivations needed and none stated. Per-call and per-latency pricing
factor through it; per-token pricing does not, and for per-token pricing the
honest output is an interval keyed to a token bound carried in the answer type
(kernel §2.5). -/
structure Shape where
  /-- The kind of answer asked for. -/
  code : Code
  /-- Who is being asked. -/
  addressee : Addressee
  /-- Under what standing conditions. -/
  scope : QScope
  /-- Which independent draw this is. -/
  draw : Nat
  deriving DecidableEq

/-- `[[q.shape]]` = the question with its prompt forgotten. -/
def Q.shape {c : Code} (q : Q c) : Shape := ⟨c, q.addressee, q.scope, q.draw⟩

@[simp] theorem Q.shape_code {c : Code} (q : Q c) : q.shape.code = c := rfl

@[simp] theorem Q.shape_addressee {c : Code} (q : Q c) : q.shape.addressee = q.addressee := rfl

/-- **Morphism equation.** `shape` forgets the prompt and *only* the prompt: two
questions with one shape and one prompt are the same question. This is what
makes `ShapeStatic` below say "the answer flows into the prompt text and nowhere
else" rather than something weaker. -/
theorem Q.eq_of_shape_of_prompt {c : Code} {q q' : Q c}
    (hs : q.shape = q'.shape) (hp : q.prompt = q'.prompt) : q = q' := by
  obtain ⟨a, s, pr, d⟩ := q
  obtain ⟨a', s', pr', d'⟩ := q'
  simp only [Q.shape, Shape.mk.injEq] at hs
  simp only [Q.mk.injEq]
  exact ⟨hs.2.1, hs.2.2.1, hp, hs.2.2.2⟩

/-! ## Keys: a question with its code, which is what a price is a function of -/

/-- `[[Key]]` = a question together with the code it asks for: a point of
question space, forgetting the answer. This is the key of the memo table, the
key of a content-addressed cache, and the argument of a price — three uses of
one object (§3 q1). -/
abbrev Key : Type := (c : Code) × Q c

/-- The question an event put. -/
def Event.key (e : Event) : Key := ⟨e.c, e.q⟩

/-- The shape of a key. -/
def Key.shape (k : Key) : Shape := k.2.shape

/-- The shape of the question an event put. -/
def Event.shape (e : Event) : Shape := e.q.shape

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
bounded one. -/
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
  exact hp c q q' h

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

/-- `[[codes p]]` = the sequence of answer codes `p` will ask for, if that
sequence is fixed by the term.

`none` at `case` and `dyn` — where it is not — and a fold of the term *alone*
elsewhere: no environment, no world. -/
def codes : {Γ : Ctx} → {A : Type} → Plan Γ A → Option (List Code)
  | _, _, .ret _ => some []
  | _, _, .askC c _ k => (c :: ·) <$> codes k
  | _, _, .ask c _ k => (c :: ·) <$> codes k
  | _, _, @Plan.case _ _ _ _ _ _ _ => none
  | _, _, .dyn _ _ => none

/-- `[[asks p γ]]` = the list of questions `p` will put, evaluated with the
least informative answers.

An environment is needed because an `ask` builds its question from the answers
in scope; `default` stands in for those answers, and the two theorems below say
exactly when that substitution is harmless: always at `batch` (there are no
`ask` nodes), and up to shape at `pipeline` under `ShapeStatic`. -/
def asks : {Γ : Ctx} → {A : Type} → Plan Γ A → Env Γ → Option (List Key)
  | _, _, .ret _, _ => some []
  | _, _, .askC c q k, γ => (⟨c, q⟩ :: ·) <$> asks k (.cons default γ)
  | _, _, .ask c e k, γ => (⟨c, e γ⟩ :: ·) <$> asks k (.cons default γ)
  | _, _, @Plan.case _ _ _ _ _ _ _, _ => none
  | _, _, .dyn _ _, _ => none

/-- `[[asksBill price p γ]]` = the bill read off the term, without running it.

The kernel writes this fold `asks price p`, and the two obligations it appears
in — `bill_exact_batch` and `bill_exact_pipeline` — are the equation
`bill price (trace ω (den p γ)) = asks price p` at the two rungs where it
holds. -/
def asksBill [Monoid S] (price : Price S) {Γ : Ctx} {A : Type} (p : Plan Γ A) (γ : Env Γ) :
    Option S :=
  (asks p γ).map (billOfKeys price)

variable {Γ Δ : Ctx} {A B : Type}

/-- **C5, first half.** The question fold is total on the pipeline fragment: the
level being `≤ pipeline` is not a side condition on the analysis, it is the
statement that the analysis is defined. -/
theorem asks_isSome_of_le_pipeline (p : Plan Γ A) (h : level p ≤ Level.pipeline) (γ : Env Γ) :
    (asks p γ).isSome := by
  induction p with
  | ret e => simp [asks]
  | askC c q k ih => simpa [asks, Option.isSome_map] using ih h _
  | ask c e k ih => simpa [asks, Option.isSome_map] using ih (le_of_ask h).2 _
  | case e arms _ => exact absurd (le_of_case h).1 (by decide)
  | dyn e f _ => exact absurd h (by simp only [level_dyn]; decide)

/-- The code fold is total there too. -/
theorem codes_isSome_of_le_pipeline (p : Plan Γ A) (h : level p ≤ Level.pipeline) :
    (codes p).isSome := by
  induction p with
  | ret e => simp [codes]
  | askC c q k ih => simpa [codes, Option.isSome_map] using ih h
  | ask c e k ih => simpa [codes, Option.isSome_map] using ih (le_of_ask h).2
  | case e arms _ => exact absurd (le_of_case h).1 (by decide)
  | dyn e f _ => exact absurd h (by simp only [level_dyn]; decide)

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
  | ret e => intro γ γ' ω; simp [asks, Plan.trace]
  | askC c q k ih =>
    intro γ γ' ω
    rw [asks, ih h (.cons default γ) (.cons (ω c q) γ') ω]
    simp [Plan.trace_askC, Event.key]
  | ask c e k _ => exact absurd (le_of_ask h).1 (by decide)
  | case e arms _ => exact absurd (le_of_case h).1 (by decide)
  | dyn e f _ => exact absurd h (by simp only [level_dyn]; decide)

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
`pipeline` (kernel open question 3). -/
theorem bill_exact_batch [Monoid S] (price : Price S) (p : Plan Γ A)
    (h : level p ≤ Level.batch) (γ : Env Γ) (ω : Ω) :
    asksBill price p γ = some (billFresh price (Plan.trace ω p γ)) := by
  rw [asksBill, asks_eq_of_le_batch p h γ γ ω]
  rfl

/-! ## C2 — PIPELINE: the exact count and code sequence -/

/-- **Kernel obligation C2, the half that is unconditionally true.** At
`level ≤ pipeline` the sequence of answer codes — and hence the number of
consultations — is fixed by the term: no world and no environment can change it.

This is the honest core of the pipeline guarantee. What is *not* true without a
further hypothesis is the kernel's claim about shapes; see
`shapes_not_world_indep`. -/
theorem codes_eq_of_le_pipeline (p : Plan Γ A) (h : level p ≤ Level.pipeline) :
    ∀ (γ : Env Γ) (ω : Ω), codes p = some ((Plan.trace ω p γ).map Event.c) := by
  induction p with
  | ret e => intro γ ω; simp [codes, Plan.trace]
  | askC c q k ih =>
    intro γ ω
    rw [codes, ih h (.cons (ω c q) γ) ω]
    simp [Plan.trace_askC]
  | ask c e k ih =>
    intro γ ω
    rw [codes, ih (le_of_ask h).2 (.cons (ω c (e γ)) γ) ω]
    simp [Plan.trace_ask]
  | case e arms _ => exact absurd (le_of_case h).1 (by decide)
  | dyn e f _ => exact absurd h (by simp only [level_dyn]; decide)

/-- **`#asks` is constant across worlds at `pipeline`** — the count the owner
asks for, before the run, with no hypothesis on the price. -/
theorem length_trace_eq_of_le_pipeline (p : Plan Γ A) (h : level p ≤ Level.pipeline)
    (γ : Env Γ) (ω ω' : Ω) :
    (Plan.trace ω p γ).length = (Plan.trace ω' p γ).length := by
  have h₁ := codes_eq_of_le_pipeline p h γ ω
  have h₂ := codes_eq_of_le_pipeline p h γ ω'
  have := Option.some.inj (h₁.symm.trans h₂)
  simpa using congrArg List.length this

/-! ## …and the half that is false, with the counterexample and the repair -/

/-- A coin to consult. -/
def coinQ : Q .flag := { addressee := .tool "coin", scope := 1, prompt := "heads?", draw := 0 }

/-- Two reviewers, differing in *addressee* — which is part of the shape. -/
def reviewerA : Q .text := { addressee := .model "a", scope := 1, prompt := "?", draw := 0 }

/-- The other reviewer. -/
def reviewerB : Q .text := { addressee := .model "b", scope := 1, prompt := "?", draw := 0 }

/-- A `pipeline` plan whose second question's **addressee** is chosen by the
first answer. Nothing here is exotic: `ask` takes an arbitrary `Expr Γ (Q c)`,
and the addressee is a field of `Q`. -/
def shifty : Plan [] String :=
  .askC .flag coinQ (.ask .text (fun γ => cond (γ.head : Bool) reviewerA reviewerB)
    (.ret (Expr.var .here)))

theorem level_shifty : level shifty = Level.pipeline := rfl

/-- The world that says heads. -/
def heads : Ω := fun c => match c with
  | .text => fun _ => "" | .verdict => fun _ => 1 | .flag => fun _ => true | .ack => fun _ => ()

/-- The world that says tails. -/
def tails : Ω := fun c => match c with
  | .text => fun _ => "" | .verdict => fun _ => 1 | .flag => fun _ => false | .ack => fun _ => ()

/-- **The kernel's C2 is false as written.** At `level ≤ pipeline` the sequence
of question *shapes* is not world-independent, because an answer may select the
addressee and the addressee is part of the shape.

Recorded in code, next to the repaired theorem, because the kernel's exact-bill
claim at `pipeline` rests on it. -/
theorem shapes_not_world_indep :
    (Plan.trace heads shifty Env.nil).map Event.shape
      ≠ (Plan.trace tails shifty Env.nil).map Event.shape := by
  decide

/-- A price that charges by addressee — per-call pricing with two vendors. It
satisfies `PricesByShape` exactly because the addressee is part of the shape. -/
def byVendor : Price (Multiplicative Nat) :=
  fun _ q => Multiplicative.ofAdd (if q.addressee = Addressee.model "a" then 5 else 1)

theorem byVendor_pricesByShape : PricesByShape byVendor := by
  intro c q q' h
  have : q.addressee = q'.addressee := congrArg Shape.addressee h
  simp [byVendor, this]

/-- **…and the bill really does move.** `PricesByShape` alone does not buy an
exact bill at `pipeline`: this is `attack-adequacy` §7's missing hypothesis
being missing in the other direction, and it is why `ShapeStatic` below is not
bookkeeping. -/
theorem bill_not_world_indep :
    billFresh byVendor (Plan.trace heads shifty Env.nil)
      ≠ billFresh byVendor (Plan.trace tails shifty Env.nil) := by
  decide

/-- `[[ShapeStatic p]]` = every question `p` builds from an answer varies only
in its **prompt text**: the addressee, the scope and the draw are fixed by the
term.

The missing hypothesis, and it is exactly the domain's pivot: "the prompt is a
function of an earlier answer" (kernel §2.3). It is a property of the term — of
each `ask` node's `Expr` — not of a trace and not of a runtime, so a checker can
demand it and an author can read it. By `Q.eq_of_shape_of_prompt` it says
precisely that the answer flows into the prompt and nowhere else. -/
def ShapeStatic : {Γ : Ctx} → {A : Type} → Plan Γ A → Prop
  | _, _, .ret _ => True
  | _, _, .askC _ _ k => ShapeStatic k
  | _, _, .ask _ e k => (∀ γ γ', (e γ).shape = (e γ').shape) ∧ ShapeStatic k
  | _, _, @Plan.case _ _ _ _ _ _ arms => ∀ t, ShapeStatic (arms t)
  | _, _, .dyn _ f => ∀ b, ShapeStatic (f b)

@[simp] theorem shapeStatic_ret (e : Expr Γ A) : ShapeStatic (Plan.ret e) := by
  simp [ShapeStatic]

@[simp] theorem shapeStatic_askC (c : Code) (q : Q c) (k : Plan (c :: Γ) A) :
    ShapeStatic (Plan.askC c q k) ↔ ShapeStatic k := by simp [ShapeStatic]

@[simp] theorem shapeStatic_ask (c : Code) (e : Expr Γ (Q c)) (k : Plan (c :: Γ) A) :
    ShapeStatic (Plan.ask c e k) ↔ (∀ γ γ', (e γ).shape = (e γ').shape) ∧ ShapeStatic k := by
  simp [ShapeStatic]

@[simp] theorem shapeStatic_case {T : Type} [Fintype T] [DecidableEq T]
    (e : Expr Γ T) (arms : T → Plan Γ A) :
    ShapeStatic (Plan.case e arms) ↔ ∀ t, ShapeStatic (arms t) := by simp [ShapeStatic]

/-- A closed question is shape-static for free, so `batch` plans satisfy the
hypothesis vacuously and C1 is the `ShapeStatic`-free special case of C2. -/
theorem shapeStatic_of_le_batch (p : Plan Γ A) (h : level p ≤ Level.batch) : ShapeStatic p := by
  induction p with
  | ret e => simp
  | askC c q k ih => exact ih h
  | ask c e k _ => exact absurd (le_of_ask h).1 (by decide)
  | case e arms _ => exact absurd (le_of_case h).1 (by decide)
  | dyn e f _ => exact absurd h (by simp only [level_dyn]; decide)

/-- **Kernel obligation C2, repaired.** At `level ≤ pipeline`, if answers flow
only into prompt text, then the sequence of question shapes is fixed by the
term: no world and no environment can change it.

The statement quantifies over *two* environments as well as two worlds, because
that is what the induction needs — at each `ask` the continuations run in
environments that already differ. -/
theorem shapes_eq_of_le_pipeline (p : Plan Γ A) (h : level p ≤ Level.pipeline)
    (hs : ShapeStatic p) :
    ∀ (γ γ' : Env Γ) (ω ω' : Ω),
      (Plan.trace ω p γ).map Event.shape = (Plan.trace ω' p γ').map Event.shape := by
  induction p with
  | ret e => intro γ γ' ω ω'; rfl
  | askC c q k ih =>
    intro γ γ' ω ω'
    simp only [Plan.trace_askC, List.map_cons]
    exact congrArg _ (ih h (shapeStatic_askC c q k |>.mp hs) _ _ _ _)
  | ask c e k ih =>
    intro γ γ' ω ω'
    obtain ⟨hshape, hrest⟩ := (shapeStatic_ask c e k).mp hs
    simp only [Plan.trace_ask, List.map_cons]
    exact congrArg₂ _ (hshape γ γ') (ih (le_of_ask h).2 hrest _ _ _ _)
  | case e arms _ => exact absurd (le_of_case h).1 (by decide)
  | dyn e f _ => exact absurd h (by simp only [level_dyn]; decide)

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

/-- **The bill is world-independent at `pipeline`**, under the two hypotheses
that are jointly necessary: the price factors through the shape, and the answers
flow only into the prompt. -/
theorem bill_indep_of_le_pipeline [Monoid S] {price : Price S} (hp : PricesByShape price)
    (p : Plan Γ A) (h : level p ≤ Level.pipeline) (hs : ShapeStatic p)
    (γ γ' : Env Γ) (ω ω' : Ω) :
    billFresh price (Plan.trace ω p γ) = billFresh price (Plan.trace ω' p γ') :=
  billFresh_eq_of_shape_eq hp (shapes_eq_of_le_pipeline p h hs γ γ' ω ω')

/-- The question fold is the transcript of the default world: this is the sense
in which `asks` is computable from the term. -/
theorem asks_eq_default (p : Plan Γ A) (h : level p ≤ Level.pipeline) :
    ∀ (γ : Env Γ), asks p γ = some ((Plan.trace ωDefault p γ).map Event.key) := by
  induction p with
  | ret e => intro γ; simp [asks, Plan.trace]
  | askC c q k ih =>
    intro γ
    rw [asks, ih h (.cons default γ)]
    simp [Plan.trace_askC, Event.key]
  | ask c e k ih =>
    intro γ
    rw [asks, ih (le_of_ask h).2 (.cons default γ)]
    simp [Plan.trace_ask, Event.key]
  | case e arms _ => exact absurd (le_of_case h).1 (by decide)
  | dyn e f _ => exact absurd h (by simp only [level_dyn]; decide)

/-- **Kernel obligation C2's bill, repaired and exact.** At `level ≤ pipeline`,
with a shape-factoring price and answers flowing only into prompts, the bill is
computed from the term and is the bill of the run in *every* world.

This is directive (1)'s "exact value when monad is not necessary", stated where
it is true. -/
theorem bill_exact_pipeline [Monoid S] {price : Price S} (hp : PricesByShape price)
    (p : Plan Γ A) (h : level p ≤ Level.pipeline) (hs : ShapeStatic p) (γ : Env Γ) (ω : Ω) :
    asksBill price p γ = some (billFresh price (Plan.trace ω p γ)) := by
  rw [asksBill, asks_eq_default p h γ]
  exact congrArg _ (bill_indep_of_le_pipeline hp p h hs γ γ ωDefault ω)

/-! ## C3 — BRANCH: a finite tree of possible bills -/

/-- `[[CostTree S]]` = the branch structure of a plan with **both arms present**,
its leaves priced: a finite tree, `leaf s ∣ node T f` with `T` a `Fintype`.

Finite because `case`'s tag type is, which is the whole reason `case` is a
former and `dyn` is quarantined. `Type 1` for the same reason `Plan` is: the
node quantifies over a `Type`. -/
inductive CostTree (S : Type) : Type 1 where
  /-- A path with its bill. -/
  | leaf : S → CostTree S
  /-- A branch, with an arm for every tag. -/
  | node (T : Type) (inst : Fintype T) (f : T → CostTree S) : CostTree S

namespace CostTree

variable {S' : Type}

/-- Repricing every leaf. `[[map g τ]]` = `τ` with `g` applied at each leaf. -/
def map (g : S → S') : CostTree S → CostTree S'
  | .leaf s => .leaf (g s)
  | .node T inst f => .node T inst (fun t => (f t).map g)

/-- `[[leaves τ]]` = the bag of bills the tree admits. Finite by construction,
which is exactly what `dyn` destroys.

A `Multiset` and not a `List`: the order of a branch's arms is not part of what
a cost tree says, and `Finset.toList` is noncomputable while `Multiset.bind`
is not — so the bag is both the honest object and the computable one. -/
def leaves : CostTree S → Multiset S
  | .leaf s => {s}
  | .node T inst f => (@Finset.univ T inst).val.bind (fun t => (f t).leaves)

@[simp] theorem leaves_leaf (s : S) : (CostTree.leaf s).leaves = {s} := rfl

/-- **Morphism equation.** `leaves` is natural in the repricing: repricing the
tree is repricing its leaves. -/
@[simp] theorem leaves_map (g : S → S') (τ : CostTree S) :
    (τ.map g).leaves = τ.leaves.map g := by
  induction τ with
  | leaf s => rfl
  | node T inst f ih =>
    simp only [map, leaves, Multiset.map_bind]
    exact congrArg _ (funext fun t => ih t)

end CostTree

/-- `[[costTree price p h γ]]` = the finite tree of every bill `p` can run up.

Defined **only** where it exists: the level bound is an argument, so "the
analysis applies at this rung" is the type of the fold rather than a side
condition on a theorem — the `dyn` clause is discharged by `absurd`, not by a
`none`. This is `E_grade_as_fold_works.lean`'s repair with the totality theorem
absorbed into the signature.

```
costTree (ret e)       γ = leaf 1
costTree (askC c q k)  γ = map (price c q *)     (costTree k γ)
costTree (ask c e k)   γ = map (price c (e γ) *) (costTree k γ)
costTree (case _ arms) γ = node T (fun t => costTree (arms t) γ)
```

The continuation is analysed under `default` answers, which is harmless exactly
under `ShapeStatic` — the same repair as at `pipeline`, and the reason
`bill_mem_leaves` carries the same two hypotheses. -/
def costTree [CommMonoid S] (price : Price S) :
    {Γ : Ctx} → {A : Type} → (p : Plan Γ A) → level p ≤ Level.branch → Env Γ → CostTree S
  | _, _, .ret _, _, _ => .leaf 1
  | _, _, .askC c q k, h, γ => (costTree price k h (.cons default γ)).map (price c q * ·)
  | _, _, .ask c e k, h, γ =>
      (costTree price k (le_of_ask h).2 (.cons default γ)).map (price c (e γ) * ·)
  | _, _, @Plan.case _ _ T fT _ _ arms, h, γ =>
      .node T fT (fun t => costTree price (arms t) ((le_of_case h).2 t) γ)
  | _, _, .dyn _ _, h, _ => absurd h (by simp only [level_dyn]; decide)

/-- **Kernel obligation C3.** At `level ≤ branch`, with the same two hypotheses
that `pipeline` needs, the bill of *every* run is a leaf of the tree.

The kernel writes this as `bill = evalTree (costTree p) (decisions p γ ω)`;
membership is that statement with the path existentially quantified, and it is
what the bounds and the budget subtype are proved from. -/
theorem bill_mem_leaves [CommMonoid S] {price : Price S} (hp : PricesByShape price) :
    ∀ {Γ : Ctx} {A : Type} (p : Plan Γ A) (h : level p ≤ Level.branch), ShapeStatic p →
      ∀ (γ γ' : Env Γ) (ω : Ω),
        billFresh price (Plan.trace ω p γ) ∈ (costTree price p h γ').leaves := by
  intro Γ A p
  induction p with
  | ret e => intro h hs γ γ' ω; simp [costTree, Plan.trace]
  | askC c q k ih =>
    intro h hs γ γ' ω
    simp only [costTree, CostTree.leaves_map, Plan.trace_askC, billFresh_cons]
    exact Multiset.mem_map_of_mem _ (ih h ((shapeStatic_askC c q k).mp hs) _ _ ω)
  | ask c e k ih =>
    intro h hs γ γ' ω
    obtain ⟨hshape, hrest⟩ := (shapeStatic_ask c e k).mp hs
    simp only [costTree, CostTree.leaves_map, Plan.trace_ask, billFresh_cons]
    rw [hp c (e γ) (e γ') (hshape γ γ')]
    exact Multiset.mem_map_of_mem _ (ih (le_of_ask h).2 hrest _ _ ω)
  | case e arms ih =>
    intro h hs γ γ' ω
    rw [Plan.trace, denote_case]
    refine Multiset.mem_bind.mpr ⟨e γ, Finset.mem_univ _, ?_⟩
    exact ih (e γ) ((le_of_case h).2 _) ((shapeStatic_case e arms).mp hs _) γ γ' ω
  | dyn e f hdyn => intro h; exact absurd h (by simp only [level_dyn]; decide)

/-! ### The tropical folds, and the bounds they give -/

section Tropical

variable [CommMonoid S] [LinearOrder S]

/-- `[[minFold τ]]` = the cheapest bill the tree admits: the fold at the
min-plus tropical semiring, in `WithTop S` because an arm-less branch admits
none. -/
def CostTree.minFold : CostTree S → WithTop S
  | .leaf s => (s : WithTop S)
  | .node T inst f => (@Finset.univ T inst).inf (fun t => (f t).minFold)

/-- `[[maxFold τ]]` = the dearest bill the tree admits: the fold at the max-plus
tropical semiring. The pair `(minFold, maxFold)` is the fold at their product,
which is the interval the doctrine's toolbox row asks for. -/
def CostTree.maxFold : CostTree S → WithBot S
  | .leaf s => (s : WithBot S)
  | .node T inst f => (@Finset.univ T inst).sup (fun t => (f t).maxFold)

omit [CommMonoid S] in
theorem CostTree.minFold_le_of_mem (τ : CostTree S) {s : S} (hs : s ∈ τ.leaves) :
    τ.minFold ≤ (s : WithTop S) := by
  induction τ with
  | leaf s' =>
    rw [CostTree.leaves_leaf, Multiset.mem_singleton] at hs
    subst hs; exact le_rfl
  | node T inst f ih =>
    obtain ⟨t, _, ht⟩ := Multiset.mem_bind.mp hs
    refine le_trans ?_ (ih t ht)
    exact Finset.inf_le (f := fun t => (f t).minFold) (Finset.mem_univ t)

omit [CommMonoid S] in
theorem CostTree.le_maxFold_of_mem (τ : CostTree S) {s : S} (hs : s ∈ τ.leaves) :
    (s : WithBot S) ≤ τ.maxFold := by
  induction τ with
  | leaf s' =>
    rw [CostTree.leaves_leaf, Multiset.mem_singleton] at hs
    subst hs; exact le_rfl
  | node T inst f ih =>
    obtain ⟨t, _, ht⟩ := Multiset.mem_bind.mp hs
    refine le_trans (ih t ht) ?_
    exact Finset.le_sup (f := fun t => (f t).maxFold) (Finset.mem_univ t)

/-- **The bounds are sound**: every run's bill lies in the tree's interval. -/
theorem minFold_le_bill {price : Price S} (hp : PricesByShape price) (p : Plan Γ A)
    (h : level p ≤ Level.branch) (hs : ShapeStatic p) (γ : Env Γ) (ω : Ω) :
    (costTree price p h γ).minFold ≤ ((billFresh price (Plan.trace ω p γ) : S) : WithTop S) :=
  CostTree.minFold_le_of_mem _ (bill_mem_leaves hp p h hs γ γ ω)

theorem bill_le_maxFold {price : Price S} (hp : PricesByShape price) (p : Plan Γ A)
    (h : level p ≤ Level.branch) (hs : ShapeStatic p) (γ : Env Γ) (ω : Ω) :
    ((billFresh price (Plan.trace ω p γ) : S) : WithBot S) ≤ (costTree price p h γ).maxFold :=
  CostTree.le_maxFold_of_mem _ (bill_mem_leaves hp p h hs γ γ ω)

/-- **Best and worst case are attained** — by *worlds*, which is what a budget
argument needs and what the kernel asks for.

Note what does the work: the tree makes the set of achievable bills finite, and
a nonempty finite set in a linear order has a least element. The kernel's
version of this theorem attains `minFold`, and that is false
(`minFold_not_attained`); this is the true statement in its place. -/
theorem exists_min_bill {price : Price S} (hp : PricesByShape price) (p : Plan Γ A)
    (h : level p ≤ Level.branch) (hs : ShapeStatic p) (γ : Env Γ) :
    ∃ ω₀ : Ω, ∀ ω : Ω,
      billFresh price (Plan.trace ω₀ p γ) ≤ billFresh price (Plan.trace ω p γ) := by
  set f : Ω → S := fun ω => billFresh price (Plan.trace ω p γ) with hf
  have hsub : Set.range f ⊆ {x | x ∈ (costTree price p h γ).leaves} := by
    rintro _ ⟨ω, rfl⟩
    exact bill_mem_leaves hp p h hs γ γ ω
  have hfin : (Set.range f).Finite :=
    Set.Finite.subset (Multiset.finite_toSet _) hsub
  have hne : hfin.toFinset.Nonempty :=
    ⟨f ωDefault, hfin.mem_toFinset.mpr ⟨ωDefault, rfl⟩⟩
  obtain ⟨b, hb, hmin⟩ := hfin.toFinset.exists_min_image id hne
  obtain ⟨ω₀, rfl⟩ := hfin.mem_toFinset.mp hb
  exact ⟨ω₀, fun ω => hmin (f ω) (hfin.mem_toFinset.mpr ⟨ω, rfl⟩)⟩

theorem exists_max_bill {price : Price S} (hp : PricesByShape price) (p : Plan Γ A)
    (h : level p ≤ Level.branch) (hs : ShapeStatic p) (γ : Env Γ) :
    ∃ ω₁ : Ω, ∀ ω : Ω,
      billFresh price (Plan.trace ω p γ) ≤ billFresh price (Plan.trace ω₁ p γ) := by
  set f : Ω → S := fun ω => billFresh price (Plan.trace ω p γ) with hf
  have hsub : Set.range f ⊆ {x | x ∈ (costTree price p h γ).leaves} := by
    rintro _ ⟨ω, rfl⟩
    exact bill_mem_leaves hp p h hs γ γ ω
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

theorem shapeStatic_constBranch : ShapeStatic constBranch := by
  refine (shapeStatic_case _ _).mpr (fun t => ?_)
  cases t <;> simp

/-- Every world pays for the one consultation on the taken path. -/
theorem bill_constBranch (ω : Ω) :
    billFresh tick (Plan.trace ω constBranch Env.nil) = Multiplicative.ofAdd 1 := rfl

/-- The unreachable arm's bill is a leaf all the same. -/
theorem one_mem_leaves_constBranch :
    (1 : Multiplicative Nat) ∈ (costTree tick constBranch level_constBranch Env.nil).leaves := by
  decide

/-- **The kernel's attainment claim is false.** The tree's minimum is not
attained by any world, because the arm that realizes it is not reachable: the
tag is a constant. The bounds stay sound (`minFold_le_bill`); what is withdrawn
is that they are tight.

`exists_min_bill` is the repair — the extreme of the *achievable* bills is
attained — and the gap between the two is precisely the reachability analysis
that this kernel does not do (kernel open question 1). -/
theorem minFold_not_attained (ω : Ω) :
    (costTree tick constBranch level_constBranch Env.nil).minFold
      ≠ ((billFresh tick (Plan.trace ω constBranch Env.nil) :
          Multiplicative Nat) : WithTop (Multiplicative Nat)) := by
  intro heq
  have hle := CostTree.minFold_le_of_mem _ one_mem_leaves_constBranch
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
  .askC .text sizeQ (.dyn (fun γ => γ.head.length) (fun n => ticks n))

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

/-- **Kernel obligation C4, strengthened.** At `dynamic` there is no finite set
of possible bills — so there is no `CostTree`, no interval, and no static bill,
because the answer chooses how much work there is and answers are unbounded.

This is the statement that separates the rungs. The kernel's own formulation
("no `Φ : Plan → S` returns the bill") is *also* true at `branch`, where the
bill genuinely varies with the world, so it does not distinguish `dyn` from
`case`; the failure of finiteness does. -/
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

/-- **Hence C3 does not extend**: no cost tree of any shape describes a `dyn`
plan, because a tree has finitely many leaves. The tree is not merely
*uncomputable* at `dynamic`; it does not exist. -/
theorem no_cost_tree_at_dyn :
    ¬ ∃ τ : CostTree (Multiplicative Nat),
        ∀ ω : Ω, billFresh tick (Plan.trace ω unbounded Env.nil) ∈ τ.leaves := by
  rintro ⟨τ, hτ⟩
  refine no_finite_bill_set_at_dyn ?_
  classical
  exact ⟨τ.leaves.toList, fun ω => Multiset.mem_toList.mpr (hτ ω)⟩

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
function exists: `maxFold ∘ costTree` is a computable fold of a first-order
term, needing no `Fintype (El c)` and therefore defined for free-text answers
(`G_cost_needs_fintype.lean` is what happens otherwise). -/

/-- `[[PlanUpTo price β A]]` = the plans that cannot cost more than `β`: a
closed plan at or below `branch`, whose answers flow only into prompts, whose
cost tree's worst leaf is within budget. -/
def PlanUpTo [CommMonoid S] [LinearOrder S] (price : Price S) (β : S) (A : Type) : Type 1 :=
  { p : Plan [] A // ∃ h : level p ≤ Level.branch,
      ShapeStatic p ∧ (costTree price p h Env.nil).maxFold ≤ (β : WithBot S) }

/-- **And the budget is honoured, in every world.** The subtype's defining
condition is about the term; the conclusion is about every run. -/
theorem PlanUpTo.bill_le [CommMonoid S] [LinearOrder S] {price : Price S}
    (hp : PricesByShape price) {β : S} {A : Type} (p : PlanUpTo price β A) (ω : Ω) :
    billFresh price (Plan.trace ω p.1 Env.nil) ≤ β := by
  obtain ⟨p, h, hs, hβ⟩ := p
  have := le_trans (bill_le_maxFold hp p h hs Env.nil ω) hβ
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

/-- Its questions differ only in prompt text, so the missing hypothesis holds. -/
theorem shapeStatic_sharedGuide : ShapeStatic sharedGuide := by
  refine ⟨fun γ γ' => rfl, ?_⟩
  refine ⟨fun γ γ' => rfl, ?_⟩
  trivial

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
