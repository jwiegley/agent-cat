import Agentic.Monoid
import Agentic.Semiring
import Mathlib.Data.ENat.Lattice
import Mathlib.Data.ENNReal.Inv
import Mathlib.Algebra.TrivSqZeroExt.Basic
import Mathlib.Algebra.Module.Opposite

/-!
# The carriers: possibility, worst-case cost, consensus weight, expectation

Four instances of the resource algebra, one for each reading of "resource"
the design uses:

* `Prop` — *can this happen at all?* `⊕` is disjunction, `⊗` conjunction, and
  the lattice is Mathlib's own order on `Prop`.
* `Cost` — *how bad can it get?* max-plus on Mathlib's `WithBot ℕ∞`, read
  through `Multiplicative`, with the ⊥ that the audit found missing supplied by
  `WithBot`. Aggregation is `iSup` on Mathlib's complete lattice.
* `Prob` — *how likely is the best run?* the Viterbi semiring `([0,1], max, ×)`
  of §2, on Mathlib's `ℝ≥0∞`: real probabilities at last, with `[0,1]` visible
  as the hypothesis `≤ 1` on the theorems that need it. Aggregation is `iSup`,
  and its infinitary distributive law is Mathlib's `ENNReal.mul_iSup`.
* `SqZero P M` — *what does it cost on average?* Eisner's expectation
  semiring, which is Mathlib's `TrivSqZeroExt P M`, complete and starred over
  any complete base and any complete module of moments.

Three of the four carriers were hand-rolled inductives with hand-rolled
arithmetic and hand-built suprema; all three are now Mathlib carriers, and what
survives in this file is what Mathlib does not have: the star at expectation,
the complete module of moments (`CompletePMod`), and the arbitrary-index
aggregation (`CompleteCSemiring`, in `Agentic.Semiring`).
-/

namespace Agentic

open Computability KStar

open scoped ENNReal NNReal

/-! ## Possibility: the `Prop` semiring

**Why these five instances are `scoped`.** `Prop` is not a carrier this package
invented; it is the sort of every proposition in Lean, and an unqualified
`AddCommMonoid Prop` is a package-wide announcement that `0` is `False`, `1` is
`True`, `2` is `True`, and that `NatCast Prop`, `Monoid.npow` and every generic
numeral-producing lemma apply to propositions. The collision probe found
exactly that: after `import Agentic`, `(37 : Prop)` elaborated. That is
pollution of a namespace the package does not own, and the arithmetic is of no
use to any reader who is not reading `Prop` *as* possibility.

So the five instances live in the `Agentic.Possibility` scope. Nothing changes
for a file that wants the possibility carrier — it writes
`open scoped Agentic.Possibility` and everything below elaborates as before —
and nothing at all is installed for a file that does not, including
`Agentic.Term`, `Agentic.Gate` and `Agentic.Meaning`, in which `Prop` appears
only as the sort of a proposition and arithmetic on it would be a bug.

