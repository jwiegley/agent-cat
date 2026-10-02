import Agentic.Manager.Meaning

/-!
# Executable deciders of the coordination transitions

The model states the transitions `openDecision`, `answer`, `resolve`,
`release` and `verify` as noncomputable definitions, because their guards are
propositions over abstract evidence. This module instantiates the model at
`I := String` and `V := String`. It replaces the abstract evidence with a
finite table, so that each guard becomes a decidable proposition.

`EvidenceTable` lists the evidence that the environment supplies: live and
unexpired preparations, cleaned owner and reservation pairs, opened run and
decision-key pairs, resolution tuples, and verified reference and value pairs.
`EvidenceTable.toEvidence` interprets the table as model evidence, in which a
fact holds exactly when the table lists it.

Each decider `*Exec` is a computable function with the same update as its
model transition. Each theorem `*Exec_eq` proves that the decider equals the
model transition at the evidence of its table. `Coordination.delivery` is
already computable, so a caller uses it directly.

The module imports `Agentic.Manager.Meaning`, and through it the history
meaning and the coordination model, so a decider and its transition share one
closure. The table is a parameter. No definition below claims that a physical worker,
clock, filesystem or transport supplies the evidence that the table lists.
-/

namespace ManagerConformance

open Agentic.Manager

-- Membership in the evidence table needs decidable equality of prepared reviews
-- and reservations. The witnesses compare decided FIFO queues and verified
-- artifacts, which needs decidable equality of pending decisions and artifacts.
-- The model derives none of the four.
deriving instance DecidableEq for Prepared
deriving instance DecidableEq for Reservation
deriving instance DecidableEq for Decision
deriving instance DecidableEq for Artifact

/-- The coordination model at string identities and string values. -/
abbrev State := Coordination String String

/-- A finite record of the evidence that the environment supplies. -/
structure EvidenceTable where
  live : List (Prepared String String)
  unexpired : List (Prepared String String)
  cleaned : List (String × Reservation String)
  opened : List (String × DecisionKey String)
  resolutions : List (String × DecisionKey String × String × Resolution)
  verified : List (String × String)

/-- The table with no evidence. Every evidence-guarded transition refuses under it. -/
def EvidenceTable.empty : EvidenceTable := ⟨[], [], [], [], [], []⟩

/-- A fact of the model evidence holds exactly when the table lists it. -/
def EvidenceTable.toEvidence (t : EvidenceTable) : Evidence String String where
  live p := p ∈ t.live
  unexpired p := p ∈ t.unexpired
  cleaned owner lease := (owner, lease) ∈ t.cleaned
  opened run key := (run, key) ∈ t.opened
  resolution run key command resolution := (run, key, command, resolution) ∈ t.resolutions
  verifies reference value := (reference, value) ∈ t.verified

instance (t : EvidenceTable) (p : Prepared String String) :
    Decidable (t.toEvidence.live p) :=
  inferInstanceAs (Decidable (p ∈ t.live))

instance (t : EvidenceTable) (p : Prepared String String) :
    Decidable (t.toEvidence.unexpired p) :=
  inferInstanceAs (Decidable (p ∈ t.unexpired))

instance (t : EvidenceTable) (owner : String) (lease : Reservation String) :
    Decidable (t.toEvidence.cleaned owner lease) :=
  inferInstanceAs (Decidable ((owner, lease) ∈ t.cleaned))

instance (t : EvidenceTable) (run : String) (key : DecisionKey String) :
    Decidable (t.toEvidence.opened run key) :=
  inferInstanceAs (Decidable ((run, key) ∈ t.opened))

instance (t : EvidenceTable) (run : String) (key : DecisionKey String) (command : String)
    (resolution : Resolution) :
    Decidable (t.toEvidence.resolution run key command resolution) :=
  inferInstanceAs (Decidable ((run, key, command, resolution) ∈ t.resolutions))

instance (t : EvidenceTable) (reference value : String) :
    Decidable (t.toEvidence.verifies reference value) :=
  inferInstanceAs (Decidable ((reference, value) ∈ t.verified))

/-- The decider of `Coordination.openDecision`. -/
def openDecisionExec (s : State) (t : EvidenceTable) (run : String) (key : DecisionKey String) :
    Option State :=
  let pending := (s.decisions.lookup run).getD []
  if t.toEvidence.opened run key ∧ ∀ old ∈ pending, old.key.id ≠ key.id then
    some { s with decisions := s.decisions.insert run (pending ++ [⟨key, none⟩]) }
  else none

