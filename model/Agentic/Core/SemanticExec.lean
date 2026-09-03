import Agentic.Core.Denote

/-!
# Semantic interpreter over bare-question dialogues

This is the K1/K6 interpreter: one answer per semantic question. Execution
intent is absent and belongs to `AnnotatedExec`.
-/

namespace Agentic.Core

abbrev Oracle (m : Type → Type) : Type := (c : Code) → Q c → Table → m (El c)

abbrev OracleM : Type → Type := StateT Table IO

/-- Memoizing interpreter of the bare-question dialogue. -/
def Dlg.execM {m : Type → Type} [Monad m] {A : Type} (o : Oracle m) :
    Dlg A → Table → m (A × Table)
  | .done a, t => pure (a, t)
  | .ask c q f, t =>
      match lookup t c q with
      | some a => Dlg.execM o (f a) t
      | none => do
          let a ← o c q t
          Dlg.execM o (f a) (Table.cons c q a t)

namespace Dlg

variable {m : Type → Type} [Monad m] {A : Type}

@[simp] theorem execM_done (o : Oracle m) (a : A) (t : Table) :
    execM o (.done a) t = pure (a, t) := rfl

theorem execM_ask_hit (o : Oracle m) (c : Code) (q : Q c) (f : El c → Dlg A)
    {t : Table} {a : El c} (h : lookup t c q = some a) :
    execM o (.ask c q f) t = execM o (f a) t := by
  rw [execM, h]

theorem execM_ask_miss (o : Oracle m) (c : Code) (q : Q c) (f : El c → Dlg A)
    {t : Table} (h : lookup t c q = none) :
    execM o (.ask c q f) t =
      o c q t >>= fun a => execM o (f a) (Table.cons c q a t) := by
  rw [execM, h]

end Dlg

/-- The semantic answer table only grows. -/
theorem execM_le {A : Type} (o : Oracle Id) (p : Dlg A) :
    ∀ t : Table, t ≤ (Dlg.execM o p t).2 := by
  induction p with
  | done a => intro t; exact le_refl t
  | ask c q f ih =>
    intro t
    rw [Dlg.execM]
    cases ha : lookup t c q with
    | some a => simpa using ih a t
    | none =>
      simp only []
      exact le_trans (le_cons_of_lookup_none _ ha) (ih _ _)

/-- Every successful Id-oracle run denotes in every world extending its table. -/
theorem execM_adequacy {A : Type} (o : Oracle Id) (p : Dlg A) :
    ∀ t : Table,
      (∀ ω, Extends ω (Dlg.execM o p t).2 → Extends ω t) ∧
      (∀ ω, Extends ω (Dlg.execM o p t).2 →
        Dlg.run ω p = (Dlg.execM o p t).1) := by
  induction p with
  | done a => intro t; exact ⟨fun _ h => h, fun _ _ => rfl⟩
  | ask c q f ih =>
    intro t
    rw [Dlg.execM]
    cases ha : lookup t c q with
    | some a =>
      simp only []
      obtain ⟨h1, h2⟩ := ih a t
      refine ⟨h1, fun ω hω => ?_⟩
      have hωa : ω c q = a := h1 ω hω c q a ha
      rw [Dlg.run_ask, hωa]
      exact h2 ω hω
    | none =>
      simp only []
      obtain ⟨h1, h2⟩ := ih (o c q t) (Table.cons c q (o c q t) t)
      refine ⟨fun ω hω c₀ q₀ a₀ hf =>
        h1 ω hω c₀ q₀ a₀ (lookup_cons_of ha hf), fun ω hω => ?_⟩
      have hωa : ω c q = o c q t :=
        h1 ω hω c q _ (lookup_cons_self t c q (o c q t))
      rw [Dlg.run_ask, hωa]
      exact h2 ω hω

/-- The oracle that is a bare-question world. -/
def pureOracle (ω : Ω) : Oracle Id := fun c q _ => pure (ω c q)

theorem Dlg.mem_trace_answer {A : Type} (ω : Ω) (p : Dlg A) :
    ∀ e ∈ Dlg.trace ω p, ω e.c e.q = e.a := by
  induction p with
  | done a => intro e he; simp at he
  | ask c q f ih =>
    intro e he
    rw [Dlg.trace_ask, List.mem_cons] at he
    rcases he with rfl | he
    · rfl
    · exact ih _ e he

