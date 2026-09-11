import Agentic.Manager.Meaning

/-!
# Coordination witnesses and axiom footprints

These are closed mathematical witnesses and refusals, not worker or storage
fixtures. The positive evidence predicates are hypotheses of an abstract world.
No test below claims that a physical environment satisfies them.
-/

namespace Agentic.Manager.Checks

private def profile : Profile Nat := ⟨4, true, {30}⟩
private def lease : Reservation Nat := ⟨7, {30}⟩
private def request : Request Nat :=
  ⟨2, 3, 4, .queued, some 0, ⟨{10}, Finmap.singleton 10 20, ∅⟩, none, none⟩
private def prepared : Prepared Nat String :=
  ⟨1, 2, 3, 4, 9, 10, 11, 5, 6, 12, 13, "exact review", .live⟩
private def evidence : Evidence Nat String :=
  ⟨fun _ => True, fun _ => True, fun _ _ => True, fun _ _ => True,
    fun _ _ _ _ => True, fun _ _ => True⟩

private def queued : Coordination Nat String :=
  ⟨5, 6, {7}, Finmap.singleton 3 profile, Finmap.singleton 1 request,
    ∅, ∅, ∅, ∅, ∅, ∅, Finmap.singleton 20 "captured input", ∅⟩

private def review : Coordination Nat String :=
  { queued with
    requests := Finmap.singleton 1 { request with phase := .review, preparation := some 8 }
    reservations := Finmap.singleton 1 lease
    preparations := Finmap.singleton 8 prepared
    runs := Finmap.singleton 9 1
    supervision := Finmap.singleton 9 .owned }

private def first : DecisionKey Nat := ⟨14, 15, 16, some 17, 18⟩
private def second : DecisionKey Nat := ⟨24, 25, 26, some 27, 28⟩
private def pending : Coordination Nat String :=
  { review with decisions := Finmap.singleton 9 [⟨first, none⟩, ⟨second, none⟩] }

/-- A ready oldest request really admits, so reservation safety is not vacuous. -/
example : ∃ next, queued.admit 1 request profile lease = some next := by
  classical
  have valid : queued.canAdmit 1 request profile lease := by
    simp [Coordination.canAdmit, Coordination.eligible, queued, request, profile, lease,
      Readiness.ready]
  simp [Coordination.admit, valid]

/-- A live exact preparation really approves, with a previously unused command identity. -/
example : ∃ next, review.approve evidence 40 41 8 12 13 prepared
    { request with phase := .review, preparation := some 8 } profile = some next := by
  classical
  have valid : review.canApprove evidence 40 8 12 13 prepared
      { request with phase := .review, preparation := some 8 } profile := by
    simp [Coordination.canApprove, review, queued, request, prepared, profile, lease, evidence]
  simp [Coordination.approve, valid]

/-- Changed process generation refuses even though the stored preparation and every other binding remain intact. -/
example : ({ review with generation := 99 } : Coordination Nat String).approve
    evidence 40 41 8 12 13 prepared { request with phase := .review, preparation := some 8 } profile = none := by
  classical
  simp [Coordination.approve, Coordination.canApprove, review, queued, prepared]

/-- Changed authority epoch cannot reuse a saved approval. -/
example : ({ review with authority := 99 } : Coordination Nat String).approve
    evidence 40 41 8 12 13 prepared { request with phase := .review, preparation := some 8 } profile = none := by
  classical
  simp [Coordination.approve, Coordination.canApprove, review, queued, prepared]

/-- Absence of current live-worker evidence refuses an otherwise exact stored review. -/
example : review.approve { evidence with live := fun _ => False } 40 41 8 12 13
    prepared { request with phase := .review, preparation := some 8 } profile = none := by
  classical
  simp [Coordination.approve, Coordination.canApprove]

/-- Expiry refuses without releasing the resource reservation. -/
example : review.approve { evidence with unexpired := fun _ => False } 40 41 8 12 13
    prepared { request with phase := .review, preparation := some 8 } profile = none := by
  classical
  simp [Coordination.approve, Coordination.canApprove]

/-- The current head admits an answer, witnessing the conditional FIFO theorem. -/
example : ∃ next, pending.answer 40 41 9 first "answer" = some next := by
  classical
  simp [Coordination.answer, pending, review, queued]

/-- A later mandatory decision is refused, not reordered into the head position. -/
example : pending.answer 40 41 9 second "answer" = none := by
  apply Coordination.answer_nonhead _ _ _ _ _ _ ⟨first, none⟩ [⟨second, none⟩]
  · simp [pending]
  · decide

/-- Uncertain delivery keeps the first answer reserved and blocks a competing answer. -/
example : ((pending.answer 40 41 9 first "answer").bind fun next => next.delivery 40 .uncertain).bind
    (fun next => next.answer 42 41 9 first "different") = none := by
  classical
  simp [Coordination.answer, Coordination.delivery, pending, review, queued]

