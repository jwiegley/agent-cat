/-!
# The extensional layer: environments, pinning, and partial meanings

This module formalizes design §3 (the environment as a complete answer sheet)
together with the two consequences the design draws from it: *caching is the
identity* on meanings (§6d, where the cache is resolved by the two-meaning
split) and *sharing is not duplication* (§6a, the failure of copy-naturality).

The move that organises everything here is the one the design calls
"randomness at the edge". A run consults the world — a model, a tool, a human
— many times, and each consultation is uncertain. Rather than thread a
distribution through every operator, the whole uncertainty is pushed to a
single sample point `ε : Env C O`, an answer for *every* question the run
might ever ask, chosen once at the outermost edge. Downstream of that choice
nothing is random: a workflow is an ordinary partial function.

Two things follow immediately, and both are theorems below rather than
commentary:

* **Caching is invisible extensionally.** Replaying a consultation under the
  same `ε` returns the same answer by construction — `ε` is a function, and a
  function has one value at each argument. So a cached workflow and an
  uncached one are the *same* meaning (`cached_eq`); the difference between
  them is entirely a resource difference, visible only in the quantitative
  layer.

* **The index at which `ε` is consulted is semantic.** Asking one question and
  copying the answer is not the same meaning as asking two questions, even
  when the questions are "the same kind of question" (`share_ne_dup`). Under a
  fixed `ε` the two agree exactly when `ε` happens to agree at the two indices
  (`share_eq_dup_of_agree`); it is under the measure at the edge that they
  come apart, because the second is a fresh draw.

Nothing in this module needs the resource algebra, so nothing is imported: the
extensional layer stands on its own, which is itself part of the design's
claim about stratification.
-/

namespace Agentic

open Classical

/-- An `Env C O` is a representation of a complete answer sheet: one sample
point `ε`, assigning to every consultation the run *might* make the answer it
*would* receive.

The type parameters are the design's two extensional parameters. `C` is the
consultation index: a `Consult` is a representation of one question the run
may put to the world — a model call, a tool command, or a human query — three
faces of one thing, and the design insists on the identification, because
every operator that treats them alike (caching, pinning, gating, retry) would
otherwise have to be written three times. `O` is the outcome type: what comes
back.

Because `Env C O` is a *function*, the same question asked twice under the
same `ε` receives the same answer; that is the whole content of §3. The
probability measure over `Env C O` sits at the outermost edge of the design
and nowhere else — it does not appear in this file, in any later operator, or
in any law; a workflow's meaning is defined per sample point, and expectation
is taken once, at the end. -/
def Env (C O : Type) : Type := C → O

/-- Counterfactual substitution `ε[q ↦ a]`: the answer sheet that agrees with
`ε` everywhere except at the question `q`, where it reads `a`.

This one operation is the design's account of a family of apparently different
mechanisms. *Forking* a session is pinning the answers already received and
letting the rest vary. *Resuming* from a checkpoint is the same act, read
forwards. *Editing a cache* — the operator override, the recorded fixture, the
"what if the tool had said this instead" — is pinning at exactly the
consultations whose recorded answers are being replaced. They are not three
features; they are three uses of function update.

The test "is this the pinned question?" is classical, so pinning is available
at *every* type of consultation and not only at those whose questions can be
compared by a program. A question is a semantic object — a prompt, a tool
invocation, a whole sub-session — and demanding that equality of questions be
decidable would restrict the meaning space for the benefit of an implementation
that is not being written here. The price is that `pin` is `noncomputable`. -/
noncomputable def pin {C O : Type} (ε : Env C O) (q : C) (a : O) : Env C O :=
  fun q' => if q' = q then a else ε q'

/-- Reading back the pinned question gives the pinned answer: an override
overrides. -/
theorem pin_same {C O : Type} (ε : Env C O) (q : C) (a : O) :
    pin ε q a q = a :=
  if_pos rfl

