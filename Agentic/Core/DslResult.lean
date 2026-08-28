import Agentic.Core.Dsl

/-!
# Typed closed-program results

Small kernel-checked witnesses for the additive result terminal. `RawProgram`
remains the frozen two-field record; `checkProgramResult` supplies one expected
code to every branch and `answer` names the value returned at that code.
-/

namespace Agentic.Core.Dsl

open Agentic.Core

private def p0 : Pos := ⟨0, 0⟩

private def modelAsk (id prompt : String) : RawRhs :=
  .ask
    { model := none
      target := { addressee := .model id, draw := 0 }
      prompt := [.lit prompt]
      pos := p0 }

private def textBinding (name prompt : String) (rest : RawBlock) : RawBlock :=
  .bind name (some .text) (.rhs (modelAsk name prompt)) rest p0

/-- One text question whose answer is the whole program result. -/
def textResultProgram : RawProgram :=
  ⟨[], textBinding "answer" "Return the final greeting." (.answer "answer" p0)⟩

/-- A value program cannot end at the legacy receipt terminal. -/
def missingResultProgram : RawProgram := ⟨[], .empty p0⟩

/-- The terminal name is live, but its code differs from the program result. -/
def mismatchedResultProgram : RawProgram := textResultProgram

/-- Both arms return text, under branch-local names. -/
def branchResultProgram : RawProgram :=
  ⟨[],
    .bind "gate" (some .flag) (.rhs (modelAsk "gate" "Choose an arm."))
      (.ifFlag "gate"
        (textBinding "yes" "Return yes." (.answer "yes" p0))
        (textBinding "no" "Return no." (.answer "no" p0))
        p0)
      p0⟩

private def accepted {ε : Type} {α : Type u} (x : Except ε α) : Bool :=
  match x with
  | .ok _ => true
  | .error _ => false

set_option maxRecDepth 20000 in
example : accepted (checkProgramResult .text textResultProgram) = true := by
  decide +kernel

set_option maxRecDepth 20000 in
example : accepted (checkProgramResult .text branchResultProgram) = true := by
  decide +kernel

example : accepted (checkProgramResult .text missingResultProgram) = false := by
  decide +kernel

example : accepted (checkProgramResult .flag mismatchedResultProgram) = false := by
  decide +kernel

end Agentic.Core.Dsl
