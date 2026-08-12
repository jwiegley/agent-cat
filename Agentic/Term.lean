import Agentic.Frag

/-!
# The syntax stratum: workflow terms graded by fragment

Design §4. A `Term` is a *written* workflow: the tree a designer composes,
carrying its fragment grade in its type. The grade is not a lint, an
annotation, or a runtime check — it is an index the constructors compute, so
that "this pipeline admits an exact cost fold" is a statement the type system
already made.

Three parameters keep this stratum honest:

* `Op : Type → Type → Type` is the **leaf signature** — the shape of a
  consultation, `Op i o` being the leaves that take an `i` and answer with an
  `o`. It is uninterpreted here. The semantics chooses a semiring and reads
  each leaf as a matrix; the syntax must not know which semiring, or it would
  be a semantics wearing a syntax's clothes.

* `G : Type` is the type of **scope annotations**, with no structure demanded.
  `Agentic.Scope` supplies the per-axis `Last` monoid and proves
  innermost-wins; the syntax only has to carry the annotation to the place
  where that theorem applies (design §5.3).

* `L : Type` is the type of **sharing labels**, with no structure demanded —
  exactly as for `G`. A label names a consultation site so that two written
  occurrences can be said to be *the same* site; what a label is, and how two
  of them are compared, is the meaning fold's business and not the syntax's.
  The fold (`Agentic.Meaning`) compares them by never comparing them: a
  labelled occurrence *rebases* the consultation key to the label, so equal
  labels build equal keys and no `DecidableEq L` is ever demanded.

The grading rules, in one line each: leaves and `Transform`s are `static`;
sequencing, alternation and branching join their parts' grades; tensoring
*adds* them (`Frag.par` — both branches are in flight, so their widths add);
gating, scoping, sharing and fueled retry leave the grade alone; `fanT n`
*scales* by `n` (`Frag.scale` — `n` copies of an `m`-wide body is `n * m`
wide, the body counting at least as one copy of itself); `bindT` is `monadic`
outright.

## Consultation identity: duplication is the default, sharing is labeled

A written term says *where* the answer sheet is consulted, and `Agentic.Env`
proves that where is part of the meaning: `share_ne_dup` exhibits two
workflows that agree on every trace whose answers happen to coincide
(`share_eq_dup_of_agree`) and differ as meanings, because a second draw is a
second draw. So the syntax cannot leave "is this one consultation or two?" to
the fold; it has to say.

It says it in two rules:

* **Every syntactic occurrence of `prim` is a distinct consultation site.**
  Identity of sites is *positional* — the path through the term — so
  `parT (prim q) (prim q)` unambiguously spends two consultations, exactly as
  a run graph's node ids are positional. Nothing about the leaf's `Op` datum
  makes two occurrences one site; `pureT` may copy a *value* freely, and
  copying a value is not re-asking a question.

* **Sharing is explicit and labeled**, by `shareT`. Within the dynamic extent
  of `shareT l t`, sites are keyed by `(l, site-within-t)` instead of by the
  absolute path, so two occurrences written with the same label consult the
  *same* sites: sharing is by label agreement, and is visible in the written
  term. The fold rebases on the label **alone** — it does not compare bodies,
  so two occurrences of one label over *different* bodies also collide
  wherever their inner sites coincide. Writing one label over one body is the
  designer's obligation, not a checked property (acat-bmc).

