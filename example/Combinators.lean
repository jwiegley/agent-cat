import Agentic.Term

/-!
# The combinator surface: the vocabulary a workflow is written in

**This module is library, not example.** It is the reusable stratum, and it
belongs in `Agentic/` proper — as `Agentic/Combinators.lean`, imported by the
root module beside `Agentic.Term` — once this arc lands. It sits under
`Agentic/Examples/` only because the worked example next door is what forced
it to exist.

`Agentic.Term`'s constructors are the *abstract syntax*: minimal, exact, and
shaped for a fold to recurse over. Nobody should write a workflow in them, any
more than one writes a program in a parse tree. What a designer writes is the
vocabulary below — a consultation (`ask`), a `Transform` (`fn`), a pipeline
(`⟫`), a stage that carries its input past (`keep`), a panel of reviewers over
one input (`panel₂`, `panel₃`), a reviewer handed a briefing (`briefed`,
`guided`), and the four annotations (`under`, `gate`, `loop`, `share`). The
Δ-tuple plumbing a tensor demands — copy the input, nest the pairs, flatten
them again for the merge — lives *here*, once, instead of being retyped in
every workflow.

**Everything here is `abbrev`, and that is load-bearing.** The grade is an
index the constructors compute, and the point of the index is that it reduces
*definitionally* at a written term: a pipeline of static parts must elaborate
at `.static` with no coercion and no `show`. A plain `def` would stand between
the elaborator and `Frag`'s equations, and every workflow would then need a
cast at every stage. So each combinator is reducible, and each is followed by
a grade example that stops compiling if it ever stops being so — the smoke
discipline `Agentic.Term` applies to the constructors, applied to their
surface.

Two combinators (`panel₂`, `panel₃`) end in a merging `Transform`, and
`Frag.join f .static = f` is *not* an `rfl` at a variable `f` — the second
argument is the one being matched. Rather than let that arithmetic leak into
their signatures, both transport along `Frag.join_static`. `Term.castGrade` is
a `cases` on an equation and computes away, so the grade still reduces at
literals; the examples below check exactly that.
-/

namespace Agentic

-- The surface lives in `Term`'s own namespace: these are how a `Term` is
-- written, so `open Term` is all a workflow file says to get the vocabulary.
-- (It also keeps `retry` from colliding with `Agentic.retry`, the scalar retry
-- solve of `Agentic.Star`.)
namespace Term

variable {Op : Type → Type → Type} {G L : Type} {f : Frag} {c i j o : Type}

/-! ## Leaves -/

/-- **A consultation.** `ask op` is one call to whatever `op` names: a model
turn, a tool invocation, an `Ask` of a human. Denotationally the leaf's own
matrix under `muS`, and the world's answer at this occurrence's key under
`muExt`. Each written occurrence is a distinct consultation site. -/
abbrev ask (op : Op i o) : Term Op G L .static i o := .prim op

/-- **A `Transform`.** `fn g` is a plain function lifted into the language: it
consults nothing, so it is central and free. Denotationally `Mat.pointMat g`
under `muS`, and `some ∘ g` under `muExt`. -/
abbrev fn (g : i → o) : Term Op G L .static i o := .pureT g

/-- **A pipeline.** `w ⟫ v` runs `w` and feeds its answer to `v`.
Denotationally `Mat.comp` under `muS` and `Option`-bind under `muExt`; the
grade is the join, a composite being as opaque as its most opaque part.

Left-associative at 55, which is looser than every application inside it and
tighter than `=`, so a chain of stages reads without parentheses and a grade
example reads without them either. -/
infixl:55 " ⟫ " => Term.seqT

/-! ## The four annotations

Thin surface names, and thin on purpose. They exist for one reason each, not
for symmetry with the constructors: in a pipeline written with `⟫` the grade of
each stage is a metavariable until the whole chain is elaborated, so a stage
written as `.retryT 2 w` has no expected type to resolve its dot-notation
against, and `Term.retryT 2 w` puts a namespace in the middle of the workflow.
These four are what let the annotations appear in a chain as plain words. No
other constructor gets one: `Term.fanT 8 body` is written where a type
ascription is already present, and `.prim`/`.pureT`/`.seqT`/`.parT` are covered
by `ask`, `fn`, `⟫` and the panels below. -/

