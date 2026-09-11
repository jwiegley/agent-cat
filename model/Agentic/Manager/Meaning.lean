import Agentic.Manager.History
import Agentic.Manager.Coordination

/-!
# The coordination specialization of the history meaning

Coordination transitions are partial endomorphisms. Composition is ordinary
`Option.bind`, so a refused transition has no accepted continuation. The
ambient history type admits arbitrary mathematical transitions. Safety laws
apply to the guarded vocabulary in `Coordination`, not to arbitrary functions.
The coordination effects of a runtime observation are supplied separately from
its opaque runtime fold. Coordination-only facts populate their own finite maps
without populating the runtime map.

A realization must supply the actual runtime fold and validate its observation
prefix, implement the chosen coordination transitions, and justify environment
evidence at the point of use. The refinement below concerns finite-map
materialization, not an unimplemented storage or transport realization.
-/

namespace Agentic.Manager

/-- A partial endomorphism of the coordination resource product. -/
abbrev Transition (I V : Type) := Coordination I V → Option (Coordination I V)

/-- The coordination action of one entry, with refusal absorbing subsequent entries. -/
def coordinationStep {I V E : Type}
    (observe : Coordination I V → I → E → Option (Coordination I V))
    (s : Option (Coordination I V)) (entry : Entry (Transition I V) I E) :
    Option (Coordination I V) :=
  s.bind fun current => match entry with
    | .inl transition => transition current
    | .inr (run, observation) => observe current run observation

/-- No accepted continuation can hide a preceding coordination refusal. -/
theorem coordination_refusal {I V E : Type}
    (observe : Coordination I V → I → E → Option (Coordination I V))
    (h : History (Transition I V) I E) :
    Q (coordinationStep observe) none h = none := by
  induction h with
  | nil => rfl
  | cons entry h ih =>
    cases entry <;> simpa [Q, coordinationStep] using ih

/-- A command intent changes coordination before it contributes any runtime observation. -/
theorem coordination_intent {I V E S : Type} [DecidableEq I]
    (observe : Coordination I V → I → E → Option (Coordination I V))
    (s s' : Coordination I V) (transition : Transition I V)
    (accepted : transition s = some s') (stepR : S → E → S) (initialR : S) :
    M (coordinationStep observe) (some s) stepR initialR [.inl transition] =
      (some s', fun _ => none) := by
  simp [M, Q, coordinationStep, P, observed, accepted]

/-- The finite-map coordinator refines both accepted resource state and unchanged per-run observations. -/
theorem coordination_refinement {I V E S : Type} [DecidableEq I]
    (observe : Coordination I V → I → E → Option (Coordination I V))
    (s : Coordination I V) (stepR : S → E → S) (initialR : S)
    (h : History (Transition I V) I E) :
    (h.foldl (Materialized.advance (coordinationStep observe) stepR initialR) ⟨some s, ∅⟩).decode =
      M (coordinationStep observe) (some s) stepR initialR h :=
  materialize_refines (coordinationStep observe) (some s) stepR initialR h

end Agentic.Manager
