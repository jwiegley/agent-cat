import Agentic.Matrix
import Mathlib.Order.Closure

/-!
# Context: compaction as an interior operator, and the const-ε collapse

The context of an agentic workflow is ordered by information: `k ≤ k'` says
`k'` knows at least what `k` knows. Compaction — summarising a transcript so
the next step fits — is not an arbitrary function on that order. It may forget
but never invent, it must respect the order, and summarising a summary must
give nothing new. Those three demands are exactly the axioms of an *interior
operator* (design §6e), and an interior operator on `K` is a closure operator
on `Kᵒᵈ`, so the object is Mathlib's `ClosureOperator (OrderDual K)` and this
module states nothing about it.

The second half of the module is about the *index discipline*. If the type of a
work depends on the context it runs in, sequencing is only defined where the
indices meet: `Work k k'` after `Work k' k''`. That is a parameterised
category, and its laws are the matrix laws, transported. The design's `const ε`
decision — every leaf running in the same, fixed context — is the instantiation
that makes the parameter constant; everything it buys, and everything it costs,
follows from that one substitution.
-/

namespace Agentic

/-- `Interior K` is Mathlib's `ClosureOperator (OrderDual K)`: an interior
operator on `K` *is* a closure operator on `Kᵒᵈ` — deflationary in `K` is
inflationary in `Kᵒᵈ`, monotone is monotone (both arguments flip), and
idempotence is unchanged. Deprecated compatibility alias, kept only because
`doc/walkthrough.html` still spells it; the six wrappers that read Mathlib's
fields back (`Interior.op`, `deflationary`, `idempotent`, `monotone`, `id`,
`compact_iff_fixed`) had no consumers and are retired, so compaction is now
spelled with `ClosureOperator`'s own API. -/
@[deprecated ClosureOperator (since := "2026-08-12")]
abbrev Interior (K : Type) [Preorder K] : Type := ClosureOperator (OrderDual K)

/-! ### The parameterised structure

`Ctx S I k k'` is a transition that may only run in context `k` and leaves the
context at `k'`. The index type of its source and target is *chosen by the
context* (`I : K → Type`): a work whose prompt depends on what has been
accumulated has a different index type in a different context. Composition is
then defined only where the contexts meet, and that typed discipline — not a
runtime check — is what prevents splicing a step into a history it was never
written for. -/

/-- A `Ctx S I k k'` is a representation of a *context-parameterised
transition*: a resource-weighted matrix whose source index is the one context
`k` determines and whose target index is the one context `k'` determines.
Sequencing two such is defined only when the middle contexts agree. -/
def Ctx {K : Type} (S : Type) (I : K → Type) (k k' : K) : Type :=
  Mat S (I k) (I k')

namespace Ctx

variable {K S : Type} {I : K → Type} {k k' k'' k''' : K}

/-- Sequencing of context-parameterised transitions: matrix composition, typed
so that it exists only where the contexts meet. The aggregation is over the
intermediate value *in the intermediate context*. -/
def comp [CommSemiring S] [CompleteCSemiring S] (f : Ctx S I k k') (g : Ctx S I k' k'') :
    Ctx S I k k'' :=
  Mat.comp f g

/-- Staying put in context `k`: the identity transition on that context's own
index. -/
noncomputable def idCtx [CommSemiring S] [CompleteCSemiring S] : Ctx S I k k :=
  Mat.idMat

/-- Sequencing is associative in the parameterised structure too: the typed
index discipline costs nothing, since the law is the matrix law transported
along a definitional equality. A context-threading pipeline has one meaning,
not a bracketing of meanings. -/
theorem comp_assoc [CommSemiring S] [CompleteCSemiring S]
    (f : Ctx S I k k') (g : Ctx S I k' k'') (h : Ctx S I k'' k''') :
    comp (comp f g) h = comp f (comp g h) :=
  Mat.comp_assoc f g h

/-- Staying put before a step changes nothing. -/
theorem idCtx_comp [CommSemiring S] [CompleteCSemiring S]
    (f : Ctx S I k k') : comp idCtx f = f :=
  Mat.id_comp f

/-- Staying put after a step changes nothing. -/
theorem comp_idCtx [CommSemiring S] [CompleteCSemiring S]
    (f : Ctx S I k k') : comp f idCtx = f :=
  Mat.comp_id f

end Ctx

/-! ### The const-ε collapse -/

/-- The constant index family: every context determines the *same* index type.
This is the design's `const ε` — the environment fixed once, ahead of every
leaf, rather than threaded and refined as the workflow runs. -/
abbrev constIx {K : Type} (ι : Type) : K → Type := fun _ => ι

/-- The const-ε collapse: the parameterised structure becomes ordinary, each
leaf history-free, pinning well-defined.

Design §6e draws *four* consequences from this one decision. Three of them are
theorems below — the parameterised monad becomes ordinary (`collapse_comp`),
each leaf's matrix is history-free (`constIx_history_free`), and pinning is
well-defined (`collapse_pin`). The fourth — that the matrix is
finite-dimensional in the prompt — is **not formalized here**: the index types
in this package are arbitrary `Type`s with no size attached, so there is
nothing yet to state it about, and it is recorded as an absence rather than
claimed.

`collapse k₀ M` reads an ordinary transition as a context-parameterised one
pinned at the single context `k₀`. Under `constIx` the parameter carries no
information, so the reading is an identity: the theorems below are all `rfl`,
which is precisely the point. What the collapse buys is that everything
typechecks unconditionally; what it costs is that the index can no longer
record which history a leaf was written for, because there is only one. -/
def collapse {K S ι : Type} (k₀ : K) (M : Mat S ι ι) :
    Ctx S (constIx (K := K) ι) k₀ k₀ := M

section Collapse

variable {K S ι : Type} {k₀ k k' : K}

/-- **Consequence one — the parameterised structure becomes ordinary.**
Sequencing pinned works is ordinary matrix composition; the parameterised
category collapses to the plain one. -/
theorem collapse_comp [CommSemiring S] [CompleteCSemiring S] (M N : Mat S ι ι) :
    Ctx.comp (collapse k₀ M) (collapse k₀ N) = collapse k₀ (Mat.comp M N) :=
  rfl

/-- **Consequence two — each leaf is history-free.** Under `constIx` the index
type of a leaf is the same in every context: the type can no longer say which
history the leaf was written for. -/
theorem constIx_history_free : constIx (K := K) ι k = constIx (K := K) ι k' :=
  rfl

/-- **Consequence three — pinning is well-defined.** Any work between any two
contexts already *is* a work at the pinned context: retargeting needs no
transport, because the types are equal. -/
theorem collapse_pin :
    Ctx S (constIx (K := K) ι) k k' = Ctx S (constIx (K := K) ι) k₀ k₀ :=
  rfl

/-- A corollary of the collapse, and not one of the design's four: staying put
is the plain identity. The pinned identity is the ordinary identity matrix, so
"do nothing" acquires no context-dependent meaning. -/
theorem collapse_idCtx [CommSemiring S] [CompleteCSemiring S] :
    (Ctx.idCtx : Ctx S (constIx (K := K) ι) k₀ k₀) = collapse k₀ Mat.idMat :=
  rfl

end Collapse

end Agentic
