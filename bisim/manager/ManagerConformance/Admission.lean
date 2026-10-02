import ManagerConformance.Exec

/-!
# Executable deciders of admission and approval

The model guards `Coordination.admit` by `Coordination.canAdmit` and
`Coordination.approve` by `Coordination.canApprove`. These guards quantify
over every identity, request, profile and lease, so the model states both
transitions as noncomputable definitions.

This module reduces each quantifier to finite entries of the state. The
disjointness guard of `eligible` ranges over the entries of `s.reservations`.
The queue-order guard of `canAdmit` ranges over the entries of `s.requests`,
the entries of `s.profiles` and the slots of `s.slots`, because an eligible
lease takes its slot from `s.slots` and its keys from its profile. The lease
guard of `canApprove` is the lookup of one reservation. The theorems
`eligible_iff`, `canAdmit_iff` and `canApprove_iff` prove each reduction, and
the `Decidable` instances of the three guards follow from them.

`admitExec` and `approveExec` decide the guards with these instances and make
the update of the model transition. The theorems `admitExec_eq` and
`approveExec_eq` prove that each decider equals its model transition. The
evidence of approval comes from an `EvidenceTable`, as for the deciders of
`ManagerConformance.Exec`.
-/

namespace ManagerConformance

open Agentic.Manager

-- Admission compares stored requests and profiles, and the witnesses compare
-- recorded start receipts. The model derives none of these instances.
deriving instance DecidableEq for Readiness
deriving instance DecidableEq for Request
deriving instance DecidableEq for Profile
deriving instance DecidableEq for Intent
deriving instance DecidableEq for Receipt

instance (r : Readiness String) : Decidable r.ready :=
  inferInstanceAs (Decidable (r.required ⊆ r.supplied.keys ∧ r.invalid = ∅))

/-- `Coordination.eligible` with its reservation quantifier over the finite entries of `s.reservations`. -/
def EligibleFin (s : State) (id : String) (r : Request String) (profile : Profile String)
    (lease : Reservation String) : Prop :=
  s.requests.lookup id = some r ∧ r.phase = .queued ∧ r.inputs.ready ∧
  s.profiles.lookup r.profile = some profile ∧ profile.enabled = true ∧
  r.profileRevision = profile.revision ∧ lease.slot ∈ s.slots ∧
  lease.exclusive = profile.resources ∧ s.reservations.lookup id = none ∧
  ∀ held ∈ s.reservations.entries, Disjoint lease.resources held.2.resources

instance (s : State) (id : String) (r : Request String) (profile : Profile String)
    (lease : Reservation String) : Decidable (EligibleFin s id r profile lease) := by
  unfold EligibleFin
  infer_instance

/-- `Coordination.canAdmit` with its queue-order quantifiers over finite entries of the state. -/
def CanAdmitFin (s : State) (id : String) (r : Request String) (profile : Profile String)
    (lease : Reservation String) : Prop :=
  EligibleFin s id r profile lease ∧ ∃ ordinal ∈ r.queueOrdinal.toList,
    ∀ other ∈ s.requests.entries, ∀ candidate ∈ s.profiles.entries, ∀ slot ∈ s.slots,
      EligibleFin s other.1 other.2 candidate.2 ⟨slot, candidate.2.resources⟩ →
      ∀ otherOrdinal ∈ other.2.queueOrdinal.toList, ordinal ≤ otherOrdinal

instance (s : State) (id : String) (r : Request String) (profile : Profile String)
    (lease : Reservation String) : Decidable (CanAdmitFin s id r profile lease) := by
  unfold CanAdmitFin
  infer_instance

/-- `Coordination.canApprove` under table evidence, with its lease witness as one reservation lookup. -/
def CanApproveFin (s : State) (t : EvidenceTable) (command preparation revision digest : String)
    (p : Prepared String String) (r : Request String) (profile : Profile String) : Prop :=
  s.preparations.lookup preparation = some p ∧ p.phase = .live ∧
  p.revision = revision ∧ p.digest = digest ∧
  s.requests.lookup p.request = some r ∧ r.phase = .review ∧
  r.preparation = some preparation ∧ r.revision = p.requestRevision ∧
  r.profile = p.profile ∧ r.profileRevision = p.profileRevision ∧
  s.profiles.lookup p.profile = some profile ∧ profile.revision = p.profileRevision ∧
  profile.enabled = true ∧ p.generation = s.generation ∧ p.authority = s.authority ∧
  (∃ lease ∈ (s.reservations.lookup p.request).toList,
    lease.exclusive = profile.resources ∧ lease.slot ∈ s.slots) ∧
  s.runs.lookup p.run = some p.request ∧
  s.commands.lookup command = none ∧ t.toEvidence.live p ∧ t.toEvidence.unexpired p

instance (s : State) (t : EvidenceTable) (command preparation revision digest : String)
    (p : Prepared String String) (r : Request String) (profile : Profile String) :
    Decidable (CanApproveFin s t command preparation revision digest p r profile) := by
  unfold CanApproveFin
  infer_instance

/-- The reservation quantifier of `eligible` ranges over the entries of `s.reservations`. -/
theorem held_iff (s : State) (lease : Reservation String) :
    (∀ other held, s.reservations.lookup other = some held →
      Disjoint lease.resources held.resources) ↔
    ∀ held ∈ s.reservations.entries, Disjoint lease.resources held.2.resources := by
  constructor
  · intro h held member
    exact h held.1 held.2 (Finmap.lookup_eq_some_iff.mpr member)
  · intro h other held found
    exact h ⟨other, held⟩ (Finmap.lookup_eq_some_iff.mp found)