/-- Missing cleanup evidence retains the reservation by refusing release. -/
example : review.release { evidence with cleaned := fun _ _ => False } 1 = none := by
  classical
  simp [Coordination.release, review]

/-- Absent verification evidence refuses publication of a verified artifact. -/
example : review.verify { evidence with verifies := fun _ _ => False } 50 51 "output" = none := by
  classical
  simp [Coordination.verify]

/-- New observed decisions append after the entire existing pending FIFO. -/
example : (pending.openDecision evidence 9 ⟨34, 35, 36, some 37, 38⟩).map
    (fun next => next.decisions.lookup 9) =
      some (some [⟨first, none⟩, ⟨second, none⟩, ⟨⟨34, 35, 36, some 37, 38⟩, none⟩]) := by
  classical
  simp [Coordination.openDecision, pending, evidence, first, second]

/-- Correlated resolution removes the reserved head and exposes the original suffix. -/
example : ((pending.answer 40 41 9 first "answer").bind
    (fun next => next.resolve evidence 9 40 first .resolved)).map
      (fun next => next.decisions.lookup 9) = some (some [⟨second, none⟩]) := by
  classical
  simp [Coordination.answer, Coordination.resolve, pending, review, queued, evidence]

/-- Proven non-effect releases the reservation without changing either decision's position. -/
example : ((pending.answer 40 41 9 first "answer").bind
    (fun next => next.resolve evidence 9 40 first .notEffective)).map
      (fun next => next.decisions.lookup 9) = some (some [⟨first, none⟩, ⟨second, none⟩]) := by
  classical
  simp [Coordination.answer, Coordination.resolve, pending, review, queued, evidence]

/-- Confirmed cleanup really releases the reservation, complementing the refusal witness. -/
example : (review.release evidence 1).map (fun next => next.reservations.lookup 1) = some none := by
  classical
  simp [Coordination.release, review, evidence]

/-- Verification retains the exact referenced value, not a fabricated success marker. -/
example : (review.verify evidence 50 51 "output").map (fun next => next.artifacts.lookup 50) =
    some (some (.verified 51 "output")) := by
  classical
  simp [Coordination.verify, evidence]

/-- Projection discards coordination and other runs without changing payloads or ordering. -/
example : P 1 ([.inr (1, 7), .inl (), .inr (2, 8), .inr (1, 9)] : History Unit Nat Nat) = [7, 9] := by
  decide

/-- A reserved execution identity in coordination has no runtime snapshot before observation. -/
example : review.runs.lookup 9 = some 1 ∧
    (M (fun q (_ : Entry Unit Nat Nat) => q) review (fun (s : Nat) e => s + e) 0 []).2 9 = none := by
  simp [review, M, P, observed]

/-- info: 'Agentic.Manager.P_append' depends on axioms: [propext] -/
#guard_msgs in
#print axioms P_append

/-- info: 'Agentic.Manager.Q_append' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in
#print axioms Q_append

/-- info: 'Agentic.Manager.R_append' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in
#print axioms R_append

/-- info: 'Agentic.Manager.M_domain' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms M_domain

/-- info: 'Agentic.Manager.M_coordination' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in
#print axioms M_coordination

/-- info: 'Agentic.Manager.Materialized.decode_advance' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms Materialized.decode_advance

/-- info: 'Agentic.Manager.coordination_refinement' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms coordination_refinement

/-- info: 'Agentic.Manager.coordination_intent' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in
#print axioms coordination_intent

/-- info: 'Agentic.Manager.Coordination.admit_exclusive' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms Coordination.admit_exclusive

/-- info: 'Agentic.Manager.Coordination.admit_oldest' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms Coordination.admit_oldest

/-- info: 'Agentic.Manager.Coordination.approval_valid' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms Coordination.approval_valid

/-- info: 'Agentic.Manager.Coordination.approve_single_use' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms Coordination.approve_single_use

/-- info: 'Agentic.Manager.Coordination.openDecision_fifo' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms Coordination.openDecision_fifo

/-- info: 'Agentic.Manager.Coordination.answer_fifo' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms Coordination.answer_fifo

/-- info: 'Agentic.Manager.Coordination.answer_nonhead' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms Coordination.answer_nonhead

/-- info: 'Agentic.Manager.Coordination.answer_reserved' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms Coordination.answer_reserved

/-- info: 'Agentic.Manager.Coordination.resolve_fifo' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms Coordination.resolve_fifo

/-- info: 'Agentic.Manager.Coordination.delivery_preserves_decisions' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms Coordination.delivery_preserves_decisions

/-- info: 'Agentic.Manager.Coordination.release_confirmed' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms Coordination.release_confirmed

/-- info: 'Agentic.Manager.Coordination.verify_exact' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms Coordination.verify_exact

end Agentic.Manager.Checks
