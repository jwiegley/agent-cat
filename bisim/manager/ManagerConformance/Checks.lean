import ManagerConformance.Exec

/-!
# Closed witnesses and axiom footprints of the deciders

Each decider has one accepted and one refused closed witness, evaluated by
`#guard`. The accepted witnesses show that the proved equalities do not hold
only because both sides refuse. The evidence table lists the evidence of an
abstract world, and no witness below claims that a physical environment
supplies it. The axiom footprint of each equality is fixed under
`#guard_msgs`, so a new axiom breaks the build.
-/

namespace ManagerConformance.Checks

open Agentic.Manager

private def first : DecisionKey String := ⟨"decision-1", "revision-1", "occurrence-1", some "attempt-1", "generation-1"⟩
private def second : DecisionKey String := ⟨"decision-2", "revision-1", "occurrence-2", some "attempt-1", "generation-1"⟩
private def third : DecisionKey String := ⟨"decision-3", "revision-1", "occurrence-3", none, "generation-1"⟩
private def lease : Reservation String := ⟨"slot-1", {"key-1"}⟩

/-- An owned run with two pending decisions and one reservation. -/
private def pending : State :=
  ⟨"generation-1", "authority-1", {"slot-1"}, ∅, ∅, Finmap.singleton "request-1" lease, ∅,
    Finmap.singleton "run-1" "request-1", Finmap.singleton "run-1" .owned,
    Finmap.singleton "run-1" [⟨first, none⟩, ⟨second, none⟩], ∅, ∅, ∅⟩

/-- The same run after the command `command-1` reserved the head decision. -/
private def reserved : State :=
  { pending with decisions := Finmap.singleton "run-1" [⟨first, some "command-1"⟩, ⟨second, none⟩] }

/-- Evidence of one cleanup, one opened decision, one resolution and one verification. -/
private def table : EvidenceTable :=
  { EvidenceTable.empty with
    cleaned := [("request-1", lease)]
    opened := [("run-1", third), ("run-1", { first with occurrence := "occurrence-9" })]
    resolutions := [("run-1", first, "command-1", .resolved)]
    verified := [("reference-1", "output")] }

-- openDecision: an opened decision with a new identity appends after the whole FIFO.
#guard (openDecisionExec pending table "run-1" third).map (·.decisions.lookup "run-1") =
  some (some [⟨first, none⟩, ⟨second, none⟩, ⟨third, none⟩])
-- openDecision: the same decision without opened evidence is refused.
#guard (openDecisionExec pending .empty "run-1" third).isNone
-- openDecision: opened evidence for an identity already pending is refused.
#guard (openDecisionExec pending table "run-1" { first with occurrence := "occurrence-9" }).isNone

-- answer: the unreserved head of an owned run is reserved by the new command.
#guard (answerExec pending "command-1" "client-1" "run-1" first "yes").map
    (·.decisions.lookup "run-1") =
  some (some [⟨first, some "command-1"⟩, ⟨second, none⟩])
-- answer: a decision behind the head is refused.
#guard (answerExec pending "command-1" "client-1" "run-1" second "yes").isNone
-- answer: a reserved head refuses a second answer.
#guard (answerExec reserved "command-2" "client-2" "run-1" first "no").isNone

-- resolve: correlated resolution removes the reserved head and keeps the suffix.
#guard (resolveExec reserved table "run-1" "command-1" first .resolved).map
    (·.decisions.lookup "run-1") =
  some (some [⟨second, none⟩])
-- resolve: a non-effect claim that the table does not list is refused.
#guard (resolveExec reserved table "run-1" "command-1" first .notEffective).isNone

-- release: confirmed cleanup removes exactly that owner's reservation.
#guard (releaseExec pending table "request-1").map (·.reservations.lookup "request-1") =
  some none
-- release: missing cleanup evidence retains the reservation by refusing.
#guard (releaseExec pending .empty "request-1").isNone

-- verify: verification evidence records the exact referenced value.
#guard (verifyExec pending table "artifact-1" "reference-1" "output").map
    (·.artifacts.lookup "artifact-1") =
  some (some (.verified "reference-1" "output"))
-- verify: a value that the table does not verify is refused.
#guard (verifyExec pending table "artifact-1" "reference-1" "other").isNone

/-- info: 'ManagerConformance.openDecisionExec_eq' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms openDecisionExec_eq

/-- info: 'ManagerConformance.answerExec_eq' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms answerExec_eq

/-- info: 'ManagerConformance.resolveExec_eq' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms resolveExec_eq

/-- info: 'ManagerConformance.releaseExec_eq' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms releaseExec_eq

/-- info: 'ManagerConformance.verifyExec_eq' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms verifyExec_eq

end ManagerConformance.Checks