/-- The decider of `Coordination.answer`. The model guard uses no evidence. -/
def answerExec (s : State) (command client run : String) (key : DecisionKey String)
    (value : String) : Option State :=
  match s.decisions.lookup run with
  | some (head :: tail) =>
    if head.key = key ∧ head.command = none ∧ s.commands.lookup command = none ∧
        s.supervision.lookup run = some .owned then
      some { s with
        decisions := s.decisions.insert run ({ head with command := some command } :: tail)
        commands := s.commands.insert command ⟨client, .answer run key value, .notAttempted, [], none⟩ }
    else none
  | _ => none

/-- The decider of `Coordination.resolve`. -/
def resolveExec (s : State) (t : EvidenceTable) (run command : String) (key : DecisionKey String)
    (resolution : Resolution) : Option State :=
  match s.decisions.lookup run with
  | some (head :: tail) =>
    if head.key = key ∧ head.command = some command ∧
        t.toEvidence.resolution run key command resolution then
      some { s with decisions := s.decisions.insert run (match resolution with
        | .resolved => tail
        | .notEffective => { head with command := none } :: tail) }
    else none
  | _ => none

/-- The decider of `Coordination.release`. -/
def releaseExec (s : State) (t : EvidenceTable) (owner : String) : Option State :=
  match s.reservations.lookup owner with
  | none => none
  | some lease => if t.toEvidence.cleaned owner lease then
      some { s with reservations := s.reservations.erase owner }
    else none

/-- The decider of `Coordination.verify`. -/
def verifyExec (s : State) (t : EvidenceTable) (artifact reference value : String) :
    Option State :=
  if t.toEvidence.verifies reference value then
    some { s with artifacts := s.artifacts.insert artifact (.verified reference value) }
  else none

/-- Two `if` expressions over one proposition agree whatever their decision procedures. -/
theorem ite_decidable {α : Type} {p : Prop} (d₁ d₂ : Decidable p) (a b : α) :
    @ite α p d₁ a b = @ite α p d₂ a b := by
  cases Subsingleton.elim d₁ d₂
  rfl

/-- The `openDecision` decider equals the model transition at the evidence of its table. -/
theorem openDecisionExec_eq (s : State) (t : EvidenceTable) (run : String)
    (key : DecisionKey String) :
    openDecisionExec s t run key = s.openDecision t.toEvidence run key := by
  unfold openDecisionExec Coordination.openDecision
  exact ite_decidable _ _ _ _

/-- The `answer` decider equals the model transition. -/
theorem answerExec_eq (s : State) (command client run : String) (key : DecisionKey String)
    (value : String) :
    answerExec s command client run key value = s.answer command client run key value := by
  unfold answerExec Coordination.answer
  rcases s.decisions.lookup run with _ | _ | ⟨head, tail⟩
  · rfl
  · rfl
  · exact ite_decidable _ _ _ _

/-- The `resolve` decider equals the model transition at the evidence of its table. -/
theorem resolveExec_eq (s : State) (t : EvidenceTable) (run command : String)
    (key : DecisionKey String) (resolution : Resolution) :
    resolveExec s t run command key resolution =
      s.resolve t.toEvidence run command key resolution := by
  unfold resolveExec Coordination.resolve
  rcases s.decisions.lookup run with _ | _ | ⟨head, tail⟩
  · rfl
  · rfl
  · exact ite_decidable _ _ _ _

/-- The `release` decider equals the model transition at the evidence of its table. -/
theorem releaseExec_eq (s : State) (t : EvidenceTable) (owner : String) :
    releaseExec s t owner = s.release t.toEvidence owner := by
  unfold releaseExec Coordination.release
  rcases s.reservations.lookup owner with _ | lease
  · rfl
  · exact ite_decidable _ _ _ _

/-- The `verify` decider equals the model transition at the evidence of its table. -/
theorem verifyExec_eq (s : State) (t : EvidenceTable) (artifact reference value : String) :
    verifyExec s t artifact reference value = s.verify t.toEvidence artifact reference value := by
  unfold verifyExec Coordination.verify
  exact ite_decidable _ _ _ _

end ManagerConformance
