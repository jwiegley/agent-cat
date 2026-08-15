axiom Code : Type
axiom El : Code → Type
axiom Qq : Code → Type
variable [DecidableEq Code] [∀ c, DecidableEq (Qq c)]

inductive Dlg (A : Type) : Type
  | done : A → Dlg A
  | ask  : (c : Code) → Qq c → (El c → Dlg A) → Dlg A

abbrev World := (c : Code) → Qq c → El c
def run (w : World) {A} : Dlg A → A
  | .done a => a
  | .ask c q f => run w (f (w c q))

abbrev Hist := List ((c : Code) × Qq c)
abbrev Strategy := Hist → (c : Code) → (q : Qq c) → El c
abbrev Table := List ((c : Code) × (q : Qq c) × El c)
def hist (t : Table) : Hist := t.map (fun e => ⟨e.1, e.2.1⟩)

def lookupT [DecidableEq Code] [∀ c, DecidableEq (Qq c)]
    (t : Table) (c : Code) (q : Qq c) : Option (El c) :=
  match t with
  | [] => none
  | ⟨c', q', a'⟩ :: rest =>
      if h : c' = c then (if (h ▸ q' : Qq c) = q then some (h ▸ a') else lookupT rest c q)
      else lookupT rest c q

def exec [DecidableEq Code] [∀ c, DecidableEq (Qq c)] (σ : Strategy) {A : Type} :
    Table → Dlg A → Table × A
  | t, .done a => (t, a)
  | t, .ask c q f =>
      match lookupT t c q with
      | some a => exec σ t (f a)
      | none   => exec σ (⟨c, q, σ (hist t) c q⟩ :: t) (f (σ (hist t) c q))

def Extends (w : World) (t : Table) : Prop := ∀ c q a, lookupT t c q = some a → w c q = a

theorem lookup_cons_self (t : Table) (c : Code) (q : Qq c) (a : El c) :
    lookupT (⟨c, q, a⟩ :: t) c q = some a := by simp [lookupT]

theorem lookup_cons_of {t : Table} {c c' : Code} {q : Qq c} {q' : Qq c'} {a' : El c'}
    {a : El c} (hnone : lookupT t c' q' = none) (h : lookupT t c q = some a) :
    lookupT (⟨c', q', a'⟩ :: t) c q = some a := by
  rw [lookupT]
  by_cases hc : c' = c
  · subst hc
    by_cases hq : q' = q
    · subst hq; rw [hnone] at h; exact absurd h (by simp)
    · simp [hq, h]
  · simp [hc, h]

theorem adequacy (σ : Strategy) {A : Type} : ∀ (p : Dlg A) (t : Table),
    (∀ w, Extends w (exec σ t p).1 → Extends w t) ∧
    (∀ w, Extends w (exec σ t p).1 → run w p = (exec σ t p).2)
  | .done a, t => ⟨fun _ h => h, fun _ _ => rfl⟩
  | .ask c q f, t => by
      rw [exec]
      cases ha : lookupT t c q with
      | some a =>
        simp only []
        obtain ⟨h1, h2⟩ := adequacy σ (f a) t
        exact ⟨h1, fun w hw => by
          have hwa : w c q = a := h1 w hw c q a ha
          show run w (f (w c q)) = _
          rw [hwa]; exact h2 w hw⟩
      | none =>
        simp only []
        obtain ⟨h1, h2⟩ := adequacy σ (f (σ (hist t) c q)) (⟨c, q, σ (hist t) c q⟩ :: t)
        refine ⟨fun w hw c₀ q₀ a₀ hf => h1 w hw c₀ q₀ a₀ (lookup_cons_of ha hf), fun w hw => ?_⟩
        have hwa := h1 w hw c q _ (lookup_cons_self t c q _)
        show run w (f (w c q)) = _
        rw [hwa]; exact h2 w hw

#print axioms adequacy
