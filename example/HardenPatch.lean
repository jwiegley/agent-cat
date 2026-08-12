import Combinators
import Agentic.Meaning
import Agentic.Instances
import Agentic.Star

/-!
# A worked example: hardening a patch

The walkthrough's §VII as Lean that compiles. Draft a patch, review it three
ways against a *shared* style guide, revise it if the panel objects, apply it
only with a human's consent. §3 is the workflow — four definitions, in the
vocabulary of `Agentic.Examples.Combinators` — and every other section is a
*reading* of those four: by the grade, by `muS` at `Cost` and at `Prop`, and by
`muExt` at an answer sheet. Nothing about the term changes between the
readings, which is the whole claim of the design.
-/

namespace Agentic

namespace Examples

namespace HardenPatch

open Term

/-! ## 1. The domain and the signature -/

abbrev Spec := String   -- what a patch is written against
abbrev Patch := String  -- the artefact under review
abbrev Guide := String  -- the house style guide, the one document the panel shares

inductive Findings where  -- a reviewer's verdict
  | approve : Findings  -- ship it
  | revise : Findings   -- send it back
  deriving DecidableEq, Repr

/-- **The signature of consultations.** Five prompts and one tool, and the type
system cannot tell them apart: a model turn, a tool call and a question to a
human are three faces of one index. None of them means anything until an
`Interp` or a `Runner` is chosen. -/
inductive PatchOp : Type → Type → Type where
  | draft : PatchOp Spec Patch                 -- write a patch against the spec
  | style : PatchOp Unit Guide                 -- recall the house style guide
  | correct : PatchOp (Guide × Patch) Findings -- review for correctness, against the guide
  | secure : PatchOp (Guide × Patch) Findings  -- review for security, against the guide
  | simple : PatchOp Patch Findings            -- review for simplicity, asked naively
  | applyP : PatchOp Patch Unit                -- apply it: the one leaf with an effect

abbrev Sc := LastOpt String  -- scopes: one axis, naming the model; innermost wins
abbrev Lbl := String         -- sharing labels; the fold never compares them
abbrev Wf (f : Frag) (i o : Type) := Term PatchOp Sc Lbl f i o  -- this example's workflows

def deepModel : Sc := LastOpt.set "opus-deep"  -- the drafting scope: deep and expensive
def sg : Lbl := "guide"                        -- the label the guide is consulted under

/-! ## 2. The domain functions -/

/-- Combining two verdicts: any objection carries. Commutative, associative,
idempotent, unit `approve` — `Agentic.Panel`'s licence to run the reviewers in
any order and to race duplicates. -/
def Findings.meet : Findings → Findings → Findings
  | .approve, v => v
  | .revise, _ => .revise

/-- The panel's fan-in: three verdicts become one, by a plain function. -/
def mergeFindings (a b c : Findings) : Findings := a.meet (b.meet c)

/-- The decoder: a reviewed patch is either *this patch, approved* (`Sum.inl`,
which the loop reads as **done**) or *go round again with this* (`Sum.inr`) —
how a static term buys value-dependence, an unbounded space of review text
factored onto a finite coproduct by a `Transform`. -/
def decodeVerdict : Patch × Findings → Sum Patch Spec
  | (p, .approve) => Sum.inl p
  | (p, .revise) => Sum.inr p

/-! ## 3. The workflow

The reason the file exists: combinator vocabulary and named domain functions,
with no plumbing, because the plumbing lives once in `Combinators`. The grade on
each signature is not a claim made about the term but one *checked* of it — the
index is what the constructors computed, and a term whose grade arithmetic
failed to reduce would need a coercion here and would not elaborate. -/

/-- Three reviewers over one patch: two read the shared style guide, the third
is asked naively. -/
def review : Wf .static Patch Findings :=
  panel₃ (guided sg .style .correct) (guided sg .style .secure) (ask .simple)
    mergeFindings

