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

* **…and it factors, once and for all, into shape and words.**
  `Q c ≅ Q.Shape c × String` (`Q.withPrompt_shape`, `Q.shape_withPrompt`,
  `Q.prompt_withPrompt`), with the shape carrying addressee, scope and draw.
  The factorization is not bookkeeping: `Plan`'s `ask` node writes the *shape*
  in the term and computes only the *words* from an earlier answer, which is
  what makes "the sequence of question shapes is fixed by the term" a
  projection of the syntax rather than a side condition on it. Relabellings
  (`Sig`) act on shapes for the same reason.

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
  /-- A tool whose answer the *runner* obtains by running a program-authored
  command, so that a check can be an exit code rather than a model's claim about
  one (D5).

  **The argv rides in the addressee**, and that is the decision the whole design
  turns on: `Q.Shape` is the addressee, the scope and the draw, so a command in
  the addressee is in the question, in its `EventKey` and in its trace event for
  free — and two acts saying the same words to the same tool id with *different*
  commands are two questions rather than one, which is what keeps a gate run
  twice from being answered from the memo table without running. `cmd` is
  separate from `args`, so "an argv naming no command" is unrepresentable and no
  term-level guard is owed. Both are `String`s and never a `Prompt`: there is no
  interpolation syntax at an argv, so there is no path from any answer to any
  command line, which is why no capability lattice is needed here. -/
  | toolExec (id : String) (cmd : String) (args : List String)
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

/-- The default verdict is approval — `default = 1`, which `default_eq_approve`
below states and proves.

**Written as `Option.some []` rather than as `1`, and that spelling is the whole
point.** `1 : Verdict` is Mathlib's, and Mathlib's `One (WithZero (FreeMonoid α))`
carries `Classical.choice` in its dependency graph. This instance is what
`Agentic.Core.worldOf` defaults with, so it is reached by
`Agentic.Core.certify_sound`, whose axiom set is a claim the package makes
(`Agentic/Core/Certify.lean`). Spelling the same element without the algebra
keeps that claim empty; `default_eq_approve` is `rfl`, so nothing is lost but
the axioms. -/
instance instInhabited : Inhabited Verdict :=
  ⟨(Option.some ([] : List Objection) : Verdict)⟩

/-- Nothing was objected to. `[[approve]] = 1`. -/
def approve : Verdict := 1

/-- …and the `Inhabited` default is that: an addressee who says nothing has
objected to nothing. `rfl`, so the two spellings are one element and the
axiom-free one may be used wherever the algebraic one is meant. -/
@[simp] theorem default_eq_approve : (default : Verdict) = approve := rfl

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

/-- **…and the morphism, folded.** A product of verdicts approves exactly when
every factor does: `approved_mul` iterated. This is what makes "everyone
approved" a `foldMap` into conjunction, and — because conjunction *is*
commutative where the verdict monoid is not — it is the whole of the licence a
scheduler gets to reorder a panel (`approved_panel_perm`). -/
theorem approved_prod (vs : List Verdict) : Approved vs.prod ↔ ∀ v ∈ vs, Approved v := by
  induction vs with
  | nil => simp [Approved, approve]
  | cons v vs ih => simp only [List.prod_cons, approved_mul, ih, List.mem_cons,
      forall_eq_or_imp]

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

/-! ## The shape of a question: everything except the words -/

/-- `[[Q.Shape c]]` = everything that determines a code-`c` question **except
what is said in it**: the addressee, the standing conditions and the draw index.

The finite quotient of question space that per-call and per-latency pricing
factor through (`attack-adequacy` §7). It is a *type of its own* rather than a
predicate on questions because it is what the `ask` node of
`Agentic/Core/Plan.lean` writes down: an author names the addressee, the scope
and the draw in the term, and only the words are computed from an earlier
answer. That split is why "the sequence of question shapes is fixed by the term"
is a structural fact at `pipeline` and not a hypothesis.

Per-token pricing does not factor through this; for it the honest output is an
interval keyed to a token bound carried in the answer type (kernel §2.5). -/
structure Q.Shape (c : Code) where
  /-- Who is being asked. -/
  addressee : Addressee
  /-- The standing conditions under which they are asked (§3 q3). -/
  scope : QScope
  /-- Which independent draw this is; `0` unless deliberately resampling. -/
  draw : Nat
  deriving DecidableEq

