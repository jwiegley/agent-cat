import Agentic.Core.Cost

/-!
# Operational billing of annotated execution traces

This module is below denotation. `Cost.billFresh` is the monoid morphism from
bare-question semantic trace; the functions here interpret `ExecTrace`, where
intent, memo reuse, and dispatched targets are representation observations.
-/

namespace Agentic.Core

/-- Operational price may inspect the authored Plan annotation. -/
abbrev ExecPrice (S : Type) : Type := (c : Code) → Request c → S

/-- Read an operational price at one annotated event. -/
def ExecEvent.price (price : ExecPrice S) (e : ExecEvent) : S :=
  price e.c e.authored

/-- Bare semantic question key of an annotated event. -/
def ExecEvent.semanticKey (e : ExecEvent) : Key := e.forget.key

/-- May `later` reuse the same semantic question as `e`? Effects are never
reusable; consult and observe annotations compare only their bare questions. -/
def ExecEvent.sameReusableQuestion (e later : ExecEvent) : Bool :=
  !later.authored.isEffect && decide (e.semanticKey = later.semanticKey)

/-- Retain the last reusable occurrence of each bare question and every effect
occurrence. The retained event keeps its own authored annotation. -/
def execMemoEvents : ExecTrace → ExecTrace
  | [] => []
  | e :: es =>
      if e.authored.isEffect then e :: execMemoEvents es
      else if es.any (e.sameReusableQuestion ·) then execMemoEvents es
      else e :: execMemoEvents es

/-- Operational memo projection only removes occurrences. -/
theorem execMemoEvents_sublist : ∀ es : ExecTrace, List.Sublist (execMemoEvents es) es := by
  intro es
  induction es with
  | nil => simp [execMemoEvents]
  | cons e es ih =>
    simp only [execMemoEvents]
    split
    · exact ih.cons_cons e
    · split
      · exact ih.cons e
      · exact ih.cons_cons e

/-- Product of operational charges in annotated trace order. -/
def billExecEvents [Monoid S] (price : ExecPrice S) (es : ExecTrace) : S :=
  (es.map (ExecEvent.price price)).prod

/-- Charge every annotated Plan occurrence. -/
def billExecFresh [Monoid S] (price : ExecPrice S) (es : ExecTrace) : S :=
  billExecEvents price es

/-- Runtime memo bill: bare-Q reusable identity, every effect occurrence. -/
def billMemo [Monoid S] (price : ExecPrice S) (es : ExecTrace) : S :=
  billExecEvents price (execMemoEvents es)

/-- Frozen v2 projection: erase annotation and deduplicate every bare question,
including effects, before applying a semantic price. -/
def billMemoLegacy [Monoid S] (price : Price S) (es : ExecTrace) : S :=
  billOfKeys price ((es.map ExecEvent.semanticKey).dedup)

/-- One operational unit per annotated occurrence. -/
def execTick : ExecPrice (Multiplicative Nat) :=
  fun _ _ => Multiplicative.ofAdd 1

@[simp] theorem billExecEvents_tick (es : ExecTrace) :
    billExecEvents execTick es = Multiplicative.ofAdd es.length := by
  induction es with
  | nil => rfl
  | cons e es ih =>
    change Multiplicative.ofAdd 1 * billExecEvents execTick es =
      Multiplicative.ofAdd (es.length + 1)
    rw [ih, ← ofAdd_add, Nat.add_comm]

@[simp] theorem billExecFresh_tick (es : ExecTrace) :
    billExecFresh execTick es = Multiplicative.ofAdd es.length :=
  billExecEvents_tick es

/-- Operational memo billing never exceeds fresh occurrence billing in the
sublist sense. -/
theorem billMemo_dvd_billExecFresh [CommMonoid S]
    (price : ExecPrice S) (es : ExecTrace) :
    billMemo price es ∣ billExecFresh price es :=
  ((execMemoEvents_sublist es).map (ExecEvent.price price)).prod_dvd_prod

/-- Equal effects remain distinct operational charges. -/
def effectTickQ : Request .ack :=
  .effect { addressee := .tool "effect", scope := 1, prompt := "", draw := 0 }

@[simp] theorem billMemo_two_equal_effects :
    let e : ExecEvent := ⟨.ack, effectTickQ, .asked effectTickQ.question, ()⟩
    billMemo execTick [e, e] = Multiplicative.ofAdd 2 := rfl

/-- Consult and observe annotations of one bare question share one reusable
charge, while each occurrence remains in `ExecTrace`. -/
def consultTickQ : Request .ack := Request.consult effectTickQ.question

def observeTickQ : Request .ack := Request.observe effectTickQ.question

@[simp] theorem billMemo_consult_observe_same_question :
    let consult : ExecEvent :=
      ⟨.ack, consultTickQ, .asked consultTickQ.question, ()⟩
    let observe : ExecEvent := ⟨.ack, observeTickQ, .reused, ()⟩
    billMemo execTick [consult, observe] = Multiplicative.ofAdd 1 := by
  decide

@[simp] theorem billMemoLegacy_mixed_intent :
    let consult : ExecEvent :=
      ⟨.ack, consultTickQ, .asked consultTickQ.question, ()⟩
    let effect : ExecEvent := ⟨.ack, effectTickQ, .asked effectTickQ.question, ()⟩
    billMemoLegacy tick [consult, effect] = Multiplicative.ofAdd 1 := by
  decide

/-- Memo policy is deliberately not a semantic monoid morphism. -/
theorem billMemo_not_monoid_hom :
    ∃ es : ExecTrace,
      billMemo execTick (es ++ es) ≠ billMemo execTick es * billMemo execTick es := by
  let q : Request .ack :=
    .consult { addressee := .tool "t", scope := 1, prompt := "", draw := 0 }
  let e : ExecEvent := ⟨.ack, q, .asked q.question, ()⟩
  refine ⟨[e], ?_⟩
  decide

end Agentic.Core
