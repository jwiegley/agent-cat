import Agentic.Core.Question
import Mathlib.Logic.Function.Basic
import Mathlib.Order.Defs.PartialOrder

/-!
# Worlds: the total answer sheet, and the finite tables that approximate it

Rederivation kernel §1 (`Ω`), §3 q1 (what "the same question twice" means), §5
(the memo table as a finite world), §7 rows 3 and 6, and open question 7 (the
two-level dependent `pin` laws, written here rather than budgeted at zero).

Two objects and one map between them.

* `Ω`, the **total** answer sheet: a function from questions to answers. Equal
  questions therefore have one answer; occurrence multiplicity lives in traces.

* `Table`, a **finite partial** answer sheet over bare questions. Its extension
  preorder identifies shadowing and reordering that denote the same sheet.

* `worldOf`, the **defaulting totalization**, which exists because every `El c`
  is inhabited. It is what turns "the run logged these answers" into "there is a
  total world in which the plan means this", with no axiom and no `IO`.

`pin` is dependent `Function.update` at code and question; the laws below
re-derive its two-level behavior.
-/

namespace Agentic.Core

/-! ## The total answer sheet -/

/-- `[[Ω]]` = one complete answer sheet: a total function assigning one answer
to each question. Two occurrences of one question therefore agree in every
world; trace separately preserves occurrence count. -/
abbrev Ω : Type := (c : Code) → Q c → El c

/-- Counterfactual substitution: `[[pin ω c q a]] = ω except that q answers a`.
`Function.update` at the code level and again at the question level — fork,
resume and fixture-edit are three uses of this one operation (§7, `acat-vgz`).

Solved, not checked: the definition below is the unique one satisfying
`pin_same` and `pin_of_ne_*` together, which is `Function.update`'s own
characterization applied twice. -/
def pin (ω : Ω) (c : Code) (q : Q c) (a : El c) : Ω :=
  Function.update ω c (Function.update (ω c) q a)

variable {ω : Ω} {c c₁ c₂ : Code}

/-- Reading back the pinned question gives the pinned answer. -/
@[simp] theorem pin_same (c : Code) (q : Q c) (a : El c) : pin ω c q a c q = a := by
  simp [pin]

/-- Pinning is surgical along the question axis. -/
theorem pin_of_ne_q {q q' : Q c} (a : El c) (h : q' ≠ q) : pin ω c q a c q' = ω c q' := by
  simp [pin, Function.update_of_ne h]