/-- **A scope annotation**: run this stage under this model, temperature,
agent, backend. Denotationally precomposition on the reader — `muS (under h w)
g = muS w (g ⋄ h)` — so innermost-wins is `LastOpt`'s non-commutativity and not
an interpreter rule. (Named `under` rather than `scoped`, which is a Lean
keyword; `under deepModel (ask .draft)` reads as the annotation it is.) -/
abbrev under (g : G) (w : Term Op G L f i o) : Term Op G L f i o := .scopeT g w

/-- **A permission guard**: a grant, a policy veto, a refusal. Denotationally
the scalar action of an indicator, so refusal is the semiring's `0` and
annihilates everything composed with it. -/
abbrev gate (b : Bool) (w : Term Op G L f i o) : Term Op G L f i o := .gateT b w

/-- **A fueled loop**: `loop n w` runs `w`; on `Sum.inr` — "not yet, try again
with this" — goes round, up to `n` times; on `Sum.inl`, answers.
Denotationally the truncated star `(M_A · d)^{≤n} · M_B`, fuel being the
truncation.

Named `loop` and not `retry` because `Agentic.retry` is already the *scalar*
retry solve this loop denotes (`Agentic.Star`), and a name from an enclosing
namespace beats an opened one, so a workflow file could not have written
`retry 2 w` and been understood. The fuel stands beside the word, which is
what keeps `loop` from over-promising. -/
abbrev loop (n : Nat) (w : Term Op G L f i (Sum o i)) : Term Op G L f i o :=
  .retryT n w

/-- **A sharing label**: *this* is the same consultation as every other
occurrence written with the same label. Duplication is the default, so this is
the one thing a designer writes to mean "ask once, read twice". -/
abbrev share (l : L) (w : Term Op G L f i o) : Term Op G L f i o := .shareT l w

/-! ## Plumbing -/

/-- **Carry the input past a stage.** `keep w` runs `w` and answers the pair
*(what went in, what `w` said)* — the idiom for a reviewer whose verdict has
to be read beside the artefact it reviewed.

The input is on the **left** of the pair: `keep review : i → i × o`, so a
decoder written against `(artefact, verdict)` is the one that fits. The
identity branch of the tensor is a wire and costs the grade nothing, since
`Frag.par .static f = f` by `rfl` — which is why `keep` is grade-transparent
at a *variable* grade and not merely at literals. -/
abbrev keep (w : Term Op G L f i o) : Term Op G L f i (i × o) :=
  fn (fun a => (a, a)) ⟫ Term.parT (fn id) w

/-! ## Panels -/

/-- **Two views of one input, reduced.** `panel₂ r s merge` copies the input to
both branches, runs them side by side, and merges the two answers with a plain
binary function. Denotationally `Mat.kron` between two `pointMat`s; the grade
is `Frag.par`, because both branches are in flight and their widths add. -/
abbrev panel₂ (r s : Term Op G L f i o) (merge : o → o → o) :
    Term Op G L (f.par f) i o :=
  Term.castGrade (Frag.join_static _)
    (fn (fun a => (a, a)) ⟫ Term.parT r s ⟫ fn (fun p => merge p.1 p.2))

/-- **Three views of one input, reduced.** As `panel₂`, with a 3-ary merge:
the caller writes `merge : o → o → o → o` and never sees the tensor's nesting,
which is `o × (o × o)` and is nobody's business but this combinator's. The
grade is `f.par (f.par f)` — three branches in flight, three widths added. -/
abbrev panel₃ (r s t : Term Op G L f i o) (merge : o → o → o → o) :
    Term Op G L (f.par (f.par f)) i o :=
  Term.castGrade (Frag.join_static _)
    (fn (fun a => (a, (a, a))) ⟫ Term.parT r (Term.parT s t)
      ⟫ fn (fun p => merge p.1 p.2.1 p.2.2))

/-! ## Consulting with a briefing -/

/-- **A consultation handed a briefing.** `briefed aside r` runs the auxiliary
workflow `aside` on `()`, pairs its answer with the input, and consults `r` on
the pair — the block behind every "review this against *that*". The briefing
runs beside the input wire, so nothing about the input reaches it.

Whether the briefing is one consultation or one per reviewer is decided by
what is passed in, and by nothing else: `briefed (ask q) r` draws its own, and
`briefed (share l (ask q)) r` — which is `guided` — reads the shared one. That
one word is the entire difference, and `Env.share_ne_dup` proves it is a
difference in meaning. -/
abbrev briefed (aside : Term Op G L .static Unit c) (r : Op (c × i) o) :
    Term Op G L .static i o :=
  fn (fun a => ((), a)) ⟫ Term.parT aside (fn id) ⟫ ask r

