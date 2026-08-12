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
package neither defines the relation nor proves its three laws, and as of this
arc it does not rename it either: Pareto dominance is written `≤`. A monotone
map out of that order is `OrderHom`, so a scalarization is `(α × β) →o γ` and
that is not renamed either. What the design contributes, and all that remains
in this file, is the incomparability witness that makes "no best workflow" a
theorem, and the insistence — recorded in prose, since Mathlib has the object —
that a scalarization is a named choice rather than the order itself.
-/

namespace Agentic

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
    ¬ (((0, 1) : Nat × Nat) ≤ (1, 0)) ∧
    ¬ (((1, 0) : Nat × Nat) ≤ (0, 1)) :=
  ⟨fun h => absurd h.2 (by decide), fun h => absurd h.1 (by decide)⟩

/-! ### Scalarization

The *extra, named choice* a selection rule makes is a monotone map from
the multi-axis score to a single ordered carrier, and a bundled monotone map is
Mathlib's `OrderHom`: since Pareto dominance *is* Mathlib's `≤` on the product,
a scalarization is exactly `(α × β) →o γ`, its promise is `OrderHom.monotone`,
and `OrderHom.fst` witnesses that the interface is inhabited without the design
endorsing any particular collapse. So the package neither names nor states it,
and this paragraph is all that is left of `Scalarization` and its three
wrappers.

The reading is what the design contributes: "no axis may be traded away
silently" is what `monotone` *means* here, and which scalarization to use is
not determined by the meanings.
-/

end Agentic
