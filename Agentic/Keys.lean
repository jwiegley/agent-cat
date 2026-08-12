import Agentic.Instances
import Agentic.Panel
import Agentic.Trace

/-!
# Keys: inhabiting the convolution algebra, one carrier per meaning

`Panel` develops the monoid semiring `S⟨K⟩` abstractly: the key monoid `K` is a
class, and no theorem there names a single concrete key type. This module pays
the inhabitation debt. It exhibits the key monoids the design actually appeals
to — the free monoid of ordered findings, the counting monoid of tallies, the
`max` monoid of widths, the "any" monoid of speculative races — and it checks,
by elaborating `MSemiring.conv` at a literal instantiation, that the classes of
`Panel` really do compose into a usable algebra rather than merely into a
consistent set of axioms.

**Newtype discipline.** `PMonoid` and `CMonoid` are keyed by their carrier, so
an instance is a package-wide claim about what `⋄` means on that type. `Nat`
carries at least two monoid structures the design wants at once — addition, for
tallies, and `max`, for the width fold of §2/§7 — and a bare `CMonoid Nat`
instance would silently decide which one every later `⋄` on a natural number
means, with the loser becoming un-writable and any second instance changing the
meaning of code that was already written. So no bare `Nat` instance is declared
here: `Tally` and `Width` are separate carriers, each owning its own operation,
and the type of a verdict says which fold it belongs to. `List` keeps its
instance because the free monoid genuinely owns `List` — concatenation is the
only monoid structure `List α` has for arbitrary `α`.

The instances also straddle the distinctions `Panel` insists on. `List α` is
*not* commutative, and convolution over it is still a panel: order-sensitive
fan-in is a legitimate verdict type. `Tally` and `Width` *are* commutative, so
the scheduler may reorder (`foldPanel_perm`, and `MSemiring.convFold_perm` for
the same licence about the weighting rather than the list). `Width` and `Bool`
are moreover *idempotent*, which is the stronger licence — duplication is free
(`foldPanel_dup`, `MSemiring.convFold_dup`), and that is what makes
at-least-once delivery, speculative execution and racing safe.
-/

namespace Agentic

/-- Panel keys: the free monoid — order-sensitive fan-in (unionFindings-style)
convolves over it. A member's contribution is the list of findings it reported,
combination is concatenation, and the empty panel reports nothing. Nothing
identifies `[a, b]` with `[b, a]`: two reviewers' findings arrive in an order,
that order survives fan-in, and the convolution theorems of `Panel` hold
regardless — which is exactly the claim that commutativity is a separate
licence rather than part of what a panel is.

This is the one carrier that may keep a bare instance: concatenation is the
only monoid `List α` carries for an arbitrary `α`, so nothing is being decided
on anyone else's behalf.

**The monoid itself is Mathlib's `FreeMonoid α`**, which is *defined* as a
synonym for `List α` with `*` given by `++`; the instance below is that
instance, transported along the synonym, and the four law proofs the package
used to carry are gone. Mathlib keeps the synonym precisely so that `List α`
carries no `Mul` — the one deliberate difference here is that this package does
put the instance on `List α` itself, because the panel algebra is generic in a
`Monoid` and every use site would otherwise be spelled `FreeMonoid.ofList`. -/
instance instPMonoidList {α : Type} : Monoid (List α) :=
  inferInstanceAs (Monoid (FreeMonoid α))

/-- A `Tally` is a representation of a *counted* verdict: votes cast, findings
counted, tokens spent. It is a wrapper on `Nat` rather than `Nat` itself
because the counting monoid is one of several structures `Nat` carries, and
the class that interprets `⋄` is keyed by the carrier — the wrapper is what
keeps `Width` (below) writable at all.

**The wrapper is Mathlib's `Multiplicative ℕ`**: writing an additive monoid
multiplicatively is exactly what `Multiplicative` is for, and the package
already uses it for `Cost` (`Agentic.Instances`). So `Tally` is a synonym, not
a structure, and its `CommMonoid` is `Nat`'s additive one, transported —
nothing about counting is re-proved here. -/
def Tally : Type := Multiplicative Nat

