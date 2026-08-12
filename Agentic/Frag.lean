import Agentic.Monoid

/-!
# The fragment grade

Design §4, *stratified, not absent*. The design withdraws the outright refusal
of `bind` and replaces it with a stratification: value-dependence is allowed,
and the price it exacts is **paid in instruments, not in meaning**. Cost,
width, and plan are folds over the term; a term containing an opaque
`b → Term` has no finite fold. So the fragment becomes a *type index* — "an
object, not a prohibition", the antidote to the anti-pattern of legislating
against a construct one cannot give a meaning to.

This module is the index alone: three grades and the arithmetic that combines
them. It is deliberately free of any semantic content — no semiring, no
matrix, no meaning function appears here — because the grade is a fact about a
term's *shape*, and the syntax stratum (`Agentic.Term`) must be able to state
that fact without committing to how the term is read.

The payload of `bounded n` has one meaning throughout, and every operation
here is answerable to it: **an upper bound on data-dependent width**, with
`static` the grade of *zero* data-dependent width. Three operations follow
from that reading, and which one a constructor uses is not a matter of taste:

* `join` — the join of a three-element lattice with `static` at the bottom and
  `monadic` at the top, `bounded` widths ordered by `Nat`. Sequencing,
  alternation and branching take it: only one part's width is in flight at a
  time, so the composite is exactly as opaque as its most opaque component.
* `par` — widths **add**, because a tensor has both branches in flight at
  once. Taking the join here would grade an at-most-3-wide fan beside an
  at-most-5-wide fan as `bounded 5`, and the honest width is 8.
* `scale` — multiplicities **multiply**, because a fan of at most `n` copies
  of an at-most-`m`-wide body is at most `n * m` wide. Taking the join here
  would grade a 3-way fan over a 5-way fan as `bounded 5`, and the honest
  multiplicity is 15. The multiplier is `max 1 m`, not `m`: a fan
  data-dependently instantiates its *whole* body, static shell included, so
  the body's contribution to width is never honestly below one copy's worth.

`static` and `bounded 0` are the two ways of writing "no data-dependent
width", and every operation that consumes a grade *upward* now treats them
alike (acat-l59): `scale n static = bounded n = scale n (bounded 0)`, and
`join`/`par` of either with `bounded m` give `bounded m`, with either against
`monadic` giving `monadic`. One residual difference survives, against `static`
itself — `join static static = static` while `join (bounded 0) static =
bounded 0`, and likewise for `par`. That is upper-bound slack and nothing
worse: `bounded 0` sits *above* `static` in the grade order, so a composite
graded that way makes the weaker claim about shape, never a false one.

The equation order in `Frag.join` and `Frag.par` is chosen so that `static ⊔ g`
and `monadic ⊔ g` reduce *definitionally* for a variable `g`; the syntax
stratum depends on that, since a pipeline of static parts must elaborate at
grade `static` with no coercion.

`join` is an idempotent commutative monoid, so it is one — `IdemCMonoid Frag`
(`Agentic.Monoid`) — and the grade order below is that class's induced order
rather than a sixth hand-rolled copy of the same six proofs. `par` is a monoid
too, and deliberately gets no instance: the classes are keyed by their carrier,
a second `PMonoid Frag` would contradict the first, and `Agentic.Keys` states
the discipline that follows from that (one carrier, one `⋄`). Wrapping `par` in
a newtype to say what `par_assoc` and `par_comm` already say would buy no
theorem, so the tensor's arithmetic stays as the plain equations it is.
-/

namespace Agentic

/-- A `Frag` is a representation of how much of a term's shape is knowable
before values flow: `static` (every fold exact), `bounded n` (folds return
suprema over at most `n`-way data-dependent shape), `monadic` (full
value-dependent continuation; the meaning is a kernel, the a-priori
instruments honestly silent). -/
inductive Frag where
  /-- Every fold is exact: branching goes through a decoding `Transform` onto
  a finite coproduct of verdicts, and loops are fueled. Nothing about the
  term's shape waits on a value. -/
  | static : Frag
  /-- Data-dependent width, bounded above by `n`: the folds still answer, and
  what they answer is an honest supremum rather than an exact count. -/
  | bounded (n : Nat) : Frag
  /-- Plan-then-execute: an unbounded, value-dependent continuation. The
  meaning is a perfectly good kernel; the a-priori instruments answer "no
  a-priori cost", which is the truth and not an evasion. -/
  | monadic : Frag
  deriving DecidableEq, Repr

