import Mathlib.Control.Applicative
axiom Qs : Type
axiom R : Qs → Type
inductive Grade | ap | sel | mon
deriving DecidableEq
def Grade.join : Grade → Grade → Grade
  | .mon, _ | _, .mon => .mon
  | .sel, _ | _, .sel => .sel
  | .ap, .ap => .ap
instance : Max Grade := ⟨Grade.join⟩

inductive W : Grade → Type → Type 1 where
  | pure   {A} : A → W .ap A
  | ask    : (q : Qs) → W .ap (R q)
  | ap     {A B g g'} : W g (A → B) → W g' A → W (max g g') B
  | select {A B g g'} : W g (Sum A B) → W g' (A → B) → W (max (max g g') .sel) B
  | bind   {A B g g'} : W g A → (A → W g' B) → W .mon B

-- (a) total fold over ALL grades, junk at select/bind
def asks {S : Type} [Monoid S] (price : Qs → S) : {g : Grade} → {A : Type} → W g A → Option S
  | _, _, .pure _ => some 1
  | _, _, .ask q => some (price q)
  | _, _, .ap wf wx => do let a ← asks price wf; let b ← asks price wx; pure (a*b)
  | _, _, .select _ _ => none
  | _, _, .bind _ _ => none

-- and then the theorem you actually wanted has to be proved, not typed:
theorem asks_total_at_ap : ∀ {A : Type} (w : W .ap A) {S : Type} [Monoid S] (price : Qs → S),
    (asks price w).isSome := by
  intro A w S _ price
  cases w with
  | pure a => simp [asks]
  | ask q => simp [asks]
  | ap wf wx => sorry
  | select a b => sorry
  | bind a b => sorry
#print axioms asks_total_at_ap
