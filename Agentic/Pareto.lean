import Mathlib.Order.Hom.Basic

/-!
# The Pareto preorder on resource factors

A workflow is scored on several axes at once — latency, money, tokens,
quality. The design refuses to fold them into a number: the meaning of "better"
on a product of ordered factors is the componentwise order, and that order is a
preorder with genuinely incomparable elements.

Model tiers are regions of this preorder; "the best workflow" is not
well-defined, and any scalarization is an extra, named choice (design §2).

**Everything structural here is Mathlib's.** The componentwise order on a
product is `Prod.instLE` (`Mathlib/Order/Basic.lean`), which is upgraded to
`Prod.instPreorder` and `Prod.instPartialOrder` when the factors are, so the
package neither defines the relation nor proves its three laws. A monotone map
out of that order is `OrderHom`. What the design contributes, and what remains
in this file, is the *reading*: the name `ParetoLE`, the incomparability
witness that makes "no best workflow" a theorem, and the insistence that a
scalarization is a named choice rather than the order itself.
-/

namespace Agentic

/-- A `ParetoLE x y` is a representation of the judgement *`x` is no worse than
`y` on every axis at once*: the componentwise order on a product of ordered
resource factors. Nothing here trades one axis against another; a trade is a
scalarization, and a scalarization is an extra, named choice.

It *is* Mathlib's `≤` on `α × β` — `Prod.instLE`, whose `le p q` is literally
`p.1 ≤ q.1 ∧ p.2 ≤ q.2` — kept as a name because the design's claim is about
what the order means, not about which relation it is. The package's earlier
refusal to install an `LE (α × β)` instance is moot: Mathlib installs it, for
every product and not only for resource scores, and the honest response is to
use it and to keep saying in the name which products are being ordered. -/
abbrev ParetoLE {α β : Type} [LE α] [LE β] (x y : α × β) : Prop := x ≤ y

/-- Unfolding lemma: a Pareto comparison *is* the conjunction of the two
component comparisons (Mathlib's `Prod.le_def`, as an equation of
propositions). -/
theorem paretoLE_def {α β : Type} [LE α] [LE β] (x y : α × β) :
    ParetoLE x y = (x.1 ≤ y.1 ∧ x.2 ≤ y.2) := rfl

/-- Introduction: a pair of component comparisons is a Pareto comparison. -/
theorem paretoLE_mk {α β : Type} [LE α] [LE β] {x y : α × β}
    (h₁ : x.1 ≤ y.1) (h₂ : x.2 ≤ y.2) : ParetoLE x y := ⟨h₁, h₂⟩

/-- The Pareto order is reflexive whenever both factors are: every workflow is
no worse than itself, on every axis. It is Mathlib's `le_refl` at
`Prod.instPreorder`; the reflexivity of the factors arrives as their `Preorder`
instances rather than as hypotheses passed by hand. -/
theorem paretoLE_refl {α β : Type} [Preorder α] [Preorder β] (x : α × β) :
    ParetoLE x x :=
  le_refl x

/-- The Pareto order is transitive whenever both factors are: dominance
composes, axis by axis (Mathlib's `le_trans` at `Prod.instPreorder`). -/
theorem paretoLE_trans {α β : Type} [Preorder α] [Preorder β] {x y z : α × β}
    (hxy : ParetoLE x y) (hyz : ParetoLE y z) : ParetoLE x z :=
  le_trans hxy hyz

/-- The Pareto order is antisymmetric whenever both factors are: two workflows
that dominate each other agree on every axis, hence are the same score
(Mathlib's `le_antisymm` at `Prod.instPartialOrder`). -/
theorem paretoLE_antisymm {α β : Type} [PartialOrder α] [PartialOrder β]
    {x y : α × β} (hxy : ParetoLE x y) (hyx : ParetoLE y x) : x = y :=
  le_antisymm hxy hyx

/-- The incomparability witness: on two `Nat` axes — say latency and money —
the score `(0, 1)` and the score `(1, 0)` stand in neither direction of the
Pareto order. Cheaper-and-slower against dearer-and-faster is not a comparison
the order makes.

This single fact is the reason the design never speaks of *the* best workflow:
selection needs a scalarization, and a scalarization is an extra choice that
must be named, not smuggled in as if it were the order itself. Totality fails
because of this pair and nothing else — the order is not total, there is no
"best", only a frontier — and saying so a second time as a `¬ ∀` adds no
content to the witness.

It is also the fact Mathlib does not have: Mathlib supplies the product order
and its laws, but the *absence* of a comparison is a statement about a design,
not a lemma anyone would file. (Mathlib has no Pareto/frontier vocabulary at
all, which is why the name and this witness stay here.) -/
theorem pareto_incomparable :
    ¬ ParetoLE ((0, 1) : Nat × Nat) (1, 0) ∧
    ¬ ParetoLE ((1, 0) : Nat × Nat) (0, 1) :=
  ⟨fun h => absurd h.2 (by decide), fun h => absurd h.1 (by decide)⟩

/-- A `Scalarization` is a representation of the *extra, named choice* that a
selection rule makes: a map from the multi-axis score to a single ordered
carrier, together with the promise that it respects Pareto dominance. The
promise is the most one can ask of it; which scalarization to use is not
determined by the meanings, and the design says so rather than picking one
silently.

A map that respects an order is a monotone map, and a bundled monotone map is
Mathlib's `OrderHom`; since Pareto dominance *is* Mathlib's order on the
product, a scalarization is exactly `(α × β) →o γ` and the package's bespoke
structure is gone. The content the design adds is the name, and the reading of
`monotone` as "no axis may be traded away silently". -/
abbrev Scalarization (α β γ : Type) [Preorder α] [Preorder β] [Preorder γ] :=
  (α × β) →o γ

namespace Scalarization

variable {α β γ : Type} [Preorder α] [Preorder β] [Preorder γ]

/-- The chosen collapse of the several axes into one: the underlying function
of the order homomorphism. -/
abbrev score (s : Scalarization α β γ) : α × β → γ := ⇑s

/-- Dominance is preserved: a workflow that is no worse on every axis does not
come out worse on the score. This is `OrderHom.monotone`, read at the Pareto
order. -/
theorem monotone (s : Scalarization α β γ) {x y : α × β} (h : ParetoLE x y) :
    score s x ≤ score s y :=
  OrderHom.monotone s h

/-- Projection onto the first axis is a scalarization: it is monotone, and it
is a *choice* — it declares the second axis irrelevant. Its existence shows the
`Scalarization` interface is inhabited without the design endorsing any
particular one. It is Mathlib's `OrderHom.fst`. -/
abbrev fst : Scalarization α β α := OrderHom.fst

end Scalarization

end Agentic