namespace Frag

/-- The combination of two grades: a composite is as opaque as its most opaque
part. `static` is the identity (a static part costs the other part nothing),
`bounded` widths take the larger bound, and `monadic` absorbs (once a
continuation is opaque, no amount of static neighbourhood makes the fold
finite again).

The equation order matters and is not cosmetic: with `static` first and
`monadic` second, both `join static g` and `join monadic g` reduce by `rfl`
for a *variable* `g`, which is what lets `Term`'s grade indices collapse
during elaboration instead of leaving stuck `join` applications behind. -/
def join : Frag → Frag → Frag
  | static,    g         => g
  | monadic,   _         => monadic
  | f,         static    => f
  | _,         monadic   => monadic
  | bounded n, bounded m => bounded (max n m)

/-- A static part costs its neighbour nothing: `static` is a left identity.
True by `rfl` for a variable grade, by the equation order above. -/
theorem static_join (f : Frag) : join static f = f := rfl

/-- `static` is a right identity too — though this one needs the cases, since
the second argument is the one being matched. -/
theorem join_static : ∀ f : Frag, join f static = f
  | static => rfl
  | bounded _ => rfl
  | monadic => rfl

/-- An opaque continuation absorbs on the left: nothing downstream restores a
finite fold. True by `rfl` for a variable grade. -/
theorem monadic_join (f : Frag) : join monadic f = monadic := rfl

/-- An opaque continuation absorbs on the right, for the same reason. -/
theorem join_monadic : ∀ f : Frag, join f monadic = monadic
  | static => rfl
  | bounded _ => rfl
  | monadic => rfl

/-- Combining a grade with itself changes nothing: the join is idempotent. -/
theorem join_idem : ∀ f : Frag, join f f = f
  | static => rfl
  | bounded n => congrArg bounded (Nat.max_self n)
  | monadic => rfl

/-- The join is commutative: which part of a composite one looks at first is
not a fact about the composite. -/
theorem join_comm : ∀ f g : Frag, join f g = join g f
  | static, static => rfl
  | static, bounded _ => rfl
  | static, monadic => rfl
  | bounded _, static => rfl
  | bounded n, bounded m => congrArg bounded (Nat.max_comm n m)
  | bounded _, monadic => rfl
  | monadic, static => rfl
  | monadic, bounded _ => rfl
  | monadic, monadic => rfl

/-- The join is associative: a composite's grade does not depend on how its
parts were bracketed. This is what lets `seqT`'s index be read off a term
without normalizing the tree. -/
theorem join_assoc : ∀ f g h : Frag, join (join f g) h = join f (join g h) := by
  intro f g h
  cases f <;> cases g <;> cases h <;>
    first
      | rfl
      | exact congrArg bounded (Nat.max_assoc _ _ _)

/-- Two bounded widths join to the larger bound. -/
theorem bounded_join_bounded (n m : Nat) :
    join (bounded n) (bounded m) = bounded (max n m) := rfl

/-- **The join is the package's idempotent commutative monoid**, with `static`
as its unit: the five theorems above are its five laws, and the instance adds
no content beyond naming them. What it buys is the order — `Frag.le` below is the join order, and `Frag` is
therefore a Mathlib `SemilatticeSup` with `⊔ = join` and `⊥ = static` — and,
with it, the licence reading: idempotence is why a grade recomputed twice is
the grade computed once. -/
instance instCMonoidFrag : CommMonoid Frag where
  mul := join
  one := static
  npow n f := Nat.rec static (fun _ ih => join ih f) n
  mul_assoc := join_assoc
  one_mul := static_join
  mul_one := join_static
  mul_comm := join_comm

