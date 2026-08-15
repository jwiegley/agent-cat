import Mathlib.Data.Fintype.Basic
import Mathlib.Data.Finset.Lattice.Fold
import Mathlib.Order.CompleteLattice.Basic
axiom Code : Type
axiom El : Code → Type
axiom Qq : Code → Type

inductive Dlg (A : Type) : Type
  | done : A → Dlg A
  | ask  : (c : Code) → Qq c → (El c → Dlg A) → Dlg A

-- (1) `under` as a signature endomorphism: does it typecheck and stay Type 0?
abbrev Sig := (c : Code) → Qq c → Qq c
def under (σ : Sig) {A} : Dlg A → Dlg A
  | .done a => .done a
  | .ask c q f => .ask c (σ c q) (fun x => under σ (f x))
#check @under

-- (2) worst-case cost as a fold: REQUIRES Fintype on every answer type.
def costMax [∀ c, Fintype (El c)] (price : (c : Code) → Qq c → ℕ) {A} : Dlg A → ℕ
  | .done _ => 0
  | .ask c q f => price c q + (Finset.univ.sup fun x => costMax price (f x))
#check @costMax

-- (3) without Fintype: no fold exists.  (uncomment to see the failure)
-- def costMax' (price : (c : Code) → Qq c → ℕ) {A} : Dlg A → ℕ
--   | .done _ => 0
--   | .ask c q f => price c q + (⨆ x, costMax' price (f x))   -- ⨆ over El c: not ℕ-valued/noncomputable
