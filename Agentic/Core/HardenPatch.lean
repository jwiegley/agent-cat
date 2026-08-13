import Agentic.Core.Morphism

/-!
# `hardenPatch`, as a `Plan`, and six theorems about its meaning

Stage 5. `example/HardenPatch.lean` writes the owner's workflow in twelve lines
of authoring surface; this module writes the *same* workflow as a term of the
first-order syntax `Plan` and proves, **in the meaning space**, the six things
the kernel promises about it.

Nothing here is a statement about the shape of a term. Every theorem quantifies
over worlds and speaks of `run` or `trace` of `⟦hardenPatch⟧`, except the one
that is *about* the fold (`level_hardenPatch`) and exists precisely to license
the branch-rung cost theorems on this workload.

The method is the doctrine's: **the meaning is written first** (`hardenD`, an
ordinary recursion over `Dlg`), the plan second, and the two are joined by one
morphism equation (`denote_hardenPatch`). Every subsequent proof is about
`hardenD`, which is a five-line dialogue, and not about the unrolled term, which
is fifteen consultations deep.
-/

namespace Agentic.Core

namespace Harden

open Plan (Cont)

/-! ## The questions

Eight questions, one per thing the workflow says, and seven distinct
addressees —
which is load-bearing rather than cosmetic: the addressee is a field of
`Q.shape`, so "the guide was read once" and "at most three drafts were asked
for" are statements about a *shape*, provable without ever comparing prompt
text. -/

/-- Under which model the drafting happens. `[[deep]] = atModel "deep"`, the
scope override the surface writes as `model "deep" <| …`. -/
def deep : Sig := atModel "deep"

/-! ### How an answer must be spelled

Two constants, because two of the four codes have an answer set smaller than
what an addressee can say, and a question that does not say which words it wants
is a question a real model answers in prose.

They are *the same words* `Exec.answerSpec` puts in the header of every question
(`demo/Main.lean` proves the two agree, by `rfl`, in the one module that imports
both): a prompt telling an addressee two different formats is a prompt that
gets neither. -/

/-- `[[verdictSpec]]` = how a reviewer must answer. `APPROVE` is the unit of the
verdict monoid and `OBJECTION: …` is one line of `Verdict.object`, so the two
spellings are the two constructors and there is no third. -/
def verdictSpec : String :=
  "Reply with exactly APPROVE if acceptable, or OBJECTION: <one line> if not."

/-- `[[flagSpec]]` = how a yes/no question must be answered. -/
def flagSpec : String := "Reply with exactly yes or no."

/-- `[[guideQ]]` = the one closed question of the workflow: read the house style
guide. Closed, so the plan starts at the `batch` rung. -/
def guideQ : Q .text :=
  { addressee := .tool "cat", scope := 1,
    prompt := "Write out the house style guide, at most four short lines.",
    draw := 0 }

/-- `[[authorShape]]` = whom a patch is asked of, and under what: the shape
shared by the first draft and every revision. Written in the term at both
nodes, which is what makes "at most three drafts" a statement about shapes. -/
def authorShape : Q.Shape .text := { addressee := .model "author", scope := 1, draw := 0 }

/-- `[[draftText spec]]` = the words of the first draft request: the
specification, and the format the answer must take — a patch, and only a patch,
because the answer is quoted verbatim into three reviewers' prompts and into the
act. -/
def draftText (spec : String) : String :=
  "Draft a patch satisfying:\n" ++ spec ++ "\nReply with a unified diff only."

/-- `[[draftQ spec]]` = ask the author for a first patch meeting `spec`. -/
def draftQ (spec : String) : Q .text := authorShape.withPrompt (draftText spec)

