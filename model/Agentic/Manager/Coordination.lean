import Mathlib.Data.Finmap

/-!
# Coordination resources and admissible operations

The object is a product of finite maps, finite resource sets, and ordered
mandatory-decision lists. It contains no execution snapshot. Labels are atoms
with decidable equality and do not denote authority, paths, or process handles.
Captured values and exact prepared reviews are parameters, not reinterpreted
workflow data.

Environment predicates state the evidence needed for live preparation,
confirmed cleanup, correlated decision resolution, and verified content.
Their truth is an explicit hypothesis at this layer. No theorem below proves
that a physical worker, clock, filesystem, or transport supplies that evidence.
-/

namespace Agentic.Manager

/-- The phase of a request, independently of supervision and runtime observations. -/
inductive RequestPhase where
  | draft | queued | preparing | review | startPending | associated | withdrawn | refused
  deriving DecidableEq

/-- The availability of a prepared capability, independently of its stored review. -/
inductive PreparationPhase where
  | live | consumed | invalidated
  deriving DecidableEq

/-- The observed ownership relation to a run, independently of its execution outcome. -/
inductive Supervision where
  | owned | cleanupPending | lost | observer
  deriving DecidableEq

/-- Required input names, immutable capture bindings, and structural validation failures. -/
structure Readiness (I : Type) where
  required : Finset I
  supplied : Finmap (fun _ : I => I)
  invalid : Finset I

/-- Structural readiness is complete binding with no invalid input, not semantic preparation. -/
def Readiness.ready {I : Type} (r : Readiness I) : Prop :=
  r.required ⊆ r.supplied.keys ∧ r.invalid = ∅

/-- A durable request revision and its independently recorded preparation/run associations. -/
structure Request (I : Type) where
  revision : I
  profile : I
  profileRevision : I
  phase : RequestPhase
  queueOrdinal : Option Nat
  inputs : Readiness I
  preparation : Option I
  run : Option I

/-- A trusted profile revision and the exclusive resource keys assigned to it. -/
structure Profile (I : Type) where
  revision : I
  enabled : Bool
  resources : Finset I

/-- One global capacity slot and a finite set of exclusive resource keys. -/
structure Reservation (I : Type) where
  slot : I
  exclusive : Finset I

/-- The disjoint union of slot identities and exclusive keys prevents collisions between their domains. -/
def Reservation.resources {I : Type} [DecidableEq I] (r : Reservation I) : Finset (I ⊕ I) :=
  {Sum.inl r.slot} ∪ r.exclusive.image Sum.inr

/-- An exact review tied to one request, profile, run, worker, and authority generation. -/
structure Prepared (I V : Type) where
  request : I
  requestRevision : I
  profile : I
  profileRevision : I
  run : I
  nativeRun : I
  worker : I
  generation : I
  authority : I
  revision : I
  digest : I
  review : V
  phase : PreparationPhase

/-- The exact identity of a mandatory runtime decision, including its revision and attempt generation. -/
structure DecisionKey (I : Type) where
  id : I
  revision : I
  occurrence : I
  attempt : Option I
  generation : I
  deriving DecidableEq

/-- A pending mandatory decision and its optional exclusive command reservation. -/
structure Decision (I : Type) where
  key : DecisionKey I
  command : Option I

/-- The delivery knowledge of an accepted intent, not its native acknowledgement or effect. -/
inductive Delivery where
  | notAttempted | attempted | uncertain | failed
  deriving DecidableEq

/-- The native acknowledgement alternatives, distinct from an observed control effect. -/
inductive Acknowledgement where
  | accepted | queued | delivered | rejectedStale | unsupported | controlFailed
  deriving DecidableEq

/-- An accepted start or decision-answer intent with its unchanged target and captured value. -/
inductive Intent (I V : Type) where
  | start (prepared : Prepared I V)
  | answer (run : I) (decision : DecisionKey I) (value : V)

/-- An attributed intent, delivery knowledge, native acknowledgements, and independent effect evidence. -/
structure Receipt (I V : Type) where
  client : I
  intent : Intent I V
  delivery : Delivery
  acknowledgements : List Acknowledgement
  effect : Option V

