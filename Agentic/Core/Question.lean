import Agentic.Scope
import Mathlib.Algebra.FreeMonoid.Basic
import Mathlib.Algebra.GroupWithZero.WithZero

/-!
# Question space: what an addressee can say, and what determines what they say

Rederivation kernel §1, §3 q3, §3 q7, §3 q8. This is the first of the three
modules of the mathematical space; nothing here knows what a workflow is.

Three decisions are made here and each is a *meaning*, not a convenience.

* **The answer universe is small and closed.** `Code` tags an answer type and
  `El` gives it. `El c` is the set of things an addressee can *say*, so it is
  inhabited (an addressee always says something, even if what it says is "I
  decline") and it lives in `Type 0`, which is what lets the world
  `Ω := (c : Code) → Q c → El c` be an ordinary function type rather than a
  rank-2 one. Extending the universe is adding a constructor and a clause; the
  two instances below are then discharged by `inferInstanceAs`.

* **The question carries everything that determines the reply** — addressee,
  scope, prompt, draw index. It has to: the world is a *function* of it. In
  particular scope is a field and not a wrapper around meanings (§3 q3), so the
  bulk operator `under σ` (see `Agentic/Core/Dlg.lean`) is a fold and not a
  constructor, and `Agentic.LastOpt`'s innermost-wins is the scope algebra
  verbatim.

* **Refusal is an answer** (§3 q8). There is no error layer, no `Option` in the
  meaning and no `⊥`; a `Verdict` that declines is an ordinary inhabitant of
  `El .verdict`, and the monoid says what a panel of them comes to.
-/

namespace Agentic.Core

open Agentic (LastOpt)

/-! ## The scope axes -/

/-- `[[Addressee]]` = the party that answers: one carrier for model, tool and
person, because no morphism separates them (§3 q7) — the differences are cost
coordinates, not constructs. -/
inductive Addressee where
  /-- A language model, named. -/
  | model (id : String)
  /-- A tool, named. -/
  | tool (id : String)
  /-- A person, named. -/
  | person (id : String)
  deriving DecidableEq, Repr, Inhabited

/-- `DecidableEq` transported through the `LastOpt` synonym, so that a scope —
and hence a question, and hence a memo table — has decidable equality. -/
instance instDecidableEqLastOpt {α : Type} [DecidableEq α] : DecidableEq (LastOpt α) :=
  inferInstanceAs (DecidableEq (Option α))

/-- `[[QScope]]` = a point of the two-axis scope monoid: which model, in which
mode, each axis either silent or saying one thing.

This is `Agentic.Scope` at the two axes the domain has, so `innermost_wins`,
`outer_survives_silence` and `axis_independence` are already proved of it. The
non-commutativity of `LastOpt` *is* innermost-wins; nothing else here has to
enforce an override discipline. -/
abbrev QScope : Type := Agentic.Scope String String

/-- `DecidableEq` transported through the `Scope` synonym: a question's scope is
a pair of axes, each an `Option`, so equality of questions is decidable and a
memo table is a lookup rather than a proposition. -/
instance instDecidableEqQScope : DecidableEq QScope :=
  inferInstanceAs (DecidableEq (LastOpt String × LastOpt String))

/-! ## Verdicts: refusal is an answer, and a panel is a monoid fold -/

/-- `[[Objection]]` = one recorded reason an addressee did not approve. -/
abbrev Objection : Type := String

/-- `[[Verdict]]` = the free monoid on objections with an absorbing element
adjoined for refusal: `WithZero (FreeMonoid Objection)`.

`approve = 1` (nothing was objected to), `object os` is the formal product of
the objections raised, and `declined = 0`, which annihilates — a panel one of
whose members would not answer has not approved and has no objection list to
show for it either.

Standard vocabulary, deliberately: the monoid, its unit, its associativity and
its zero are Mathlib's `MonoidWithZero (WithZero (FreeMonoid α))`, so the laws
are already paid for rather than proved here, and there is no redundant
`object []`-versus-`approve` presentation to keep coherent. -/
def Verdict : Type := WithZero (FreeMonoid Objection)

namespace Verdict

instance instMonoidWithZero : MonoidWithZero Verdict :=
  inferInstanceAs (MonoidWithZero (WithZero (FreeMonoid Objection)))

instance instDecidableEq : DecidableEq Verdict :=
  inferInstanceAs (DecidableEq (Option (List Objection)))

instance instInhabited : Inhabited Verdict := ⟨1⟩

/-- Nothing was objected to. `[[approve]] = 1`. -/
def approve : Verdict := 1

/-- The addressee would not answer. `[[declined]] = 0`. -/
def declined : Verdict := 0

/-- The objections raised, as a formal product. `[[object os]] = ↑os`. -/
def object (os : List Objection) : Verdict :=
  WithZero.coe (α := FreeMonoid Objection) (FreeMonoid.ofList os)

/-- **Morphism equation.** `object` is the monoid morphism from objection lists:
`[[object (a ++ b)]] = [[object a]] * [[object b]]`. Derived, not checked — the
definition above is the solved form of this equation, which is why it is `rfl`. -/
theorem object_mul_object (a b : List Objection) :
    object a * object b = object (a ++ b) := rfl

/-- `[[approve]] = 1` is the unit on the left. -/
theorem approve_mul (v : Verdict) : approve * v = v := one_mul v

/-- `[[approve]] = 1` is the unit on the right. -/
theorem mul_approve (v : Verdict) : v * approve = v := mul_one v

/-- Refusal annihilates on the left: `[[declined]] * v = [[declined]]`. -/
theorem declined_mul (v : Verdict) : declined * v = declined := zero_mul v

/-- Refusal annihilates on the right: `v * [[declined]] = [[declined]]`. -/
theorem mul_declined (v : Verdict) : v * declined = declined := mul_zero v

/-- Every verdict is a refusal or a (possibly empty) list of objections: the
case analysis a `case` node branches on. -/
theorem eq_declined_or_object (v : Verdict) : v = declined ∨ ∃ os, v = object os := by
  induction v using WithZero.recZeroCoe with
  | zero => exact Or.inl rfl
  | coe a => exact Or.inr ⟨FreeMonoid.toList a, rfl⟩

/-- Objecting is not declining. -/
theorem object_ne_declined (os : List Objection) : object os ≠ declined :=
  WithZero.coe_ne_zero

/-- `Approved v` = the verdict raised nothing: `v = 1`. -/
def Approved (v : Verdict) : Prop := v = approve

/-- `Approved` at the unit. -/
@[simp] theorem approved_approve : Approved approve := rfl

/-- Approval is the empty objection list, and only that. -/
theorem approved_object_iff (os : List Objection) : Approved (object os) ↔ os = [] := by
  constructor
  · intro h; exact Option.some.inj h
  · rintro rfl; rfl

/-- Refusal is not approval — the whole point of refusal being an answer rather
than an exception. -/
theorem not_approved_declined : ¬ Approved declined :=
  fun h => WithZero.zero_ne_coe h

/-- **Morphism equation.** `Approved` is the monoid morphism into
conjunction — `[[Approved (v * w)]] = [[Approved v]] ∧ [[Approved w]]` — which
is the statement that "everyone approved" is compositional, and the reason a
panel's reducer is an ordinary `foldMap` into this monoid (§3 q6). -/
theorem approved_mul (v w : Verdict) : Approved (v * w) ↔ Approved v ∧ Approved w := by
  rcases eq_declined_or_object v with rfl | ⟨a, rfl⟩
  · simp [declined_mul, not_approved_declined]
  · rcases eq_declined_or_object w with rfl | ⟨b, rfl⟩
    · simp [mul_declined, not_approved_declined]
    · simp [object_mul_object, approved_object_iff]

end Verdict

/-! ## The answer universe -/

/-- `[[Code]]` = a tag for one answer type: the small, closed universe of things
an addressee can be asked *for*.

Small on purpose. `El c` must live in `Type 0` so that `Ω` is an ordinary
dependent function type, and it must be inhabited so that total worlds exist —
those two facts are what make the world a *function of questions* rather than a
rank-2 oracle threaded through a history. -/
inductive Code where
  /-- Free text. -/
  | text
  /-- A review verdict (§3 q8: refusal included). -/
  | verdict
  /-- A yes/no. -/
  | flag
  /-- An acknowledgement carrying no information. -/
  | ack
  deriving DecidableEq, Repr, Inhabited

/-- `[[El c]]` = the set of things an addressee can say in reply to a question of
kind `c`. Every one of them is inhabited and lives in `Type 0`. -/
def El : Code → Type
  | .text => String
  | .verdict => Verdict
  | .flag => Bool
  | .ack => Unit

/-- Every answer type is inhabited: an addressee always says *something*. This
is what makes total worlds exist, and hence what makes the defaulting
totalization of a memo table (`Agentic.Core.worldOf`) definable. -/
instance instInhabitedEl : (c : Code) → Inhabited (El c)
  | .text => inferInstanceAs (Inhabited String)
  | .verdict => inferInstanceAs (Inhabited Verdict)
  | .flag => inferInstanceAs (Inhabited Bool)
  | .ack => inferInstanceAs (Inhabited Unit)

/-- Every answer type has decidable equality, which is what makes the per-run
certificate a `Bool` rather than a proposition. -/
instance instDecidableEqEl : (c : Code) → DecidableEq (El c)
  | .text => inferInstanceAs (DecidableEq String)
  | .verdict => inferInstanceAs (DecidableEq Verdict)
  | .flag => inferInstanceAs (DecidableEq Bool)
  | .ack => inferInstanceAs (DecidableEq Unit)

/-! ## Questions -/

/-- `[[Q c]]` = a point of question space: everything that determines the reply
to a question whose answer is an `El c` — who is asked, under what standing
conditions, in what words, and which independent draw this is.

It carries all four because the world is a *function* of it (§1). Two
consequences that other designs need machinery for are here mere consequences:
asking the same question twice is the same answer (§3 q1), because `Ω` is a
function; and resampling is a *different question* rather than a different
operation, because `draw` is a field the author varies — no gensym, no state,
no freshness from nowhere. -/
structure Q (c : Code) where
  /-- Who is being asked. -/
  addressee : Addressee
  /-- The standing conditions under which they are asked (§3 q3). -/
  scope : QScope
  /-- Everything said to them. -/
  prompt : String
  /-- Which independent draw this is; `0` unless deliberately resampling. -/
  draw : Nat
  deriving DecidableEq

/-- `[[Sig]]` = a relabelling of question space, one per code. The scope
operator `under σ` of `Agentic/Core/Dlg.lean` is the action of this monoid on
dialogues; it is `Agentic.actR`'s law at a dependent function space. -/
abbrev Sig : Type := (c : Code) → Q c → Q c

/-- The identity relabelling: `[[idSig]] = 1` in the endomorphism monoid. -/
def idSig : Sig := fun _ q => q

/-- Composition of relabellings: `[[compSig σ τ]] = [[σ]] ∘ [[τ]]`. -/
def compSig (σ τ : Sig) : Sig := fun c q => σ c (τ c q)

/-- Setting the model axis of a question's scope, as a `Sig`. The override
discipline is `LastOpt`'s and not this function's: `set_overrides` is what makes
the innermost `atModel` win.

**Derivation, and the side the new setting goes on.** The equation to satisfy is
`Agentic.withScope_compose` transported to questions — the outer scope sits on
the *left*, where the non-commutative `LastOpt` lets the inner one have the last
word. `under` composes as `under σ (under τ p) = under (compSig σ τ) p` with
`compSig σ τ = σ ∘ τ`, so in `under (atModel mOuter) (under (atModel mInner) p)`
the *outer* relabelling is the one applied *last*; it must therefore append its
setting on the **left** of what is already there, and the question's own written
scope — innermost of all, being at the leaf — stays rightmost. Solving that
equation gives the definition below.

Appending on the right instead type-checks and is exactly the error
`Agentic/Scope.lean` warns about: it would make the outermost `atModel` win. -/
def atModel (m : String) : Sig :=
  fun _ q => { q with scope := Agentic.Scope.fst m * q.scope }

/-- What `atModel` does to a scope, in the scope monoid's own terms. -/
@[simp] theorem atModel_scope (m : String) (c : Code) (q : Q c) :
    (atModel m c q).scope = Agentic.Scope.fst m * q.scope := rfl

/-- An outer model setting is absorbed by an inner one, on the nose. This is
`Agentic.LastOpt.set_overrides` at the first axis of a two-axis scope, and it is
the whole of innermost-wins; the second axis is untouched because the product
monoid cannot let the axes see each other. -/
theorem fst_mul_fst (mOuter mInner : String) :
    (Agentic.Scope.fst mOuter : QScope) * Agentic.Scope.fst mInner
      = Agentic.Scope.fst mInner := rfl

/-- **Innermost wins**, transported to questions and stated at the *composite*
relabelling, which is where the direction can actually go wrong.

`under σ (under τ p) = under (compSig σ τ) p` (`Dlg.under_under`,
`Plan.under_under`), so this equation says: writing one `atModel` outside
another — `model mOuter <| model mInner <| body` — relabels every question of
`body` exactly as the inner one alone would. Nothing about the *last-applied*
relabelling is claimed, because last-applied is outermost and outermost loses. -/
theorem compSig_atModel_atModel (mOuter mInner : String) :
    compSig (atModel mOuter) (atModel mInner) = atModel mInner := by
  funext c q
  simp only [compSig, atModel, ← mul_assoc, fst_mul_fst]

/-- Reading the axis off: at a question that names no model of its own, the
model in force under nested `atModel`s is the innermost one. The hypothesis is
not idle — a question that *does* name a model is more deeply nested than any
`under` wrapped around it, and wins over both. -/
theorem axis₁_compSig_atModel_atModel (mOuter mInner : String) (c : Code) (q : Q c)
    (h : Agentic.Scope.axis₁ q.scope = Agentic.LastOpt.unset) :
    Agentic.Scope.axis₁ ((compSig (atModel mOuter) (atModel mInner) c q).scope)
      = Agentic.LastOpt.set mInner := by
  rw [compSig_atModel_atModel, atModel_scope]
  show Agentic.LastOpt.set mInner * Agentic.Scope.axis₁ q.scope = _
  rw [h]; exact Agentic.LastOpt.unset_defers _

end Agentic.Core
