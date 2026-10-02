import ManagerConformance.Admission

/-!
# Closed witness states of the deciders

This module defines the closed states, records and evidence tables that
`ManagerConformance.Checks` evaluates and that `ManagerConformance.Cases`
encodes as retained oracle cases. The definitions are public so that the
codec round trips, the decider checks and the retained cases use the same
values.

The evidence tables list the evidence of an abstract world. No definition
below claims that a physical environment supplies it.
-/

namespace ManagerConformance.Witnesses

open Agentic.Manager

/-! ## Witnesses of the evidence-guarded deciders -/

def first : DecisionKey String := ⟨"decision-1", "revision-1", "occurrence-1", some "attempt-1", "generation-1"⟩
def second : DecisionKey String := ⟨"decision-2", "revision-1", "occurrence-2", some "attempt-1", "generation-1"⟩
def third : DecisionKey String := ⟨"decision-3", "revision-1", "occurrence-3", none, "generation-1"⟩
def lease : Reservation String := ⟨"slot-1", {"key-1"}⟩

/-- An owned run with two pending decisions and one reservation. -/
def pending : State :=
  ⟨"generation-1", "authority-1", {"slot-1"}, ∅, ∅, Finmap.singleton "request-1" lease, ∅,
    Finmap.singleton "run-1" "request-1", Finmap.singleton "run-1" .owned,
    Finmap.singleton "run-1" [⟨first, none⟩, ⟨second, none⟩], ∅, ∅, ∅⟩

/-- The same run after the command `command-1` reserved the head decision. -/
def reserved : State :=
  { pending with decisions := Finmap.singleton "run-1" [⟨first, some "command-1"⟩, ⟨second, none⟩] }

/-- A key with the identity of `first` and another occurrence. -/
def reopened : DecisionKey String := { first with occurrence := "occurrence-9" }

/-- Evidence of one cleanup, one opened decision, one resolution and one verification. -/
def table : EvidenceTable :=
  { EvidenceTable.empty with
    cleaned := [("request-1", lease)]
    opened := [("run-1", third), ("run-1", reopened)]
    resolutions := [("run-1", first, "command-1", .resolved)]
    verified := [("reference-1", "output")] }

/-! ## Witnesses of admission and approval -/

def profile : Profile String := ⟨"profile-revision-1", true, {"key-1"}⟩
def otherProfile : Profile String := ⟨"profile-revision-2", true, {"key-2"}⟩
def inputs : Readiness String := ⟨{"input-1"}, Finmap.singleton "input-1" "capture-1", ∅⟩

/-- The oldest queued request, configured with the key `key-1`. -/
def older : Request String :=
  ⟨"request-revision-1", "profile-1", "profile-revision-1", .queued, some 0, inputs, none, none⟩

/-- A later queued request of an independent profile, configured with the key `key-2`. -/
def later : Request String :=
  ⟨"request-revision-1", "profile-2", "profile-revision-2", .queued, some 1, inputs, none, none⟩

/-- Two queued requests, two free slots and no reservation. -/
def queued : State :=
  ⟨"generation-1", "authority-1", {"slot-1", "slot-2"},
    (Finmap.singleton "profile-1" profile).insert "profile-2" otherProfile,
    (Finmap.singleton "request-2" older).insert "request-3" later,
    ∅, ∅, ∅, ∅, ∅, ∅, ∅, ∅⟩

/-- The same queue while `request-1` holds `slot-1` and the key `key-1`. -/
def held : State := { queued with reservations := Finmap.singleton "request-1" lease }

/-- An exact live preparation of `request-1` in the review phase. -/
def prepared : Prepared String String :=
  ⟨"request-1", "request-revision-1", "profile-1", "profile-revision-1", "run-1", "native-1",
    "worker-1", "generation-1", "authority-1", "preparation-revision-1", "digest-1",
    "exact review", .live⟩

def reviewed : Request String :=
  { older with phase := .review, preparation := some "preparation-1" }

/-- The request `request-1` in review, with its reservation, preparation and run. -/
def review : State :=
  { queued with
    requests := Finmap.singleton "request-1" reviewed
    reservations := Finmap.singleton "request-1" lease
    preparations := Finmap.singleton "preparation-1" prepared
    runs := Finmap.singleton "run-1" "request-1"
    supervision := Finmap.singleton "run-1" .owned }

/-- Evidence that the preparation is live and unexpired. -/
def liveTable : EvidenceTable :=
  { EvidenceTable.empty with live := [prepared], unexpired := [prepared] }

end ManagerConformance.Witnesses
