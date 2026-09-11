import Mathlib.Data.Finmap

/-!
# Indexed coordination histories

A history is a finite word of coordination transitions and indexed observations.
`P` selects unchanged observations. `Q` folds all accepted entries, including
coordination intent before any observation. `M` pairs that fold with the finite
partial map of observed runs. A reserved identity alone has no runtime value.

The observation type and its fold are parameters, not another interpreter.
Instantiation with the runtime snapshot fold is restricted to its validated,
contiguous, same-run observations. The implementation bridge must establish that
restriction. These generic equations do not validate a physical observation.
-/

namespace Agentic.Manager

/-- A coordination entry or an observation indexed by its execution identity. -/
abbrev Entry (Coord Run Observation : Type) := Coord ⊕ (Run × Observation)

/-- A finite ordered word of coordination entries and execution observations. -/
abbrev History (Coord Run Observation : Type) := List (Entry Coord Run Observation)

variable {C I E S T : Type} [DecidableEq I]

/-- The unchanged subsequence of observations at one execution identity. -/
def P (run : I) (h : History C I E) : List E :=
  h.filterMap fun entry => match entry with
    | .inl _ => none
    | .inr (id, event) => if run = id then some event else none

/-- Projection is a word homomorphism: `P r (h ++ k) = P r h ++ P r k`. -/
theorem P_append (run : I) (h k : History C I E) :
    P run (h ++ k) = P run h ++ P run k := by
  simp [P, List.filterMap_append]

/-- The fold of accepted coordination facts, including entries without runtime evidence. -/
def Q (step : T → Entry C I E → T) (initial : T) (h : History C I E) : T :=
  h.foldl step initial

omit [DecidableEq I] in
/-- Coordination composition is the ordinary left-fold equation. -/
theorem Q_append (step : T → Entry C I E → T) (initial : T) (h k : History C I E) :
    Q step initial (h ++ k) = k.foldl step (Q step initial h) :=
  List.foldl_append

/-- The supplied observation fold, without any manager-defined execution semantics. -/
def R (step : S → E → S) (initial : S) (xs : List E) : S :=
  xs.foldl step initial

/-- Observation composition: `R (xs ++ ys) = fold step (R xs) ys`. -/
theorem R_append (step : S → E → S) (initial : S) (xs ys : List E) :
    R step initial (xs ++ ys) = ys.foldl step (R step initial xs) :=
  List.foldl_append

/-- A partial observation value, absent precisely when no observation was accepted. -/
def observed (step : S → E → S) (initial : S) : List E → Option S
  | [] => none
  | event :: rest => some (rest.foldl step (step initial event))

@[simp] theorem observed_append_one (step : S → E → S) (initial : S)
    (xs : List E) (event : E) :
    observed step initial (xs ++ [event]) =
      some (step ((observed step initial xs).getD initial) event) := by
  cases xs <;> simp [observed, List.foldl_append]

/-- The coordination fold paired with the finite partial map of observed executions. -/
def M (stepQ : T → Entry C I E → T) (initialQ : T)
    (stepR : S → E → S) (initialR : S) (h : History C I E) :
    T × (I → Option S) :=
  (Q stepQ initialQ h, fun run => observed stepR initialR (P run h))

/-- A run has no runtime value exactly when its observation projection is empty. -/
theorem M_absent_iff (stepQ : T → Entry C I E → T) (initialQ : T)
    (stepR : S → E → S) (initialR : S) (h : History C I E) (run : I) :
    (M stepQ initialQ stepR initialR h).2 run = none ↔ P run h = [] := by
  simp only [M]
  cases P run h <;> simp [observed]

/-- The finite domain of a history's runtime map consists of observed run identities. -/
theorem M_domain (stepQ : T → Entry C I E → T) (initialQ : T)
    (stepR : S → E → S) (initialR : S) (h : History C I E) (run : I) :
    (M stepQ initialQ stepR initialR h).2 run ≠ none ↔
      run ∈ (h.filterMap (fun entry => match entry with
        | .inl _ => none | .inr (id, _) => some id)).toFinset := by
  simp only [ne_eq, M_absent_iff]
  induction h with
  | nil => simp [P]
  | cons entry h ih =>
    cases entry with
    | inl c => simp_all [P]
    | inr pair =>
      rcases pair with ⟨id, event⟩
      by_cases hr : run = id
      · simp [P, hr]
      · simp_all [P]

