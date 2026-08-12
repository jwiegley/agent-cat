import Mathlib.Data.ENat.Lattice
import Mathlib.Tactic.Push

/-!
# The fragment grade

Design §4, *stratified, not absent*. The design withdraws the outright refusal
of `bind` and replaces it with a stratification: value-dependence is allowed,
and the price it exacts is **paid in instruments, not in meaning**. Cost,
width, and plan are folds over the term; a term containing an opaque
`b → Term` has no finite fold. So the fragment becomes a *type index* — "an
object, not a prohibition", the antidote to the anti-pattern of legislating
against a construct one cannot give a meaning to.

This module is the index alone: the grade and the arithmetic that combines it.
It is deliberately free of any semantic content — no semiring, no matrix, no
meaning function appears here — because the grade is a fact about a term's
*shape*, and the syntax stratum (`Agentic.Term`) must be able to state that
fact without committing to how the term is read.

## The grade is `ℕ∞`, and the three constructors were its elements

The payload of a grade has one meaning throughout: **an upper bound on
data-dependent width**. A three-constructor inductive (`static`, `bounded n`,
`monadic`) was one encoding of that quantity, and the arithmetic written on it
— join takes the larger bound with `monadic` absorbing, `par` adds with
`monadic` absorbing, a bottom `static` below every bound — is, line for line,
the arithmetic Mathlib already carries on `ℕ∞`:

| the grade | `ℕ∞` |
|---|---|
| `static` | `0` (which is `⊥`) |
| `bounded n` | `(n : ℕ∞)` |
| `monadic` | `⊤` |
| the join of sequencing | `⊔` — `⊤` absorbs because it is the top |
| the addition of the tensor | `+` — `⊤` absorbs because `WithTop` says so |
| the grade order | `≤`, a `CompleteLinearOrder` |
| `static` is the bottom | `bot_le` |
| the join is an idempotent commutative monoid | `SemilatticeSup` |

So `Frag` is `ℕ∞`, and the module that used to prove the join's laws, the
tensor's laws, an order induced from the join, and the monotonicity of
everything in sight now proves none of them: they are `sup_assoc`, `sup_comm`,
`sup_idem`, `bot_sup_eq`, `add_comm`, `zero_add`, `le_sup_left`, `Nat.cast_le`,
and the rest of Mathlib's order and arithmetic on `ℕ∞`. Most of this module's
declarations went with them, and the ones that remain are about `scale`.

`static` and `bounded 0` are no longer *two ways of writing* no data-dependent
width — they are one grade written two ways, `bounded 0 = static` by `rfl`
(`Frag.bounded_zero`). The residual slack the three-constructor encoding had
to apologize for (a composite graded `bounded 0` where `static` was true) does
not exist to apologize for.

## What is still ours: `scale`, and the fan's `max 1`

One operation is not Mathlib's, because it is not an operation on `ℕ∞` that
anyone else would name: a data-dependent fan of at most `n` copies of a body
of grade `f` has grade `n * max 1 f`. Multiplicities multiply — `n` copies of
an at-most-`m`-wide body is at most `n * m` wide, so a 3-way fan over a 5-way
fan is 15 and not `max 3 5` — and the multiplier on the body is `max 1 f`
rather than `f` because a fan data-dependently instantiates its *whole* body,
static shell included, so the body's contribution is never honestly below one
copy's worth. That factor is named (`Frag.copies`) rather than inlined,
because it is the same number the semantic width bound multiplies written
sites by (`Term.peak_le_writtenSites_mul_copies`).

Two consequences of doing the arithmetic in `ℕ∞` rather than in the
three-constructor encoding, both of them repairs:

* `scale 0 monadic = static`. A zero-fan of an opaque body runs the body zero
  times, so it is a provable constant, and the honest grade is the bottom one.
  The old arithmetic answered `monadic` — the grade claimed no a-priori width
  for a term whose semantic width is provably `0` — which is the review's
  finding 1. `0 * ⊤ = 0` in `ℕ∞`, and that is the correct answer, not a
  coincidence of the encoding.
* `scale n monadic = monadic` for `n > 0` still holds (`ENat.mul_top`), so
  nothing about a genuine fan over an opaque body has been weakened.

## `abbrev`, not `def`

`Frag` is an `abbrev`, so it *is* `ℕ∞` to instance resolution, to `simp`, and
to the elaborator. That is the point: the whole content of this arc is that
the grade needs no arithmetic of its own, and a `def` would take that back —
every instance (`SemilatticeSup`, `OrderBot`, `AddCommMonoid`, `CommSemiring`,
`DecidableEq`, `DecidableLE`, `CompleteLinearOrder`) would have to be
re-declared by `inferInstanceAs`, and every Mathlib lemma about `ℕ∞` would
have to be transported or re-proved before `simp` could use it. The price of
the `abbrev` is defeq leakage — a `Frag` and an `ℕ∞` are interchangeable, and
nothing stops a grade being added to a cost bound — and that price is worth
paying *here* and not everywhere: `Agentic.Instances.Cost` is a `def` for the
opposite reason (it needs `*` to be `WithBot ℕ∞`'s `+`, a *different* algebra
on the carrier), and `Agentic.Keys.Width` is `SupMon ℕ` because it needs a
*second* monoid on `ℕ`. `Frag` competes with nobody: it uses `ℕ∞`'s own `⊔`,
`+` and `≤`, with exactly their Mathlib meanings, so there is no instance to
control and nothing for a wrapper to protect.