/-- A referenced, verified, or unavailable artifact, separately from any runtime outcome. -/
inductive Artifact (I V : Type) where
  | referenced (reference : I)
  | verified (reference : I) (value : V)
  | unavailable (reference : I)

/-- The product of coordination resource dimensions, with no fabricated execution component. -/
structure Coordination (I V : Type) where
  generation : I
  authority : I
  slots : Finset I
  profiles : Finmap (fun _ : I => Profile I)
  requests : Finmap (fun _ : I => Request I)
  reservations : Finmap (fun _ : I => Reservation I)
  preparations : Finmap (fun _ : I => Prepared I V)
  runs : Finmap (fun _ : I => I)
  supervision : Finmap (fun _ : I => Supervision)
  decisions : Finmap (fun _ : I => List (Decision I))
  commands : Finmap (fun _ : I => Receipt I V)
  captures : Finmap (fun _ : I => V)
  artifacts : Finmap (fun _ : I => Artifact I V)

/-- Correlated evidence either resolves a decision or proves its reserved answer did not take effect. -/
inductive Resolution where
  | resolved | notEffective
  deriving DecidableEq

/-- Abstract evidence supplied by the environment, never inferred from a stored label. -/
structure Evidence (I V : Type) where
  live : Prepared I V → Prop
  unexpired : Prepared I V → Prop
  cleaned : I → Reservation I → Prop
  opened : I → DecisionKey I → Prop
  resolution : I → DecisionKey I → I → Resolution → Prop
  verifies : I → V → Prop

variable {I V : Type} [DecidableEq I]

/-- Reservation exclusivity means distinct owners have disjoint slot/key sets. -/
def Coordination.exclusive (s : Coordination I V) : Prop :=
  ∀ a ra b rb, s.reservations.lookup a = some ra → s.reservations.lookup b = some rb →
    a ≠ b → Disjoint ra.resources rb.resources

/-- Eligibility means structural readiness, the current profile, a free slot, and every configured key. -/
def Coordination.eligible (s : Coordination I V) (id : I) (r : Request I)
    (profile : Profile I) (lease : Reservation I) : Prop :=
  s.requests.lookup id = some r ∧ r.phase = .queued ∧ r.inputs.ready ∧
  s.profiles.lookup r.profile = some profile ∧ profile.enabled = true ∧
  r.profileRevision = profile.revision ∧ lease.slot ∈ s.slots ∧
  lease.exclusive = profile.resources ∧ s.reservations.lookup id = none ∧
  ∀ other held, s.reservations.lookup other = some held → Disjoint lease.resources held.resources

/-- Admission chooses an oldest eligible queue ordinal without blocking independent eligible profiles. -/
def Coordination.canAdmit (s : Coordination I V) (id : I) (r : Request I)
    (profile : Profile I) (lease : Reservation I) : Prop :=
  s.eligible id r profile lease ∧ ∃ ordinal, r.queueOrdinal = some ordinal ∧
    ∀ other request otherProfile otherLease otherOrdinal,
      s.eligible other request otherProfile otherLease → request.queueOrdinal = some otherOrdinal →
      ordinal ≤ otherOrdinal

/-- Admission reserves all resources together and changes only the request's admission phase. -/
noncomputable def Coordination.admit (s : Coordination I V) (id : I) (r : Request I)
    (profile : Profile I) (lease : Reservation I) : Option (Coordination I V) := by
  classical
  exact if s.canAdmit id r profile lease then
    some { s with requests := s.requests.insert id { r with phase := .preparing }
                  reservations := s.reservations.insert id lease }
  else none

/-- Admission has exactly the guarded finite-map update specified by the resource meaning. -/
theorem Coordination.admit_spec (s s' : Coordination I V) (id : I) (r : Request I)
    (profile : Profile I) (lease : Reservation I) :
    s.admit id r profile lease = some s' ↔ s.canAdmit id r profile lease ∧
      s' = { s with requests := s.requests.insert id { r with phase := .preparing }
                    reservations := s.reservations.insert id lease } := by
  classical
  by_cases h : s.canAdmit id r profile lease <;> simp [admit, h, eq_comm]