/-- `[[q.shape]]` = the question with its words forgotten. A projection, and
`Q` is its total space: `Q c ≅ Q.Shape c × String`, witnessed by the three
`rfl`s below. -/
def Q.shape {c : Code} (q : Q c) : Q.Shape c := ⟨q.addressee, q.scope, q.draw⟩

/-- `[[s.withPrompt t]]` = the question of shape `s` whose words are `t`. -/
def Q.Shape.withPrompt {c : Code} (s : Q.Shape c) (prompt : String) : Q c :=
  ⟨s.addressee, s.scope, prompt, s.draw⟩

/-- **Morphism equation, first half.** Saying `t` in the shape `s` has shape
`s`: the words do not touch the shape. This is the equation that makes the
kernel's C2 structural. -/
@[simp] theorem Q.shape_withPrompt {c : Code} (s : Q.Shape c) (t : String) :
    (s.withPrompt t).shape = s := rfl

/-- **Morphism equation, second half.** …and the words said are the words
given. -/
@[simp] theorem Q.prompt_withPrompt {c : Code} (s : Q.Shape c) (t : String) :
    (s.withPrompt t).prompt = t := rfl

/-- …and the two halves are jointly exhaustive: a question is its shape and its
words, on the nose. `rfl` by structure eta, which is what makes `askC c q k` and
`ask c q.shape (const q.prompt) k` the same term's worth of data (C0). -/
@[simp] theorem Q.withPrompt_shape {c : Code} (q : Q c) : q.shape.withPrompt q.prompt = q := rfl

