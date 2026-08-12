/-!
# One monoid, one action, one order

Combination is the most-repeated structure in this package. Panel keys
combine, scopes nest, histories concatenate, fragment grades join, costs take
their worst case: five presentations of *the same* algebra, each of which had
been written out again with its own class, its own notation and its own three
law theorems. This module states it once.

Three things live here and nothing else does.

* **The monoid.** `PMonoid` is associativity and a two-sided unit, with
  commutativity (`CMonoid`) and idempotence (`IdemCMonoid`) as separate
  strengthenings, because they are separate *licences*: commutativity lets the
  scheduler reorder, idempotence lets it duplicate. Every carrier in the
  package instantiates exactly one of the three, and the class it instantiates
  is the statement of what may be done to it.

* **The two actions on a reader.** A meaning awaiting a context is a function
  `G → R`, and there are exactly two ways a monoid element can act on one:
  extend the ambient element on the right (`actR`) or on the left (`actL`).
  `Agentic.Scope.withScope` is `actR` and `Agentic.deriv` — the Brzozowski
  derivative of a session — is `actL`; both had proved the unit and
  composition laws for themselves, and both now import them.

  The two are genuinely different and the difference is the operand order in
  the composition law: `actR` composes covariantly (`actR_compose`) and `actL`
  contravariantly (`actL_compose`). Neither is a convention. Which one a
  construction wants is fixed by which end of the ambient element the new one
  belongs at, and for a non-commutative monoid — `Last` and the free monoid
  both are — the other equation is false rather than merely unidiomatic.

* **The order.** An idempotent commutative operation *is* a join, and a join
  *is* a partial order: `a ≤ b` iff `a ⋄ b = b`. That order had been written
  out three times (worst-case cost twice, fragment grades once) with the same
  six proofs each time. It is proved here once, generically, and the carriers
  keep their own names for it by delegation.

Nothing in this module mentions a semiring, an aggregation or a matrix: it is
below all of them, and imports nothing.
-/

namespace Agentic

/-- A `PMonoid K` is a representation of a *combinable verdict*: `⋄` combines
two contributions into one and `unit` is the contribution of the empty
combination. Associativity and the unit laws are exactly the promise that the
answer does not depend on how the contributions were bracketed, nor on how many
absentees were counted.

Commutativity is deliberately *not* required here: an ordered transcript is a
legitimate verdict type, a nested scope is order-sensitive on purpose, and a
history of turns is not a multiset. What commutativity buys is a scheduling
licence, and it is charged for separately in `CMonoid`. -/
class PMonoid (K : Type) where
  /-- Combination of two contributions, written `⋄`. -/
  op : K → K → K
  /-- The contribution of the empty combination. -/
  unit : K
  /-- Contributions are unbracketed. -/
  op_assoc : ∀ a b c : K, op (op a b) c = op a (op b c)
  /-- The empty contribution adds nothing on the left. -/
  unit_op : ∀ a : K, op unit a = a
  /-- The empty contribution adds nothing on the right. -/
  op_unit : ∀ a : K, op a unit = a

@[inherit_doc PMonoid.op]
infixl:70 " ⋄ " => PMonoid.op

/-- A `CMonoid K` is a representation of a combinable verdict whose
contributions are *interchangeable*: the answer does not depend on the order in
which they arrived. This is the algebraic form of a scheduling licence — it is
what `foldPanel_perm` needs, and it is exactly what `Last`-style scoping must
not have. -/
class CMonoid (K : Type) extends PMonoid K where
  /-- Contributions are interchangeable. -/
  op_comm : ∀ a b : K, a ⋄ b = b ⋄ a

/-- An `IdemCMonoid K` is a representation of a combinable verdict for which a
contribution counted twice counts once. It carries two things at once, and they
are the same thing seen from two sides:

* the **duplication licence** — at-least-once delivery, a retried member, a
  speculative race and a duplicated reply are all safe, which is the hypothesis
  of `foldPanel_dup`;
* the **order** — an idempotent commutative operation is a join, so `⋄` induces
  the partial order `a ≤ b ↔ a ⋄ b = b` developed at the end of this module.

A counting reducer is a `CMonoid` and not this: counting a member twice counts
twice, which is the honest reason a tally gets no duplication licence and no
induced order. -/
class IdemCMonoid (K : Type) extends CMonoid K where
  /-- A contribution counted twice counts once. -/
  op_idem : ∀ a : K, a ⋄ a = a

/-- The product of two combinable verdicts, acting coordinatewise: two axes
that know nothing about each other. Independence of the coordinates is not an
extra axiom — it is this instance, and the theorems that read it back (see
`Agentic.Scope.axis_independence`) are computations. -/
instance instPMonoidProd {G H : Type} [PMonoid G] [PMonoid H] : PMonoid (G × H) where
  op p q := (p.1 ⋄ q.1, p.2 ⋄ q.2)
  unit := (PMonoid.unit, PMonoid.unit)
  op_assoc p q r := by
    show ((p.1 ⋄ q.1) ⋄ r.1, (p.2 ⋄ q.2) ⋄ r.2) = (p.1 ⋄ (q.1 ⋄ r.1), p.2 ⋄ (q.2 ⋄ r.2))
    rw [PMonoid.op_assoc, PMonoid.op_assoc]
  unit_op p := by
    show ((PMonoid.unit : G) ⋄ p.1, (PMonoid.unit : H) ⋄ p.2) = p
    rw [PMonoid.unit_op, PMonoid.unit_op]
  op_unit p := by
    show (p.1 ⋄ (PMonoid.unit : G), p.2 ⋄ (PMonoid.unit : H)) = p
    rw [PMonoid.op_unit, PMonoid.op_unit]