/-- Recomputing a grade twice is computing it once: the duplication licence at
`Frag`, in Mathlib's unbundled `Std.IdempotentOp` form. -/
instance instIdemCMonoid : IdemCMonoid Frag := ⟨join_idem⟩

/-- The grade combination is the join, definitionally. -/
theorem op_eq_join (f g : Frag) : f ⋄ g = join f g := rfl

/-- Grade arithmetic for the tensor: widths in flight add.

The join is the wrong arithmetic for `⊗`. Under a join, two bounded branches
would grade at the larger of the two bounds, but a tensor runs *both* branches
— an at-most-3-wide fan beside an at-most-5-wide fan can have eight
consultations outstanding at once, not five. Since the payload of `bounded` is
an upper bound on data-dependent width, and `static` is the grade with *no*
data-dependent width, the tensor's arithmetic is addition with `static` as the
zero and `monadic` still absorbing.

The equation order is the same trick as in `join`, and for the same reason:
`par static g` and `par monadic g` reduce by `rfl` for a *variable* `g`, so a
tensor with one static side elaborates at the other side's grade with no
coercion. -/
def par : Frag → Frag → Frag
  | static,    g         => g
  | monadic,   _         => monadic
  | f,         static    => f
  | _,         monadic   => monadic
  | bounded n, bounded m => bounded (n + m)

/-- Grade arithmetic for a data-dependent fan of at most `n` copies:
multiplicities multiply, and the body counts at least as itself.

The join is the wrong arithmetic for a fan. `n` copies of a body that is
itself at most `m` wide is at most `n * m` wide, not `max n m`: a 3-way fan
over a 5-way fan can have fifteen consultations outstanding. A static body
contributes no data-dependent width of its own, so the fan contributes exactly
its own bound `n`; and an opaque body stays opaque however many copies of it
are run.

The multiplier on a `bounded m` body is `max 1 m` rather than `m`, and the
reason is the one that fixes acat-l59: a fan data-dependently instantiates its
**whole** body — including the body's static shell, the consultations that are
there whatever the values say — so the body's contribution to width is never
honestly below one copy's worth. Plain `n * m` sent `scale n (bounded 0)` to
`bounded 0`, under-grading a fan over a body that mixes real consultations
with a 0-fan, and contradicting the order: `static ≤ bounded 0`, yet
`scale n static = bounded n` was not below `scale n (bounded 0)`. With
`max 1 m` the two agree (`scale_bounded_zero`) and the fan is monotone in its
body (`scale_le_scale_right`). A `0`-fan still grades `bounded 0` whatever the
body — `scale 0 (bounded m) = bounded (0 * max 1 m) = bounded 0` — because a
fan of no copies runs nothing. -/
def scale (n : Nat) : Frag → Frag
  | static    => bounded n
  | bounded m => bounded (n * max 1 m)
  | monadic   => monadic

/-- A static side of a tensor contributes no width: `static` is a left zero
for `par`. True by `rfl` for a variable grade, by the equation order above. -/
theorem static_par (f : Frag) : par static f = f := rfl

/-- `static` contributes no width on the right either — this one needs the
cases, since the second argument is the one being matched. -/
theorem par_static : ∀ f : Frag, par f static = f
  | static => rfl
  | bounded _ => rfl
  | monadic => rfl

/-- An opaque branch absorbs on the left: running something finite beside an
opaque continuation does not make the composite's width foldable. True by
`rfl` for a variable grade. -/
theorem monadic_par (f : Frag) : par monadic f = monadic := rfl

/-- An opaque branch absorbs on the right, for the same reason. -/
theorem par_monadic : ∀ f : Frag, par f monadic = monadic
  | static => rfl
  | bounded _ => rfl
  | monadic => rfl

/-- Two bounded branches in flight add their widths. -/
theorem bounded_par_bounded (n m : Nat) :
    par (bounded n) (bounded m) = bounded (n + m) := rfl