/-- The tally that counts `n`: `Multiplicative.ofAdd`, under the package's
constructor name. -/
def Tally.mk (n : Nat) : Tally := Multiplicative.ofAdd n

/-- The count a tally records: `Multiplicative.toAdd`, under the package's
projection name. -/
def Tally.val (t : Tally) : Nat := Multiplicative.toAdd t

/-- Counting reducers: tallies under addition are a commutative key monoid.
Because `op_comm` holds, `foldPanel_perm` applies: the scheduler may run the
members in any order it likes, and the tally is unchanged. Note that it is
*not* idempotent — counting the same member twice counts twice — so a tally
panel gets no duplication licence, which is the honest statement of why
at-least-once delivery corrupts a count.

The instance is Mathlib's `Multiplicative.commMonoid` at `ℕ`; the four laws are
`Nat`'s addition laws, which the package no longer restates. -/
instance instCMonoidTally : CommMonoid Tally :=
  inferInstanceAs (CommMonoid (Multiplicative Nat))

/-- Tallies have decidable equality, being counts: `Nat`'s instance,
transported. -/
instance instDecidableEqTally : DecidableEq Tally :=
  inferInstanceAs (DecidableEq Nat)

/-- A `Width` is a representation of a *width* verdict: how wide a fan-out
got, how deep a queue went, how many members a panel ran at once. Its monoid
is `max`, not `+` — the design's width fold (§2, §7) is a monoid and not a
semiring factor, and reporting the worst width of two shards is taking their
maximum, not their sum. -/
structure Width where
  /-- The width. -/
  val : Nat
  deriving DecidableEq, Repr

/-- The width fold: widths under `max` are an *idempotent* commutative key
monoid, with `0` — nothing ran — as the unit. This is the instance that a bare
`CMonoid Nat` would have made unwritable, and the reason the two carriers are
distinct types.

Idempotence is claimed at the class (`IdemCMonoid`) rather than exhibited as a
loose theorem, which is what makes the duplication licence and the induced
order available here without proving either again.

**Survivor, and exactly what Mathlib lacks.** Mathlib has `max` on `ℕ` as a
`SemilatticeSup` with `⊥ = 0` (`OrderBot`), and it has `Std.Associative`,
`Std.Commutative` and `Std.IdempotentOp` for `⊔` — but it has no `Monoid` whose
`*` is a join, and no type synonym (a `Multiplicative`-for-`⊔`) that would
manufacture one, because installing `Mul := ⊔` on a lattice would collide with
every genuine multiplication. The panel algebra (`Agentic.MSemiring`) is
generic in a `Monoid` on the key, so the join has to be presented as one
somewhere; that is this instance, and its four laws are Mathlib's `Nat.max_*`
lemmas rather than new proofs. -/
instance instCMonoidWidth : CommMonoid Width where
  mul := fun a b => ⟨max a.val b.val⟩
  one := ⟨0⟩
  npow n a := Nat.rec ⟨0⟩ (fun _ ih => ⟨max ih.val a.val⟩) n
  mul_assoc := fun a b c => congrArg Width.mk (Nat.max_assoc a.val b.val c.val)
  one_mul := fun a => congrArg Width.mk (Nat.max_eq_right (Nat.zero_le a.val))
  mul_one := fun a => congrArg Width.mk (Nat.max_eq_left (Nat.zero_le a.val))
  mul_comm := fun a b => congrArg Width.mk (Nat.max_comm a.val b.val)

/-- The width fold is idempotent: the duplication licence at `Width`, in
Mathlib's unbundled form. -/
instance instIdemCMonoidWidth : IdemCMonoid Width :=
  ⟨fun a => congrArg Width.mk (Nat.max_self a.val)⟩

