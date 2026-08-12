import Agentic.Monoid
import Agentic.Semiring

/-!
# The carriers: possibility, worst-case cost, consensus weight, expectation

Four instances of the resource algebra, one for each reading of "resource"
the design uses:

* `Prop` — *can this happen at all?* `⊕` is disjunction, `⊗` conjunction.
* `Cost` — *how bad can it get?* `⊕` is maximum, `⊗` is addition: max-plus,
  with the ⊥ that the audit found missing.
* `Prob` — *how likely is the best run?* the Viterbi semiring `([0,1], max, ×)`
  of §2, built exactly and without reals as the probabilities `2⁻ⁿ` and `0`.
* `SqZero P M` — *what does it cost on average?* Eisner's expectation
  semiring, the square-zero extension, complete and starred over any complete
  base and any complete module of moments.
-/

namespace Agentic

/-! ## Possibility: the `Prop` semiring -/

/-- Possibility as a resource semiring: `⊕` is `∨` (either way of succeeding
will do), `⊗` is `∧` (both steps must succeed), `0` is `False` (refusal) and
`1` is `True` (the free step). -/
instance instCSemiringProp : CSemiring Prop where
  add := Or
  mul := And
  zero := False
  one := True
  add_comm _ _ := propext ⟨Or.symm, Or.symm⟩
  add_assoc _ _ _ := propext or_assoc
  zero_add _ := propext ⟨fun h => h.elim False.elim id, Or.inr⟩
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

/-- Aggregation over `Prop` is existential quantification: the family is
possible exactly when some member of it is. This is the smallest complete
semiring the design uses, and the one that makes "meaning as a matrix"
degenerate to "meaning as a relation". -/
instance instCompleteCSemiringProp : CompleteCSemiring Prop where
  toCSemiring := instCSemiringProp
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

/-- **Iteration at possibility is always possible**: `p* = True`. Repeating a
step any number of times *including none* can always be done by doing it none,
so the star of every proposition is the free step.

This is the design's "at Bool, termination possibility" read-out (§5.2), and
until this instance existed it could not be stated: the star had exactly one
carrier, worst-case cost. Degenerate is not the same as vacuous — the content
is carried by what the star does *inside* a retry, where it says that a loop
is possible exactly when its exit is (`Agentic.retry_possible`, in
`Agentic.Star`). -/
instance instStarSemiringProp : StarSemiring Prop where
  star := fun _ => True
  star_eq_left := fun _ => propext ⟨fun _ => Or.inl trivial, fun _ => trivial⟩

/-- Possibility is idempotent: `p ∨ p` is `p`. Two ways of doing the same
thing are one way, which is the duplication licence at this carrier. -/
instance instIdemAddProp : IdemAdd Prop where
  add_idem _ := propext ⟨fun h => h.elim id id, Or.inl⟩

/-- **The additive order at possibility is implication.** `p ≤+ q` unfolds to
`(p ∨ q) = q`, and an equation between propositions is a two-way implication;
one direction is trivial, so what the order says is `p → q`. Stating this once
turns every leastness proof at `Prop` into ordinary propositional reasoning. -/
theorem addLe_prop_iff {p q : Prop} : p ≤+ q ↔ (p → q) := by
  constructor
  · intro h hp
    have h' : (p ∨ q) = q := h
    exact cast h' (Or.inl hp)
  · intro h
    show (p ∨ q) = q
    exact propext ⟨fun hpq => hpq.elim h id, Or.inr⟩

/-- **Iteration at possibility is least.** Kleene induction here is one step of
propositional reasoning: `p* · b` is `True ∧ b`, so what has to be shown is
`b → x`, and that is the left half of the hypothesis `b ∨ (p ∧ x) → x`.

That it holds at all is worth a sentence, because the star answers `True` — the
*greatest* element of the implication order — and a greatest element can be
least only if it is the only competitor. It is: every solution of
`x = 1 + p · x` collapses to `True` (`Agentic.star_prop_solution`). So at this
carrier the equation already determines its answer and leastness merely agrees
with it, whereas at `Cost` the equation does not and leastness is what decides.
The instance earns its place by making the generic `Agentic.retry_least`
readable at possibility, not by being hard. -/
instance instKleeneStarProp : KleeneStar Prop where
  star_le_left _ _ _ h :=
    addLe_prop_iff.mpr fun hsb => addLe_prop_iff.mp h (Or.inl hsb.right)

/-! ## Worst-case cost: max-plus with a genuine bottom -/

/-- A `Cost` is a representation of a worst-case resource bound: `bot` is the
identity of `max` — the audit's corrected carrier, without which max-plus has
`0 = 1` and the semiring collapses — `fin n` is the bound `n`, and `inf` is
divergence, the bound that no run respects.

`bot` is *not* "zero cost": it is the cost of the impossible run, the empty
alternative. Zero cost is `fin 0`, which is `1`. -/
inductive Cost where
  /-- The impossible run: the identity of `max`, hence the semiring's `0`. -/
  | bot : Cost
  /-- The bound `n`. -/
  | fin (n : Nat) : Cost
  /-- Divergence: a run with no bound at all. -/
  | inf : Cost
  deriving DecidableEq, Repr

namespace Cost

/-- Combination of alternatives on costs is worst-case: `max`, with `bot`
least and `inf` greatest. -/
def add : Cost → Cost → Cost
  | bot,   y     => y
  | fin m, bot   => fin m
  | fin m, fin n => fin (max m n)
  | fin _, inf   => inf
  | inf,   _     => inf

/-- Sequencing of costs adds them, with `bot` annihilating — even
`inf * bot = bot`, because a step that cannot happen cannot diverge. -/
def mul : Cost → Cost → Cost
  | bot,   _     => bot
  | fin _, bot   => bot
  | fin m, fin n => fin (m + n)
  | fin _, inf   => inf
  | inf,   bot   => bot
  | inf,   fin _ => inf
  | inf,   inf   => inf

/-- Worst-case combination is idempotent: one alternative twice is that
alternative. -/
theorem add_idem : ∀ x : Cost, add x x = x
  | bot => rfl
  | fin n => congrArg fin (Nat.max_self n)
  | inf => rfl

/-- Combination of costs is commutative. -/
theorem add_comm' : ∀ x y : Cost, add x y = add y x
  | bot, bot => rfl
  | bot, fin _ => rfl
  | bot, inf => rfl
  | fin _, bot => rfl
  | fin m, fin n => congrArg fin (Nat.max_comm m n)
  | fin _, inf => rfl
  | inf, bot => rfl
  | inf, fin _ => rfl
  | inf, inf => rfl

/-- Combination of costs is associative. -/
theorem add_assoc' : ∀ x y z : Cost, add (add x y) z = add x (add y z) := by
  intro x y z
  cases x <;> cases y <;> cases z <;>
    first
      | rfl
      | exact congrArg fin (Nat.max_assoc _ _ _)

/-- **Worst-case combination is the package's idempotent commutative monoid**,
with `bot` — the impossible run — as its unit. Associativity, commutativity and
idempotence are the three theorems just proved; the unit laws are the first
equation of `add` and that equation read through commutativity.

