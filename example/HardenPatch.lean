import Agentic.Meaning
import Agentic.Instances
import Agentic.Star

/-!
# A worked example: hardening a patch

This is the walkthrough's §VII, written as Lean that compiles. One workflow —
draft a patch, review it three ways, revise it if the panel objects, and apply
it only if a human consents — carries every feature the library claims to
carry: several consultations, sub-agents in parallel, a *shared* consultation,
value-dependent branching, a permission gate, and a bounded revise loop.

Read it as three passes over one tree.

1. **The signature and the terms.** A `PatchOp` is a signature of
   consultations; the terms are built from it and are graded by the type
   system as they are written.
2. **The quantitative reading.** Choose an `Interp` — a price list — and the
   same tree becomes a matrix over `Cost` (what it may spend) or over `Prop`
   (whether it can succeed at all).
3. **The extensional reading.** Choose a `Runner` — a world — and the same
   tree becomes a partial function: one sample point, one run.

Nothing in the tree changes between the passes. That is the whole claim of
the design, and this file is where it is small enough to check by eye.

## For the Haskeller arriving here first

`Term Op G L f i o` is a free structure over a leaf signature `Op`, in the
sense that `Free f a` is: leaves that mean nothing until an interpretation is
chosen. Three things are unusual against the Haskell idiom.

* **It is an inductive family, indexed by its own static analysis.** The
  `f : Frag` index is a *grade* — `static`, `bounded n`, `monadic` — computed
  by the constructors, so "this workflow admits an exact a-priori cost" is a
  fact the elaborator establishes while the term is being written, not a lint
  run afterwards. Where Haskell would return `Maybe Cost` from an analysis
  pass, the type here already says which answer the pass will give.
* **There are two interpretations, and they are incomparable.**
  `muS : Term → Mat S i o` is the quantitative fold, a homomorphism into
  matrices over a complete semiring. `muExt : Term → (i → Option o)` is the
  extensional fold, per sample point. They are not two views of one thing: the
  library proves each sees something the other cannot.
* **Consultation identity is positional.** Two syntactic occurrences of the
  same leaf are two questions asked, not one question shared — because two
  draws from a model are two samples. `shareT` is the explicit override, and
  §VII's style guide is exactly where it earns its keep.
-/

namespace Agentic

namespace Examples

namespace HardenPatch

/-! ## 1. The signature

A signature of *consultations*. Its constructors are questions, not answers,
and the type `PatchOp i o` says only "there is a question that takes an `i`
and comes back with an `o`".

Nothing here has a meaning yet. A leaf means something once an `Interp` (a
static price list) or a `Runner` (a world that answers) is chosen — which is
exactly agent-functor's `Op`, whose leaves mean nothing until an ACP backend
interprets them. The signature is deliberately semiring-free: it does not
know whether it will be read as cost, as probability, or as reachability.
-/

/-- What a patch is written against. Concrete types keep the example
readable; nothing below depends on them being `String`. -/
abbrev Spec := String

/-- The artefact under review. -/
abbrev Patch := String

/-- The house style guide — the *one* document the reviewers consult, and the
reason `shareT` appears at all. -/
abbrev Guide := String

/-- A reviewer's verdict. Two values are enough to make branching real, and a
finite type with decidable equality keeps every fact below computational. -/
inductive Findings where
  /-- Ship it. -/
  | approve : Findings
  /-- Send it back. -/
  | revise : Findings
  deriving DecidableEq, Repr

/-- Combining two verdicts: any objection carries. This is the panel's fan-in
reducer, and it is a commutative idempotent monoid with `approve` as its unit
— which, by `Agentic.Panel`, is precisely the licence for the runtime to run
the three reviewers in any order and to race duplicates. -/
def Findings.meet : Findings → Findings → Findings
  | .approve, v => v
  | .revise, _ => .revise

/-- Objections carry in either order... -/
example (a b : Findings) : a.meet b = b.meet a := by cases a <;> cases b <;> rfl

/-- ...however they are grouped... -/
example (a b c : Findings) : (a.meet b).meet c = a.meet (b.meet c) := by
  cases a <;> cases b <;> cases c <;> rfl

/-- ...an approval adds nothing... -/
example (a : Findings) : a.meet .approve = a := by cases a <;> rfl

/-- ...and hearing the same objection twice is hearing it once.

Those four lines are the panel's operational licences, priced by
`Agentic.Panel` rather than configured: associativity and the unit make the
fan-in a monoid at all, commutativity buys "the three reviewers may land in
any order", and idempotence buys "the runtime may speculate and race". A
reducer that concatenated review text would have none of the last two, and the
scheduler would then owe declaration order. -/
example (a : Findings) : a.meet a = a := by cases a <;> rfl

/-- **The signature of consultations.** Five prompts and one tool, and the
type system cannot tell them apart — a tool call and a model turn are both
"ask the world something", which is the design's claim that model, tool and
human are three faces of one index. -/
inductive PatchOp : Type → Type → Type where
  /-- Prompt: write a patch against the spec. -/
  | draft : PatchOp Spec Patch
  /-- Prompt: recall the house style guide. -/
  | style : PatchOp Unit Guide
  /-- Prompt: review the patch for correctness, against the guide. -/
  | correct : PatchOp (Guide × Patch) Findings
  /-- Prompt: review the patch for security, against the guide. -/
  | secure : PatchOp (Guide × Patch) Findings
  /-- Prompt: review the patch for simplicity. No guide: this reviewer is
  asked to be naive. -/
  | simple : PatchOp Patch Findings
  /-- Tool: apply the patch to the working tree. The one leaf with an effect
  on the world, and the one the consent gate stands in front of. -/
  | applyP : PatchOp Patch Unit

/-! ### Scopes and labels

`Term` takes two more type parameters, and neither is constrained by the
syntax: `G`, the scope annotations, and `L`, the sharing labels.

A scope is an element of a monoid whose multiplication decides the override
discipline. `LastOpt String` — one axis, "which model" — is the library's
`Last` monoid: `x ⋄ set m = set m`, so the *innermost* annotation wins, and
innermost-wins is therefore a property of the monoid rather than a rule in an
interpreter. -/

/-- The scope algebra of this example: one axis, naming the model. -/
abbrev Sc := LastOpt String

/-- The sharing labels of this example. Labels are compared by nothing at all
— the fold never tests them for equality — so `String` costs nothing here. -/
abbrev Lbl := String

/-- The scope the drafting step runs under: a deep, expensive model. -/
def deepModel : Sc := LastOpt.set "opus-deep"

