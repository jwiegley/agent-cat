/-!
# The Pareto preorder on resource factors

A workflow is scored on several axes at once — latency, money, tokens,
quality. The design refuses to fold them into a number: the meaning of "better"
on a product of ordered factors is the componentwise order, and that order is a
preorder with genuinely incomparable elements.

Model tiers are regions of this preorder; "the best workflow" is not
well-defined, and any scalarization is an extra, named choice (design §2).
-/

namespace Agentic

/-- A `ParetoLE x y` is a representation of the judgement *`x` is no worse than
`y` on every axis at once*: the componentwise order on a product of ordered
resource factors. Nothing here trades one axis against another; a trade is a
scalarization, and a scalarization is an extra, named choice. -/
def ParetoLE {α β : Type} [LE α] [LE β] (x y : α × β) : Prop :=
  x.1 ≤ y.1 ∧ x.2 ≤ y.2

/-- Unfolding lemma: a Pareto comparison *is* the conjunction of the two
component comparisons.

The relation is deliberately left as a named definition rather than installed
as an `LE (α × β)` instance. An instance with an unconstrained head would claim
the meaning of `≤` for *every* product in the package — including products that
are not resource scores at all — and the design's whole point is that this
order is a named choice about resources, not the ambient meaning of "better".
Every theorem below therefore names `ParetoLE`. -/
theorem paretoLE_def {α β : Type} [LE α] [LE β] (x y : α × β) :
    ParetoLE x y = (x.1 ≤ y.1 ∧ x.2 ≤ y.2) := rfl

/-- Introduction: a pair of component comparisons is a Pareto comparison. -/
theorem paretoLE_mk {α β : Type} [LE α] [LE β] {x y : α × β}
    (h₁ : x.1 ≤ y.1) (h₂ : x.2 ≤ y.2) : ParetoLE x y := ⟨h₁, h₂⟩

/-- The Pareto order is reflexive whenever both factors are: every workflow is
no worse than itself, on every axis. -/
theorem paretoLE_refl {α β : Type} [LE α] [LE β]
    (ha : ∀ a : α, a ≤ a) (hb : ∀ b : β, b ≤ b) (x : α × β) : ParetoLE x x :=
  ⟨ha x.1, hb x.2⟩

/-- The Pareto order is transitive whenever both factors are: dominance
composes, axis by axis. -/
theorem paretoLE_trans {α β : Type} [LE α] [LE β]
    (ha : ∀ a b c : α, a ≤ b → b ≤ c → a ≤ c)
    (hb : ∀ a b c : β, a ≤ b → b ≤ c → a ≤ c)
    {x y z : α × β} (hxy : ParetoLE x y) (hyz : ParetoLE y z) : ParetoLE x z :=
  ⟨ha _ _ _ hxy.1 hyz.1, hb _ _ _ hxy.2 hyz.2⟩

/-- The Pareto order is antisymmetric whenever both factors are: two workflows
that dominate each other agree on every axis, hence are the same score. -/
theorem paretoLE_antisymm {α β : Type} [LE α] [LE β]
    (ha : ∀ a b : α, a ≤ b → b ≤ a → a = b)
    (hb : ∀ a b : β, a ≤ b → b ≤ a → a = b)
    {x y : α × β} (hxy : ParetoLE x y) (hyx : ParetoLE y x) : x = y := by
  have h₁ : x.1 = y.1 := ha _ _ hxy.1 hyx.1
  have h₂ : x.2 = y.2 := hb _ _ hxy.2 hyx.2
  calc x = (x.1, x.2) := rfl
    _ = (y.1, y.2) := by rw [h₁, h₂]
    _ = y := rfl

/-- The incomparability witness: on two `Nat` axes — say latency and money —
the score `(0, 1)` and the score `(1, 0)` stand in neither direction of the
Pareto order. Cheaper-and-slower against dearer-and-faster is not a comparison
the order makes.

This single fact is the reason the design never speaks of *the* best workflow:
selection needs a scalarization, and a scalarization is an extra choice that
must be named, not smuggled in as if it were the order itself. Totality fails
because of this pair and nothing else — the order is not total, there is no
"best", only a frontier — and saying so a second time as a `¬ ∀` adds no
content to the witness. -/
theorem pareto_incomparable :
    ¬ ParetoLE ((0, 1) : Nat × Nat) (1, 0) ∧
    ¬ ParetoLE ((1, 0) : Nat × Nat) (0, 1) :=
  ⟨fun h => absurd h.2 (by decide), fun h => absurd h.1 (by decide)⟩

/-- A `Scalarization` is a representation of the *extra, named choice* that a
selection rule makes: a map from the multi-axis score to a single ordered
carrier, together with the promise that it respects Pareto dominance. The
promise is the most one can ask of it; which scalarization to use is not
determined by the meanings, and the design says so rather than picking one
silently. -/
structure Scalarization (α β γ : Type) [LE α] [LE β] [LE γ] where
  /-- The chosen collapse of the several axes into one. -/
  score : α × β → γ
  /-- Dominance is preserved: a workflow that is no worse on every axis does
  not come out worse on the score. -/
  monotone : ∀ x y : α × β, ParetoLE x y → score x ≤ score y

/-- Projection onto the first axis is a scalarization: it is monotone, and it
is a *choice* — it declares the second axis irrelevant. Its existence shows the
`Scalarization` interface is inhabited without the design endorsing any
particular one. -/
def Scalarization.fst {α β : Type} [LE α] [LE β] : Scalarization α β α where
  score := Prod.fst
  monotone := fun _ _ h => h.1

end Agentic
