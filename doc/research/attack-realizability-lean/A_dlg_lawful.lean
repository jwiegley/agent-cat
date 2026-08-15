/- Meaning-first kernel: does it actually build, lawfully, in Type 0? -/
axiom Code : Type
axiom El : Code → Type
axiom Qq : Code → Type

inductive Dlg (A : Type) : Type
  | done : A → Dlg A
  | ask  : (c : Code) → Qq c → (El c → Dlg A) → Dlg A

namespace Dlg
def bind {A B} : Dlg A → (A → Dlg B) → Dlg B
  | .done a,     k => k a
  | .ask c q f,  k => .ask c q (fun x => bind (f x) k)

instance : Monad Dlg where
  pure := .done
  bind := bind

theorem bind_pure {A} (p : Dlg A) : bind p (fun a => .done a) = p := by
  induction p with
  | done a => rfl
  | ask c q f ih => simp [bind]; funext x; exact ih x

theorem bind_assoc {A B C} (p : Dlg A) (k : A → Dlg B) (h : B → Dlg C) :
    bind (bind p k) h = bind p (fun a => bind (k a) h) := by
  induction p with
  | done a => rfl
  | ask c q f ih => simp [bind]; funext x; exact ih x

instance : LawfulMonad Dlg := by
  apply LawfulMonad.mk' (m := Dlg)
  · intro α x; induction x with
    | done a => rfl
    | ask c q f ih => simp [Functor.map, bind]; funext y; exact ih y
  · intro α β x f; rfl
  · intro α β γ x f g
    exact bind_assoc x f g

/- the world, run, trace -/
def World := (c : Code) → Qq c → El c

def run (w : World) {A} : Dlg A → A
  | .done a => a
  | .ask c q f => run w (f (w c q))

structure Event where
  c : Code
  q : Qq c
  a : El c

def trace (w : World) {A} : Dlg A → List Event
  | .done _ => []
  | .ask c q f => ⟨c, q, w c q⟩ :: trace w (f (w c q))

theorem run_bind (w : World) {A B} (p : Dlg A) (k : A → Dlg B) :
    run w (bind p k) = run w (k (run w p)) := by
  induction p with
  | done a => rfl
  | ask c q f ih => simp [bind, run]; exact ih _

theorem trace_bind (w : World) {A B} (p : Dlg A) (k : A → Dlg B) :
    trace w (bind p k) = trace w p ++ trace w (k (run w p)) := by
  induction p with
  | done a => rfl
  | ask c q f ih => simp [bind, trace, run]; exact ih _

#print axioms bind_pure
#print axioms trace_bind