/-! ## The two actions on a reader

A meaning awaiting a context is a function out of the monoid. There are two
actions of the monoid on such a function, and the package uses both.
-/

section Actions

variable {G R : Type} [PMonoid G]

/-- Acting on the *right*: `actR g f` is the reader that extends whatever
arrives from outside with `g` and then consults `f`. This is entering a scope —
the ambient element `h` was fixed first, and `g` is appended after it, which is
what puts `g` innermost. -/
def actR (g : G) (f : G → R) : G → R :=
  fun h => f (h ⋄ g)

/-- Acting on the *left*: `actL u f` is the reader that prefixes whatever
arrives with `u` and then consults `f`. This is continuing past a prefix — `u`
has already happened, and `w` is what may still happen. -/
def actL (u : G) (f : G → R) : G → R :=
  fun w => f (u ⋄ w)

/-- The empty element acts trivially on the right. -/
theorem actR_unit (f : G → R) : actR PMonoid.unit f = f := by
  funext h
  show f (h ⋄ PMonoid.unit) = f h
  rw [PMonoid.op_unit]

/-- **The right action composes covariantly**: acting by `g₂` and then by `g₁`
is acting by `g₁ ⋄ g₂`, with the operand order *preserved*.

The order is forced and getting it wrong is the classic error. The ambient
element meets `g₁` first and `g₂` last, so `g₂` ends up rightmost; stating the
law with the operands exchanged type-checks and is false as soon as `⋄` is
non-commutative. -/
theorem actR_compose (g₁ g₂ : G) (f : G → R) :
    actR g₁ (actR g₂ f) = actR (g₁ ⋄ g₂) f := by
  funext h
  show f (h ⋄ g₁ ⋄ g₂) = f (h ⋄ (g₁ ⋄ g₂))
  rw [PMonoid.op_assoc]

/-- The empty element acts trivially on the left. -/
theorem actL_unit (f : G → R) : actL PMonoid.unit f = f := by
  funext w
  show f (PMonoid.unit ⋄ w) = f w
  rw [PMonoid.unit_op]

/-- **The left action composes contravariantly**: acting by the prefix `u ⋄ v`
is acting by `u` and *then* by `v`, so the operands appear in the opposite
order from `actR_compose`. That reversal is what makes resume-after-fork
associate. -/
theorem actL_compose (u v : G) (f : G → R) :
    actL (u ⋄ v) f = actL v (actL u f) := by
  funext w
  show f (u ⋄ v ⋄ w) = f (u ⋄ (v ⋄ w))
  rw [PMonoid.op_assoc]

end Actions

/-! ## The order induced by an idempotent join -/

namespace IdemCMonoid

variable {G : Type} [IdemCMonoid G]

/-- `le a b` — *`a` is below `b`* — is the order induced by the join:
`a ⋄ b = b`. Defining the order by this equation rather than by cases is what
makes every lemma below an equational consequence of three monoid laws, so that
a carrier which exhibits its join gets its order for nothing. -/
def le (a b : G) : Prop := a ⋄ b = b

/-- The induced order is reflexive: idempotence, in the order's notation. -/
theorem le_refl (a : G) : le a a := op_idem a

/-- The induced order is transitive. -/
theorem le_trans {a b c : G} (hab : le a b) (hbc : le b c) : le a c := by
  show a ⋄ c = c
  rw [← hbc, ← PMonoid.op_assoc, hab]

/-- The induced order is antisymmetric, so it is a genuine partial order and
not merely a preorder: two mutually-below elements are one element. -/
theorem le_antisymm {a b : G} (hab : le a b) (hba : le b a) : a = b := by
  have h : a ⋄ b = b ⋄ a := CMonoid.op_comm a b
  rw [hab] at h
  rw [hba] at h
  exact h.symm

/-- A part is below the combination: `⋄` is an upper bound of its left
operand. -/
theorem le_op_left (a b : G) : le a (a ⋄ b) := by
  show a ⋄ (a ⋄ b) = a ⋄ b
  rw [← PMonoid.op_assoc, op_idem]

/-- A part is below the combination on the right too. -/
theorem le_op_right (a b : G) : le b (a ⋄ b) := by
  show b ⋄ (a ⋄ b) = a ⋄ b
  rw [CMonoid.op_comm a b, ← PMonoid.op_assoc, op_idem]

/-- The combination is the *least* upper bound: anything above both parts is
above their combination. With `le_op_left` and `le_op_right` this says `⋄` is
the join of the order it induces, and not merely some upper bound. -/
theorem op_le {a b c : G} (ha : le a c) (hb : le b c) : le (a ⋄ b) c := by
  show (a ⋄ b) ⋄ c = c
  rw [PMonoid.op_assoc, show b ⋄ c = c from hb, ha]

/-- The join is monotone in both arguments: weakening the parts weakens the
combination, and never the other way. -/
theorem op_le_op {a a' b b' : G} (ha : le a a') (hb : le b b') :
    le (a ⋄ b) (a' ⋄ b') :=
  op_le (le_trans ha (le_op_left a' b')) (le_trans hb (le_op_right a' b'))

end IdemCMonoid

end Agentic