/-- One attempt: draft under the deep model, keep the patch beside its review,
decode the verdict. -/
def attempt : Wf .static Spec (Sum Patch Spec) :=
  under deepModel (ask .draft) ⟫ keep review ⟫ fn decodeVerdict

/-- The whole workflow: at most three attempts, then the tool call behind a
consent gate. `consent` is a parameter because a written term is a finite datum
— the guard's `Bool` has to be supplied when the term is built. -/
def harden (consent : Bool) : Wf .static Spec Unit :=
  loop 2 attempt ⟫ gate consent (ask .applyP)

/-- The dynamic counterpart of the fixed panel: one simplicity review per file
the draft touched, at most eight, the list's length being a value. -/
def perFile : Wf (.bounded 8) (List Patch) (List Findings) := Term.fanT 8 (ask .simple)

/-! ## 4. The grades

`rfl` closes each: `Frag`'s arithmetic is not a decision procedure run at the
use site, it is already the answer. -/

/-- **The whole workflow is static** — gate, loop, panel and all — so every
a-priori instrument over `harden` is exact. -/
example (c : Bool) : Term.grade (harden c) = .static := rfl

/-- The width fold agrees. It says `0` of a workflow that asks seven questions,
which is not a bug: grade width counts copies of a written shell that values can
bring into flight, and `harden` writes its shell once. -/
example (c : Bool) : Term.widthT (harden c) = some 0 := rfl

/-- The fan is bounded by its own promise and by nothing else. -/
example : Term.grade perFile = .bounded 8 := rfl

/-! ## 5. The read-outs

Six facts about the term above, in three carriers and one world.

### The bound calculus this workflow needs

`Agentic.Star` proves how `Mat.CostBounded k M` — no entry of `M` costs more
than `k` — propagates through the identity, alternation, composition and the
retry blocks. Four combinators used here have no such lemma yet. **They belong
upstream in `Agentic.Star`**; nothing about them is specific to this example. -/

section BelongsInStar
variable {ι κ : Type}

theorem cost_mul_le {x x' y y' : Cost} (hx : x ≤ x') (hy : y ≤ y') : x * y ≤ x' * y' :=
  -- costs multiply monotonically; `Agentic.Instances` has only the one-sided form
  calc x * y ≤ x * y' := Cost.mul_mono_right x hy
    _ = y' * x := mul_comm _ _
    _ ≤ y' * x' := Cost.mul_mono_right y' hx
    _ = x' * y' := mul_comm _ _

/-- **A leaf's price bounds it**: any prompt may become any reply, all at one
price — the honest constant-matrix reading of a model. -/
theorem const_costBounded (k : Nat) :
    Mat.CostBounded k (fun (_ : ι) (_ : κ) => Cost.fin k) := fun _ _ => le_refl _

/-- **A `Transform` is free**: `1` at `Cost` is `fin 0`, so copying, pairing,
decoding and merging cost nothing. -/
theorem pointMat_costBounded (h : ι → κ) :
    Mat.CostBounded 0 (Mat.pointMat h : Mat Cost ι κ) := by
  intro a b; by_cases hb : h a = b
  · subst hb; rw [Mat.pointMat_apply_self, Cost.fin_zero_eq_one]
  · rw [Mat.pointMat_apply_ne hb]; exact Cost.bot_le _

/-- **Branches in flight add** — a Kronecker entry is a product of entries, the
same arithmetic `Frag.par` does on widths one stratum up. -/
theorem kron_costBounded {ι' κ' : Type} {j k : Nat} {A : Mat Cost ι κ}
    {B : Mat Cost ι' κ'} (hA : Mat.CostBounded j A) (hB : Mat.CostBounded k B) :
    Mat.CostBounded (j + k) (Mat.kron A B) := by
  intro p q
  refine le_trans (cost_mul_le (hA p.1 q.1) (hB p.2 q.2)) ?_; rw [Cost.fin_mul_fin]