/-- Pure factorization: value, extending table, and transcript coverage. -/
theorem execM_pure {A : Type} (ω : Ω) (p : Dlg A) :
    ∀ t : Table, Extends ω t →
      (Dlg.execM (pureOracle ω) p t).1 = Dlg.run ω p ∧
      Extends ω (Dlg.execM (pureOracle ω) p t).2 ∧
      ∀ e ∈ Dlg.trace ω p,
        lookup (Dlg.execM (pureOracle ω) p t).2 e.c e.q = some e.a := by
  induction p with
  | done a => intro t ht; exact ⟨rfl, ht, by simp⟩
  | ask c q f ih =>
    intro t ht
    rw [Dlg.execM]
    cases ha : lookup t c q with
    | some a =>
      simp only []
      have hωa : ω c q = a := ht c q a ha
      obtain ⟨h1, h2, h3⟩ := ih a t ht
      refine ⟨by rw [Dlg.run_ask, hωa]; exact h1, h2, ?_⟩
      intro e he
      rw [Dlg.trace_ask, List.mem_cons] at he
      rcases he with rfl | he
      · have hle : t ≤ (Dlg.execM (pureOracle ω) (f a) t).2 := execM_le _ _ t
        exact (hle c q a ha).trans (by rw [hωa])
      · rw [hωa] at he
        exact h3 e he
    | none =>
      simp only []
      have hcons : Extends ω (Table.cons c q (ω c q) t) := ht.cons c q
      obtain ⟨h1, h2, h3⟩ := ih (ω c q) (Table.cons c q (ω c q) t) hcons
      refine ⟨by rw [Dlg.run_ask]; exact h1, h2, ?_⟩
      intro e he
      rw [Dlg.trace_ask, List.mem_cons] at he
      rcases he with rfl | he
      · have hle : Table.cons c q (ω c q) t
            ≤ (Dlg.execM (pureOracle ω) (f (ω c q))
                (Table.cons c q (ω c q) t)).2 := execM_le _ _ _
        exact hle c q (ω c q) (lookup_cons_self t c q (ω c q))
      · exact h3 e he

/-- `worldOf` of a pure run agrees with its source world on semantic trace. -/
theorem worldOf_execM_pure {A : Type} (ω : Ω) (p : Dlg A)
    (t : Table) (ht : Extends ω t) :
    ∀ e ∈ Dlg.trace ω p,
      worldOf (Dlg.execM (pureOracle ω) p t).2 e.c e.q = ω e.c e.q := by
  intro e he
  have h := (execM_pure ω p t ht).2.2 e he
  rw [worldOf, h, Option.getD_some, Dlg.mem_trace_answer ω p e he]

/-- Interpret a Plan through its erasing denotation and semantic memo table. -/
def Plan.execWith {m : Type → Type} [Monad m] {Γ : Ctx} {A : Type}
    (o : Oracle m) (p : Plan Γ A) (γ : Env Γ) (t : Table) : m (A × Table) :=
  Dlg.execM o (denote p γ) t

@[simp] theorem Plan.execWith_eq_execM_denote {m : Type → Type} [Monad m]
    {Γ : Ctx} {A : Type} (o : Oracle m) (p : Plan Γ A) (γ : Env Γ) (t : Table) :
    Plan.execWith o p γ t = Dlg.execM o (denote p γ) t := rfl

/-- Pure semantic interpreter. -/
def Plan.execPure {Γ : Ctx} {A : Type} (ω : Ω) (p : Plan Γ A) (γ : Env Γ) :
    Table → A × Table :=
  Plan.execWith (pureOracle ω) p γ

theorem Plan.execPure_fst {A : Type} (ω : Ω) (p : Plan [] A) :
    (Plan.execPure ω p Env.nil Table.nil).1 = Plan.run ω p Env.nil :=
  (execM_pure ω (denote p Env.nil) Table.nil (extends_nil ω)).1

theorem Plan.worldOf_execPure {A : Type} (ω : Ω) (p : Plan [] A) :
    ∀ e ∈ Plan.trace ω p Env.nil,
      worldOf (Plan.execPure ω p Env.nil Table.nil).2 e.c e.q = ω e.c e.q :=
  worldOf_execM_pure ω (denote p Env.nil) Table.nil (extends_nil ω)

theorem Plan.execWith_adequacy {A : Type} (o : Oracle Id) (p : Plan [] A)
    (ω : Ω) (h : Extends ω (Plan.execWith o p Env.nil Table.nil).2) :
    Plan.run ω p Env.nil = (Plan.execWith o p Env.nil Table.nil).1 :=
  (execM_adequacy o (denote p Env.nil) Table.nil).2 ω h

end Agentic.Core
