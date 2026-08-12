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

## The vocabulary

Every combinator this file writes, and nothing else. Read the table before §3
and §3 needs no glossary. `f` is the grade of the annotated or composed part,
`Wf f i o` is this example's `Term PatchOp Sc Lbl f i o`.

| combinator | reads as | denotes | grade |
| --- | --- | --- | --- |
| `ask op` | consult `op`, once | this leaf's matrix; the world's answer at this occurrence's key | `.static` |
| `fn h` | compute `h` locally | `Mat.pointMat h`; `some ∘ h` | `.static` |
| `w >>> v` | then | `Mat.comp` (Chapman–Kolmogorov); `Option`-bind | `f.join g` |
| `keep w` | run `w`, keep the input beside it | the diagonal, then `idMat ⊗ w` | `f` |
| `panel rs` | ask all of them, combine the verdicts | `⊗` of the members, folded by the monoid on `o` | `Frag.parN rs.length f` |
| `briefed aside r` | consult `r`, handed what `aside` said | `aside ⊗ id`, then the leaf | `.static` |
| `guided l q r` | …handed the *shared* briefing | the same, with every `l` reading one cell | `.static` |
| `share l w` | ask once, read twice | rebases the sites inside `w` onto `l` | `f` |
| `under g w` | run `w` in this scope | precomposition on the reader | `f` |
| `gate b w` | only with permission | the scalar action of an indicator; refusal is `0` | `f` |
| `loop n w` | up to `n` more tries | the truncated star `(M_A · d)^{≤n} · M_B` | `f` |
| `Term.fanT n w` | one `w` per item, at most `n` | the fold truncated at `n` | `f.scale n` |

`share` is written here only inside `guided`, and `Term.fanT` only in
`perFile`; the other ten are the workflow. The two columns that carry the
argument are the third and the fourth: the *denotation* is what the term means
in whatever carrier is chosen, and the *grade* is what the type already knows
before a carrier is chosen at all.
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

/-- **The panel's reducer, as the monoid it is.** `Term.panel` asks for a
`Monoid` on the verdict type and for nothing else, and this is that monoid:
`*` is `meet`, `1` is `approve`. The three laws are the three cases; what a
`Monoid` deliberately does *not* carry is the other two licences below, because
`panel` does not need them and charging for them here would misprice the
scheduler's freedom (`Agentic.Panel`'s "two reorderings, two licences"). -/
instance : Monoid Findings where
  mul := Findings.meet
  one := .approve
  mul_assoc a b c := by cases a <;> cases b <;> cases c <;> rfl
  one_mul _ := rfl
  mul_one a := by cases a <;> rfl

/-- Unfolding: the monoid's `*` is `meet`, definitionally. -/
theorem Findings.mul_def (a b : Findings) : a * b = a.meet b := rfl

/-- **The reordering licence**, which `panel` does not require: the members of
a panel may be consulted in any order, because their verdicts commute. -/
theorem Findings.meet_comm (a b : Findings) : a * b = b * a := by
  cases a <;> cases b <;> rfl

/-- **The duplication licence**, which `panel` does not require either: the
same verdict counted twice counts once, so a race between two copies of one
reviewer is the reviewer. -/
theorem Findings.meet_idem (a : Findings) : a * a = a := by cases a <;> rfl

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
is asked naively. The list is the panel — its length is the panel's arity, and
`Frag.parN 3 .static = .static` is why this signature needs no cast. -/
def review : Wf .static Patch Findings :=
  panel
    [ guided sg .style .correct   -- correctness, against the guide shared under `sg`
    , guided sg .style .secure    -- security, against the *same* cell of the world
    , ask .simple ]               -- simplicity, asked with no briefing at all
    -- fan-in is `Findings`' monoid: any objection carries, `approve` is the unit

/-- One attempt: draft under the deep model, keep the patch beside its review,
decode the verdict. -/
def attempt : Wf .static Spec (Sum Patch Spec) :=
  under deepModel (ask .draft)  -- the expensive model, for this stage only
    >>> keep review             -- the patch is still needed after the verdict
    >>> fn decodeVerdict        -- (patch, verdict) ↦ done | go round again

