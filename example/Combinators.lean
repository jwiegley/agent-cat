import Agentic.Term
import Mathlib.Algebra.Group.Nat.Defs

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
(`>>>`), a stage that carries its input past (`keep`), a panel of reviewers
over one input (`panel`), a reviewer handed a briefing (`briefed`, `guided`),
and the four annotations (`under`, `gate`, `loop`, `share`). The Δ-tuple
plumbing a tensor demands — copy the input, nest the pairs, flatten them again
for the merge — lives *here*, once, instead of being retyped in every workflow.

**Everything here is `abbrev`, and that is load-bearing.** The grade is an
index the constructors compute, and the point of the index is that it reduces
*definitionally* at a written term: a pipeline of static parts must elaborate
at `.static` with no coercion and no `show`. A plain `def` would stand between
the elaborator and `Frag`'s equations, and every workflow would then need a
cast at every stage. So each combinator is reducible, and each is followed by
a grade example that stops compiling if it ever stops being so — the smoke
discipline `Agentic.Term` applies to the constructors, applied to their
surface.

`panel` ends in a merging `Transform`, and `Frag.join f .static = f` is *not*
an `rfl` at a variable `f` — the second argument is the one being matched.
Rather than let that arithmetic leak into its signature, `panel` transports
along `Frag.join_static`. `Term.castGrade` is a `cases` on an equation and
computes away, so the grade still reduces at literals; the examples below check
exactly that.
-/

namespace Agentic

/-! ## The tensor's `n`-fold iterate

`Frag.parN` is grade arithmetic and nothing else, so it **belongs in
`Agentic.Frag`**, beside `join`, `par` and `scale`; it is written here only
because `panel` is what forced it to exist and this file is where `panel`
lives. Nothing about it mentions a term, a semiring or a meaning. -/

/-- **`n` branches of one shape, all in flight.** `parN n f` is the `n`-fold
`Frag.par` of `f` with itself, right-nested, with `Frag.par`'s unit `.static`
at the bottom: the grade of a panel of `n` members each graded `f`.

The empty tensor is `.static` and **not** `.bounded 0` — `par`'s unit is the
grade with no data-dependent width, and a panel of no members runs nothing.
Consequently `parN 0 (.bounded m) = .static` rather than `.bounded 0`, which is
the sharper of the two claims and the true one.

Recursion is on `n` first, so `parN` reduces at a literal count for a
*variable* `f`, which is what lets `panel`'s index collapse during
elaboration. -/
def Frag.parN : Nat → Frag → Frag
  | 0, _ => .static
  | n + 1, f => f.par (Frag.parN n f)

/-- A panel of no members has no width: the empty tensor is `par`'s unit. -/
theorem Frag.parN_zero (f : Frag) : parN 0 f = .static := rfl

/-- One more member is one more branch in flight. -/
theorem Frag.parN_succ (n : Nat) (f : Frag) : parN (n + 1) f = f.par (parN n f) := rfl

/-- **A panel of static members is static, however many there are.** By `rfl`
at each step — `par static g = g` holds at a variable `g` — so this is an
induction that computes rather than one a fold has to carry. -/
theorem Frag.parN_static : ∀ n : Nat, parN n .static = .static
  | 0 => rfl
  | n + 1 => parN_static n

/-- Three static members make a static panel, at a literal count. -/
example : Frag.parN 3 .static = .static := rfl

/-- Two at-most-3-wide members make an at-most-6-wide panel: widths add, and
the arithmetic is already the answer rather than a decision procedure. -/
example : Frag.parN 2 (.bounded 3) = .bounded 6 := rfl

/-- The same fact by `decide`, which is what a fragment check in an
implementation will be. -/
example : Frag.parN 2 (.bounded 3) = .bounded 6 := by decide

-- The surface lives in `Term`'s own namespace: these are how a `Term` is
-- written, so `open Term` is all a workflow file says to get the vocabulary.
-- (It also keeps `retry` from colliding with `Agentic.retry`, the scalar retry
-- solve of `Agentic.Star`.)
namespace Term

