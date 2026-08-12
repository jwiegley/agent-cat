import Agentic.Monoid

/-!
# Scoping as precomposition

Design §5.3. A scoped meaning is not a meaning with a mutable environment
inside it; it is a *function awaiting its scope*, and entering a scope is
precomposition with the scope's element. Two facts follow, and both are
theorems below rather than conventions:

* **Innermost wins** is not a rule imposed on the interpreter. It is the
  monoid: each axis of a scope is the `Last` monoid on `Option`, whose `*`
  keeps the right operand when it is present. Change the monoid and the
  override discipline changes with it; there is nothing else to change.

  Note what that costs, and that the cost is the content: `Last` is
  **non-commutative on every axis with two or more inhabitants** —
  `set a * set b = set b` while `set b * set a = set a` — and that failure of
  commutativity *is* innermost-wins. What commutes is the product across
  *distinct* axes (`axis_comm`, `axis_independence`), because the axes act on
  separate coordinates and cannot see each other.

* **Scoping is a monoid homomorphism, covariantly.**
  `withScope g₁ (withScope g₂ f)` is `withScope (g₁ * g₂) f`: the operand order
  is *preserved*, so `withScope` takes `*` in the scope monoid to composition
  of scope-entering maps in the same order, and nothing here is contravariant.
  Mind the operand order all the same — `g₁` is the *outer* scope and must sit
  on the left, because the ambient scope meets it first and `g₂`, the inner
  one, must end up rightmost where the `Last` monoid lets it win. Writing the
  equation with the operands exchanged is the classic error; since `Last` is
  non-commutative, it is a false equation and not merely a stylistic one.

  §5.3's warning that "precomposition is contravariant" is about a scope given
  as a *map* on environments, where `local σ ∘ local τ = local (τ ∘ σ)` reverses
  because the maps themselves compose. Here a scope is an *element* of a monoid
  and is appended to the ambient one, so no reversal occurs. The hazard the
  warning points at is the same, and it is the operand order above.

A scope algebra is a Mathlib `Monoid` and nothing more: the package has one
monoid class, Mathlib's, and a scope is one of the things it is about. This module
used to declare a second class, `ScopeMonoid`, together with `Mul` and `One`
instances whose heads were unconstrained — `[ScopeMonoid G] : Mul G` claimed
`*` for *every* type carrying a scope algebra, which is precisely how a scope
and a resource come to share a notation by accident. Both are gone: `*` is the
combination of scopes as it is the combination of everything else, and `1` is
the empty scope. What is a real distinction — that a scope
monoid must *not* be commutative — survives as the absence of a `CommMonoid`
instance and as `LastOpt.set_overrides`.
-/

namespace Agentic

/-! ## One axis: the `Last` monoid -/

/-- A `LastOpt α` is a representation of *one axis of a scope*: either the axis
says nothing (`none`) or it says one thing (`some a`). It is `Option α`, given
a name of its own because the monoid below — not the type — is the content.

**Survivor, and exactly what Mathlib lacks.** The last-wins monoid is the
*right-zero* semigroup on `α` (`a * b = b`) with a unit adjoined, and Mathlib
supplies the second half of that and not the first: `WithOne α` is `Option α`
with `none` as the unit, and `WithOne.instMonoid` upgrades any `Semigroup α` to
a monoid on it. But Mathlib has no right-zero semigroup — no instance, no type
synonym, not even the name — so there is nothing to feed `WithOne`, and
`Option`'s own `orElse` (which is first-wins, and the mirror image of what a
scope needs) carries no `Monoid` instance either. Manufacturing a one-element
synonym here purely to hand it to `WithOne` would trade three two-line proofs
for a synonym, an instance and a defeq that no longer holds on the nose
(`WithOne`'s multiplication case-splits on *both* arguments, where
`set_overrides` below is `rfl`). So the definition and its three laws stay. -/
def LastOpt (α : Type) : Type := Option α

namespace LastOpt

variable {α : Type}

/-- The axis says nothing. -/
def unset : LastOpt α := none

/-- The axis says exactly `a`. -/
def set (a : α) : LastOpt α := some a

/-- Combining two settings of one axis: **the right operand wins if it is
present**. Read right-to-left as outer-then-inner, this is innermost-wins —
and it is a monoid operation, not an interpreter rule. -/
def mul (x y : LastOpt α) : LastOpt α :=
  match y with
  | some b => some b
  | none   => x

/-- The neutral setting: saying nothing on this axis. -/
def one : LastOpt α := none

/-- Combining settings is unbracketed: whoever is rightmost-present wins,
however the combination is grouped. -/
theorem mul_assoc (x y z : LastOpt α) : mul (mul x y) z = mul x (mul y z) := by
  cases z with
  | some _ => rfl
  | none => cases y <;> rfl

/-- Saying nothing outside leaves the inner setting alone. -/
theorem one_mul (x : LastOpt α) : mul one x = x := by
  cases x <;> rfl

/-- Saying nothing inside leaves the outer setting alone. -/
theorem mul_one (x : LastOpt α) : mul x one = x := rfl

/-- The `Last` monoid: one axis of a scope, with innermost-wins as its
combination. It is a `Monoid` and deliberately not a `CommMonoid` — see
`set_overrides`, which is the failure of commutativity and is also the whole
of innermost-wins. -/
instance instPMonoid : Monoid (LastOpt α) where
  mul := mul
  one := one
  npow n x := Nat.rec one (fun _ ih => mul ih x) n
  mul_assoc := mul_assoc
  one_mul := one_mul
  mul_one := mul_one

/-- The axis combination is `Last`, definitionally. -/
theorem op_eq_mul (x y : LastOpt α) : x * y = mul x y := rfl