/-- Reading back any *other* question is undisturbed: pinning is surgical, and
in particular a fork does not perturb the consultations it did not fix. -/
theorem pin_other {C O : Type} (ε : Env C O) (q q' : C) (a : O)
    (h : q' ≠ q) : pin ε q a q' = ε q' :=
  if_neg h

/-- The later pin wins: re-editing a cache entry discards the earlier edit
rather than layering on it. -/
theorem pin_pin_same {C O : Type} (ε : Env C O) (q : C) (a b : O) :
    pin (pin ε q a) q b = pin ε q b := by
  funext q'
  by_cases h : q' = q
  · simp [pin, h]
  · simp [pin, h]

/-- Pinning a question to the answer it already had changes nothing: recording
a cache faithfully is not an intervention. -/
theorem pin_get {C O : Type} (ε : Env C O) (q : C) :
    pin ε q (ε q) = ε := by
  funext q'
  by_cases h : q' = q
  · simp [pin, h]
  · simp [pin, h]

/-- Pins at distinct questions commute: independent overrides may be applied in
either order, so a fork specified by a set of pinnings is well defined without
choosing an order for them. -/
theorem pin_pin_comm {C O : Type} (ε : Env C O) {q₁ q₂ : C}
    (a b : O) (h : q₁ ≠ q₂) : pin (pin ε q₁ a) q₂ b = pin (pin ε q₂ b) q₁ a := by
  funext q'
  by_cases h₁ : q' = q₁
  · by_cases h₂ : q' = q₂
    · exact absurd (h₁ ▸ h₂ ▸ rfl : q₁ = q₂) h
    · simp [pin, h₁, h]
  · by_cases h₂ : q' = q₂
    · simp [pin, h₂, h.symm]
    · simp [pin, h₁, h₂]

/-- An `Ext C O W ι κ` is a representation of the extensional meaning of a
workflow: given one sample point `ε`, a partial function from an input value
`ι` paired with a world `W` to an output value `κ` paired with a world.

Three commitments are packed into the shape. The `Env C O →` on the outside is
randomness-at-the-edge: the meaning is defined per answer sheet, not as a
distribution. The `W ×` on both sides is the world-threading that makes the
design's tensor merely premonoidal — effects on a shared world are sequenced,
and cannot be commuted past one another, even though the resource algebra can.
The `Option` is *refusal*: partiality here is not failure-as-error but a
workflow declining to produce a result — a gate closed, a guard unsatisfied, a
budget exhausted. Refusal is the annihilating element (`extComp_none_left`,
`extComp_none_right`), which is the extensional shadow of `0` absorbing in the
resource semiring. -/
def Ext (C O W ι κ : Type) : Type := Env C O → W × ι → Option (W × κ)

/-- The workflow that does nothing: it consults nothing, changes no world,
refuses nothing, and returns its input. -/
def extId {C O W ι : Type} : Ext C O W ι ι :=
  fun _ s => some s

/-- The workflow that refuses everything, at every sample point and every
input. This is the meaning of a permanently closed gate. -/
def extNone {C O W ι κ : Type} : Ext C O W ι κ :=
  fun _ _ => none

/-- Sequencing of extensional meanings: run `f`, and if it produced a world and
a value, run `g` from there — the Kleisli composition of `Option`, with the
world threaded through. Both halves see the *same* sample point `ε`, which is
what makes the answer sheet global to a run rather than local to a step. -/
def extComp {C O W ι κ ν : Type} (f : Ext C O W ι κ) (g : Ext C O W κ ν) :
    Ext C O W ι ν :=
  fun ε s => (f ε s).bind (g ε)

/-- Sequencing is associative: a pipeline has one meaning, not a bracketing of
meanings. Refusal propagates identically either way, which is the whole of the
`Option` case analysis. -/
theorem extComp_assoc {C O W ι κ ν ρ : Type}
    (f : Ext C O W ι κ) (g : Ext C O W κ ν) (h : Ext C O W ν ρ) :
    extComp (extComp f g) h = extComp f (extComp g h) := by
  funext ε s
  show ((f ε s).bind (g ε)).bind (h ε) = (f ε s).bind (fun t => (g ε t).bind (h ε))
  cases f ε s with
  | none => rfl
  | some t => rfl

/-- Doing nothing first changes no meaning. -/
theorem extId_comp {C O W ι κ : Type} (f : Ext C O W ι κ) :
    extComp extId f = f := rfl

/-- Doing nothing afterwards changes no meaning. -/
theorem extComp_id {C O W ι κ : Type} (f : Ext C O W ι κ) :
    extComp f extId = f := by
  funext ε s
  show (f ε s).bind (fun t => some t) = f ε s
  cases f ε s with
  | none => rfl
  | some t => rfl

/-- Refusing first refuses the whole: nothing downstream of a closed gate
runs. -/
theorem extComp_none_left {C O W ι κ ν : Type} (g : Ext C O W κ ν) :
    extComp (extNone : Ext C O W ι κ) g = extNone := rfl

/-- Refusing afterwards refuses the whole: work already done does not rescue a
refused result. Note that the *world* effects of `f` are discarded along with
its value — extensionally, refusal is total, and any account of partial
rollback belongs to the world type `W`, not to `Option`. -/
theorem extComp_none_right {C O W ι κ ν : Type} (f : Ext C O W ι κ) :
    extComp f (extNone : Ext C O W κ ν) = extNone := by
  funext ε s
  show (f ε s).bind (fun _ => none) = none
  cases f ε s with
  | none => rfl
  | some t => rfl

/-- The cached form of a workflow: the very same meaning.

This is the design's §3 dividend, and the reason the definition is allowed to
look vacuous. Caching, replay, memoisation and record/replay testing are all
the claim "asking again returns what it returned before". Under the
answer-sheet semantics that claim is not a property to be enforced by an
implementation, nor an assumption to be discharged; it is the definition of a
function. Given the same `ε`, replay *is* identity.

What is not vacuous is what this buys: the extensional layer sees no
difference at all (`cached_eq`), so every law proved about `f` transfers to its
cached form for free, and the entire content of caching moves to the
quantitative layer, where the same meaning is carried by a cheaper resource —
the cost drops while the meaning does not move. A cache that changed the
meaning would be a bug in the implementation, and the fact that it *cannot* be
expressed here is the point. -/
def cachedAt {C O W ι κ : Type} (f : Ext C O W ι κ) : Ext C O W ι κ := f

/-- Caching changes no meaning: §6d's resolution of the cache, which is §3's
two-meaning split spent, stated as an equation. Everything one might
want to add — that a cache in front of a cache is one cache, that a cached
stage of a pipeline is the same pipeline — is this equation rewritten, and is
left to the reader's `rw` rather than restated as a lemma. -/
theorem cached_eq {C O W ι κ : Type} (f : Ext C O W ι κ) : cachedAt f = f := rfl

/-! ### Sharing versus duplication

The next block exhibits the design's §6a distinction. Both workflows below
return a pair of outcomes and touch the world not at all; they differ only in
*where* they read the answer sheet. `askPair q₁ q₂` consults `q₁` and `q₂`; the
"shared" workflow is `askPair q q` and the "duplicated" one is `askPair q₁ q₂`
with `q₁ ≠ q₂`. -/

/-- The workflow that consults the answer sheet at two named questions and
returns both answers, leaving the world alone. `askPair q q` is *sharing* — one
consultation whose answer is copied — and `askPair q₁ q₂` with distinct
questions is *duplication* — two consultations. -/
def askPair {C O W : Type} (q₁ q₂ : C) : Ext C O W Unit (O × O) :=
  fun ε p => some (p.1, (ε q₁, ε q₂))

/-- Sharing really does copy: the shared form returns one answer twice, by
construction, with no appeal to any determinism assumption. -/
theorem askPair_same {C O W : Type} (q : C) (ε : Env C O) (p : W × Unit) :
    (askPair q q : Ext C O W Unit (O × O)) ε p = some (p.1, (ε q, ε q)) := rfl

/-- Pinning is visible through a consultation: overriding the question the
workflow asks overrides what it reads. -/
theorem askPair_pin {C O W : Type} (q : C) (a : O)
    (ε : Env C O) (p : W × Unit) :
    (askPair q q : Ext C O W Unit (O × O)) (pin ε q a) p = some (p.1, (a, a)) := by
  show some (p.1, (pin ε q a q, pin ε q a q)) = some (p.1, (a, a))
  rw [pin_same]

/-- Copy-naturality, pointwise in `ε`: at any *particular* sample point where
the two questions happen to receive the same answer, sharing and duplication
are indistinguishable. This is the precise sense in which the distinction is
invisible to a single trace — and the reason it is so easy to lose. -/
theorem share_eq_dup_of_agree {C O W : Type} (q₁ q₂ : C) (ε : Env C O)
    (h : ε q₁ = ε q₂) :
    (askPair q₁ q₁ : Ext C O W Unit (O × O)) ε = askPair q₁ q₂ ε := by
  funext p
  show some (p.1, (ε q₁, ε q₁)) = some (p.1, (ε q₁, ε q₂))
  rw [h]

/-- A two-point consultation index with Boolean outcomes: the smallest world in
which sharing and duplication can differ. -/
abbrev TwoQ : Type := Bool

/-- The answer sheet that answers the two questions differently — the
counterexample's whole content: a world in which the second draw does not
match the first. -/
def epsSplit : Env TwoQ Bool := fun q => q

/-- Sharing: consult question `false` once and copy the answer. -/
def shareEx : Ext TwoQ Bool Unit Unit (Bool × Bool) := askPair false false

/-- Duplication: consult question `false` and question `true`, separately. -/
def dupEx : Ext TwoQ Bool Unit Unit (Bool × Bool) := askPair false true

/-- Under `epsSplit`, sharing returns the same answer twice. -/
theorem shareEx_epsSplit :
    shareEx epsSplit ((), ()) = some ((), (false, false)) := rfl

/-- Under `epsSplit`, duplication returns two different answers. -/
theorem dupEx_epsSplit :
    dupEx epsSplit ((), ()) = some ((), (false, true)) := rfl

/-- Sharing is not duplication.

The index at which `ε` is consulted is semantic. Copy-naturality — the law
that would let a compiler, a scheduler, or a refactoring replace "ask once and
copy" by "ask twice" — holds pointwise in `ε` exactly when the answer sheet
agrees at the two indices (`share_eq_dup_of_agree`), and fails in general: the
witness `epsSplit` answers `false` at one question and `true` at the other.
Under the measure at the edge the failure is systematic rather than
accidental, since the two consultations are separate draws; a "self-consistency"
ensemble that accidentally shares one index collapses to a single sample, and
the two meanings differ in their variance even where they agree in their
support. This is why the design makes the consultation index part of the
meaning instead of leaving it to the implementation. -/
theorem share_ne_dup : shareEx ≠ dupEx := by
  intro h
  have h1 : shareEx epsSplit ((), ()) = dupEx epsSplit ((), ()) := by rw [h]
  rw [shareEx_epsSplit, dupEx_epsSplit] at h1
  simp at h1

end Agentic