/-- Is the scope in force the deep model? The one question the price list
below asks of a scope. -/
def isDeep : Sc → Bool
  | some m => m == "opus-deep"
  | none => false

/-- The label under which the style guide is consulted *once*. -/
def sg : Lbl := "guide"

/-- Workflows of this example: `Term` at this signature, this scope algebra
and these labels, with only the grade and the endpoints left to vary. -/
abbrev Wf (f : Frag) (i o : Type) := Term PatchOp Sc Lbl f i o

/-! ## 2. The terms

Three definitions and a grade check after each. The grade is not asserted
anywhere below — it is the index the constructors computed, and every
`example ... := rfl` merely names the fact that they computed the expected
one.
-/

/-- The panel's fan-in: three verdicts become one. Written as a plain
function, so it is a `pureT` and costs nothing — the reducer is a
`Transform`, not a consultation. -/
def mergeFindings : Findings × (Findings × Findings) → Findings
  | (a, (b, c)) => a.meet (b.meet c)

/-- The decoder: a reviewed patch becomes either *this patch, approved* or
*go round again with this*. This is how a static term buys value-dependence —
the unbounded space of review text is factored through a finite coproduct by
a plain function, the payload flowing as data while the verdict steers.

Note the orientation, which `retryT` fixes: `Sum.inl` is **done**, `Sum.inr`
is **again**. Note also the type: §VII's prose says `Findings → Sum Patch
Spec`, but the patch must survive its own review, so the decoder takes the
pair the term actually carries. -/
def decodeVerdict : Patch × Findings → Sum Patch Spec
  | (p, .approve) => Sum.inl p
  | (p, .revise) => Sum.inr p

/-- **The three-lens panel.**

Copying the patch to all three reviewers is the leading `pureT`: copying a
*value* is free, because it is not re-asking a *question*. Consulting the
style guide is a question, and without annotation the two occurrences of
`prim .style` would be two consultation sites — two independent draws of the
guide, which is the safe default and the wrong reading here. `shareT sg`
makes them one: within its extent the site is keyed by the label, so both
occurrences build the *same* key and the world answers once.

The third reviewer is asked without the guide, so the tensor is not
symmetric: `parT` juxtaposes, it does not broadcast. -/
def panel : Wf .static Patch Findings :=
  .seqT (.pureT fun p => (((), p), (((), p), p)))
    (.seqT
      (.parT
        (.seqT (.parT (.shareT sg (.prim .style)) (.pureT fun p : Patch => p))
          (.prim .correct))
        (.parT
          (.seqT (.parT (.shareT sg (.prim .style)) (.pureT fun p : Patch => p))
            (.prim .secure))
          (.prim .simple)))
      (.pureT mergeFindings))

/-- The same panel with the label removed: three reviewers, and now *two*
draws of the style guide. This is the term §VII's `dup`-by-default paragraph
is about, and the extensional section below proves a world can tell the two
apart. -/
def panelDup : Wf .static Patch Findings :=
  .seqT (.pureT fun p => (((), p), (((), p), p)))
    (.seqT
      (.parT
        (.seqT (.parT (.prim .style) (.pureT fun p : Patch => p))
          (.prim .correct))
        (.parT
          (.seqT (.parT (.prim .style) (.pureT fun p : Patch => p))
            (.prim .secure))
          (.prim .simple)))
      (.pureT mergeFindings))

/-- **One attempt**: draft under the deep-model scope, keep the patch beside
its review, decode the verdict.

`parT (pureT id) panel` is the idiom for "carry a value past a stage that
does not take it" — the identity branch of a tensor is a wire, and it costs
the grade nothing because `Frag.par .static f = f`. -/
def attempt : Wf .static Spec (Sum Patch Spec) :=
  .seqT (.scopeT deepModel (.prim .draft))
    (.seqT
      (.seqT (.pureT fun p : Patch => (p, p))
        (.parT (.pureT fun p : Patch => p) panel))
      (.pureT decodeVerdict))

/-- **The whole workflow**: at most three attempts, then the tool call behind
a consent gate.

`consent` is a parameter, where §VII's listing left it free: a written term is
a finite datum, so the guard's `Bool` has to be supplied when the term is
built. The two instantiations are the two theorems below — `harden true` is a
workflow that can succeed, `harden false` denotes the zero matrix. -/
def harden (consent : Bool) : Wf .static Spec Unit :=
  .seqT (.retryT 2 attempt) (.gateT consent (.prim .applyP))

/-- The dynamic counterpart of the fixed panel: one simplicity review per file
the draft touched, at most eight of them. The list's length is a value, not a
constant, and `fanT` is what grades that. -/
def perFile : Wf (.bounded 8) (List Patch) (List Findings) :=
  .fanT 8 (.prim .simple)

/-- Value-dependent branching, for completeness: the same coproduct the
decoder produces, consumed by `choiceT` instead of by `retryT`. Both arms are
static, so the branch is static — a choice among enumerated alternatives is
not a data dependence, however large the token space that produced it. -/
def triage : Wf .static (Sum Patch Spec) Findings :=
  .choiceT (.prim .simple) (.seqT (.prim .draft) (.prim .simple))

/-! ### The grades, checked

Each of these is the index the constructors already computed. They are `rfl`
because `Frag`'s arithmetic reduces definitionally — `par static static`,
`join static static` and `scale 8 static` are not decision procedures run at
the use site, they are already the answer. -/

/-- The fixed panel is static: three known branches contribute no
data-dependent width, because `Frag.par` adds widths and the width of a known
branch is zero. -/
example : Term.grade panel = .static := rfl

/-- One attempt is static — the scope annotation and the decoder change no
shape. -/
example : Term.grade attempt = .static := rfl

/-- **The whole workflow is static**, gate, retry and all: a fueled loop has a
shape known before any value flows, and a guard changes no shape. So every
a-priori instrument over `harden` is exact. -/
example (c : Bool) : Term.grade (harden c) = .static := rfl

/-- The fan is bounded by its own promise. -/
example : Term.grade perFile = .bounded 8 := rfl

/-- The width fold agrees with the grade index on the nose: a static term has
no data-dependent width. -/
example (c : Bool) : Term.widthT (harden c) = some 0 := rfl

/-- And the fan's width is the fan's bound. -/
example : Term.widthT perFile = some 8 := rfl

/-! ### The grade is not the count

`widthT` above answered `some 0` for a workflow that asks seven questions,
and that is not a bug: grade width counts *copies of a written shell* that
values can bring into flight, and `harden` writes its shell once. The count
of consultations is a different fold, `Term.peak`, anchored to the
extensional meaning rather than to the grade's arithmetic. The library proves
the two are incomparable (`Term.peak_not_le_widthE`); here is what each says
about this example. -/

/-- **Three consultations in flight**: the panel's three reviewers, since
`peak` adds across a tensor and takes the max along a sequence. The style
guide does not add a fourth — it is asked inside a reviewer's own branch, in
sequence with the review, not beside it. -/
theorem peak_panel : Term.peak panel = 3 := by
  simp [Term.peak, panel]
  rfl

/-- The whole workflow peaks at the panel too: drafting is one consultation in
sequence before three, and the fueled loop runs its trips one after another
rather than together. -/
theorem peak_harden (c : Bool) : Term.peak (harden c) = 3 := by
  cases c with
  | false =>
    show max (max 1 (max (max 0 (0 + Term.peak panel)) 0)) 0 = 3
    rw [peak_panel]; norm_num
  | true =>
    show max (max 1 (max (max 0 (0 + Term.peak panel)) 0)) 1 = 3
    rw [peak_panel]; norm_num

/-- **Seven questions are written; at most three are ever outstanding.** This
is `Term.peak_le_writtenSites_mul_copiesT` at this workflow, and both factors
are visible: seven `prim` occurrences, and one copy of the shell because the
grade is static. The inequality is strict here, which is what a sequence
buys. -/
theorem peak_le_bound (c : Bool) :
    Term.peak (harden c) ≤ Term.writtenSites (harden c) * Term.copiesT (harden c) :=
  Term.peak_le_writtenSites_mul_copiesT _

/-- The fan is the case where the two folds agree: eight copies of a body
that consults once is eight consultations, and eight is also the grade. They
agree here by coincidence of the arithmetic, not by a theorem — the grade
counts shells and `peak` counts questions. -/
theorem peak_perFile : Term.peak perFile = 8 := by
  simp [Term.peak, perFile]

/-- The written count itself, for the record. -/
theorem writtenSites_harden (c : Bool) : Term.writtenSites (harden c) = 7 := by
  simp [Term.writtenSites, harden, attempt, panel]
  rfl


/-! ## 3. The quantitative reading

An `Interp Op G S` is a price list: given the scope in force, it reads each
leaf as a matrix over a complete resource semiring. `Term.muS` then folds the
whole tree into one matrix, and every clause of that fold is an algebraic
operation — sequencing is composition, tensoring is the Kronecker product,
gating is a scalar action, fuel is a truncated star.

Two carriers appear below and the term is not touched between them: `Cost`
answers *what may this spend*, `Prop` answers *can this succeed at all*.
-/

/-- **The price list.** Numbers are in whatever unit the reader likes —
tokens, cents, seconds.

The draft's price depends on the scope, which is the entire point of having
scopes: a leaf's matrix may depend on the model the enclosing `scopeT` named,
and the dependence has to enter through the interpretation because the syntax
knows nothing about it. -/
def price (g : Sc) : {a b : Type} → PatchOp a b → Nat
  | _, _, .draft => if isDeep g then 2000 else 800
  | _, _, .style => 100
  | _, _, .correct => 400
  | _, _, .secure => 400
  | _, _, .simple => 400
  | _, _, .applyP => 0

/-- **A scope-sensitive interpretation at worst-case cost.** Each leaf becomes
the constant matrix of its price: *any* prompt may become *any* reply, and the
worst case of that is the price. Nothing finer is needed to price a workflow,
and nothing finer would be honest about a model. -/
def costInterp : Term.Interp PatchOp Sc Cost :=
  fun g => @fun _ _ op _ _ => Cost.fin (price g op)

/-- **And an interpretation that ignores the scope**, for contrast: the same
prices read at the empty scope, so the cheap model is billed everywhere and
`scopeT` moves no weight at all. Scope-sensitivity is a property of the
interpretation, not of the fold. -/
def flatInterp : Term.Interp PatchOp Sc Cost :=
  fun _ => @fun _ _ op _ _ => Cost.fin (price LastOpt.unset op)

/-- A leaf is worth what the price list says, under the scope in force:
`muS_prim` is `rfl`, so this is a computation and not a theorem. -/
example (s : Spec) (p : Patch) :
    Term.muS costInterp (Term.prim (G := Sc) (L := Lbl) PatchOp.draft) deepModel s p
      = Cost.fin 2000 := rfl

/-- **Scoping does work**: the same leaf, wrapped in `scopeT deepModel` and
read at the *empty* ambient scope, prices at the deep model — because
`muS (scopeT h t) g = muS t (g ⋄ h)` and the `Last` monoid lets the inner
annotation win. -/
theorem cost_draft_scoped (g : Sc) :
    Term.muS costInterp (Term.scopeT (L := Lbl) deepModel (.prim PatchOp.draft)) g
      = fun _ _ => Cost.fin 2000 := rfl

/-- Without the annotation the same leaf prices at the cheap model. The
difference between this line and the last one is the whole Reader row. -/
example (s : Spec) (p : Patch) :
    Term.muS costInterp (Term.prim (G := Sc) (L := Lbl) PatchOp.draft)
      LastOpt.unset s p = Cost.fin 800 := rfl

/-- Under the scope-blind interpretation the annotation buys nothing: same
term, same scope, cheap price. -/
example (s : Spec) (p : Patch) :
    Term.muS flatInterp (Term.scopeT (L := Lbl) deepModel (.prim PatchOp.draft))
      LastOpt.unset s p = Cost.fin 800 := rfl

/-! ### Pricing the workflow: the library's bound calculus, and three lemmas
it is missing

The exact matrix of `harden` is a large object — a weight for every pair of
prompt and reply — and the question a budget asks of it is not "what is every
entry" but "how bad can any entry be". `Agentic.Star` already answers that
shape of question: `Mat.CostBounded k M` says no entry of `M` costs more than
`k`, and the library proves how the bound propagates through the identity,
alternation, composition, the truncated star and the retry blocks —
`Mat.retryTrunc_costBounded` even exhibits the count this example needs,
`n · k + k`, "n trips round the loop and one exit".

Three combinators used by this workflow have no such lemma yet, because
nothing in the library had priced a `parT`, a `pureT` or a `gateT` before.
They are proved here and they belong upstream in `Agentic.Star` beside the
others; nothing about them is specific to the example. -/

/-- Costs multiply monotonically. (`Agentic.Instances` has the one-sided
`Cost.mul_mono_right`; this is the two-sided form the tensor needs.) -/
theorem cost_mul_le {x x' y y' : Cost} (hx : x ≤ x') (hy : y ≤ y') :
    x * y ≤ x' * y' :=
  calc x * y ≤ x * y' := Cost.mul_mono_right x hy
    _ = y' * x := mul_comm _ _
    _ ≤ y' * x' := Cost.mul_mono_right y' hx
    _ = x' * y' := mul_comm _ _

variable {ι κ : Type}

/-- **A leaf's price bounds it.** A constant matrix is the honest reading of a
model: any prompt may become any reply, and they all cost the same. -/
theorem const_costBounded (k : Nat) :
    Mat.CostBounded k (fun (_ : ι) (_ : κ) => Cost.fin k) :=
  fun _ _ => le_refl _

/-- **A `Transform` is free.** Its matrix is `0`/`1`-valued and `1` at `Cost`
is `fin 0`, so copying, pairing, decoding and merging are bounded by zero. -/
theorem pointMat_costBounded (f : ι → κ) :
    Mat.CostBounded 0 (Mat.pointMat f : Mat Cost ι κ) := by
  intro a b
  by_cases h : f a = b
  · subst h; rw [Mat.pointMat_apply_self, Cost.fin_zero_eq_one]
  · rw [Mat.pointMat_apply_ne h]; exact Cost.bot_le _

/-- **Branches in flight add.** The Kronecker entry is a product of entries,
and a product of costs is the sum of the bounds — which is the same
arithmetic `Frag.par` does on widths, one stratum up. -/
theorem kron_costBounded {ι' κ' : Type} {j k : Nat} {A : Mat Cost ι κ}
    {B : Mat Cost ι' κ'} (hA : Mat.CostBounded j A) (hB : Mat.CostBounded k B) :
    Mat.CostBounded (j + k) (Mat.kron A B) := by
  intro p q
  refine le_trans (cost_mul_le (hA p.1 q.1) (hB p.2 q.2)) ?_
  rw [Cost.fin_mul_fin]

/-- **A guard never costs anything.** Either the gate is open and the bound is
the body's, or it is shut and the meaning is `0`. -/
theorem gate_costBounded {k : Nat} {M : Mat Cost ι κ} (b : Prop)
    (hM : Mat.CostBounded k M) : Mat.CostBounded k (Mat.gate b M) := by
  intro a c
  by_cases hb : b
  · rw [Mat.gate_true hb]; exact hM a c
  · rw [Mat.gate_false hb]; exact Cost.bot_le _

/-! ### The workflow, priced

Three bounds, each one the previous one plus the arithmetic of the stage that
encloses it. The numbers are the point: they are computed by the semiring.
Each proof states the sum the lemmas actually produce and then reads it off
with `Mat.costBounded_mono`, so the headline figure is arithmetic on a total
the calculus built, not a figure asserted and checked against. -/

/-- **The panel costs at most 1400.** Two style consultations at 100, three
reviews at 400 each, and the copying, pairing and merging are free.

Read the `100 + 100` and wince: the style guide is *shared*, and the
extensional fold below proves that only one consultation happens. `muS` is
transparent to `shareT` (`Term.muS_shareT`, `rfl`), so the quantitative layer
over-charges sharing by exactly the number of extra reads. That is the
documented state of §6a's quantitative half: the bound is honest as a bound,
and it is not tight. -/
theorem cost_panel (g : Sc) :
    Mat.CostBounded 1400 (Term.muS costInterp panel g) := by
  -- Every clause of `muS` holds by `rfl`, so unfolding the term is the whole
  -- of the rewriting: what is left is the matrix expression itself, and the
  -- bound below is the sum the lemmas produce.
  have h : Mat.CostBounded (0 + (100 + 0 + 400 + (100 + 0 + 400 + 400) + 0))
      (Term.muS costInterp panel g) := by
    simp only [panel]
    exact Mat.comp_costBounded (pointMat_costBounded _)
      (Mat.comp_costBounded
        (kron_costBounded
          (Mat.comp_costBounded
            (kron_costBounded (const_costBounded 100) (pointMat_costBounded _))
            (const_costBounded 400))
          (kron_costBounded
            (Mat.comp_costBounded
              (kron_costBounded (const_costBounded 100) (pointMat_costBounded _))
              (const_costBounded 400))
            (const_costBounded 400)))
        (pointMat_costBounded _))
  exact Mat.costBounded_mono (by norm_num) h

/-- **One attempt costs at most 3400**: the deep-model draft at 2000, then the
panel at 1400. The draft's 2000 rather than 800 is the scope doing its work —
`cost_draft_scoped` is the same fact at the leaf. -/
theorem cost_attempt (g : Sc) :
    Mat.CostBounded 3400 (Term.muS costInterp attempt g) := by
  have h : Mat.CostBounded (2000 + (0 + (0 + 1400) + 0))
      (Term.muS costInterp attempt g) := by
    simp only [attempt]
    exact Mat.comp_costBounded (const_costBounded 2000)
      (Mat.comp_costBounded
        (Mat.comp_costBounded (pointMat_costBounded _)
          (kron_costBounded (pointMat_costBounded _) (cost_panel _)))
        (pointMat_costBounded _))
  exact Mat.costBounded_mono (by norm_num) h

/-- **Three attempts, written out.** Fuel `2` unrolls to: leave now, or go
once round and leave, or go twice round and leave. This is `retryTrunc`'s own
unfolding law applied twice, it holds at every carrier, and it is where the
`3` in the bound below comes from — the cost fold does not count attempts, the
truncated star does. -/
theorem retry_three_attempts {S ι κ : Type} [CompleteCSemiring S]
    (M : Mat S ι (Sum κ ι)) :
    Mat.retryTrunc 2 M
      = Mat.matAdd (Mat.exitBlock M)
          (Mat.comp (Mat.loopBlock M)
            (Mat.matAdd (Mat.exitBlock M)
              (Mat.comp (Mat.loopBlock M) (Mat.exitBlock M)))) := by
  rw [Mat.retryTrunc_succ, Mat.retryTrunc_succ, Mat.retryTrunc_zero]

/-- **The whole workflow costs at most 10200 — three attempts at 3400.**

This is the sentence a budget wants before anything is spent, and it is a
theorem about the term rather than a measurement of a run. The `3` is
`Mat.retryTrunc_costBounded`'s `n · k + k` at `n = 2`: two trips round the
loop block and one through the exit. The tool call itself is free; what it
costs is not money. -/
theorem cost_harden (c : Bool) (g : Sc) :
    Mat.CostBounded 10200 (Term.muS costInterp (harden c) g) := by
  have h : Mat.CostBounded (2 * 3400 + 3400 + 0)
      (Term.muS costInterp (harden c) g) := by
    simp only [harden]
    exact Mat.comp_costBounded (Mat.retryTrunc_costBounded (cost_attempt g) 2)
      (gate_costBounded _ (const_costBounded 0))
  exact Mat.costBounded_mono (by norm_num) h

/-- **And the workflow never diverges.** This is §VII's "provably finite" for
the retry, and it is worth seeing what pays for it: not the fuel alone, but
the fuel *together with* a uniform bound on the body. Over an infinite space
of prompts the worst case is a supremum, and a supremum of finite costs with
no common bound is `inf` — so `Mat.retryTrunc_cost_finite` charges for
`CostBounded`, and the three lemmas above are what supply it here. -/
theorem cost_harden_finite (c : Bool) (g : Sc) (s : Spec) (u : Unit) :
    Term.muS costInterp (harden c) g s u ≠ Cost.inf := fun h =>
  Cost.not_inf_le_fin (h ▸ cost_harden c g s u)

/-- The arithmetic, standing alone, since it is the part a reader checks by
hand: an attempt is the draft plus the panel, and three attempts is three
times an attempt. Costs multiply in the semiring and add in the numbers,
which is what "max-plus" means. -/
example : Cost.fin 2000 * Cost.fin 1400 = Cost.fin 3400 := by
  rw [Cost.fin_mul_fin]

example : Cost.fin 3400 * Cost.fin 3400 * Cost.fin 3400 = Cost.fin 10200 := by
  rw [Cost.fin_mul_fin, Cost.fin_mul_fin]

/-- And the bound is a real bound in a decidable order: 10200 is worse than
one attempt and better than four. -/
example : Cost.fin 3400 ≤ Cost.fin 10200 := Cost.fin_le_fin.mpr (by decide)

example : ¬ (Cost.fin 13600 ≤ Cost.fin 10200) := fun h =>
  absurd (Cost.fin_le_fin.mp h) (by decide)

/-! ### Refusal, by the algebra

The consent gate is not a branch and not an exception: it is multiplication by
an indicator, and the indicator of a refusal is the semiring's `0`. The zero
then annihilates through composition — no interpreter rule, no special case,
no `Halt`.

Note where the gate sits in this term: at the *end*. So what the refusal
annihilates is everything *before* it, and the workflow does not denote "spend
10200 and then stop" — it denotes the impossible run. A budget reading the
refused workflow is told, correctly, that nothing happens.

Note also the generality: this holds at **every** complete resource semiring,
for every price list. -/

/-- **Refusal annihilates the workflow.** -/
theorem muS_harden_false {S : Type} [CompleteCSemiring S]
    (interp : Term.Interp PatchOp Sc S) (g : Sc) :
    Term.muS interp (harden false) g = Mat.zeroMat := by
  show Mat.comp (Term.muS interp (Term.retryT 2 attempt) g)
      (Term.muS interp (Term.gateT false (Term.prim PatchOp.applyP)) g) = Mat.zeroMat
  rw [Term.muS_gateT_false, Mat.comp_zeroMat]

/-- At `Cost` the annihilation reads as `⊥`, the impossible run — which is
*not* the same as a free run (`fin 0`, the semiring's `1`). A refused workflow
does not cost nothing; it does not happen. -/
example (g : Sc) (s : Spec) : Term.muS costInterp (harden false) g s () = Cost.bot := by
  rw [muS_harden_false]; rfl

/-! ### Feasibility: the same fold at `Prop`

Swap the carrier and the same term answers a different question. At `Prop`,
`⊕` is `∨`, `⊗` is `∧`, aggregation is `∃`, and a matrix *is* a relation: the
entry `M a b` says that `a` can become `b`. Nothing about the workflow
changes; the analyzer was never a program, so there is no second analyzer to
write.

The four little lemmas below are the four operations of the meaning space
read at this carrier — composition is "give me the intermediate value",
tensoring is "give me both", a `Transform` reaches its own value, and doing
nothing is possible. -/

/-- Every leaf can answer anything: the maximally permissive world, which is
the right interpretation for a feasibility question. -/
def possible : Term.Interp PatchOp Sc Prop := fun _ => @fun _ _ _ _ _ => True

/-- Composition at `Prop`: exhibit the intermediate value. -/
theorem comp_possible {ι κ ν : Type} {M : Mat Prop ι κ} {N : Mat Prop κ ν}
    {a : ι} {c : ν} (b : κ) (hM : M a b) (hN : N b c) : Mat.comp M N a c :=
  ⟨b, hM, hN⟩

/-- Tensoring at `Prop`: both branches must be possible. -/
theorem kron_possible {ι κ ι' κ' : Type} {A : Mat Prop ι κ} {B : Mat Prop ι' κ'}
    {p : ι × ι'} {q : κ × κ'} (hA : A p.1 q.1) (hB : B p.2 q.2) :
    Mat.kron A B p q := ⟨hA, hB⟩

/-- A `Transform` reaches its own value. -/
theorem point_possible {ι κ : Type} (f : ι → κ) (a : ι) :
    (Mat.pointMat f : Mat Prop ι κ) a (f a) := by
  rw [Mat.pointMat_apply_self]; trivial

/-- Doing nothing is possible — the fact that makes a *fueled* loop possible
by taking zero trips. -/
theorem id_possible {ι : Type} (a : ι) : (Mat.idMat : Mat Prop ι ι) a a := by
  rw [Mat.idMat_self]; trivial

/-- **The panel can return any verdict.** The witnesses are the run: a style
guide (any string will do), the patch carried past the reviewers by the
identity wire, and three reviews that agree. -/
theorem panel_possible (g : Sc) (p : Patch) :
    ∀ f : Findings, Term.muS possible panel g p f
  | .approve =>
    comp_possible (((), p), (((), p), p))
      (point_possible (fun p : Patch => (((), p), (((), p), p))) p)
      (comp_possible (Findings.approve, (Findings.approve, Findings.approve))
        (kron_possible
          (comp_possible ("", p)
            (kron_possible trivial (point_possible (fun p : Patch => p) p)) trivial)
          (kron_possible
            (comp_possible ("", p)
              (kron_possible trivial (point_possible (fun p : Patch => p) p)) trivial)
            trivial))
        (point_possible mergeFindings _))
  | .revise =>
    comp_possible (((), p), (((), p), p))
      (point_possible (fun p : Patch => (((), p), (((), p), p))) p)
      (comp_possible (Findings.revise, (Findings.revise, Findings.revise))
        (kron_possible
          (comp_possible ("", p)
            (kron_possible trivial (point_possible (fun p : Patch => p) p)) trivial)
          (kron_possible
            (comp_possible ("", p)
              (kron_possible trivial (point_possible (fun p : Patch => p) p)) trivial)
            trivial))
        (point_possible mergeFindings _))

/-- **An attempt can end either way**: approved, or sent back for a redraft.
Both are reachable, which is what makes the loop below a loop rather than a
formality. -/
theorem attempt_possible (g : Sc) (s : Spec) :
    ∀ v : Sum Patch Spec, Term.muS possible attempt g s v
  | Sum.inl q =>
    comp_possible q trivial
      (comp_possible (q, Findings.approve)
        (comp_possible (q, q) (point_possible (fun p : Patch => (p, p)) q)
          (kron_possible (point_possible (fun p : Patch => p) q)
            (panel_possible g q Findings.approve)))
        (point_possible decodeVerdict (q, Findings.approve)))
  | Sum.inr q =>
    comp_possible q trivial
      (comp_possible (q, Findings.revise)
        (comp_possible (q, q) (point_possible (fun p : Patch => (p, p)) q)
          (kron_possible (point_possible (fun p : Patch => p) q)
            (panel_possible g q Findings.revise)))
        (point_possible decodeVerdict (q, Findings.revise)))

/-- **With consent, the workflow can succeed.** The witness is the shortest
run: zero trips round the loop (the identity summand of the truncated star),
one attempt that approves, and the tool call. Feasibility is a reachability
question, and reachability is what the `Prop` carrier computes. -/
theorem harden_possible (g : Sc) (s : Spec) : Term.muS possible (harden true) g s () :=
  comp_possible s
    (comp_possible s (Or.inl (id_possible s)) (attempt_possible g s (Sum.inl s)))
    (by rw [Term.muS_gateT_true]; trivial)

/-- **Without consent, it cannot.** Not "is unlikely", not "fails at runtime":
the entry is `False`, because the gate multiplied it by `0`. The two theorems
together are the design's claim that a permission is a scalar. -/
theorem harden_infeasible (g : Sc) (s : Spec) :
    ¬ Term.muS possible (harden false) g s () := by
  rw [muS_harden_false]
  exact fun h => h


/-! ## 4. The extensional reading

The other fold. A `Runner` is *the world, decoded*: given the scope in force
and the **key** of the consultation — the path to this leaf through the
written term — it answers, or refuses. `Term.muExt` folds the tree into a
partial function `i → Option o`: one sample point, one run.

The key is the whole subject of this section. It is computed by the fold from
the syntax, so what counts as "the same consultation" is decided by the term
and not by the runner — which is why sharing is observable at all.

Below, the world is an *answer sheet*: `Env (Key Lbl) String`, a value for
every question the run might ask. This is the design's ε, and it is exactly a
session file: replay is the identity, and forking is editing one cell.
-/

/-- What a reviewer does with its cell of the answer sheet and the style guide
it was handed. A pedantic guide always finds something; otherwise the cell
decides.

The guide *matters* to the verdict — that is what makes the shared
consultation observable rather than decorative. -/
def review (cell : String) (guide : Guide) : Findings :=
  if guide == "pedantic" then .revise
  else if cell == "ok" then .approve else .revise

/-- **A runner backed by an answer sheet.** One outcome type, `String`, for
every question, with the runner decoding it per leaf: the draft and the style
guide are read off directly, a review is the verdict its cell and its guide
imply, and the tool always succeeds if it is reached at all.

That decoding is where the heterogeneity goes. `Env C O` assigns *one*
outcome type to every consultation while `PatchOp a b` answers in a `b` that
varies from leaf to leaf, and rather than a dependent answer sheet the runner
simply owns the decoder — which is what a real backend does with a wire
format.

Note what this particular world ignores: the patch text. A reviewer's verdict
here depends on its own cell and on the guide it was handed, and not on what
it is reviewing. That is a legitimate sample point — a world may be as coarse
as it likes — and it keeps the equations below short enough to read. -/
def sheetRunner (ε : Env (Key Lbl) String) : Runner PatchOp Sc Lbl :=
  fun _ k => @fun _ _ op a =>
    match op, a with
    | .draft, _ => some (ε k)
    | .style, _ => some (ε k)
    | .correct, (gd, _) => some (review (ε k) gd)
    | .secure, (gd, _) => some (review (ε k) gd)
    | .simple, _ => some (review (ε k) "")
    | .applyP, _ => some ()

/-! ### The keys this workflow reads

A key is either `abs site` — a path from the root of the term — or
`rel l site`, a path from the nearest enclosing `shareT l`. The paths below
are not postulated: each one is the site the fold computes, and the equations
that mention them are closed by `rfl`, which is the check. -/

/-! Keys are compared nowhere in the library — the fold's whole point is that
it never has to — so `Key` carries no `DecidableEq`. Two facts below want one,
and here it is: equality of keys is decidable exactly when equality of labels
is. Deriving it changes nothing about the fold; it only lets a reader close
"these are two different questions" by computation. -/

deriving instance DecidableEq for Key

/-- Where the panel's correctness review is consulted, reading `panel` from
the root. -/
def kCorrect : Key Lbl := .abs [.seqR, .seqL, .parL, .seqR]

/-- Where the security review is consulted. -/
def kSecure : Key Lbl := .abs [.seqR, .seqL, .parR, .parL, .seqR]

/-- Where the simplicity review is consulted. -/
def kSimple : Key Lbl := .abs [.seqR, .seqL, .parR, .parR]

/-- **Where the style guide is consulted — once.** The key is *rebased* on the
label: it records the label and the path below it, and nothing about where in
the term the occurrence sits. That is why two occurrences collide. -/
def kGuide : Key Lbl := .rel sg []

/-- In the unlabelled panel, where the *first* reviewer's style consultation
sits. -/
def kStyle₁ : Key Lbl := .abs [.seqR, .seqL, .parL, .seqL, .parL]

/-- And the *second* — a different path, hence a different question. -/
def kStyle₂ : Key Lbl := .abs [.seqR, .seqL, .parR, .parL, .seqL, .parL]

/-- Where the `trip`-th draft is consulted, reading `retryT 2 attempt` from
the root. The trip index is part of the path, so each trip round the loop is a
fresh consultation. -/
def kDraft (trip : Nat) : Key Lbl := .abs [.retry trip, .seqL, .scope]

/-! ### (c) Sharing, observed

Two theorems, one per panel, both `rfl`, and both stated for an *arbitrary*
answer sheet — so they describe the fold's behaviour at every sample point at
once, not at a lucky one. -/

/-- **The shared panel reads one guide cell, twice.** `ε kGuide` appears twice
on the right and there is one cell behind both: the two `shareT sg`
occurrences rebase to the same key, so the world is asked once and the answer
is used by both reviewers. -/
theorem panel_reads_one_cell (ε : Env (Key Lbl) String) (p : Patch) :
    Term.muExt (sheetRunner ε) panel LastOpt.unset Key.root p
      = some (mergeFindings
          (review (ε kCorrect) (ε kGuide),
            (review (ε kSecure) (ε kGuide), review (ε kSimple) ""))) := rfl

/-- **The unlabelled panel reads two.** Same three reviewers, same merge, and
now the guide is drawn twice — two independent samples, which is the default
and is what a designer who did not write `shareT` asked for. -/
theorem panelDup_reads_two_cells (ε : Env (Key Lbl) String) (p : Patch) :
    Term.muExt (sheetRunner ε) panelDup LastOpt.unset Key.root p
      = some (mergeFindings
          (review (ε kCorrect) (ε kStyle₁),
            (review (ε kSecure) (ε kStyle₂), review (ε kSimple) ""))) := rfl

/-- And the two style keys really are two keys — a decidable fact about
paths, with no appeal to the label. -/
theorem kStyle_ne : kStyle₁ ≠ kStyle₂ := by decide

/-- An answer sheet on which the difference is visible: the second reviewer's
own style draw comes back *pedantic*, the first one's does not. -/
def sheetSplit : Env (Key Lbl) String := fun k =>
  if k = kStyle₂ then "pedantic"
  else match k with
    | .rel _ _ => "lenient"
    | .abs _ => "ok"

/-- **Sharing is not duplication, at this workflow.** One consultation twice
read approves; two consultations, one of which drew a stricter guide, does
not. The library's `Term.muExt_dupPair_ne_sharedPair` says this in the
abstract; this is the same fact wearing the example's clothes. -/
theorem share_ne_dup_here (p : Patch) :
    Term.muExt (sheetRunner sheetSplit) panel LastOpt.unset Key.root p
      = some Findings.approve
    ∧ Term.muExt (sheetRunner sheetSplit) panelDup LastOpt.unset Key.root p
      = some Findings.revise :=
  ⟨rfl, rfl⟩

/-! ### (a) A happy path, and (d) a refusal

With every cell reading `"ok"` the first attempt approves, the gate is open,
and the tool runs: the workflow answers `some ()`. Flip the gate and the same
world answers `none` — refusal is partiality here, exactly as it was the zero
matrix there. -/

/-- The world in which everything goes well the first time. -/
def sheetHappy : Env (Key Lbl) String := fun _ => "ok"

/-- **(a) A complete run**: draft, three reviews, approve, apply. -/
theorem harden_happy :
    Term.muExt (sheetRunner sheetHappy) (harden true) LastOpt.unset Key.root "spec"
      = some () := rfl

/-- **(d) The same world, consent withheld**: no answer at all. Nothing
downstream of the gate is consulted — the fold does not reach the tool, it
refuses before it. -/
theorem harden_refused :
    Term.muExt (sheetRunner sheetHappy) (harden false) LastOpt.unset Key.root "spec"
      = none := rfl

/-! ### (b) The loop, looping

A world that rejects the first draft and accepts the second. The trip index
sits in every absolute key below a `retryT`, so the second draft is drawn from
a *different cell* of the answer sheet — a second draw, not a replay of the
first. That is the whole content of `Step.retry`. -/

/-- Cells belonging to the second trip read `"ok"`; everything on the first
trip reads `"no"`; the shared guide is lenient. -/
def sheetRevise : Env (Key Lbl) String
  | .abs s => if s.contains (Step.retry 1) then "ok" else "no"
  | .rel _ _ => "lenient"

/-- **Trip 0 is rejected.** The attempt run at the trip-0 key answers
`Sum.inr` — go round again — carrying the rejected draft back as the spec for
the next one. -/
theorem trip_zero_rejects :
    Term.muExt (sheetRunner sheetRevise) attempt LastOpt.unset
        (Key.abs [Step.retry 0]) "spec"
      = some (Sum.inr "no") := rfl

/-- **Trip 1 approves.** Same term, same world, different key — and that is
the only difference between the two runs. -/
theorem trip_one_approves :
    Term.muExt (sheetRunner sheetRevise) attempt LastOpt.unset
        (Key.abs [Step.retry 1]) "no"
      = some (Sum.inl "ok") := rfl

/-- **The first draft is rejected and the second is applied.** The answer is
the *trip-1* draft cell — `"ok"` — and not the trip-0 one, which is what it
means for the loop to have gone round. -/
theorem revise_loop_runs :
    Term.muExt (sheetRunner sheetRevise) (Term.retryT 2 attempt)
        LastOpt.unset Key.root "spec"
      = some (sheetRevise (kDraft 1)) := rfl

/-- And the two drafts are two consultations: different keys, so a world is
free to answer them differently — which `sheetRevise` does. If the trip index
were *not* in the key, the second draft would read the first draft's cell and
a retry could never change anything. -/
theorem kDraft_ne : kDraft 0 ≠ kDraft 1 := by decide

/-- What the trip-0 draft actually read, for contrast. -/
example : sheetRevise (kDraft 0) = "no" := rfl

/-- **The shared guide, however, is drawn once for the whole loop.** Its key
is `rel sg []`, which contains no trip index at all — the rebase discards the
absolute position, and the position is where the trip lived. So `shareT`
outside a leaf but inside a loop means "ask once, ever", and a designer who
wanted a fresh guide per trip would have to put the label inside the trip.
The library's `Key` docstring warns about the converse case (a labelled body
*containing* a loop, where the trips are still distinct sites); this is the
same rule read the other way. -/
theorem guide_key_trip_free (trip : Nat) :
    (Key.rebase (L := Lbl) sg) = kGuide ∧ kGuide ≠ kDraft trip :=
  ⟨rfl, by simp [kGuide, kDraft]⟩


/-! ## 5. Realization notes — what an implementation would have to be

Everything above is a specification: it says what the workflow *means*, in
four number systems and one world, and it never runs. This closing section
maps each construct onto the thing an implementation in the
`agent-functor`/`incite` line already has, or would have to grow, and — more
usefully — says where the realization must **differ** from the spec and why
the difference is not a defect.

### The signature ↔ the `Op` an ACP backend interprets

`PatchOp` is `agent-functor`'s `Op`: a closed datum naming a consultation,
with no idea what answering it involves. A real leaf carries more payload — a
prompt template, a tool schema, a timeout — and answers over a wire, so the
realized leaf is `Op i o` plus a codec. The codec's failure mode is already in
the spec: a reply that will not parse is a refusal, and refusal is `none` in
`muExt` and `0` in `muS`. Nothing needs to be added for it; a parse failure and
a withheld consent annihilate identically, which is the one thing an
implementation must not "improve" by throwing an exception instead.

### `Interp` ↔ the backend registry and the price book

`Term.Interp Op G S` is `G → Op a b → Mat S a b`: the scope names a backend
and a model, the registry resolves it, the price book prices it. Two honest
differences:

* **Prices depend on the input.** `costInterp` above gave each leaf a constant
  matrix, which reads "any prompt, any reply, this price". A realization
  prices by tokens, so the entry is a function of the prompt and the reply —
  and `Interp` already allows exactly that, since it returns a *matrix* and
  not a scalar. The constant matrices here are a readability choice, not a
  limitation of the fold; the bound calculus is what survives either way.
* **The price book is not the only carrier.** The same registry, read into
  `Prop`, is a feasibility check ("is this backend configured at all"); read
  into `ℝ≥0∞`, a Viterbi consensus weight; read into the expectation semiring,
  spend-given-success. An implementation that hard-codes its cost fold — the
  audit's finding against `agent-functor` — has to write a new traversal per
  question. Parameterizing by the semiring is the whole of the fix, and it is
  one type argument.

### `Runner` + `Env` ↔ `LeafRunner` and the content-addressed store

A `Runner` is `LeafRunner`: scope, key, leaf, input, and an answer or a
refusal. The answer sheet `ε : Env (Key L) String` is the session store, and
the correspondence is tighter than an analogy:

* **A session file IS `ε` restricted to the keys actually asked.** The run
  consults finitely many cells; recording those cells is recording the
  restriction.
* **Replay is the identity.** Re-running against the recorded restriction
  gives the same partial function, because `muExt` is a function of `ε` and
  the run reads no cell outside the record. Caching is not an optimization
  with a semantics attached; it *is* the identity on meanings (§6d).
* **Fork is `pin`.** Changing one answer and re-running is
  `Env.pin ε q a = Function.update ε q a`, and "fork the session at this
  answer" needs no other machinery.

The sharp difference is **what a cell is keyed by**. Here a cell is keyed by
*position in the term*; a content-addressed store keys by *hash of the
request*. Those are different equivalence relations on consultations, and the
gap between them is precisely `share` versus `dup`: content addressing
silently merges two occurrences of the same prompt into one draw. Under
`Env.share_ne_dup` that is a change of meaning, not a cache hit — it collapses
a self-consistency ensemble to a single sample and leaves the variance wrong
while the support stays right, which is exactly the class of bug that never
shows up in a test. An implementation may key by content **only** where the
leaf is deterministic; conflating "deterministic" with "cacheable" is the
audit's `isCacheable` finding, and this file is what it looks like when the
distinction is kept: `panel` and `panelDup` differ, by `rfl`, at a world that
can tell.

### `scopeT` ↔ `withBackend` / `withMode` / `applyScope`

`scopeT g` is precomposition on the reader, `withScope = actR`, and the
implementation's `applyScope` is its solved form. Innermost-wins is not code:
it is `LastOpt`'s non-commutativity, so an implementation gets the override
discipline right by *using a monoid* and gets it wrong by writing an
interpreter rule. `cost_draft_scoped` above is the whole content — the leaf's
price changed because the scope reached the interpretation.

### The grade ↔ what `plan` and `cost` may print before spending

`Term.grade` is a static analysis that has already run. A `cost` subcommand
could report, without a single call:

* `.static` — an exact quote. `harden` is static, so `cost_harden`'s 10200 is
  a number the tool may print.
* `.bounded n` — a supremum, honestly labelled: `perFile` may spend eight
  reviews and the tool should quote eight.
* `.monadic` — a refusal to quote. Not an estimate, not a guess: the plan does
  not exist until the model writes it, and the honest answer is "unknown a
  priori, sample the prefix".

And `Term.peak` is what a *scheduler* wants: three consultations in flight for
`harden`, so a worker pool of three is not a tuning parameter but a fact about
the term (`peak_harden`). The pair `peak ≤ writtenSites * copiesT` is the
general shape of that budget.

### `shareT` ↔ `leafKey` and the share machinery

`shareT l` rebases the key onto the label, which is what a `leafKey` scheme
approximates when it lets two call sites declare a shared identity. Two
liabilities, both visible in this file and both the designer's to discharge:

* **The label is trusted.** The fold keys on `l` alone and never looks at the
  body, so one label over two different bodies collides (acat-bmc). An
  implementation that generates labels from source position is safe; one that
  takes them from user configuration is not.
* **The label is scope-blind.** `kGuide` has no scope and no trip index in it
  (`guide_key_trip_free`), so the shared guide is drawn *once for the entire
  loop*. That is a real design decision and it is visible here: if a fresh
  guide per attempt is wanted, the label must be written inside the retry
  body, not outside it.

### Where the realization must differ

* **Nondeterminism: the runner is one sample point; the implementation draws
  it.** `muExt run` is the meaning *at* a world; a real run does not receive a
  world, it samples one, and a second run samples another. So a passing run
  proves nothing about the workflow and a theorem quantified over `ε` proves
  everything. Read the other way: `sheetHappy` is not "the behaviour", it is
  one row of it, and the honest summary over all rows is the *quantitative*
  reading — which is why `Cost` is a worst case and `Prob` is a Viterbi
  maximum rather than an average of observed runs.
* **Concurrency: `muExt` sequences what an implementation runs in parallel.**
  The extensional fold runs a tensor left-first and short-circuits, and takes
  the leftmost defined alternative of a `sumT`. A `ParStrategy` that runs both
  branches concurrently will consult sites the spec says are never reached
  when the left branch refuses. The quantitative fold is symmetric
  (`Mat.kron`), so the *cost* of the parallel realization is the spec's cost;
  only the set of sites visited differs, and an implementation should treat
  the extra consultations as its own business and not as answers the workflow
  may read.
* **Bounds must be enforced, not intended.** `fanT n` truncates *in the
  meaning* (`Term.muS_fanT_zero`), so an uncapped parallel map is not an
  optimistic scheduler, it denotes a different workflow.
* **The gate is coarser here than a real policy.** `gateT` takes a `Bool`;
  a realization wants `Grant` — a lattice of permissions with footprints — and
  the semantics is ready for it, since gating is the action of a scalar and
  any semiring element will do. That is tracked as acat-755.
* **Sharing is not yet priced.** `muS` is transparent to `shareT`, so
  `cost_panel` bills the style guide twice while the run reads it once. An
  implementation that reports the spec's number will over-quote by exactly the
  extra reads, which is the safe direction and is stated rather than hidden.
-/

end HardenPatch

end Examples

end Agentic
