import Agentic.Core.SemanticExec

/-!
# Sequential reference execution of annotated Plans

Intent is interpreted here, below denotation. Reusable identity is the authored
bare question; effects bypass memo. Production scheduling remains Haskell and is
accepted empirically against these representation observations.
-/

namespace Agentic.Core

/-- Operational answering service sees the authored annotation and semantic
answer table. -/
abbrev ExecOracle (m : Type → Type) : Type :=
  (c : Code) → Request c → Table → m (El c)

/-- Result of one annotated Plan execution. -/
structure ExecResult (A : Type) where
  value : A
  table : Table
  trace : ExecTrace

/-- Put or reuse one annotated occurrence. Memo identity is bare `Q`; the memo
stores only its typed answer, while the caller constructs the current event. -/
def execRequest {m : Type → Type} [Monad m] (o : ExecOracle m)
    (c : Code) (r : Request c) (t : Table) :
    m (El c × Table × AnswerSource c) :=
  if r.isEffect then do
    let a ← o c r t
    pure (a, t, .asked r.question)
  else
    match lookup t c r.question with
    | some a => pure (a, t, .reused)
    | none => do
        let a ← o c r t
        pure (a, Table.cons c r.question a t, .asked r.question)

/-- Operational interpretation algebra for the annotated Plan signature. -/
def execAnnotatedAlg {m : Type → Type} [Monad m] (o : ExecOracle m) :
    PlanAlg (fun Γ A => Env Γ → Table → m (ExecResult A)) where
  ret e := fun γ t => pure ⟨e γ, t, []⟩
  askC c r k := fun γ t => do
    let (a, t', source) ← execRequest o c r t
    let result ← k (.cons a γ) t'
    pure ⟨result.value, result.table, ⟨c, r, source, a⟩ :: result.trace⟩
  ask c s e k := fun γ t => do
    let r := s.withPrompt (e γ)
    let (a, t', source) ← execRequest o c r t
    let result ← k (.cons a γ) t'
    pure ⟨result.value, result.table, ⟨c, r, source, a⟩ :: result.trace⟩
  case := fun _ e arms γ t => arms (e γ) γ t
  dyn := fun _ e f γ t => f (e γ) γ t

/-- Sequential reference realization of the five-form annotated Plan. -/
def Plan.execAnnotatedM {m : Type → Type} [Monad m] (o : ExecOracle m)
    (p : Plan Γ A) (γ : Env Γ) (t : Table) : m (ExecResult A) :=
  (execAnnotatedAlg o).fold p γ t

/-- Operational oracle induced by a semantic world. -/
def pureExecOracle (ω : Ω) : ExecOracle Id :=
  fun c r _ => pure (ω c r.question)

/-- Pure K5 interpretation of one annotated occurrence. -/
def execRequestPure (ω : Ω) (c : Code) (r : Request c) (t : Table) :
    El c × Table × AnswerSource c :=
  if r.isEffect then
    let a := ω c r.question
    (a, t, .asked r.question)
  else
    match lookup t c r.question with
    | some a => (a, t, .reused)
    | none =>
      let a := ω c r.question
      (a, Table.cons c r.question a t, .asked r.question)

/-- K5 pure annotated executor algebra. The monadic executor above is an IO-side
realization; this algebra is the checker-owned operation definition. -/
def execAnnotatedAlgPure (ω : Ω) :
    PlanAlg (fun Γ A => Env Γ → Table → ExecResult A) where
  ret e := fun γ t => ⟨e γ, t, []⟩
  askC c r k := fun γ t =>
    let (a, t', source) := execRequestPure ω c r t
    let result := k (.cons a γ) t'
    ⟨result.value, result.table, ⟨c, r, source, a⟩ :: result.trace⟩
  ask c s e k := fun γ t =>
    let r := s.withPrompt (e γ)
    let (a, t', source) := execRequestPure ω c r t
    let result := k (.cons a γ) t'
    ⟨result.value, result.table, ⟨c, r, source, a⟩ :: result.trace⟩
  case := fun _ e arms γ t => arms (e γ) γ t
  dyn := fun _ e f γ t => f (e γ) γ t

/-- Actual pure K5 specialization of the annotated executor. -/
def Plan.execAnnotated {Γ : Ctx} {A : Type} (ω : Ω)
    (p : Plan Γ A) (γ : Env Γ) (t : Table) : ExecResult A :=
  (execAnnotatedAlgPure ω).fold p γ t

@[simp] theorem Plan.execAnnotated_ret (ω : Ω) (e : Expr Γ A)
    (γ : Env Γ) (t : Table) :
    Plan.execAnnotated ω (.ret e) γ t = ⟨e γ, t, []⟩ := rfl

@[simp] theorem Plan.execAnnotated_askC (ω : Ω) (c : Code) (r : Request c)
    (k : Plan (c :: Γ) A) (γ : Env Γ) (t : Table) :
    Plan.execAnnotated ω (.askC c r k) γ t =
      if r.isEffect then
        let a := ω c r.question
        let result := Plan.execAnnotated ω k (.cons a γ) t
        ⟨result.value, result.table, ⟨c, r, .asked r.question, a⟩ :: result.trace⟩
      else
        match lookup t c r.question with
        | some a =>
          let result := Plan.execAnnotated ω k (.cons a γ) t
          ⟨result.value, result.table, ⟨c, r, .reused, a⟩ :: result.trace⟩
        | none =>
          let a := ω c r.question
          let result := Plan.execAnnotated ω k (.cons a γ)
            (Table.cons c r.question a t)
          ⟨result.value, result.table, ⟨c, r, .asked r.question, a⟩ :: result.trace⟩ := by
  unfold Plan.execAnnotated
  rw [PlanAlg.fold_askC]
  simp only [execAnnotatedAlgPure]
  unfold execRequestPure
  cases he : r.isEffect
  · cases hq : lookup t c r.question <;> rfl
  · rfl

@[simp] theorem Plan.execAnnotated_ask (ω : Ω) (c : Code)
    (s : Request.Shape c) (e : Expr Γ String) (k : Plan (c :: Γ) A)
    (γ : Env Γ) (t : Table) :
    let r := s.withPrompt (e γ)
    Plan.execAnnotated ω (.ask c s e k) γ t =
      if r.isEffect then
        let a := ω c r.question
        let result := Plan.execAnnotated ω k (.cons a γ) t
        ⟨result.value, result.table, ⟨c, r, .asked r.question, a⟩ :: result.trace⟩
      else
        match lookup t c r.question with
        | some a =>
          let result := Plan.execAnnotated ω k (.cons a γ) t
          ⟨result.value, result.table, ⟨c, r, .reused, a⟩ :: result.trace⟩
        | none =>
          let a := ω c r.question
          let result := Plan.execAnnotated ω k (.cons a γ)
            (Table.cons c r.question a t)
          ⟨result.value, result.table, ⟨c, r, .asked r.question, a⟩ :: result.trace⟩ := by
  dsimp only
  unfold Plan.execAnnotated
  rw [PlanAlg.fold_ask]
  simp only [execAnnotatedAlgPure]
  generalize hr : s.withPrompt (e γ) = r
  unfold execRequestPure
  cases he : r.isEffect
  · cases hq : lookup t c r.question <;> rfl
  · rfl

@[simp] theorem Plan.execAnnotated_case (ω : Ω) (tag : Tag)
    (e : Expr Γ tag.El) (arms : tag.El → Plan Γ A) (γ : Env Γ) (t : Table) :
    Plan.execAnnotated ω (.case tag e arms) γ t =
      Plan.execAnnotated ω (arms (e γ)) γ t := rfl

@[simp] theorem Plan.execAnnotated_dyn (ω : Ω) (c : Code)
    (e : Expr Γ (El c)) (f : El c → Plan Γ A) (γ : Env Γ) (t : Table) :
    Plan.execAnnotated ω (.dyn c e f) γ t =
      Plan.execAnnotated ω (f (e γ)) γ t := rfl

/-- Whether this occurrence was served by memo rather than dispatched. -/
def ExecEvent.reusedB (e : ExecEvent) : Bool :=
  match e.source with | .reused => true | .asked _ => false

/-- Regression: an effect never seeds the reusable answer table. An equal
consultation immediately afterward is dispatched rather than marked reused. -/
def effectThenConsult (q : Q .ack) : Plan [] Unit :=
  .askC .ack (Request.effect q)
    (.askC .ack (Request.consult q) (.ret fun _ => ()))

@[simp] theorem effectThenConsult_not_reused (ω : Ω) (q : Q .ack) :
    ((Plan.execAnnotated ω (effectThenConsult q) Env.nil Table.nil).trace.map
      ExecEvent.reusedB) = [false, false] := rfl

/-- Correctness relation for the actual pure K5 annotated executor. -/
def ExecResult.Correct (ω : Ω) (p : Plan Γ A) (γ : Env Γ)
    (r : ExecResult A) : Prop :=
  r.value = Plan.run ω p γ ∧ Extends ω r.table ∧
    r.trace.map ExecEvent.forget = Plan.trace ω p γ

/-- **K6 for the actual K5 executor.** From any table extended by `ω`, pure
annotated execution returns the semantic value, leaves an extended bare-Q table,
and its per-node execution trace erases exactly to semantic trace. -/
theorem Plan.execAnnotated_correct (ω : Ω) (p : Plan Γ A) :
    ∀ (γ : Env Γ) (t : Table), Extends ω t →
      (Plan.execAnnotated ω p γ t).Correct ω p γ := by
  induction p with
  | ret e =>
    intro γ t ht
    exact ⟨rfl, ht, rfl⟩
  | askC c r k ih =>
    rcases r with ⟨q, intent⟩
    cases intent with
    | consult =>
      intro γ t ht
      simp only [Plan.execAnnotated_askC, Request.isEffect, Intent.isEffect,
        Bool.false_eq_true, if_false]
      cases hq : lookup t c q with
      | some a =>
        have hwa : ω c q = a := ht c q a hq
        obtain ⟨hv, ht', htr⟩ := ih (.cons a γ) t ht
        refine ⟨?_, ht', ?_⟩
        · simpa [ExecResult.Correct, hwa] using hv
        · simpa [hwa] using congrArg (fun xs => (⟨c, q, a⟩ : Event) :: xs) htr
      | none =>
        have hcons : Extends ω (Table.cons c q (ω c q) t) := ht.cons c q
        obtain ⟨hv, ht', htr⟩ := ih (.cons (ω c q) γ)
          (Table.cons c q (ω c q) t) hcons
        exact ⟨hv, ht', congrArg (fun xs => (⟨c, q, ω c q⟩ : Event) :: xs) htr⟩
    | observe =>
      intro γ t ht
      simp only [Plan.execAnnotated_askC, Request.isEffect, Intent.isEffect,
        Bool.false_eq_true, if_false]
      cases hq : lookup t c q with
      | some a =>
        have hwa : ω c q = a := ht c q a hq
        obtain ⟨hv, ht', htr⟩ := ih (.cons a γ) t ht
        refine ⟨?_, ht', ?_⟩
        · simpa [ExecResult.Correct, hwa] using hv
        · simpa [hwa] using congrArg (fun xs => (⟨c, q, a⟩ : Event) :: xs) htr
      | none =>
        have hcons : Extends ω (Table.cons c q (ω c q) t) := ht.cons c q
        obtain ⟨hv, ht', htr⟩ := ih (.cons (ω c q) γ)
          (Table.cons c q (ω c q) t) hcons
        exact ⟨hv, ht', congrArg (fun xs => (⟨c, q, ω c q⟩ : Event) :: xs) htr⟩
    | effect =>
      intro γ t ht
      simp only [Plan.execAnnotated_askC, Request.isEffect, Intent.isEffect, if_true]
      obtain ⟨hv, ht', htr⟩ := ih (.cons () γ) t ht
      exact ⟨hv, ht', congrArg (fun xs => (⟨.ack, q, ()⟩ : Event) :: xs) htr⟩
  | ask c s e k ih =>
    rcases s with ⟨shape, intent⟩
    cases intent with
    | consult =>
      intro γ t ht
      simp only [Plan.execAnnotated_ask, Request.isEffect, Request.intent_withPrompt,
        Request.question_withPrompt, Intent.isEffect, Bool.false_eq_true, if_false]
      let q := shape.withPrompt (e γ)
      cases hq : lookup t c q with
      | some a =>
        have hwa : ω c q = a := ht c q a hq
        obtain ⟨hv, ht', htr⟩ := ih (.cons a γ) t ht
        refine ⟨?_, ht', ?_⟩
        · simpa [ExecResult.Correct, q, hwa] using hv
        · simpa [q, hwa] using congrArg (fun xs => (⟨c, q, a⟩ : Event) :: xs) htr
      | none =>
        have hcons : Extends ω (Table.cons c q (ω c q) t) := ht.cons c q
        obtain ⟨hv, ht', htr⟩ := ih (.cons (ω c q) γ)
          (Table.cons c q (ω c q) t) hcons
        exact ⟨hv, ht', congrArg (fun xs => (⟨c, q, ω c q⟩ : Event) :: xs) htr⟩
    | observe =>
      intro γ t ht
      simp only [Plan.execAnnotated_ask, Request.isEffect, Request.intent_withPrompt,
        Request.question_withPrompt, Intent.isEffect, Bool.false_eq_true, if_false]
      let q := shape.withPrompt (e γ)
      cases hq : lookup t c q with
      | some a =>
        have hwa : ω c q = a := ht c q a hq
        obtain ⟨hv, ht', htr⟩ := ih (.cons a γ) t ht
        refine ⟨?_, ht', ?_⟩
        · simpa [ExecResult.Correct, q, hwa] using hv
        · simpa [q, hwa] using congrArg (fun xs => (⟨c, q, a⟩ : Event) :: xs) htr
      | none =>
        have hcons : Extends ω (Table.cons c q (ω c q) t) := ht.cons c q
        obtain ⟨hv, ht', htr⟩ := ih (.cons (ω c q) γ)
          (Table.cons c q (ω c q) t) hcons
        exact ⟨hv, ht', congrArg (fun xs => (⟨c, q, ω c q⟩ : Event) :: xs) htr⟩
    | effect =>
      intro γ t ht
      simp only [Plan.execAnnotated_ask, Request.isEffect, Request.intent_withPrompt,
        Request.question_withPrompt, Intent.isEffect, if_true]
      let q := shape.withPrompt (e γ)
      obtain ⟨hv, ht', htr⟩ := ih (.cons () γ) t ht
      exact ⟨hv, ht', congrArg (fun xs => (⟨.ack, q, ()⟩ : Event) :: xs) htr⟩
  | case tag e arms ih =>
    intro γ t ht
    simpa [ExecResult.Correct] using ih (e γ) γ t ht
  | dyn c e f ih =>
    intro γ t ht
    simpa [ExecResult.Correct] using ih (e γ) γ t ht

/-- Pure checked annotated execution is the actual K5 executor. -/
def Plan.execAnnotatedPure {Γ : Ctx} {A : Type} (ω : Ω)
    (p : Plan Γ A) (γ : Env Γ) (t : Table) : ExecResult A :=
  Plan.execAnnotated ω p γ t

@[simp] theorem Plan.execAnnotatedPure_value {A : Type} (ω : Ω) (p : Plan [] A) :
    (Plan.execAnnotatedPure ω p Env.nil Table.nil).value =
      Plan.run ω p Env.nil :=
  (Plan.execAnnotated_correct ω p Env.nil Table.nil (extends_nil ω)).1

/-- **K6 pure trace square for the actual executor.** -/
@[simp] theorem Plan.execAnnotatedPure_forget_trace {Γ : Ctx} {A : Type}
    (ω : Ω) (p : Plan Γ A) (γ : Env Γ) (t : Table) (ht : Extends ω t) :
    (Plan.execAnnotatedPure ω p γ t).trace.map ExecEvent.forget =
      Plan.trace ω p γ :=
  (Plan.execAnnotated_correct ω p γ t ht).2.2

end Agentic.Core
