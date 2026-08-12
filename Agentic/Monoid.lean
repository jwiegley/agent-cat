import Mathlib.Algebra.Group.Prod
import Mathlib.Order.Lattice
import Mathlib.Order.BoundedOrder.Basic

/-!
# One monoid, one action, one order — now Mathlib's

Combination is the most-repeated structure in this package. Panel keys
combine, scopes nest, histories concatenate, fragment grades join, costs take
their worst case. This module used to *state* that algebra: three classes
(`PMonoid`, `CMonoid`, `IdemCMonoid`), a notation, and a fourteen-line
development of the order an idempotent join induces.

None of that is stated here any more, because all of it is in Mathlib.

* **The monoid** is `Monoid` and `CommMonoid`. `PMonoid`/`CMonoid` survive as
  reducible abbreviations so that every binder and instance name in the package
  keeps elaborating; `⋄` is scoped notation for `*`.
* **The order** is `SemilatticeSup` together with `OrderBot`: `a ≤ b`,
  `le_refl`, `le_trans`, `le_antisymm`, `le_sup_left`, `le_sup_right`,
  `sup_le`, `sup_le_sup` and `bot_le` are Mathlib's, and the carriers that had
  their own copies (`Cost`, `Frag`, `Width`) now instantiate Mathlib's classes
  and delegate. `IdemCMonoid` survives as the abbreviation
  `Std.IdempotentOp (· * ·)` over a `CommMonoid` — the *duplication licence*
  separated from the order, which is how Mathlib factors it.
* **The two actions on a reader** are the one thing that does not come from
  Mathlib, and they are kept here with the survivor docstring the migration
  policy requires (`actR`, `actL`, and their four laws).

Nothing in this module mentions a semiring, an aggregation or a matrix: it is
below all of them.
-/

namespace Agentic

/-- `a ⋄ b` is `a * b`: the package's historic spelling of monoid combination,
kept as scoped notation for one migration era so that every `⋄` already written
— panel keys, scopes, histories, grades, costs — keeps parsing while the
carriers move to Mathlib's `*` (and, where the carrier is a join-semilattice,
to `⊔`, which the carriers below make definitionally the same operation). -/
scoped infixl:70 " ⋄ " => HMul.hMul

/-- `PMonoid K` is Mathlib's `Monoid K`.

The package's own class had exactly Mathlib's fields — associativity and a
two-sided unit — and none of its consumers used anything else, so the class is
gone and the name is an abbreviation. What the old class *documented* is still
true and still load-bearing: commutativity is a separate licence
(`CMonoid`/`CommMonoid`, needed by `foldPanel_perm`) and idempotence a further
one (`IdemCMonoid`, needed by `foldPanel_dup`), and an ordered transcript, a
nested scope and a history of turns are legitimate carriers that have neither. -/
abbrev PMonoid (K : Type) := Monoid K

/-- `CMonoid K` is Mathlib's `CommMonoid K`: the scheduling licence, charged
separately from the monoid itself. -/
abbrev CMonoid (K : Type) := CommMonoid K

/-- `IdemCMonoid K` is Mathlib's `Std.IdempotentOp` at the monoid operation:
*a contribution counted twice counts once*.

Mathlib has no bundled "idempotent commutative monoid" class, and does not need
one: such a thing is a join-semilattice with a bottom, which Mathlib carries as
`SemilatticeSup` + `OrderBot`, and the *order* development that used to live
here comes from there. What a `SemilatticeSup` does not supply is a `Monoid`
structure, and the panel algebra (`Agentic.MSemiring`) is generic in a monoid;
so the licence is taken in Mathlib's unbundled form — the standard
`Std.IdempotentOp` mixin on `(· * ·)` — rather than by reintroducing a class. -/
abbrev IdemCMonoid (K : Type) [CommMonoid K] := Std.IdempotentOp (α := K) (· * ·)

namespace PMonoid