/-- The tensor's arithmetic is commutative: which branch one calls the left
one is not a fact about the composite. -/
theorem par_comm : ∀ f g : Frag, par f g = par g f
  | static, static => rfl
  | static, bounded _ => rfl
  | static, monadic => rfl
  | bounded _, static => rfl
  | bounded n, bounded m => congrArg bounded (Nat.add_comm n m)
  | bounded _, monadic => rfl
  | monadic, static => rfl
  | monadic, bounded _ => rfl
  | monadic, monadic => rfl

/-- The tensor's arithmetic is associative: a wide panel's grade does not
depend on how its branches were bracketed. -/
theorem par_assoc : ∀ f g h : Frag, par (par f g) h = par f (par g h) := by
  intro f g h
  cases f <;> cases g <;> cases h <;>
    first
      | rfl
      | exact congrArg bounded (Nat.add_assoc _ _ _)

/-- A fan over a static body is bounded by the fan's own width. -/
theorem scale_static (n : Nat) : scale n static = bounded n := rfl

/-- A fan multiplies the body's bound by its own, the body counting at least
as one copy of itself. -/
theorem scale_bounded (n m : Nat) :
    scale n (bounded m) = bounded (n * max 1 m) := rfl

/-- **The repaired incoherence** (acat-l59): a fan over a `bounded 0` body
grades exactly as a fan over a `static` one. `static` and `bounded 0` both say
"no data-dependent width", the grade order places the second just above the
first, and `scale` no longer distinguishes them — which is what makes
`scale_le_scale_right` true. -/
theorem scale_bounded_zero (n : Nat) : scale n (bounded 0) = bounded n :=
  congrArg bounded (Nat.mul_one n)

/-- A fan over an opaque body is opaque: multiplicity does not restore a
finite fold. -/
theorem scale_monadic (n : Nat) : scale n monadic = monadic := rfl

/-- A fan of no copies runs nothing, whatever its body: the multiplier is
beside the point once the multiplicity is zero. -/
example : scale 0 (bounded 7) = bounded 0 := rfl

/-- `f ≤ g` on grades means *`f` is no more opaque than `g`*: the order induced
by the join, `f ⊔ g = g`. It is the `≤` of the Mathlib `SemilatticeSup` just
below, which is why the lemmas after it are one line each — the order comes
from Mathlib, as `Cost`'s does (there it is Mathlib's complete lattice on
`WithBot ℕ∞`). -/
def le (f g : Frag) : Prop := join f g = g

/-- **The grade order is Mathlib's.** `Frag` is a join-semilattice with a
bottom: `⊔` is `join`, `⊥` is `static`, and `≤` is the equation `f ⊔ g = g`.
Reflexivity, transitivity, antisymmetry, the two upper-bound laws, the
least-upper-bound law and monotonicity are Mathlib's from here on; the package
no longer re-derives an order from an idempotent join. -/
instance instSemilatticeSupFrag : SemilatticeSup Frag where
  le := Frag.le
  le_refl := join_idem
  le_trans := fun f g h hfg hgh => by
    show join f h = h
    rw [← hgh, ← join_assoc, hfg]
  le_antisymm := fun f g hfg hgf => by
    have h : join f g = join g f := join_comm f g
    rw [hfg] at h; rw [hgf] at h; exact h.symm
  sup := join
  le_sup_left := fun f g => by
    show join f (join f g) = join f g
    rw [← join_assoc, join_idem]
  le_sup_right := fun f g => by
    show join g (join f g) = join f g
    rw [join_comm f g, ← join_assoc, join_idem]
  sup_le := fun f g h hf hg => by
    show join (join f g) h = h
    rw [join_assoc, show join g h = h from hg, hf]

/-- `static` is the bottom of the grade order: the design's guidance — *write
in the lowest fragment that expresses the job* — has a bottom to aim at. -/
instance instOrderBotFrag : OrderBot Frag where
  bot := static
  bot_le _ := rfl