/-- **A guard never costs anything**: open, the bound is the body's; shut, the
meaning is `0`. -/
theorem gate_costBounded {k : Nat} {M : Mat Cost ι κ} (b : Prop)
    (hM : Mat.CostBounded k M) : Mat.CostBounded k (Mat.gate b M) := by
  intro a c; by_cases hb : b
  · rw [Mat.gate_true hb]; exact hM a c
  · rw [Mat.gate_false hb]; exact Cost.bot_le _

end BelongsInStar

/-! ### (i) What it may spend -/

def isDeep : Sc → Bool | some m => m == "opus-deep" | none => false  -- the deep model?

/-- **The price list**, in whatever unit the reader likes. The draft's price
depends on the scope, which is the point of having scopes: the dependence enters
through the interpretation, the syntax knowing nothing about it. -/
def price (g : Sc) : {a b : Type} → PatchOp a b → Nat
  | _, _, .draft => if isDeep g then 2000 else 800
  | _, _, .style => 100
  | _, _, .correct | _, _, .secure | _, _, .simple => 400
  | _, _, .applyP => 0

def costInterp : Term.Interp PatchOp Sc Cost :=
  fun g => @fun _ _ op _ _ => Cost.fin (price g op)  -- scope-sensitive, worst case

/-- **One attempt costs at most 3400**: the deep-model draft at 2000 — 2000 and
not 800 is `under` doing its work, the annotation reaching the price list — then
the panel at 1400, two guides at 100 and three reviews at 400. Every `Transform`
in it (the `keep` wire, the copies, the decoder, the merge) is free. -/
theorem cost_attempt (g : Sc) : Mat.CostBounded 3400 (Term.muS costInterp attempt g) :=
  have brief : ∀ r : PatchOp (Guide × Patch) Findings, price g r = 400 →
      Mat.CostBounded 500 (Term.muS costInterp (guided sg .style r : Wf .static Patch Findings) g) :=
    fun r h => Mat.costBounded_mono (k := 0 + (100 + 0) + price g r) (by omega)
      (Mat.comp_costBounded (Mat.comp_costBounded (pointMat_costBounded _)
        (kron_costBounded (const_costBounded 100) (pointMat_costBounded _)))
        (const_costBounded (price g r)))
  Mat.costBounded_mono (by norm_num) <|
    Mat.comp_costBounded
      (Mat.comp_costBounded (const_costBounded 2000)
        (Mat.comp_costBounded (pointMat_costBounded _)
          (kron_costBounded (pointMat_costBounded _)
            (Mat.comp_costBounded
              (Mat.comp_costBounded (pointMat_costBounded _)
                (kron_costBounded (brief .correct rfl)
                  (kron_costBounded (brief .secure rfl) (const_costBounded 400))))
              (pointMat_costBounded _)))))
      (pointMat_costBounded _)

/-- **(1) The whole workflow costs at most 10200** — three attempts at 3400 —
which is the sentence a budget wants before anything is spent: a theorem about
the term, not a measurement of a run. The `3` is `Mat.retryTrunc_costBounded`'s
`n · k + k` at `n = 2`; the tool call is free. Read the two `100`s and wince,
though — the guide is *shared* and the run below reads it once, but `muS` is
transparent to `shareT`, so the quantitative layer overbills sharing by exactly
the extra reads. Honest as a bound, not tight: §6a's quantitative half. -/
theorem cost_harden (c : Bool) (g : Sc) :
    Mat.CostBounded 10200 (Term.muS costInterp (harden c) g) :=
  Mat.costBounded_mono (by norm_num) <|
    Mat.comp_costBounded (Mat.retryTrunc_costBounded (cost_attempt g) 2)
      (gate_costBounded _ (const_costBounded 0))