## Noncomputability, and why it is not a retreat

`⊔` and `max` on `ℕ∞` go through Mathlib's `CompleteLinearOrder`, which is
noncomputable, so `Frag.copies` and `Frag.scale` are noncomputable and so is
any *literal term* whose stored sub-grades mention them (`Agentic.Term`'s
smoke examples are `noncomputable example` for that reason and no other).
Nothing is lost that this package ever had: grades are type indices, folds
over terms still compute, and the decision procedures still run — `decide`
closes `bounded 2 ≤ bounded 5` and refutes its converse, which is the form an
implementation's fragment check takes.
-/

namespace Agentic

/-- A `Frag` is a representation of how much of a term's shape is knowable
before values flow, counted as data-dependent copies of the written shape:
`0` (every fold exact), `n` (folds return suprema over at most `n`-way
data-dependent shape), `⊤` (full value-dependent continuation; the meaning is
a kernel, the a-priori instruments honestly silent).

It is Mathlib's `ℕ∞` — see the module header for the table of what that buys
and for why this is an `abbrev`. -/
abbrev Frag := ℕ∞

namespace Frag

/-- Every fold is exact: branching goes through a decoding `Transform` onto a
finite coproduct of verdicts, and loops are fueled. Nothing about the term's
shape waits on a value. This is `0`, and it is also `⊥`. -/
def static : Frag := 0

/-- Data-dependent width, bounded above by `n`: the folds still answer, and
what they answer is an honest supremum rather than an exact count. -/
def bounded (n : Nat) : Frag := (n : ℕ∞)

/-- Plan-then-execute: an unbounded, value-dependent continuation. The meaning
is a perfectly good kernel; the a-priori instruments answer "no a-priori
cost", which is the truth and not an evasion. This is `⊤`. -/
def monadic : Frag := ⊤

/-- **The copies a grade admits**: `max 1` of the grade.

A grade counts *data-dependent* copies of a written shape, and the shape
always counts as one copy of itself, so a `static` term admits one copy and
not zero. This is the factor `scale` multiplies a fan's multiplicity by, and
the same factor the semantic width bound multiplies written sites by
(`Term.peak_le_writtenSites_mul_copies`) — one number, named once. -/
noncomputable def copies (f : Frag) : Frag := max 1 f

/-- Grade arithmetic for a data-dependent fan of at most `n` copies:
multiplicities multiply, and the body counts at least as itself.

The join is the wrong arithmetic for a fan. `n` copies of a body that is
itself at most `m` wide is at most `n * m` wide, not `max n m`: a 3-way fan
over a 5-way fan can have fifteen consultations outstanding. The multiplier on
the body is `copies`, not the body's grade, because a fan data-dependently
instantiates its **whole** body — including the body's static shell, the
consultations that are there whatever the values say — so the body's
contribution to width is never honestly below one copy's worth.

A `0`-fan grades `static` whatever the body, *including* an opaque one
(`scale_zero`): a fan of no copies runs nothing, and `0 * ⊤ = 0` in `ℕ∞`. -/
noncomputable def scale (n : Nat) (f : Frag) : Frag := (n : ℕ∞) * copies f

/-- **`static` and `bounded 0` are one grade.** In the three-constructor
encoding these were two elements with one meaning, and every operation that
consumed a grade upward had to be shown to treat them alike; here the equation
is `rfl` and there is nothing left to show. -/
theorem bounded_zero : bounded 0 = static := rfl

/-- `static` is `⊥`, so the design's guidance — *write in the lowest fragment
that expresses the job* — aims at Mathlib's bottom and inherits `bot_le`. -/
theorem static_eq_bot : static = (⊥ : Frag) := rfl

/-- `monadic` is `⊤`: no grade is more opaque than a full continuation, and
`le_top` says so. -/
theorem monadic_eq_top : monadic = (⊤ : Frag) := rfl

/-- Every grade admits at least one copy. -/
theorem one_le_copies (f : Frag) : 1 ≤ copies f := le_max_left _ _

/-- Hence no grade admits zero copies — which is what keeps the semantic width
bound's right-hand side from collapsing at `⊤`. -/
theorem copies_ne_zero (f : Frag) : copies f ≠ 0 := by
  intro h
  have h1 := one_le_copies f
  rw [h] at h1
  exact absurd h1 (by simp)