/-- Widths are linearly ordered by the width they record, and that order *is*
the one the fold induces (`width_le_iff`). It is Mathlib's, transported along
the wrapper — the package no longer builds an order out of the join by hand. -/
instance instLinearOrderWidth : LinearOrder Width :=
  LinearOrder.lift' Width.val (fun a b h => by cases a; cases b; cases h; rfl)

/-- Speculative verdicts: `Bool` under "or", with `false` — nobody answered —
as the unit. This is the reducer of a race: several members are launched at
the same question and the panel's verdict is that *some* member answered yes;
hearing the same yes twice is hearing it once, so the monoid is idempotent and
says so.

**Survivor, for the same reason as `Width`, and with one hazard named.** `Bool`
is a Mathlib `BooleanAlgebra`, so `∨` is its `⊔` with `false` as `⊥`, and again
Mathlib carries no `Monoid` at a join. The hazard is that Mathlib *does* carry
a different multiplication on `Bool`: `Mathlib/Algebra/Ring/BooleanRing.lean`
installs `Mul Bool := and` as part of `BooleanRing Bool`. That file is not in
this package's import graph (checked), so `⋄` on `Bool` is unambiguous here;
should it ever be imported, two `Mul Bool` instances would disagree and the
race reducer would have to move to a newtype, exactly as `Tally` and `Width`
did for `Nat`. -/
instance instCMonoidBool : CommMonoid Bool where
  mul := or
  one := false
  npow n b := Nat.rec false (fun _ ih => or ih b) n
  mul_assoc := Bool.or_assoc
  one_mul := Bool.false_or
  mul_one := Bool.or_false
  mul_comm := Bool.or_comm

/-- Racing is idempotent: hearing the same yes twice is hearing it once. -/
instance instIdemCMonoidBool : IdemCMonoid Bool := ⟨by decide⟩