/-- **(2) Refusal annihilates the workflow.** The gate is not a branch and not
an exception: it is multiplication by an indicator, refusal is the semiring's
`0`, and the zero annihilates through composition — no interpreter rule, no
special case, no `Halt`. The gate sits at the *end*, so what is annihilated is
everything before it: the refused workflow does not denote "spend 10200 and
stop", it denotes the impossible run. True at **every** complete resource
semiring, for every price list. -/
theorem muS_harden_false {S : Type} [CompleteCSemiring S]
    (interp : Term.Interp PatchOp Sc S) (g : Sc) :
    Term.muS interp (harden false) g = Mat.zeroMat := by
  show Mat.comp (Term.muS interp (Term.retryT 2 attempt) g)
      (Term.muS interp (Term.gateT false (Term.prim PatchOp.applyP)) g) = Mat.zeroMat
  rw [Term.muS_gateT_false, Mat.comp_zeroMat]

/-! ### (ii) Whether it can succeed at all

Swap the carrier and the same term answers a different question. At `Prop`, `⊕`
is `∨`, `⊗` is `∧`, aggregation is `∃`, and a matrix *is* a relation; the
analyzer was never a program, so there is no second analyzer to write. The four
one-liners are the meaning space's four operations read at this carrier. -/

def possible : Term.Interp PatchOp Sc Prop := fun _ => @fun _ _ _ _ _ => True
  -- every leaf can answer anything: the maximally permissive world

theorem comp_possible {ι κ ν : Type} {M : Mat Prop ι κ} {N : Mat Prop κ ν} {a : ι}
    {c : ν} (b : κ) (hM : M a b) (hN : N b c) : Mat.comp M N a c := ⟨b, hM, hN⟩
  -- composition: exhibit the intermediate value

theorem kron_possible {ι κ ι' κ' : Type} {A : Mat Prop ι κ} {B : Mat Prop ι' κ'}
    {p : ι × ι'} {q : κ × κ'} (hA : A p.1 q.1) (hB : B p.2 q.2) : Mat.kron A B p q := ⟨hA, hB⟩
  -- tensoring: both branches must be possible

theorem point_possible {ι κ : Type} (h : ι → κ) (a : ι) :
    (Mat.pointMat h : Mat Prop ι κ) a (h a) := by rw [Mat.pointMat_apply_self]; trivial
  -- a Transform reaches its own value

theorem id_possible {ι : Type} (a : ι) : (Mat.idMat : Mat Prop ι ι) a a := by
  rw [Mat.idMat_self]; trivial  -- doing nothing is possible: the loop may take zero trips

/-- **(3) With consent, the workflow can succeed.** Feasibility is reachability,
and reachability is what the `Prop` carrier computes. The witness is the shortest
run, outside in: zero trips round the loop (the identity summand of the truncated
star), one attempt whose reviewers approve, the tool call behind an open gate.
Its counterpart is `muS_harden_false` — without consent the entry is not
"unlikely" but `False` — and the two together are the design's claim that a
permission is a scalar. -/
theorem harden_possible (g : Sc) (s : Spec) : Term.muS possible (harden true) g s () :=
  have rev : ∀ (r : PatchOp (Guide × Patch) Findings) (p : Patch) (v : Findings),
      Term.muS possible (guided (Op := PatchOp) (G := Sc) sg .style r) g p v := fun _ p _ =>
    comp_possible ("", p) (comp_possible ((), p) (point_possible _ p)
      (kron_possible trivial (point_possible id p))) trivial
  have pan : ∀ (p : Patch) (v : Findings), Term.muS possible review g p v := fun p v =>
    comp_possible (Findings.approve, (Findings.approve, v))
      (comp_possible (p, (p, p)) (point_possible (fun a : Patch => (a, (a, a))) p)
        (kron_possible (rev .correct p .approve)
          (kron_possible (rev .secure p .approve) trivial)))
      (point_possible _ _)
  have att : ∀ q : Patch, Term.muS possible attempt g q (Sum.inl q) := fun q =>
    comp_possible (q, Findings.approve)
      (comp_possible q trivial
        (comp_possible (q, q) (point_possible (fun a : Patch => (a, a)) q)
          (kron_possible (point_possible id q) (pan q .approve))))
      (point_possible decodeVerdict (q, .approve))
  comp_possible s (comp_possible s (Or.inl (id_possible s)) (att s))
    (by rw [Term.muS_gateT_true]; trivial)