variable {Op : Type → Type → Type} {G L : Type} {f g : Frag} {c i j o : Type}

/-! ## Leaves -/

/-- **A consultation.** `ask op` is one call to whatever `op` names: a model
turn, a tool invocation, an `Ask` of a human.
*Denotes* the leaf's own matrix under `muS`, and the world's answer at this
occurrence's key under `muExt`; each written occurrence is a distinct site.
*A realization* issues one request to a backend and decodes the reply — a reply
that will not parse is a refusal, `none` in `muExt` and `0` in `muS`.
*Grade* `.static`: one written call is one call, whatever the values say. -/
abbrev ask (op : Op i o) : Term Op G L .static i o := .prim op

/-- **A `Transform`.** `fn h` is a plain function lifted into the language: it
consults nothing, so it is central and free.
*Denotes* `Mat.pointMat h` under `muS` and `some ∘ h` under `muExt`.
*A realization* runs local code — a parser, a decoder, a projection — and talks
to no backend, which is why nothing can observe its order against anything.
*Grade* `.static`, and it costs its neighbours nothing. -/
abbrev fn (h : i → o) : Term Op G L .static i o := .pureT h

/-! ## Composition

**`>>>` is composition, and it is spelled with Lean's own token.** The class
behind that token is `HShiftRight`, which is *heterogeneous*: three type
arguments, the third an `outParam`. That is exactly the shape grade-indexed
composition needs — the operands are `Term … f i j` and `Term … g j o`, two
*different* types, and the result is a third, `Term … (f.join g) i o`, computed
from them. A homogeneous class (Mathlib's `CategoryStruct`, say, or a `Mul`)
cannot state that, because a category's `Hom` composition keeps one object type
family and the grade index moves. And `>>>` is the spelling every Haskeller
already reads as `Control.Category` composition, so a pipeline reads as a
pipeline with no local notation to learn.

**One wrinkle, and it is the elaborator's, not the class's.** Lean will not run
instance synthesis while the first or second type argument still contains
metavariables, and in `ask q >>> fn h` the leaf parameters `Op`, `G`, `L` of
each operand *are* metavariables until the whole chain is unified against the
expected type. Synthesis therefore gets stuck on a term that is perfectly well
typed. The repair keeps the class and adds one scoped `macro_rules` expansion:
inside this namespace `x >>> y` elaborates as `Term.seqT x y` directly — by
unification, which is happy to postpone, rather than by synthesis, which is
not — and Lean backtracks to the ordinary `HShiftRight` path for every other
type, so `(8 >>> 2 : Nat)` is untouched. The two spellings agree
definitionally, the instance being `⟨Term.seqT⟩`; the example below checks
that. -/

/-- **A pipeline.** `w >>> v` runs `w` and feeds its answer to `v`.
*Denotes* `Mat.comp` under `muS` — Chapman–Kolmogorov, summing over the
intermediate answer — and `Option`-bind under `muExt`.
*A realization* awaits the first stage's decoded answer and hands it to the
second; a refusal upstream short-circuits, because `0` annihilates.
*Grade* `f.join g`: a composite is as opaque as its most opaque part, only one
stage being in flight at a time.

Lean's own `infixl:75`, which is looser than every application inside it and
tighter than `=`, so a chain of stages reads without parentheses and a grade
example reads without them either. -/
instance instHShiftRightTerm : HShiftRight (Term Op G L f i j) (Term Op G L g j o)
    (Term Op G L (f.join g) i o) := ⟨Term.seqT⟩

/-- The scoped expansion that keeps `>>>` elaborating when the leaf parameters
are still metavariables. See the section header: this is a workaround for
synthesis' impatience, not a second meaning for the token. -/
scoped macro_rules | `($x >>> $y) => `(Term.seqT $x $y)

/-! ## The four annotations

Thin surface names, and thin on purpose. They exist for one reason each, not
for symmetry with the constructors: in a pipeline written with `>>>` the grade
of each stage is a metavariable until the whole chain is elaborated, so a stage
written as `.retryT 2 w` has no expected type to resolve its dot-notation
against, and `Term.retryT 2 w` puts a namespace in the middle of the workflow.
These four are what let the annotations appear in a chain as plain words. No
other constructor gets one: `Term.fanT 8 body` is written where a type
ascription is already present, and `.prim`/`.pureT`/`.seqT`/`.parT` are covered
by `ask`, `fn`, `>>>` and `panel` below. -/

/-- **A scope annotation**: run this stage under this model, temperature,
agent, backend.
*Denotes* precomposition on the reader — `muS (under h w) g = muS w (g ⋄ h)` —
so innermost-wins is `LastOpt`'s non-commutativity and not an interpreter rule.
*A realization* pushes a frame onto the request context for the extent of the
stage and pops it after; nothing is re-planned, only re-addressed.
*Grade* `f`, unchanged: annotating changes no shape.

(Named `under` rather than `scoped`, which is a Lean keyword; `under deepModel
(ask .draft)` reads as the annotation it is.) -/
abbrev under (g : G) (w : Term Op G L f i o) : Term Op G L f i o := .scopeT g w

/-- **A permission guard**: a grant, a policy veto, a refusal.
*Denotes* the scalar action of an indicator, so refusal is the semiring's `0`
and annihilates everything composed with it — not a branch and not an
exception.
*A realization* consults the policy (or the human) and, on refusal, produces no
run at all; it must not "improve" on this by raising, since a raise is not `0`.
*Grade* `f`, unchanged. -/
abbrev gate (b : Bool) (w : Term Op G L f i o) : Term Op G L f i o := .gateT b w

/-- **A fueled loop**: `loop n w` runs `w`; on `Sum.inr` — "not yet, try again
with this" — goes round, up to `n` times; on `Sum.inl`, answers.
*Denotes* the truncated star `(M_A · d)^{≤n} · M_B`, fuel being the truncation.
*A realization* re-runs the body against a fresh set of consultation keys — the
trip index is part of every key below the loop, so a second attempt is a second
draw and not a replay.
*Grade* `f`, unchanged: a bound on the trip count is a shape known in advance.

Named `loop` and not `retry` because `Agentic.retry` is already the *scalar*
retry solve this loop denotes (`Agentic.Star`), and a name from an enclosing
namespace beats an opened one, so a workflow file could not have written
`retry 2 w` and been understood. The fuel stands beside the word, which is
what keeps `loop` from over-promising. -/
abbrev loop (n : Nat) (w : Term Op G L f i (Sum o i)) : Term Op G L f i o :=
  .retryT n w

/-- **A sharing label**: *this* is the same consultation as every other
occurrence written with the same label.
*Denotes* a rebase of the consultation keys inside the body onto the label, so
two occurrences of one label read one cell; `Env.share_ne_dup` proves that this
is a difference in *meaning* from asking twice, not a cache hit.
*A realization* looks the answer up by `(label, site-within-body)` instead of by
position — and must key by content only where the leaf is deterministic.
*Grade* `f`, unchanged: a label changes where answers come from, never shape.

Duplication is the default, so this is the one thing a designer writes to mean
"ask once, read twice". -/
abbrev share (l : L) (w : Term Op G L f i o) : Term Op G L f i o := .shareT l w

/-! ## Plumbing -/

/-- **Carry the input past a stage.** `keep w` runs `w` and answers the pair
*(what went in, what `w` said)* — the idiom for a reviewer whose verdict has
to be read beside the artefact it reviewed.
*Denotes* `⟨idMat, muS w⟩` Kronecker'd after the copying `pointMat`, which is
the diagonal followed by the tensor and nothing cleverer.
*A realization* holds the input in the frame while the stage runs; no request
is issued for the identity branch, because a wire is not a consultation.
*Grade* `f`, unchanged, and unchanged at a **variable** grade: the identity
branch of the tensor is a wire and costs nothing, `Frag.par .static f = f`
holding by `rfl`.

The input is on the **left** of the pair: `keep review : i → i × o`, so a
decoder written against `(artefact, verdict)` is the one that fits. -/
abbrev keep (w : Term Op G L f i o) : Term Op G L f i (i × o) :=
  fn (fun a => (a, a)) >>> Term.parT (fn id) w

/-! ## Panels

**A panel is `n`-ary, and its reducer is a monoid.** Design §5.1 says the
fan-in of a panel is convolution over a monoid of keys; `panel` is that
sentence made literal at the surface — the members' answers are combined by
`List.foldr` with the monoid's `*` and `1`, so the empty panel denotes the
constant unit, one member denotes itself (times the unit), and the order of the
fold is the order the members were written.

There is no `panel₂`/`panel₃`. A fixed arity would have to fix the merge's
arity with it (`o → o → o`, `o → o → o → o`, …), and each such merge is an
*ad hoc* re-statement of associativity that the monoid already states once. It
would also make the grade a written formula — `f.par (f.par f)` — instead of
`Frag.parN rs.length f`, a function of the list the designer actually wrote. -/

/-- **A panel with the reducer supplied by hand.** `panelWith merge unit rs`
fans the input to every member of `rs`, runs them side by side, and folds the
answers right-to-left with `merge`, `unit` closing the fold.
*Denotes* an iterated `Mat.kron` of the members, pre-composed with the copying
`pointMat` and post-composed with the merging one.
*A realization* dispatches the members concurrently and joins them; the joining
code is local and free, and the fold's order is the written order.
*Grade* `Frag.parN rs.length f` — every member is in flight, so their widths
add, `rs.length` of them.

This is the recursion; `panel` is this at the monoid, and costs nothing extra
because there was nothing extra to cost. Handing in `merge` and `unit`
separately is for the carriers that have no canonical `Monoid` instance — a
`List` append, a `min` on scores — where writing `instance : Monoid …` would be
a lie about which of the several monoids on that carrier was meant. Nothing
here checks that `merge`/`unit` are lawful; `panel` is the spelling that
carries the laws. -/
abbrev panelWith (merge : o → o → o) (unit : o) :
    (rs : List (Term Op G L f i o)) → Term Op G L (Frag.parN rs.length f) i o
  | [] => fn (fun _ => unit)
  | r :: rs =>
    Term.castGrade (Frag.join_static _)
      (fn (fun a => (a, a)) >>> Term.parT r (panelWith merge unit rs)
        >>> fn (fun p => merge p.1 p.2))

/-- **A panel of reviewers over one input, reduced by the monoid on their
verdicts.** `panel rs` copies the input to every member of `rs`, runs them all,
and combines the answers with `*`, the empty panel denoting the constant `1`.
*Denotes* the design's §5.1 reducer, made literal: the members' meanings
Kronecker'd together and folded by the monoid, which is why reordering them is
licensed by `CommMonoid` and racing duplicates by idempotence — separate
licences, charged separately.
*A realization* fans out `rs.length` concurrent consultations and reduces their
verdicts as they land; the monoid laws are exactly what make "as they land"
safe to say.
*Grade* `Frag.parN rs.length f`, which reduces at a literal list: three static
members give `.static`, three at-most-3-wide members give `.bounded 9`. -/
abbrev panel (rs : List (Term Op G L f i o)) [Monoid o] :
    Term Op G L (Frag.parN rs.length f) i o :=
  panelWith (· * ·) 1 rs

/-! ## Consulting with a briefing -/

/-- **A consultation handed a briefing.** `briefed aside r` runs the auxiliary
workflow `aside` on `()`, pairs its answer with the input, and consults `r` on
the pair — the block behind every "review this against *that*".
*Denotes* the tensor of `aside`'s meaning with the identity on the input wire,
composed into the leaf; the briefing runs beside the input, so nothing about
the input reaches it.
*A realization* fetches the briefing (a document, a schema, a prior turn) and
puts it in the same request as the artefact.
*Grade* `.static`, briefing and all, whenever the briefing is.

Whether the briefing is one consultation or one per reviewer is decided by
what is passed in, and by nothing else: `briefed (ask q) r` draws its own, and
`briefed (share l (ask q)) r` — which is `guided` — reads the shared one. That
one word is the entire difference, and `Env.share_ne_dup` proves it is a
difference in meaning. -/
abbrev briefed (aside : Term Op G L .static Unit c) (r : Op (c × i) o) :
    Term Op G L .static i o :=
  fn (fun a => ((), a)) >>> Term.parT aside (fn id) >>> ask r

/-- **A reviewer reading the shared briefing.** `guided l q r` is `briefed` at
the sharing idiom: every occurrence written with the label `l` consults the
*same* site.
*Denotes* one cell of the world read by every member of the panel, rather than
one cell each — a panel of `guided sg _ _` reviewers draws one briefing between
them.
*A realization* fetches the guide once per label and reuses it; the quantitative
layer, being transparent to `shareT`, still bills it per reader, which is an
over-count and not a wrong meaning.
*Grade* `.static`, exactly as `briefed`. -/
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

variable (q : Op String Nat) (r : Op String String)

/-- A consultation is static, and so is a `Transform`. -/
example : Term Op G L .static String Nat := ask q >>> fn (· + 1)

/-- A pipeline of static stages is static, with no coercion anywhere in the
chain — the property the whole surface exists to preserve. -/
example : Term Op G L .static String Nat := fn (· ++ "!") >>> ask r >>> ask q

/-- A pipeline is as opaque as its most opaque stage. -/
example : Term Op G L (.bounded 8) String (List Nat) :=
  ask r >>> fn (fun s => [s]) >>> Term.fanT 8 (ask q)

/-- **`>>>` is `HShiftRight`, and `HShiftRight` at `Term` is `seqT`.** The
instance is real and elaborates: this is the class's own projection applied to
two terms, and it is the constructor, definitionally. -/
example (w : Term Op G L f String Nat) (v : Term Op G L g Nat String) :
    HShiftRight.hShiftRight w v = Term.seqT w v := rfl

/-- The grade of a pipeline is the join, at a *variable* grade on both sides. -/
example (w : Term Op G L f String Nat) (v : Term Op G L g Nat String) :
    Term.grade (w >>> v) = f.join g := rfl

/-- `keep` is grade-transparent at a **variable** grade: carrying a value past
a stage is a wire, and a wire has no width. -/
example (w : Term Op G L f String Nat) : Term.grade (keep w) = f := rfl

/-- Three static reviewers make a static panel: three known branches contribute
no data-dependent width. The merge here is `Nat`'s multiplicative monoid, which
is a monoid and nothing more — `panel` asks for nothing more. -/
example : Term Op G L .static String Nat := panel [ask q, ask q, ask q]

/-- An **empty** panel is the constant unit, and it is static: a panel of no
members runs nothing and asks nobody. -/
example : Term Op G L .static String Nat := panel ([] : List (Term Op G L .static String Nat))

/-- Three *bounded* reviewers add: a panel of three at-most-3-wide fans is
at-most-9-wide, and the merge adds nothing. This is the example that fails if
`panel`'s transport, or `Frag.parN`'s recursion, stops computing. -/
example (b : Op String (List Nat)) :
    Term Op G L (.bounded 9) (List String) (List Nat) :=
  panelWith (· ++ ·) [] [Term.fanT 3 (ask b) >>> fn List.flatten,
    Term.fanT 3 (ask b) >>> fn List.flatten,
    Term.fanT 3 (ask b) >>> fn List.flatten]

/-- And two of them add to six. -/
example (b : Op String (List Nat)) :
    Term Op G L (.bounded 6) (List String) (List Nat) :=
  panelWith (· ++ ·) [] [Term.fanT 3 (ask b) >>> fn List.flatten,
    Term.fanT 3 (ask b) >>> fn List.flatten]

/-- The grade is a function of the *list*, not of a written arity: at a literal
list it is the literal count, by `rfl`. -/
example : Term.grade (panel [ask q, ask q, ask q] : Term Op G L _ String Nat)
    = Frag.parN 3 .static := rfl

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
  loop 2 (under g (ask draft) >>> keep (panel [guided l brief rev,
    guided l brief rev, briefed (ask brief) rev]) >>> fn decode)
  >>> gate b (ask apply)

end Smoke

end Term

end Agentic