/-- The whole workflow: at most three attempts, then the tool call behind a
consent gate. `consent` is a parameter because a written term is a finite datum
— the guard's `Bool` has to be supplied when the term is built. -/
def harden (consent : Bool) : Wf .static Spec Unit :=
  loop 2 attempt                 -- one attempt, then at most two more
    >>> gate consent (ask .applyP)  -- the effect, and the only one

/-- The dynamic counterpart of the fixed panel: one simplicity review per file
the draft touched, at most eight, the list's length being a value. -/
def perFile : Wf (.bounded 8) (List Patch) (List Findings) := Term.fanT 8 (ask .simple)

/-! ## 4. The grades

`rfl` closes each: `Frag`'s arithmetic is not a decision procedure run at the
use site, it is already the answer. -/

/-- **The whole workflow is static** — gate, loop, panel and all — so every
a-priori instrument over `harden` is exact. -/
example (c : Bool) : Term.grade (harden c) = .static := rfl

/-- The panel's grade is a function of the list the designer wrote: three
members, each static, `Frag.parN 3 .static`, which *is* `.static`. -/
example : Term.grade review = Frag.parN 3 .static := rfl

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
decoding and merging cost nothing — and so does the empty panel, which is a
`Transform` and nothing else. -/
theorem pointMat_costBounded (h : ι → κ) :
    Mat.CostBounded 0 (Mat.pointMat h : Mat Cost ι κ) := by
  intro a b; by_cases hb : h a = b
  · subst hb; rw [Mat.pointMat_apply_self, Cost.fin_zero_eq_one]
  · rw [Mat.pointMat_apply_ne hb]; exact Cost.bot_le _

/-- **Branches in flight add** — a Kronecker entry is a product of entries, the
same arithmetic `Frag.par` does on widths one stratum up, and the same
arithmetic `Frag.parN` iterates for a panel. -/
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
in it (the `keep` wire, the copies, the decoder, the merges) is free, and so is
the empty panel that closes the fold.

