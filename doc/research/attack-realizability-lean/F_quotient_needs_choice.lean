import Mathlib.Data.Quot
axiom Qs : Type
axiom R : Qs → Type
inductive Grade | ap | sel | mon deriving DecidableEq
def Grade.join : Grade → Grade → Grade
  | .mon, _ | _, .mon => .mon
  | .sel, _ | _, .sel => .sel
  | .ap, .ap => .ap
instance : Max Grade := ⟨Grade.join⟩

-- REPAIR 2: equation field on the index
inductive V : Grade → Type → Type 1 where
  | pure {A} : A → V .ap A
  | ask : (q : Qs) → V .ap (R q)
  | ap {A B g g' h} : h = max g g' → V g (A → B) → V g' A → V h B

example {A : Type} (w : V .ap A) : True := by
  cases w with
  | pure a => trivial
  | ask q => trivial
  | ap heq f x => trivial     -- eliminates fine now; `heq : Grade.ap = max g g'` is usable

-- Quotiented-free monad: `bind` on the quotient needs a representative -> choice
inductive T : Type → Type 1 where
  | pure {A} : A → T A
  | ask : (q : Qs) → T (R q)
  | bind {A B} : T A → (A → T B) → T B
axiom rel : {A : Type} → T A → T A → Prop
axiom relEq : ∀ {A}, Equivalence (@rel A)
noncomputable instance stp (A : Type) : Setoid (T A) := ⟨rel, relEq⟩
abbrev QT (A : Type) := Quotient (stp A)
noncomputable def qbind {A B} (w : QT A) (k : A → QT B) : QT B :=
  Quotient.mk _ (T.bind w.out (fun a => (k a).out))
#print axioms qbind