The instance is what makes the cost order below three lines rather than thirty:
an idempotent commutative operation induces a partial order (`IdemCMonoid.le`),
and `Cost` and `Frag` are two carriers of that one construction. It is also the
duplication licence at `Cost`, and reading it as such is the statement that a
worst case counted twice is the same worst case. -/
instance instIdemCMonoid : IdemCMonoid Cost where
  op := add
  unit := bot
  op_assoc := add_assoc'
  unit_op _ := rfl
  op_unit x := (add_comm' bot x).symm
  op_comm := add_comm'
  op_idem := add_idem

/-- The cost combination is worst-case, definitionally. -/
theorem op_eq_add (x y : Cost) : x ⋄ y = add x y := rfl

/-- `x ≤ y` on costs means `x` is no worse a bound than `y`: the order induced
by `max`, `x + y = y`. It is `IdemCMonoid.le` at `Cost` — the same definition
that gives `Frag` its grade order — so the lemmas below are that development
instantiated rather than a second copy of it. -/
def le (x y : Cost) : Prop := IdemCMonoid.le x y

/-- `≤` on costs is the max-order. -/
instance : LE Cost := ⟨Cost.le⟩

/-- The cost order is decidable: it is an equation between costs. -/
instance decLe (x y : Cost) : Decidable (x ≤ y) :=
  inferInstanceAs (Decidable (add x y = y))

/-- Unfolding lemma: `x ≤ y` is by definition `x + y = y`. -/
theorem le_def {x y : Cost} : (x ≤ y) = (add x y = y) := rfl

/-- The cost order is reflexive (the generic order, at `Cost`). -/
theorem le_refl (x : Cost) : x ≤ x := IdemCMonoid.le_refl x

/-- The cost order is transitive. -/
theorem le_trans {x y z : Cost} (hxy : x ≤ y) (hyz : y ≤ z) : x ≤ z :=
  IdemCMonoid.le_trans hxy hyz

/-- The cost order is antisymmetric: it is a genuine partial order. -/
theorem le_antisymm {x y : Cost} (hxy : x ≤ y) (hyx : y ≤ x) : x = y :=
  IdemCMonoid.le_antisymm hxy hyx

/-- An alternative is no worse than the choice between it and another. -/
theorem le_add_left (x y : Cost) : x ≤ add x y := IdemCMonoid.le_op_left x y

/-- The same on the right. -/
theorem le_add_right (x y : Cost) : y ≤ add x y := IdemCMonoid.le_op_right x y

/-- A bound on two alternatives separately is a bound on their combination:
`add` really is the join of the cost order. -/
theorem add_le {x y z : Cost} (hx : x ≤ z) (hy : y ≤ z) : add x y ≤ z :=
  IdemCMonoid.op_le hx hy

/-- `bot` is the least cost: the impossible run is no worse than anything. -/
theorem bot_le (x : Cost) : bot ≤ x := rfl

/-- `inf` is the greatest cost: divergence is the worst bound. -/
theorem le_inf : ∀ x : Cost, x ≤ inf
  | bot => rfl
  | fin _ => rfl
  | inf => rfl

/-- Nothing below `bot` but `bot`. -/
theorem eq_bot_of_le_bot : ∀ {x : Cost}, x ≤ bot → x = bot
  | bot, _ => rfl
  | fin _, h => absurd h (by simp [le_def, add])
  | inf, h => absurd h (by simp [le_def, add])

/-- Nothing above `inf` but `inf`. -/
theorem eq_inf_of_inf_le : ∀ {y : Cost}, inf ≤ y → y = inf
  | bot, h => h.symm
  | fin _, h => h.symm
  | inf, _ => rfl

/-- On finite bounds the cost order is the order of `Nat`. -/
theorem fin_le_fin {m n : Nat} : (fin m ≤ fin n) ↔ m ≤ n := by
  constructor
  · intro h
    have h' : max m n = n := fin.inj h
    exact h' ▸ Nat.le_max_left m n
  · intro h
    show add (fin m) (fin n) = fin n
    exact congrArg fin (Nat.max_eq_right h)

/-- A finite bound is never below `bot`. -/
theorem not_fin_le_bot {n : Nat} : ¬ (fin n ≤ bot) := by
  simp [le_def, add]

/-- Divergence is never below a finite bound. -/
theorem not_inf_le_fin {n : Nat} : ¬ (inf ≤ fin n) := by
  simp [le_def, add]

/-- Divergence is never below `bot`. -/
theorem not_inf_le_bot : ¬ (inf ≤ bot) := by
  simp [le_def, add]

/-- Sequencing of costs is order-insensitive, because `Nat` addition is.
Named here, and not left inside the `CSemiring` instance, so that proofs about
`Cost.mul` may use it without going through the semiring's notation — the
matrix bounds of `Agentic.Star` do exactly that. -/
theorem mul_comm' : ∀ x y : Cost, mul x y = mul y x := by
  intro a b
  cases a <;> cases b <;>
    first
      | rfl
      | exact congrArg Cost.fin (Nat.add_comm _ _)

end Cost

/-- Worst-case cost is a resource semiring: `⊕` is `max` (the worse of two
alternatives is the bound you must quote) and `⊗` is `+` (bounds of successive
steps add), with `0 = bot` and `1 = fin 0`. This is max-plus — commutative
because `Nat` addition is. -/
instance instCSemiringCost : CSemiring Cost where
  add := Cost.add
  mul := Cost.mul
  zero := Cost.bot
  one := Cost.fin 0
  add_comm := Cost.add_comm'
  add_assoc := Cost.add_assoc'
  zero_add _ := rfl
  mul_comm := Cost.mul_comm'
  mul_assoc := by
    intro a b c
    cases a <;> cases b <;> cases c <;>
      first
        | rfl
        | exact congrArg Cost.fin (Nat.add_assoc _ _ _)
  one_mul := by
    intro a
    cases a <;>
      first
        | rfl
        | exact congrArg Cost.fin (Nat.zero_add _)
  mul_one := by
    intro a
    cases a <;>
      first
        | rfl
        | exact congrArg Cost.fin (Nat.add_zero _)
  left_distrib := by
    intro a b c
    cases a <;> cases b <;> cases c <;>
      first
        | rfl
        | exact congrArg Cost.fin (Nat.add_max_add_left _ _ _).symm
  right_distrib := by
    intro a b c
    cases a <;> cases b <;> cases c <;>
      first
        | rfl
        | exact congrArg Cost.fin (Nat.add_max_add_right _ _ _).symm
  zero_mul _ := rfl
  mul_zero := by
    intro a
    cases a <;> rfl

namespace Cost

/-- Iteration of a cost: repeating a step any number of times costs nothing
extra only if the step itself is free. Concretely `star bot = fin 0`,
`star (fin 0) = fin 0`, and everything else diverges — which is the honest
worst case for an unbounded retry loop. -/
def star : Cost → Cost
  | bot => fin 0
  | fin 0 => fin 0
  | fin (_ + 1) => inf
  | inf => inf

/-- `star` is the promised conditional: one, if the step is free; divergence
otherwise. -/
theorem star_spec (x : Cost) : star x = if x ≤ fin 0 then fin 0 else inf := by
  cases x with
  | bot => rfl
  | fin n =>
    cases n with
    | zero => rfl
    | succ k =>
      have h : ¬ (fin (k + 1) ≤ fin 0) := by
        intro hle
        exact absurd (fin_le_fin.mp hle) (by simp)
      simp [star, h]
  | inf => simp [star, not_inf_le_fin]

/-- Unrolling an iteration from the front changes nothing. -/
theorem star_eq_left' (x : Cost) : star x = add (fin 0) (mul x (star x)) := by
  cases x with
  | bot => rfl
  | fin n => cases n with
    | zero => rfl
    | succ _ => rfl
  | inf => rfl

/-! ### Iteration at `Cost` is the *least* bound, not merely a bound

The unrolling law leaves the loop's bound open: at this carrier `x = 1 + a · x`
is solved by a whole up-set of costs, and only an order can say which of them
the loop means. `star_le_left'` says it means the smallest, and the proof is the
two-case analysis the definition of `star` invites — a free body, where the
star is `1` and the exit's own bound suffices; and a costly body, where the star
is `inf` and the work is to show that *every* absorbing `x` is already `inf`. -/

/-- A bound on a choice bounds the left alternative. -/
theorem le_of_add_le_left {x y z : Cost} (h : add x y ≤ z) : x ≤ z :=
  le_trans (le_add_left x y) h

/-- A bound on a choice bounds the right alternative. -/
theorem le_of_add_le_right {x y z : Cost} (h : add x y ≤ z) : y ≤ z :=
  le_trans (le_add_right x y) h

/-- **A costly step cannot be absorbed by a finite bound.** If the body `a` is
not free and `x` is a possible bound that absorbs one more trip round it —
`a · x ≤ x` — then `x` is divergence.

This is the whole content of `star (fin (n+1)) = inf` being *least*: the star
answers `inf`, and the lemma says nothing smaller was available. The argument
is that `fin (k+1) · fin m = fin (k+1+m)`, which is strictly worse than
`fin m`, so no finite bound absorbs a trip. -/
theorem eq_inf_of_mul_le {a x : Cost} (ha : ¬ a ≤ fin 0) (hx : x ≠ bot)
    (h : mul a x ≤ x) : x = inf := by
  cases x with
  | bot => exact absurd rfl hx
  | inf => rfl
  | fin m =>
    cases a with
    | bot => exact absurd (bot_le (fin 0)) ha
    | inf => exact absurd h not_inf_le_fin
    | fin n =>
      cases n with
      | zero => exact absurd (le_refl (fin 0)) ha
      | succ k =>
        have hle : k + 1 + m ≤ m := fin_le_fin.mp h
        omega

/-- **The star is the least solution at worst-case cost.** If `x` absorbs the
exit `b` and one more trip round the body `a`, then `x` already absorbs
`a* · b`.

The two cases are the two values of `star`. If the body is free, `a* = fin 0`
is the unit and the claim is that `x` absorbs the exit, which is half the
hypothesis. If the body is not free, `a* = inf`, and either the exit is
impossible — in which case `inf · bot = bot` costs nothing — or it is not, and
then `x` is a possible bound absorbing a costly loop, hence `inf` by
`eq_inf_of_mul_le`. Divergence is therefore not an admission of defeat by the
analysis: it is the least honest answer available. -/
theorem star_le_left' (a b x : Cost) (h : add b (mul a x) ≤ x) :
    mul (star a) b ≤ x := by
  have hb : b ≤ x := le_of_add_le_left h
  have hax : mul a x ≤ x := le_of_add_le_right h
  by_cases ha : a ≤ fin 0
  · rw [star_spec, if_pos ha]
    have h1 : mul (fin 0) b = b := NSemiring.one_mul b
    rw [h1]
    exact hb
  · rw [star_spec, if_neg ha]
    by_cases hbot : b = bot
    · rw [hbot]
      show mul inf bot ≤ x
      exact bot_le x
    · have hxbot : x ≠ bot := fun hx =>
        hbot (eq_bot_of_le_bot (hx ▸ hb))
      have hmul : mul inf b = inf := by
        cases b with
        | bot => exact absurd rfl hbot
        | fin _ => rfl
        | inf => rfl
      rw [hmul, eq_inf_of_mul_le ha hxbot hax]
      exact le_refl inf

end Cost

/-- Iteration on worst-case cost is a star: it unrolls from the front, and —
because `⊗` happens to be commutative here — from the back as well
(`star_eq_right`). Only the front unrolling is asked of the instance; the
Conway identities are neither assumed by the class nor proved here. -/
instance instStarSemiringCost : StarSemiring Cost where
  star := Cost.star
  star_eq_left := Cost.star_eq_left'

/-- Worst-case combination is idempotent: `max x x = x`. The same theorem that
gives `Cost` its `IdemCMonoid`, read at the semiring's `+`. -/
instance instIdemAddCost : IdemAdd Cost where
  add_idem := Cost.add_idem

/-- **Iteration at worst-case cost is the least solution of the loop
equation.** The additive order `≤+` is `Cost.le` — both are `max x y = y` — so
this instance says exactly what `Cost.star_le_left'` proves, and the
under-determination of the unrolling law at this carrier
(`Agentic.retry_cost_ambiguous`: `fin 3`, `fin 5` and `inf` all solve one loop)
is thereby resolved in favour of the smallest bound.

That is the answer a bound checker wants. `checkBounds` is a question about the
*best* bound quotable for a loop, and an equation with three answers cannot be
asked it; with this instance the question has one answer, and `star_eq_one_iff`
of `Agentic.Star` reads it off. -/
instance instKleeneStarCost : KleeneStar Cost where
  star_le_left := Cost.star_le_left'

namespace Cost

/-! ### Aggregation of costs is supremum

`Cost` is a complete linear order, so an arbitrary family of costs has a least
upper bound; that bound is the aggregation the design calls for. The
construction is classical (`Classical.choose` on the proved existence of a
supremum) and therefore `noncomputable` — legitimately so: the meaning of "the
worst case over all runs" is not something an implementation enumerates. -/

/-- Every cost is `bot`, some `fin n`, or `inf` — case analysis packaged as a
disjunction so that proofs may split on the *value* of a term. -/
theorem cost_cases (x : Cost) : x = bot ∨ (∃ n, x = fin n) ∨ x = inf := by
  cases x
  · exact Or.inl rfl
  · exact Or.inr (Or.inl ⟨_, rfl⟩)
  · exact Or.inr (Or.inr rfl)

/-- Below a finite bound there is only `bot` and smaller finite bounds. -/
theorem le_fin_cases {x : Cost} {m : Nat} (h : x ≤ fin m) :
    x = bot ∨ ∃ n, x = fin n ∧ n ≤ m := by
  cases x with
  | bot => exact Or.inl rfl
  | fin n => exact Or.inr ⟨n, rfl, fin_le_fin.mp h⟩
  | inf => exact absurd h not_inf_le_fin

/-- A bounded, inhabited set of naturals has a greatest element. This is the
one piece of arithmetic the supremum construction needs, and it is where the
absence of `Nat.find` from core is paid for: induction on the bound. -/
theorem exists_greatest (p : Nat → Prop) :
    ∀ b : Nat, (∀ n, p n → n ≤ b) → (∃ n, p n) → ∃ m, p m ∧ ∀ n, p n → n ≤ m := by
  intro b
  induction b with
  | zero =>
    intro hb hne
    match hne with
    | ⟨n, hn⟩ => exact ⟨n, hn, fun k hk => Nat.le_trans (hb k hk) (Nat.zero_le n)⟩
  | succ b ih =>
    intro hb hne
    by_cases hp : p (b + 1)
    · exact ⟨b + 1, hp, hb⟩
    · refine ih ?_ hne
      intro n hn
      match Nat.lt_or_ge n (b + 1) with
      | Or.inl h => exact Nat.le_of_lt_succ h
      | Or.inr h => exact absurd (Nat.le_antisymm (hb n hn) h ▸ hn) hp

/-- `IsSup f x` is a representation of "`x` is the worst case over the family
`f`": an upper bound, and the least one. -/
def IsSup {ι : Type} (f : ι → Cost) (x : Cost) : Prop :=
  (∀ i, f i ≤ x) ∧ ∀ y, (∀ i, f i ≤ y) → x ≤ y

/-- A family has at most one supremum: the order is antisymmetric. -/
theorem isSup_unique {ι : Type} {f : ι → Cost} {x y : Cost}
    (hx : IsSup f x) (hy : IsSup f y) : x = y :=
  le_antisymm (hx.2 y hy.1) (hy.2 x hx.1)

/-- Every family of costs has a supremum. The proof is the case analysis the
carrier suggests: divergence dominates; otherwise all-`bot` is `bot`; otherwise
the finite bounds are either bounded — and then have a greatest element — or
unbounded, and their worst case is divergence. -/
theorem exists_isSup {ι : Type} (f : ι → Cost) : ∃ x, IsSup f x := by
  by_cases hinf : ∃ i, f i = inf
  · refine ⟨inf, fun i => le_inf _, fun y hy => ?_⟩
    match hinf with
    | ⟨i, hi⟩ => exact hi ▸ hy i
  · have hnotinf : ∀ i, f i ≠ inf := fun i hi => hinf ⟨i, hi⟩
    by_cases hbot : ∀ i, f i = bot
    · exact ⟨bot, fun i => (hbot i) ▸ le_refl bot, fun y _ => bot_le y⟩
    · have hex : ∃ i, f i ≠ bot :=
        Classical.byContradiction fun hc =>
          hbot fun i => Classical.byContradiction fun h' => hc ⟨i, h'⟩
      match hex with
      | ⟨i₀, hi₀⟩ =>
        have hfin : ∃ n, f i₀ = fin n := by
          match cost_cases (f i₀) with
          | Or.inl h => exact absurd h hi₀
          | Or.inr (Or.inl h) => exact h
          | Or.inr (Or.inr h) => exact absurd h (hnotinf i₀)
        match hfin with
        | ⟨n₀, hn₀⟩ =>
          by_cases hbdd : ∃ b, ∀ n, (∃ i, f i = fin n) → n ≤ b
          · match hbdd with
            | ⟨b, hb⟩ =>
              match exists_greatest (fun n => ∃ i, f i = fin n) b hb ⟨n₀, i₀, hn₀⟩ with
              | ⟨m, hm, hmax⟩ =>
                refine ⟨fin m, fun i => ?_, fun y hy => ?_⟩
                · match cost_cases (f i) with
                  | Or.inl h => exact h ▸ bot_le _
                  | Or.inr (Or.inl ⟨n, h⟩) =>
                    exact h ▸ fin_le_fin.mpr (hmax n ⟨i, h⟩)
                  | Or.inr (Or.inr h) => exact absurd h (hnotinf i)
                · match hm with
                  | ⟨i, hi⟩ => exact hi ▸ hy i
          · refine ⟨inf, fun i => le_inf _, fun y hy => ?_⟩
            match cost_cases y with
            | Or.inl h =>
              exact absurd (h ▸ hn₀ ▸ hy i₀) not_fin_le_bot
            | Or.inr (Or.inl ⟨j, h⟩) =>
              refine absurd ⟨j, fun n hn => ?_⟩ hbdd
              match hn with
              | ⟨i, hi⟩ => exact fin_le_fin.mp (h ▸ hi ▸ hy i)
            | Or.inr (Or.inr h) => exact h ▸ le_refl inf

/-- The aggregation of a family of costs: its worst case, the least upper
bound whose existence `exists_isSup` establishes. Noncomputable by
construction, and rightly so — this is a meaning, not an algorithm. -/
noncomputable def csum {ι : Type} (f : ι → Cost) : Cost :=
  Classical.choose (exists_isSup f)

/-- `csum f` is the supremum of `f`. -/
theorem csum_isSup {ι : Type} (f : ι → Cost) : IsSup f (csum f) :=
  Classical.choose_spec (exists_isSup f)

/-- Every member of a family is bounded by its aggregate. -/
theorem le_csum {ι : Type} (f : ι → Cost) (i : ι) : f i ≤ csum f := (csum_isSup f).1 i

/-- The aggregate is the least of the family's upper bounds. -/
theorem csum_le {ι : Type} {f : ι → Cost} {y : Cost} (h : ∀ i, f i ≤ y) : csum f ≤ y :=
  (csum_isSup f).2 y h

/-- Anything that is a supremum of `f` *is* `csum f`. -/
theorem csum_eq {ι : Type} {f : ι → Cost} {x : Cost} (h : IsSup f x) : csum f = x :=
  isSup_unique (csum_isSup f) h

/-- The aggregate of impossibilities is impossible. -/
theorem csum_zero' {ι : Type} : csum (fun _ : ι => bot) = bot :=
  csum_eq ⟨fun _ => le_refl bot, fun y _ => bot_le y⟩

/-- A family that is `bot` everywhere aggregates to `bot`. -/
theorem csum_eq_bot {ι : Type} {f : ι → Cost} (h : ∀ i, f i = bot) : csum f = bot :=
  csum_eq ⟨fun i => (h i) ▸ le_refl bot, fun y _ => bot_le y⟩

/-- If the aggregate is not `bot`, some member is not. -/
theorem exists_ne_bot_of_csum_ne_bot {ι : Type} {f : ι → Cost} (h : csum f ≠ bot) :
    ∃ i, f i ≠ bot :=
  Classical.byContradiction fun hc =>
    h (csum_eq_bot fun i => Classical.byContradiction fun h' => hc ⟨i, h'⟩)

/-- A finite supremum is attained: if the worst case is `fin m`, some member
*is* `fin m`. (In a complete linear order with no infinitesimals, suprema of
finite value are maxima.) -/
theorem exists_eq_fin_of_isSup {ι : Type} {f : ι → Cost} {m : Nat} (h : IsSup f (fin m)) :
    ∃ i, f i = fin m := by
  apply Classical.byContradiction
  intro hcon
  have hne : ∀ i, f i ≠ fin m := fun i hi => hcon ⟨i, hi⟩
  cases m with
  | zero =>
    have hb : ∀ i, f i ≤ bot := by
      intro i
      match le_fin_cases (h.1 i) with
      | Or.inl he => exact he ▸ le_refl bot
      | Or.inr ⟨n, he, hn⟩ =>
        exact absurd (he.trans (congrArg fin (Nat.le_zero.mp hn))) (hne i)
    exact absurd (h.2 bot hb) not_fin_le_bot
  | succ k =>
    have hb : ∀ i, f i ≤ fin k := by
      intro i
      match le_fin_cases (h.1 i) with
      | Or.inl he => exact he ▸ bot_le _
      | Or.inr ⟨n, he, hn⟩ =>
        have hnk : n ≤ k := by
          match Nat.eq_or_lt_of_le hn with
          | Or.inl heq => exact absurd (he.trans (congrArg fin heq)) (hne i)
          | Or.inr hlt => exact Nat.le_of_lt_succ hlt
        exact he ▸ fin_le_fin.mpr hnk
    exact absurd (fin_le_fin.mp (h.2 (fin k) hb)) (Nat.not_succ_le_self k)

/-- A finite aggregate is attained by some member of the family. -/
theorem exists_eq_fin_of_csum_eq_fin {ι : Type} {f : ι → Cost} {m : Nat}
    (h : csum f = fin m) : ∃ i, f i = fin m :=
  exists_eq_fin_of_isSup (h ▸ csum_isSup f)

/-- A family supported at one index aggregates to its one value. -/
theorem csum_point' {ι : Type} (i₀ : ι) (f : ι → Cost) (h : ∀ i, i ≠ i₀ → f i = bot) :
    csum f = f i₀ :=
  csum_eq ⟨fun i => by
      by_cases he : i = i₀
      · exact he ▸ le_refl (f i)
      · exact (h i he) ▸ bot_le (f i₀),
    fun y hy => hy i₀⟩

/-- **Two-point agreement at `Cost`**: the supremum of a two-point family is
the worse of its two values, which is exactly what `⊕ = max` says. The
supremum's two halves discharge it directly — each value is a lower bound of
the pair's maximum, and any common bound bounds the maximum. -/
theorem csum_pair' (x y : Cost) : csum (fun b : Bool => cond b x y) = add x y :=
  csum_eq ⟨fun b =>
      match b with
      | true => le_add_left x y
      | false => le_add_right x y,
    fun _ hz => add_le (hz true) (hz false)⟩

/-! ### Sequencing distributes over aggregation -/

/-- Sequencing a fixed step before a worse alternative is worse. -/
theorem mul_mono_right (x : Cost) {y z : Cost} (h : y ≤ z) : mul x y ≤ mul x z := by
  cases x with
  | bot => exact le_refl _
  | fin k =>
    cases y with
    | bot => exact bot_le _
    | fin n =>
      cases z with
      | bot => exact absurd h not_fin_le_bot
      | fin m => exact fin_le_fin.mpr (Nat.add_le_add_left (fin_le_fin.mp h) k)
      | inf => exact le_inf _
    | inf =>
      cases z with
      | bot => exact absurd h not_inf_le_bot
      | fin m => exact absurd h not_inf_le_fin
      | inf => exact le_refl _
  | inf =>
    cases y with
    | bot => exact bot_le _
    | fin n =>
      cases z with
      | bot => exact absurd h not_fin_le_bot
      | fin m => exact le_refl _
      | inf => exact le_refl _
    | inf =>
      cases z with
      | bot => exact absurd h not_inf_le_bot
      | fin m => exact absurd h not_inf_le_fin
      | inf => exact le_refl _

/-- Divergence before a possible step diverges. -/
theorem mul_inf_of_ne_bot {z : Cost} (h : z ≠ bot) : mul inf z = inf := by
  cases z with
  | bot => exact absurd rfl h
  | fin _ => rfl
  | inf => rfl

/-- Only the impossible step makes a possible step impossible. -/
theorem eq_bot_of_mul_eq_bot {x z : Cost} (hx : x ≠ bot) (h : mul x z = bot) : z = bot := by
  cases x with
  | bot => exact absurd rfl hx
  | fin k =>
    cases z with
    | bot => rfl
    | fin n => exact Cost.noConfusion h
    | inf => exact Cost.noConfusion h
  | inf =>
    cases z with
    | bot => rfl
    | fin n => exact Cost.noConfusion h
    | inf => exact Cost.noConfusion h

/-- A finite step followed by `z` is finitely bounded only if `z` is. -/
theorem le_of_mul_fin_le_fin {k j : Nat} {z : Cost} (h : mul (fin k) z ≤ fin j) :
    z ≤ fin j := by
  cases z with
  | bot => exact bot_le _
  | fin n =>
    exact fin_le_fin.mpr (Nat.le_trans (Nat.le_add_left n k) (fin_le_fin.mp h))
  | inf => exact absurd h not_inf_le_fin

/-- The aggregate, sequenced after a fixed step, is still bounded by any bound
on the sequenced members: the "least upper bound" half of infinitary
distributivity. -/
theorem mul_csum_le {ι : Type} (x : Cost) (f : ι → Cost) {y : Cost}
    (hy : ∀ i, mul x (f i) ≤ y) : mul x (csum f) ≤ y := by
  cases x with
  | bot => exact bot_le _
  | inf =>
    by_cases hb : csum f = bot
    · exact hb ▸ bot_le y
    · match exists_ne_bot_of_csum_ne_bot hb with
      | ⟨i, hi⟩ =>
        have hinf : inf ≤ y := (mul_inf_of_ne_bot hi) ▸ hy i
        have hyi : y = inf := eq_inf_of_inf_le hinf
        rw [hyi]
        exact le_inf _
  | fin k =>
    match cost_cases (csum f) with
    | Or.inl hb => exact hb ▸ bot_le y
    | Or.inr (Or.inl ⟨m, hs⟩) =>
      match exists_eq_fin_of_csum_eq_fin hs with
      | ⟨i, hi⟩ => exact hs ▸ hi ▸ hy i
    | Or.inr (Or.inr hs) =>
      have hyinf : y = inf := by
        match cost_cases y with
        | Or.inl hyb =>
          have hall : ∀ i, f i = bot := by
            intro i
            have h1 : mul (fin k) (f i) ≤ bot := hyb ▸ hy i
            exact eq_bot_of_mul_eq_bot (fun hc => Cost.noConfusion hc)
              (eq_bot_of_le_bot h1)
          have h2 : csum f = bot := csum_eq_bot hall
          rw [h2] at hs
          exact Cost.noConfusion hs
        | Or.inr (Or.inl ⟨j, hyj⟩) =>
          have hall : ∀ i, f i ≤ fin j := fun i => le_of_mul_fin_le_fin (hyj ▸ hy i)
          exact absurd (hs ▸ csum_le hall) not_inf_le_fin
        | Or.inr (Or.inr hyi) => exact hyi
      rw [hyinf]
      exact le_inf _

/-- Sequencing distributes over aggregation: the infinitary left distributive
law for worst-case cost. -/
theorem mul_csum {ι : Type} (x : Cost) (f : ι → Cost) :
    mul x (csum f) = csum (fun i => mul x (f i)) :=
  (csum_eq ⟨fun i => mul_mono_right x (le_csum f i), fun _ hy => mul_csum_le x f hy⟩).symm

/-! ### Fubini -/

/-- Each member of a doubly-indexed family is bounded by the iterated aggregate. -/
theorem csum_csum_upper {ι κ : Type} (f : ι → κ → Cost) (i : ι) (j : κ) :
    f i j ≤ csum (fun i => csum (fun j => f i j)) :=
  le_trans (le_csum (fun j => f i j) j) (le_csum (fun i => csum (fun j => f i j)) i)

/-- Any bound on all members bounds the iterated aggregate. -/
theorem csum_csum_least {ι κ : Type} (f : ι → κ → Cost) {y : Cost}
    (h : ∀ i j, f i j ≤ y) : csum (fun i => csum (fun j => f i j)) ≤ y :=
  csum_le fun i => csum_le fun j => h i j

/-- Fubini: a doubly-indexed family may be aggregated in either order. -/
theorem csum_swap' {ι κ : Type} (f : ι → κ → Cost) :
    csum (fun i => csum (fun j => f i j)) = csum (fun j => csum (fun i => f i j)) :=
  le_antisymm
    (csum_csum_least f fun i j => csum_csum_upper (fun j i => f i j) j i)
    (csum_csum_least (fun j i => f i j) fun j i => csum_csum_upper f i j)

/-- Aggregating over a product index is aggregating twice. -/
theorem csum_prod' {ι κ : Type} (f : ι → κ → Cost) :
    csum (fun p : ι × κ => f p.1 p.2) = csum (fun i => csum (fun j => f i j)) :=
  csum_eq ⟨fun p => csum_csum_upper f p.1 p.2,
    fun _ hy => csum_csum_least f fun i j => hy (i, j)⟩

end Cost

/-- Worst-case cost is a complete resource semiring: aggregation over an
arbitrary family is its supremum. Noncomputable, because the supremum is
obtained classically. -/
noncomputable instance instCompleteCSemiringCost : CompleteCSemiring Cost where
  toCSemiring := instCSemiringCost
  csum := fun {_} f => Cost.csum f
  csum_zero := Cost.csum_zero'
  csum_point := by
    intro ι i₀ f h
    exact Cost.csum_point' i₀ f h
  csum_mul_left := Cost.mul_csum
  csum_swap := Cost.csum_swap'
  csum_prod := Cost.csum_prod'
  csum_pair := Cost.csum_pair'

/-! ## Consensus weight: the Viterbi semiring, in exact logarithms

The design names a third carrier beside possibility and worst-case cost: *the
Viterbi semiring `([0,1], max, ×)` (consensus weight — not `([0,1], +, ×)`,
which is not closed under addition)* (§2). It is the probability-reading
factor — what §3's projection projects onto, and where §5.2 reads its
absorption — and until now the package had no carrier for it at all.

**Why not the rational unit interval.** Lean 4.30's core does ship `Rat`
(probe: `#check @Rat` answers `Rat : Type`, and `Rat.mul_comm`, `Rat.mul_assoc`
are core theorems), so `{q : Rat // 0 ≤ q ∧ q ≤ 1}` with `max` and `×` could be
written down, and it would be a `CSemiring`. It could **not** be a
`CompleteCSemiring`, and the obstruction is mathematical rather than a matter
of missing lemmas: `csum` must aggregate an *arbitrary* family; at a carrier
whose `⊕` is `max` the aggregate has to be the supremum — two-point agreement
(`csum_pair`) already forces it to be the supremum on families of two — and a
family of rationals in `[0,1]` need not have a rational supremum. The rational
unit interval is not a complete lattice, so the aggregate a complete semiring
*means* — the join of the family — is not available there; an operation called
`csum` that is not that join is the disease two-point agreement was added to
prevent (acat-9kn), moved from pairs to families. No impossibility theorem is
claimed, and none is needed: nothing is being ruled out here except writing
down an aggregation that is not an aggregation. Reals would repair it properly,
and reals are Mathlib's (acat-467).

**What is built instead.** The sub-semiring of `([0,1], max, ×)` generated by
one half: the probabilities `2⁻ⁿ` together with `0`. It is closed under both
operations — `2⁻ᵐ · 2⁻ⁿ = 2⁻⁽ᵐ⁺ⁿ⁾` and `max 2⁻ᵐ 2⁻ⁿ = 2⁻ᵐᶦⁿ⁽ᵐ˒ⁿ⁾` — and, which
is the point, it *is* complete: a supremum is a least exponent, the naturals
are well-ordered, so every family has one and it is attained. Attainment is
what makes the infinitary distributive law a dozen lines here where `Cost`
needed forty — a supremum that is a member of its family can simply be
substituted for.

The carrier is therefore represented by its exponent — a log-probability,
which is what an implementation of Viterbi carries anyway — and its arithmetic
is exact `Nat` arithmetic rather than a floating-point apology. Reading the
representation: `exp2 n` *is* the probability `2⁻ⁿ`, `never` is `0`, `⊕` takes
the more probable alternative and `⊗` multiplies. Because `⊕` is `max` it is
idempotent, so unlike the expectation carrier below this one keeps the
canonical additive order, and its star is least (`instKleeneStarProb`). -/

/-- A `Prob` is a representation of a *consensus weight*: the probability of
the best run, either impossible (`never`) or a power of one half (`exp2 n`
denotes `2⁻ⁿ`, so `exp2 0` is certainty).

The exponent, not the probability, is the datum — the carrier is the Viterbi
semiring in logarithms — and the two constructors are the two things a
probability of this shape can be. Restricting to powers of one half is what
buys completeness: every family of these has a supremum, namely the least
exponent occurring in it, whereas a family of rationals in `[0,1]` need not
have one in `[0,1] ∩ ℚ`. -/
inductive Prob where
  /-- The impossible run: probability `0`, the semiring's `0`. -/
  | never : Prob
  /-- The probability `2⁻ⁿ`. `exp2 0` is certainty, the semiring's `1`. -/
  | exp2 (n : Nat) : Prob
  deriving DecidableEq, Repr

namespace Prob

/-- Combination of alternatives is the more probable of the two — `max` on
probabilities, which on exponents is `min` — with the impossible run losing to
everything. -/
def add : Prob → Prob → Prob
  | never,  y      => y
  | exp2 m, never  => exp2 m
  | exp2 m, exp2 n => exp2 (min m n)

/-- Sequencing multiplies probabilities, which on exponents adds them; the
impossible run annihilates, since a step that cannot happen cannot be
followed. -/
def mul : Prob → Prob → Prob
  | never,  _      => never
  | exp2 _, never  => never
  | exp2 m, exp2 n => exp2 (m + n)

/-- Alternatives are unordered. -/
theorem add_comm' : ∀ x y : Prob, add x y = add y x
  | never,  never  => rfl
  | never,  exp2 _ => rfl
  | exp2 _, never  => rfl
  | exp2 m, exp2 n => congrArg exp2 (Nat.min_comm m n)

/-- Alternatives are unbracketed. -/
theorem add_assoc' : ∀ x y z : Prob, add (add x y) z = add x (add y z) := by
  intro x y z
  cases x <;> cases y <;> cases z <;>
    first
      | rfl
      | exact congrArg exp2 (Nat.min_assoc _ _ _)

/-- The best of two identical alternatives is that alternative: `max` is
idempotent, which is the duplication licence at this carrier. -/
theorem add_idem' : ∀ x : Prob, add x x = x
  | never  => rfl
  | exp2 n => congrArg exp2 (Nat.min_self n)

/-- Probabilities multiply in either order. -/
theorem mul_comm' : ∀ x y : Prob, mul x y = mul y x := by
  intro x y
  cases x <;> cases y <;>
    first
      | rfl
      | exact congrArg exp2 (Nat.add_comm _ _)

/-- Sequencing is unbracketed. -/
theorem mul_assoc' : ∀ x y z : Prob, mul (mul x y) z = mul x (mul y z) := by
  intro x y z
  cases x <;> cases y <;> cases z <;>
    first
      | rfl
      | exact congrArg exp2 (Nat.add_assoc _ _ _)

/-- Certainty before a step changes nothing. -/
theorem one_mul' : ∀ x : Prob, mul (exp2 0) x = x
  | never  => rfl
  | exp2 n => congrArg exp2 (Nat.zero_add n)

/-- Certainty after a step changes nothing. -/
theorem mul_one' : ∀ x : Prob, mul x (exp2 0) = x
  | never  => rfl
  | exp2 n => congrArg exp2 (Nat.add_zero n)

/-- Sequencing distributes over the better alternative, downstream. -/
theorem left_distrib' : ∀ x y z : Prob, mul x (add y z) = add (mul x y) (mul x z) := by
  intro x y z
  cases x <;> cases y <;> cases z <;>
    first
      | rfl
      | exact congrArg exp2 (Nat.add_min_add_left _ _ _).symm

/-- Sequencing distributes over the better alternative, upstream. -/
theorem right_distrib' : ∀ x y z : Prob, mul (add x y) z = add (mul x z) (mul y z) := by
  intro x y z
  cases x <;> cases y <;> cases z <;>
    first
      | rfl
      | exact congrArg exp2 (Nat.add_min_add_right _ _ _).symm

/-- Sequencing before the impossible run is impossible. -/
theorem mul_zero' : ∀ x : Prob, mul x never = never
  | never  => rfl
  | exp2 _ => rfl

end Prob

/-- Consensus weight is a resource semiring: `⊕` is `max` (the better of two
alternatives is the one a Viterbi read-out keeps) and `⊗` is `×` (probabilities
of successive independent steps multiply), with `0` the impossible run and `1`
certainty. This is the design's `([0,1], max, ×)`, exactly, on the
probabilities it can represent. -/
instance instCSemiringProb : CSemiring Prob where
  add := Prob.add
  mul := Prob.mul
  zero := Prob.never
  one := Prob.exp2 0
  add_comm := Prob.add_comm'
  add_assoc := Prob.add_assoc'
  zero_add _ := rfl
  mul_comm := Prob.mul_comm'
  mul_assoc := Prob.mul_assoc'
  one_mul := Prob.one_mul'
  mul_one := Prob.mul_one'
  left_distrib := Prob.left_distrib'
  right_distrib := Prob.right_distrib'
  zero_mul _ := rfl
  mul_zero := Prob.mul_zero'

/-- Consensus weight is idempotent: the better of an alternative and itself is
that alternative. This is what separates the Viterbi carrier from a
measure-theoretic one, and it is why the canonical additive order and Kleene
induction are available here and not there. -/
instance instIdemAddProb : IdemAdd Prob where
  add_idem := Prob.add_idem'

namespace Prob

/-- The impossible run *is* the semiring's `0`. -/
theorem never_eq_zero : (never : Prob) = 0 := rfl

/-- Certainty *is* the semiring's `1`. -/
theorem exp2_zero_eq_one : exp2 0 = (1 : Prob) := rfl

/-- **The additive order at consensus weight is the probability order**, which
on exponents is reversed: `2⁻ᵐ` is no more probable than `2⁻ⁿ` exactly when
`n ≤ m`. -/
theorem addLe_exp2_iff {m n : Nat} : (exp2 m ≤+ exp2 n) ↔ n ≤ m := by
  constructor
  · intro h
    have h' : exp2 (min m n) = exp2 n := h
    have h'' : min m n = n := exp2.inj h'
    exact h'' ▸ Nat.min_le_left m n
  · intro h
    show add (exp2 m) (exp2 n) = exp2 n
    exact congrArg exp2 (Nat.min_eq_right h)

/-- **Certainty is the top of the order**: nothing is more probable than the
free step. This is the fact that makes the star at this carrier constant. -/
theorem addLe_one : ∀ x : Prob, x ≤+ (1 : Prob)
  | never  => rfl
  | exp2 n => congrArg exp2 (Nat.min_eq_right (Nat.zero_le n))

/-- **Iteration at consensus weight is certainty**: `p* = 1`. A loop may be run
no times, the empty run is certain, and `max` keeps the best — so repeating a
step any number of times *including none* is certain whatever the step. This is
the Viterbi reading of §5.2's star, and it is the exact analogue of `p* = True`
at possibility. -/
theorem star_eq_left' (x : Prob) : (1 : Prob) = 1 + x * 1 := by
  have h : x + 1 = (1 : Prob) := addLe_one x
  rw [mul_one, add_comm, h]

end Prob

/-- Iteration at consensus weight: the star is certainty, because the empty run
is always available and `max` prefers it to any product of probabilities. -/
instance instStarSemiringProb : StarSemiring Prob where
  star := fun _ => 1
  star_eq_left := Prob.star_eq_left'

/-- **Iteration at consensus weight is least.** The star answers `1`, which is
the *top* of the probability order, so leastness is worth a sentence: the
hypothesis of Kleene induction already contains `b ≤+ x`, and `1 · b` is `b`,
so the loop's solve is below every invariant of the loop step for the same
reason it is at possibility — a loop that may be taken zero times imposes no
condition. This carrier is therefore a `KleeneStar` and `retry_least` applies
to it, which is *not* true of the expectation semiring below. -/
instance instKleeneStarProb : KleeneStar Prob where
  star_le_left a b x h := by
    show (1 : Prob) * b ≤+ x
    rw [one_mul]
    exact addLe_trans (addLe_add_left b (a * x)) h

namespace Prob

/-! ### Aggregation of consensus weights is the most probable member

An arbitrary family of consensus weights has a supremum in the probability
order, and — unlike at `Cost`, where a family of unboundedly growing finite
bounds has only `inf` for a supremum — that supremum is always *attained*: it
is the least exponent occurring in the family, and the naturals are
well-ordered. Attainment is the whole reason this section is short. Every
aggregation axiom below is either the order's own arithmetic or the observation
that a sup which is a member can be substituted for. -/

/-- `IsSup f x` is a representation of "`x` is the most probable member of the
family `f`": an upper bound in the additive order, and the least one. -/
def IsSup {ι : Type} (f : ι → Prob) (x : Prob) : Prop :=
  (∀ i, f i ≤+ x) ∧ ∀ y, (∀ i, f i ≤+ y) → x ≤+ y

/-- A family has at most one supremum: the additive order is antisymmetric. -/
theorem isSup_unique {ι : Type} {f : ι → Prob} {x y : Prob}
    (hx : IsSup f x) (hy : IsSup f y) : x = y :=
  addLe_antisymm (hx.2 y hy.1) (hy.2 x hx.1)

/-- **A nonempty set of naturals has a least member.** The one piece of
arithmetic the supremum needs, and — `Nat.find` being absent from core — it is
paid for by induction on a witness bound, exactly as `Cost.exists_greatest`
pays for the dual fact. -/
theorem exists_least (p : Nat → Prop) :
    ∀ b : Nat, ∀ k, k ≤ b → p k → ∃ m, p m ∧ ∀ j, p j → m ≤ j := by
  intro b
  induction b with
  | zero =>
    intro k hk hp
    have hk0 : k = 0 := Nat.le_zero.mp hk
    exact ⟨0, hk0 ▸ hp, fun j _ => Nat.zero_le j⟩
  | succ b ih =>
    intro k hk hp
    by_cases hlow : ∃ j, j ≤ b ∧ p j
    · match hlow with
      | ⟨j, hjb, hj⟩ => exact ih j hjb hj
    · have hnone : ∀ j, j ≤ b → ¬ p j := fun j hjb hj => hlow ⟨j, hjb, hj⟩
      have hk' : k = b + 1 := by
        match Nat.lt_or_ge k (b + 1) with
        | Or.inl h => exact absurd hp (hnone k (Nat.le_of_lt_succ h))
        | Or.inr h => exact Nat.le_antisymm hk h
      refine ⟨b + 1, hk' ▸ hp, fun j hj => ?_⟩
      match Nat.lt_or_ge j (b + 1) with
      | Or.inl h => exact absurd hj (hnone j (Nat.le_of_lt_succ h))
      | Or.inr h => exact h

/-- A family of impossible runs has the impossible run for its supremum. -/
theorem isSup_zero {ι : Type} {f : ι → Prob} (h : ∀ i, f i = 0) : IsSup f 0 := by
  refine ⟨fun i => ?_, fun y _ => zero_addLe y⟩
  rw [h i]
  exact addLe_refl (0 : Prob)

/-- **The supremum is attained.** Either every member of the family is
impossible, or some member *is* the family's supremum — there is no third case,
because a supremum here is a least exponent and a nonempty set of naturals has
a least member. This is the lemma the whole completeness argument runs on. -/
theorem exists_attained {ι : Type} (f : ι → Prob) :
    (∀ i, f i = 0) ∨ ∃ i, IsSup f (f i) := by
  by_cases hall : ∀ i, f i = 0
  · exact Or.inl hall
  · refine Or.inr ?_
    have hex : ∃ i, f i ≠ 0 := Classical.byContradiction fun hc =>
      hall fun i => Classical.byContradiction fun h' => hc ⟨i, h'⟩
    match hex with
    | ⟨i₀, hi₀⟩ =>
      have hfin : ∃ n, f i₀ = exp2 n := by
        cases h : f i₀ with
        | never => exact absurd h hi₀
        | exp2 n => exact ⟨n, rfl⟩
      match hfin with
      | ⟨n₀, hn₀⟩ =>
        match exists_least (fun n => ∃ i, f i = exp2 n) n₀ n₀ (Nat.le_refl n₀)
            ⟨i₀, hn₀⟩ with
        | ⟨m, ⟨i₁, hi₁⟩, hmin⟩ =>
          refine ⟨i₁, fun i => ?_, fun y hy => hy i₁⟩
          cases h : f i with
          | never => exact zero_addLe (f i₁)
          | exp2 k =>
            rw [hi₁]
            exact addLe_exp2_iff.mpr (hmin k ⟨i, h⟩)

/-- Every family of consensus weights has a supremum. -/
theorem exists_isSup {ι : Type} (f : ι → Prob) : ∃ x, IsSup f x :=
  match exists_attained f with
  | Or.inl h => ⟨0, isSup_zero h⟩
  | Or.inr ⟨i, h⟩ => ⟨f i, h⟩

/-- The aggregation of a family of consensus weights: the probability of its
best member. Noncomputable, because the choice of that member is classical —
the same price `Cost.csum` pays, and for the same reason. -/
noncomputable def csum {ι : Type} (f : ι → Prob) : Prob :=
  Classical.choose (exists_isSup f)

/-- `csum f` is the supremum of `f`. -/
theorem csum_isSup {ι : Type} (f : ι → Prob) : IsSup f (csum f) :=
  Classical.choose_spec (exists_isSup f)

/-- Every member of a family is at most its aggregate. -/
theorem le_csum {ι : Type} (f : ι → Prob) (i : ι) : f i ≤+ csum f :=
  (csum_isSup f).1 i

/-- The aggregate is the least of the family's upper bounds. -/
theorem csum_le {ι : Type} {f : ι → Prob} {y : Prob} (h : ∀ i, f i ≤+ y) :
    csum f ≤+ y :=
  (csum_isSup f).2 y h

/-- Anything that is a supremum of `f` *is* `csum f`. -/
theorem csum_eq {ι : Type} {f : ι → Prob} {x : Prob} (h : IsSup f x) : csum f = x :=
  isSup_unique (csum_isSup f) h

/-- Aggregation respects pointwise equality of families. -/
theorem csum_congr' {ι : Type} {f g : ι → Prob} (h : ∀ i, f i = g i) :
    csum f = csum g :=
  congrArg csum (funext h)

/-- **The aggregate is a member**, unless the whole family is impossible. This
is `exists_attained` read through `csum`, and it is what replaces `Cost`'s
laborious case analysis on whether a supremum is finite. -/
theorem csum_attained {ι : Type} (f : ι → Prob) :
    ((∀ i, f i = 0) ∧ csum f = 0) ∨ ∃ i, csum f = f i :=
  match exists_attained f with
  | Or.inl h => Or.inl ⟨h, csum_eq (isSup_zero h)⟩
  | Or.inr ⟨i, h⟩ => Or.inr ⟨i, csum_eq h⟩

/-- Aggregating impossibilities is impossible. -/
theorem csum_zero' {ι : Type} : csum (fun _ : ι => (0 : Prob)) = 0 :=
  csum_eq (isSup_zero fun _ => rfl)

/-- A family supported at one index aggregates to its one value. -/
theorem csum_point' {ι : Type} (i₀ : ι) (f : ι → Prob) (h : ∀ i, i ≠ i₀ → f i = 0) :
    csum f = f i₀ := by
  refine csum_eq ⟨fun i => ?_, fun y hy => hy i₀⟩
  by_cases he : i = i₀
  · rw [he]
    exact addLe_refl (f i₀)
  · rw [h i he]
    exact zero_addLe (f i₀)

/-- **Two-point agreement at consensus weight**: the supremum of a two-point
family is the better of its two values, which is what `⊕ = max` says. -/
theorem csum_pair' (x y : Prob) : csum (fun b : Bool => cond b x y) = x + y := by
  refine csum_eq ⟨fun b => ?_, fun z hz => add_addLe (hz true) (hz false)⟩
  cases b
  · exact addLe_add_right x y
  · exact addLe_add_left x y

/-- **Sequencing distributes over aggregation**: the infinitary left
distributive law. Attainment does all the work — the aggregate is a member, and
a fixed step before the best member is the best of the stepped members. -/
theorem mul_csum' {ι : Type} (x : Prob) (f : ι → Prob) :
    x * csum f = csum (fun i => x * f i) := by
  match csum_attained f with
  | Or.inl ⟨hall, h0⟩ =>
    have hz : ∀ i, x * f i = 0 := fun i => by rw [hall i, mul_zero]
    rw [h0, mul_zero, csum_congr' hz, csum_zero']
  | Or.inr ⟨i₀, hi₀⟩ =>
    have hstep : ∀ i, x * f i ≤+ x * f i₀ := by
      intro i
      refine mul_addLe_mul_left x ?_
      rw [← hi₀]
      exact le_csum f i
    rw [hi₀]
    exact (csum_eq ⟨hstep, fun y hy => hy i₀⟩).symm

/-- Each member of a doubly-indexed family is below the iterated aggregate. -/
theorem csum_csum_upper {ι κ : Type} (f : ι → κ → Prob) (i : ι) (j : κ) :
    f i j ≤+ csum (fun i => csum (fun j => f i j)) :=
  addLe_trans (le_csum (fun j => f i j) j) (le_csum (fun i => csum (fun j => f i j)) i)

/-- Any bound on all members bounds the iterated aggregate. -/
theorem csum_csum_least {ι κ : Type} (f : ι → κ → Prob) {y : Prob}
    (h : ∀ i j, f i j ≤+ y) : csum (fun i => csum (fun j => f i j)) ≤+ y :=
  csum_le fun i => csum_le fun j => h i j

/-- Fubini: a doubly-indexed family may be aggregated in either order. -/
theorem csum_swap' {ι κ : Type} (f : ι → κ → Prob) :
    csum (fun i => csum (fun j => f i j)) = csum (fun j => csum (fun i => f i j)) :=
  addLe_antisymm
    (csum_csum_least f fun i j => csum_csum_upper (fun j i => f i j) j i)
    (csum_csum_least (fun j i => f i j) fun j i => csum_csum_upper f i j)

/-- Aggregating over a product index is aggregating twice. -/
theorem csum_prod' {ι κ : Type} (f : ι → κ → Prob) :
    csum (fun p : ι × κ => f p.1 p.2) = csum (fun i => csum (fun j => f i j)) :=
  csum_eq ⟨fun p => csum_csum_upper f p.1 p.2,
    fun _ hy => csum_csum_least f fun i j => hy (i, j)⟩

end Prob

/-- Consensus weight is a complete resource semiring: aggregation over an
arbitrary family is the probability of its best member. Noncomputable, because
that member is chosen classically — but *attained*, which is why this instance
costs a fifth of what `Cost`'s costs. -/
noncomputable instance instCompleteCSemiringProb : CompleteCSemiring Prob where
  toCSemiring := instCSemiringProb
  csum := fun {_} f => Prob.csum f
  csum_zero := Prob.csum_zero'
  csum_point := by
    intro ι i₀ f h
    exact Prob.csum_point' i₀ f h
  csum_mul_left := Prob.mul_csum'
  csum_swap := Prob.csum_swap'
  csum_prod := Prob.csum_prod'
  csum_pair := Prob.csum_pair'

/-! ## Expectation: the square-zero extension -/

/-- A `PMod P M` is a representation of the *moments* a resource semiring `P`
can carry: a commutative monoid `M` on which `P` acts. In the expectation
semiring `M` holds the accumulated cost and `P` the probability that weights
it; `smul p m` is "the moment `m`, seen through the weight `p`".

Only the laws the square-zero construction actually consumes are demanded —
they are exactly the module laws. -/
class PMod (P M : Type) [CSemiring P] where
  /-- The absent moment. -/
  zero : M
  /-- Accumulation of moments. -/
  add : M → M → M
  /-- The weighting of a moment by a resource. -/
  smul : P → M → M
  /-- Accumulation is unordered. -/
  add_comm : ∀ m n : M, add m n = add n m
  /-- Accumulation is unbracketed. -/
  add_assoc : ∀ m n o : M, add (add m n) o = add m (add n o)
  /-- The absent moment accumulates nothing. -/
  zero_add : ∀ m : M, add zero m = m
  /-- Weighting the absent moment leaves it absent. -/
  smul_zero : ∀ p : P, smul p zero = zero
  /-- Weighting distributes over accumulation. -/
  smul_add : ∀ (p : P) (m n : M), smul p (add m n) = add (smul p m) (smul p n)
  /-- Weighting distributes over alternatives of resource. -/
  add_smul : ∀ (p q : P) (m : M), smul (p + q) m = add (smul p m) (smul q m)
  /-- Weighting by a sequence is weighting twice. -/
  mul_smul : ∀ (p q : P) (m : M), smul (p * q) m = smul p (smul q m)
  /-- The free step does not reweight. -/
  one_smul : ∀ m : M, smul 1 m = m
  /-- The impossible step erases the moment. -/
  zero_smul : ∀ m : M, smul (0 : P) m = zero

namespace PMod

variable {P M : Type} [CSemiring P] [PMod P M]

/-- The absent moment accumulates nothing on the right either. -/
theorem add_zero (m : M) : PMod.add P m (PMod.zero P) = m := by
  rw [PMod.add_comm, PMod.zero_add]

/-- Two independent weightings commute, because the resource semiring does. -/
theorem smul_comm (p q : P) (m : M) : smul p (smul q m) = smul q (smul p m) := by
  rw [← PMod.mul_smul, ← PMod.mul_smul, mul_comm]

/-- The middle-four interchange for accumulation: the rearrangement the
distributive law needs. -/
theorem add_add_add_comm (a b c d : M) :
    PMod.add P (PMod.add P a b) (PMod.add P c d) = PMod.add P (PMod.add P a c) (PMod.add P b d) := by
  rw [PMod.add_assoc, PMod.add_assoc, ← PMod.add_assoc b c d, ← PMod.add_assoc c b d,
    PMod.add_comm b c]

end PMod

/-- Any resource semiring is a module over itself: the moment is another
resource, weighted by multiplication. This is the instance that makes
`SqZero P P` the dual numbers over `P`. -/
instance instPModSelf {P : Type} [CSemiring P] : PMod P P where
  zero := 0
  add := fun p q => p + q
  smul := fun p q => p * q
  add_comm := add_comm
  add_assoc := add_assoc
  zero_add := zero_add
  smul_zero := mul_zero
  smul_add := left_distrib
  add_smul := right_distrib
  mul_smul := mul_assoc
  one_smul := one_mul
  zero_smul := zero_mul

/-- A `SqZero P M` is a representation of a resource together with a *first
moment* of it: `base` is the weight of the run, `moment` the weighted quantity
carried along with it. This is Eisner's expectation semiring — the same
square-zero extension that gives forward-mode automatic differentiation, with
`moment` playing the part of the derivative — so composition of meanings
computes an expected cost, not merely a possibility. -/
structure SqZero (P M : Type) where
  /-- The weight of the run: a probability, a possibility, a count. -/
  base : P
  /-- The weighted quantity accumulated along the run. -/
  moment : M

namespace SqZero

/-- Two such pairs are equal when their parts are. -/
theorem eq_of_parts {P M : Type} {x y : SqZero P M}
    (hb : x.base = y.base) (hm : x.moment = y.moment) : x = y := by
  cases x with
  | mk b m =>
    cases y with
    | mk b' m' =>
      have hb' : b = b' := hb
      have hm' : m = m' := hm
      rw [hb', hm']

variable {P M : Type} [CSemiring P] [PMod P M]

/-- Alternatives combine componentwise: weights add, moments accumulate. -/
def add (x y : SqZero P M) : SqZero P M :=
  ⟨x.base + y.base, PMod.add P x.moment y.moment⟩

/-- Sequencing multiplies the weights and cross-weights the moments: this is
the product rule, and the reason the extension is called square-zero — a pure
moment times a pure moment is nothing. -/
def mul (x y : SqZero P M) : SqZero P M :=
  ⟨x.base * y.base, PMod.add P (PMod.smul x.base y.moment) (PMod.smul y.base x.moment)⟩

/-- The impossible run, carrying no moment. -/
def zero : SqZero P M := ⟨0, PMod.zero P⟩

/-- The free step, carrying no moment. -/
def one : SqZero P M := ⟨1, PMod.zero P⟩

/-- Alternatives are unordered. -/
theorem add_comm' (x y : SqZero P M) : add x y = add y x :=
  eq_of_parts (Agentic.add_comm _ _) (PMod.add_comm _ _)

/-- Alternatives are unbracketed. -/
theorem add_assoc' (x y z : SqZero P M) : add (add x y) z = add x (add y z) :=
  eq_of_parts (Agentic.add_assoc _ _ _) (PMod.add_assoc _ _ _)

/-- The impossible run contributes nothing. -/
theorem zero_add' (x : SqZero P M) : add zero x = x :=
  eq_of_parts (Agentic.zero_add _) (PMod.zero_add _)

/-- Sequencing is order-insensitive: the cross terms swap. -/
theorem mul_comm' (x y : SqZero P M) : mul x y = mul y x :=
  eq_of_parts (Agentic.mul_comm _ _) (PMod.add_comm _ _)

/-- Sequencing is unbracketed. -/
theorem mul_assoc' (x y z : SqZero P M) : mul (mul x y) z = mul x (mul y z) := by
  refine eq_of_parts (Agentic.mul_assoc _ _ _) ?_
  show PMod.add P (PMod.smul (x.base * y.base) z.moment)
      (PMod.smul z.base (PMod.add P (PMod.smul x.base y.moment) (PMod.smul y.base x.moment)))
    = PMod.add P (PMod.smul x.base (PMod.add P (PMod.smul y.base z.moment)
        (PMod.smul z.base y.moment)))
      (PMod.smul (y.base * z.base) x.moment)
  rw [PMod.smul_add, PMod.smul_add, PMod.mul_smul, PMod.mul_smul,
    PMod.smul_comm z.base x.base y.moment, PMod.smul_comm z.base y.base x.moment,
    PMod.add_assoc]

/-- The free step costs nothing and carries nothing. -/
theorem one_mul' (x : SqZero P M) : mul one x = x := by
  refine eq_of_parts (Agentic.one_mul _) ?_
  show PMod.add P (PMod.smul (1 : P) x.moment) (PMod.smul x.base (PMod.zero P)) = x.moment
  rw [PMod.one_smul, PMod.smul_zero, PMod.add_zero]

/-- The free step costs nothing after, either: the right unit law, which the
base class asks for as a field and which a commutative carrier answers with one
rewrite. -/
theorem mul_one' (x : SqZero P M) : mul x one = x :=
  (mul_comm' x one).trans (one_mul' x)

/-- Sequencing distributes over alternatives. -/
theorem left_distrib' (x y z : SqZero P M) : mul x (add y z) = add (mul x y) (mul x z) := by
  refine eq_of_parts (Agentic.left_distrib _ _ _) ?_
  show PMod.add P (PMod.smul x.base (PMod.add P y.moment z.moment))
      (PMod.smul (y.base + z.base) x.moment)
    = PMod.add P (PMod.add P (PMod.smul x.base y.moment) (PMod.smul y.base x.moment))
      (PMod.add P (PMod.smul x.base z.moment) (PMod.smul z.base x.moment))
  rw [PMod.smul_add, PMod.add_smul, PMod.add_add_add_comm]

/-- Sequencing distributes over alternatives on the right too. -/
theorem right_distrib' (x y z : SqZero P M) :
    mul (add x y) z = add (mul x z) (mul y z) := by
  rw [mul_comm' (add x y) z, left_distrib' z x y, mul_comm' z x, mul_comm' z y]

/-- The impossible run stays impossible, moment and all. -/
theorem zero_mul' (x : SqZero P M) : mul zero x = zero := by
  refine eq_of_parts (Agentic.zero_mul _) ?_
  show PMod.add P (PMod.smul (0 : P) x.moment) (PMod.smul x.base (PMod.zero P))
    = PMod.zero P
  rw [PMod.zero_smul, PMod.smul_zero, PMod.add_zero]

/-- An impossible step downstream is still impossible. -/
theorem mul_zero' (x : SqZero P M) : mul x zero = zero :=
  (mul_comm' x zero).trans (zero_mul' x)

end SqZero

/-- Eisner's expectation semiring: the square-zero extension of `P` by `M`.
Composition in this semiring computes an expected cost — the base component
carries the probability, the moment component the probability-weighted cost —
which is precisely how forward-mode automatic differentiation carries a
derivative alongside a value. -/
instance instCSemiringSqZero {P M : Type} [CSemiring P] [PMod P M] :
    CSemiring (SqZero P M) where
  add := SqZero.add
  mul := SqZero.mul
  zero := SqZero.zero
  one := SqZero.one
  add_comm := SqZero.add_comm'
  add_assoc := SqZero.add_assoc'
  zero_add := SqZero.zero_add'
  mul_comm := SqZero.mul_comm'
  mul_assoc := SqZero.mul_assoc'
  one_mul := SqZero.one_mul'
  mul_one := SqZero.mul_one'
  left_distrib := SqZero.left_distrib'
  right_distrib := SqZero.right_distrib'
  zero_mul := SqZero.zero_mul'
  mul_zero := SqZero.mul_zero'

namespace SqZero

variable {P M : Type} [CSemiring P] [PMod P M]

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
    (⟨0, m⟩ : SqZero P M) * (⟨0, n⟩ : SqZero P M) = 0 := by
  refine eq_of_parts (Agentic.zero_mul _) ?_
  show PMod.add P (PMod.smul (0 : P) n) (PMod.smul (0 : P) m) = PMod.zero P
  rw [PMod.zero_smul, PMod.zero_smul, PMod.zero_add]

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
the style of `IdemAdd`. Extending would put a second `PMod P M` in scope
whenever `M` is `P` — one from `instPModSelf`, one from the parent projection —
and the `CSemiring (SqZero P M)` used by the semiring laws would then have to
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

Every field is the moment-side twin of a `CompleteCSemiring` field, save the
last, which is the only genuinely new law: it says the two aggregations agree
when a family of *weights* acts on one fixed moment. Without it the
distributive law for the square-zero `csum` cannot be proved, because the
cross-term of the product rule weights a fixed moment by every member of an
aggregated family of weights. -/
class CompletePMod (P M : Type) [CompleteCSemiring P] [PMod P M] where
  /-- The accumulation of a whole family of moments: `msum f = ⊕ᵢ f i`. -/
  msum : {ι : Type} → (ι → M) → M
  /-- Accumulating absent moments leaves the moment absent. -/
  msum_zero : ∀ {ι : Type}, msum (fun _ : ι => PMod.zero P) = PMod.zero P
  /-- A family supported at one index accumulates to its one moment. -/
  msum_point : ∀ {ι : Type} (i₀ : ι) (f : ι → M),
    (∀ i, i ≠ i₀ → f i = PMod.zero P) → msum f = f i₀
  /-- Fubini for moments: a doubly-indexed family accumulates in either order. -/
  msum_swap : ∀ {ι κ : Type} (f : ι → κ → M),
    msum (fun i => msum (fun j => f i j)) = msum (fun j => msum (fun i => f i j))
  /-- Accumulating over a product index is accumulating twice. -/
  msum_prod : ∀ {ι κ : Type} (f : ι → κ → M),
    msum (fun p : ι × κ => f p.1 p.2) = msum (fun i => msum (fun j => f i j))
  /-- **Two-point agreement for moments**: accumulating a family of two agrees
  with binary accumulation. The moment-side half of the `csum_pair` obligation
  that `Agentic.Semiring` charges every complete carrier. -/
  msum_pair : ∀ m n : M, msum (fun b : Bool => cond b m n) = PMod.add P m n
  /-- Weighting distributes over accumulation: a fixed weight may be pushed
  under the aggregation sign. -/
  smul_msum : ∀ {ι : Type} (p : P) (f : ι → M),
    PMod.smul p (msum f) = msum (fun i => PMod.smul p (f i))
  /-- **The two aggregations agree on a fixed moment**: weighting by an
  aggregate of weights is accumulating the weightings. This is the law that
  makes the square-zero infinitary distributive law true, and it is the only
  field with no counterpart in `CompleteCSemiring`. -/
  csum_smul : ∀ {ι : Type} (g : ι → P) (m : M),
    PMod.smul (csum g) m = msum (fun i => PMod.smul (g i) m)

export CompletePMod (msum)

namespace CompletePMod

variable {P M : Type} [CompleteCSemiring P] [PMod P M] [CompletePMod P M]

/-- Accumulation respects pointwise equality of families. -/
theorem msum_congr {ι : Type} {f g : ι → M} (h : ∀ i, f i = g i) :
    msum P f = msum P g :=
  congrArg (msum P) (funext h)

/-- Any family of moments indexed by `Bool` accumulates to the sum of its two
values: `msum_pair` with the `cond` presentation stripped away. -/
theorem msum_bool (g : Bool → M) : msum P g = PMod.add P (g true) (g false) := by
  rw [← msum_pair (g true) (g false)]
  exact msum_congr fun b => by cases b <;> rfl

/-- **Accumulation of moments is additive**: `⊕ᵢ (mᵢ + nᵢ) = (⊕ᵢ mᵢ) + (⊕ᵢ nᵢ)`.
The proof is `Agentic.csum_add` transported to the moment side — replace each
binary sum by an accumulation over `Bool`, exchange by Fubini, read the outer
one back — and it is what the product rule's two cross-terms need in order to
be separated under the aggregation sign. -/
theorem msum_add {ι : Type} (x y : ι → M) :
    msum P (fun i => PMod.add P (x i) (y i)) = PMod.add P (msum P x) (msum P y) :=
  calc msum P (fun i => PMod.add P (x i) (y i))
      = msum P (fun i => msum P fun b : Bool => cond b (x i) (y i)) :=
        msum_congr fun i => (msum_pair (x i) (y i)).symm
    _ = msum P (fun b : Bool => msum P fun i => cond b (x i) (y i)) :=
        msum_swap fun i (b : Bool) => cond b (x i) (y i)
    _ = PMod.add P (msum P fun i => cond true (x i) (y i))
          (msum P fun i => cond false (x i) (y i)) :=
        msum_bool fun b : Bool => msum P fun i => cond b (x i) (y i)
    _ = PMod.add P (msum P x) (msum P y) := rfl

end CompletePMod

/-- **Any complete resource semiring is a complete module over itself**, with
`csum` for `msum`: every law of the class is a law the semiring already has,
and the mixed law `csum_smul` is `csum_mul_right`. This is the instance that
makes `SqZero P P` — the dual numbers over `P` — a complete semiring, and with
it `Mat.comp` elaborates over the expectation semiring at every carrier the
package owns. -/
instance instCompletePModSelf {P : Type} [CompleteCSemiring P] : CompletePMod P P where
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

/-- **A module of moments need not be the weights.** Two moment modules
side by side are a moment module: `SqZero P (M × N)` carries two first moments
at once — an expected cost and an expected latency, say — weighted by one
probability.

The instance exists to answer a real gap rather than to be used: before it, the
only `PMod` in the package was the diagonal `instPModSelf`, so "`M` is a
`P`-module of costs" (design §3) was a phrase with exactly one witness, and the
class could not be told apart from a redundant copy of `P`. -/
instance instPModProd {P M N : Type} [CSemiring P] [PMod P M] [PMod P N] :
    PMod P (M × N) where
  zero := (PMod.zero P, PMod.zero P)
  add := fun a b => (PMod.add P a.1 b.1, PMod.add P a.2 b.2)
  smul := fun p a => (PMod.smul p a.1, PMod.smul p a.2)
  add_comm _ _ := prod_eq_of_parts (PMod.add_comm _ _) (PMod.add_comm _ _)
  add_assoc _ _ _ := prod_eq_of_parts (PMod.add_assoc _ _ _) (PMod.add_assoc _ _ _)
  zero_add _ := prod_eq_of_parts (PMod.zero_add _) (PMod.zero_add _)
  smul_zero _ := prod_eq_of_parts (PMod.smul_zero _) (PMod.smul_zero _)
  smul_add _ _ _ := prod_eq_of_parts (PMod.smul_add _ _ _) (PMod.smul_add _ _ _)
  add_smul _ _ _ := prod_eq_of_parts (PMod.add_smul _ _ _) (PMod.add_smul _ _ _)
  mul_smul _ _ _ := prod_eq_of_parts (PMod.mul_smul _ _ _) (PMod.mul_smul _ _ _)
  one_smul _ := prod_eq_of_parts (PMod.one_smul _) (PMod.one_smul _)
  zero_smul _ := prod_eq_of_parts (PMod.zero_smul _) (PMod.zero_smul _)

/-- Two complete moment modules side by side aggregate componentwise, so the
two-moment expectation semiring is complete as well. -/
instance instCompletePModProd {P M N : Type} [CompleteCSemiring P]
    [PMod P M] [PMod P N] [CompletePMod P M] [CompletePMod P N] :
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

variable {P M : Type} [CompleteCSemiring P] [PMod P M] [CompletePMod P M]

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
  · show msum P (fun _ : ι => PMod.zero P) = PMod.zero P
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
  · show PMod.add P (PMod.smul x.base (msum P fun i => (F i).moment))
          (PMod.smul (Agentic.csum fun i => (F i).base) x.moment)
        = msum P (fun i =>
            PMod.add P (PMod.smul x.base (F i).moment) (PMod.smul (F i).base x.moment))
    rw [CompletePMod.msum_add (fun i => PMod.smul x.base (F i).moment)
        (fun i => PMod.smul (F i).base x.moment),
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
    [CompleteCSemiring P] [PMod P M] [CompletePMod P M] :
    CompleteCSemiring (SqZero P M) where
  toCSemiring := instCSemiringSqZero
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
theorem star_base_key {P : Type} [CSemiring P] (p q : P) (h : q = 1 + p * q) :
    q * q = p * (q * q) + q :=
  calc q * q = (1 + p * q) * q := by rw [← h]
    _ = 1 * q + p * q * q := right_distrib _ _ _
    _ = q + p * (q * q) := by rw [one_mul, mul_assoc]
    _ = p * (q * q) + q := add_comm _ _

variable {P M : Type} [CSemiring P] [PMod P M] [StarSemiring P]

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
instance instStarSemiringSqZero : StarSemiring (SqZero P M) where
  star := fun x => ⟨star x.base, PMod.smul (star x.base * star x.base) x.moment⟩
  star_eq_left := by
    intro x
    refine eq_of_parts (StarSemiring.star_eq_left x.base) ?_
    show PMod.smul (star x.base * star x.base) x.moment
        = PMod.add P (PMod.zero P)
            (PMod.add P
              (PMod.smul x.base (PMod.smul (star x.base * star x.base) x.moment))
              (PMod.smul (star x.base) x.moment))
    rw [PMod.zero_add, ← PMod.mul_smul, ← PMod.add_smul,
      ← star_base_key x.base (star x.base) (StarSemiring.star_eq_left x.base)]

/-- **The expectation star, read out**: its weight is the weight's star and its
moment is `p* m p*`. True by `rfl` — it is the definition — and stated because
the design's formula deserves a name that a reader can grep for. -/
theorem star_moment (x : SqZero P M) :
    (star x).moment = PMod.smul (star x.base * star x.base) x.moment := rfl

/-- The weight of the star is the star of the weight: forgetting the moment
commutes with iteration, so the first projection is a homomorphism of *starred*
semirings and not merely of semirings. This is the fibration of design §3 with
the star included: the probability factor of a loop is the loop of the
probability factors. -/
theorem pi_star (x : SqZero P M) : pi (star x) = star (pi x) := rfl

/-- **`p* m p*`, literally.** At the dual numbers — the moment module is the
carrier itself — the expectation star's moment is the design's `p* · m · p*`
with the multiplications written out and in the design's order. -/
theorem star_moment_dual (x : SqZero P P) :
    (star x).moment = star x.base * x.moment * star x.base := by
  show star x.base * star x.base * x.moment = star x.base * x.moment * star x.base
  rw [mul_assoc, mul_assoc, mul_comm (star x.base) x.moment]

end SqZero

end Agentic