/-- **A reviewer reading the shared briefing.** `guided l q r` is `briefed` at
the sharing idiom: every occurrence written with the label `l` consults the
*same* site, so a panel of `guided sg _ _` reviewers draws one briefing between
them rather than one each. -/
abbrev guided (l : L) (shared : Op Unit c) (r : Op (c × i) o) :
    Term Op G L .static i o :=
  briefed (share l (ask shared)) r

section Smoke

/-! ## Grade examples

One per combinator, and they are the specification of the paragraph above: each
elaborates at a *literal* grade with no coercion, which is the claim that the
combinator did not put a `def` between the workflow and `Frag`'s arithmetic.
Where a combinator is transparent at a *variable* grade, the example says so,
since that is the stronger property. -/

variable (q : Op String Nat) (r : Op String String) (m₂ : Nat → Nat → Nat)
  (m₃ : Nat → Nat → Nat → Nat)

/-- A consultation is static, and so is a `Transform`. -/
example : Term Op G L .static String Nat := ask q ⟫ fn (· + 1)

/-- A pipeline of static stages is static, with no coercion anywhere in the
chain — the property the whole surface exists to preserve. -/
example : Term Op G L .static String Nat := fn (· ++ "!") ⟫ ask r ⟫ ask q

/-- A pipeline is as opaque as its most opaque stage. -/
example : Term Op G L (.bounded 8) String (List Nat) :=
  ask r ⟫ fn (fun s => [s]) ⟫ Term.fanT 8 (ask q)

/-- `keep` is grade-transparent at a **variable** grade: carrying a value past
a stage is a wire, and a wire has no width. -/
example (w : Term Op G L f String Nat) : Term.grade (keep w) = f := rfl

/-- Three static reviewers make a static panel: three known branches contribute
no data-dependent width. -/
example : Term Op G L .static String Nat := panel₃ (ask q) (ask q) (ask q) m₃

/-- Three *bounded* reviewers add: a panel of three at-most-3-wide fans is
at-most-9-wide, and the merge adds nothing. This is the example that fails if
`panel₃`'s transport stops computing. -/
example (b : Op String (List Nat)) (m : List Nat → List Nat → List Nat → List Nat) :
    Term Op G L (.bounded 9) (List String) (List Nat) :=
  panel₃ (Term.fanT 3 (ask b) ⟫ fn List.flatten) (Term.fanT 3 (ask b) ⟫ fn List.flatten)
    (Term.fanT 3 (ask b) ⟫ fn List.flatten) m

/-- And two of them add to two. -/
example (b : Op String (List Nat)) (m : List Nat → List Nat → List Nat) :
    Term Op G L (.bounded 6) (List String) (List Nat) :=
  panel₂ (Term.fanT 3 (ask b) ⟫ fn List.flatten)
    (Term.fanT 3 (ask b) ⟫ fn List.flatten) m

/-- A briefed consultation is static, briefing and all. -/
example (brief : Op Unit String) (rev : Op (String × String) Nat) :
    Term Op G L .static String Nat := briefed (ask brief) rev

/-- And so is a guided one: a label changes where an answer comes from, never
what shape a term has. -/
example (l : L) (brief : Op Unit String) (rev : Op (String × String) Nat) :
    Term Op G L .static String Nat := guided l brief rev

/-- The four annotations are grade-transparent at a **variable** grade — by
`rfl`, so no fold has to case-split to know that annotating does not
relabel. -/
example (w : Term Op G L f String Nat) (g : G) (l : L) (b : Bool) :
    Term.grade (under g (gate b (share l w))) = f := rfl

/-- Including the loop: a bound on the trip count is still a shape known before
any value flows. -/
example (w : Term Op G L f String (Sum Nat String)) :
    Term.grade (loop 3 w) = f := rfl

/-- The whole vocabulary at once, at a literal grade: draft, keep it beside a
three-way panel of guided reviewers, decode, loop, gate. If any combinator
above stopped reducing, this line would need a cast. -/
example (l : L) (g : G) (brief : Op Unit String) (rev : Op (String × String) Nat)
    (draft : Op String String) (apply : Op String Unit)
    (decode : String × Nat → Sum String String) (b : Bool) :
    Term Op G L .static String Unit :=
  loop 2 (under g (ask draft) ⟫ keep (panel₃ (guided l brief rev)
    (guided l brief rev) (briefed (ask brief) rev) m₃) ⟫ fn decode)
  ⟫ gate b (ask apply)

end Smoke

end Term

end Agentic