/-! ### (iii) One world, one run

The other fold. A `Runner` is the world decoded: given the scope in force and
the **key** of a consultation — the path to that occurrence through the written
term — it answers, or refuses. The key is computed by the fold from the syntax,
so what counts as "the same consultation" is decided by the term and not by the
runner, which is why sharing is observable at all. The world below is an *answer
sheet*, `Env (Key Lbl) String`: the design's ε, and exactly a session file.
Every theorem here is stated for an *arbitrary* sheet, so it describes the fold
at every sample point at once. -/

/-- What a reviewer does with its cell and the guide it was handed. The guide
*matters*: that is what makes the shared consultation observable. -/
def judge (cell : String) (guide : Guide) : Findings :=
  if guide == "pedantic" then .revise else if cell == "ok" then .approve else .revise

/-- **A runner backed by an answer sheet**: one outcome type for every question,
with the runner owning the decoder, as a real backend does with a wire format.
This world ignores the patch text — a legitimate sample point, and short. -/
def sheetRunner (ε : Env (Key Lbl) String) : Runner PatchOp Sc Lbl :=
  fun _ k => @fun _ _ op a =>
    match op, a with
    | .draft, _ | .style, _ => some (ε k)
    | .correct, (gd, _) | .secure, (gd, _) => some (judge (ε k) gd)
    | .simple, _ => some (judge (ε k) "")
    | .applyP, _ => some ()

/-! Where each consultation happens, reading the terms below from the root. No
path here is postulated: each is the site the fold computes, and the `rfl`s are
the check. `kGuide` is the one that is *rebased* — it records the label and the
path below it and nothing about where in the term the occurrence sits, which is
exactly why two occurrences of `share sg` collide. -/

def kCorrect : Key Lbl := .abs [.seqL, .seqR, .parL, .seqR]                       -- correctness
def kSecure : Key Lbl := .abs [.seqL, .seqR, .parR, .parL, .seqR]                 -- security
def kSimple : Key Lbl := .abs [.seqL, .seqR, .parR, .parR]                        -- simplicity
def kGuide : Key Lbl := .rel sg []                                                -- the shared guide
def kStyle₁ : Key Lbl := .abs [.seqL, .seqR, .parL, .seqL, .seqR, .parL]          -- unshared draw 1
def kStyle₂ : Key Lbl := .abs [.seqL, .seqR, .parR, .parL, .seqL, .seqR, .parL]   -- unshared draw 2
def kDraft (trip : Nat) : Key Lbl := .abs [.retry trip, .seqL, .seqL, .scope]     -- the trip-th draft

/-- **(4) The shared panel reads one guide cell, twice.** `ε kGuide` appears
twice on the right with one cell behind both: the two `share sg` occurrences
rebase to the same key, so the world is asked once and both reviewers read the
answer. -/
theorem review_reads_one_cell (ε : Env (Key Lbl) String) (p : Patch) :
    Term.muExt (sheetRunner ε) review LastOpt.unset Key.root p
      = some (mergeFindings (judge (ε kCorrect) (ε kGuide))
          (judge (ε kSecure) (ε kGuide)) (judge (ε kSimple) "")) := rfl

/-- **The one contrast definition**: the same panel with the sharing removed.
`review` writes `guided sg .style`, which is `briefed (share sg (ask .style))`;
this writes `briefed (ask .style)`. One word, and it is the word §6a is about. -/
def reviewDup : Wf .static Patch Findings :=
  panel₃ (briefed (ask .style) .correct) (briefed (ask .style) .secure)
    (ask .simple) mergeFindings

/-- **(5) The unshared panel reads two.** Same reviewers, same merge, and now
the guide is drawn twice — two independent samples, the default, and what a
designer who did not write `share` asked for. A sheet answering `kStyle₁` and
`kStyle₂` differently separates the two terms, and `Env.share_ne_dup` is why
that is a difference in *meaning* and not a missed cache hit. -/
theorem reviewDup_reads_two_cells (ε : Env (Key Lbl) String) (p : Patch) :
    Term.muExt (sheetRunner ε) reviewDup LastOpt.unset Key.root p
      = some (mergeFindings (judge (ε kCorrect) (ε kStyle₁))
          (judge (ε kSecure) (ε kStyle₂)) (judge (ε kSimple) "")) := rfl

