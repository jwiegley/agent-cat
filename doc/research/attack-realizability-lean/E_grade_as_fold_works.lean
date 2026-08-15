import Mathlib.Algebra.Group.Defs
axiom Qs : Type
axiom R : Qs → Type
inductive Grade | ap | sel | mon
deriving DecidableEq
def Grade.join : Grade → Grade → Grade
  | .mon, _ | _, .mon => .mon
  | .sel, _ | _, .sel => .sel
  | .ap, .ap => .ap
instance : Max Grade := ⟨Grade.join⟩

-- REPAIR 1: unindexed term + grade as a fold (the meaning-first shape)
inductive T : Type → Type 1 where
  | pure   {A} : A → T A
  | ask    : (q : Qs) → T (R q)
  | ap     {A B} : T (A → B) → T A → T B
  | select {A B} : T (Sum A B) → T (A → B) → T B
  | bind   {A B} : T A → (A → T B) → T B

def grade : {A : Type} → T A → Grade
  | _, .pure _ => .ap
  | _, .ask _ => .ap
  | _, .ap f x => max (grade f) (grade x)
  | _, .select c f => max (max (grade c) (grade f)) .sel
  | _, .bind _ _ => .mon

def asks {S : Type} [Monoid S] (price : Qs → S) : {A : Type} → T A → Option S
  | _, .pure _ => some 1
  | _, .ask q => some (price q)
  | _, .ap f x => do let a ← asks price f; let b ← asks price x; pure (a*b)
  | _, .select _ _ => none
  | _, .bind _ _ => none

theorem asks_total_at_ap {S : Type} [Monoid S] (price : Qs → S) :
    ∀ {A : Type} (w : T A), grade w = .ap → (asks price w).isSome := by
  intro A w h
  induction w with
  | pure a => simp [asks]
  | ask q => simp [asks]
  | ap f x ihf ihx =>
      simp [grade] at h
      have hf : grade f = .ap := by
        cases hg : grade f <;> cases hg' : grade x <;> simp_all [grade, Max.max, Grade.join]
      have hx : grade x = .ap := by
        cases hg : grade f <;> cases hg' : grade x <;> simp_all [grade, Max.max, Grade.join]
      simp [asks, Option.isSome_iff_exists] at *
      obtain ⟨a, ha⟩ := ihf hf; obtain ⟨b, hb⟩ := ihx hx
      exact ⟨a*b, by simp [ha, hb]⟩
  | select c f _ _ => simp [grade, Max.max, Grade.join] at h; cases hg : grade c <;> cases hg' : grade f <;> simp_all
  | bind _ _ _ _ => simp [grade] at h
#print axioms asks_total_at_ap
