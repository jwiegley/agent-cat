import Mathlib.Algebra.Group.Prod
import Mathlib.Order.Lattice
import Mathlib.Order.BoundedOrder.Lattice

/-!
# One monoid, one action, one order — now Mathlib's

Combination is the most-repeated structure in this package. Panel keys
combine, scopes nest, histories concatenate, fragment grades join, costs take
their worst case. This module used to *state* that algebra: three classes
(`PMonoid`, `CMonoid`, `IdemCMonoid`), a `⋄` notation, and a fourteen-line
development of the order an idempotent join induces.

None of that is stated here any more, because all of it is in Mathlib, and as
of this arc none of it is *spelled* here any more either: the binders say
`Monoid`, `CommMonoid` and `Std.IdempotentOp (· * ·)`, combination is written
`*`, and the order is `≤` of `SemilatticeSup` + `OrderBot`. The three old class
names survive for one line each, `@[deprecated]`, solely because
`doc/walkthrough.html` still spells them; nothing in the package consumes them.

**The two actions on a reader** are the one thing that does not come from
Mathlib, and they are what this module is now for (`actR`, `actL`, and their
four laws), with the survivor docstring the migration policy requires.

Nothing in this module mentions a semiring, an aggregation or a matrix: it is
below all of them.
-/

namespace Agentic

/-- `PMonoid K` is Mathlib's `Monoid K`. Deprecated compatibility alias: the
name is still spelled in `doc/walkthrough.html`, and nothing in the package
uses it. -/
@[deprecated Monoid (since := "2026-08-12")]
abbrev PMonoid (K : Type) := Monoid K

/-- `CMonoid K` is Mathlib's `CommMonoid K`. Deprecated compatibility alias,
kept only because `doc/walkthrough.html` still spells it. -/
@[deprecated CommMonoid (since := "2026-08-12")]
abbrev CMonoid (K : Type) := CommMonoid K

/-- `IdemCMonoid K` is Mathlib's `Std.IdempotentOp` at `*`. Deprecated
compatibility alias, kept only because `doc/walkthrough.html` still spells
it. -/
@[deprecated Std.IdempotentOp (since := "2026-08-12")]
abbrev IdemCMonoid (K : Type) [CommMonoid K] := Std.IdempotentOp (α := K) (· * ·)

/-! ## The join, presented as a monoid

Several of the package's reducers *are* joins: the width fold of §2/§7 is
`max` on `ℕ`, the race reducer of the speculate/race licence is `or` on
`Bool`. The panel algebra (`Agentic.MSemiring`) is generic in a `Monoid` on the
key, so a join has to be presented as one somewhere. `SupMon` is that
presentation, written once.

**Survivor, and exactly what Mathlib lacks.** Mathlib has the join
(`SemilatticeSup`), its unit (`OrderBot`), and the unbundled facts that `⊔` is
associative, commutative and idempotent (`Std.Associative`, `Std.Commutative`,
`Std.IdempotentOp` in `Mathlib/Order/Lattice.lean`). What it has nowhere is a
`Monoid` whose `*` is `⊔`, nor the type synonym that would carry one — a
`Multiplicative`-for-joins. It cannot install such an instance on the carrier
itself, for the same reason this module cannot: `Mul` on a lattice is spoken
for by whatever genuine multiplication the carrier already has (`ℕ`'s, `Bool`'s
in `Mathlib/Algebra/Ring/BooleanRing.lean`), and a second one would silently
change the meaning of every `*`. Hence the synonym, whose entire content is
that `SupMon α` is a *different type* from `α` to instance resolution.

This is an upstream candidate: nothing in it mentions this package, and it is
the exact join-side dual of `Multiplicative`/`Additive`. -/

/-- `SupMon α` is `α` carrying the *join* as its multiplication: `a * b = a ⊔ b`
and `1 = ⊥`. It is a `def`, not an `abbrev`, so `α`'s own `Mul` and `One` — if
it has any — are not in competition with the join's; that isolation is the
whole point.

