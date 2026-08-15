/- Per-run certificate: adequacy becomes a decidable CHECK on the logged table,
   so IO need not be axiomatized at all. -/
axiom Code : Type
axiom El : Code → Type
axiom Qq : Code → Type
variable [DecidableEq Code] [∀ c, DecidableEq (Qq c)] [∀ c, Inhabited (El c)]

inductive Dlg (A : Type) : Type
  | done : A → Dlg A
  | ask  : (c : Code) → Qq c → (El c → Dlg A) → Dlg A

abbrev World := (c : Code) → Qq c → El c
def run (w : World) {A} : Dlg A → A
  | .done a => a
  | .ask c q f => run w (f (w c q))

abbrev Table := List ((c : Code) × (q : Qq c) × El c)
def lookupT [DecidableEq Code] [∀ c, DecidableEq (Qq c)]
    (t : Table) (c : Code) (q : Qq c) : Option (El c) :=
  match t with
  | [] => none
  | ⟨c', q', a'⟩ :: rest =>
      if h : c' = c then (if (h ▸ q' : Qq c) = q then some (h ▸ a') else lookupT rest c q)
      else lookupT rest c q

/-- Any total world extending the logged table (default elsewhere). -/
def worldOf [DecidableEq Code] [∀ c, DecidableEq (Qq c)] [∀ c, Inhabited (El c)]
    (t : Table) : World := fun c q => (lookupT t c q).getD default

/-- COMPUTABLE certificate: replay the logged answers against the pure meaning. -/
def certify [DecidableEq Code] [∀ c, DecidableEq (Qq c)] [∀ c, Inhabited (El c)]
    {A} [DecidableEq A] (p : Dlg A) (t : Table) (a : A) : Bool :=
  decide (run (worldOf t) p = a)

theorem certify_sound [DecidableEq Code] [∀ c, DecidableEq (Qq c)] [∀ c, Inhabited (El c)]
    {A} [DecidableEq A] (p : Dlg A) (t : Table) (a : A) :
    certify p t a = true → ∃ w : World, run w p = a :=
  fun h => ⟨worldOf t, of_decide_eq_true h⟩
#print axioms certify_sound
