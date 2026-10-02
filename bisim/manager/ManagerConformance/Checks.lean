import ManagerConformance.Admission

/-!
# Closed witnesses and axiom footprints of the deciders

Each decider has at least one accepted and one refused closed witness,
evaluated by `#guard`. The accepted witnesses show that the proved equalities do not hold
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

private def profile : Profile String := ⟨"profile-revision-1", true, {"key-1"}⟩
private def otherProfile : Profile String := ⟨"profile-revision-2", true, {"key-2"}⟩
private def inputs : Readiness String := ⟨{"input-1"}, Finmap.singleton "input-1" "capture-1", ∅⟩

/-- The oldest queued request, configured with the key `key-1`. -/
private def older : Request String :=
  ⟨"request-revision-1", "profile-1", "profile-revision-1", .queued, some 0, inputs, none, none⟩

/-- A later queued request of an independent profile, configured with the key `key-2`. -/
private def later : Request String :=
  ⟨"request-revision-1", "profile-2", "profile-revision-2", .queued, some 1, inputs, none, none⟩

/-- Two queued requests, two free slots and no reservation. -/
private def queued : State :=
  ⟨"generation-1", "authority-1", {"slot-1", "slot-2"},
    (Finmap.singleton "profile-1" profile).insert "profile-2" otherProfile,
    (Finmap.singleton "request-2" older).insert "request-3" later,
    ∅, ∅, ∅, ∅, ∅, ∅, ∅, ∅⟩

/-- The same queue while `request-1` holds `slot-1` and the key `key-1`. -/
private def held : State := { queued with reservations := Finmap.singleton "request-1" lease }

-- admit: the oldest eligible request reserves its slot and keys together.
#guard (admitExec queued "request-2" older profile ⟨"slot-2", {"key-1"}⟩).map
    (fun next => ((next.requests.lookup "request-2").map (·.phase),
      next.reservations.lookup "request-2")) =
  some (some .preparing, some ⟨"slot-2", {"key-1"}⟩)
-- admit: a later request is refused while an older request is eligible.
#guard (admitExec queued "request-3" later otherProfile ⟨"slot-2", {"key-2"}⟩).isNone
-- admit: a lease whose key overlaps a held reservation is refused.
#guard (admitExec held "request-2" older profile ⟨"slot-2", {"key-1"}⟩).isNone
-- admit: a lease whose slot overlaps a held reservation is refused.
#guard (admitExec held "request-3" later otherProfile ⟨"slot-1", {"key-2"}⟩).isNone
-- admit: a request of an independent profile admits past the older request that the
-- held key blocks.
#guard (admitExec held "request-3" later otherProfile ⟨"slot-2", {"key-2"}⟩).map
    (·.reservations.lookup "request-3") =
  some (some ⟨"slot-2", {"key-2"}⟩)

/-- An exact live preparation of `request-1` in the review phase. -/
private def prepared : Prepared String String :=
  ⟨"request-1", "request-revision-1", "profile-1", "profile-revision-1", "run-1", "native-1",
    "worker-1", "generation-1", "authority-1", "preparation-revision-1", "digest-1",
    "exact review", .live⟩

private def reviewed : Request String :=
  { older with phase := .review, preparation := some "preparation-1" }

/-- The request `request-1` in review, with its reservation, preparation and run. -/
private def review : State :=
  { queued with
    requests := Finmap.singleton "request-1" reviewed
    reservations := Finmap.singleton "request-1" lease
    preparations := Finmap.singleton "preparation-1" prepared
    runs := Finmap.singleton "run-1" "request-1"
    supervision := Finmap.singleton "run-1" .owned }

/-- Evidence that the preparation is live and unexpired. -/
private def liveTable : EvidenceTable :=
  { EvidenceTable.empty with live := [prepared], unexpired := [prepared] }

-- approve: an exact live preparation is consumed and records an undelivered start intent.
#guard (approveExec review liveTable "command-1" "client-1" "preparation-1"
    "preparation-revision-1" "digest-1" prepared reviewed profile).map
    (fun next => ((next.preparations.lookup "preparation-1").map (·.phase),
      (next.requests.lookup "request-1").map (fun r => (r.phase, r.run)),
      next.commands.lookup "command-1")) =
  some (some .consumed, some (.startPending, some "run-1"),
    some ⟨"client-1", .start prepared, .notAttempted, [], none⟩)
-- approve: a changed process generation is refused with every other binding intact.
#guard (approveExec { review with generation := "generation-2" } liveTable "command-1"
    "client-1" "preparation-1" "preparation-revision-1" "digest-1" prepared reviewed
    profile).isNone
-- approve: the same preparation without live evidence is refused.
#guard (approveExec review .empty "command-1" "client-1" "preparation-1"
    "preparation-revision-1" "digest-1" prepared reviewed profile).isNone

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

/-- info: 'ManagerConformance.eligible_iff' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms eligible_iff

/-- info: 'ManagerConformance.canAdmit_iff' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms canAdmit_iff

/-- info: 'ManagerConformance.canApprove_iff' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms canApprove_iff

/-- info: 'ManagerConformance.admitExec_eq' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms admitExec_eq

/-- info: 'ManagerConformance.approveExec_eq' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms approveExec_eq

end ManagerConformance.Checks