**Why a scope and not a synonym.** The obvious alternative is `def Poss := Prop`
with the instances on the synonym, which is what `Cost`, `Width` and `Race` do
for their carriers. It is the wrong tool *here*, and for a reason specific to
this carrier: the value of the possibility reading is that its elements really
are propositions and its order really is implication, so a read-out can be
*used*. `Agentic.reach M a b` is a hypothesis one can apply; `le_prop_iff : p ≤ q
↔ (p → q)` is `Iff.rfl`; `retry_possible` ends in an honest `↔`. Behind a
semireducible synonym none of those even state, and every read-out would be an
opaque `Poss` needing an unfolding lemma before it could be believed. The
carriers that got synonyms had a *competing* operation to protect (`ℕ`'s `+`
versus `max`, `Bool`'s `and` versus `or`); `Prop` has no competing arithmetic
to protect, only bystanders to protect *from*, and a scope is exactly the tool
that hides an instance from bystanders while keeping the type honest.
-/

namespace Possibility


/-- Possibility as a resource semiring: `⊕` is `∨` (either way of succeeding
will do), `⊗` is `∧` (both steps must succeed), `0` is `False` (refusal) and
`1` is `True` (the free step).

The instance is Mathlib's `IdemCommSemiring`, and the *order* half of it is
taken from Mathlib's existing lattice on `Prop` rather than induced afresh:
`⊔` there is `Or`, `⊥` is `False`, and `≤` is implication. So the canonical
additive order at this carrier is `→` on the nose — which is what
`le_prop_iff` reads off — and no second order on `Prop` is
created. -/
scoped instance instAddCommMonoidProp : AddCommMonoid Prop where
  add := Or
  zero := False
  nsmul n p := Nat.rec False (fun _ ih => Or ih p) n
  add_comm _ _ := propext ⟨Or.symm, Or.symm⟩
  add_assoc _ _ _ := propext or_assoc
  zero_add _ := propext ⟨fun h => h.elim False.elim id, Or.inr⟩
  add_zero _ := propext ⟨fun h => h.elim id False.elim, Or.inl⟩

/-- Possibility is an idempotent commutative semiring: `⊗` is `∧` with `True`
for `1`, on top of the `∨`/`False` alternation above, and the lattice half is
Mathlib's own order on `Prop`. -/
noncomputable scoped instance instCSemiringProp : IdemCommSemiring Prop where
  __ := instAddCommMonoidProp
  __ := (inferInstance : SemilatticeSup Prop)
  __ := (inferInstance : OrderBot Prop)
  mul := And
  one := True
  mul_comm _ _ := propext ⟨And.symm, And.symm⟩
  mul_assoc _ _ _ := propext and_assoc
  one_mul _ := propext ⟨And.right, fun h => ⟨trivial, h⟩⟩
  mul_one _ := propext ⟨And.left, fun h => ⟨h, trivial⟩⟩
  left_distrib _ _ _ := propext
    ⟨fun ⟨ha, hbc⟩ => hbc.elim (fun hb => Or.inl ⟨ha, hb⟩) (fun hc => Or.inr ⟨ha, hc⟩),
     fun h => h.elim (fun ⟨ha, hb⟩ => ⟨ha, Or.inl hb⟩) (fun ⟨ha, hc⟩ => ⟨ha, Or.inr hc⟩)⟩
  right_distrib _ _ _ := propext
    ⟨fun ⟨hab, hc⟩ => hab.elim (fun ha => Or.inl ⟨ha, hc⟩) (fun hb => Or.inr ⟨hb, hc⟩),
     fun h => h.elim (fun ⟨ha, hc⟩ => ⟨Or.inl ha, hc⟩) (fun ⟨hb, hc⟩ => ⟨Or.inr hb, hc⟩)⟩
  zero_mul _ := propext ⟨And.left, False.elim⟩
  mul_zero _ := propext ⟨And.right, False.elim⟩
  add_eq_sup _ _ := rfl

/-- Aggregation over `Prop` is existential quantification: the family is
possible exactly when some member of it is. This is the smallest complete
semiring the design uses, and the one that makes "meaning as a matrix"
degenerate to "meaning as a relation". -/
noncomputable scoped instance instCompleteCSemiringProp : CompleteCSemiring Prop where
  csum := fun {_} f => ∃ i, f i
  csum_zero := propext ⟨fun ⟨_, h⟩ => h, False.elim⟩
  csum_point := by
    intro ι i₀ f h
    apply propext
    apply Iff.intro
    · intro hex
      match hex with
      | ⟨i, hi⟩ =>
        by_cases he : i = i₀
        · exact he ▸ hi
        · have hf : f i = False := h i he
          exact False.elim (hf ▸ hi)
    · intro hi
      exact ⟨i₀, hi⟩
  csum_mul_left := fun _ _ => propext
    ⟨fun ⟨hx, i, hi⟩ => ⟨i, hx, hi⟩, fun ⟨i, hx, hi⟩ => ⟨hx, i, hi⟩⟩
  csum_swap := fun _ => propext
    ⟨fun ⟨i, j, h⟩ => ⟨j, i, h⟩, fun ⟨j, i, h⟩ => ⟨i, j, h⟩⟩
  csum_prod := fun _ => propext
    ⟨fun ⟨p, h⟩ => ⟨p.1, p.2, h⟩, fun ⟨i, j, h⟩ => ⟨(i, j), h⟩⟩
  csum_pair := fun _ _ => propext
    ⟨fun ⟨b, h⟩ => match b, h with
      | true, hx => Or.inl hx
      | false, hy => Or.inr hy,
     fun h => h.elim (fun hx => ⟨true, hx⟩) fun hy => ⟨false, hy⟩⟩

/-- Aggregation at possibility *is* the lattice supremum: `∃` is `⨆` on
`Prop`, which is Mathlib's `iSup_Prop_eq`. One line, and it is the whole of
this carrier's star theory. -/
scoped instance instCsumIsSupProp : CsumIsSup Prop where
  csum_eq_iSup _ := iSup_Prop_eq.symm

/-- **Iteration at possibility is always possible**: `p* = True` — and it is
the general star, not a carrier-specific one.

This instance used to be a hand-built Kleene algebra: a `kstar` returning
`True`, a proof of the unrolling law and a proof of Kleene induction. All three
are gone. `KleeneAlgebra.ofCsumIsSup` builds `p∗ = ⊕ₙ pⁿ` — at possibility,
"the loop runs some number of times" — out of `instCsumIsSupProp` alone, and
`Agentic.star_prop` reads off that this aggregate is `True` because the `n = 0`
disjunct is.

That leastness holds at all is worth a sentence, because the star answers
`True` — the *greatest* element of the implication order — and a greatest
element can be least only if it is the only competitor. It is: every solution
of `x = 1 + p · x` collapses to `True` (`Agentic.star_prop_solution`). So at
this carrier the equation already determines its answer and leastness merely
agrees with it, whereas at `Cost` the equation does not and leastness is what
decides. -/
noncomputable scoped instance instKleeneStarProp : KleeneAlgebra Prop :=
  KleeneAlgebra.ofCsumIsSup Prop

end Possibility

-- The possibility carrier's arithmetic, in scope for the rest of this file.
-- Every later section that reads a resource at `Prop` needs it; no module that
-- does not say `open scoped Agentic.Possibility` sees any of it.
open scoped Possibility

/-- **The additive order at possibility is implication.** With `Prop`'s
Mathlib order this is `Iff.rfl`: `≤` on `Prop` *is* `→`. The theorem is kept
because every leastness read-out at this carrier is phrased through it. -/
theorem le_prop_iff {p q : Prop} : p ≤ q ↔ (p → q) := Iff.rfl

/-! ## Worst-case cost: max-plus over Mathlib's `WithBot ℕ∞`

The carrier used to be a three-constructor inductive with a hand-rolled `max`,
a hand-rolled `+`, thirty lines of order development and — the bulk of it — two
hundred lines building a supremum by hand. All of that is Mathlib's:

| was | now |
| --- | --- |
| `inductive Cost` (`bot`/`fin n`/`inf`) | `Multiplicative (WithBot ℕ∞)` |
| `Cost.add` (hand-written `max`) | `⊔` of Mathlib's lattice on `WithBot ℕ∞` |
| `Cost.mul` (hand-written `+` with `bot` absorbing) | `+` of `WithBot ℕ∞`, through `Multiplicative` |
| the order and its eight lemmas | `CompleteLinearOrder (WithBot ℕ∞)` |
| `IsSup`, `exists_greatest`, `exists_isSup`, `csum` | `iSup` |

**Why `Multiplicative (WithBot ℕ∞)` and not `Tropical`.** Mathlib has a
tropical-semiring construction (`Mathlib.Algebra.Tropical.Basic`), and it is
min-plus: `Tropical R`'s `+` is `min` *in `R`'s own order*, so the canonical
additive order of the semiring is the reverse of the order the type carries.
An `IdemSemiring` — which is what `KleeneAlgebra` and hence every leastness
theorem in `Agentic.Star` needs — must have `a + b = a ⊔ b` in *its* order, so
`Tropical` would supply the lattice pointing the wrong way and the two orders
would be a diamond. `Multiplicative` has no order of its own to clash: it turns
`WithBot ℕ∞`'s `+` into `*`, leaves the lattice alone, and the join is then the
semiring's `⊕` on the nose.

**Why `WithBot ℕ∞` and not `ℕ∞`.** This is the audit's finding, in Mathlib's
vocabulary. Max-plus on `ℕ∞` alone would have `0 = ⊥ = (0 : ℕ∞) = 1`: the
identity of `max` and the identity of `+` are the same element and the semiring
collapses. `WithBot` adjoins the missing `-∞`, which is the cost of the run
that does not happen, and `WithBot.bot_add` — `⊥` absorbs — is precisely
`0 * x = 0`. The same `⊥` is what makes the infinitary distributive law
unconditional (`Cost.mul_iSup` below needs no `Nonempty ι`, where Mathlib's
`ENat.add_iSup` does).
-/

/-- A `Cost` is a worst-case resource bound: Mathlib's `WithBot ℕ∞`, read
multiplicatively, so that the type's `+` becomes the semiring's `⊗` and the
type's `⊔` becomes the semiring's `⊕`.

`⊥` (`Cost.bot`) is the impossible run — the identity of `max`, hence the
semiring's `0`, and the element without which max-plus has `0 = 1`. A coerced
natural (`Cost.fin n`) is the bound `n`, and `↑⊤` (`Cost.inf`) is divergence,
the bound no run respects. Zero cost is `fin 0`, which is `1`.

This is a `def` rather than an `abbrev` deliberately: `WithBot ℕ∞` already
carries an `AddCommMonoid` in which `+` is `+`, and the resource semiring needs
`+` to be `⊔`. The synonym keeps the two readings apart, exactly as
`Multiplicative` and `Tropical` do in Mathlib. -/
def Cost := Multiplicative (WithBot ℕ∞)

namespace Cost

/-- The impossible run: `⊥`, the identity of `max`, hence the semiring's `0`. -/
def bot : Cost := Multiplicative.ofAdd (⊥ : WithBot ℕ∞)

/-- The bound `n`, as a cost: the natural `n` inside `ℕ∞` inside `WithBot`. -/
def fin (n : Nat) : Cost := Multiplicative.ofAdd (((n : ℕ∞)) : WithBot ℕ∞)

/-- Divergence: a run with no bound at all, `↑⊤`. -/
def inf : Cost := Multiplicative.ofAdd (((⊤ : ℕ∞)) : WithBot ℕ∞)

end Cost

/-- Sequencing of costs is `WithBot ℕ∞`'s addition, read multiplicatively:
bounds of successive steps add, `1` is `fin 0`, and this is Mathlib's
`CommMonoid` on `Multiplicative`, not a re-proof of it. -/
instance instCommMonoidCost : CommMonoid Cost :=
  inferInstanceAs (CommMonoid (Multiplicative (WithBot ℕ∞)))

/-- **The cost order is Mathlib's, and it is complete.** `WithBot ℕ∞` is a
`CompleteLinearOrder` (`Mathlib.Data.ENat.Lattice`), so every family of costs
has a least upper bound and the aggregation the design calls for is `iSup` —
which is what deleted two hundred lines of hand-built supremum here.
Noncomputable because Mathlib's instance is. -/
noncomputable instance instCompleteLinearOrderCost : CompleteLinearOrder Cost :=
  inferInstanceAs (CompleteLinearOrder (WithBot ℕ∞))

/-- Costs have decidable equality (they are `Option (Option ℕ)` underneath). -/
instance instDecidableEqCost : DecidableEq Cost :=
  inferInstanceAs (DecidableEq (WithBot ℕ∞))

/-- The impossible run is the semiring's `0`. -/
instance instZeroCost : Zero Cost := ⟨Cost.bot⟩

/-- Combination of alternatives on costs is worst-case: the join of the
complete lattice, which on `WithBot ℕ∞` is `max`. -/
noncomputable instance instAddCost : Add Cost := ⟨fun x y => (x ⊔ y : Cost)⟩

/-- **Worst-case cost is a commutative idempotent resource semiring**, and
every field of it is a Mathlib lemma about `WithBot ℕ∞`: `⊕` is the lattice
join (`sup_comm`, `sup_assoc`, `bot_sup_eq`), `⊗` is addition through
`Multiplicative` (the whole `CommMonoid`, inherited), distributivity is
`add_max`/`max_add` — addition is monotone on a linear order, so it maps
maxima to maxima — and annihilation is `WithBot.bot_add`/`WithBot.add_bot`.

`add_eq_sup` holds by `rfl`, so the lattice `IdemSemiring` demands *is* the
lattice the carrier came with: no second order is created, and the canonical
additive order `≤` is the `WithBot ℕ∞` order on the nose. -/
noncomputable instance instIdemCommSemiringCost : IdemCommSemiring Cost where
  __ := (inferInstance : CommMonoid Cost)
  add_comm := sup_comm (α := Cost)
  add_assoc := sup_assoc (α := Cost)
  zero_add := bot_sup_eq (α := Cost)
  add_zero := sup_bot_eq (α := Cost)
  nsmul := nsmulRec
  nsmul_zero := fun _ => rfl
  nsmul_succ := fun _ _ => rfl
  left_distrib a b c := add_max (α := WithBot ℕ∞) a b c
  right_distrib a b c := max_add (α := WithBot ℕ∞) a b c
  zero_mul := WithBot.bot_add (α := ℕ∞)
  mul_zero := WithBot.add_bot (α := ℕ∞)
  bot_le := fun _ => bot_le (α := Cost)
  add_eq_sup _ _ := rfl

namespace Cost

/-- The impossible run *is* the semiring's `0`. -/
theorem bot_eq_zero : bot = (0 : Cost) := rfl

/-- The impossible run *is* the order's `⊥`. -/
theorem bot_eq_bot : bot = (⊥ : Cost) := rfl

/-- Divergence *is* the order's `⊤`. -/
theorem inf_eq_top : inf = (⊤ : Cost) := rfl

/-- Zero cost *is* the semiring's `1`. -/
theorem fin_zero_eq_one : fin 0 = (1 : Cost) := rfl

/-- Bounds add along sequencing: `fin m ⊗ fin n = fin (m + n)`. -/
theorem fin_mul_fin (m n : Nat) : fin m * fin n = fin (m + n) := by
  show Multiplicative.ofAdd (((m : ℕ∞) : WithBot ℕ∞) + ((n : ℕ∞) : WithBot ℕ∞)) = _
  rw [← WithBot.coe_add, ← Nat.cast_add]
  rfl

/-- On finite bounds the cost order is the order of `Nat`. -/
theorem fin_le_fin {m n : Nat} : (fin m ≤ fin n) ↔ m ≤ n := by
  show (((m : ℕ∞) : WithBot ℕ∞) ≤ ((n : ℕ∞) : WithBot ℕ∞)) ↔ _
  rw [WithBot.coe_le_coe, Nat.cast_le]

/-- Nothing below `bot` but `bot`. -/
theorem eq_bot_of_le_bot {x : Cost} (h : x ≤ bot) : x = bot := le_bot_iff.mp h

/-- Nothing above `inf` but `inf`. -/
theorem eq_inf_of_inf_le {y : Cost} (h : inf ≤ y) : y = inf := (top_le_iff.mp h).symm ▸ rfl

/-- A finite bound is never below `bot`. -/
theorem not_fin_le_bot {n : Nat} : ¬ (fin n ≤ bot) := fun h =>
  absurd (le_bot_iff.mp h : ((n : ℕ∞) : WithBot ℕ∞) = ⊥) WithBot.coe_ne_bot

/-- A finite bound is not the impossible run. -/
theorem fin_ne_bot {n : Nat} : fin n ≠ bot := fun h => not_fin_le_bot (_root_.le_of_eq h)

/-- Divergence is never below a finite bound. -/
theorem not_inf_le_fin {n : Nat} : ¬ (inf ≤ fin n) := fun h =>
  absurd (top_le_iff.mp (WithBot.coe_le_coe.mp h)) (ENat.coe_ne_top n)

/-- Divergence is never below `bot`. -/
theorem not_inf_le_bot : ¬ (inf ≤ bot) := fun h =>
  absurd (le_bot_iff.mp h : ((⊤ : ℕ∞) : WithBot ℕ∞) = ⊥) WithBot.coe_ne_bot

/-- Every cost is `bot`, some `fin n`, or `inf` — case analysis packaged as a
disjunction so that proofs may split on the *value* of a term. Where the old
inductive gave this by `cases`, the synonym gives it by matching on the two
`Option` layers underneath. -/
theorem cost_cases (x : Cost) : x = bot ∨ (∃ n, x = fin n) ∨ x = inf := by
  match x with
  | (⊥ : WithBot ℕ∞) => exact Or.inl rfl
  | ((⊤ : ℕ∞) : WithBot ℕ∞) => exact Or.inr (Or.inr rfl)
  | (((n : Nat) : ℕ∞) : WithBot ℕ∞) => exact Or.inr (Or.inl ⟨n, rfl⟩)

/-- Below a finite bound there is only `bot` and smaller finite bounds. -/
theorem le_fin_cases {x : Cost} {m : Nat} (h : x ≤ fin m) :
    x = bot ∨ ∃ n, x = fin n ∧ n ≤ m := by
  rcases cost_cases x with hb | ⟨n, hn⟩ | hi
  · exact Or.inl hb
  · exact Or.inr ⟨n, hn, fin_le_fin.mp (hn ▸ h)⟩
  · exact absurd (hi ▸ h) not_inf_le_fin

/-- Sequencing a fixed step before a worse alternative is worse: addition on
`WithBot ℕ∞` is monotone. -/
theorem mul_mono_right (x : Cost) {y z : Cost} (h : y ≤ z) : (x * y) ≤ (x * z) := by
  have h' : Multiplicative.toAdd y ≤ Multiplicative.toAdd z := h
  show Multiplicative.toAdd x + Multiplicative.toAdd y
      ≤ Multiplicative.toAdd x + Multiplicative.toAdd z
  exact add_le_add_right h' _

/-- A possible step never makes a run cheaper: `y ≤ x ⊗ y` whenever `x` is not
the impossible run. (At `x = bot` both sides are `bot`, so the hypothesis is
not decoration.) -/
theorem le_mul_of_ne_bot {x : Cost} (hx : x ≠ bot) (y : Cost) : y ≤ (x * y) := by
  rcases cost_cases y with hb | ⟨m, hm⟩ | hi
  · exact hb ▸ (mul_zero x).symm.le
  · rcases cost_cases x with hb' | ⟨n, hn'⟩ | hi'
    · exact absurd hb' hx
    · subst hm; subst hn'; rw [show ((fin n) * (fin m)) = fin (n + m) from fin_mul_fin n m]
      exact fin_le_fin.mpr (Nat.le_add_left m n)
    · subst hm; subst hi'
      show ((m : ℕ∞) : WithBot ℕ∞) ≤ ((⊤ : ℕ∞) : WithBot ℕ∞) + ((m : ℕ∞) : WithBot ℕ∞)
      rw [← WithBot.coe_add, WithBot.coe_le_coe, top_add]
      exact le_top
  · subst hi
    rcases cost_cases x with hb' | ⟨n, hn'⟩ | hi'
    · exact absurd hb' hx
    · subst hn'
      show ((⊤ : ℕ∞) : WithBot ℕ∞) ≤ ((n : ℕ∞) : WithBot ℕ∞) + ((⊤ : ℕ∞) : WithBot ℕ∞)
      rw [← WithBot.coe_add, add_top]
    · subst hi'
      show ((⊤ : ℕ∞) : WithBot ℕ∞) ≤ ((⊤ : ℕ∞) : WithBot ℕ∞) + ((⊤ : ℕ∞) : WithBot ℕ∞)
      rw [← WithBot.coe_add, add_top]

/-- A possible step before divergence diverges. -/
theorem mul_inf_of_ne_bot {x : Cost} (hx : x ≠ bot) : (x * inf) = inf :=
  _root_.le_antisymm le_top (le_mul_of_ne_bot hx inf)

/-- Divergence before a possible step diverges. -/
theorem inf_mul_of_ne_bot {x : Cost} (hx : x ≠ bot) : (inf * x) = inf := by
  rw [mul_comm]
  exact mul_inf_of_ne_bot hx

/-- Only the impossible step makes a possible step impossible. -/
theorem eq_bot_of_mul_eq_bot {x z : Cost} (hx : x ≠ bot) (h : (x * z) = bot) : z = bot := by
  by_contra hz
  exact absurd (h ▸ le_mul_of_ne_bot hx z : z ≤ bot) (fun hle => hz (eq_bot_of_le_bot hle))

/-- A finite step followed by `z` is finitely bounded only if `z` is. -/
theorem le_of_mul_fin_le_fin {k j : Nat} {z : Cost} (h : ((fin k) * z) ≤ fin j) :
    z ≤ fin j :=
  _root_.le_trans (le_mul_of_ne_bot (x := fin k) fin_ne_bot z) h

/-! ### Iteration at `Cost` is the *least* bound, not merely a bound

The unrolling law leaves the loop's bound open: at this carrier `x = 1 + a · x`
is solved by a whole up-set of costs, and only an order can say which of them
the loop means. The star this carrier now has is the general one — the
aggregate of the powers — and it means the smallest, because an aggregate that
is a supremum is a least upper bound. The one lemma below is what turns that
into the closed form a bound checker reads. -/

/-- **A costly step cannot be absorbed by a finite bound.** If the body `a` is
not free and `x` is a possible bound that absorbs one more trip round it —
`a · x ≤ x` — then `x` is divergence.

This is the whole content of `(fin (n+1))∗ = inf` being *least*: the star
answers `inf`, and the lemma says nothing smaller was available. -/
theorem eq_inf_of_mul_le {a x : Cost} (ha : ¬ a ≤ fin 0) (hx : x ≠ bot)
    (h : (a * x) ≤ x) : x = inf := by
  rcases cost_cases x with hb | ⟨m, hm⟩ | hi
  · exact absurd hb hx
  · subst hm
    rcases cost_cases a with hb' | ⟨n, hn'⟩ | hi'
    · exact absurd (hb' ▸ bot_le) ha
    · subst hn'
      rw [show ((fin n) * (fin m)) = fin (n + m) from fin_mul_fin n m] at h
      have hnm : n + m ≤ m := fin_le_fin.mp h
      have hn0 : n ≠ 0 := fun h0 => ha (by rw [h0])
      omega
    · subst hi'
      rw [inf_mul_of_ne_bot fin_ne_bot] at h
      exact absurd h not_inf_le_fin
  · exact hi

end Cost

namespace Cost

/-! ### Aggregation of costs is Mathlib's `iSup`

`Cost` is a complete lattice, so an arbitrary family of costs has a least upper
bound and that bound is the aggregation the design calls for. This is where the
migration paid best: `IsSup`, `isSup_unique`, `exists_greatest`, `exists_isSup`,
`csum_isSup`, `csum_eq`, `exists_eq_fin_of_isSup`, `csum_csum_upper`,
`csum_csum_least` and the classical choice that produced the supremum are all
deleted in favour of `iSup`, `le_iSup`, `iSup_le`, `iSup_comm` and `iSup_prod`.
The one fact that is genuinely about *this* carrier and not about lattices in
general — a finite supremum is attained — survives below, because the
infinitary distributive law needs it. -/

/-- The aggregation of a family of costs: its worst case, Mathlib's `iSup`. -/
noncomputable abbrev csum {ι : Type} (f : ι → Cost) : Cost := ⨆ i, f i

/-- Every member of a family is bounded by its aggregate (Mathlib's
`le_iSup`). -/
theorem le_csum {ι : Type} (f : ι → Cost) (i : ι) : f i ≤ csum f := le_iSup f i

/-- The aggregate is the least of the family's upper bounds (Mathlib's
`iSup_le`). -/
theorem csum_le {ι : Type} {f : ι → Cost} {y : Cost} (h : ∀ i, f i ≤ y) : csum f ≤ y :=
  iSup_le h

/-- The aggregate of impossibilities is impossible. -/
theorem csum_zero' {ι : Type} : csum (fun _ : ι => bot) = bot := iSup_bot

/-- A family that is `bot` everywhere aggregates to `bot`. -/
theorem csum_eq_bot {ι : Type} {f : ι → Cost} (h : ∀ i, f i = bot) : csum f = bot := by
  rw [show f = (fun _ => bot) from funext h]
  exact csum_zero'

/-- If the aggregate is not `bot`, some member is not. -/
theorem exists_ne_bot_of_csum_ne_bot {ι : Type} {f : ι → Cost} (h : csum f ≠ bot) :
    ∃ i, f i ≠ bot :=
  Classical.byContradiction fun hc =>
    h (csum_eq_bot fun i => Classical.byContradiction fun h' => hc ⟨i, h'⟩)

/-- **A finite aggregate is attained.** If the worst case over a family is
`fin m`, some member *is* `fin m`: the costs below `fin m` have a greatest
element, so a supremum that were not attained would be one of them.

This is the one lemma of the old supremum development that survives, and it
survives because it is a fact about `WithBot ℕ∞` and not about complete
lattices: it is false at, say, the reals in `[0, 1]`. It is what makes the
infinitary distributive law below three lines long. -/
theorem exists_eq_fin_of_csum_eq_fin {ι : Type} {f : ι → Cost} {m : Nat}
    (h : csum f = fin m) : ∃ i, f i = fin m := by
  by_contra hc
  have hne : ∀ i, f i ≠ fin m := fun i hi => hc ⟨i, hi⟩
  have hle : ∀ i, f i ≤ fin m := fun i => h ▸ le_csum f i
  cases m with
  | zero =>
    have hb : ∀ i, f i ≤ bot := by
      intro i
      rcases le_fin_cases (hle i) with hb | ⟨n, hn, hnm⟩
      · exact hb ▸ le_refl _
      · exact absurd (hn.trans (congrArg fin (Nat.le_zero.mp hnm))) (hne i)
    exact absurd (h ▸ csum_le hb) not_fin_le_bot
  | succ k =>
    have hb : ∀ i, f i ≤ fin k := by
      intro i
      rcases le_fin_cases (hle i) with hb | ⟨n, hn, hnm⟩
      · exact hb ▸ bot_le
      · have hnk : n ≤ k := by
          rcases Nat.eq_or_lt_of_le hnm with he | hlt
          · exact absurd (hn.trans (congrArg fin he)) (hne i)
          · omega
        exact hn ▸ fin_le_fin.mpr hnk
    exact absurd (fin_le_fin.mp (h ▸ csum_le hb)) (by omega)

/-- A family supported at one index aggregates to its one value. -/
theorem csum_point' {ι : Type} (i₀ : ι) (f : ι → Cost) (h : ∀ i, i ≠ i₀ → f i = bot) :
    csum f = f i₀ :=
  _root_.le_antisymm
    (csum_le fun i => by
      by_cases he : i = i₀
      · exact he ▸ le_refl (f i)
      · rw [h i he]; exact bot_le)
    (le_csum f i₀)

/-- **Two-point agreement at `Cost`**: the supremum of a two-point family is
the worse of its two values, which is exactly what `⊕ = max` says (Mathlib's
`iSup_bool_eq`). -/
theorem csum_pair' (x y : Cost) : csum (fun b : Bool => cond b x y) = (x + y) := by
  show (⨆ b : Bool, cond b x y) = (x + y)
  rw [iSup_bool_eq]
  rfl

/-- **Sequencing distributes over aggregation**: the infinitary left
distributive law for worst-case cost, `x ⊗ ⨆ᵢ fᵢ = ⨆ᵢ (x ⊗ fᵢ)`.

Note what the genuine `⊥` buys: Mathlib's `ENat.add_iSup` needs `[Nonempty ι]`,
because over `ℕ∞` the empty supremum is `0` and `a + 0 ≠ 0`. Here the empty
supremum is `bot`, which annihilates, so the law is unconditional — the same
element that rescues the semiring from `0 = 1` rescues the distributive law
from a side condition.

The proof is the three cases of the aggregate: impossible (both sides `bot`),
finite (attained, so substitute the attaining member), or divergent (and then
the right-hand side already dominates the left, since a possible step never
makes a run cheaper). -/
theorem mul_csum {ι : Type} (x : Cost) (f : ι → Cost) :
    (x * (csum f)) = csum (fun i => (x * (f i))) := by
  refine _root_.le_antisymm ?_ (csum_le fun i => mul_mono_right x (le_csum f i))
  by_cases hx : x = bot
  · subst hx
    exact _root_.le_trans (zero_mul _).le (bot_le)
  · rcases cost_cases (csum f) with hb | ⟨m, hm⟩ | hinf
    · rw [hb]
      exact _root_.le_trans (mul_zero x).le (bot_le)
    · obtain ⟨i, hi⟩ := exists_eq_fin_of_csum_eq_fin hm
      rw [hm, ← hi]
      exact le_csum (fun i => (x * (f i))) i
    · rw [hinf, mul_inf_of_ne_bot hx, ← hinf]
      exact iSup_mono fun i => le_mul_of_ne_bot hx (f i)

/-- Fubini: a doubly-indexed family may be aggregated in either order
(Mathlib's `iSup_comm`). -/
theorem csum_swap' {ι κ : Type} (f : ι → κ → Cost) :
    csum (fun i => csum (fun j => f i j)) = csum (fun j => csum (fun i => f i j)) :=
  iSup_comm

/-- Aggregating over a product index is aggregating twice (Mathlib's
`iSup_prod`). -/
theorem csum_prod' {ι κ : Type} (f : ι → κ → Cost) :
    csum (fun p : ι × κ => f p.1 p.2) = csum (fun i => csum (fun j => f i j)) :=
  iSup_prod

end Cost

/-- Worst-case cost is a complete resource semiring: aggregation over an
arbitrary family is Mathlib's `iSup`. Noncomputable, because the complete
lattice on `WithBot ℕ∞` is. -/
noncomputable instance instCompleteCSemiringCost : CompleteCSemiring Cost where
  csum := fun {_} f => Cost.csum f
  csum_zero := Cost.csum_zero'
  csum_point := by
    intro ι i₀ f h
    exact Cost.csum_point' i₀ f h
  csum_mul_left := Cost.mul_csum
  csum_swap := Cost.csum_swap'
  csum_prod := Cost.csum_prod'
  csum_pair := Cost.csum_pair'

/-- Aggregation at worst-case cost *is* the lattice supremum: `Cost.csum` was
defined as `⨆`, so the mixin holds by `rfl`. -/
instance instCsumIsSupCost : CsumIsSup Cost where
  csum_eq_iSup _ := rfl

/-- **Iteration at worst-case cost is the least solution of the loop
equation** — and it is the general star, `x∗ = ⊕ₙ xⁿ`, the worst case over how
many trips the loop takes.

This instance used to be a hand-built `if`, with its own unrolling law and its
own Kleene induction (`Cost.star`, `star_spec`, `star_eq_left'`,
`star_le_left'`). `Prob` proved the identical two theorems about the identical
formula. Both are gone: the star is `KleeneAlgebra.ofCsumIsSup`, and the
closed form a bound checker wants is now a *read-out* of it,
`Cost.kstar_eq`.

The additive order `≤` is `Cost`'s own order — both are Mathlib's order on
`WithBot ℕ∞` — so the under-determination of the unrolling law at this carrier
(`Agentic.retry_cost_ambiguous`: `fin 3`, `fin 5` and `inf` all solve one loop)
is resolved in favour of the smallest bound, which is what `checkBounds`
wants. -/
noncomputable instance instKleeneStarCost : KleeneAlgebra Cost :=
  KleeneAlgebra.ofCsumIsSup Cost

/-- **The closed form of the cost star**: `x∗` is free if the step is free and
divergence otherwise. What was the *definition* of `Cost.star` is now a theorem
about the aggregate of the powers, and it is proved from the general star
rather than beside it.

Free bodies: Mathlib's `kstar_eq_one` at a `KleeneAlgebra`. Costly bodies: the
aggregate is a possible bound (`1 ≤ x∗`) that absorbs one more trip
(`x · x∗ ≤ x∗`), and `Cost.eq_inf_of_mul_le` says the only such bound is
divergence. -/
theorem Cost.kstar_eq (x : Cost) : x∗ = if x ≤ Cost.fin 0 then Cost.fin 0 else Cost.inf := by
  split
  · next h => exact kstar_eq_one.mpr h
  · next h =>
      have h1 : (Cost.fin 0) ≤ x∗ := one_le_kstar
      exact Cost.eq_inf_of_mul_le h (fun hb => Cost.not_fin_le_bot (hb ▸ h1))
        mul_kstar_le_kstar

/-! ## Consensus weight: Viterbi at `ℝ≥0∞`, the real probability carrier

The design names a third carrier beside possibility and worst-case cost: *the
Viterbi semiring `([0,1], max, ×)` (consensus weight — not `([0,1], +, ×)`,
which is not closed under addition)* (§2).

**What this used to be, and why.** It used to be a two-constructor inductive
carrying a `Nat` exponent — the probabilities `2⁻ⁿ` and `0` — with `max` and
`×` written out on exponents, its own `IsSup`, its own well-ordering argument
(`exists_least`), its own `Classical.choose` aggregation and its own attainment
lemma. The reason given was completeness: `csum` must be a supremum, and a
family of *rationals* in `[0,1]` need not have a rational supremum. That
reason is sound and it is also an argument for using the reals, which is what
happens here.

**What it is now.** Mathlib's `ℝ≥0∞` (`ENNReal`), with `⊕ = ⊔` and `⊗ = ×`.
`ℝ≥0∞` is a `CompleteLinearOrder` whose `⊥` is `0`, a `CommMonoidWithZero`
under multiplication, and — the lemma that deletes this section's entire
aggregation development — it satisfies `ENNReal.mul_iSup` unconditionally.
Probabilities are now real numbers; `Prob.exp2 n` is the actual number `2⁻ⁿ`,
not a tag for it.

**What the widening costs, stated plainly.** `ℝ≥0∞` contains weights above `1`,
and two theorems that were unconditional at the dyadic carrier are conditional
here: `Prob.le_one` (certainty is the top) and, downstream in `Agentic.Star`,
Viterbi absorption `retry_prob`. That is not a loss of content but a repair of
an overclaim — "the star of a consensus weight is certainty" is *true because
the weight is at most certain*, and at the old carrier that hypothesis was
smuggled in by the choice of constructors. The sub-unit hypothesis `p ≤ 1` is
exactly the design's `[0,1]`, now visible in the statements that need it.
Above `1` the star answers `⊤`, which is the honest reading: a step that
amplifies, iterated without limit, has unbounded weight.
-/

/-- A `Prob` is a *consensus weight*: Mathlib's `ℝ≥0∞`, with `⊕` the join
(`max`, the better of two alternatives) and `⊗` multiplication (weights of
successive independent steps multiply). `0` is the impossible run — which is
also `⊥`, so the semiring's zero and the order's bottom coincide without any
adjustment — and `1` is certainty.

A `def` rather than an `abbrev`, for the reason `Cost` is: `ℝ≥0∞` already
carries an `AddCommMonoid` whose `+` is addition, and the Viterbi semiring
needs `+` to be `⊔`. The sum-product reading of `ℝ≥0∞` (`+` really `+`, with
`tsum` for aggregation) is a *different* semiring on the same numbers, and
keeping them apart is what the synonym is for. -/
def Prob := ℝ≥0∞

namespace Prob

/-- The impossible run: probability `0`, the semiring's `0` and the order's
`⊥`. -/
def never : Prob := (0 : ℝ≥0∞)

/-- The probability `2⁻ⁿ`, as a real number. `exp2 0` is certainty, the
semiring's `1`. The old carrier could represent nothing else; this one can, and
the constructor survives only because the read-outs and examples name it. -/
noncomputable def exp2 (n : Nat) : Prob := (2 : ℝ≥0∞)⁻¹ ^ n

end Prob

/-- Sequencing of consensus weights is multiplication of probabilities:
Mathlib's `CommMonoid` on `ℝ≥0∞`, not a re-proof of it. -/
noncomputable instance instCommMonoidProb : CommMonoid Prob := inferInstanceAs (CommMonoid ℝ≥0∞)

/-- **The probability order is Mathlib's, and it is complete.** Every family of
consensus weights has a least upper bound — the aggregation the design calls
for — and it is `iSup`. This is what deleted `IsSup`, `exists_least`,
`exists_attained` and the classical choice they fed. -/
noncomputable instance instCompleteLinearOrderProb : CompleteLinearOrder Prob :=
  inferInstanceAs (CompleteLinearOrder ℝ≥0∞)

/-- Consensus weights have decidable equality (Mathlib's, on `ℝ≥0∞`). -/
noncomputable instance instDecidableEqProb : DecidableEq Prob :=
  inferInstanceAs (DecidableEq ℝ≥0∞)

/-- The impossible run is the semiring's `0` — and `ℝ≥0∞`'s `0` is its `⊥`, so
this is also the order's bottom. -/
instance instZeroProb : Zero Prob := ⟨Prob.never⟩

/-- Combination of alternatives is the better of the two: the join, which on
`ℝ≥0∞` is `max`. -/
noncomputable instance instAddProb : Add Prob := ⟨fun x y => (x ⊔ y : Prob)⟩

/-- **Consensus weight is a commutative idempotent resource semiring**, every
field of it a Mathlib lemma about `ℝ≥0∞`: `⊕` is the lattice join, `⊗` is the
inherited `CommMonoid`, distributivity is `max_mul_mul_left`/`max_mul_mul_right`
(multiplication is monotone on a linear order, so it maps maxima to maxima) and
annihilation is `mul_zero`/`zero_mul`.

Idempotence of `⊕` is what separates this carrier from a measure-theoretic
one — `max` is idempotent, `+` is not — and it is why the canonical additive
order and Kleene induction are available here. -/
noncomputable instance instIdemCommSemiringProb : IdemCommSemiring Prob where
  __ := (inferInstance : CommMonoid Prob)
  add_comm := sup_comm (α := Prob)
  add_assoc := sup_assoc (α := Prob)
  zero_add := bot_sup_eq (α := Prob)
  add_zero := sup_bot_eq (α := Prob)
  nsmul := nsmulRec
  nsmul_zero := fun _ => rfl
  nsmul_succ := fun _ _ => rfl
  left_distrib a b c := (max_mul_mul_left (α := ℝ≥0∞) a b c).symm
  right_distrib a b c := (max_mul_mul_right (α := ℝ≥0∞) a b c).symm
  zero_mul := MulZeroClass.zero_mul (M₀ := ℝ≥0∞)
  mul_zero := MulZeroClass.mul_zero (M₀ := ℝ≥0∞)
  bot_le := fun _ => bot_le (α := Prob)
  add_eq_sup _ _ := rfl

namespace Prob

/-- The impossible run *is* the semiring's `0`. -/
theorem never_eq_zero : (never : Prob) = 0 := rfl

/-- The impossible run *is* the order's `⊥`: at `ℝ≥0∞` the two coincide with no
adjunction of a bottom, which is the one respect in which this carrier is
simpler than `Cost`. -/
theorem never_eq_bot : (never : Prob) = ⊥ := rfl

/-- Certainty *is* the semiring's `1`. -/
theorem exp2_zero_eq_one : exp2 0 = (1 : Prob) := pow_zero _

/-- Powers of one half multiply by adding exponents: `2⁻ᵐ · 2⁻ⁿ = 2⁻⁽ᵐ⁺ⁿ⁾`,
now an identity about real numbers rather than the definition of `⊗`. -/
theorem exp2_mul_exp2 (m n : Nat) : exp2 m * exp2 n = exp2 (m + n) :=
  (pow_add _ m n).symm

/-- **The additive order at consensus weight is the probability order**, which
on the exponents of `2⁻ⁿ` is reversed: `2⁻ᵐ` is no more probable than `2⁻ⁿ`
exactly when `n ≤ m`. At the old carrier this was the definition of the order;
here it is a fact about powers of a real number below one. -/
theorem exp2_le_exp2_iff {m n : Nat} : (exp2 m ≤ exp2 n) ↔ n ≤ m := by
  show ((2 : ℝ≥0∞)⁻¹ ^ m ≤ (2 : ℝ≥0∞)⁻¹ ^ n) ↔ n ≤ m
  rw [← ENNReal.inv_pow, ← ENNReal.inv_pow, ENNReal.inv_le_inv,
    show (2 : ℝ≥0∞) = ((2 : NNReal) : ℝ≥0∞) from rfl, ← ENNReal.coe_pow, ← ENNReal.coe_pow,
    ENNReal.coe_le_coe]
  exact pow_le_pow_iff_right₀ (by norm_num)

end Prob

namespace Prob

/-! ### Aggregation of consensus weights is Mathlib's `iSup`

The old development built the supremum by hand: a well-ordering argument on
exponents (`exists_least`), an `IsSup` predicate, its uniqueness, a
`Classical.choose`, an attainment lemma and a proof of the infinitary
distributive law from attainment. All of it is `iSup` on `ℝ≥0∞`, and the
infinitary distributive law — the one axiom that is not lattice bookkeeping —
is Mathlib's `ENNReal.mul_iSup`, which holds for an arbitrary and possibly
empty index. -/

/-- The aggregation of a family of consensus weights: the probability of its
best member, Mathlib's `iSup`. -/
noncomputable abbrev csum {ι : Type} (f : ι → Prob) : Prob := ⨆ i, f i

/-- Every member of a family is at most its aggregate (Mathlib's `le_iSup`). -/
theorem le_csum {ι : Type} (f : ι → Prob) (i : ι) : f i ≤ csum f := le_iSup f i

/-- The aggregate is the least of the family's upper bounds (Mathlib's
`iSup_le`). -/
theorem csum_le {ι : Type} {f : ι → Prob} {y : Prob} (h : ∀ i, f i ≤ y) : csum f ≤ y :=
  iSup_le h

/-- Aggregation respects pointwise equality of families. -/
theorem csum_congr' {ι : Type} {f g : ι → Prob} (h : ∀ i, f i = g i) :
    csum f = csum g :=
  congrArg _ (funext h)

/-- Aggregating impossibilities is impossible. -/
theorem csum_zero' {ι : Type} : csum (fun _ : ι => (0 : Prob)) = 0 := iSup_bot

/-- A family supported at one index aggregates to its one value. -/
theorem csum_point' {ι : Type} (i₀ : ι) (f : ι → Prob) (h : ∀ i, i ≠ i₀ → f i = 0) :
    csum f = f i₀ :=
  le_antisymm
    (csum_le fun i => by
      by_cases he : i = i₀
      · exact he ▸ le_rfl
      · rw [h i he]; exact bot_le)
    (le_csum f i₀)

/-- **Two-point agreement at consensus weight**: the supremum of a two-point
family is the better of its two values, which is what `⊕ = max` says (Mathlib's
`iSup_bool_eq`). -/
theorem csum_pair' (x y : Prob) : csum (fun b : Bool => cond b x y) = x + y := by
  show (⨆ b : Bool, cond b x y) = x + y
  rw [iSup_bool_eq]
  rfl

/-- **Sequencing distributes over aggregation**: the infinitary left
distributive law, which at this carrier is exactly Mathlib's
`ENNReal.mul_iSup` — no attainment argument, no case analysis, no `Nonempty`
side condition. -/
theorem mul_csum' {ι : Type} (x : Prob) (f : ι → Prob) :
    x * csum f = csum (fun i => x * f i) := by
  show x * (⨆ i, f i) = ⨆ i, x * f i
  exact ENNReal.mul_iSup x f

/-- Fubini: a doubly-indexed family may be aggregated in either order
(Mathlib's `iSup_comm`). -/
theorem csum_swap' {ι κ : Type} (f : ι → κ → Prob) :
    csum (fun i => csum (fun j => f i j)) = csum (fun j => csum (fun i => f i j)) :=
  iSup_comm

/-- Aggregating over a product index is aggregating twice (Mathlib's
`iSup_prod`). -/
theorem csum_prod' {ι κ : Type} (f : ι → κ → Prob) :
    csum (fun p : ι × κ => f p.1 p.2) = csum (fun i => csum (fun j => f i j)) :=
  iSup_prod

end Prob

/-- Consensus weight is a complete resource semiring: aggregation over an
arbitrary family is the probability of its best member, Mathlib's `iSup`. -/
noncomputable instance instCompleteCSemiringProb : CompleteCSemiring Prob where
  csum := fun {_} f => Prob.csum f
  csum_zero := Prob.csum_zero'
  csum_point := by
    intro ι i₀ f h
    exact Prob.csum_point' i₀ f h
  csum_mul_left := Prob.mul_csum'
  csum_swap := Prob.csum_swap'
  csum_prod := Prob.csum_prod'
  csum_pair := Prob.csum_pair'

/-- Aggregation at consensus weight *is* the lattice supremum: `Prob.csum` was
defined as `⨆`, so the mixin holds by `rfl`. -/
instance instCsumIsSupProb : CsumIsSup Prob where
  csum_eq_iSup _ := rfl

/-- **Iteration at consensus weight is a Kleene star**: `x∗ = ⊕ₙ xⁿ`, the best
weight over how many trips the loop takes, and the least solution of the loop
equation in the canonical additive order.

`Prob` used to prove the *same two theorems about the same formula* as `Cost`
— an `if x ≤ 1 then 1 else ⊤`, an unrolling law, a Kleene induction — and the
duplication was the clearest sign that neither belonged to its carrier. Both
copies are gone; what is left of this carrier's star theory is
`instCsumIsSupProb`, one `rfl`, and the closed form as a read-out
(`Prob.kstar_eq`). This carrier is a `KleeneAlgebra`, so `retry_least` applies
to it, which is *not* true of the expectation semiring below. -/
noncomputable instance instKleeneStarProb : KleeneAlgebra Prob :=
  KleeneAlgebra.ofCsumIsSup Prob

/-- **The closed form of the Viterbi star**: certainty if the step is at most
certain, and `⊤` otherwise — the very formula `Cost.kstar_eq` states, now
proved twice from the *general* star instead of once per carrier from scratch.

Sub-unit bodies: Mathlib's `kstar_eq_one`. Amplifying bodies: the aggregate is
at least `1`, hence nonzero, and absorbs one more trip; were it finite,
cancelling it in `x · x∗ ≤ 1 · x∗` would make the body sub-unit after all. -/
theorem Prob.kstar_eq (x : Prob) : x∗ = if x ≤ 1 then 1 else ⊤ := by
  split
  · next h => exact kstar_eq_one.mpr h
  · next h =>
      have h1 : (1 : Prob) ≤ x∗ := one_le_kstar
      have hx0 : x∗ ≠ 0 := fun h0 => by
        rw [h0] at h1
        exact absurd (le_antisymm h1 (bot_le : (0 : Prob) ≤ 1)) (one_ne_zero (α := ℝ≥0∞))
      by_contra hxt
      refine absurd ((ENNReal.mul_le_mul_iff_left hx0 hxt).mp ?_) h
      calc x * x∗ ≤ x∗ := mul_kstar_le_kstar
        _ = 1 * x∗ := (_root_.one_mul _).symm

/-! ## Expectation: the square-zero extension -/

/-- `PMod P M` is Mathlib's `Module P M`. Deprecated compatibility alias, kept
only because `doc/walkthrough.html` still spells it; the eleven law wrappers it
carried, and the `PMod.zero`/`PMod.add`/`PMod.smul` re-spellings of `0`, `+`
and `•`, are retired. -/
@[deprecated Module (since := "2026-08-12")]
abbrev PMod (P M : Type) [CommSemiring P] [AddCommMonoid M] := Module P M

/-! ### The opposite action a `TrivSqZeroExt` needs

Mathlib's square-zero extension is stated for a possibly *non-commutative* base
`R`, so its multiplication weights the moment on both sides — `r •> m` and
`m <• r` — and its semiring instances ask for `[Module Rᵐᵒᵖ M]` and
`[IsCentralScalar R M]` beside `[Module R M]`. Over the commutative carriers
this package uses, those two are not extra data: the opposite ring is the ring,
and the two actions coincide. The instances below supply exactly that, so every
`SqZero P M` statement keeps the hypotheses it always had (`[CommSemiring P]`,
`[AddCommMonoid M]`, `[Module P M]`) and no call site changes.

Both are given **low priority** deliberately. When `M` is `P` itself — the dual
numbers, `SqZero P P`, which is the instance the read-outs use — Mathlib's own
`Semiring.toOppositeModule` (priority 910) already applies, and it must keep
winning: its action is `m * unop r`, ours would be `unop r • m`, and the two
are equal only by commutativity, not by `rfl`. Priority 50 keeps Mathlib's
instance in front and confines ours to the modules Mathlib has nothing to say
about. -/

/-- **SURVIVOR (instance, not definition) — what Mathlib lacks.** A commutative
semiring acts on any of its modules through the opposite ring, because the
opposite ring is the ring; Mathlib has this only for the action of `P` on
itself (`Semiring.toOppositeModule`), so a `Module Pᵐᵒᵖ M` for a general module
of moments has to be produced, and this is it: restriction of scalars along
`Pᵐᵒᵖ →+* P`, which exists because every pair of elements of `P` commutes. -/
instance (priority := 50) instPModOpposite {P M : Type} [CommSemiring P] [AddCommMonoid M]
    [Module P M] : Module Pᵐᵒᵖ M :=
  Module.compHom M ((RingHom.id P).fromOpposite fun x y => mul_comm x y)

/-- The two actions of a commutative `P` on a module of moments are the same
action — by `rfl`, given `instPModOpposite` — which is what
`TrivSqZeroExt`'s commutative instances mean by `IsCentralScalar`. -/
instance (priority := 50) instPModIsCentralScalar {P M : Type} [CommSemiring P]
    [AddCommMonoid M] [Module P M] : IsCentralScalar P M :=
  ⟨fun _ _ => rfl⟩

/-- A `SqZero P M` is a resource together with a *first moment* of it: `base`
is the weight of the run, `moment` the weighted quantity carried along with it.
This is Eisner's expectation semiring — the same square-zero extension that
gives forward-mode automatic differentiation, with `moment` playing the part of
the derivative — so composition of meanings computes an expected cost, not
merely a possibility.

It is now **Mathlib's** `TrivSqZeroExt P M`, which is that construction under
its Mathlib name (`R × M` with `(r₁, m₁) * (r₂, m₂) = (r₁r₂, r₁m₂ + r₂m₁)`),
and the hundred lines of semiring laws this package proved by hand — the
product rule's associativity, the two distributive laws, the annihilations —
are `TrivSqZeroExt.commSemiring`.

A `def` rather than an `abbrev`, so that `x.base` and `x.moment` keep resolving
through this package's field names rather than Mathlib's `fst`/`snd`. Every
instance the carrier needs is transported by `inferInstanceAs` in one line
each. -/
def SqZero (P M : Type) := TrivSqZeroExt P M

namespace SqZero

/-- The weight of the run: a probability, a possibility, a count. Mathlib's
`TrivSqZeroExt.fst`, under this package's field name. -/
abbrev base {P M : Type} (x : SqZero P M) : P := TrivSqZeroExt.fst x

/-- The weighted quantity accumulated along the run. Mathlib's
`TrivSqZeroExt.snd`, under this package's field name. -/
abbrev moment {P M : Type} (x : SqZero P M) : M := TrivSqZeroExt.snd x

/-- Two such pairs are equal when their parts are (Mathlib's
`TrivSqZeroExt.ext`). -/
theorem eq_of_parts {P M : Type} {x y : SqZero P M}
    (hb : x.base = y.base) (hm : x.moment = y.moment) : x = y :=
  TrivSqZeroExt.ext hb hm

end SqZero

/-- Eisner's expectation semiring, alternation half: componentwise addition,
Mathlib's `TrivSqZeroExt.addCommMonoid`, transported to the package's name. -/
instance instAddCommMonoidSqZero {P M : Type} [CommSemiring P] [AddCommMonoid M] [Module P M] :
    AddCommMonoid (SqZero P M) :=
  inferInstanceAs (AddCommMonoid (TrivSqZeroExt P M))

/-- Eisner's expectation semiring: `⊗` is the product rule — weights multiply
and the moments cross-weight — over the componentwise alternation above. This
is Mathlib's `TrivSqZeroExt.commSemiring`; what used to be eleven hand-proved
laws is one `inferInstanceAs`. -/
instance instCSemiringSqZero {P M : Type} [CommSemiring P] [AddCommMonoid M] [Module P M] :
    CommSemiring (SqZero P M) :=
  inferInstanceAs (CommSemiring (TrivSqZeroExt P M))

namespace SqZero

variable {P M : Type} [CommSemiring P] [AddCommMonoid M] [Module P M]

/-- The projection to the weight: forgetting the moment. -/
def pi (x : SqZero P M) : P := x.base

/-- Forgetting the moment preserves the impossible run. -/
theorem pi_zero : pi (0 : SqZero P M) = 0 := rfl

/-- Forgetting the moment preserves the free step. -/
theorem pi_one : pi (1 : SqZero P M) = 1 := rfl

/-- Forgetting the moment preserves alternatives. -/
theorem pi_add (x y : SqZero P M) : pi (x + y) = pi x + pi y := rfl

/-- Forgetting the moment preserves sequencing. The four `pi_*` lemmas
together say that the first projection is a homomorphism of resource
semirings: the expectation semiring sits over `P`, and forgetting the moment
recovers the plain resource, so every law of `P` still holds of the weights. -/
theorem pi_mul (x y : SqZero P M) : pi (x * y) = pi x * pi y := rfl

/-- Why "square-zero": two pure moments multiply to nothing, so the extension
carries first moments only — expectations, not variances. -/
theorem moment_sq_zero (m n : M) :
    (⟨0, m⟩ * ⟨0, n⟩ : SqZero P M) = 0 := by
  refine eq_of_parts (MulZeroClass.zero_mul (0 : P)) ?_
  show (0 : P) • n + (0 : P) • m = (0 : M)
  rw [zero_smul P, zero_smul P, zero_add]

end SqZero

/-! ### Moments that aggregate: the complete module

A meaning is a matrix, and matrices compose by aggregating over the
intermediate state (`Mat.comp` — Chapman–Kolmogorov). So a carrier that cannot
aggregate is a carrier no meaning can be written over: until this section
existed, `Mat.comp` did not *elaborate* at `SqZero P M`, the expectation
semiring carried no meaning at all, and §5.2's "at the expectation semiring,
the expected cost of a retry loop is `p* m p*`" was a sentence about nothing.

Aggregation in the square-zero extension is componentwise — weights aggregate
in `P`, moments aggregate in `M` — so what the base was missing is an
aggregation on the module of moments. `CompletePMod` is that: `msum`, with
exactly the laws the six `CompleteCSemiring` axioms consume when they are
checked componentwise, including two-point agreement (the `csum_pair`
obligation acat-9kn left for this instance) and the one law that mixes the two
aggregations, `csum_smul`.

The class does **not** extend `PMod`; it takes it as an instance parameter, in
the style of `IdemAdd`. Extending would put a second `Module P M` in scope
whenever `M` is `P` — one from Mathlib's `Semiring.toModule`, one from the
parent projection —
and the `CommSemiring (SqZero P M)` used by the semiring laws would then have to
be proved defeq to the one used by the aggregation laws. A parameter has no
diamond to reconcile.
**What is deliberately not here.** The `M` of the design's *numeric* reading is
a module of costs weighted by probabilities — `smul` multiplying a cost by a
probability — and no such module exists over the carriers this package owns: a
probability times a cost is neither a probability (`Prob` is closed under `×`,
not under multiplication by a bound) nor a cost (`Cost`'s `⊗` adds bounds
rather than scaling them). One carrier must hold both, which means `ℝ≥0`, which
means Mathlib (acat-467). So the algebra of expectation is in-tree and complete
— the construction, its aggregation, its star and its read-outs, generic in `P`
and `M` — while the arithmetic of expectation waits, and the instances supplied
are the diagonal (`SqZero P P`, the dual numbers, where the weighting is the
carrier's own multiplication) and the product module. -/

/-- A `CompletePMod P M` is a representation of a module of moments in which
*aggregation over an index* makes sense: `msum f` is the accumulation of the
whole family `f`, as `csum` is for the weights.

**SURVIVOR — what Mathlib lacks.** Mathlib has no class for a module with an
arbitrary-index sum. Its infinitary sums on a module are `tsum` (topological,
needing `TopologicalSpace`, `T2Space` and summability) and `iSup` (needing a
`CompleteLattice`, hence an idempotent addition on the moments, which the
intended moment module — accumulated costs — does not have). The moment side of
`CompleteCSemiring`'s obligation therefore has to be stated, and this class is
that statement and nothing more: `msum` and its laws, over Mathlib's
`Module`.

Every field is the moment-side twin of a `CompleteCSemiring` field, save the
last, which is the only genuinely new law: it says the two aggregations agree
when a family of *weights* acts on one fixed moment. Without it the
distributive law for the square-zero `csum` cannot be proved, because the
cross-term of the product rule weights a fixed moment by every member of an
aggregated family of weights. -/
class CompletePMod (P M : Type) [CommSemiring P] [CompleteCSemiring P]
    [AddCommMonoid M] [Module P M] where
  /-- The accumulation of a whole family of moments: `msum f = ⊕ᵢ f i`. -/
  msum : {ι : Type} → (ι → M) → M
  /-- Accumulating absent moments leaves the moment absent. -/
  msum_zero : ∀ {ι : Type}, msum (fun _ : ι => 0) = 0
  /-- A family supported at one index accumulates to its one moment. -/
  msum_point : ∀ {ι : Type} (i₀ : ι) (f : ι → M),
    (∀ i, i ≠ i₀ → f i = 0) → msum f = f i₀
  /-- Fubini for moments: a doubly-indexed family accumulates in either order. -/
  msum_swap : ∀ {ι κ : Type} (f : ι → κ → M),
    msum (fun i => msum (fun j => f i j)) = msum (fun j => msum (fun i => f i j))
  /-- Accumulating over a product index is accumulating twice. -/
  msum_prod : ∀ {ι κ : Type} (f : ι → κ → M),
    msum (fun p : ι × κ => f p.1 p.2) = msum (fun i => msum (fun j => f i j))
  /-- **Two-point agreement for moments**: accumulating a family of two agrees
  with binary accumulation. The moment-side half of the `csum_pair` obligation
  that `Agentic.Semiring` charges every complete carrier. -/
  msum_pair : ∀ m n : M, msum (fun b : Bool => cond b m n) = (m + n)
  /-- Weighting distributes over accumulation: a fixed weight may be pushed
  under the aggregation sign. -/
  smul_msum : ∀ {ι : Type} (p : P) (f : ι → M),
    p • (msum f) = msum (fun i => p • (f i))
  /-- **The two aggregations agree on a fixed moment**: weighting by an
  aggregate of weights is accumulating the weightings. This is the law that
  makes the square-zero infinitary distributive law true, and it is the only
  field with no counterpart in `CompleteCSemiring`. -/
  csum_smul : ∀ {ι : Type} (g : ι → P) (m : M),
    (csum g) • m = msum (fun i => (g i) • m)

export CompletePMod (msum)

namespace CompletePMod

variable {P M : Type} [CommSemiring P] [CompleteCSemiring P] [AddCommMonoid M] [Module P M] [CompletePMod P M]

/-- Accumulation respects pointwise equality of families. -/
theorem msum_congr {ι : Type} {f g : ι → M} (h : ∀ i, f i = g i) :
    msum P f = msum P g :=
  congrArg (msum P) (funext h)

/-- Any family of moments indexed by `Bool` accumulates to the sum of its two
values: `msum_pair` with the `cond` presentation stripped away. -/
theorem msum_bool (g : Bool → M) : msum P g = g true + g false := by
  rw [← msum_pair (P := P) (g true) (g false)]
  exact msum_congr fun b => by cases b <;> rfl

/-- **Accumulation of moments is additive**: `⊕ᵢ (mᵢ + nᵢ) = (⊕ᵢ mᵢ) + (⊕ᵢ nᵢ)`.
The proof is `Agentic.csum_add` transported to the moment side — replace each
binary sum by an accumulation over `Bool`, exchange by Fubini, read the outer
one back — and it is what the product rule's two cross-terms need in order to
be separated under the aggregation sign. -/
theorem msum_add {ι : Type} (x y : ι → M) :
    msum P (fun i => ((x i) + (y i))) = ((msum P x) + (msum P y)) :=
  calc msum P (fun i => ((x i) + (y i)))
      = msum P (fun i => msum P fun b : Bool => cond b (x i) (y i)) :=
        msum_congr fun i => (msum_pair (x i) (y i)).symm
    _ = msum P (fun b : Bool => msum P fun i => cond b (x i) (y i)) :=
        msum_swap fun i (b : Bool) => cond b (x i) (y i)
    _ = ((msum P fun i => cond true (x i) (y i)) + (msum P fun i => cond false (x i) (y i))) :=
        msum_bool fun b : Bool => msum P fun i => cond b (x i) (y i)
    _ = ((msum P x) + (msum P y)) := rfl

end CompletePMod

/-- **Any complete resource semiring is a complete module over itself**, with
`csum` for `msum`: every law of the class is a law the semiring already has,
and the mixed law `csum_smul` is `csum_mul_right`. This is the instance that
makes `SqZero P P` — the dual numbers over `P` — a complete semiring, and with
it `Mat.comp` elaborates over the expectation semiring at every carrier the
package owns. -/
instance instCompletePModSelf {P : Type} [CommSemiring P] [CompleteCSemiring P] : CompletePMod P P where
  msum := fun {_} f => csum f
  msum_zero := csum_zero
  msum_point := fun i₀ f h => csum_point i₀ f h
  msum_swap := csum_swap
  msum_prod := csum_prod
  msum_pair := csum_pair
  smul_msum := csum_mul_left
  csum_smul := fun g m => csum_mul_right m g

/-- Two pairs are equal when their parts are: the `SqZero.eq_of_parts` of the
product, needed by the product module below. -/
theorem prod_eq_of_parts {M N : Type} {a b : M × N}
    (h1 : a.1 = b.1) (h2 : a.2 = b.2) : a = b := by
  cases a with
  | mk x y =>
    cases b with
    | mk x' y' =>
      have hx : x = x' := h1
      have hy : y = y' := h2
      rw [hx, hy]

/-- Two complete moment modules side by side aggregate componentwise, so the
two-moment expectation semiring is complete as well. -/
instance instCompletePModProd {P M N : Type} [CommSemiring P] [CompleteCSemiring P]
    [AddCommMonoid M] [AddCommMonoid N]
    [Module P M] [Module P N] [CompletePMod P M] [CompletePMod P N] :
    CompletePMod P (M × N) where
  msum := fun {_} f => (msum P fun i => (f i).1, msum P fun i => (f i).2)
  msum_zero := prod_eq_of_parts CompletePMod.msum_zero CompletePMod.msum_zero
  msum_point := fun i₀ f h =>
    prod_eq_of_parts
      (CompletePMod.msum_point i₀ (fun i => (f i).1) fun i hi => congrArg Prod.fst (h i hi))
      (CompletePMod.msum_point i₀ (fun i => (f i).2) fun i hi => congrArg Prod.snd (h i hi))
  msum_swap := fun f =>
    prod_eq_of_parts
      (CompletePMod.msum_swap fun i j => (f i j).1)
      (CompletePMod.msum_swap fun i j => (f i j).2)
  msum_prod := fun f =>
    prod_eq_of_parts
      (CompletePMod.msum_prod fun i j => (f i j).1)
      (CompletePMod.msum_prod fun i j => (f i j).2)
  msum_pair := fun m n =>
    prod_eq_of_parts
      ((CompletePMod.msum_congr (M := M) fun b : Bool => by cases b <;> rfl).trans
        (CompletePMod.msum_pair m.1 n.1))
      ((CompletePMod.msum_congr (M := N) fun b : Bool => by cases b <;> rfl).trans
        (CompletePMod.msum_pair m.2 n.2))
  smul_msum := fun p f =>
    prod_eq_of_parts
      (CompletePMod.smul_msum p fun i => (f i).1)
      (CompletePMod.smul_msum p fun i => (f i).2)
  csum_smul := fun g m =>
    prod_eq_of_parts
      (CompletePMod.csum_smul g m.1)
      (CompletePMod.csum_smul g m.2)

namespace SqZero

variable {P M : Type} [CommSemiring P] [CompleteCSemiring P] [AddCommMonoid M] [Module P M] [CompletePMod P M]

/-- **Aggregation in the expectation semiring is componentwise**: the weights
aggregate in `P`, the moments accumulate in `M`. This is the definition the
design's §3 projection needs — forgetting the moment turns it into `csum` at
the weights — and the one `Mat.comp` sums over the intermediate state with. -/
def csum {ι : Type} (F : ι → SqZero P M) : SqZero P M :=
  ⟨Agentic.csum fun i => (F i).base, msum P fun i => (F i).moment⟩

/-- Aggregating impossibilities is impossible, moment and all. -/
theorem csum_zero' {ι : Type} : csum (fun _ : ι => (0 : SqZero P M)) = 0 := by
  refine eq_of_parts ?_ ?_
  · show Agentic.csum (fun _ : ι => (0 : P)) = 0
    exact Agentic.csum_zero
  · show msum P (fun _ : ι => 0) = 0
    exact CompletePMod.msum_zero

/-- A family supported at one index aggregates to its one value. -/
theorem csum_point' {ι : Type} (i₀ : ι) (F : ι → SqZero P M)
    (h : ∀ i, i ≠ i₀ → F i = 0) : csum F = F i₀ :=
  eq_of_parts
    (Agentic.csum_point i₀ (fun i => (F i).base) fun i hi => congrArg SqZero.base (h i hi))
    (CompletePMod.msum_point i₀ (fun i => (F i).moment) fun i hi =>
      congrArg SqZero.moment (h i hi))

/-- **The infinitary distributive law at expectation.** Sequencing a fixed step
before an aggregate is aggregating the sequenced steps — weights by the
semiring's own law, moments by the product rule: the fixed step's weight rides
over the accumulated moments (`smul_msum`), and the fixed step's moment is
weighted by the aggregate of the family's weights (`csum_smul`). This is where
the mixed law of `CompletePMod` is spent. -/
theorem csum_mul_left' {ι : Type} (x : SqZero P M) (F : ι → SqZero P M) :
    x * csum F = csum (fun i => x * F i) := by
  refine eq_of_parts ?_ ?_
  · show x.base * Agentic.csum (fun i => (F i).base)
        = Agentic.csum (fun i => x.base * (F i).base)
    exact Agentic.csum_mul_left x.base fun i => (F i).base
  · show ((x.base • (msum P fun i => (F i).moment)) + ((Agentic.csum fun i => (F i).base) • x.moment))
        = msum P (fun i =>
            ((x.base • (F i).moment) + ((F i).base • x.moment)))
    rw [CompletePMod.msum_add (fun i => x.base • (F i).moment)
        (fun i => (F i).base • x.moment),
      CompletePMod.smul_msum x.base fun i => (F i).moment,
      CompletePMod.csum_smul (fun i => (F i).base) x.moment]

/-- Fubini at expectation: componentwise, from Fubini at the weights and at the
moments. -/
theorem csum_swap' {ι κ : Type} (F : ι → κ → SqZero P M) :
    csum (fun i => csum (fun j => F i j)) = csum (fun j => csum (fun i => F i j)) :=
  eq_of_parts
    (Agentic.csum_swap fun i j => (F i j).base)
    (CompletePMod.msum_swap fun i j => (F i j).moment)

/-- Aggregating over a product index is aggregating twice, componentwise. -/
theorem csum_prod' {ι κ : Type} (F : ι → κ → SqZero P M) :
    csum (fun p : ι × κ => F p.1 p.2) = csum (fun i => csum (fun j => F i j)) :=
  eq_of_parts
    (Agentic.csum_prod fun i j => (F i j).base)
    (CompletePMod.msum_prod fun i j => (F i j).moment)

/-- **Two-point agreement at expectation** — the obligation acat-9kn left for
this instance, discharged componentwise: a two-point family aggregates to the
alternative of its two values, weights and moments alike. -/
theorem csum_pair' (x y : SqZero P M) :
    csum (fun b : Bool => cond b x y) = x + y :=
  eq_of_parts
    ((Agentic.csum_congr fun b : Bool => by cases b <;> rfl).trans
      (Agentic.csum_pair x.base y.base))
    ((CompletePMod.msum_congr fun b : Bool => by cases b <;> rfl).trans
      (CompletePMod.msum_pair x.moment y.moment))

end SqZero

/-- **The expectation semiring is a complete resource semiring.** With this
instance `Mat.comp` elaborates over `SqZero P M` — the meaning space exists at
expectation, not merely the scalars — and every matrix theorem of
`Agentic.Matrix` (associativity, the units, Kronecker's mixed product, the
truncated star) holds there without being restated.

The hypotheses are the honest ones: a complete carrier of weights and a
complete module of moments. Both are supplied for free on the diagonal
(`instCompletePModSelf`), so `SqZero Prop Prop`, `SqZero Cost Cost` and
`SqZero Prob Prob` are complete without further work. -/
instance instCompleteCSemiringSqZero {P M : Type}
    [CommSemiring P] [CompleteCSemiring P] [AddCommMonoid M] [Module P M] [CompletePMod P M] :
    CompleteCSemiring (SqZero P M) where
  csum := fun {_} F => SqZero.csum F
  csum_zero := SqZero.csum_zero'
  csum_point := by
    intro ι i₀ F h
    exact SqZero.csum_point' i₀ F h
  csum_mul_left := SqZero.csum_mul_left'
  csum_swap := SqZero.csum_swap'
  csum_prod := SqZero.csum_prod'
  csum_pair := SqZero.csum_pair'

/-! ### The star at expectation: `p* m p*`, as a theorem

§5.2 says that at the expectation semiring "the expected cost of a retry loop
is `p* m p*`, in three lines". The three lines are these: writing `(q, n)` for
the star of `(p, m)`, the unrolling law `(q, n) = (1, 0) + (p, m)(q, n)` splits
into `q = 1 + p·q` — so `q` is `p*` — and `n = p·n + q·m`, whose solution is
`n = p* · m · p*`. Defining the star by that formula and *proving* the
unrolling law is what turns the design's calculation into a theorem.

The proof is one identity about the base: from `q = 1 + p·q` follows
`q·q = p·(q·q) + q`, and the moment component is that identity weighted by `m`.
Nothing is assumed about `M` beyond the module laws, so the read-out holds for
the two-moment module and for the dual numbers alike. -/

namespace SqZero

/-- The algebraic core of the expectation star: any solution `q` of the
unrolling equation satisfies `q·q = p·(q·q) + q`, which is the moment
component's equation with the moment cancelled. -/
theorem star_base_key {P : Type} [CommSemiring P] (p q : P) (h : q = 1 + p * q) :
    q * q = p * (q * q) + q :=
  calc q * q = (1 + p * q) * q := by rw [← h]
    _ = 1 * q + p * q * q := right_distrib _ _ _
    _ = q + p * (q * q) := by rw [one_mul, mul_assoc]
    _ = p * (q * q) + q := add_comm _ _

variable {P M : Type} [CommSemiring P] [AddCommMonoid M] [Module P M] [KStar P] [StarSemiring P]

/-- Iteration at expectation: the weight iterates by the base carrier's star,
and the moment is the design's `p* m p*` — the moment weighted by the star on
both sides, which in a commutative carrier is `smul (p* · p*)`.

This is `StarSemiring` and not `KleeneStar`, deliberately. Leastness needs an
idempotent `+`, and the `+` of `SqZero P M` is idempotent only if `M`'s
accumulation is — which the *intended* `M`, an expectation of costs that
genuinely adds, is not (acat-zms). So the canonical additive order is not this
carrier's order, no leastness is claimed here, and the class that would let it
be claimed is the ordered-carrier class acat-jmm. What this instance says is
exactly what the design says: the formula answers the unrolling equation. -/
instance instKStarSqZero : KStar (SqZero P M) where
  kstar x := ⟨x.base∗, (x.base∗ * x.base∗) • x.moment⟩

/-- The expectation star answers the unrolling law. This is `StarSemiring` and
not `KleeneAlgebra`, deliberately: leastness needs an idempotent `+`, and the
`+` of `SqZero P M` is idempotent only if `M`'s accumulation is — which the
*intended* `M`, an expectation of costs that genuinely adds, is not (acat-zms).
What this instance says is exactly what the design says: the formula answers
the unrolling equation. -/
instance instStarSemiringSqZero : StarSemiring (SqZero P M) where
  star_eq_left := by
    intro x
    refine eq_of_parts (StarSemiring.star_eq_left x.base) ?_
    show (x.base∗ * x.base∗) • x.moment
        = (0 : M)
            + (x.base • ((x.base∗ * x.base∗) • x.moment)
              + x.base∗ • x.moment)
    rw [zero_add, ← mul_smul, ← add_smul,
      ← star_base_key x.base (x.base∗) (StarSemiring.star_eq_left x.base)]

omit [StarSemiring P] in
/-- **The expectation star, read out**: its weight is the weight's star and its
moment is `p* m p*`. True by `rfl` — it is the definition — and stated because
the design's formula deserves a name that a reader can grep for. -/
theorem star_moment (x : SqZero P M) :
    (x∗).moment = (x.base∗ * x.base∗) • x.moment := rfl

omit [StarSemiring P] in
/-- The weight of the star is the star of the weight: forgetting the moment
commutes with iteration, so the first projection is a homomorphism of *starred*
semirings and not merely of semirings. This is the fibration of design §3 with
the star included: the probability factor of a loop is the loop of the
probability factors. -/
theorem pi_star (x : SqZero P M) : pi (x∗) = (pi x)∗ := rfl

omit [StarSemiring P] in
/-- **`p* m p*`, literally.** At the dual numbers — the moment module is the
carrier itself — the expectation star's moment is the design's `p* · m · p*`
with the multiplications written out and in the design's order. -/
theorem star_moment_dual (x : SqZero P P) :
    (x∗).moment = x.base∗ * x.moment * x.base∗ := by
  show x.base∗ * x.base∗ * x.moment = x.base∗ * x.moment * x.base∗
  rw [mul_assoc, mul_assoc, mul_comm (x.base∗) x.moment]

end SqZero

end Agentic