/-- A present inner setting overrides whatever the axis said before. -/
theorem set_overrides (x : LastOpt α) (a : α) : x * set a = set a := rfl

/-- An absent inner setting defers to whatever the axis said before. -/
theorem unset_defers (x : LastOpt α) : x * unset = x := rfl

end LastOpt

/-! ## Several axes: the product monoid

Two axes that know nothing about each other are the product monoid, and the
product monoid is Mathlib's `Prod.instMonoid` — it is not built here, because
independence of coordinates is not a fact about scopes. `axis_independence`
below reads that instance back at the two-axis scope.
-/

/-- A `Scope μ α` is a representation of a *two-axis scope*: a model setting
and an audience setting (say), each independently either unset or set, and each
overridden innermost-first. Any finite number of axes is the same
construction iterated; two is enough to exhibit independence. -/
def Scope (μ α : Type) : Type := LastOpt μ × LastOpt α

namespace Scope

variable {μ α : Type}

/-- Scopes compose axis by axis, each axis by innermost-wins. -/
instance instPMonoid : Monoid (Scope μ α) :=
  inferInstanceAs (Monoid (LastOpt μ × LastOpt α))

/-- A scope built from its two axes. -/
def mk (m : LastOpt μ) (a : LastOpt α) : Scope μ α := (m, a)

/-- What the scope says on the first axis. -/
def axis₁ (s : Scope μ α) : LastOpt μ := Prod.fst s

/-- The scope that sets only the first axis. -/
def fst (m : μ) : Scope μ α := mk (LastOpt.set m) LastOpt.unset

/-- The scope that sets only the second axis. -/
def snd (a : α) : Scope μ α := mk LastOpt.unset (LastOpt.set a)

/-- Setting one axis and then the other, in either order, is the same scope:
the axes do not interfere. This is bifunctoriality of the product, and it is a
computation. -/
theorem axis_comm (m : μ) (a : α) :
    (fst m : Scope μ α) * snd a = snd a * fst m := rfl

end Scope

/-! ## Meanings awaiting a scope -/

/-- A `Scoped G R` is a representation of *a meaning awaiting its scope*: give
it the scope in force and it yields the meaning there. It is the reader
functor, and nothing about it is specific to `R` — the meanings this wraps are
the matrices of `Agentic.Mat`, but the scoping laws never look inside. -/
def Scoped (G R : Type) : Type := G → R

/-- Entering the scope `g`: precompose with "and also `g`". The scope already
in force, `h`, arrives from outside and is extended on the right, because `g`
is inside `h` and the inner setting is the one that wins.

**Entering a scope IS the right action of a monoid on a reader** — `actR` of
`Agentic.Monoid`, at no distance whatever. The two laws below are that action's
two laws, and they are imported rather than reproved; what is specific to
scoping is not the action but the monoid it acts by, and that is `LastOpt`. -/
def withScope {G R : Type} [Monoid G] (g : G) (f : Scoped G R) :
    Scoped G R :=
  actR g f

section Laws

variable {G R : Type} [Monoid G]

/-- Entering the empty scope is doing nothing (`actR_unit`). -/
theorem withScope_one (f : Scoped G R) : withScope (1 : G) f = f :=
  actR_unit f

/-- **Scoping is a covariant monoid homomorphism.** Nesting `g₂` inside `g₁` is
entering the single scope `g₁ * g₂` — outer on the *left*, operand order
preserved, so `withScope` carries the scope monoid into the monoid of
scope-entering maps without reversal. It is `actR_compose`.

The order is nevertheless forced, and getting it wrong is the classic error:
the ambient scope `h` meets `g₁` first and `g₂` last, so `g₂` is the innermost
and must sit rightmost, where the `Last` monoid lets it win. Stating this law
with the operands exchanged type-checks and is false — `Last` is
non-commutative wherever an axis has two values to choose between. -/
theorem withScope_compose (g₁ g₂ : G) (f : Scoped G R) :
    withScope g₁ (withScope g₂ f) = withScope (g₁ * g₂) f :=
  actR_compose g₁ g₂ f

end Laws

section ScopeLaws

variable {μ α R : Type}

/-- **Innermost wins**, concretely: whatever an outer scope said on the first
axis, an inner scope that speaks on that axis has the last word. Note that the
outer scope's own ambient prefix `h` is irrelevant — this is the monoid
absorbing it. -/
theorem innermost_wins (h : Scope μ α) (a₁ a₂ : μ) (b₁ b₂ : LastOpt α) :
    Scope.axis₁ (h * Scope.mk (LastOpt.set a₁) b₁ * Scope.mk (LastOpt.set a₂) b₂)
      = LastOpt.set a₂ := rfl

/-- An inner scope silent on the first axis leaves the outer setting standing:
the other half of innermost-wins, and the reason silence is not a value. -/
theorem outer_survives_silence (h : Scope μ α) (a₁ : μ) (b₁ b₂ : LastOpt α) :
    Scope.axis₁ (h * Scope.mk (LastOpt.set a₁) b₁ * Scope.mk LastOpt.unset b₂)
      = LastOpt.set a₁ := rfl

/-- **Axis independence.** Entering a scope that sets the first axis and then
one that sets the second is entering them the other way round: the two axes of
a `Scope` commute, so a workflow may name them in any order without changing
its meaning. Interference between axes would have to be put into the monoid
deliberately; the product cannot express it. -/
theorem axis_independence (m : μ) (a : α) (f : Scoped (Scope μ α) R) :
    withScope (Scope.fst m) (withScope (Scope.snd a) f)
      = withScope (Scope.snd a) (withScope (Scope.fst m) f) := by
  rw [withScope_compose, withScope_compose, Scope.axis_comm]

end ScopeLaws

end Agentic