/-- A materialized coordination value and a finite map of runtime observations. -/
structure Materialized (Coord Run Snapshot : Type) where
  coordination : Coord
  runs : Finmap (fun _ : Run => Snapshot)

/-- The partial-map meaning of a materialized value is lookup, not stored identity authority. -/
def Materialized.decode (s : Materialized T I S) : T × (I → Option S) :=
  (s.coordination, fun run => s.runs.lookup run)

/-- Appending one entry updates coordination and only its indexed execution observation. -/
def stepMeaning (stepQ : T → Entry C I E → T) (stepR : S → E → S) (initialR : S)
    (s : T × (I → Option S)) (entry : Entry C I E) : T × (I → Option S) :=
  (stepQ s.1 entry, fun run => match entry with
    | .inl _ => s.2 run
    | .inr (id, event) =>
      if run = id then some (stepR ((s.2 run).getD initialR) event) else s.2 run)

/-- The finite-map implementation solved from `decode (advance s e) = stepMeaning (decode s) e`. -/
def Materialized.advance (stepQ : T → Entry C I E → T) (stepR : S → E → S)
    (initialR : S) (s : Materialized T I S) (entry : Entry C I E) : Materialized T I S :=
  ⟨stepQ s.coordination entry, match entry with
    | .inl _ => s.runs
    | .inr (run, event) =>
      s.runs.insert run (stepR ((s.runs.lookup run).getD initialR) event)⟩

/-- The one-entry refinement square commutes for every materialized state. -/
theorem Materialized.decode_advance (stepQ : T → Entry C I E → T)
    (stepR : S → E → S) (initialR : S) (s : Materialized T I S) (entry : Entry C I E) :
    (s.advance stepQ stepR initialR entry).decode =
      stepMeaning stepQ stepR initialR s.decode entry := by
  apply Prod.ext
  · rfl
  · funext run
    cases entry with
    | inl c => rfl
    | inr pair =>
      rcases pair with ⟨id, event⟩
      by_cases h : run = id
      · subst run; simp [advance, decode, stepMeaning]
      · simp [advance, decode, stepMeaning, h]

/-- The meaning of appending one entry is its action on the preceding meaning. -/
theorem M_append_one (stepQ : T → Entry C I E → T) (initialQ : T)
    (stepR : S → E → S) (initialR : S) (h : History C I E) (entry : Entry C I E) :
    M stepQ initialQ stepR initialR (h ++ [entry]) =
      stepMeaning stepQ stepR initialR (M stepQ initialQ stepR initialR h) entry := by
  apply Prod.ext
  · simp [M, Q, stepMeaning, List.foldl_append]
  · funext run
    cases entry with
    | inl c => simp [M, P, stepMeaning]
    | inr pair =>
      rcases pair with ⟨id, event⟩
      by_cases h : run = id <;> simp [M, P, stepMeaning, h]

/-- Incremental finite-map storage refines the full history meaning, including its coordination fold. -/
theorem materialize_refines (stepQ : T → Entry C I E → T) (initialQ : T)
    (stepR : S → E → S) (initialR : S) (h : History C I E) :
    (h.foldl (Materialized.advance stepQ stepR initialR) ⟨initialQ, ∅⟩).decode =
      M stepQ initialQ stepR initialR h := by
  induction h using List.reverseRecOn with
  | nil => simp [Materialized.decode, M, Q, P, observed]
  | append_singleton h entry ih =>
    simpa only [List.foldl_append, List.foldl_cons, List.foldl_nil,
      Materialized.decode_advance, ih] using
      (M_append_one stepQ initialQ stepR initialR h entry).symm

/-- A coordination-only entry cannot create, remove, or alter a runtime observation. -/
theorem M_coordination (stepQ : T → Entry C I E → T) (initialQ : T)
    (stepR : S → E → S) (initialR : S) (h : History C I E) (intent : C) :
    (M stepQ initialQ stepR initialR (h ++ [.inl intent])).2 =
      (M stepQ initialQ stepR initialR h).2 := by
  rw [M_append_one]
  rfl

end Agentic.Manager