/-- `≤` on grades is the join order (the old `LE` instance name, now the one
Mathlib's semilattice supplies). -/
abbrev instLEFrag : LE Frag := inferInstance

/-- The grade order is decidable: it is an equation between grades, and grades
have decidable equality. -/
instance decLe (f g : Frag) : Decidable (f ≤ g) :=
  inferInstanceAs (Decidable (join f g = g))

/-- Unfolding lemma: `f ≤ g` is by definition `f ⊔ g = g`. -/
theorem le_def {f g : Frag} : (f ≤ g) = (join f g = g) := rfl

/-- The grade order is reflexive (Mathlib's, at `Frag`). -/
theorem le_refl (f : Frag) : f ≤ f := _root_.le_refl f

/-- The grade order is transitive. -/
theorem le_trans {f g h : Frag} (hfg : f ≤ g) (hgh : g ≤ h) : f ≤ h :=
  _root_.le_trans hfg hgh

/-- The grade order is antisymmetric: it is a genuine partial order, so
"lowest fragment that expresses the job" names a unique grade when it names
one at all. -/
theorem le_antisymm {f g : Frag} (hfg : f ≤ g) (hgf : g ≤ f) : f = g :=
  _root_.le_antisymm hfg hgf

/-- `static` is the bottom: the design's guidance — *write in the lowest
fragment that expresses the job* — has a bottom to aim at. -/
theorem static_le (f : Frag) : static ≤ f := rfl

/-- `monadic` is the top: no grade is more opaque than a full continuation. -/
theorem le_monadic : ∀ f : Frag, f ≤ monadic
  | static => rfl
  | bounded _ => rfl
  | monadic => rfl

/-- On bounded widths the grade order is the order of `Nat`: a narrower
data-dependent fan-out is the weaker claim about shape. -/
theorem bounded_le_bounded {n m : Nat} : (bounded n ≤ bounded m) ↔ n ≤ m := by
  constructor
  · intro h
    have h' : max n m = m := bounded.inj h
    exact h' ▸ Nat.le_max_left n m
  · intro h
    show join (bounded n) (bounded m) = bounded m
    exact congrArg bounded (Nat.max_eq_right h)

/-- A bounded grade is never below `static`: data-dependent width is a real
concession, not a relabelling of a static term. -/
theorem not_bounded_le_static {n : Nat} : ¬ (bounded n ≤ static) := by
  intro h; exact Frag.noConfusion h

/-- The order is not merely decidable in principle: `decide` closes goals about
it, which is what an implementation's fragment check will be. -/
example : Frag.bounded 2 ≤ Frag.bounded 5 := by decide

/-- And it refutes the false comparisons just as directly. -/
example : ¬ (Frag.bounded 5 ≤ Frag.bounded 2) := by decide

/-- `monadic` is never below anything but itself. -/
theorem eq_monadic_of_monadic_le : ∀ {g : Frag}, monadic ≤ g → g = monadic
  | static, h => h.symm
  | bounded _, h => h.symm
  | monadic, _ => rfl

/-- A composite is at least as opaque as its left part. A fold that answers
for a `join` grade therefore answers for either part's grade. -/
theorem le_join_left (f g : Frag) : f ≤ join f g := le_sup_left

/-- A composite is at least as opaque as its right part. -/
theorem le_join_right (f g : Frag) : g ≤ join f g := le_sup_right

/-- A grade above both parts is above the composite: the join really is the
join of the grade order, and not merely one upper bound of the two parts. -/
theorem join_le {f g h : Frag} (hf : f ≤ h) (hg : g ≤ h) : join f g ≤ h :=
  sup_le hf hg

/-- The join is monotone in both arguments: weakening the parts' claims about
shape weakens the composite's, and never the other way. This is the lemma a
grade-respecting fold needs when it recurses under `seqT`, `sumT` and
`choiceT`. -/
theorem join_le_join {f f' g g' : Frag} (hf : f ≤ f') (hg : g ≤ g') :
    join f g ≤ join f' g' :=
  sup_le_sup hf hg

/-- The grade order is linear: `static` below every `bounded n`, every
`bounded n` below `monadic`, and two bounded widths compared by `Nat`. Two
grades are therefore always comparable, which is what lets a fold over a
branching term take "the more opaque of the two" without a lattice argument. -/
theorem le_total : ∀ f g : Frag, f ≤ g ∨ g ≤ f
  | static, _ => Or.inl rfl
  | _, static => Or.inr rfl
  | monadic, _ => Or.inr (le_monadic _)
  | _, monadic => Or.inl (le_monadic _)
  | bounded n, bounded m =>
    (Nat.le_total n m).imp bounded_le_bounded.mpr bounded_le_bounded.mpr

/-- The tensor is never cheaper than the alternation: running both branches
can only widen what running the more opaque of them already costs. -/
theorem join_le_par : ∀ f g : Frag, join f g ≤ par f g
  | static, _ => le_refl _
  | monadic, _ => le_refl _
  | bounded _, static => le_refl _
  | bounded _, monadic => le_refl _
  | bounded n, bounded m =>
    bounded_le_bounded.mpr (Nat.max_le.mpr ⟨Nat.le_add_right n m, Nat.le_add_left m n⟩)

/-- `par` is monotone in both arguments, like `join`: a wider bound on either
branch is a wider bound on the tensor. -/
theorem par_le_par {f f' g g' : Frag} (hf : f ≤ f') (hg : g ≤ g') :
    par f g ≤ par f' g' := by
  cases f <;> cases f' <;> cases g <;> cases g' <;>
    first
      | exact Frag.noConfusion hf
      | exact Frag.noConfusion hg
      | exact le_monadic _
      | exact static_le _
      | exact hf
      | exact hg
      | (apply bounded_le_bounded.mpr
         have h₁ := bounded_le_bounded.mp hf
         have h₂ := bounded_le_bounded.mp hg
         omega)
      | (apply bounded_le_bounded.mpr
         have h₁ := bounded_le_bounded.mp hf
         omega)
      | (apply bounded_le_bounded.mpr
         have h₂ := bounded_le_bounded.mp hg
         omega)

/-- A fan is monotone in its bound: promising more copies is the weaker claim
about shape. -/
theorem scale_le_scale_left {n n' : Nat} (h : n ≤ n') :
    ∀ f : Frag, scale n f ≤ scale n' f
  | static => bounded_le_bounded.mpr h
  | bounded m => bounded_le_bounded.mpr (Nat.mul_le_mul_right (max 1 m) h)
  | monadic => le_refl _

/-- A fan is monotone in its **body** too: a weaker claim about the body's
shape is a weaker claim about the fan's. This is the lemma the old `n * m`
arithmetic made false — `static ≤ bounded 0` while `scale n static = bounded n`
was not below `scale n (bounded 0) = bounded 0` — and the `max 1 m` multiplier
is exactly what repairs it (acat-l59). -/
theorem scale_le_scale_right (n : Nat) :
    ∀ {f g : Frag}, f ≤ g → scale n f ≤ scale n g
  | static, static, _ => le_refl _
  | static, bounded m, _ => by
      apply bounded_le_bounded.mpr
      have h₁ : n * 1 ≤ n * max 1 m :=
        Nat.mul_le_mul (Nat.le_refl n) (Nat.le_max_left 1 m)
      rw [Nat.mul_one] at h₁
      exact h₁
  | static, monadic, _ => le_monadic _
  | bounded _, static, h => absurd h not_bounded_le_static
  | bounded m, bounded m', h => by
      have hm : m ≤ m' := bounded_le_bounded.mp h
      have hmax : max 1 m ≤ max 1 m' := by omega
      exact bounded_le_bounded.mpr (Nat.mul_le_mul (Nat.le_refl n) hmax)
  | bounded _, monadic, _ => le_monadic _
  | monadic, static, h => Frag.noConfusion h
  | monadic, bounded _, h => Frag.noConfusion h
  | monadic, monadic, _ => le_refl _

/-- `scale` is monotone in both arguments — the lemma that keeps the old
partial one's name, now that the body direction is true as well. A fold that
answers for the fan's grade therefore answers for any weakening of either the
multiplicity or the body. -/
theorem scale_le_scale {n n' : Nat} {f g : Frag} (hn : n ≤ n') (hf : f ≤ g) :
    scale n f ≤ scale n' g :=
  le_trans (scale_le_scale_left hn f) (scale_le_scale_right n' hf)

end Frag

end Agentic