/-- Concatenation of findings is the key operation, definitionally. -/
theorem list_op_eq_append {α : Type} (l l' : List α) : l ⋄ l' = l ++ l' := rfl

/-- Tallying is addition, definitionally. -/
theorem tally_op_eq_add (m n : Tally) : m ⋄ n = Tally.mk (m.val + n.val) := rfl

/-- The width fold is `max`, definitionally. -/
theorem width_op_eq_max (m n : Width) : m ⋄ n = ⟨max m.val n.val⟩ := rfl

/-- Racing is disjunction, definitionally. -/
theorem bool_op_eq_or (a b : Bool) : a ⋄ b = (a || b) := rfl

/-- The free key monoid is genuinely non-commutative, so `Panel`'s refusal to
assume `op_comm` is not idle generality: here is a panel whose verdict does
depend on the order in which its two members reported. -/
theorem list_op_not_comm : ∃ l l' : List Nat, l ⋄ l' ≠ l' ⋄ l :=
  ⟨[0], [1], by decide⟩

/-! ### The duplication licence, inhabited

`foldPanel_dup` says that an idempotent reducer is indifferent to a panel run
twice. Until now nothing in the development satisfied its hypothesis, so the
design's speculate/race licence was a theorem about no one. These two
instances witness it: racing on "any member said yes", and folding widths by
`max`. -/

/-- Racing is idempotent: hearing the same yes twice is hearing it once (the
class field, at `Bool`). -/
theorem bool_or_idem : ∀ b : Bool, b ⋄ b = b := IdemCMonoid.op_idem

/-- The width fold is idempotent: two shards of the same width are that
width. -/
theorem width_op_idem (w : Width) : w ⋄ w = w := IdemCMonoid.op_idem w

/-- **The speculation licence, applied.** A raced panel may be delivered
twice — at-least-once delivery, a retried member, a duplicate reply — and its
verdict is unchanged. This is `foldPanel_dup` at a carrier that actually
satisfies its hypothesis, which is what makes the licence a fact about the
design rather than about an empty class of reducers. -/
example (l : List Bool) : foldPanel (l ++ l) = foldPanel l :=
  foldPanel_dup bool_or_idem l

/-- The same licence for the width fold: re-reporting a shard's width does not
inflate the panel's. -/
example (l : List Width) : foldPanel (l ++ l) = foldPanel l :=
  foldPanel_dup width_op_idem l

/-- **The same two licences, at the denotation.** The three theorems above are
about lists; these two are about the weightings those lists denote, and they
are the form in which the licences are worth having. Racing a panel of `Bool`
verdicts and delivering it twice denotes the *same element of* `Prop⟨Bool⟩` —
not merely the same reduced verdict. -/
example (l : List Bool) :
    (MSemiring.convFold (l ++ l) : MSemiring Prop Bool) = MSemiring.convFold l :=
  MSemiring.convFold_dup l

/-- And the scheduler's reorder licence at the width fold, denotationally: the
order the shards report in is not part of the panel's meaning. -/
example {l l' : List Width} (hp : l.Perm l') :
    (MSemiring.convFold l : MSemiring Prop Width) = MSemiring.convFold l' :=
  MSemiring.convFold_perm hp

/-- The order licence is not vacuous generality either: at the free key monoid
`convFold` is order-*sensitive*, which is `list_op_not_comm` read at the
denotation — two panels of the same two certain members, differing only in the
order of the members, are different weightings. -/
example : (MSemiring.convFold [[0], [1]] : MSemiring Prop (List Nat))
    ≠ MSemiring.convFold [[1], [0]] := by
  intro h
  have h' := congrFun h (foldPanel [[0], [1]])
  rw [MSemiring.convFold_delta, MSemiring.convFold_delta,
    MSemiring.delta_self, MSemiring.delta_of_ne (by decide)] at h'
  have h1 : (1 : Prop) := True.intro
  rw [h'] at h1
  exact h1

/-! ### The order the width fold came with

An idempotent commutative reducer induces a partial order (`IdemCMonoid.le`),
and `Width` gets it for nothing: `w ≤ w'` means combining the two widths
reports `w'`, which is to say `w` was never the wider. The design's width fold
is therefore not merely a monoid but an ordered one, and comparisons of widths
are equations in that monoid rather than an extra structure to define. -/

/-- A narrower shard is below a wider one, and the proof is the fold itself:
`⟨2⟩ ⋄ ⟨5⟩` computes to `⟨5⟩`, so the order holds by `rfl`. -/
example : IdemCMonoid.le (Width.mk 2) (Width.mk 5) := by decide

/-- And the false comparison is refuted just as directly: the width order is
not a matter of opinion about which shard mattered. -/
example : ¬ IdemCMonoid.le (Width.mk 5) (Width.mk 2) := by decide

/-- The width order *is* the order of `Nat`, unfolded: the generic construction
lands where the design says the width fold lands. -/
theorem width_le_iff {m n : Nat} :
    IdemCMonoid.le (Width.mk m) (Width.mk n) ↔ m ≤ n := Iff.rfl

/-- **And it is still the order the fold induces.** `Width`'s order is now
Mathlib's, lifted from `Nat`, rather than defined as `w ⋄ w' = w'`; this is the
theorem that the two agree, so nothing the old construction said about the
width fold has been given up in the move. -/
theorem width_le_iff_op {a b : Width} : a ≤ b ↔ a ⋄ b = b := by
  constructor
  · intro h
    exact congrArg Width.mk (Nat.max_eq_right h)
  · intro h
    have h' : max a.val b.val = b.val := congrArg Width.val h
    show a.val ≤ b.val
    exact h' ▸ Nat.le_max_left a.val b.val

/-- A raced panel of three members answers yes when any of them does. -/
example : foldPanel [false, true, false] = true := rfl

/-- The convolution algebra is inhabited: at `S := Prop` (possibility, from
`Instances`) and `K := List Nat` (ordered findings, above) `MSemiring.conv`
elaborates, so the two classes `CompleteCSemiring` and `PMonoid` are
simultaneously satisfiable at a literal instantiation. The weighting convolved
here is the panel of two members, one certain to report nothing and one certain
to report the single finding `1`. -/
example : MSemiring Prop (List Nat) :=
  MSemiring.conv (fun k => k = []) (fun k => k = [1])

/-- The same at a commutative key monoid, where the scheduler's licence holds:
convolution over tallies elaborates too. -/
example : MSemiring Prop Tally :=
  MSemiring.conv (fun n => n = Tally.mk 0) (fun n => n = Tally.mk 1)

/-- And at the width fold, the design's other commutative reducer. -/
example : MSemiring Prop Width :=
  MSemiring.conv (fun w => w = ⟨0⟩) (fun w => w = ⟨1⟩)

/-- Fan-in over the free monoid is concatenation of the members' reports: the
reducer of a panel of findings is `unionFindings` up to the choice of a list as
the report type. -/
example : foldPanel [[0], [1], ([2] : List Nat)] = [0, 1, 2] := rfl

/-- Fan-in over tallies is the sum of the members' counts. -/
example : foldPanel [Tally.mk 2, Tally.mk 3, Tally.mk 4] = Tally.mk 9 := rfl

/-- Fan-in over widths is the worst width, not the total. -/
example : foldPanel [Width.mk 2, Width.mk 3, Width.mk 4] = ⟨4⟩ := rfl

/-! ### The key monoid that decidability excluded

`MSemiring` once demanded `DecidableEq K`, and that demand was not free: it
silently restricted the panel keys to those whose verdicts a program can
compare. The Mazurkiewicz trace monoid (`Agentic.Trace`) is the case that
restriction cost the design. A trace is a class of the quotient of schedules by
an inductively generated equivalence; two histories are equal when finitely
many exchanges of adjacent independent turns carry one to the other, and
nothing decides that. So `Trace ind` could not be a panel key at all — the one
key monoid the design builds *for* concurrency was the one the panel algebra
could not accept.

With the decidability evicted (acat-192) it is a key like any other, and the
examples below are the demonstration: the type elaborates, and the convolution
laws hold at it. -/

/-- **The payoff.** `MSemiring S (Trace ind)` elaborates at an arbitrary
alphabet, an arbitrary independence relation and an arbitrary carrier: a panel
whose verdict is *the history that occurred, up to scheduling*, with
convolution combining two members' histories by concatenation. -/
noncomputable example {S A : Type} [CompleteCSemiring S] {ind : A → A → Prop}
    (f g : MSemiring S (Trace ind)) : MSemiring S (Trace ind) :=
  MSemiring.conv f g

/-- The trace key is not merely typeable but usable: convolution over histories
is associative, so a panel of panels of sessions is a panel of sessions and the
bracketing of the members is not part of the meaning. -/
example {S A : Type} [CompleteCSemiring S] {ind : A → A → Prop}
    (f g h : MSemiring S (Trace ind)) :
    MSemiring.conv (MSemiring.conv f g) h = MSemiring.conv f (MSemiring.conv g h) :=
  MSemiring.conv_assoc f g h

/-- The same at a literal instantiation, so that nothing is hiding in the
generality: possibility weights over histories of `Nat`-turns in which every
pair of turns is independent — the fully concurrent alphabet, whose traces are
multisets of turns. The panel convolved is one member certain to have done
nothing and one certain to have taken the turn `0`. -/
example : MSemiring Prop (Trace (fun _ _ : Nat => True)) :=
  MSemiring.conv (fun t => t = 1) (fun t => t = Trace.single 0)

/-- The augmentation homomorphism holds at the trace key too: the total weight
of a panel of sessions is the product of the halves' totals, which is the audit
fact of `Panel` stated where the keys are histories. -/
example {S A : Type} [CompleteCSemiring S] {ind : A → A → Prop}
    (f g : MSemiring S (Trace ind)) :
    MSemiring.total (MSemiring.conv f g) = MSemiring.total f * MSemiring.total g :=
  MSemiring.total_conv f g

end Agentic