/-- Eligibility is its finite form. -/
theorem eligible_iff (s : State) (id : String) (r : Request String) (profile : Profile String)
    (lease : Reservation String) :
    s.eligible id r profile lease ↔ EligibleFin s id r profile lease := by
  unfold Coordination.eligible EligibleFin
  rw [held_iff]

/-- Admission is its finite form. An eligible lease has a slot of `s.slots` and the keys of its profile. -/
theorem canAdmit_iff (s : State) (id : String) (r : Request String) (profile : Profile String)
    (lease : Reservation String) :
    s.canAdmit id r profile lease ↔ CanAdmitFin s id r profile lease := by
  unfold Coordination.canAdmit CanAdmitFin
  rw [eligible_iff]
  refine and_congr_right fun _ => ⟨?_, ?_⟩
  · rintro ⟨ordinal, ordered, oldest⟩
    refine ⟨ordinal, by simp [ordered], ?_⟩
    intro other _ candidate _ slot _ eligible otherOrdinal member
    exact oldest other.1 other.2 candidate.2 ⟨slot, candidate.2.resources⟩ otherOrdinal
      ((eligible_iff _ _ _ _ _).mpr eligible) (by simpa using member)
  · rintro ⟨ordinal, ordered, oldest⟩
    refine ⟨ordinal, by simpa using ordered, ?_⟩
    intro other request otherProfile otherLease otherOrdinal eligible numbered
    rcases otherLease with ⟨slot, exclusive⟩
    have finite : EligibleFin s other request otherProfile ⟨slot, exclusive⟩ :=
      (eligible_iff _ _ _ _ _).mp eligible
    unfold EligibleFin at finite
    rcases finite with ⟨stored, _, _, configured, _, _, free, keys, _, _⟩
    simp only at keys free
    subst keys
    exact oldest ⟨other, request⟩ (Finmap.lookup_eq_some_iff.mp stored)
      ⟨request.profile, otherProfile⟩ (Finmap.lookup_eq_some_iff.mp configured) slot free
      ((eligible_iff _ _ _ _ _).mp eligible) otherOrdinal (by simp [numbered])

/-- The lease witness of approval is the stored reservation of the request. -/
theorem lease_iff (s : State) (request : String) (profile : Profile String) :
    (∃ lease, s.reservations.lookup request = some lease ∧
      lease.exclusive = profile.resources ∧ lease.slot ∈ s.slots) ↔
    ∃ lease ∈ (s.reservations.lookup request).toList,
      lease.exclusive = profile.resources ∧ lease.slot ∈ s.slots := by
  constructor
  · rintro ⟨lease, found, guard⟩
    exact ⟨lease, by simp [found], guard⟩
  · rintro ⟨lease, found, guard⟩
    exact ⟨lease, by simpa using found, guard⟩

/-- Approval under table evidence is its finite form. -/
theorem canApprove_iff (s : State) (t : EvidenceTable)
    (command preparation revision digest : String) (p : Prepared String String)
    (r : Request String) (profile : Profile String) :
    s.canApprove t.toEvidence command preparation revision digest p r profile ↔
      CanApproveFin s t command preparation revision digest p r profile := by
  unfold Coordination.canApprove CanApproveFin
  rw [lease_iff]

instance (s : State) (id : String) (r : Request String) (profile : Profile String)
    (lease : Reservation String) : Decidable (s.eligible id r profile lease) :=
  decidable_of_iff _ (eligible_iff s id r profile lease).symm

instance (s : State) (id : String) (r : Request String) (profile : Profile String)
    (lease : Reservation String) : Decidable (s.canAdmit id r profile lease) :=
  decidable_of_iff _ (canAdmit_iff s id r profile lease).symm

instance (s : State) (t : EvidenceTable) (command preparation revision digest : String)
    (p : Prepared String String) (r : Request String) (profile : Profile String) :
    Decidable (s.canApprove t.toEvidence command preparation revision digest p r profile) :=
  decidable_of_iff _ (canApprove_iff s t command preparation revision digest p r profile).symm

/-- The decider of `Coordination.admit`. -/
def admitExec (s : State) (id : String) (r : Request String) (profile : Profile String)
    (lease : Reservation String) : Option State :=
  if s.canAdmit id r profile lease then
    some { s with requests := s.requests.insert id { r with phase := .preparing }
                  reservations := s.reservations.insert id lease }
  else none

/-- The decider of `Coordination.approve`. -/
def approveExec (s : State) (t : EvidenceTable)
    (command client preparation revision digest : String) (p : Prepared String String)
    (r : Request String) (profile : Profile String) : Option State :=
  if s.canApprove t.toEvidence command preparation revision digest p r profile then
    some { s with
      preparations := s.preparations.insert preparation { p with phase := .consumed }
      requests := s.requests.insert p.request { r with phase := .startPending, run := some p.run }
      commands := s.commands.insert command ⟨client, .start p, .notAttempted, [], none⟩ }
  else none

/-- The `admit` decider equals the model transition. -/
theorem admitExec_eq (s : State) (id : String) (r : Request String) (profile : Profile String)
    (lease : Reservation String) :
    admitExec s id r profile lease = s.admit id r profile lease := by
  unfold admitExec Coordination.admit
  exact ite_decidable _ _ _ _

/-- The `approve` decider equals the model transition at the evidence of its table. -/
theorem approveExec_eq (s : State) (t : EvidenceTable)
    (command client preparation revision digest : String) (p : Prepared String String)
    (r : Request String) (profile : Profile String) :
    approveExec s t command client preparation revision digest p r profile =
      s.approve t.toEvidence command client preparation revision digest p r profile := by
  unfold approveExec Coordination.approve
  exact ite_decidable _ _ _ _

end ManagerConformance