`Agentic.Width` (the width fold, `max` on `ℕ`) and `Agentic.Race` (the race
reducer, `or` on `Bool`) are both this synonym, and the four monoid laws and
the idempotence they used to prove separately are `Mathlib`'s `sup_assoc`,
`bot_sup_eq`, `sup_bot_eq`, `sup_comm` and `sup_idem` here, proved once.

See the section docstring for the absence claim and the upstream note. -/
def SupMon (α : Type) : Type := α

namespace SupMon

variable {α : Type}

/-- The element `a`, read as a member of the join monoid. -/
def of (a : α) : SupMon α := a

/-- The underlying element of a member of the join monoid. -/
def val (a : SupMon α) : α := a

/-- `of` and `val` are mutually inverse, definitionally: the synonym adds no
data, only an instance boundary. -/
@[simp] theorem val_of (a : α) : val (of a) = a := rfl

/-- The same, the other way round. -/
@[simp] theorem of_val (a : SupMon α) : of (val a) = a := rfl

/-- The synonym is injective on the nose, so equations between joins may be
proved on the carrier. -/
theorem of_inj {a b : α} (h : of a = of b) : a = b := h

/-- The order comes along with the carrier: `SupMon α` is ordered exactly as
`α` is, so the order the join induces is Mathlib's and not a second one. -/
instance instSemilatticeSup [SemilatticeSup α] : SemilatticeSup (SupMon α) :=
  inferInstanceAs (SemilatticeSup α)

/-- The bare comparison, transported: needed before `OrderBot` and
`DecidableLE` can even be stated at the synonym. -/
instance instLE [LE α] : LE (SupMon α) := inferInstanceAs (LE α)

/-- The unit of the join is the bottom of the order, transported. -/
instance instOrderBot [LE α] [OrderBot α] : OrderBot (SupMon α) :=
  inferInstanceAs (OrderBot α)

/-- Decidable equality, transported: a verdict is compared as its carrier is. -/
instance instDecidableEq [DecidableEq α] : DecidableEq (SupMon α) :=
  inferInstanceAs (DecidableEq α)

/-- Decidable comparison, transported, so `decide` closes order goals about
widths and races. -/
instance instDecidableLE [LE α] [DecidableLE α] : DecidableLE (SupMon α) :=
  inferInstanceAs (DecidableLE α)

/-- Printing, transported. -/
instance instRepr [Repr α] : Repr (SupMon α) := inferInstanceAs (Repr α)

/-- **The join as a commutative monoid**: `*` is `⊔`, `1` is `⊥`. Every law is
Mathlib's, and this is the one instance the synonym exists to carry. -/
instance instCommMonoid [SemilatticeSup α] [OrderBot α] : CommMonoid (SupMon α) where
  mul a b := of (val a ⊔ val b)
  one := of ⊥
  mul_assoc a b c := congrArg of (sup_assoc (val a) (val b) (val c))
  one_mul a := congrArg of (bot_sup_eq (val a))
  mul_one a := congrArg of (sup_bot_eq (val a))
  mul_comm a b := congrArg of (sup_comm (val a) (val b))

/-- Multiplication in the join monoid *is* the join, definitionally. -/
theorem mul_def [SemilatticeSup α] [OrderBot α] (a b : SupMon α) :
    a * b = of (val a ⊔ val b) := rfl

/-- The unit of the join monoid *is* the bottom, definitionally. -/
theorem one_def [SemilatticeSup α] [OrderBot α] : (1 : SupMon α) = of ⊥ := rfl

/-- **A join is idempotent**, so every `SupMon` reducer carries the duplication
licence — speculation, retry and at-least-once delivery are free at any of
them, and no carrier has to earn it separately. -/
instance instIdempotentOp [SemilatticeSup α] [OrderBot α] :
    Std.IdempotentOp (α := SupMon α) (· * ·) :=
  ⟨fun a => congrArg of (sup_idem (val a))⟩

/-- **The monoid order is the lattice order.** `a ≤ b` iff combining the two
reports `b`: the order `Agentic`'s idempotent reducers used to define by hand
is Mathlib's `≤`, and this theorem is the bridge that says so once for all of
them. -/
theorem le_iff_mul [SemilatticeSup α] [OrderBot α] {a b : SupMon α} :
    a ≤ b ↔ a * b = b :=
  ⟨fun h => congrArg of (sup_eq_right.mpr h), fun h => sup_eq_right.mp (of_inj h)⟩

