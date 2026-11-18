import Agentic.Core.Schema
import Mathlib.Algebra.Order.Field.Rat

/-!
# Regions of the probability simplex

A region is a finite intersection of half-spaces of Δ(T), read on the cone.

The options `T` of a decision are a finite list of names, and an answer is a
record `v : T → ℚ` of one number per option. The answer means a point of the
simplex `Δ(T) = {p : T → ℚ≥0 | Σp = 1}` through the projective reading
`π(v) = v / Σv`, which is defined exactly on the cone
`C(T) = {v | v ≥ 0 ∧ Σv > 0}`. Outside the cone an answer means nothing.

An affine reading of `Δ(T)` is a pairing `⟨w,·⟩` with a weight vector
`w : T → ℚ`, and a test of a reading against a threshold `θ` is the closed
half-space `H(w,θ) = {p | ⟨w,p⟩ ≥ θ}`. On a representative of the cone the
test is homogeneous: `⟨w,π v⟩ ≥ θ ⇔ ⟨w,v⟩ ≥ θ·Σv`. A region `R` is a finite
list of half-spaces, and

`holds R v ⇔ v ∈ C(T) ∧ ∀ (w,θ) ∈ R. ⟨w,v⟩ ≥ θ·Σv`.

With `R = []` this says that `v` is a distribution up to scale.

The four theorems below are the laws of that reading: it is invariant under a
positive scale (`holds_scale`), it is closed under the addition of
representatives (`holds_add`, the cone is convex and each half-space is a
convex cone on representatives), it agrees with the test on the normalized
point (`holds_iff_normalized`), and the normalized point is a point of the
simplex (`normalize_mem_simplex`). That `normalize` lands in Mathlib's
`stdSimplex` is the statement of `normalize_mem_simplex` in that vocabulary.
It is not proved against `stdSimplex` itself, which would bring
convex-analysis Mathlib into the closure of the conformance oracle.

The second half of the module reads a decision record out of a structured
value: `Schema.Shape.numberFieldsAt?` names the options of the number record
at a field path, and `Schema.Shape.recordAt` reads that record of a value.
-/

namespace Agentic.Core

namespace Region

/-- `[[Halfspace]]` = the closed half-space `H(w,θ) = {p ∈ Δ(T) | ⟨w,p⟩ ≥ θ}`
of the simplex over a decision's options, with the weight vector `w` given by
`weights` (an option that is not listed weighs `0`) and the threshold `θ` given
by `atLeast`. On a representative `v` of the cone it is read homogeneously, as
`⟨w,v⟩ ≥ θ·Σv`. -/
structure Halfspace where
  /-- The weight vector `w`, as pairs of an option name and its weight. -/
  weights : List (String × Rat)
  /-- The threshold `θ`. -/
  atLeast : Rat
  deriving DecidableEq, Repr

/-- `[[dot w v]]` = `⟨w,v⟩ = Σ_{(n,c) ∈ w} c · v n`, the pairing of a weight
list with a record. -/
def dot (w : List (String × Rat)) (v : String → Rat) : Rat :=
  (w.map fun nc => nc.2 * v nc.1).sum

/-- `[[total names v]]` = `Σ_{n ∈ names} v n`, the mass of a record over the
options. -/
def total (names : List String) (v : String → Rat) : Rat :=
  (names.map v).sum

/-- `[[inCone names v]]` = `v ∈ C(T)`: every entry is non-negative and the mass
is positive. This is the domain of the reading `π(v) = v/Σv`. -/
def inCone (names : List String) (v : String → Rat) : Bool :=
  names.all (fun n => decide (0 ≤ v n)) && decide (0 < total names v)

/-- `[[h.holds names v]]` = `⟨w,v⟩ ≥ θ·Σv`, the half-space `h` read
homogeneously on the representative `v`. -/
def Halfspace.holds (names : List String) (h : Halfspace) (v : String → Rat) : Bool :=
  decide (h.atLeast * total names v ≤ dot h.weights v)

/-- `[[holds names R v]]` = `v ∈ C(T) ∧ ∀ h ∈ R. h.holds names v`: the record
`v` means a point of `Δ(T)` and that point lies in the region `R`. -/
def holds (names : List String) (R : List Halfspace) (v : String → Rat) : Bool :=
  inCone names v && R.all (·.holds names v)

/-- `[[normalize names v]]` = `π(v) = v/Σv`, the point of the simplex that the
record `v` represents. It is meaningful on the cone, and `normalize_mem_simplex`
states that it lands in `Δ(T)` there. -/
def normalize (names : List String) (v : String → Rat) : String → Rat :=
  fun n => v n / total names v

/-! ## Linearity of the pairing and of the mass -/

private theorem sum_map_mul_left {α : Type} (l : List α) (f : α → Rat) (c : Rat) :
    (l.map fun x => c * f x).sum = c * (l.map f).sum := by
  induction l with
  | nil => simp
  | cons a l ih => simp [ih, mul_add]