/-- **Morphism equation.** `shape` forgets the prompt and *only* the prompt: two
questions with one shape and one prompt are the same question. -/
theorem Q.eq_of_shape_of_prompt {c : Code} {q q' : Q c}
    (hs : q.shape = q'.shape) (hp : q.prompt = q'.prompt) : q = q' := by
  rw [← Q.withPrompt_shape q, ← Q.withPrompt_shape q', hs, hp]

@[simp] theorem Q.addressee_withPrompt {c : Code} (s : Q.Shape c) (t : String) :
    (s.withPrompt t).addressee = s.addressee := rfl

@[simp] theorem Q.scope_withPrompt {c : Code} (s : Q.Shape c) (t : String) :
    (s.withPrompt t).scope = s.scope := rfl

@[simp] theorem Q.draw_withPrompt {c : Code} (s : Q.Shape c) (t : String) :
    (s.withPrompt t).draw = s.draw := rfl

@[simp] theorem Q.shape_addressee {c : Code} (q : Q c) : q.shape.addressee = q.addressee := rfl

@[simp] theorem Q.shape_scope {c : Code} (q : Q c) : q.shape.scope = q.scope := rfl

@[simp] theorem Q.shape_draw {c : Code} (q : Q c) : q.shape.draw = q.draw := rfl

/-! ## Relabellings -/

/-- `[[Sig]]` = a relabelling of question **shapes**, one per code. The scope
operator `under σ` of `Agentic/Core/Dlg.lean` is the action of this monoid on
dialogues; it is `Agentic.actR`'s law at a dependent function space.

Shapes and not questions, and that is the meaning rather than a restriction: a
standing condition is a fact about *whom* one asks and *under what*, never about
what one says. Pinning it here is what lets `Plan.under` be a fold on a syntax
whose `ask` nodes carry their shape — a relabelling that could rewrite the words
as a function of the words could turn a term-level shape into a computed one,
and then no analysis could read the shape off the term. -/
abbrev Sig : Type := (c : Code) → Q.Shape c → Q.Shape c

/-- `[[σ.onQ c q]]` = the relabelling's action on a whole question: relabel the
shape, keep the words. This is the unique extension of `σ` along the
isomorphism `Q c ≅ Q.Shape c × String`. -/
def Sig.onQ (σ : Sig) (c : Code) (q : Q c) : Q c := (σ c q.shape).withPrompt q.prompt

@[simp] theorem Sig.onQ_withPrompt (σ : Sig) (c : Code) (s : Q.Shape c) (t : String) :
    σ.onQ c (s.withPrompt t) = (σ c s).withPrompt t := rfl

@[simp] theorem Sig.shape_onQ (σ : Sig) (c : Code) (q : Q c) :
    (σ.onQ c q).shape = σ c q.shape := rfl

@[simp] theorem Sig.prompt_onQ (σ : Sig) (c : Code) (q : Q c) :
    (σ.onQ c q).prompt = q.prompt := rfl

/-- **What the shape-level restriction costs, in code.** Relabellings of *whole*
questions are strictly more numerous, and the extra ones are exactly the ones a
scope operator must not be: this exhibits a `τ : (c : Code) → Q c → Q c` that
makes the relabelled question's **addressee** a function of the original's
**words**, and shows it is `σ.onQ` for no `σ`.

Recorded here because the restriction is a decision. `Plan.under σ` must send an
`ask` node to an `ask` node, and an `ask` node's shape is term-level data while
its words are computed from an answer; a `τ` like this one would turn a written
shape into a computed one, and the shape sequence would stop being a projection
of the syntax (`Agentic/Core/Cost.lean`, C2). The narrowing is therefore the
meaning: a standing condition is a fact about whom one asks and under what, and
something that reads the words to decide whom to ask is a *different question*,
not a scope. -/
theorem exists_relabel_not_onQ :
    ∃ τ : (c : Code) → Q c → Q c, ∀ σ : Sig, ∃ (c : Code) (q : Q c), τ c q ≠ σ.onQ c q := by
  refine ⟨fun _ q =>
    { q with addressee := .tool (if q.prompt = "" then "a" else "b") }, fun σ => ?_⟩
  by_contra hcon
  push Not at hcon
  have h1 := congrArg Q.addressee (hcon .ack ⟨.tool "x", 1, "", 0⟩)
  have h2 := congrArg Q.addressee (hcon .ack ⟨.tool "x", 1, "z", 0⟩)
  simp only [Sig.onQ, Q.addressee_withPrompt, Q.shape, if_pos,
    reduceIte, String.reduceEq] at h1 h2
  exact absurd (h1.trans h2.symm) (by simp)

/-- The identity relabelling: `[[idSig]] = 1` in the endomorphism monoid. -/
def idSig : Sig := fun _ s => s

@[simp] theorem idSig_onQ (c : Code) (q : Q c) : idSig.onQ c q = q := rfl

/-- Composition of relabellings: `[[compSig σ τ]] = [[σ]] ∘ [[τ]]`. -/
def compSig (σ τ : Sig) : Sig := fun c s => σ c (τ c s)

@[simp] theorem compSig_onQ (σ τ : Sig) (c : Code) (q : Q c) :
    (compSig σ τ).onQ c q = σ.onQ c (τ.onQ c q) := rfl

/-- Setting the model axis of a shape's scope, as a `Sig`. The override
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
  fun _ s => { s with scope := Agentic.Scope.fst m * s.scope }

/-- What `atModel` does to a scope, in the scope monoid's own terms. -/
@[simp] theorem atModel_scope (m : String) (c : Code) (s : Q.Shape c) :
    (atModel m c s).scope = Agentic.Scope.fst m * s.scope := rfl

/-- …and at a whole question, which is where a transcript reads it. -/
@[simp] theorem atModel_onQ_scope (m : String) (c : Code) (q : Q c) :
    ((atModel m).onQ c q).scope = Agentic.Scope.fst m * q.scope := rfl

/-- A relabelling never touches the addressee unless it says so: `atModel`
does not. -/
@[simp] theorem atModel_onQ_addressee (m : String) (c : Code) (q : Q c) :
    ((atModel m).onQ c q).addressee = q.addressee := rfl

/-- Nor the words. -/
@[simp] theorem atModel_onQ_prompt (m : String) (c : Code) (q : Q c) :
    ((atModel m).onQ c q).prompt = q.prompt := rfl

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
  funext c s
  simp only [compSig, atModel, ← mul_assoc, fst_mul_fst]

/-- Reading the axis off: at a question that names no model of its own, the
model in force under nested `atModel`s is the innermost one. The hypothesis is
not idle — a question that *does* name a model is more deeply nested than any
`under` wrapped around it, and wins over both. -/
theorem axis₁_compSig_atModel_atModel (mOuter mInner : String) (c : Code) (q : Q c)
    (h : Agentic.Scope.axis₁ q.scope = Agentic.LastOpt.unset) :
    Agentic.Scope.axis₁ (((compSig (atModel mOuter) (atModel mInner)).onQ c q).scope)
      = Agentic.LastOpt.set mInner := by
  rw [compSig_atModel_atModel, atModel_onQ_scope]
  show Agentic.LastOpt.set mInner * Agentic.Scope.axis₁ q.scope = _
  rw [h]; exact Agentic.LastOpt.unset_defers _

end Agentic.Core