variable {K : Type}

/-- `PMonoid.op` is `*`: the old projection, kept resolving. -/
abbrev op [Mul K] (a b : K) : K := a * b

/-- `PMonoid.unit` is `1`: the old projection, kept resolving. -/
abbrev unit [One K] : K := 1

/-- Contributions are unbracketed (Mathlib's `mul_assoc`, under the old name). -/
theorem op_assoc [Semigroup K] (a b c : K) : a * b * c = a * (b * c) :=
  mul_assoc a b c

/-- The empty contribution adds nothing on the left (Mathlib's `one_mul`). -/
theorem unit_op [MulOneClass K] (a : K) : 1 * a = a := one_mul a

/-- The empty contribution adds nothing on the right (Mathlib's `mul_one`). -/
theorem op_unit [MulOneClass K] (a : K) : a * 1 = a := mul_one a

end PMonoid

namespace CMonoid

/-- Contributions are interchangeable (Mathlib's `mul_comm`, under the old
name). -/
theorem op_comm {K : Type} [CommMonoid K] (a b : K) : a * b = b * a := mul_comm a b

end CMonoid

namespace IdemCMonoid

variable {K : Type}

/-- A contribution counted twice counts once (the `Std.IdempotentOp` field,
under the old name). -/
theorem op_idem [CommMonoid K] [IdemCMonoid K] (a : K) : a * a = a :=
  Std.IdempotentOp.idempotent (op := fun a b : K => a * b) a

/-- `IdemCMonoid.le` is Mathlib's `≤`.

The old definition was `a ⋄ b = b`, and every carrier that used it now carries
a Mathlib `SemilatticeSup` whose `⊔` *is* its `⋄`, so the two orders are the
same relation and the six lemmas below are Mathlib's. -/
abbrev le [LE K] (a b : K) : Prop := a ≤ b

/-- The induced order is reflexive (Mathlib's `le_refl`). -/
theorem le_refl [Preorder K] (a : K) : a ≤ a := _root_.le_refl a

/-- The induced order is transitive (Mathlib's `le_trans`). -/
theorem le_trans [Preorder K] {a b c : K} (hab : a ≤ b) (hbc : b ≤ c) : a ≤ c :=
  _root_.le_trans hab hbc

/-- The induced order is antisymmetric (Mathlib's `le_antisymm`). -/
theorem le_antisymm [PartialOrder K] {a b : K} (hab : a ≤ b) (hba : b ≤ a) : a = b :=
  _root_.le_antisymm hab hba

/-- A part is below the join (Mathlib's `le_sup_left`). -/
theorem le_op_left [SemilatticeSup K] (a b : K) : a ≤ a ⊔ b := le_sup_left

/-- A part is below the join, on the right (Mathlib's `le_sup_right`). -/
theorem le_op_right [SemilatticeSup K] (a b : K) : b ≤ a ⊔ b := le_sup_right

/-- The join is least among upper bounds (Mathlib's `sup_le`). -/
theorem op_le [SemilatticeSup K] {a b c : K} (ha : a ≤ c) (hb : b ≤ c) : a ⊔ b ≤ c :=
  sup_le ha hb

/-- The join is monotone in both arguments (Mathlib's `sup_le_sup`). -/
theorem op_le_op [SemilatticeSup K] {a a' b b' : K} (ha : a ≤ a') (hb : b ≤ b') :
    a ⊔ b ≤ a' ⊔ b' := sup_le_sup ha hb

end IdemCMonoid

/-- The product of two combinable verdicts, acting coordinatewise: Mathlib's
`Prod.instMonoid`. Kept under the package's old instance name so that
`Agentic.Scope` may name it; independence of the coordinates is that instance,
and `Agentic.Scope.axis_independence` is still a computation. -/
abbrev instPMonoidProd {G H : Type} [Monoid G] [Monoid H] : Monoid (G × H) :=
  inferInstance

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