/-- `[[objections v]]` = the reasons a verdict gave; `[]` if it declined. The
projection that lets a revision be told *what* was wrong (kernel §3 q5, and
`attack-adequacy` §2.3's second correction to the incumbent). -/
def objections (v : Verdict) : List Objection :=
  if h : v = 0 then [] else FreeMonoid.toList (WithZero.unzero h)

/-- `[[render v]]` = a verdict as text an addressee can read. -/
def render (v : Verdict) : String := String.intercalate "; " (objections v)

/-- `[[reviseText guide patch v]]` = the words of a revision request: the guide,
the patch and what the reviewers objected to. Everything an answer reaches. -/
def reviseText (guide patch : String) (v : Verdict) : String :=
  guide ++ "\nRevise this patch:\n" ++ patch ++ "\n" ++ render v ++
    "\nReply with the revised diff only."

/-- `[[reviseQ guide patch v]]` = ask the author to revise `patch`, quoting the
guide **and the objections**. -/
def reviseQ (guide patch : String) (v : Verdict) : Q .text :=
  authorShape.withPrompt (reviseText guide patch v)

/-- `[[correctShape]]` = whom the correctness review goes to. -/
def correctShape : Q.Shape .verdict :=
  { addressee := .model "reviewer-correct", scope := 1, draw := 0 }

/-- `[[correctText guide patch]]` = what is said to the correctness reviewer. -/
def correctText (guide patch : String) : String :=
  guide ++ "\nIs this patch correct?\n" ++ patch ++ "\n" ++ verdictSpec

/-- `[[correctQ guide patch]]` = the correctness reviewer, quoting the guide. -/
def correctQ (guide patch : String) : Q .verdict :=
  correctShape.withPrompt (correctText guide patch)

/-- `[[secureShape]]` = whom the security review goes to. -/
def secureShape : Q.Shape .verdict :=
  { addressee := .model "reviewer-secure", scope := 1, draw := 0 }

/-- `[[secureText guide patch]]` = what is said to the security reviewer. -/
def secureText (guide patch : String) : String :=
  guide ++ "\nIs this patch secure?\n" ++ patch ++ "\n" ++ verdictSpec

/-- `[[secureQ guide patch]]` = the security reviewer, quoting the same guide. -/
def secureQ (guide patch : String) : Q .verdict :=
  secureShape.withPrompt (secureText guide patch)

/-- `[[simplerShape]]` = whom the simplicity review goes to. -/
def simplerShape : Q.Shape .verdict :=
  { addressee := .model "reviewer-simple", scope := 1, draw := 0 }

/-- `[[simplerText patch]]` = what is said to the simplicity reviewer, who does
not need the guide. -/
def simplerText (patch : String) : String :=
  "Could this patch be simpler?\n" ++ patch ++ "\n" ++ verdictSpec

/-- `[[simplerQ patch]]` = the simplicity reviewer, who does not need the
guide. -/
def simplerQ (patch : String) : Q .verdict := simplerShape.withPrompt (simplerText patch)

/-- `[[consentShape]]` = whom consent is asked of. A person is an addressee like
any other (§3 q7); nothing about this node is a construct. -/
def consentShape : Q.Shape .flag := { addressee := .person "owner", scope := 1, draw := 0 }

/-- `[[consentText patch]]` = what the owner is shown. -/
def consentText (patch : String) : String :=
  "Apply this patch?\n" ++ patch ++ "\n" ++ flagSpec

/-- `[[consentQ patch]]` = ask the owner whether to apply. -/
def consentQ (patch : String) : Q .flag := consentShape.withPrompt (consentText patch)

/-- `[[applyShape]]` = the addressee of the terminal act: the tool that applies
the patch. -/
def applyShape : Q.Shape .ack := { addressee := .tool "apply", scope := 1, draw := 0 }

/-- `[[applyText patch]]` = what is said to it: the patch, and the act itself
spelled out — write the file, *here*, and say so. "Here" is the session's
working directory, which `demo/Main.lean` makes a fresh scratch directory for a
live run, so the act is confined to somewhere nobody minds. -/
def applyText (patch : String) : String :=
  "Apply:\n" ++ patch ++ "\nWrite the patched file here, then reply DONE."

/-- `[[applyQ patch]]` = the terminal act, addressed to the tool that applies
it. The only `.ack` question in the workflow, which is what makes "the apply
question was not put" a statement about codes. -/
def applyQ (patch : String) : Q .ack := applyShape.withPrompt (applyText patch)

/-! ## The meaning, written first

`hardenD` is what the workflow *is*: a world-indexed (answer, transcript) pair,
presented as a dialogue. It is an ordinary recursion in the metalanguage, reads
like the twelve lines of the surface, and is the object every theorem below is
about. The plan comes next and is joined to it by one equation. -/

/-- `[[panelD guide patch]]` = the three reviewers, in order, their verdicts
combined in the verdict monoid. The reducer is `Monoid.mul` and nothing else
(§3 q6). -/
def panelD (guide patch : String) : Dlg (El .verdict) :=
  Dlg.ask1 .verdict (correctQ guide patch) >>= fun v₁ =>
  Dlg.ask1 .verdict (secureQ guide patch) >>= fun v₂ =>
  Dlg.ask1 .verdict (simplerQ patch) >>= fun v₃ =>
  pure (v₁ * (v₂ * v₃))

/-- `[[redraftD guide patch v]]` = one revision, under the deep model, told what
the reviewers objected to. -/
def redraftD (guide patch : String) (v : Verdict) : Dlg (El .text) :=
  Dlg.ask1 .text (deep.onQ .text (reviseQ guide patch v))

/-- `[[loopD guide n patch]]` = review `patch`; if the panel approves, stop with
it; otherwise revise and go again, at most `n` more times; if the last review
still objects, give up with `none`.

**Check first, revise in the recursive call** (kernel §3 q5): `loopD guide n`
performs `n + 1` panels and at most `n` revisions, and never pays for a revision
it does not review. -/
def loopD (guide : String) : Nat → El .text → Dlg (Option (El .text))
  | 0, a => panelD guide a >>= fun v => pure (if Verdict.approvedB v then some a else none)
  | n + 1, a => panelD guide a >>= fun v =>
      if Verdict.approvedB v then pure (some a)
      else redraftD guide a v >>= fun a' => loopD guide n a'

/-- `[[finishD o]]` = if the loop produced a patch, ask the owner and apply only
if the owner said yes; if it gave up, do nothing. The gate is `case` on a
`Bool`, so both arms are in the term and the not-taken arm costs nothing on the
taken path (§3 q8). -/
def finishD : Option (El .text) → Dlg Unit
  | none => pure ()
  | some patch =>
      Dlg.ask1 .flag (consentQ patch) >>= fun ok =>
        if ok = true then Dlg.ask1 .ack (applyQ patch) >>= fun _ => pure () else pure ()

/-- `[[hardenD spec]]` = the workflow. Read the guide; draft under the deep
model; review-and-revise up to twice; ask the owner; apply if and only if the
owner consented. -/
def hardenD (spec : String) : Dlg Unit :=
  Dlg.ask1 .text guideQ >>= fun guide =>
  Dlg.ask1 .text (deep.onQ .text (draftQ spec)) >>= fun draft =>
  loopD guide 2 draft >>= fun final =>
  finishD final

/-! ## The plan

The same workflow as a term of the five formers. Read it against `hardenD`: one
`askC` for the guide, one `askC` under `deep` for the draft, `revising` for the
bounded loop, and two `caseB`s for "did the loop produce a patch" and "did the
owner consent". -/

/-- `[[review]]` = the panel, as a continuation of the loop: `check`, in
`revising`'s sense. **Morphism equation** (`denotes_review`): it denotes
`panelD` at the guide in scope. -/
def review : Cont [.text] (El .text) Verdict := fun _ σ patch =>
  Plan.panel
    [ Plan.ask1 .verdict correctShape (fun δ => correctText (σ δ).head (patch δ)),
      Plan.ask1 .verdict secureShape (fun δ => secureText (σ δ).head (patch δ)),
      Plan.ask1 .verdict simplerShape (fun δ => simplerText (patch δ)) ]

/-- `[[redraft]]` = the revision, as a continuation of the loop: `revise`, in
`revising`'s sense, with the verdict threaded into the prompt. **Morphism
equation** (`denotes_redraft`): it denotes `redraftD`. -/
def redraft : Cont [.text] (El .text × Verdict) (El .text) := fun _ σ av =>
  Plan.under deep
    (Plan.ask1 .text authorShape (fun δ => reviseText (σ δ).head (av δ).1 (av δ).2))

/-- `[[patchOf o]]` = the patch the loop produced, or `""` where it produced
none. Only ever read on the arm where the loop *did* produce one; the fallback
is unreachable and the two theorems about consent say so. -/
def patchOf (o : Option (El .text)) : El .text := o.getD ""

/-- `[[finishK Γ]]` = the tail of the workflow, as a continuation: if the loop
produced a patch, ask the owner and apply only if the owner consented.

Context-polymorphic in the trivial way — it reads only the loop's answer, never
what was bound before it — which is exactly the coherence `Plan.Denotes`
demands. -/
def finishK (Γ : Ctx) : Cont Γ (Option (El .text)) Unit := fun _ _ final =>
  -- if the loop produced a patch …
  Plan.caseB (fun θ => (final θ).isSome)
    -- … ok ← askHuman "Apply this patch?" ; if ok then ask "Apply: …"
    (Plan.ask .flag consentShape (fun θ => consentText (patchOf (final θ)))
      (Plan.caseB (fun θ => θ.head)
        (Plan.ask .ack applyShape (fun θ => applyText (patchOf (final θ.tail)))
          (.ret fun _ => ()))
        (.ret fun _ => ())))
    (.ret fun _ => ())

/-- `[[bodyK]]` = the body of the workflow after the draft: review-and-revise up
to twice, then finish. -/
def bodyK : Cont [.text] (El .text) Unit := fun Δ σ draft =>
  -- final ← revising (panel …) (redraft …) 2 draft
  Plan.graft (Plan.revising review redraft 2 Δ σ draft) (finishK Δ)

/-- `[[hardenPatch spec]]` = the owner's workflow as a `Plan`.

**Morphism equation** (`denote_hardenPatch`): `⟦hardenPatch spec⟧ · = hardenD spec`. -/
def hardenPatch (spec : String) : Plan [] Unit :=
  -- guide ← ask "Write out the house style guide."
  .askC .text guideQ <|
    -- draft ← model "deep" <| ask "Draft a patch satisfying: …"
    Plan.graft (Plan.under deep (Plan.askC1 .text (draftQ spec))) bodyK

/-! ## The morphism equation: the plan means the dialogue

One equation joins the two halves. Everything after it is a theorem about
`hardenD`, i.e. about the meaning, and never about the term. -/

/-- `[[Kreview]]` = the semantic continuation of `review`: the panel, read at
the guide in scope. -/
def Kreview : El .text → Env [.text] → Dlg Verdict := fun patch γ => panelD γ.head patch

/-- `[[Kredraft]]` = the semantic continuation of `redraft`. -/
def Kredraft : El .text × Verdict → Env [.text] → Dlg (El .text) :=
  fun av γ => redraftD γ.head av.1 av.2

/-- **The panel square, at this workload.** -/
theorem denotes_review : Plan.Denotes review Kreview := by
  intro Δ σ e δ
  show denote (Plan.panel _) δ = _
  rw [Morphism.denote_panel]
  simp only [List.map_cons, List.map_nil, List.foldr_cons, List.foldr_nil, denote_ask1,
    Kreview, panelD, correctQ, secureQ, simplerQ, seq_eq_bind_map, map_eq_pure_bind,
    bind_assoc, pure_bind, mul_one]

/-- **The revision square, at this workload.** -/
theorem denotes_redraft : Plan.Denotes redraft Kredraft := by
  intro Δ σ e δ
  simp [redraft, Kredraft, redraftD, reviseQ, Plan.ask1, Dlg.ask1, Plan.under, denote,
    Sig.onQ]

/-- **The loop square.** `revising`'s semantic loop, instantiated here, *is*
`loopD` — two independently written recursions agreeing at every fuel. -/
theorem reviseLoop_eq_loopD (n : Nat) (a : El .text) (γ : Env [.text]) :
    reviseLoop Kreview Kredraft n a γ = loopD γ.head n a := by
  induction n generalizing a with
  | zero => rfl
  | succ n ih =>
    show reviseLoop Kreview Kredraft (n + 1) a γ = loopD γ.head (n + 1) a
    rw [Morphism.reviseLoop_succ]
    simp only [loopD, Kreview, Kredraft]
    refine congrArg _ (funext fun v => ?_)
    by_cases h : Verdict.approvedB v = true
    · simp [h]
    · simp only [h, if_false, Bool.false_eq_true]
      exact congrArg _ (funext fun a' => ih a')

/-- **The consent-gate square.** The tail of the workflow means `finishD`, in
every context: the gate is `case` on a `Bool` and nothing else. -/
theorem denotes_finishK (Γ : Ctx) :
    Plan.Denotes (finishK Γ) (fun o (_ : Env Γ) => finishD o) := by
  intro Δ σ e δ
  show denote (finishK Γ Δ σ e) δ = _
  cases h : e δ with
  | none => simp [finishK, finishD, h]; rfl
  | some patch =>
    simp only [finishK, denote_caseB, h, Option.isSome_some, if_true, finishD, patchOf,
      Option.getD_some, denote_ask, Dlg.ask1]
    refine congrArg _ (funext fun ok => ?_)
    by_cases hok : ok = true
    · simp only [hok, if_true, Env.head_cons, Env.tail_cons, h, Option.getD_some,
        denote_ret]
      rfl
    · simp only [hok, Env.head_cons, denote_ret]
      rfl

/-- `[[Kbody]]` = the semantic continuation of the workflow's body: the bounded
loop, then the consent gate. -/
def Kbody : El .text → Env [.text] → Dlg Unit := fun draft γ =>
  loopD γ.head 2 draft >>= fun final => finishD final

/-- **The body square.** -/
theorem denotes_bodyK : Plan.Denotes bodyK Kbody := by
  intro Δ σ draft δ
  show denote (Plan.graft (Plan.revising review redraft 2 Δ σ draft) (finishK Δ)) δ = _
  rw [Agentic.Core.denote_graft _ (fun o (_ : Env Δ) => finishD o) _ (denotes_finishK Δ) δ,
    denotes_revising denotes_review denotes_redraft 2 Δ σ draft δ, reviseLoop_eq_loopD]
  rfl

/-- **The workflow square.** `⟦hardenPatch spec⟧ · = hardenD spec`: the term of
the first-order syntax means the dialogue written at the top of this module.

This is the only bridge between the two halves, and every theorem below is on
the meaning side of it. -/
theorem denote_hardenPatch (spec : String) :
    denote (hardenPatch spec) Env.nil = hardenD spec := by
  have key : ∀ guide : El .text,
      denote (Plan.graft (Plan.under deep (Plan.askC1 .text (draftQ spec))) bodyK)
          (Env.cons guide Env.nil)
        = (Dlg.ask1 .text (deep.onQ .text (draftQ spec)) >>= fun draft =>
            loopD guide 2 draft >>= fun final => finishD final) := by
    intro guide
    rw [Agentic.Core.denote_graft _ Kbody bodyK denotes_bodyK (Env.cons guide Env.nil)]
    rfl
  show Dlg.ask .text guideQ
      (fun guide => denote (Plan.graft (Plan.under deep (Plan.askC1 .text (draftQ spec))) bodyK)
        (Env.cons guide Env.nil))
    = Dlg.ask .text guideQ (fun guide =>
        Dlg.ask1 .text (deep.onQ .text (draftQ spec)) >>= fun draft =>
          loopD guide 2 draft >>= fun final => finishD final)
  exact congrArg _ (funext key)

/-- `run` of the plan is `run` of the dialogue. -/
theorem run_hardenPatch (ω : Ω) (spec : String) :
    Plan.run ω (hardenPatch spec) Env.nil = Dlg.run ω (hardenD spec) := by
  rw [Plan.run, denote_hardenPatch]

/-- …and so is `trace`. Every theorem below is stated about `Plan.trace` and
proved about `Dlg.trace (hardenD spec)` through this one rewrite. -/
theorem trace_hardenPatch (ω : Ω) (spec : String) :
    Plan.trace ω (hardenPatch spec) Env.nil = Dlg.trace ω (hardenD spec) := by
  rw [Plan.trace, denote_hardenPatch]

/-! ## The transcript calculus

Six unrollings of `Dlg.trace`/`Dlg.run` at the four pieces of the meaning.
Everything below is a two-line consequence of these; nothing below ever looks at
the plan again. -/

section Transcript

variable {A B : Type} (ω : Ω)

/-- `trace` does not see a pure post-processing step: `f <$> x` consults exactly
what `x` consults. A `Functor`-level restatement of `trace_bind`. -/
@[simp] theorem trace_map (f : A → B) (x : Dlg A) : Dlg.trace ω (f <$> x) = Dlg.trace ω x := by
  rw [map_eq_pure_bind, Dlg.trace_bind']
  simp

/-- …and `run` applies it: `run ω` is a functor morphism into `Id`. -/
@[simp] theorem run_map (f : A → B) (x : Dlg A) : Dlg.run ω (f <$> x) = f (Dlg.run ω x) := by
  rw [map_eq_pure_bind, Dlg.run_bind']
  rfl

@[simp] theorem trace_panelD (g a : String) :
    Dlg.trace ω (panelD g a)
      = [⟨.verdict, correctQ g a, ω .verdict (correctQ g a)⟩,
         ⟨.verdict, secureQ g a, ω .verdict (secureQ g a)⟩,
         ⟨.verdict, simplerQ a, ω .verdict (simplerQ a)⟩] := by
  simp [panelD, Dlg.trace_bind', Dlg.ask1]

@[simp] theorem run_panelD (g a : String) :
    Dlg.run ω (panelD g a)
      = ω .verdict (correctQ g a) * (ω .verdict (secureQ g a) * ω .verdict (simplerQ a)) := by
  simp [panelD, Dlg.run_bind', Dlg.ask1]

@[simp] theorem trace_redraftD (g a : String) (v : Verdict) :
    Dlg.trace ω (redraftD g a v)
      = [⟨.text, deep.onQ .text (reviseQ g a v), ω .text (deep.onQ .text (reviseQ g a v))⟩] := rfl

@[simp] theorem run_redraftD (g a : String) (v : Verdict) :
    Dlg.run ω (redraftD g a v) = ω .text (deep.onQ .text (reviseQ g a v)) := rfl

theorem trace_loopD_zero (g : String) (a : El .text) :
    Dlg.trace ω (loopD g 0 a) = Dlg.trace ω (panelD g a) := by
  rw [loopD, Dlg.trace_bind']
  simp

theorem run_loopD_zero (g : String) (a : El .text) :
    Dlg.run ω (loopD g 0 a)
      = if Verdict.approvedB (Dlg.run ω (panelD g a)) then some a else none := by
  rw [loopD, Dlg.run_bind']
  rfl

theorem trace_loopD_succ (g : String) (n : Nat) (a : El .text) :
    Dlg.trace ω (loopD g (n + 1) a)
      = Dlg.trace ω (panelD g a) ++
        (if Verdict.approvedB (Dlg.run ω (panelD g a)) then []
         else Dlg.trace ω (redraftD g a (Dlg.run ω (panelD g a)))
                ++ Dlg.trace ω
                    (loopD g n (Dlg.run ω (redraftD g a (Dlg.run ω (panelD g a)))))) := by
  rw [loopD, Dlg.trace_bind', apply_ite (Dlg.trace ω), Dlg.trace_pure, Dlg.trace_bind']
  rfl

theorem run_loopD_succ (g : String) (n : Nat) (a : El .text) :
    Dlg.run ω (loopD g (n + 1) a)
      = if Verdict.approvedB (Dlg.run ω (panelD g a)) then some a
        else Dlg.run ω (loopD g n (Dlg.run ω (redraftD g a (Dlg.run ω (panelD g a))))) := by
  rw [loopD, Dlg.run_bind', apply_ite (Dlg.run ω), Dlg.run_pure, Dlg.run_bind']
  rfl

@[simp] theorem trace_finishD_none : Dlg.trace ω (finishD none) = [] := rfl

theorem trace_finishD_some (p : El .text) :
    Dlg.trace ω (finishD (some p))
      = ⟨.flag, consentQ p, ω .flag (consentQ p)⟩ ::
        (if ω .flag (consentQ p) = true then [⟨.ack, applyQ p, ω .ack (applyQ p)⟩]
         else []) := by
  rw [finishD, Dlg.trace_bind', Dlg.trace_ask1, Dlg.run_ask1, apply_ite (Dlg.trace ω),
    Dlg.trace_bind', Dlg.trace_ask1, Dlg.trace_pure]
  simp

/-- The transcript of the whole workflow: the guide, the draft, the loop, the
tail. Everything the six theorems say is read off this line. -/
theorem trace_hardenD (spec : String) :
    Dlg.trace ω (hardenD spec)
      = ⟨.text, guideQ, ω .text guideQ⟩
        :: ⟨.text, deep.onQ .text (draftQ spec), ω .text (deep.onQ .text (draftQ spec))⟩
        :: (Dlg.trace ω (loopD (ω .text guideQ) 2 (ω .text (deep.onQ .text (draftQ spec))))
            ++ Dlg.trace ω
                (finishD (Dlg.run ω
                  (loopD (ω .text guideQ) 2 (ω .text (deep.onQ .text (draftQ spec))))))) := by
  simp only [hardenD, Dlg.trace_bind', Dlg.trace_ask1, Dlg.run_ask1,
    List.cons_append, List.nil_append]

/-! ### What a review round and a revision can say

Three facts about the loop, each an induction on the fuel and each two lines
once the unrollings above are in place. -/

/-- `[[guideKey]]` = the guide question, as a point of question space. -/
def guideKey : Key := ⟨.text, guideQ⟩

/-- An event that asked for a different *code* did not ask the guide question. -/
theorem key_ne_of_code {e : Event} (h : e.c ≠ Code.text) : e.key ≠ guideKey :=
  fun heq => h (congrArg Sigma.fst heq)

/-- An event addressed to somebody else did not ask the guide question. The
proof goes through `Key.shape`, so no dependent-pair injection is needed. -/
theorem key_ne_of_addressee {e : Event} (h : e.q.addressee ≠ guideQ.addressee) :
    e.key ≠ guideKey :=
  fun heq => h (congrArg (fun k => (Key.shape k).addressee) heq)

/-- `[[isDraft e]]` = the event asked the author for a patch: the draft, or one
of the revisions. -/
def isDraft (e : Event) : Bool := decide (e.q.addressee = (Addressee.model "author"))

theorem loopD_key_ne_guide (g : String) :
    ∀ (n : Nat) (a : El .text), ∀ e ∈ Dlg.trace ω (loopD g n a), e.key ≠ guideKey := by
  intro n
  induction n with
  | zero =>
    intro a e he
    rw [trace_loopD_zero, trace_panelD] at he
    simp only [List.mem_cons, List.not_mem_nil, or_false] at he
    rcases he with rfl | rfl | rfl <;> exact key_ne_of_code (by simp)
  | succ n ih =>
    intro a e he
    rw [trace_loopD_succ] at he
    rcases List.mem_append.mp he with h | h
    · rw [trace_panelD] at h
      simp only [List.mem_cons, List.not_mem_nil, or_false] at h
      rcases h with rfl | rfl | rfl <;> exact key_ne_of_code (by simp)
    · split at h
      · exact absurd h (by simp)
      · rcases List.mem_append.mp h with h' | h'
        · rw [trace_redraftD] at h'
          simp only [List.mem_cons, List.not_mem_nil, or_false] at h'
          subst h'
          exact key_ne_of_addressee (by simp [deep, atModel, reviseQ, guideQ, authorShape])
        · exact ih _ e h'

theorem loopD_code_ne_ack (g : String) :
    ∀ (n : Nat) (a : El .text), ∀ e ∈ Dlg.trace ω (loopD g n a), e.c ≠ Code.ack := by
  intro n
  induction n with
  | zero =>
    intro a e he
    rw [trace_loopD_zero, trace_panelD] at he
    simp only [List.mem_cons, List.not_mem_nil, or_false] at he
    rcases he with rfl | rfl | rfl <;> simp
  | succ n ih =>
    intro a e he
    rw [trace_loopD_succ] at he
    rcases List.mem_append.mp he with h | h
    · rw [trace_panelD] at h
      simp only [List.mem_cons, List.not_mem_nil, or_false] at h
      rcases h with rfl | rfl | rfl <;> simp
    · split at h
      · exact absurd h (by simp)
      · rcases List.mem_append.mp h with h' | h'
        · rw [trace_redraftD] at h'
          simp only [List.mem_cons, List.not_mem_nil, or_false] at h'
          subst h'
          simp
        · exact ih _ e h'

/-- **At most `n` revisions.** The panel asks nobody for a patch, and each turn
of the loop asks for exactly one — so the fuel bounds the drafts, which is what
"revise up to twice" means. -/
theorem loopD_countP_draft (g : String) :
    ∀ (n : Nat) (a : El .text), (Dlg.trace ω (loopD g n a)).countP isDraft ≤ n := by
  intro n
  induction n with
  | zero =>
    intro a
    rw [trace_loopD_zero, trace_panelD]
    simp [isDraft, correctQ, secureQ, simplerQ, correctShape, secureShape, simplerShape]
  | succ n ih =>
    intro a
    rw [trace_loopD_succ, List.countP_append, trace_panelD]
    have hpanel : (List.countP isDraft
        [(⟨.verdict, correctQ g a, ω .verdict (correctQ g a)⟩ : Event),
         ⟨.verdict, secureQ g a, ω .verdict (secureQ g a)⟩,
         ⟨.verdict, simplerQ a, ω .verdict (simplerQ a)⟩]) = 0 := by
      simp [isDraft, correctQ, secureQ, simplerQ, correctShape, secureShape, simplerShape]
    rw [hpanel, Nat.zero_add]
    split
    · simp
    · rw [List.countP_append, trace_redraftD]
      have hrev : (List.countP isDraft
          [(⟨.text, deep.onQ .text (reviseQ g a (Dlg.run ω (panelD g a))),
             ω .text (deep.onQ .text (reviseQ g a (Dlg.run ω (panelD g a))))⟩ : Event)]) = 1 := by
        simp [isDraft, deep, atModel, reviseQ, authorShape]
      rw [hrev, Nat.add_comm]
      exact Nat.succ_le_succ (ih _)

/-- **The shape of a run of the loop.** Every world takes the loop through some
number `k ≤ n` of revisions, spending `4k + 3` consultations — three reviewers
per round and one revision between rounds — and it gives up (`none`) only when
it has used every revision it had. -/
theorem loopD_rounds (g : String) :
    ∀ (n : Nat) (a : El .text), ∃ k, k ≤ n
      ∧ (Dlg.trace ω (loopD g n a)).length = 4 * k + 3
      ∧ (Dlg.run ω (loopD g n a) = none → k = n) := by
  intro n
  induction n with
  | zero =>
    intro a
    refine ⟨0, le_rfl, ?_, fun _ => rfl⟩
    rw [trace_loopD_zero, trace_panelD]
    rfl
  | succ n ih =>
    intro a
    rw [trace_loopD_succ, run_loopD_succ]
    split
    · exact ⟨0, Nat.zero_le _, by rw [trace_panelD]; rfl, by simp⟩
    · obtain ⟨k, hk, hlen, hnone⟩ := ih (Dlg.run ω (redraftD g a (Dlg.run ω (panelD g a))))
      refine ⟨k + 1, Nat.succ_le_succ hk, ?_, fun h => congrArg (· + 1) (hnone h)⟩
      rw [List.length_append, List.length_append, trace_panelD, trace_redraftD, hlen]
      simp only [List.length_cons, List.length_nil]
      omega

theorem length_trace_finishD_some (p : El .text) :
    (Dlg.trace ω (finishD (some p))).length = if ω .flag (consentQ p) = true then 2 else 1 := by
  rw [trace_finishD_some]
  split <;> simp

theorem finishD_key_ne_guide :
    ∀ (o : Option (El .text)), ∀ e ∈ Dlg.trace ω (finishD o), e.key ≠ guideKey := by
  rintro (_ | p) e he
  · exact absurd he (by simp)
  · rw [trace_finishD_some] at he
    simp only [List.mem_cons] at he
    rcases he with rfl | he
    · exact key_ne_of_code (by simp)
    · split at he
      · simp only [List.mem_cons, List.not_mem_nil, or_false] at he
        subst he; exact key_ne_of_code (by simp)
      · exact absurd he (by simp)

theorem finishD_countP_draft (o : Option (El .text)) :
    (Dlg.trace ω (finishD o)).countP isDraft = 0 := by
  rcases o with _ | p
  · rfl
  · rw [trace_finishD_some]
    split <;> simp [isDraft, consentQ, applyQ, consentShape, applyShape]

end Transcript

/-! ## The six theorems

Each is stated about `⟦hardenPatch spec⟧` — `Plan.run` and `Plan.trace` are
*defined* as `Dlg.run` and `Dlg.trace` of the denotation — so none of them is a
statement about the shape of a term. -/

section Theorems

variable (ω : Ω) (spec : String)

/-! ### 1. Consent gates the act -/

/-- **The strong form.** If the workflow put *any* `.ack` question — and the
apply question is the only one — then the owner said yes to some patch. The
gate is not "the term contains a `case`"; it is a fact about every transcript in
every world. -/
theorem consent_of_ack (e : Event) (he : e ∈ Plan.trace ω (hardenPatch spec) Env.nil)
    (hc : e.c = Code.ack) : ∃ p : El .text, ω .flag (consentQ p) = true := by
  rw [trace_hardenPatch, trace_hardenD] at he
  simp only [List.mem_cons] at he
  rcases he with rfl | rfl | he
  · exact absurd hc (by simp)
  · exact absurd hc (by simp)
  rcases List.mem_append.mp he with h | h
  · exact absurd hc (loopD_code_ne_ack ω _ 2 _ e h)
  · revert h
    rcases hfin : Dlg.run ω (loopD (ω .text guideQ) 2
        (ω .text (deep.onQ .text (draftQ spec)))) with _ | p
    · intro h; exact absurd h (by simp)
    · intro h
      rw [trace_finishD_some] at h
      simp only [List.mem_cons] at h
      rcases h with rfl | h
      · exact absurd hc (by simp)
      · refine ⟨p, ?_⟩
        by_contra hne
        rw [if_neg hne] at h
        exact absurd h (by simp)

/-- **Kernel theorem 1, as asked.** In a world where the owner refuses consent,
the apply question is never put: no `.ack` event occurs in the transcript at
all. -/
theorem no_ack_of_refused (h : ∀ p : El .text, ω .flag (consentQ p) = false) :
    ∀ e ∈ Plan.trace ω (hardenPatch spec) Env.nil, e.c ≠ Code.ack := by
  intro e he hc
  obtain ⟨p, hp⟩ := consent_of_ack ω spec e he hc
  rw [h p] at hp
  exact absurd hp (by simp)

/-- …and in particular the apply question itself is not in the transcript. -/
theorem apply_not_mem_of_refused (h : ∀ p : El .text, ω .flag (consentQ p) = false)
    (p : El .text) :
    (⟨.ack, applyQ p, ω .ack (applyQ p)⟩ : Event)
      ∉ Plan.trace ω (hardenPatch spec) Env.nil :=
  fun he => no_ack_of_refused ω spec h _ he rfl

/-! ### 2. The guide is read exactly once -/

/-- `[[isGuide e]]` = the event put the guide question. -/
def isGuide (e : Event) : Bool := decide (e.key = guideKey)

/-- **Kernel theorem 2.** In every world the guide question occurs exactly once
in the transcript — not "once per reviewer", and not "once because the author
hoisted it". Sharing is a variable used twice and it costs one event (§3 q2),
and here that is checked against the workload rather than against a two-line
example. -/
theorem guide_once :
    (Plan.trace ω (hardenPatch spec) Env.nil).countP isGuide = 1 := by
  have hzero : ∀ l : Trace, (∀ e ∈ l, e.key ≠ guideKey) → l.countP isGuide = 0 := by
    intro l hl
    exact List.countP_eq_zero.mpr fun e he => by simpa [isGuide] using hl e he
  rw [trace_hardenPatch, trace_hardenD, List.countP_cons, List.countP_cons, List.countP_append,
    hzero _ (loopD_key_ne_guide ω _ 2 _), hzero _ (finishD_key_ne_guide ω _)]
  have hd : isGuide ⟨.text, deep.onQ .text (draftQ spec),
      ω .text (deep.onQ .text (draftQ spec))⟩ = false := by
    simp only [isGuide, decide_eq_false_iff_not]
    exact key_ne_of_addressee (by simp [deep, atModel, draftQ, guideQ, authorShape])
  have hg : isGuide ⟨.text, guideQ, ω .text guideQ⟩ = true := by
    simp [isGuide, Event.key, guideKey]
  rw [hd, hg]
  rfl

/-! ### 4. At most three drafts -/

/-- **Kernel theorem 4.** In every world the author is asked for a patch at most
three times: one draft and at most two revisions. This is `revising … 2` doing
what its English says — three reviews and *two* revisions, never a revision
that is paid for and discarded unreviewed (`attack-adequacy` A1). -/
theorem draft_count_le_three :
    (Plan.trace ω (hardenPatch spec) Env.nil).countP isDraft ≤ 3 := by
  rw [trace_hardenPatch, trace_hardenD, List.countP_cons, List.countP_cons, List.countP_append,
    finishD_countP_draft ω _]
  have hg : isDraft ⟨.text, guideQ, ω .text guideQ⟩ = false := by
    simp [isDraft, guideQ]
  have hd : isDraft ⟨.text, deep.onQ .text (draftQ spec),
      ω .text (deep.onQ .text (draftQ spec))⟩ = true := by
    simp [isDraft, deep, atModel, draftQ, authorShape]
  have hloop := loopD_countP_draft ω (ω .text guideQ) 2 (ω .text (deep.onQ .text (draftQ spec)))
  simp only [hg, hd, if_true, Bool.false_eq_true, if_false, Nat.add_zero]
  omega

/-! ### 6. Totality -/

/-- **Kernel theorem 6.** `run` terminates with `()` in every world. By
construction: `Dlg` is a *least* fixed point and `hardenPatch` is a finite term,
so `Dlg.run` is a total function and there is no `⊥`, no `Option` and no partial
interpreter anywhere in the meaning (§3 q8). The proof is `rfl` because the
statement has no content beyond that — which is the point. -/
theorem run_terminates : Plan.run ω (hardenPatch spec) Env.nil = () := rfl

/-! ### The length of a transcript, exactly -/

/-- **What every run costs, in consultations.** Seven possibilities and no
others: `4k + 6` or `4k + 7` for `k ≤ 2` revisions when a patch survives review
(the owner is asked, and applies or does not), and `13` when the loop exhausts
its revisions and gives up — in which case the owner is never troubled. -/
theorem length_trace_hardenPatch :
    (Plan.trace ω (hardenPatch spec) Env.nil).length ∈ [6, 7, 10, 11, 13, 14, 15] := by
  rw [trace_hardenPatch, trace_hardenD]
  obtain ⟨k, hk, hlen, hnone⟩ :=
    loopD_rounds ω (ω .text guideQ) 2 (ω .text (deep.onQ .text (draftQ spec)))
  simp only [List.length_cons, List.length_append, hlen]
  rcases hfin : Dlg.run ω (loopD (ω .text guideQ) 2
      (ω .text (deep.onQ .text (draftQ spec)))) with _ | p
  · rw [hnone hfin]
    simp
  · rw [length_trace_finishD_some]
    simp only [List.mem_cons, List.not_mem_nil, or_false]
    split <;> omega

/-- Hence the bill of any run is at least six consultations… -/
theorem six_le_length : 6 ≤ (Plan.trace ω (hardenPatch spec) Env.nil).length := by
  have := length_trace_hardenPatch ω spec
  simp only [List.mem_cons, List.not_mem_nil, or_false] at this
  omega

/-- …and at most fifteen. -/
theorem length_le_fifteen : (Plan.trace ω (hardenPatch spec) Env.nil).length ≤ 15 := by
  have := length_trace_hardenPatch ω spec
  simp only [List.mem_cons, List.not_mem_nil, or_false] at this
  omega

/-! ### 3. The workflow sits at the branch rung

One fact about the *term*, and the only one in this module. It is here because
it is the hypothesis of the C3 cost theorems, and stating it is how the workload
gets billed. There used to be a second — `ShapeStatic (hardenPatch spec)`, "the
answers flow into prompt text and nowhere else", together with six closure
lemmas proving that the property survives `sub`, `graft`, `ask1`, `zipWith`,
`panel`, `caseB` and `revising`. All eight are gone: the `ask` node now carries
its shape as term-level data, so the property they established is the type of
the node and there is nothing left to establish. -/

/-- **Kernel theorem 3.** `level (hardenPatch spec) = branch`, by `rfl`.

Not `dynamic`: the whole workflow — a scoped draft, a three-member panel over a
shared guide, check-then-revise twice, a human consent gate and a gated act —
contains no `dyn`, because every answer flows either into a *prompt* (`ask`) or
into a *finite tag* (`case`). That is exactly the claim `attack-adequacy` A3
shows the four dossier kernels cannot make: in all of them this workload is
monadic and has no static cost at all. -/
theorem level_hardenPatch (spec : String) : level (hardenPatch spec) = Level.branch := rfl

/-- …and hence every C3 theorem of `Agentic/Core/Cost.lean` applies to it. -/
theorem level_le_branch (spec : String) : level (hardenPatch spec) ≤ Level.branch :=
  le_of_eq (level_hardenPatch spec)

/-- The counting price prices by shape, vacuously: it does not look at the
question at all. -/
theorem tick_pricesByShape : PricesByShape tick := fun _ _ _ _ => rfl

/-! ### 5. The bill

`tick` charges one unit per consultation, so a bill is a transcript length and
the two readings agree. The numbers below are computed, not asserted. -/

/-! The membership form of C3 — `bill ∈ (costTree …).leaves` — is *true* of this
workload and is exactly `Cost.bill_mem_leaves` instantiated, but checking that
instantiation costs Lean about a minute: `∈` on a `Multiset` is `Quot.liftOn`,
so `isDefEq` tries to iota-reduce the quotient and therefore to evaluate the
whole fifteen-consultation cost tree. The two order forms below say the usable
half at no cost — `≤` on `WithTop`/`WithBot` forces no reduction — and
`bill_hardenPatch` below is strictly sharper than membership anyway: it names
the seven bills a world can actually produce, where the tree has nine leaves. -/

/-- **C3 applies: the bill lies in the tree's interval.** -/
theorem bill_le_maxFold_hardenPatch (spec : String) (ω : Ω) :
    ((billFresh tick (Plan.trace ω (hardenPatch spec) Env.nil) : Multiplicative Nat) :
        WithBot (Multiplicative Nat))
      ≤ (costTree tick (hardenPatch spec) (level_le_branch spec) Env.nil).maxFold :=
  bill_le_maxFold (S := Multiplicative Nat) (price := tick) tick_pricesByShape
    (hardenPatch spec) (level_le_branch spec) Env.nil ω

theorem minFold_le_bill_hardenPatch (spec : String) (ω : Ω) :
    (costTree tick (hardenPatch spec) (level_le_branch spec) Env.nil).minFold
      ≤ ((billFresh tick (Plan.trace ω (hardenPatch spec) Env.nil) : Multiplicative Nat) :
          WithTop (Multiplicative Nat)) :=
  minFold_le_bill (S := Multiplicative Nat) (price := tick) tick_pricesByShape
    (hardenPatch spec) (level_le_branch spec) Env.nil ω

/-- **The bill of a run, in every world**: `Multiplicative.ofAdd` of one of seven
numbers. -/
theorem bill_hardenPatch (spec : String) (ω : Ω) :
    ∃ n ∈ [6, 7, 10, 11, 13, 14, 15],
      billFresh tick (Plan.trace ω (hardenPatch spec) Env.nil) = Multiplicative.ofAdd n :=
  ⟨_, length_trace_hardenPatch ω spec, billFresh_tick _⟩

/-! #### The numbers, at a concrete specification

`tick` does not read the question, so the cost tree of `hardenPatch spec` is the
same for every `spec`; fixing one lets the kernel compute it. -/

/-- `[[demo]]` = the workflow at a concrete specification. `tick` does not read
the question, so the cost tree is the same for every specification; fixing one
is what lets the kernel compute the numbers below. -/
def demo : Plan [] Unit := hardenPatch "harden the parser"

theorem level_demo : level demo ≤ Level.branch := level_le_branch _

set_option maxRecDepth 10000 in
/-- **The cost tree has nine leaves**: three ways out of the revision loop
(approve at round 1, 2 or 3) times three ways through the tail (no patch; a
patch refused; a patch applied). -/
theorem card_leaves_demo : Multiset.card (costTree tick demo level_demo Env.nil).leaves = 9 := by
  decide

set_option maxRecDepth 10000 in
/-- **The cheapest leaf is 5 consultations** — and no world pays it; see
`minFold_not_attained_demo`. -/
theorem minFold_demo :
    (costTree tick demo level_demo Env.nil).minFold
      = ((Multiplicative.ofAdd 5 : Multiplicative Nat) : WithTop (Multiplicative Nat)) := by
  decide

set_option maxRecDepth 10000 in
/-- **The dearest leaf is 15 consultations**, and that one *is* paid; see
`bill_echo_demo`. -/
theorem maxFold_demo :
    (costTree tick demo level_demo Env.nil).maxFold
      = ((Multiplicative.ofAdd 15 : Multiplicative Nat) : WithBot (Multiplicative Nat)) := by
  decide

/-- `[[ωRefuse]]` = the world in which the panel approves at once and the owner
refuses. -/
def ωRefuse : Ω := fun c => match c with
  | .text => fun _ => ""
  | .verdict => fun _ => Verdict.approve
  | .flag => fun _ => false
  | .ack => fun _ => ()

/-- `[[ωApply]]` = the world in which the panel approves at once and the owner
applies. -/
def ωApply : Ω := fun c => match c with
  | .text => fun _ => ""
  | .verdict => fun _ => Verdict.approve
  | .flag => fun _ => true
  | .ack => fun _ => ()

/-- `[[ωStubborn]]` = the world in which the panel never approves: the loop
exhausts its two revisions, gives up with `none`, and the owner is never
troubled. -/
def ωStubborn : Ω := fun c => match c with
  | .text => fun _ => ""
  | .verdict => fun _ => Verdict.object ["needs work"]
  | .flag => fun _ => true
  | .ack => fun _ => ()

/-- `[[ωEcho]]` = the world that echoes every prompt back and whose reviewers
approve only a patch long enough to have been revised twice: it objects at
rounds 1 and 2 and approves at round 3. At `demo`'s specification the threshold sits above round
2's longest reviewer prompt (355 characters) and below round 3's shortest
(425). Only a world that can tell the rounds apart reaches the dearest leaf, and
the only thing that distinguishes them is the patch under review — which is why
attaining the maximum needs a world that reads prompt text.

The threshold is a function of the *words* of the questions, which is why it
moved when they were rewritten to tell a real model how to answer: 190 was the
number when a reviewer's prompt was the guide, the patch and nothing else. That
is the one thing in this module prompt text can change, and it changes a `def`
in a world, never a theorem — `bill_echo_demo` below is the same statement it
was, and it is still 15. -/
def ωEcho : Ω := fun c => match c with
  | .text => fun q => q.prompt
  | .verdict => fun q => if 400 ≤ q.prompt.length then Verdict.approve else Verdict.object ["no"]
  | .flag => fun _ => true
  | .ack => fun _ => ()

set_option maxRecDepth 20000 in
theorem bill_refuse_demo :
    billFresh tick (Plan.trace ωRefuse demo Env.nil) = Multiplicative.ofAdd 6 := by
  rw [billFresh_tick]
  exact congrArg _ (by decide)

set_option maxRecDepth 20000 in
theorem bill_apply_demo :
    billFresh tick (Plan.trace ωApply demo Env.nil) = Multiplicative.ofAdd 7 := by
  rw [billFresh_tick]
  exact congrArg _ (by decide)

set_option maxRecDepth 20000 in
theorem bill_stubborn_demo :
    billFresh tick (Plan.trace ωStubborn demo Env.nil) = Multiplicative.ofAdd 13 := by
  rw [billFresh_tick]
  exact congrArg _ (by decide)

set_option maxRecDepth 100000 in
set_option maxHeartbeats 1000000 in
/-- **The maximum is attained.** Fifteen consultations: guide, draft, three
panel rounds of three, two revisions, the owner, and the act.

The heartbeat budget above is what a `decide` on this world costs: `ωEcho` is
the one world in the module that *reads* prompt text, so the kernel evaluates
every prompt of the dearest run — three rounds of a patch that quotes the
previous patch, which is 478 characters by round three. -/
theorem bill_echo_demo :
    billFresh tick (Plan.trace ωEcho demo Env.nil) = Multiplicative.ofAdd 15 := by
  rw [billFresh_tick]
  exact congrArg _ (by decide)

/-- **The minimum of the tree is not attained**, and the gap is one
consultation: `minFold` is `5`, every run costs at least `6`, and the cheapest
run costs exactly `6` (`bill_refuse_demo`). Read against `attack-adequacy` A2's
audit of the dossier's worked cost for this workload ("min 7, max 15"): the
maximum lands on 15 and is attained (`bill_echo_demo`), while the minimum is 6
attained and 5 as a leaf — neither of them 7.

The unreachable leaf is "the panel approves at round 1 *and* the loop returns
`none`", which no world realizes: approval at any round makes the answer
`some`. This is `Cost.minFold_not_attained` again, now on the flagship
workload, and it is why `exists_min_bill` — the extreme of the *achievable*
bills — is the theorem a budget argument may use. -/
theorem minFold_not_attained_demo (ω : Ω) :
    billFresh tick (Plan.trace ω demo Env.nil) ≠ Multiplicative.ofAdd 5 := by
  have h6 := six_le_length ω "harden the parser"
  rw [show demo = hardenPatch "harden the parser" from rfl, billFresh_tick]
  intro h
  have h5 : (Plan.trace ω (hardenPatch "harden the parser") Env.nil).length = 5 :=
    Multiplicative.ofAdd.injective h
  omega

/-- `[[demoUpTo]]` = the workflow, presented as an inhabitant of the budget
type. **The budget is a type, and this workflow inhabits it at fifteen.** -/
def demoUpTo : PlanUpTo tick (Multiplicative.ofAdd 15 : Multiplicative Nat) Unit :=
  ⟨demo, level_demo, le_of_eq maxFold_demo⟩

theorem demoUpTo_bill_le (ω : Ω) :
    billFresh tick (Plan.trace ω demo Env.nil) ≤ Multiplicative.ofAdd 15 :=
  PlanUpTo.bill_le tick_pricesByShape demoUpTo ω

end Theorems

end Harden

end Agentic.Core