/-- Pinning is surgical along the code axis. -/
theorem pin_of_ne_code {q : Q c₁} {q' : Q c₂} (a : El c₁) (h : c₂ ≠ c₁) :
    pin ω c₁ q a c₂ q' = ω c₂ q' := by
  simp [pin, Function.update_of_ne h]

/-- The later pin wins: re-editing one entry discards the earlier edit. -/
theorem pin_pin_same (q : Q c) (a b : El c) : pin (pin ω c q a) c q b = pin ω c q b := by
  simp [pin, Function.update_idem]

/-- Pinning an answer to what it already was changes nothing — the sense in
which a cache hit is the identity. -/
theorem pin_get (q : Q c) : pin ω c q (ω c q) = ω := by
  simp [pin, Function.update_eq_self]

/-- Pins at distinct codes commute. -/
theorem pin_pin_comm_of_code_ne {q₁ : Q c₁} {q₂ : Q c₂} (a : El c₁) (b : El c₂)
    (h : c₁ ≠ c₂) :
    pin (pin ω c₁ q₁ a) c₂ q₂ b = pin (pin ω c₂ q₂ b) c₁ q₁ a := by
  simp only [pin, Function.update_of_ne h, Function.update_of_ne (Ne.symm h)]
  exact Function.update_comm h _ _ _

/-- Pins at distinct questions of one code commute. -/
theorem pin_pin_comm_of_q_ne {q₁ q₂ : Q c} (a b : El c) (h : q₁ ≠ q₂) :
    pin (pin ω c q₁ a) c q₂ b = pin (pin ω c q₂ b) c q₁ a := by
  simp only [pin, Function.update_self, Function.update_idem]
  exact congrArg _ (Function.update_comm h _ _ _)

/-- **The fork law.** Pins at distinct questions commute, so a counterfactual
specified by a *set* of pinnings is well defined without an order. The keys are
compared as the pair they are, which is why the hypothesis is a `Sigma`
disequality. -/
theorem pin_pin_comm {q₁ : Q c₁} {q₂ : Q c₂} (a : El c₁) (b : El c₂)
    (h : (⟨c₁, q₁⟩ : (c : Code) × Q c) ≠ ⟨c₂, q₂⟩) :
    pin (pin ω c₁ q₁ a) c₂ q₂ b = pin (pin ω c₂ q₂ b) c₁ q₁ a := by
  by_cases hc : c₁ = c₂
  · subst hc
    exact pin_pin_comm_of_q_ne a b (fun hq => h (by subst hq; rfl))
  · exact pin_pin_comm_of_code_ne a b hc

/-! ## Finite partial answer sheets -/

/-- `[[Table]]` = a finite partial answer sheet: the answers a run has actually
heard, most recent first.

This is the memo table, and calling it a finite world is the whole of §5's
argument: an interpreter that consults it before asking discharges the
functionality condition *structurally*, so the adequacy theorem needs no
hypothesis about the agents. Later entries are shadowed by earlier ones, which
is why the extension order below is a preorder rather than an order. -/
def Table : Type := List ((c : Code) × Q c × El c)

namespace Table

/-- `[[Table.nil]]` = the empty partial sheet: nothing has been heard yet. -/
def nil : Table := []

/-- `[[Table.cons c q a t]]` = `t` overridden to answer `q` with `a`; the
`worldOf`-image of this is `pin`, which is `worldOf_cons`. -/
def cons (c : Code) (q : Q c) (a : El c) (t : Table) : Table := ⟨c, q, a⟩ :: t

end Table

/-- `[[lookup t c q]]` = what `t` records as the answer to `q`, if anything.
First entry wins, so `cons` records an answer without disturbing what the older
entries say about *other* questions. -/
def lookup : Table → (c : Code) → Q c → Option (El c)
  | [], _, _ => none
  | ⟨c', q', a'⟩ :: rest, c, q =>
      if h : c' = c then (if (h ▸ q' : Q c) = q then some (h ▸ a') else lookup rest c q)
      else lookup rest c q

@[simp] theorem lookup_nil (c : Code) (q : Q c) : lookup Table.nil c q = none := rfl

/-- The entry just recorded is the one found. -/
@[simp] theorem lookup_cons_self (t : Table) (c : Code) (q : Q c) (a : El c) :
    lookup (Table.cons c q a t) c q = some a := by
  simp [lookup, Table.cons]

/-- Recording an answer to `q` does not disturb another question of the same
code. -/
theorem lookup_cons_of_ne_q (t : Table) (c : Code) {q q' : Q c} (a : El c) (h : q' ≠ q) :
    lookup (Table.cons c q a t) c q' = lookup t c q' := by
  simp [lookup, Table.cons, Ne.symm h]

/-- Recording an answer at one code does not disturb another code. -/
theorem lookup_cons_of_ne_code (t : Table) {c c' : Code} (q : Q c) (q' : Q c') (a : El c)
    (h : c ≠ c') : lookup (Table.cons c q a t) c' q' = lookup t c' q' := by
  simp [lookup, Table.cons, h]

/-- **The memoization discipline, formalized** (`attack-realizability` §5.2):
prepending preserves the older lookups exactly when the new key was absent. This
one-line side condition is what the adequacy proof needs and what a
non-memoizing runtime does not have. -/
theorem lookup_cons_of {t : Table} {c c' : Code} {q : Q c} {q' : Q c'} {a : El c} {a' : El c'}
    (hnone : lookup t c q = none) (h : lookup t c' q' = some a') :
    lookup (Table.cons c q a t) c' q' = some a' := by
  rw [Table.cons, lookup]
  by_cases hc : c = c'
  · subst hc
    by_cases hq : q = q'
    · subst hq; rw [hnone] at h; exact absurd h (by simp)
    · simp [hq, h]
  · simp [hc, h]

/-! ## The extension order -/

/-- `t ≤ t'` = every answer `t` records, `t'` records too: the extension order
the kernel writes `⊑`. A preorder and not an order, because shadowing and
reordering give distinct lists denoting one partial sheet. -/
instance instPreorderTable : Preorder Table where
  le t t' := ∀ (c : Code) (q : Q c) (a : El c), lookup t c q = some a → lookup t' c q = some a
  le_refl _ _ _ _ h := h
  le_trans _ _ _ h₁ h₂ c q a h := h₂ c q a (h₁ c q a h)

theorem le_def {t t' : Table} :
    t ≤ t' ↔ ∀ (c : Code) (q : Q c) (a : El c), lookup t c q = some a → lookup t' c q = some a :=
  Iff.rfl

/-- The empty table is the bottom of the extension order. -/
theorem nil_le (t : Table) : Table.nil ≤ t := by
  intro c q a h; rw [lookup_nil] at h; exact absurd h (by simp)

/-- Recording an answer *extends* the table exactly when the key was absent —
the order-theoretic reading of `lookup_cons_of`. -/
theorem le_cons_of_lookup_none {t : Table} {c : Code} {q : Q c} (a : El c)
    (hnone : lookup t c q = none) : t ≤ Table.cons c q a t :=
  fun _ _ _ h => lookup_cons_of hnone h

/-- Recording an already-present answer also extends the table by shadowing the
same question with the same value. -/
theorem le_cons_of_lookup_eq {t : Table} {c : Code} {q : Q c} {a : El c}
    (hsome : lookup t c q = some a) : t ≤ Table.cons c q a t := by
  intro c' q' a' h
  by_cases hc : c = c'
  · subst c'
    by_cases hq : q' = q
    · subst q'
      rw [lookup_cons_self]
      exact hsome.symm.trans h
    · rw [lookup_cons_of_ne_q t c a hq]
      exact h
  · rw [lookup_cons_of_ne_code t q q' a hc]
    exact h

/-- An acknowledgement may be recorded again without invalidating an older table:
its answer type is `Unit`, so the repeated value is necessarily the same. This is
the extension fact used when every effect occurrence is executed and recorded. -/
theorem le_cons_ack (t : Table) (q : Q .ack) :
    t ≤ Table.cons .ack q () t := by
  cases h : lookup t .ack q with
  | none => exact le_cons_of_lookup_none (c := .ack) (q := q) () h
  | some a =>
    cases a
    exact le_cons_of_lookup_eq (c := .ack) (q := q) h

/-! ## From a partial sheet to a total one -/

/-- `Extends ω t` = the total world `ω` agrees with everything `t` recorded.
This is the hypothesis of the adequacy theorem and the conclusion of the
certificate. -/
def Extends (ω : Ω) (t : Table) : Prop :=
  ∀ (c : Code) (q : Q c) (a : El c), lookup t c q = some a → ω c q = a

/-- Every world extends the empty table. -/
theorem extends_nil (ω : Ω) : Extends ω Table.nil := by
  intro c q a h; rw [lookup_nil] at h; exact absurd h (by simp)

/-- **Extension is antitone in the hypothesis**: agreeing with a bigger table is
a stronger condition. -/
theorem Extends.mono {ω : Ω} {t t' : Table} (hle : t ≤ t') (h : Extends ω t') : Extends ω t :=
  fun c q a hq => h c q a (hle c q a hq)

/-- What a world extending `cons` says about the recorded question. -/
theorem Extends.head {ω : Ω} {t : Table} {c : Code} {q : Q c} {a : El c}
    (h : Extends ω (Table.cons c q a t)) : ω c q = a :=
  h c q a (lookup_cons_self t c q a)

/-- Recording what an extending world already says preserves extension. -/
theorem Extends.cons {ω : Ω} {t : Table} (h : Extends ω t)
    (c : Code) (q : Q c) : Extends ω (Table.cons c q (ω c q) t) := by
  intro c₀ q₀ a₀ ha
  by_cases hc : c = c₀
  · subst hc
    by_cases hq : q₀ = q
    · subst hq
      rw [lookup_cons_self] at ha
      exact (Option.some.inj ha) ▸ rfl
    · rw [lookup_cons_of_ne_q t c _ hq] at ha
      exact h c q₀ a₀ ha
  · rw [lookup_cons_of_ne_code t q q₀ _ hc] at ha
    exact h c₀ q₀ a₀ ha

/-- `[[worldOf t]]` = the total answer sheet that says what `t` says and
defaults elsewhere. It exists because every `El c` is inhabited, and it is the
whole of why a run can exhibit a world without `IO` being modelled. -/
def worldOf (t : Table) : Ω := fun c q => (lookup t c q).getD default

/-- **Morphism equation for the totalization**: `worldOf` is a section of the
extension relation — the defaulted world does extend the table it came from. -/
theorem worldOf_extends (t : Table) : Extends (worldOf t) t := by
  intro c q a h; simp [worldOf, h]

/-- **Morphism equation.** Recording an answer is pinning it: `worldOf` takes
`cons` to `pin`, so the table's `cons` and the world's counterfactual update are
the same operation seen at the two levels. -/
theorem worldOf_cons (t : Table) (c : Code) (q : Q c) (a : El c) :
    worldOf (Table.cons c q a t) = pin (worldOf t) c q a := by
  funext c₀ q₀
  by_cases hc : c = c₀
  · subst hc
    by_cases hq : q₀ = q
    · subst hq; simp [worldOf, pin_same]
    · rw [worldOf, lookup_cons_of_ne_q t c a hq, pin_of_ne_q a hq]; rfl
  · rw [worldOf, lookup_cons_of_ne_code t q q₀ a hc, pin_of_ne_code a (Ne.symm hc)]; rfl

end Agentic.Core