-- Second-trip cells read `"ok"`, first-trip cells `"no"`, the shared guide lenient.
def sheetRevise : Env (Key Lbl) String
  | .abs s => if s.contains (Step.retry 1) then "ok" else "no"
  | .rel _ _ => "lenient"

/-- **(6) The first draft is rejected and the second is applied.** The answer is
the *trip-1* draft cell, not the trip-0 one, which is what it means for the loop
to have gone round: the trip index sits in every absolute key below a `retryT`,
so the second draft is a second draw and not a replay. The shared guide, whose
key carries no trip index at all, is drawn once for the *whole* loop — a
designer wanting a fresh guide per attempt must label inside the loop body. -/
theorem revise_loop_runs :
    Term.muExt (sheetRunner sheetRevise) (loop 2 attempt) LastOpt.unset Key.root "spec"
      = some (sheetRevise (kDraft 1)) := rfl

/-! ## 6. Realization notes — where a realization must differ

Everything above is a specification: it says what the workflow *means*, and it
never runs. The mapping onto the `agent-functor`/`incite` line, and — the useful
part — the four places an implementation must **differ**.

* **The leaves and the price book.** `PatchOp` is the `Op` an ACP backend
  interprets; a real leaf adds a prompt template, a schema, a timeout, a wire.
  Its failure mode is already here: a reply that will not parse is a refusal,
  `none` in `muExt` and `0` in `muS`, annihilating exactly as a withheld consent
  does — the one thing an implementation must not "improve" on by throwing.
  `Interp` prices it, and by returning a *matrix* it already allows per-token
  prices; read into `Prop` the same registry is a feasibility check, into `ℝ≥0∞`
  a consensus weight. Hard-coding the cost fold (the audit's finding against
  `agent-functor`) costs a new traversal per question; the semiring parameter is
  one type argument.
* **The store, and what a cell is keyed by.** A session file *is* `ε` restricted
  to the keys asked; replay is the identity on meanings and fork is `Env.pin`.
  But a cell is keyed here by *position in the term* and in a content-addressed
  store by *hash of the request*, and the gap between those two equivalence
  relations is exactly `review` versus `reviewDup`: content addressing silently
  merges two draws into one, collapsing an ensemble and leaving the variance
  wrong while the support stays right. Key by content **only** where the leaf is
  deterministic. Likewise `share` ↔ `leafKey`: the fold keys on the label alone
  and never compares bodies (acat-bmc), so labels generated from source position
  are safe and labels taken from user configuration are not. And innermost-wins
  is not code — it is `LastOpt`'s non-commutativity, so `under` is got right by
  using a monoid and wrong by writing an interpreter rule.
* **What may be quoted before spending.** `.static` is an exact quote
  (`cost_harden`'s 10200), `.bounded n` a supremum honestly labelled (`perFile`
  quotes eight), `.monadic` a refusal to quote — the truth, not an evasion.
* **Where the spec is not the run.** `muExt run` is the meaning *at* a world; a
  real run samples one, so a passing run proves nothing and a theorem quantified
  over `ε` proves everything. `muExt` also runs a tensor left-first and
  short-circuits, so a parallel strategy consults sites the spec says are never
  reached — `muS` is symmetric, so the *cost* is unchanged, and the extra
  consultations are the implementation's business, not answers the workflow may
  read. Finally, bounds must be enforced and not intended: `fanT n` truncates
  *in the meaning*, so an uncapped parallel map denotes a different workflow,
  and `gateT`'s `Bool` wants to become a lattice of permissions, which the
  semantics is ready for, gating being the action of a scalar (acat-755).
-/

end HardenPatch

end Examples

end Agentic