The proof's shape is the panel's recursion, read outwards: `[]` at 0, `[simple]`
at 400, `[secure, simple]` at 900, `[correct, secure, simple]` at 1400. A fixed
`panel₃` hid that nesting behind a 3-ary merge; the `n`-ary panel puts it in the
proof, where it is one `kron_costBounded` per member and reads as the sum it
is. -/
theorem cost_attempt (g : Sc) : Mat.CostBounded 3400 (Term.muS costInterp attempt g) :=
  have brief : ∀ r : PatchOp (Guide × Patch) Findings, price g r = 400 →
      Mat.CostBounded 500 (Term.muS costInterp (guided sg .style r : Wf .static Patch Findings) g) :=
    fun r h => Mat.costBounded_mono (k := 0 + (100 + 0) + price g r) (by omega)
      (Mat.comp_costBounded (Mat.comp_costBounded (pointMat_costBounded _)
        (kron_costBounded (const_costBounded 100) (pointMat_costBounded _)))
        (const_costBounded (price g r)))
  -- the empty panel that closes the fold: a `Transform`, hence free
  have panel₀ := pointMat_costBounded (ι := Patch) (κ := Findings) (fun _ => (1 : Findings))
  Mat.costBounded_mono (by norm_num) <|
    Mat.comp_costBounded
      (Mat.comp_costBounded (const_costBounded 2000)
        (Mat.comp_costBounded (pointMat_costBounded _)
          (kron_costBounded (pointMat_costBounded _)
            -- `review` = the panel of three, each level a copy, a tensor, a merge
            (Mat.comp_costBounded
              (Mat.comp_costBounded (pointMat_costBounded _)
                (kron_costBounded (brief .correct rfl)
                  (Mat.comp_costBounded
                    (Mat.comp_costBounded (pointMat_costBounded _)
                      (kron_costBounded (brief .secure rfl)
                        (Mat.comp_costBounded
                          (Mat.comp_costBounded (pointMat_costBounded _)
                            (kron_costBounded (const_costBounded 400) panel₀))
                          (pointMat_costBounded _))))
                    (pointMat_costBounded _))))
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
permission is a scalar.

`pan` is where the `n`-ary panel shows in a proof: one `comp`/`kron`/`merge`
triple per member, nested to the right, closed by the unit. Every merge but the
innermost reduces on the nose, `approve * v` being `v` by `Findings.meet`'s
first equation; the innermost is `v * 1`, which is `mul_one` — the monoid law,
present exactly because `panel` asked for a `Monoid`, and discharged here by
the verdict's two cases (`mrg1`). -/
theorem harden_possible (g : Sc) (s : Spec) : Term.muS possible (harden true) g s () :=
  have rev : ∀ (r : PatchOp (Guide × Patch) Findings) (p : Patch) (v : Findings),
      Term.muS possible (guided (Op := PatchOp) (G := Sc) sg .style r) g p v := fun _ p _ =>
    comp_possible ("", p) (comp_possible ((), p) (point_possible _ p)
      (kron_possible trivial (point_possible id p))) trivial
  have mrg : ∀ q : Findings × Findings,
      (Mat.pointMat (fun p : Findings × Findings => p.1 * p.2) : Mat Prop _ Findings) q (q.1 * q.2) :=
    fun q => point_possible (fun p : Findings × Findings => p.1 * p.2) q
  have mrg1 : ∀ w : Findings,
      (Mat.pointMat (fun p : Findings × Findings => p.1 * p.2) : Mat Prop _ Findings) (w, 1) w := by
    intro w; cases w <;> exact point_possible (fun p : Findings × Findings => p.1 * p.2) _
  have pan : ∀ (p : Patch) (v : Findings), Term.muS possible review g p v := fun p v =>
    comp_possible (Findings.approve, v)
      (comp_possible (p, p) (point_possible (fun a : Patch => (a, a)) p)
        (kron_possible (rev .correct p .approve)
          (comp_possible (Findings.approve, v)
            (comp_possible (p, p) (point_possible (fun a : Patch => (a, a)) p)
              (kron_possible (rev .secure p .approve)
                (comp_possible (v, (1 : Findings))
                  (comp_possible (p, p) (point_possible (fun a : Patch => (a, a)) p)
                    (kron_possible trivial (point_possible (fun _ : Patch => (1 : Findings)) p)))
                  (mrg1 v))))
            (mrg (Findings.approve, v)))))
      (mrg (Findings.approve, v))
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
the check.

**The paths are the `n`-ary panel's recursion.** `panel [a, b, c]` is
`fn copy >>> parT a (panel [b, c]) >>> fn merge`, so the head member sits at
`[.seqL, .seqR, .parL]` and the *rest of the panel* at `[.seqL, .seqR, .parR]`:
each successive member is one `[.seqL, .seqR, .parR]` deeper than the last. That
is a real change from the fixed `panel₃`, whose three members sat at `parL`,
`parR/parL` and `parR/parR` — the first member's path is unchanged, the second's
and the third's are longer. A key is a fact about a written term, and the term
was rewritten.

`kGuide` is the one that is *rebased* — it records the label and the path below
it and nothing about where in the term the occurrence sits, which is exactly why
two occurrences of `share sg` collide, and why lengthening the panel's spine did
not move it. -/

-- correctness: panel member 0, then the leaf of `briefed`
def kCorrect : Key Lbl := .abs [.seqL, .seqR, .parL, .seqR]
-- security: one panel step in, then member 0 of the tail, then the leaf
def kSecure : Key Lbl := .abs [.seqL, .seqR, .parR, .seqL, .seqR, .parL, .seqR]
-- simplicity: two panel steps in, then member 0 of that tail; no briefing to pass
def kSimple : Key Lbl := .abs [.seqL, .seqR, .parR, .seqL, .seqR, .parR, .seqL, .seqR, .parL]
-- the shared guide: rebased onto the label, so it carries no path at all
def kGuide : Key Lbl := .rel sg []
-- the two unshared draws of the guide in `reviewDup`, at the two briefing sites
def kStyle₁ : Key Lbl := .abs [.seqL, .seqR, .parL, .seqL, .seqR, .parL]
def kStyle₂ : Key Lbl :=
  .abs [.seqL, .seqR, .parR, .seqL, .seqR, .parL, .seqL, .seqR, .parL]
-- the trip-th draft, the trip index sitting above the whole attempt
def kDraft (trip : Nat) : Key Lbl := .abs [.retry trip, .seqL, .seqL, .scope]

/-- **(4) The shared panel reads one guide cell, twice.** `ε kGuide` appears
twice on the right with one cell behind both: the two `share sg` occurrences
rebase to the same key, so the world is asked once and both reviewers read the
answer.

The right-hand side is the panel's fold written out — `v₀ * (v₁ * (v₂ * 1))` —
and the trailing `1` is the empty panel, the term `fn (fun _ => 1)` that closes
the recursion. It is not noise: it is what makes the arity a property of the
list rather than of the combinator's name. -/
theorem review_reads_one_cell (ε : Env (Key Lbl) String) (p : Patch) :
    Term.muExt (sheetRunner ε) review LastOpt.unset Key.root p
      = some (judge (ε kCorrect) (ε kGuide)
          * (judge (ε kSecure) (ε kGuide) * (judge (ε kSimple) "" * 1))) := rfl

/-- The same read-out with the unit discharged, which is all `mul_one` is for:
the empty panel contributes the identity and then goes away. -/
theorem review_reads_one_cell' (ε : Env (Key Lbl) String) (p : Patch) :
    Term.muExt (sheetRunner ε) review LastOpt.unset Key.root p
      = some (judge (ε kCorrect) (ε kGuide)
          * (judge (ε kSecure) (ε kGuide) * judge (ε kSimple) "")) := by
  simpa using review_reads_one_cell ε p

/-- **The one contrast definition**: the same panel with the sharing removed.
`review` writes `guided sg .style`, which is `briefed (share sg (ask .style))`;
this writes `briefed (ask .style)`. One word, and it is the word §6a is about. -/
def reviewDup : Wf .static Patch Findings :=
  panel [briefed (ask .style) .correct, briefed (ask .style) .secure, ask .simple]

/-- **(5) The unshared panel reads two.** Same reviewers, same merge, and now
the guide is drawn twice — two independent samples, the default, and what a
designer who did not write `share` asked for. A sheet answering `kStyle₁` and
`kStyle₂` differently separates the two terms, and `Env.share_ne_dup` is why
that is a difference in *meaning* and not a missed cache hit. -/
theorem reviewDup_reads_two_cells (ε : Env (Key Lbl) String) (p : Patch) :
    Term.muExt (sheetRunner ε) reviewDup LastOpt.unset Key.root p
      = some (judge (ε kCorrect) (ε kStyle₁)
          * (judge (ε kSecure) (ε kStyle₂) * (judge (ε kSimple) "" * 1))) := rfl

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
  deterministic. Positional keying has its own liability, and §5's key table is
  where it shows: adding a fourth reviewer to `panel` lengthens the spine and
  *renames* every member below the insertion point, so a session file is
  invalidated by an edit that changed nobody's prompt. That is the honest price
  of "a site is a position", and a store that wants edit-stable keys must earn
  them with a labelling (`share`) rather than by hashing behind the designer's
  back. Likewise `share` ↔ `leafKey`: the fold keys on the label alone and never
  compares bodies (acat-bmc), so labels generated from source position are safe
  and labels taken from user configuration are not. And innermost-wins is not
  code — it is `LastOpt`'s non-commutativity, so `under` is got right by using a
  monoid and wrong by writing an interpreter rule.
* **What may be quoted before spending.** `.static` is an exact quote
  (`cost_harden`'s 10200), `.bounded n` a supremum honestly labelled (`perFile`
  quotes eight), `.monadic` a refusal to quote — the truth, not an evasion. A
  panel quotes `Frag.parN rs.length f`, so the quote grows with the list and
  needs no new combinator to do it.
* **Where the spec is not the run.** `muExt run` is the meaning *at* a world; a
  real run samples one, so a passing run proves nothing and a theorem quantified
  over `ε` proves everything. `muExt` also runs a tensor left-first and
  short-circuits, so a parallel strategy consults sites the spec says are never
  reached — `muS` is symmetric, so the *cost* is unchanged, and the extra
  consultations are the implementation's business, not answers the workflow may
  read. The panel's fold is right-nested and its reducer is a monoid, which is
  the licence to reduce members as they land rather than in written order;
  reordering the *members* is a further licence (`Findings.meet_comm`) and racing
  duplicates a further one still (`Findings.meet_idem`), and an implementation
  that helps itself to either without the corresponding law is not implementing
  this term. Finally, bounds must be enforced and not intended: `fanT n`
  truncates *in the meaning*, so an uncapped parallel map denotes a different
  workflow, and `gateT`'s `Bool` wants to become a lattice of permissions, which
  the semantics is ready for, gating being the action of a scalar (acat-755).
-/

end HardenPatch

end Examples

end Agentic
