import Agentic.Term
import Agentic.Scope

/-!
# The authoring surface: the words a workflow is written in

This module is the **author-facing surface**: the five words (`ask`,
`askHuman`, `model`, `panel`, `revising`) plus a `Monad` instance, which is all
a workflow file needs to import. A workflow is written here; it is not written
in `Agentic.Term`'s constructors, any more than a program is written in a parse
tree.

**The signature is the contract; the internals are scaffolding.** Everything
below the `def` lines — the `.monadic` grade, `toMonadic`, the `parT` plumbing
that pairs two `PUnit` inputs so a panel's branches are structurally side by
side — is an encoding into the *current* `Term` calculus,
and that calculus is condemned by the re-derivation (dossier
`rederivation-kernel.md`; obr `acat-o8s`). What is stable is the shape of the
words: `ask : String → W α`, `panel : List (W o) → W o` at a `Monoid o`,
`revising : Nat → σ → (σ → W (σ × Verdict)) → W σ`. When the carrier is
re-pointed at the Plan, these signatures survive and the bodies do not.

**Sharing is variable binding here, and that is deliberate.** `Term.shareT` and
the label parameter `L` go unused: in the authoring surface an answer is asked
once and read as many times as its `let`-bound name occurs, so "ask once, read
twice" is `let guide ← ask …` followed by two uses of `guide`, not a label. The
labelled form remains in the syntax stratum for terms that are *built* rather
than *written*.
-/

namespace Agentic

/-- Who a question is put to: a model, or the human at the keyboard. The
distinction is semantic — a human's answer is a consent, not a sample. -/
inductive Addressee
  | model
  | human
  deriving DecidableEq, Repr

/-- A question, addressed: *this text, put to this addressee, answered by an
`α`*. The text is already fully formed — interpolation happens in Lean, before
the question exists — so a `Query` carries no unfilled holes. -/
structure Query (α : Type) where
  /-- The question as it will be asked, verbatim. -/
  text : String
  /-- Whom it is asked of. -/
  addressee : Addressee

/-- The leaf signature of this surface: every consultation is a `Query`, and
its input is discarded, because a question is composed before it is put. -/
abbrev PromptSig : Type → Type → Type := fun _ α => Query α

/-- A **workflow answering an `α`**: a written term over addressed questions,
scoped by a model name (one `Last` axis, so the innermost `model` wins),
starting from no input. Its grade is `.monadic` because an answer is allowed to
choose what is asked next. -/
abbrev W (α : Type) : Type 1 :=
  Term PromptSig (LastOpt String) String .monadic PUnit α

variable {α β o σ : Type}

/-- Sequencing a workflow after an answer: `x >>= k` asks `x`, then asks
whatever `k` makes of the answer. `pure a` asks nothing and answers `a`.

Plain `Monad`, operations only. **Lawfulness here is semantic**, not
syntactic: the laws hold of the *meanings* (`Agentic.Meaning`) of these terms,
not of the terms themselves — `pure a >>= k` is a different tree from `k a`
while denoting the same thing — so no `LawfulMonad` instance is attempted or
wanted. -/
instance : Monad W where
  pure a := Term.toMonadic (.pureT (fun _ => a))
  bind x k := Term.bindT x k

/-- **Ask a model.** `ask s` puts the question `s` to whichever model the
enclosing `model` scope names, and answers with what comes back. Each written
occurrence is its own consultation: asking twice asks twice. -/
def ask (s : String) : W α :=
  Term.toMonadic (.prim ⟨s, .model⟩)

/-- **Ask the human.** `askHuman s` puts the question to the person the
workflow is running for; at `α = Bool` it is a consent, and a workflow that
proceeds without it has not been consented to. -/
def askHuman (s : String) : W α :=
  Term.toMonadic (.prim ⟨s, .human⟩)

/-- **Address a sub-workflow to a named model.** `model name w` runs all of
`w`'s questions against `name`, and an inner `model` overrides an outer one —
innermost wins, because the scope axis is `LastOpt`'s `Last` monoid. -/
def model (name : String) (w : W α) : W α :=
  Term.scopeT (LastOpt.set name) w

/-- **Two workflows in flight at once**, answering the pair of their answers:
the empty input is copied to both, and neither branch can read the other. This
is the panel's spine, not one of the surface's words — `panel` is what a
designer writes.

(The `.monadic` grade is pinned by the return type rather than by a
`castGrade`, so the grades stored in the tree stay the literals `⊤` and `⊤ + ⊤`
and the term still compiles: `⊤ ⊔ f = ⊤` holds by `rfl`.) -/
def parPair (a : W α) (b : W β) : W (α × β) :=
  Term.seqT
    (Term.toMonadic (Term.pureT (fun _ : PUnit => (PUnit.unit, PUnit.unit))))
    (Term.parT a b)

/-- **A panel of reviewers, all asked at once.** `panel ws` runs every member of
`ws` side by side on the same (empty) input and combines their answers with the
monoid on `o`; an empty panel answers `1`, having asked nobody.

The members are *structurally* parallel — the spine is `parT`, so every branch
is in flight and none reads another's answer — and the fan-in is the monoid's
`*`, applied by a `Transform`, so a panel is a fan-in and not a fold over a
queue. -/
def panel [Monoid o] : List (W o) → W o
  | [] => pure 1
  | w :: ws =>
      Term.seqT (parPair w (panel ws)) (Term.pureT (fun p => p.1 * p.2))

/-- A reviewer's answer: the work stands, or it goes back. -/
inductive Verdict
  | approve
  | revise
  deriving DecidableEq, Repr

/-- **Any objection carries.** `approve` is the unit — a panel that says
nothing against a patch approves it — and one `revise` sends it back however
many approvals sit beside it. -/
instance : Monoid Verdict where
  mul | .approve, v => v | .revise, _ => .revise
  one := .approve
  mul_assoc a b c := by cases a <;> cases b <;> cases c <;> rfl
  one_mul _ := rfl
  mul_one a := by cases a <;> rfl

/-- **Check, then revise, up to `n` times.** `revising n init step` runs `step`
on the current artefact, which answers with a new artefact and a verdict:
`approve` returns it, `revise` runs `step` again on it while budget remains,
and an exhausted budget returns the last artefact reviewed.

The artefact returned is therefore *always* one that has been reviewed —
including the one that runs out of budget, which is returned with its objection
already recorded. -/
def revising (n : Nat) (init : σ) (step : σ → W (σ × Verdict)) : W σ :=
  step init >>= fun (s, v) =>
    match v, n with
    | .approve, _ => pure s
    | .revise, 0 => pure s
    | .revise, m + 1 => revising m s step
termination_by n

end Agentic
