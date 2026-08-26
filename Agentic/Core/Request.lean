import Agentic.Core.Question

/-!
# Annotated requests: the executable Plan representation

A `Q c` is principal answer identity: addressee, scope, words, and draw. The
runtime additionally needs to know whether one Plan occurrence is a consultation,
observation, or effect so that it can choose reuse, ordering, permission, and
completion policy without inferring them from answer code or addressee.

`Request c = Q c × Intent c` is that typed representation annotation. Denotation
forgets `Intent`; worlds, semantic events, tables, and semantic prices remain
keyed by `Q`. Routes and failover preserve the authored annotation while selecting
a separate dispatched target.

Source lowering supplies the annotation: ordinary value asks consult, value
`toolExec` observes, and statement-position acts effect. `effect` is available
only at `.ack`, preventing a value-bearing effect result in this representation.
The tags prove neither faithful observation nor physical state change.
-/

namespace Agentic.Core

/-- `[[Intent c]]` = execution annotation of one code-`c` Plan occurrence.
`effect` is restricted to `.ack`, so this representation cannot branch on an
alleged effect result. -/
inductive Intent : Code → Type where
  /-- Ask an addressee for an answer. -/
  | consult {c : Code} : Intent c
  /-- Read external state through a declared observation. -/
  | observe {c : Code} : Intent c
  /-- Request a change to external state. -/
  | effect : Intent .ack
  deriving DecidableEq, Repr

instance : Inhabited (Intent c) := ⟨.consult⟩

/-- Stable spelling used by renderers and the intent-aware conformance wire. -/
def Intent.name : Intent c → String
  | .consult => "consult"
  | .observe => "observe"
  | .effect => "effect"

/-- Whether operational execution must treat this occurrence as an effect. -/
def Intent.isEffect : Intent c → Bool
  | .effect => true
  | _ => false

/-- `[[Request c]]` = semantic question plus executable Plan annotation. -/
structure Request (c : Code) where
  question : Q c
  intent : Intent c
  deriving DecidableEq

/-- Annotated request with only prompt forgotten. Intent stays in Plan shape so
an answer cannot choose execution policy dynamically. -/
structure Request.Shape (c : Code) where
  question : Q.Shape c
  intent : Intent c
  deriving DecidableEq

/-- An ordinary consultation of `q`. -/
abbrev Request.consult (q : Q c) : Request c := ⟨q, .consult⟩

/-- A declared observation using `q`. -/
abbrev Request.observe (q : Q c) : Request c := ⟨q, .observe⟩

/-- An occurrence-sensitive effect using the acknowledgement question `q`. -/
abbrev Request.effect (q : Q .ack) : Request .ack := ⟨q, .effect⟩

/-- A consultation shape. -/
abbrev Request.Shape.consult (q : Q.Shape c) : Request.Shape c := ⟨q, .consult⟩

/-- An observation shape. -/
abbrev Request.Shape.observe (q : Q.Shape c) : Request.Shape c := ⟨q, .observe⟩

/-- An effect shape. -/
abbrev Request.Shape.effect (q : Q.Shape .ack) : Request.Shape .ack := ⟨q, .effect⟩

@[simp] theorem Request.consult_intent (q : Q c) :
    (Request.consult q).intent = .consult := rfl

@[simp] theorem Request.observe_intent (q : Q c) :
    (Request.observe q).intent = .observe := rfl

@[simp] theorem Request.effect_intent (q : Q .ack) :
    (Request.effect q).intent = .effect := rfl

/-- The two representation annotations are structurally distinct; denotation
forgets this distinction (`denote_askC_intent_irrel`). -/
theorem Request.consult_ne_observe (q : Q c) :
    Request.consult q ≠ Request.observe q := by
  intro h
  cases h

/-- Forget only a request's prompt. -/
def Request.shape (r : Request c) : Request.Shape c := ⟨r.question.shape, r.intent⟩

/-- Fill the sole missing component of a request shape. -/
def Request.Shape.withPrompt (s : Request.Shape c) (prompt : String) : Request c :=
  ⟨s.question.withPrompt prompt, s.intent⟩

abbrev Request.prompt (r : Request c) : String := r.question.prompt
abbrev Request.addressee (r : Request c) : Addressee := r.question.addressee
abbrev Request.scope (r : Request c) : QScope := r.question.scope
abbrev Request.draw (r : Request c) : Nat := r.question.draw
abbrev Request.Shape.addressee (s : Request.Shape c) : Addressee := s.question.addressee
abbrev Request.Shape.scope (s : Request.Shape c) : QScope := s.question.scope
abbrev Request.Shape.draw (s : Request.Shape c) : Nat := s.question.draw

