import Combinators
import Agentic.Meaning

/-! The harden-a-patch workflow: draft under a deep model, a three-reviewer panel
over a shared style guide, revise up to twice, apply behind a consent gate. See
`Tour.lean` for the checked read-outs. -/

namespace Agentic.Examples.HardenPatch
open Term

abbrev Spec := String   -- what a patch is written against
abbrev Patch := String  -- the artefact under review
abbrev Guide := String  -- the house style guide, shared by the panel

inductive Findings | approve | revise  -- a reviewer's verdict
  deriving DecidableEq, Repr

inductive PatchOp : Type → Type → Type where  -- five prompts and one tool
  | draft : PatchOp Spec Patch
  | style : PatchOp Unit Guide
  | correct : PatchOp (Guide × Patch) Findings
  | secure : PatchOp (Guide × Patch) Findings
  | simple : PatchOp Patch Findings
  | applyP : PatchOp Patch Unit

abbrev Sc := LastOpt String  -- scopes: one axis, naming the model; innermost wins
abbrev Lbl := String         -- sharing labels
abbrev Wf (f : Frag) (i o : Type) := Term PatchOp Sc Lbl f i o
def deepModel : Sc := LastOpt.set "opus-deep"
def sg : Lbl := "guide"

instance : Monoid Findings where  -- any objection carries, `approve` is the unit
  mul | .approve, v => v | .revise, _ => .revise
  one := .approve
  mul_assoc a b c := by cases a <;> cases b <;> cases c <;> rfl
  one_mul _ := rfl
  mul_one a := by cases a <;> rfl

def decodeVerdict : Patch × Findings → Sum Patch Spec  -- inl: done; inr: go again
  | (p, .approve) => Sum.inl p
  | (p, .revise) => Sum.inr p

-- Two reviewers read the guide shared under `sg`; the third is asked naively.
def review : Wf .static Patch Findings :=
  panel [guided sg .style .correct, guided sg .style .secure, ask .simple]

-- Draft under the deep model, keep the patch beside its review, decode.
def attempt : Wf .static Spec (Sum Patch Spec) :=
  under deepModel (ask .draft) >>> keep review >>> fn decodeVerdict

-- One attempt, then at most two more, then the effect behind a consent gate.
def harden (consent : Bool) : Wf .static Spec Unit :=
  loop 2 attempt >>> gate consent (ask .applyP)

-- One simplicity review per file the draft touched, at most eight.
def perFile : Wf (.bounded 8) (List Patch) (List Findings) := Term.fanT 8 (ask .simple)

example (c : Bool) : Term.grade (harden c) = .static := rfl
example (c : Bool) : Term.widthT (harden c) = some 0 := rfl
end Agentic.Examples.HardenPatch