/-- Copies is monotone: a weaker claim about a body's shape admits at least as
many copies of it. -/
theorem copies_mono {f g : Frag} (h : f ≤ g) : copies f ≤ copies g :=
  max_le_max le_rfl h

/-- A static body admits exactly one copy of itself. -/
theorem copies_static : copies static = 1 := by
  show max 1 (0 : ℕ∞) = 1
  simp

/-- A bounded body admits `max 1 n` copies, with the `max` inside the cast:
the form the arithmetic downstream uses. -/
theorem copies_bounded (n : Nat) : copies (bounded n) = ((max 1 n : Nat) : ℕ∞) := by
  show max 1 ((n : Nat) : ℕ∞) = _
  rfl

/-- An opaque body admits unboundedly many copies. -/
theorem copies_monadic : copies monadic = monadic := by
  show max 1 (⊤ : ℕ∞) = ⊤
  simp

/-- **A fan multiplies the copies**, provided it has at least one. This is the
one arithmetic identity the fan case of the semantic width bound turns on, and
it is where the `max 1` pays for itself: `n` copies of a shape that already
counts once is `n * copies f`, which is itself at least one, so the outer
`max 1` is absorbed. -/
theorem copies_scale {n : Nat} (hn : 0 < n) (f : Frag) :
    copies (scale n f) = (n : ℕ∞) * copies f := by
  have hn' : (1 : ℕ∞) ≤ (n : ℕ∞) := by exact_mod_cast hn
  exact max_eq_right (one_le_mul_of_one_le_of_one_le hn' (one_le_copies f))

/-- A fan over a static body is bounded by the fan's own width. -/
theorem scale_static (n : Nat) : scale n static = bounded n := by
  show (n : ℕ∞) * copies static = _
  rw [copies_static, mul_one]
  rfl

/-- A fan multiplies the body's bound by its own, the body counting at least
as one copy of itself. -/
theorem scale_bounded (n m : Nat) :
    scale n (bounded m) = bounded (n * max 1 m) := by
  show (n : ℕ∞) * copies (bounded m) = _
  rw [copies_bounded]
  show ((n : Nat) : ℕ∞) * ((max 1 m : Nat) : ℕ∞) = ((n * max 1 m : Nat) : ℕ∞)
  push_cast
  rfl

/-- **The repaired grade** (acat-vel, review finding 1): a fan of no copies
runs nothing, whatever its body — *including an opaque one*. The old
arithmetic sent `scale 0 monadic` to `monadic`, claiming no a-priori width for
a term that is a provable constant; `0 * ⊤ = 0` in `ℕ∞` gives the honest
answer, and the honest answer is the bottom grade. -/
theorem scale_zero (f : Frag) : scale 0 f = static := by
  show (0 : ℕ∞) * copies f = 0
  simp

/-- A fan of at least one copy over an opaque body is opaque: multiplicity
does not restore a finite fold. -/
theorem scale_monadic {n : Nat} (hn : 0 < n) : scale n monadic = monadic := by
  show (n : ℕ∞) * copies monadic = ⊤
  rw [copies_monadic]
  exact ENat.mul_top (by exact_mod_cast hn.ne')

/-- `scale` is monotone in both arguments: a fold that answers for a fan's
grade answers for any weakening of either the multiplicity or the body. -/
theorem scale_le_scale {n n' : Nat} {f g : Frag} (hn : n ≤ n') (hf : f ≤ g) :
    scale n f ≤ scale n' g :=
  mul_le_mul' (by exact_mod_cast hn) (copies_mono hf)

/-- **The tensor is never cheaper than the alternation**: running both
branches can only widen what running the more opaque of them already costs.
Mathlib has the two halves (`le_self_add`, `le_add_self`) but not this
statement, which is true on a canonically ordered carrier like `ℕ∞` and false
of a lattice with an arbitrary addition on it. -/
theorem sup_le_add (f g : Frag) : f ⊔ g ≤ f + g := sup_le le_self_add le_add_self

/-! On bounded widths the grade order is the order of `Nat` — a narrower
data-dependent fan-out is the weaker claim about shape — and that is
`Nat.cast_le`, spelled exactly that way at every use site. The wrapper this
module used to keep for it is gone. -/

/-- The order is not merely decidable in principle: `decide` closes goals about
it, which is what an implementation's fragment check will be — and it still
does with the grade collapsed onto `ℕ∞`, which is the cost this collapse had
to be shown not to incur. -/
example : Frag.bounded 2 ≤ Frag.bounded 5 := by decide

/-- And it refutes the false comparisons just as directly. -/
example : ¬ (Frag.bounded 5 ≤ Frag.bounded 2) := by decide

/-- A bounded grade is below `static` exactly when it is `static`: the old
`not_bounded_le_static` was true only because the encoding kept `bounded 0`
and `static` apart. -/
example {n : Nat} : bounded n ≤ static ↔ n = 0 := by
  rw [show static = bounded 0 from bounded_zero.symm]
  exact Nat.cast_le.trans (by omega)

end Frag

end Agentic
