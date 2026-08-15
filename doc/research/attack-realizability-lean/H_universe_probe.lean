axiom Qd : Type
axiom Ans : Qd → Type
inductive Sig : Type → Type where
  | ask : (q : Qd) → Sig (Ans q)

-- free monad over an arbitrary Type→Type signature
inductive FreeM (f : Type → Type) (A : Type) : Type 1 where
  | pure : A → FreeM f A
  | roll : {α : Type} → f α → (α → FreeM f A) → FreeM f A
#check @FreeM

-- Can it live in Type 0?  (expected: NO, α : Type is a field)
/-- error -/
inductive FreeM0 (f : Type → Type) (A : Type) : Type where
  | pure : A → FreeM0 f A
  | roll : {α : Type} → f α → (α → FreeM0 f A) → FreeM0 f A