end SupMon

/-! ## The two actions on a reader

A meaning awaiting a context is a function out of the monoid. There are two
actions of the monoid on such a function, and the package uses both.

**This is the survivor of the migration, and here is exactly what Mathlib
lacks.** Mathlib's reader-precomposition action is `DomMulAct`
(`Mathlib/GroupTheory/GroupAction/DomAct/Basic.lean`): for `[SMul M α]` it puts
`SMul Mᵈᵐᵃ (α → β)` by `(c • f) a = f (mk.symm c • a)`. Taking `α := M` with
the self-action, that smul *is* `actL`, and `MulAction.mul_smul` *is*
`actL_compose`. Two things stop it being usable here.

* `Mᵈᵐᵃ` is a type synonym for `MulOpposite M`, so every scope element and
  every trace prefix would have to be written `DomMulAct.mk g` at the use site
  — `Agentic.Scope.withScope` and `Agentic.deriv` take a bare element of the
  monoid, which is the whole point of "a scope is an element, not a map".
* Only *one* of the two orders is available at a time. `actR` is the same
  construction over `Mᵐᵒᵖ`, so a carrier needing both — and this package needs
  both, on the same monoid, in the same file — would carry two synonyms and
  translate between them at every equation. The covariance/contravariance
  distinction the two composition laws record would be hidden inside the
  synonyms rather than stated.

So the two definitions and their four laws stay, stated over Mathlib's
`Monoid`.
-/

section Actions

variable {G R : Type} [Monoid G]

/-- Acting on the *right*: `actR g f` is the reader that extends whatever
arrives from outside with `g` and then consults `f`. This is entering a scope —
the ambient element `h` was fixed first, and `g` is appended after it, which is
what puts `g` innermost.

Survivor: see the section docstring for what Mathlib's `DomMulAct` supplies and
what it does not. -/
def actR (g : G) (f : G → R) : G → R :=
  fun h => f (h * g)

/-- Acting on the *left*: `actL u f` is the reader that prefixes whatever
arrives with `u` and then consults `f`. This is continuing past a prefix — `u`
has already happened, and `w` is what may still happen.

Survivor: this is `DomMulAct`'s smul on `G → R` at the self-action, without the
`MulOpposite` synonym. -/
def actL (u : G) (f : G → R) : G → R :=
  fun w => f (u * w)

/-- The empty element acts trivially on the right. -/
theorem actR_unit (f : G → R) : actR (1 : G) f = f := by
  funext h
  show f (h * 1) = f h
  rw [mul_one]

/-- **The right action composes covariantly**: acting by `g₂` and then by `g₁`
is acting by `g₁ * g₂`, with the operand order *preserved*.

The order is forced and getting it wrong is the classic error. The ambient
element meets `g₁` first and `g₂` last, so `g₂` ends up rightmost; stating the
law with the operands exchanged type-checks and is false as soon as `*` is
non-commutative. -/
theorem actR_compose (g₁ g₂ : G) (f : G → R) :
    actR g₁ (actR g₂ f) = actR (g₁ * g₂) f := by
  funext h
  show f (h * g₁ * g₂) = f (h * (g₁ * g₂))
  rw [mul_assoc]

/-- The empty element acts trivially on the left. -/
theorem actL_unit (f : G → R) : actL (1 : G) f = f := by
  funext w
  show f (1 * w) = f w
  rw [one_mul]

/-- **The left action composes contravariantly**: acting by the prefix `u * v`
is acting by `u` and *then* by `v`, so the operands appear in the opposite
order from `actR_compose`. That reversal is what makes resume-after-fork
associate. -/
theorem actL_compose (u v : G) (f : G → R) :
    actL (u * v) f = actL v (actL u f) := by
  funext w
  show f (u * v * w) = f (u * (v * w))
  rw [mul_assoc]

end Actions

end Agentic