/-- Admission preserves resource exclusivity rather than overwriting an existing reservation. -/
theorem Coordination.admit_exclusive (s s' : Coordination I V) (id : I) (r : Request I)
    (profile : Profile I) (lease : Reservation I) (before : s.exclusive)
    (accepted : s.admit id r profile lease = some s') : s'.exclusive := by
  classical
  rcases (admit_spec s s' id r profile lease).mp accepted with ⟨valid, rfl⟩
  rcases valid.1 with ⟨_, _, _, _, _, _, _, _, _, free⟩
  intro a ra b rb ha hb different
  by_cases a_id : a = id
  · subst a
    have ra_lease : lease = ra := by simpa using ha
    subst ra
    have b_id : b ≠ id := Ne.symm different
    exact free b rb (by simpa [Finmap.lookup_insert_of_ne _ b_id] using hb)
  · by_cases b_id : b = id
    · subst b
      have rb_lease : lease = rb := by simpa using hb
      subst rb
      exact (free a ra (by simpa [Finmap.lookup_insert_of_ne _ a_id] using ha)).symm
    · exact before a ra b rb
        (by simpa [Finmap.lookup_insert_of_ne _ a_id] using ha)
        (by simpa [Finmap.lookup_insert_of_ne _ b_id] using hb) different

/-- No earlier eligible queued request is overtaken by an accepted admission. -/
theorem Coordination.admit_oldest (s s' : Coordination I V) (id : I) (r : Request I)
    (profile : Profile I) (lease : Reservation I) (accepted : s.admit id r profile lease = some s') :
    ∃ ordinal, r.queueOrdinal = some ordinal ∧
      ∀ other request otherProfile otherLease otherOrdinal,
        s.eligible other request otherProfile otherLease → request.queueOrdinal = some otherOrdinal →
        ordinal ≤ otherOrdinal :=
  ((admit_spec s s' id r profile lease).mp accepted).1.2

/-- Approval requires the current exact preparation and live evidence in the same authority generation. -/
def Coordination.canApprove (s : Coordination I V) (e : Evidence I V)
    (command preparation revision digest : I) (p : Prepared I V) (r : Request I)
    (profile : Profile I) : Prop :=
  s.preparations.lookup preparation = some p ∧ p.phase = .live ∧
  p.revision = revision ∧ p.digest = digest ∧
  s.requests.lookup p.request = some r ∧ r.phase = .review ∧
  r.preparation = some preparation ∧ r.revision = p.requestRevision ∧
  r.profile = p.profile ∧ r.profileRevision = p.profileRevision ∧
  s.profiles.lookup p.profile = some profile ∧ profile.revision = p.profileRevision ∧
  profile.enabled = true ∧ p.generation = s.generation ∧ p.authority = s.authority ∧
  (∃ lease, s.reservations.lookup p.request = some lease ∧
    lease.exclusive = profile.resources ∧ lease.slot ∈ s.slots) ∧
  s.runs.lookup p.run = some p.request ∧
  s.commands.lookup command = none ∧ e.live p ∧ e.unexpired p

/-- Approval consumes the live capability and records its exact start intent without claiming delivery. -/
noncomputable def Coordination.approve (s : Coordination I V) (e : Evidence I V)
    (command client preparation revision digest : I) (p : Prepared I V) (r : Request I)
    (profile : Profile I) : Option (Coordination I V) := by
  classical
  exact if s.canApprove e command preparation revision digest p r profile then
    some { s with
      preparations := s.preparations.insert preparation { p with phase := .consumed }
      requests := s.requests.insert p.request { r with phase := .startPending, run := some p.run }
      commands := s.commands.insert command ⟨client, .start p, .notAttempted, [], none⟩ }
  else none

/-- Approval is the guarded update that binds the exact worker's review to an undelivered start intent. -/
theorem Coordination.approve_spec (s s' : Coordination I V) (e : Evidence I V)
    (command client preparation revision digest : I) (p : Prepared I V) (r : Request I)
    (profile : Profile I) :
    s.approve e command client preparation revision digest p r profile = some s' ↔
      s.canApprove e command preparation revision digest p r profile ∧
      s' = { s with
        preparations := s.preparations.insert preparation { p with phase := .consumed }
        requests := s.requests.insert p.request { r with phase := .startPending, run := some p.run }
        commands := s.commands.insert command ⟨client, .start p, .notAttempted, [], none⟩ } := by
  classical
  by_cases h : s.canApprove e command preparation revision digest p r profile <;>
    simp [approve, h, eq_comm]

/-- Accepted approval preserves every live binding and records neither delivery nor an execution result. -/
theorem Coordination.approval_valid (s s' : Coordination I V) (e : Evidence I V)
    (command client preparation revision digest : I) (p : Prepared I V) (r : Request I)
    (profile : Profile I)
    (accepted : s.approve e command client preparation revision digest p r profile = some s') :
    p.revision = revision ∧ p.digest = digest ∧
    r.revision = p.requestRevision ∧ r.profile = p.profile ∧
    r.profileRevision = p.profileRevision ∧ profile.revision = p.profileRevision ∧
    p.generation = s.generation ∧ p.authority = s.authority ∧ e.live p ∧ e.unexpired p ∧
    s'.preparations.lookup preparation = some { p with phase := .consumed } ∧
    s'.commands.lookup command = some ⟨client, .start p, .notAttempted, [], none⟩ ∧
    s'.reservations = s.reservations ∧ s'.artifacts = s.artifacts := by
  rcases (approve_spec s s' e command client preparation revision digest p r profile).mp accepted
    with ⟨valid, rfl⟩
  rcases valid with ⟨_, _, rev, digest, _, _, _, reqrev, reqprofile, reqprofRev, _, profrev,
    _, generation, authority, _, _, _, live, unexpired⟩
  exact ⟨rev, digest, reqrev, reqprofile, reqprofRev, profrev, generation, authority, live, unexpired,
    by simp, by simp, rfl, rfl⟩

/-- A consumed or invalidated stored preparation refuses approval even when every label is retained. -/
theorem Coordination.approve_not_live (s : Coordination I V) (e : Evidence I V)
    (command client preparation revision digest : I) (p : Prepared I V) (r : Request I)
    (profile : Profile I) (notLive : p.phase ≠ .live) :
    s.approve e command client preparation revision digest p r profile = none := by
  classical
  simp [approve, canApprove, notLive]

/-- A stored consumed capability cannot be revived by submitting a different record with the same label. -/
theorem Coordination.approve_consumed (s : Coordination I V) (e : Evidence I V)
    (command client preparation revision digest : I) (p saved : Prepared I V) (r : Request I)
    (profile : Profile I) (stored : s.preparations.lookup preparation = some saved)
    (spent : saved.phase ≠ .live) :
    s.approve e command client preparation revision digest p r profile = none := by
  classical
  unfold approve
  split
  next valid =>
    have same : saved = p := Option.some.inj (stored.symm.trans valid.1)
    cases same
    exact False.elim (spent valid.2.1)
  next => rfl

/-- Successful approval is single-use even under another command, client, or proposed prepared record. -/
theorem Coordination.approve_single_use (s s' : Coordination I V) (e later : Evidence I V)
    (command client preparation revision digest : I) (p : Prepared I V) (r : Request I)
    (profile : Profile I)
    (accepted : s.approve e command client preparation revision digest p r profile = some s')
    (nextCommand nextClient nextRevision nextDigest : I) (nextPrepared : Prepared I V)
    (nextRequest : Request I) (nextProfile : Profile I) :
    s'.approve later nextCommand nextClient preparation nextRevision nextDigest
      nextPrepared nextRequest nextProfile = none := by
  rcases (approve_spec s s' e command client preparation revision digest p r profile).mp accepted
    with ⟨_, rfl⟩
  exact approve_consumed _ later nextCommand nextClient preparation nextRevision nextDigest
    nextPrepared { p with phase := .consumed } nextRequest nextProfile (by simp) (by simp)

/-- An observed mandatory decision extends only its own run's pending sequence. -/
noncomputable def Coordination.openDecision (s : Coordination I V) (e : Evidence I V)
    (run : I) (key : DecisionKey I) : Option (Coordination I V) := by
  classical
  let pending := (s.decisions.lookup run).getD []
  exact if e.opened run key ∧ ∀ old ∈ pending, old.key.id ≠ key.id then
    some { s with decisions := s.decisions.insert run (pending ++ [⟨key, none⟩]) }
  else none

/-- The opening equation retains the entire preceding FIFO before the new observed decision. -/
theorem Coordination.openDecision_fifo (s s' : Coordination I V) (e : Evidence I V)
    (run : I) (key : DecisionKey I) (accepted : s.openDecision e run key = some s') :
    e.opened run key ∧
    s'.decisions.lookup run = some ((s.decisions.lookup run).getD [] ++ [⟨key, none⟩]) ∧
    (∀ other, other ≠ run → s'.decisions.lookup other = s.decisions.lookup other) := by
  classical
  dsimp only [openDecision] at accepted
  split at accepted
  next valid =>
    cases accepted
    exact ⟨valid.1, by simp, fun other different => by simp [Finmap.lookup_insert_of_ne _ different]⟩
  next => cases accepted

/-- A decision answer reserves only the current unreserved head of an owned run. -/
noncomputable def Coordination.answer (s : Coordination I V) (command client run : I)
    (key : DecisionKey I) (value : V) : Option (Coordination I V) := by
  classical
  exact match s.decisions.lookup run with
  | some (head :: tail) =>
    if head.key = key ∧ head.command = none ∧ s.commands.lookup command = none ∧
        s.supervision.lookup run = some .owned then
      some { s with
        decisions := s.decisions.insert run ({ head with command := some command } :: tail)
        commands := s.commands.insert command ⟨client, .answer run key value, .notAttempted, [], none⟩ }
    else none
  | _ => none

/-- An accepted answer changes exactly the head's reservation and preserves the pending suffix. -/
theorem Coordination.answer_fifo (s s' : Coordination I V) (command client run : I)
    (key : DecisionKey I) (value : V) (accepted : s.answer command client run key value = some s') :
    ∃ head tail, s.decisions.lookup run = some (head :: tail) ∧ head.key = key ∧
      head.command = none ∧
      s'.decisions.lookup run = some ({ head with command := some command } :: tail) ∧
      s'.commands.lookup command = some ⟨client, .answer run key value, .notAttempted, [], none⟩ ∧
      (∀ other, other ≠ run → s'.decisions.lookup other = s.decisions.lookup other) := by
  classical
  unfold answer at accepted
  split at accepted
  next head tail queue =>
    split at accepted
    next valid =>
      cases accepted
      exact ⟨head, tail, queue, valid.1, valid.2.1, by simp, by simp,
        fun other different => by simp [Finmap.lookup_insert_of_ne _ different]⟩
    next => cases accepted
  next => cases accepted

/-- Non-head mandatory decisions refuse through the same answer operation used for every caller. -/
theorem Coordination.answer_nonhead (s : Coordination I V) (command client run : I)
    (key : DecisionKey I) (value : V) (head : Decision I) (tail : List (Decision I))
    (queue : s.decisions.lookup run = some (head :: tail)) (different : head.key ≠ key) :
    s.answer command client run key value = none := by
  classical
  simp [answer, queue, different]

/-- A reserved head refuses a second answer until correlated evidence releases or resolves it. -/
theorem Coordination.answer_reserved (s : Coordination I V) (command client run : I)
    (key : DecisionKey I) (value : V) (head : Decision I) (tail : List (Decision I))
    (queue : s.decisions.lookup run = some (head :: tail)) (reserved : head.command ≠ none) :
    s.answer command client run key value = none := by
  classical
  simp [answer, queue, reserved]

/-- Only correlated evidence removes a resolved head or releases its proven ineffective reservation. -/
noncomputable def Coordination.resolve (s : Coordination I V) (e : Evidence I V) (run command : I)
    (key : DecisionKey I) (resolution : Resolution) : Option (Coordination I V) := by
  classical
  exact match s.decisions.lookup run with
  | some (head :: tail) =>
    if head.key = key ∧ head.command = some command ∧ e.resolution run key command resolution then
      some { s with decisions := s.decisions.insert run (match resolution with
        | .resolved => tail
        | .notEffective => { head with command := none } :: tail) }
    else none
  | _ => none

/-- Resolution changes only the matching reserved head and requires explicit correlated evidence. -/
theorem Coordination.resolve_fifo (s s' : Coordination I V) (e : Evidence I V) (run command : I)
    (key : DecisionKey I) (resolution : Resolution)
    (accepted : s.resolve e run command key resolution = some s') :
    ∃ head tail, s.decisions.lookup run = some (head :: tail) ∧ head.key = key ∧
      head.command = some command ∧ e.resolution run key command resolution ∧
      s'.decisions.lookup run = some (match resolution with
        | .resolved => tail
        | .notEffective => { head with command := none } :: tail) := by
  classical
  unfold resolve at accepted
  split at accepted
  next head tail queue =>
    split at accepted
    next valid =>
      cases accepted
      exact ⟨head, tail, queue, valid.1, valid.2.1, valid.2.2, by cases resolution <;> simp⟩
    next => cases accepted
  next => cases accepted

/-- Delivery knowledge changes a receipt only, leaving pending decision reservations intact. -/
def Coordination.delivery (s : Coordination I V) (command : I) (knowledge : Delivery) :
    Option (Coordination I V) := do
  let receipt ← s.commands.lookup command
  pure { s with commands := s.commands.insert command { receipt with delivery := knowledge } }

/-- Attempted, uncertain, or failed delivery is not evidence that permits another answer. -/
theorem Coordination.delivery_preserves_decisions (s s' : Coordination I V)
    (command : I) (knowledge : Delivery) (accepted : s.delivery command knowledge = some s') :
    s'.decisions = s.decisions := by
  cases found : s.commands.lookup command with
  | none => simp [delivery, found] at accepted
  | some receipt =>
    simp [delivery, found] at accepted
    cases accepted
    rfl

/-- Resource release requires confirmed cleanup of that exact owner's reservation. -/
noncomputable def Coordination.release (s : Coordination I V) (e : Evidence I V) (owner : I) :
    Option (Coordination I V) := by
  classical
  exact match s.reservations.lookup owner with
  | none => none
  | some lease => if e.cleaned owner lease then
      some { s with reservations := s.reservations.erase owner }
    else none

/-- Release removes only the confirmed owner's reservation and requires its cleanup evidence. -/
theorem Coordination.release_confirmed (s s' : Coordination I V) (e : Evidence I V) (owner : I)
    (accepted : s.release e owner = some s') :
    ∃ lease, s.reservations.lookup owner = some lease ∧ e.cleaned owner lease ∧
      s'.reservations = s.reservations.erase owner := by
  classical
  unfold release at accepted
  split at accepted
  next => cases accepted
  next lease found =>
    split at accepted
    next cleaned =>
      cases accepted
      exact ⟨lease, found, cleaned, rfl⟩
    next => cases accepted

/-- A verified artifact observation retains its exact value only with corresponding verification evidence. -/
noncomputable def Coordination.verify (s : Coordination I V) (e : Evidence I V)
    (artifact reference : I) (value : V) : Option (Coordination I V) := by
  classical
  exact if e.verifies reference value then
    some { s with artifacts := s.artifacts.insert artifact (.verified reference value) }
  else none

/-- Verified output preserves the exact observation value under the explicit verification hypothesis. -/
theorem Coordination.verify_exact (s s' : Coordination I V) (e : Evidence I V)
    (artifact reference : I) (value : V)
    (accepted : s.verify e artifact reference value = some s') :
    e.verifies reference value ∧ s'.artifacts.lookup artifact = some (.verified reference value) := by
  classical
  unfold verify at accepted
  split at accepted
  next verified =>
    cases accepted
    exact ⟨verified, by simp⟩
  next => cases accepted

end Agentic.Manager