/-- Effects are Plan occurrences operational memoization must not suppress. -/
def Request.isEffect (r : Request c) : Bool := r.intent.isEffect

@[simp] theorem Request.shape_withPrompt (s : Request.Shape c) (t : String) :
    (s.withPrompt t).shape = s := rfl

@[simp] theorem Request.question_withPrompt (s : Request.Shape c) (t : String) :
    (s.withPrompt t).question = s.question.withPrompt t := rfl

@[simp] theorem Request.prompt_withPrompt (s : Request.Shape c) (t : String) :
    (s.withPrompt t).prompt = t := rfl

/-- Computing prompt words cannot change execution annotation. -/
@[simp] theorem Request.intent_withPrompt (s : Request.Shape c) (t : String) :
    (s.withPrompt t).intent = s.intent := rfl

@[simp] theorem Request.addressee_withPrompt (s : Request.Shape c) (t : String) :
    (s.withPrompt t).addressee = s.addressee := rfl

@[simp] theorem Request.scope_withPrompt (s : Request.Shape c) (t : String) :
    (s.withPrompt t).scope = s.scope := rfl

@[simp] theorem Request.draw_withPrompt (s : Request.Shape c) (t : String) :
    (s.withPrompt t).draw = s.draw := rfl

@[simp] theorem Request.withPrompt_shape (r : Request c) :
    r.shape.withPrompt r.prompt = r := rfl

/-- Shape and prompt jointly determine a request. -/
theorem Request.eq_of_shape_of_prompt {r r' : Request c}
    (hs : r.shape = r'.shape) (hp : r.prompt = r'.prompt) : r = r' := by
  rw [← Request.withPrompt_shape r, ← Request.withPrompt_shape r', hs, hp]

@[simp] theorem Request.shape_question (r : Request c) :
    r.shape.question = r.question.shape := rfl

@[simp] theorem Request.shape_intent (r : Request c) : r.shape.intent = r.intent := rfl

/-- Scope relabelling acts on the question and cannot rewrite intent. -/
def Sig.onRequestShape (σ : Sig) (c : Code) (s : Request.Shape c) : Request.Shape c :=
  ⟨σ c s.question, s.intent⟩

/-- The unique intent-preserving extension of a question relabelling to requests. -/
def Sig.onRequest (σ : Sig) (c : Code) (r : Request c) : Request c :=
  ⟨σ.onQ c r.question, r.intent⟩

@[simp] theorem Sig.onRequest_intent (σ : Sig) (c : Code) (r : Request c) :
    (σ.onRequest c r).intent = r.intent := rfl

@[simp] theorem Sig.onRequestShape_intent (σ : Sig) (c : Code) (s : Request.Shape c) :
    (σ.onRequestShape c s).intent = s.intent := rfl

@[simp] theorem Sig.onRequestShape_question (σ : Sig) (c : Code)
    (s : Request.Shape c) :
    (σ.onRequestShape c s).question = σ c s.question := rfl

@[simp] theorem Sig.onRequestShape_addressee (σ : Sig) (c : Code)
    (s : Request.Shape c) :
    (σ.onRequestShape c s).addressee = (σ c s.question).addressee := rfl

@[simp] theorem Sig.onRequest_withPrompt (σ : Sig) (c : Code)
    (s : Request.Shape c) (t : String) :
    σ.onRequest c (s.withPrompt t) = (σ.onRequestShape c s).withPrompt t := rfl

@[simp] theorem Sig.shape_onRequest (σ : Sig) (c : Code) (r : Request c) :
    (σ.onRequest c r).shape = σ.onRequestShape c r.shape := rfl

@[simp] theorem Sig.question_onRequest (σ : Sig) (c : Code) (r : Request c) :
    (σ.onRequest c r).question = σ.onQ c r.question := rfl

@[simp] theorem Sig.prompt_onRequest (σ : Sig) (c : Code) (r : Request c) :
    (σ.onRequest c r).prompt = r.prompt := rfl

@[simp] theorem idSig_onRequestShape (c : Code) (s : Request.Shape c) :
    idSig.onRequestShape c s = s := rfl

@[simp] theorem compSig_onRequestShape (σ τ : Sig) (c : Code) (s : Request.Shape c) :
    (compSig σ τ).onRequestShape c s =
      σ.onRequestShape c (τ.onRequestShape c s) := rfl

@[simp] theorem idSig_onRequest (c : Code) (r : Request c) : idSig.onRequest c r = r := rfl

@[simp] theorem compSig_onRequest (σ τ : Sig) (c : Code) (r : Request c) :
    (compSig σ τ).onRequest c r = σ.onRequest c (τ.onRequest c r) := rfl

end Agentic.Core