Duplication is the default because the two readings differ extensionally and
only one of them is safe to assume. Spending a consultation the designer meant
to reuse is a resource error — the meaning is still an honest one, and the
quantitative layer reports the cost. Silently reusing a consultation the
designer meant to spend twice *correlates two samples that were meant to be
independent*: a self-consistency ensemble collapses to a single draw, and the
two meanings then differ in their variance even where their supports agree
(`Env.share_ne_dup`'s closing paragraph). A default may only be the reading
that cannot silently equate distinct samples.

**No weakening constructor.** There is deliberately no
`sub : f ≤ g → Term f i o → Term g i o`. Grades here are *exact by
construction*, and the joins already absorb, so nothing in this module needs
to relabel a term upward. If a later stratum wants `Term f i o → Term g i o`
for `f ≤ g` — say, to place a static workflow into a monadic pipeline's
uniform type — that is a **fold** over the term, defined where the
recursion's target lives, not a constructor. Adding it here would put a second
term with the same meaning into the syntax and make every fold prove it
respects the relabelling, for no gain.
-/

namespace Agentic

/-- A `Term Op G L f i o` is a representation of a *written* workflow taking an
`i` to an `o`, built from the consultation leaves `Op`, annotated with scopes
drawn from `G` and sharing labels drawn from `L`, and graded by the fragment
`f : Frag` that says how much of its shape is knowable before values flow
(design §4).

The family is indexed by the grade, so the grade is computed by the
constructors rather than checked afterwards; a term that elaborates at
`.static` is one whose folds — cost, width, plan — are exact, and no further
proof obligation is incurred to say so. -/
inductive Term (Op : Type → Type → Type) (G L : Type) : Frag → Type → Type → Type 1 where
  /-- A consultation leaf: one call to whatever `Op` describes — a model turn,
  a tool invocation, an `Ask` of the human. Its shape is fixed before any
  value flows, so it is `static`; what it *costs* is the semantics' business,
  not the grade's.

  **Each occurrence is a distinct consultation site**, keyed by its position in
  the term and not by the `Op` datum it carries: writing the same `q` twice
  asks twice. Writing it once and sharing the answer is `shareT`. -/
  | prim {i o : Type} : Op i o → Term Op G L .static i o
  /-- A `Transform`: a plain function lifted into the language. The design's
  audit killed the reading of `Transform` as a monoid endomorphism — these are
  plain functions, central by construction (they consult nothing, so nothing
  can observe their order against anything else), and therefore `static`.

  A `pureT` may freely copy its input — `fun x => (x, x)` is an ordinary
  function — and that is not in tension with §6a's failure of copy-naturality:
  copying a *value* is not re-asking a *question*. Which consultations were
  asked is settled by where the `prim`s and `shareT`s are, and a `Transform`
  contains neither. -/
  | pureT {i o : Type} : (i → o) → Term Op G L .static i o
  /-- Sequencing: run the first, feed its answer to the second. The composite
  is as opaque as its most opaque part, so the grade is the join. -/
  | seqT {f g : Frag} {i j o : Type} :
      Term Op G L f i j → Term Op G L g j o → Term Op G L (f.join g) i o
  /-- Tensoring: two workflows side by side on a pair of inputs. This is the
  panel's skeleton (design §5.1) — the *reducer* that fans the results back in
  is a choice made in the semantics, where convolution over the key monoid
  lives; the syntax only records that both ran.

  Grade is `Frag.par`, **not** the join: both branches are in flight, so their
  data-dependent widths add. A three-wide fan beside a five-wide fan is eight
  consultations outstanding, and grading it `bounded 5` would be a bound the
  term does not respect. A static side still costs its neighbour nothing,
  since `static` is the grade of zero data-dependent width. -/
  | parT {f g : Frag} {i j k l : Type} :
      Term Op G L f i j → Term Op G L g k l → Term Op G L (f.par g) (i × k) (j × l)
  /-- Alternatives: `⊕`, which is fallback and beam search. The design is
  emphatic that sums are *alternatives*, a different combinator from the
  panel and not a variant of it (design §5.1). Grade is the join. -/
  | sumT {f g : Frag} {i o : Type} :
      Term Op G L f i o → Term Op G L g i o → Term Op G L (f.join g) i o
  /-- Value-dependent branching among enumerated alternatives: the input has
  already been decoded into a coproduct, and each branch handles its side.
  This is how the static fragment buys value-dependence — the huge token space
  factors onto a finite coproduct of verdicts through a decoding `pureT` into
  `Sum`, the payload flowing as data while the verdict steers (design §4).
  Grade is the join, and in particular a choice between static branches is
  still static. -/
  | choiceT {f g : Frag} {i j o : Type} :
      Term Op G L f i o → Term Op G L g j o → Term Op G L (f.join g) (Sum i j) o
  /-- A permission guard: a grant, a policy veto, a refusal. The syntax
  carries only the datum; the semantics reads it as the scalar action of an
  indicator, where refusal is `0` and annihilates everything downstream
  (design §2's Grant/Consent row and §4's `LeftSemimodule` equation,
  `Agentic.Gate`). The undecided `Prop` form belongs
  there, not here — a written term must be a finite datum. A guard changes no
  shape, so the grade passes through untouched. -/
  | gateT {f : Frag} {i o : Type} : Bool → Term Op G L f i o → Term Op G L f i o
  /-- A scope annotation applied to a sub-workflow: model, temperature, agent,
  backend. The semantics reads it as precomposition on a reader's domain, and
  innermost-wins is then a theorem rather than an interpreter rule (design
  §5.3). Annotating changes no shape, so the grade passes through. -/
  | scopeT {f : Frag} {i o : Type} : G → Term Op G L f i o → Term Op G L f i o
  /-- A sharing label applied to a sub-workflow: *this* is the same
  consultation as every other occurrence written with the same label (design
  §6a, "make sharing an operation: `share` reuses a consultation index, `dup`
  spends two"). Body agreement is the designer's obligation — the fold keys on
  the label alone and never compares bodies (acat-bmc).

  The default in this syntax is duplication — a consultation site is the path
  to a `prim` occurrence, so two occurrences are two sites and two draws.
  `shareT` is the override, and the only one: it is what a designer writes to
  mean "ask once, read twice".

  **Meaning obligation, discharged in `Agentic.Meaning`.** Within the dynamic
  extent of `shareT l t`, consultation sites are keyed by
  `(l, site-within-t)` *instead of* by the absolute path through the term.
  Consequently two occurrences of `shareT l t` with equal `l` and
  syntactically equal `t` consult the same sites and read the same answers,
  while `shareT l₁ t` beside `shareT l₂ t` with `l₁ ≠ l₂` is duplication
  again. Note the sharpness of "keyed by `(l, site-within-t)`": the rebase
  reads the label and nothing else, so one label over two *different* bodies
  collides wherever the inner sites coincide, and one label under two
  different scopes rebases identically. Body agreement is the designer's
  obligation and is tracked as acat-bmc; `Term.muExt_shareT` states the
  liability where the fold incurs it. The distinction is not a matter of taste
  for the fold to settle:
  `Agentic.Env.share_ne_dup` proves that consulting one index twice and two
  indices once are *different meanings*, agreeing only at those sample points
  where the answer sheet happens to agree (`Env.share_eq_dup_of_agree`). The
  syntax records which one was written; the fold is obliged to respect it, and
  does: `Term.muExt_dupPair_ne_sharedPair` separates the two terms below,
  `Term.muExt_dupPair_eq_sharedPair_of_const` recovers their agreement exactly
  at the key-blind sample points. The *quantitative* half of §6a — share costs
  one, dup costs two — is not yet paid; `Term.muS` is transparent at `shareT`,
  and its docstring records what charging it would take.

  A label changes where answers come from, never what shape the term has, so
  the grade passes through untouched — `shareT` is grade-transparent in
  exactly the sense `gateT` and `scopeT` are. -/
  | shareT {f : Frag} {i o : Type} : L → Term Op G L f i o → Term Op G L f i o
  /-- Fueled iteration: run the body, and on `Sum.inr` — "not yet, try again
  with this" — go round, up to the given fuel; on `Sum.inl`, answer. The
  semantics solves this as `(M_A · d)* · M_B`, where **fuel is the star's
  truncation** and unboundedness is the star's divergence (design §5.2). The
  fuel is syntax and the grade is unchanged: a loop with a bound on its trip
  count still has a shape known before values flow. -/
  | retryT {f : Frag} {i o : Type} :
      Nat → Term Op G L f i (Sum o i) → Term Op G L f i o
  /-- Data-dependent width, bounded by `n`: map a sub-workflow across a list
  whose length only the values decide, promising at most `n` of them. This is
  precisely the `bounded` fragment — the folds still answer, and what they
  answer is an honest supremum (design §4).

  Grade is `Frag.scale n`, **not** a join with `.bounded n`: `n` copies of a
  body that is itself at most `m` wide is at most `n * m` wide. A three-way fan
  over a five-way fan is fifteen consultations, and grading it `bounded 5`
  would be a bound the term does not respect. Over a static body the fan itself
  is the only data-dependent width, so the grade is exactly `.bounded n` — and
  over a `.bounded 0` body it is `.bounded n` as well, since the fan
  instantiates the body's static shell `n` times over whatever its
  data-dependent width happens to be (`Frag.scale`'s `max 1 m`, acat-l59).

  **The bound is a contract on the MEANING, not the type**, and the contract
  is now kept: both folds of `Agentic.Meaning` truncate the input list at `n`,
  so `fanT 0` denotes the constant `[]` (`Term.muS_fanT_zero`,
  `Term.muExt_fanT_zero`) and no output longer than `n` carries any weight
  (`Term.muS_fanT_eq_zero_of_length_gt`). A length-indexed input type was the
  alternative repair, and truncation did not prove surprising enough to need
  it. Nothing in *this* module makes the promise good — the grade is about
  shape — but the width fold `Term.widthT` now agrees with the grade index on
  the nose (`Term.widthT_eq_width`), which checks the index against a second
  computation of the same arithmetic. The *semantic* width bound, consultations
  in flight at a run, is still owed (acat-vbl). -/
  | fanT {f : Frag} {i o : Type} :
      (n : Nat) → Term Op G L f i o → Term Op G L (f.scale n) (List i) (List o)
  /-- A full value-dependent continuation: plan, then execute the plan the
  values produced. The meaning is a perfectly good kernel — Chapman–Kolmogorov
  *is* bind, and over a complete semiring the composite matrix is a
  well-defined sum — but the continuation is an opaque function, so no finite
  fold over the term exists and the a-priori instruments must answer "no
  a-priori cost" (design §4). The grade says exactly that, and says it in the
  type rather than in a warning. -/
  | bindT {f g : Frag} {i k o : Type} :
      Term Op G L f i k → (k → Term Op G L g PUnit o) → Term Op G L .monadic i o

namespace Term

/-- The grade of a term: the index is the fact, and this is its name. -/
def grade {Op : Type → Type → Type} {G L : Type} {f : Frag} {i o : Type}
    (_t : Term Op G L f i o) : Frag := f

/-- Transport a term along an *equation* between grades. This is not the
weakening the module header refuses: it relabels a term by a grade that is
already the same grade, which is what one needs when an index arrives in a
form the elaborator has not reduced — `Frag.par f .static` where `f` was
wanted, say. It is a `cases` on the equality and nothing else, so it computes
away. -/
def castGrade {Op : Type → Type → Type} {G L : Type} {f g : Frag} {i o : Type}
    (h : f = g) (t : Term Op G L f i o) : Term Op G L g i o :=
  match h with
  | rfl => t

/-- Transporting along `rfl` is the identity, definitionally: the cast leaves
no residue for a fold to reason about. -/
theorem castGrade_rfl {Op : Type → Type → Type} {G L : Type} {f : Frag}
    {i o : Type} (t : Term Op G L f i o) : castGrade rfl t = t := rfl

/-- The derived monadic weakening, for heterogeneous planners: a continuation
in `bindT` must produce terms at one grade, so a planner that answers with a
static term for one verdict and a bounded one for another has no common type
to land in. Prefixing the trivial `pureT` puts any `PUnit`-input term at
`.monadic` — the honest grade for a branch chosen by a value — without a
weakening *constructor*, which would put a second term with the same meaning
into the syntax. The prefix is the identity on `PUnit`, so the meaning is the
term's own. -/
def toMonadic {Op : Type → Type → Type} {G L : Type} {f : Frag} {o : Type}
    (t : Term Op G L f PUnit o) : Term Op G L .monadic PUnit o :=
  .bindT (.pureT (fun _ : PUnit => PUnit.unit)) (fun _ => t)

section Smoke

/-! ### Smoke examples

These are the load-bearing checks on the *encoding*, not decoration. Each one
elaborates at a literal grade with no coercion and no `show`, which is the
claim that the joins reduce definitionally — if `Frag.join`'s equation order
were wrong, these would fail even though the grade arithmetic is "the same". -/

/-- A static pipeline: consult, decode the answer onto a coproduct of
verdicts, branch, all under a permission guard and a fueled retry. Every
combinator here joins `static` with `static`, and the whole tree elaborates at
`.static` with no coercion — the design's "write in the lowest fragment that
expresses the job", made checkable. -/
example (Op : Type → Type → Type) (G L : Type) (q : Op String String) :
    Term Op G L .static String Nat :=
  .retryT 3
    (.gateT true
      (.seqT (.prim q)
        (.seqT (.pureT (fun s => if s.isEmpty then Sum.inl s else Sum.inr s))
          (.choiceT
            (.pureT (fun s => Sum.inr s))
            (.pureT (fun s => Sum.inl s.length))))))

/-- Scoping and alternation are static too: a fallback between two scoped
consultations is a `static` term. -/
example (Op : Type → Type → Type) (G L : Type) (g₁ g₂ : G) (q : Op String Nat) :
    Term Op G L .static String Nat :=
  .sumT (.scopeT g₁ (.prim q)) (.scopeT g₂ (.prim q))

/-- Bounded width: fanning a static consultation across a list, at most three
wide, is `bounded 3` — `static ⊔ bounded 3` reduces to `bounded 3`. -/
example (Op : Type → Type → Type) (G L : Type) (q : Op String String) :
    Term Op G L (.bounded 3) (List String) (List String) :=
  .fanT 3 (.prim q)

/-- A static prefix followed by a bounded stage is bounded: the composite is
as opaque as its most opaque part, and no more. -/
example (Op : Type → Type → Type) (G L : Type) (q : Op String String) :
    Term Op G L (.bounded 3) String (List String) :=
  .seqT (.pureT (fun s => [s])) (.fanT 3 (.prim q))

/-- Two bounded stages *in sequence* take the larger bound: only one of them
is in flight at a time. -/
example (Op : Type → Type → Type) (G L : Type) (q : Op String String) :
    Term Op G L (.bounded 5) (List String) (List String) :=
  .seqT (.fanT 3 (.prim q)) (.fanT 5 (.prim q))

/-- Two bounded stages *side by side* add: a three-wide fan beside a five-wide
fan has eight consultations outstanding, and the grade says eight. This is the
example the join got wrong. -/
example (Op : Type → Type → Type) (G L : Type) (q : Op String String) :
    Term Op G L (.bounded 8) (List String × List String) (List String × List String) :=
  .parT (.fanT 3 (.prim q)) (.fanT 5 (.prim q))

/-- A fan over a fan multiplies: three copies of an at-most-five-wide body is
at most fifteen wide. This is the other example the join got wrong. -/
example (Op : Type → Type → Type) (G L : Type) (q : Op String String) :
    Term Op G L (.bounded 15) (List (List String)) (List (List String)) :=
  .fanT 3 (.fanT 5 (.prim q))

/-- **The acat-l59 witness**, kept as a term. A body that consults, transforms,
and then fans zero ways grades `.bounded 0`; fanning that body three ways runs
its consultation three times, so the honest bound is three. Under the old
`n * m` arithmetic this term elaborated at `.bounded 0` — a bound it plainly
does not respect, since three consultations are outstanding — and the grade is
now `.bounded 3` because `Frag.scale`'s multiplier is `max 1 m`: the body
counts at least as one copy of itself. -/
example (Op : Type → Type → Type) (G L : Type) (q : Op String String) :
    Term Op G L (.bounded 3) (List String) (List (List String)) :=
  .fanT 3
    (.seqT (.seqT (.prim q) (.pureT (fun s => [s])))
      (.fanT 0 (.prim q)))

/-- **Two consultations, by default.** A tensor of two `prim` occurrences of
the same `Op` datum is *two* consultation sites, because a site is a position
in the term and these are two positions: `dupPair` spends two draws, and the
two answers need not agree (`Env.share_ne_dup`). The grade is `static` all the
same — `par` has `static` as its zero, so nothing is paid *in shape* for
putting two shape-known branches side by side, and what is paid in
consultations is the quantitative layer's business, not the grade's. -/
def dupPair {Op : Type → Type → Type} {G L : Type} (q : Op String Nat) :
    Term Op G L .static (String × String) (Nat × Nat) :=
  .parT (.prim q) (.prim q)

/-- **One consultation, twice read — by explicit label agreement.** The same
tensor with both branches labeled `l` denotes a single consultation site whose
answer is read twice: under the keying obligation recorded at `shareT`, each
branch keys its site by `(l, site-within-body)`, and the bodies are
syntactically equal, so the two sites coincide. This is what a designer writes
for "ask once, reuse"; `dupPair` is what they write for "ask twice". The two
are different meanings — that is `Env.share_ne_dup` — and here the difference
is written down rather than inferred. -/
def sharedPair {Op : Type → Type → Type} {G L : Type} (l : L)
    (q : Op String Nat) :
    Term Op G L .static (String × String) (Nat × Nat) :=
  .parT (.shareT l (.prim q)) (.shareT l (.prim q))

/-- Sharing is by label *agreement*, so two different labels are duplication
again: this term is `dupPair` with labels written on it, not `sharedPair`. The
hypothesis `l₁ ≠ l₂` is what makes that the reading — the syntax carries the
labels, and the fold compares them. -/
example (Op : Type → Type → Type) (G L : Type) (l₁ l₂ : L) (_h : l₁ ≠ l₂)
    (q : Op String Nat) :
    Term Op G L .static (String × String) (Nat × Nat) :=
  .parT (.shareT l₁ (.prim q)) (.shareT l₂ (.prim q))

/-- `shareT` is grade-transparent: a label changes where answers come from,
never what shape a term has. True by `rfl` at a *variable* grade, so no fold
has to case-split to know that labelling does not relabel. -/
example (Op : Type → Type → Type) (G L : Type) (f : Frag) (l : L)
    (t : Term Op G L f String Nat) : grade (shareT l t) = grade t := rfl

/-- A static branch beside a bounded one is bounded by the bounded one alone:
a static branch has no data-dependent width to add. -/
example (Op : Type → Type → Type) (G L : Type) (q : Op String String) :
    Term Op G L (.bounded 3) (String × List String) (String × List String) :=
  .parT (.pureT (fun s => s)) (.fanT 3 (.prim q))

/-- The equation order pays off at the term level: a static branch on the left
of a tensor leaves even a *variable* grade untouched, with no coercion — which
is the property `Frag.par`'s equation order exists to provide. -/
example (Op : Type → Type → Type) (G L : Type) (f : Frag)
    (t : Term Op G L f String Nat) :
    Term Op G L f (String × String) (String × Nat) :=
  .parT (.pureT (fun s => s)) t

/-- The derived monadic weakening lands at `.monadic` with no coercion, which
is what makes it usable as the common type in a heterogeneous planner. -/
example (Op : Type → Type → Type) (G L : Type) (q : Op PUnit Nat) :
    Term Op G L .monadic PUnit Nat :=
  toMonadic (.prim q)

/-- Full bind: a consultation whose answer chooses the continuation. The term
is `monadic`, and it is monadic *in its type* — nothing is forbidden, the
instruments are simply told, in advance, what they will not be able to say. -/
example (Op : Type → Type → Type) (G L : Type) (q : Op String String)
    (plan : String → Term Op G L .static PUnit Nat) :
    Term Op G L .monadic String Nat :=
  .bindT (.prim q) plan

/-- Monadic absorbs: a static prefix before a monadic stage is still
monadic, and the grade index says so without a coercion. -/
example (Op : Type → Type → Type) (G L : Type) (q : Op String String)
    (plan : String → Term Op G L .static PUnit Nat) :
    Term Op G L .monadic String Nat :=
  .seqT (.pureT (fun s => s ++ "!")) (.bindT (.prim q) plan)

end Smoke

section GradeExact

/-! ### Exactness of the grade arithmetic

The claims the smoke examples rely on, stated on `Frag` alone. Each is `rfl`:
the index of a composite is not computed by a decision procedure at use sites,
it is already the answer. -/

/-- A static part costs its neighbour nothing. -/
example (n : Nat) : Frag.join .static (.bounded n) = .bounded n := rfl

/-- And costs it nothing on the other side either. -/
example (n : Nat) : Frag.join (.bounded n) .static = .bounded n := rfl

/-- Bounded widths join to the larger bound. -/
example : Frag.join (.bounded 3) (.bounded 5) = .bounded 5 := rfl

/-- Bounded widths in a tensor add. -/
example : Frag.par (.bounded 3) (.bounded 5) = .bounded 8 := rfl

/-- A static branch adds nothing to a tensor — for a *variable* grade, by
`rfl`, which is what keeps `parT` with a static side coercion-free. -/
example (f : Frag) : Frag.par .static f = f := rfl

/-- A fan over a static body is bounded by the fan's own width. -/
example : Frag.scale 3 .static = .bounded 3 := rfl

/-- Nested fans multiply. -/
example : Frag.scale 3 (.bounded 5) = .bounded 15 := rfl

/-- A fan over a `bounded 0` body grades at the fan's own width — the same
grade as a fan over a static body, since the two are the same claim about
shape. This is the index the acat-l59 witness above elaborates at, and it
reduces on literals like the rest. -/
example : Frag.scale 3 (.bounded 0) = .bounded 3 := rfl

/-- An opaque continuation absorbs whatever precedes it — for a *variable*
grade, by `rfl`. -/
example (f : Frag) : Frag.join .monadic f = .monadic := rfl

/-- And whatever follows it, by cases on the neighbour. -/
example (f : Frag) : Frag.join f .monadic = .monadic := Frag.join_monadic f

/-- `grade` returns the index and nothing else — the name of a fact, not a
traversal. -/
example (Op : Type → Type → Type) (G L : Type) (q : Op String String) :
    grade (Term.fanT (G := G) (L := L) 3 (.prim q)) = .bounded 3 := rfl

end GradeExact

end Term

end Agentic