private theorem sum_map_add {α : Type} (l : List α) (f g : α → Rat) :
    (l.map fun x => f x + g x).sum = (l.map f).sum + (l.map g).sum := by
  induction l with
  | nil => simp
  | cons a l ih => simp only [List.map_cons, List.sum_cons, ih]; exact add_add_add_comm _ _ _ _

/-- `⟨w, c·v⟩ = c·⟨w,v⟩`. -/
theorem dot_scale (w : List (String × Rat)) (v : String → Rat) (c : Rat) :
    dot w (fun n => c * v n) = c * dot w v := by
  unfold dot
  rw [← sum_map_mul_left]
  congr 1
  exact List.map_congr_left fun nc _ => mul_left_comm _ _ _

/-- `⟨w, v + v'⟩ = ⟨w,v⟩ + ⟨w,v'⟩`. -/
theorem dot_add (w : List (String × Rat)) (v v' : String → Rat) :
    dot w (fun n => v n + v' n) = dot w v + dot w v' := by
  unfold dot
  rw [← sum_map_add]
  congr 1
  exact List.map_congr_left fun nc _ => mul_add _ _ _

/-- `Σ(c·v) = c·Σv`. -/
theorem total_scale (names : List String) (v : String → Rat) (c : Rat) :
    total names (fun n => c * v n) = c * total names v :=
  sum_map_mul_left names v c

/-- `Σ(v + v') = Σv + Σv'`. -/
theorem total_add (names : List String) (v v' : String → Rat) :
    total names (fun n => v n + v' n) = total names v + total names v' :=
  sum_map_add names v v'

/-! ## The laws of the reading -/

/-- **Projective invariance.** `holds R (c·v) = holds R v` for `c > 0`: the
reading sees the ray of a representative and not the representative. -/
theorem holds_scale {names : List String} {R : List Halfspace} {v : String → Rat}
    {c : Rat} (hc : 0 < c) :
    holds names R (fun n => c * v n) = holds names R v := by
  have hcone : inCone names (fun n => c * v n) = inCone names v := by
    unfold inCone
    rw [total_scale]
    congr 1
    · exact List.all_congr rfl fun n => by
        simp only [decide_eq_decide]
        exact mul_nonneg_iff_of_pos_left hc
    · simp only [decide_eq_decide]
      exact mul_pos_iff_of_pos_left hc
  have hall : R.all (·.holds names (fun n => c * v n)) = R.all (·.holds names v) :=
    List.all_congr rfl fun h => by
      unfold Halfspace.holds
      rw [total_scale, dot_scale, mul_left_comm, decide_eq_decide]
      exact mul_le_mul_iff_of_pos_left hc
  unfold holds
  rw [hcone, hall]

/-- **Convexity on representatives.** If `v` and `v'` both hold, so does
`v + v'`: the cone is convex, and each homogeneous half-space is a convex cone
of representatives. -/
theorem holds_add {names : List String} {R : List Halfspace} {v v' : String → Rat}
    (h₁ : holds names R v = true) (h₂ : holds names R v' = true) :
    holds names R (fun n => v n + v' n) = true := by
  simp only [holds, inCone, Halfspace.holds, Bool.and_eq_true, List.all_eq_true,
    decide_eq_true_eq] at h₁ h₂ ⊢
  obtain ⟨⟨hv, hT⟩, hR⟩ := h₁
  obtain ⟨⟨hv', hT'⟩, hR'⟩ := h₂
  refine ⟨⟨fun n hn => add_nonneg (hv n hn) (hv' n hn), ?_⟩, fun h hh => ?_⟩
  · rw [total_add]
    exact add_pos hT hT'
  · rw [total_add, dot_add, mul_add]
    exact add_le_add (hR h hh) (hR' h hh)

/-- **The homogeneous test is the test on the point.** On the cone,
`holds R v = ∀ (w,θ) ∈ R. ⟨w, π v⟩ ≥ θ`. -/
theorem holds_iff_normalized {names : List String} {R : List Halfspace}
    {v : String → Rat} (h : inCone names v = true) :
    holds names R v =
      R.all (fun h => decide (h.atLeast ≤ dot h.weights (normalize names v))) := by
  have hT : 0 < total names v := by
    simp only [inCone, Bool.and_eq_true, decide_eq_true_eq] at h
    exact h.2
  unfold holds
  rw [h, Bool.true_and]
  refine List.all_congr rfl fun hs => ?_
  have hnorm : normalize names v = fun n => (total names v)⁻¹ * v n := by
    funext n
    exact div_eq_inv_mul _ _
  unfold Halfspace.holds
  rw [hnorm, dot_scale, ← div_eq_inv_mul, decide_eq_decide]
  exact (le_div_iff₀ hT).symm

/-- **The reading lands in the simplex.** On the cone, `π v` is non-negative at
every option and has mass `1`. -/
theorem normalize_mem_simplex {names : List String} {v : String → Rat}
    (h : inCone names v = true) :
    (∀ n ∈ names, 0 ≤ normalize names v n) ∧ total names (normalize names v) = 1 := by
  simp only [inCone, Bool.and_eq_true, List.all_eq_true, decide_eq_true_eq] at h
  obtain ⟨hv, hT⟩ := h
  refine ⟨fun n hn => div_nonneg (hv n hn) hT.le, ?_⟩
  have hnorm : normalize names v = fun n => (total names v)⁻¹ * v n := by
    funext n
    exact div_eq_inv_mul _ _
  rw [hnorm, total_scale]
  exact inv_mul_cancel₀ hT.ne'

end Region

/-! ## The decision record inside a structured value -/

namespace Schema.Shape

/-- `[[s.numberFields]]` = the field names of `s` in declaration order when `s`
is a record every field of which is a `number`, and `none` otherwise. The empty
record answers `some []`. -/
def numberFields : Shape → Option (List String)
  | .object => some []
  | .property name .number rest => (numberFields rest).map (name :: ·)
  | _ => none

/-- `[[s.numberRecord v]]` = the entries of the value `v` of the number record
`s`, as (field name, number) pairs in declaration order, and `none` when `s` is
not a number record. Its names are `s.numberFields`
(`numberRecord_names`). -/
def numberRecord : (s : Shape) → s.El → Option (List (String × Rat))
  | .object, _ => some []
  | .property name .number rest, value => by
      change Rat × rest.El at value
      exact (numberRecord rest value.2).map ((name, value.1) :: ·)
  | _, _ => none

/-- `[[s.numberFieldsAt? p]]` = the options of the non-empty number record at
the field path `p` inside `s`, in declaration order. The empty path names `s`
itself. A path that leaves the records of `s`, or ends at anything other than a
non-empty record of numbers, names nothing. -/
def numberFieldsAt? : Shape → List String → Option (List String)
  | s, [] =>
    match s.numberFields with
    | some (n :: ns) => some (n :: ns)
    | _ => none
  | .property name schema rest, field :: path =>
    if name = field then numberFieldsAt? schema path
    else numberFieldsAt? rest (field :: path)
  | _, _ :: _ => none

/-- `[[s.recordAt p v]]` = the number record at the field path `p` inside the
value `v`, as its options and the record `n ↦ v n` (an unlisted name reads `0`),
or `none` exactly where `s.numberFieldsAt? p` is `none`. The options agree with
`numberFieldsAt?` (`recordAt_names`). -/
def recordAt : (s : Shape) → List String → s.El → Option (List String × (String → Rat))
  | s, [], value =>
    match s.numberRecord value with
    | some (e :: es) =>
      some ((e :: es).map Prod.fst, fun n => (((e :: es).lookup n)).getD 0)
    | _ => none
  | .property name schema rest, field :: path, value => by
      change schema.El × rest.El at value
      exact if name = field then recordAt schema path value.1
        else recordAt rest (field :: path) value.2
  | _, _ :: _, _ => none

/-- The names of a number record's entries are its field names. -/
theorem numberRecord_names (s : Shape) (value : s.El) :
    (s.numberRecord value).map (·.map Prod.fst) = s.numberFields := by
  induction s with
  | property name schema rest _ ihr =>
    cases schema with
    | number =>
      simp only [numberRecord, numberFields]
      rw [← ihr value.2]
      dsimp only [id]
      cases numberRecord rest value.2 <;> rfl
    | _ => rfl
  | _ => rfl

/-- At the empty path the options agree: the record a value reads is over the
field names of the schema. -/
private theorem recordAt_nil_names {s : Shape} {ns : List String} (value : s.El)
    (h : s.numberFieldsAt? [] = some ns) :
    (s.recordAt [] value).map Prod.fst = some ns := by
  have hn := numberRecord_names s value
  simp only [numberFieldsAt?] at h
  simp only [recordAt]
  split at h
  · rename_i n ns' hns
    cases h
    rw [hns] at hn
    cases hr : numberRecord s value with
    | none => rw [hr] at hn; cases hn
    | some es =>
      rw [hr] at hn
      cases es with
      | nil => cases hn
      | cons e es =>
        simp only [Option.map_some, Option.some.injEq] at hn
        simp [hn]
  · cases h

/-- **The options agree.** Where `numberFieldsAt?` names the options `ns` at a
path, `recordAt` reads a record over exactly `ns` from every value. -/
theorem recordAt_names {s : Shape} {p : List String} {ns : List String} (value : s.El)
    (h : s.numberFieldsAt? p = some ns) :
    (s.recordAt p value).map Prod.fst = some ns := by
  cases p with
  | nil => exact recordAt_nil_names value h
  | cons field path =>
    induction s generalizing field path ns with
    | property name schema rest ihs ihr =>
      simp only [numberFieldsAt?] at h
      simp only [recordAt]
      split
      · rename_i heq
        rw [if_pos heq] at h
        cases path with
        | nil => exact recordAt_nil_names value.1 h
        | cons f' p' => exact ihs value.1 f' p' h
      · rename_i hne
        rw [if_neg hne] at h
        exact ihr value.2 field path h
    | _ => simp [numberFieldsAt?] at h

end Schema.Shape

end Agentic.Core
